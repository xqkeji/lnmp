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
  if [[ -x /usr/local/sbin/ocserv ]]; then
    ver=$(/usr/local/sbin/ocserv --version 2>&1 | sed -n 1p) || true; info "  ${ver}"
    if svc_status ocserv; then
      info "  ocserv 运行中（AnyConnect 客户端连 https://<服务器IP>:${CFG_ocserv_port:-4443}/）"
    else
      warn "  ocserv 未运行（启动：sudo ./ctrl.sh start ocserv）"
    fi
  fi

  # 防火墙收紧状态（scripts/78-firewall.sh 的策略：对外仅 80/443/ocserv 端口）
  local fw=""
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    if firewall-cmd --query-service=ssh >/dev/null 2>&1; then
      fw="firewalld：SSH 仍对外开放（ocserv 就绪后重跑 78-firewall.sh 收紧）"
    else
      fw="firewalld：对外仅 80/443/${CFG_ocserv_port:-4443}，SSH 仅限本机 + VPN 段"
    fi
  elif command -v iptables >/dev/null 2>&1 && iptables -S LNMP-IN >/dev/null 2>&1; then
    fw="iptables（LNMP-IN 链）：对外仅 80/443/${CFG_ocserv_port:-4443}，其余端口（含 27017）拒绝"
  fi
  # 三条路径都没命中就是"根本没收紧"，必须显式说出来：78-firewall.sh 现在遇到
  # 缺 iptables 只告警不中止，若这里保持沉默，自检报告看着像一切正常。
  if [[ -n $fw ]]; then
    info "  防火墙  $fw"
  else
    warn "  防火墙  未收紧：既没有运行中的 firewalld，也没有 iptables 的 LNMP-IN 链"
  fi

  # mongod 是否真的在运行（上面的 --version 只是看版本号，不代表进程在跑）
  if svc_status mongodb; then
    info "  mongod 运行中"
  else
    warn "  mongod 未运行（启动：sudo ./ctrl.sh start mongodb）"
  fi

  # 只跑一次 php -m，后面在变量里比对
  local mods miss=() e
  mods="$("$PREFIX_PHP/bin/php" -m 2>/dev/null)" || true

  # sodium / openssl 也在列：它们由 ./configure 默认开启，但前提是编译时有对应的
  # 开发包与 pkg-config。缺了 PHP 照样编译成功、只是扩展静默缺席，要等应用调
  # password_hash / curl https 才暴露，所以在这里就报出来。
  local -a want_ext=(zip gd mongodb xqkeji sodium openssl)
  for e in "${want_ext[@]}"; do
    printf '%s\n' "$mods" | grep -qix "$e" || miss+=("$e")
  done

  if ((${#miss[@]})); then
    warn "  以下扩展未加载：${miss[*]:-}"
  else
    info "  PHP 扩展全部就绪：${want_ext[*]}"
  fi

  # 上传目录禁执行 PHP：每个 php location 前都该有 guard，少一段就是少一道闸。
  # 按数量比对而不是"文件里出现过就算"：一个站点两个 server 块，只加固了一个
  # 块的情况必须报出来。
  local etc="$NGINX_ETC"
  [[ ${CFG_nginx_install:-apt} == src ]] && etc="$PREFIX_NGINX/conf"
  local guard="$etc/snippets/lnmp-upload-guard.conf"
  if [[ ! -f $guard ]]; then
    warn "  上传防护  缺 $guard（重跑 sudo ${ROOT_DIR}/scripts/80-nginx-conf.sh 生成）"
  else
    local f n_ok=0 nphp nguard
    local -a unguard=()
    for f in "$etc/conf.d"/*.conf; do
      [[ -f $f ]] || continue
      [[ "$(basename "$f")" == acme.conf ]] && continue   # http 上下文的公共配置，不含 location
      nphp=$(grep -cE '^[[:space:]]*location[^;{]*\.php' "$f" || true)
      ((nphp > 0)) || continue
      nguard=$(grep -c 'lnmp-upload-guard\.conf' "$f" || true)
      if (( nguard >= nphp )); then
        n_ok=$((n_ok + 1))
      else
        unguard+=("$(basename "$f") ${nguard}/${nphp}")
      fi
    done
    if ((${#unguard[@]})); then
      warn "  上传防护  以下站点的 php location 未被 guard 覆盖：${unguard[*]}"
      warn "            重跑 sudo ${ROOT_DIR}/scripts/80-nginx-conf.sh 会自动注入（改前留 .bak-lnmp）"
    elif ((n_ok == 0)); then
      info "  上传防护  片段已就绪（${guard}），conf.d 下暂无 PHP 站点"
    else
      info "  上传防护  ${n_ok} 个站点的上传目录已禁执行 PHP（${CFG_upload_dirs:-$UPLOAD_DIRS_DEFAULT}）"
    fi
  fi

  # 本地测试 HTTPS（80-nginx-conf.sh 的 gen_local_tls）。这里只读状态不补签：
  # 名单改动、证书重签都归 80 号脚本，自检偷偷生成会让"配置和盘上不是一回事"
  # 这件事永远看不见。
  if [[ -n ${CFG_local_tls_names:-} ]]; then
    local tls_vhost="$etc/conf.d/local-tls.conf" tls_end="" tls_bad=""
    if [[ -s $LOCAL_TLS_CRT && -s $LOCAL_TLS_KEY ]]; then
      tls_end="$(openssl x509 -in "$LOCAL_TLS_CRT" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')" || true
      # 多个问题用"、"接在同一行报出来，别为每件事各刷屏
      openssl x509 -in "$LOCAL_TLS_CRT" -noout -checkend 2592000 >/dev/null 2>&1 \
        || tls_bad="${tls_bad:+${tls_bad}、}剩余有效期不足 30 天"
      # 链这一项单独查：CA 被重建过、站点证书还是旧 CA 签的，nginx 起得来、
      # 浏览器只报"证书链不完整"，光比名单和有效期发现不了
      openssl verify -CAfile "$LOCAL_TLS_CA" "$LOCAL_TLS_CRT" >/dev/null 2>&1 \
        || tls_bad="${tls_bad:+${tls_bad}、}证书链不通到当前 CA"
    else
      tls_bad="缺证书文件"
    fi
    [[ -f $tls_vhost ]] || tls_bad="${tls_bad:+${tls_bad}、}缺站点 ${tls_vhost}"

    if [[ -n $tls_bad ]]; then
      warn "  本地 TLS  ${tls_bad}（重跑 sudo ${ROOT_DIR}/scripts/80-nginx-conf.sh 会自动补齐）"
    else
      info "  本地 TLS  就绪，到期 ${tls_end:-未知}"
      info "            证书 ${LOCAL_TLS_CRT} / CA ${LOCAL_TLS_CA}"
      info "            站点 ${tls_vhost}（已存在则保留：改了名单要手工同步里面的 server_name）"
      info "            名单 ${CFG_local_tls_names}"
      info "            设备侧只导入 CA 这一份即可（本机信任库脚本已处理，撤销方式见 README）"
    fi
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
              ocserv   /usr/local/sbin（配置: ${OCSERV_SYS}）
   端口       nginx ${PORT_NGINX} / php-fpm ${PORT_PHP_FPM} / mongodb ${PORT_MONGODB} / ocserv ${CFG_ocserv_port:-4443}
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
    for u in nginx php-fpm mongod ocserv; do
      case "$u" in
        nginx)   command -v nginx >/dev/null 2>&1 || [[ -x $PREFIX_NGINX/sbin/nginx ]] || continue ;;
        php-fpm) [[ -x $PREFIX_PHP/sbin/php-fpm  ]] || continue ;;
        mongod)  [[ -x $PREFIX_MONGODB/bin/mongod ]] || continue ;;
        ocserv)  [[ -x /usr/local/sbin/ocserv ]] || continue ;;
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
