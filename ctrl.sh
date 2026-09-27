#!/usr/bin/env bash
# ============================================================================
# ctrl.sh - LNMP 服务管理（start / stop / restart / status）
#
# 用法：
#   sudo ./ctrl.sh <动作> [服务...]
#   动作：start | stop | restart | status
#   服务：nginx php-fpm mongodb ocserv（缺省 = 全部）
#
# 有 systemd 走 systemctl；无 systemd（容器）走各组件二进制直启。
# 单独执行：sudo ./ctrl.sh restart
# ============================================================================

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/lib" && pwd)/common.sh"
source "$LIB_DIR/service.sh"

readonly ALL_SVCS=(nginx php-fpm mongodb ocserv)

usage() {
  cat <<EOF
用法：sudo ./ctrl.sh <动作> [服务...]

动作：
  start    启动
  stop     停止
  restart  重启
  status   查看运行状态

服务（缺省=全部）：nginx  php-fpm  mongodb  ocserv

示例：
  sudo ./ctrl.sh restart            # 全部重启
  sudo ./ctrl.sh status             # 查看全部状态
  sudo ./ctrl.sh stop nginx mongodb  # 只停 nginx 和 mongodb
EOF
}

main() {
  local act="${1:-}"; shift || true
  [[ $act =~ ^(start|stop|restart|status)$ ]] || { usage; exit 1; }

  local -a targets=("$@")
  ((${#targets[@]})) || targets=("${ALL_SVCS[@]}")

  init_log

  local t ok
  for t in "${targets[@]}"; do
    case "$t" in
      nginx | php-fpm | mongodb | ocserv) ;;
      *) warn "未知服务：$t，跳过"; continue ;;
    esac

    if [[ $act == status ]]; then
      if svc_status "$t" >/dev/null 2>&1; then
        info "  $t 运行中"
      else
        info "  $t 未运行"
      fi
    else
      printf '%-9s %s ... ' "$t" "$act"
      local ok unit
      # mongodb 走安全启动（会自动修正数据目录属主、清锁），其余直接 svc_*
      if [[ $t == mongodb && ( $act == start || $act == restart ) ]]; then
        start_mongod_safe && ok=0 || ok=1
      else
        svc_"$act" "$t" >/dev/null 2>&1 && ok=0 || ok=1
      fi
      # ok 存的是原始退出码（0=成功，非0=失败），故用 ((ok == 0)) 判定，
      # 不能写 ((ok)) —— bash 里 ((0)) 为假、((1)) 为真，会整个反判
      if ((ok == 0)); then
        echo "完成"
      else
        echo "失败"
        # 可落地的定位提示：systemd 下若 unit 不存在，多半是 install 没跑到
        # systemd 步骤（前面步骤 abort 过）；否则提示看 systemctl status 详情
        if have_systemd; then
          unit="${SVC_UNIT[$t]:-$t}"
          # 用 systemctl cat 判断 unit 文件是否存在（标准做法）：返回 0 = 存在（无论 active 与否），
          # 非 0 = 不存在。避免 list-unit-files | grep 在 set -o pipefail 下误报“未找到”。
          if ! systemctl cat "${unit}.service" >/dev/null 2>&1; then
            warn "    未找到 ${unit}.service：install 未完成（先 sudo ./install.sh 跑完，systemd 步骤会生成 unit）"
          else
            warn "    排查：systemctl status ${unit} -l  /  journalctl -xeu ${unit}"
          fi
        fi
      fi
    fi
  done
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
