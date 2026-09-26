#!/usr/bin/env bash
# ============================================================================
# scripts/99-verify.sh - 安装结果自检
#
# 单独执行：sudo ./scripts/99-verify.sh
# ============================================================================

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
source "$LIB_DIR/config.sh"
source "$LIB_DIR/preflight.sh"
source "$LIB_DIR/service.sh"

step_verify() {
  step "安装结果"

  # 先确保已安装服务开机自启（幂等），再报告状态
  enable_boot_services

  # 取首行统一用 sed -n 1p：head 会提前关闭管道导致上游 SIGPIPE，
  # 配合 set -o pipefail 会把正常命令误判为失败
  local ver nginx_bin
  nginx_bin="$(command -v nginx 2>/dev/null || echo "$PREFIX_NGINX/sbin/nginx")"
  ver=$("$nginx_bin" -v 2>&1 | sed -n 1p) || true;                 info "  ${ver}"
  ver=$("$PREFIX_PHP/bin/php" -v | sed -n 1p) || true;               info "  ${ver}"
  ver=$("$PREFIX_MONGODB/bin/mongod" --version | sed -n 1p) || true; info "  ${ver}"
  ver=$(composer --version | sed -n 1p) || true;                     info "  ${ver}"
  ver=$(pie --version | sed -n 1p) || true;                          info "  ${ver}"

  # mongod 是否真的在运行（上面的 --version 只是看版本号，不代表进程在跑）
  if svc_status mongodb; then
    info "  mongod 运行中"
  else
    warn "  mongod 未运行（启动：sudo ./ctrl.sh start mongodb）"
  fi

  # 只跑一次 php -m，后面在变量里比对
  local mods miss=() e
  mods="$("$PREFIX_PHP/bin/php" -m 2>/dev/null)" || true

  for e in zip gd mongodb xqkeji; do
    printf '%s\n' "$mods" | grep -qix "$e" || miss+=("$e")
  done

  if ((${#miss[@]})); then
    warn "  以下扩展未加载：${miss[*]:-}"
  else
    info "  zip / gd / mongodb / xqkeji 全部就绪"
  fi

  local repo_root="${LIB_DIR%/*}"
  cat <<EOF

============================================================================
 LNMP 安装完成
   安装路径   nginx    $(command -v nginx || echo "${PREFIX_NGINX}")  (配置: ${NGINX_ETC})
              mongodb  ${PREFIX_MONGODB}
              php      ${PREFIX_PHP}
              composer ${PREFIX_COMPOSER}
              pie      ${PREFIX_PIE}
   端口       nginx ${PORT_NGINX} / php-fpm ${PORT_PHP_FPM} / mongodb ${PORT_MONGODB}
   站点根目录 $([[ ${CFG_nginx_install:-apt} == apt ]] && echo /usr/share/nginx/html || echo ${PREFIX_NGINX}/html)
   日志       ${LOG_FILE}
============================================================================

日常服务管理（启动 / 停止 / 重启 / 状态，支持单个服务）
  sudo ${repo_root}/ctrl.sh start              # 全部启动
  sudo ${repo_root}/ctrl.sh restart            # 全部重启
  sudo ${repo_root}/ctrl.sh restart nginx      # 仅重启 nginx
  sudo ${repo_root}/ctrl.sh restart php-fpm    # 仅重启 php-fpm
  sudo ${repo_root}/ctrl.sh restart mongodb    # 仅重启 mongodb
  sudo ${repo_root}/ctrl.sh stop nginx mongodb # 停指定服务
  sudo ${repo_root}/ctrl.sh status             # 查看全部状态

开机自启（重启服务器后自动拉起）
EOF

  if have_systemd; then
    local u enabled
    for u in nginx php-fpm mongod; do
      case "$u" in
        nginx)   command -v nginx >/dev/null 2>&1 || [[ -x $PREFIX_NGINX/sbin/nginx ]] || continue ;;
        php-fpm) [[ -x $PREFIX_PHP/sbin/php-fpm  ]] || continue ;;
        mongod)  [[ -x $PREFIX_MONGODB/bin/mongod ]] || continue ;;
      esac
      if systemctl is-enabled "$u" >/dev/null 2>&1; then enabled="已启用"; else enabled="未启用"; fi
      printf '  %-8s %s\n' "$u" "$enabled"
    done
  else
    info "  无 systemd（容器/无 init）：开机自启跳过，用 sudo ./ctrl.sh 手动管理"
  fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  init_log
  step_verify
fi
