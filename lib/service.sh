#!/usr/bin/env bash
# ============================================================================
# lib/service.sh - 服务启停控制（systemd / 无 systemd 双路径）
#
# 仅被 source，不单独执行。install.sh、ctrl.sh、scripts/20-mongodb.sh
# 都会用到这里的 svc_start / svc_stop / svc_restart / svc_status。
#
# 设计：
#   - 有 systemd：统一走 systemctl
#   - 无 systemd（容器）：走各组件的 direct_* 函数，用二进制直启/直停
# ============================================================================

# 已加载则跳过（被重复 source 时 readonly 会报错）
[[ -n ${_LNMP_LIB_SERVICE:-} ]] && return 0
readonly _LNMP_LIB_SERVICE=1

# 控制脚本用的短名 -> systemd unit 名
declare -A SVC_UNIT=(
  [nginx]=nginx
  [php-fpm]=php-fpm
  [mongodb]=mongod
  [ocserv]=ocserv
)

# 判断 systemd 是否真正在管理本机：光有 systemctl 二进制不够（openEuler 等
# 容器镜像预装了 systemctl 但 PID1 不是 systemd，直接调用会报 "Host is down"）。
# /run/systemd/system 只有 systemd 起来后才存在，是标准判据。
have_systemd() {
  command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]
}

# 是否存在非僵尸的同名进程。容器里 PID1 往往不 reap 子进程，daemon 化服务
# 退出后会留下 comm 仍可被 pgrep 匹配的 zombie，直接 pgrep 会误判"还在跑"
proc_running() {
  local p s
  for p in $(pgrep -x "$1" 2>/dev/null || true); do
    s="$(awk '/^State:/{print $2}' "/proc/$p/status" 2>/dev/null)" || true
    [[ $s != Z ]] && return 0
  done
  return 1
}

# --- 无 systemd 时的直接启停实现 -------------------------------------------
# nginx 二进制按路线取：apt=/usr/sbin/nginx，src=/usr/local/nginx/sbin/nginx
_nginx_bin() {
  if [[ $(nginx_route) == apt ]] && command -v nginx >/dev/null 2>&1; then
    command -v nginx
  else
    printf '%s' "$PREFIX_NGINX/sbin/nginx"
  fi
}
direct_start_nginx()  { "$(_nginx_bin)"; }
direct_stop_nginx()   { "$(_nginx_bin)" -s quit 2>/dev/null || true; }
direct_status_nginx() { proc_running nginx; }

direct_start_php_fpm()  { "$PREFIX_PHP/sbin/php-fpm" --daemonize --fpm-config "$PREFIX_PHP/etc/php-fpm.conf"; }
direct_stop_php_fpm()   { pkill -x php-fpm 2>/dev/null || true; }
direct_status_php_fpm() { proc_running php-fpm; }

# mongod.conf 已配 processManagement.fork:true，直启会自己 daemon 化
direct_start_mongodb()  { "$PREFIX_MONGODB/bin/mongod" --config "$PREFIX_MONGODB/mongod.conf"; }
direct_stop_mongodb()   { "$PREFIX_MONGODB/bin/mongod" --config "$PREFIX_MONGODB/mongod.conf" --shutdown 2>/dev/null || pkill -x mongod 2>/dev/null || true; }
direct_status_mongodb() { proc_running mongod; }

# ocserv 不带 -f 时自己 daemon 化（pid-file 写在 ocserv.conf 里）。
# 进程名注意：1.5 起 master 叫 ocserv-main（另有 ocserv-sm/worker），不是 ocserv。
# stop 要等旧 master 真正退出（端口释放）再返回，否则紧随的 start 会 bind 撞车
direct_start_ocserv()  { /usr/local/sbin/ocserv --config "$OCSERV_SYS/ocserv.conf"; }
direct_stop_ocserv() {
  local i
  pkill -x ocserv-main 2>/dev/null || true
  for ((i = 0; i < 5; i++)); do
    proc_running ocserv-main || return 0
    sleep 1
  done
  pkill -9 -x ocserv-main 2>/dev/null || true
  return 0
}
direct_status_ocserv() { proc_running ocserv-main; }

# 判定服务是否真的在运行。
# 不迷信 systemctl is-active 的退出码：在 Type=forking 单元、以及个别 systemd 版本下，
# is-active 偶发返回非 0 即使服务实际 active（这正是一度"服务已起但 ctrl.sh 报失败"的根因）。
# 故以"进程确实在跑"为最终裁决——systemctl is-active 优先，失败时再用 pgrep 兜底。
#
# 关键点：systemctl restart 在 forking 单元上返回后，服务可能处于"旧进程已退、新进程尚未
# 完全就绪"的瞬时空窗（或 unit 配了 Restart=on-failure 由 systemd 兜底重试拉起），此刻
# is-active 与 pgrep 都会短暂返回非 0。若只检查一次就会误判失败。故"是否起来"判定重试若干
# 次（每次短 sleep），吸收该空窗；"是否停下"则立即裁决（停成功时首轮即返回，不拖慢）。
_svc_is_up() {
  local unit="$1" svc="$2"
  local proc="$svc"
  [[ $svc == mongodb ]] && proc=mongod   # mongod 进程名是 mongod 而非 mongodb
  [[ $svc == ocserv  ]] && proc=ocserv-main   # ocserv master 进程名是 ocserv-main
  local i
  for ((i = 0; i < 5; i++)); do
    # 注意：必须用 if 包裹判定命令，不能写 "cmd && return 0"——
    # set -e 下"失败命令作为函数内独立语句"会中止整个函数，导致 pgrep 兜底层永远执行不到
    if systemctl is-active --quiet "$unit" 2>/dev/null; then
      return 0
    fi
    if proc_running "$proc"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# svc_action <start|stop|restart|status> <短名>
svc_action() {
  local act="$1" svc="$2"
  local unit="${SVC_UNIT[$svc]:-$svc}"

  if have_systemd; then
    case "$act" in
      status)
        systemctl is-active --quiet "$unit" ;;
      start)
        systemctl start "$unit" >/dev/null 2>&1 || true
        _svc_is_up "$unit" "$svc" ;;
      restart)
        systemctl restart "$unit" >/dev/null 2>&1 || true
        _svc_is_up "$unit" "$svc" ;;
      stop)
        systemctl stop "$unit" >/dev/null 2>&1 || true
        # 停止成功 = 进程已不在（is-active 与 pgrep 双重确认）
        _svc_is_up "$unit" "$svc" && return 1 || return 0 ;;
    esac
  else
    # 函数名不能带连字符：短名 php-fpm 必须转成 php_fpm 才能拼出 direct_* 函数，
    # 否则无 systemd（容器）下 php-fpm 的启停/状态全部 127 command not found
    local fn="${svc//-/_}"
    case "$act" in
      restart) direct_stop_"$fn"; direct_start_"$fn" ;;
      status)  direct_status_"$fn" ;;
      *)       "direct_${act}_${fn}" ;;
    esac
  fi
}

svc_start()   { svc_action start   "$1"; }
svc_stop()    { svc_action stop    "$1"; }
svc_restart() { svc_action restart "$1"; }
svc_status()  { svc_action status  "$1"; }

# ---------------------------------------------------------------------------
# 开机自启：只为「实际已安装」的服务设置 systemd enable
#
# 为什么按二进制存在判断：选装模式（如只装 nginx）时若无条件 enable 全部三个
# 服务，会把未安装的服务写进开机依赖，导致开机卡在失败的 unit 上。这里逐个
# 检查 PREFIX_* 下二进制是否就绪，只 enable 真正装了的。
#
# 无 systemd（容器）→ 直接返回，自启交给 ctrl.sh 手动管理。幂等，可重复调用。
# ---------------------------------------------------------------------------
enable_boot_services() {
  have_systemd || return 0
  local -a units=()
  ( command -v nginx >/dev/null 2>&1 || [[ -x $PREFIX_NGINX/sbin/nginx ]] ) && units+=(nginx)
  [[ -x $PREFIX_PHP/sbin/php-fpm  ]]          && units+=(php-fpm)
  [[ -x $PREFIX_MONGODB/bin/mongod ]]         && units+=(mongod)
  [[ -x /usr/local/sbin/ocserv ]]             && units+=(ocserv)
  ((${#units[@]})) || return 0
  systemctl daemon-reload 2>/dev/null || true
  systemctl enable "${units[@]}" >/dev/null 2>&1 || true
  info "  已设置开机自启：${units[*]}"
}

# 确保某服务在运行（最多等 30s），用于初始化类步骤的前置条件
ensure_running() {
  local svc="$1" i
  svc_status "$svc" || svc_start "$svc"
  for ((i = 0; i < 30; i++)); do
    svc_status "$svc" && return 0
    sleep 1
  done
  return 1
}

# ---------------------------------------------------------------------------
# mongod 专用安全启动
#
# 背景坑：账号恢复流程（recover_mongodb_account）曾以 root 身份起过
#   mongod --noauth --fork 来建账号，这会把 ${PREFIX_MONGODB}/data 下的文件
#   写成 root 属主；而 systemd 单元用 User=mongodb 启动会 Permission denied，
#   导致 mongod 再也起不来。故启动前必须把数据目录属主改回 mongodb。
#
# 流程：杀残留孤儿 → 修正属主 → 清陈旧锁 → restart/start →
#       仍失败则 --repair 兜底 → 失败打印真实日志。
# 返回 0 = 拉起成功；1 = 失败（调用方自行告警，不在此中止安装）。
# ---------------------------------------------------------------------------
start_mongod_safe() {
  local bin="$PREFIX_MONGODB/bin/mongod"
  local conf="$PREFIX_MONGODB/mongod.conf"
  local lock="$PREFIX_MONGODB/data/mongod.lock"

  # 1) 清掉可能残留的孤儿进程（recover 遗留的 noauth 实例、上次的僵死进程等）
  if pgrep -x mongod >/dev/null 2>&1; then
    have_systemd && systemctl stop mongod 2>/dev/null || true
    pkill -x mongod 2>/dev/null || true
    sleep 2
    pkill -9 -x mongod 2>/dev/null || true
    sleep 1
  fi

  # 2) 修正数据目录属主（root 起过的实例会把文件写成 root，systemd 用户起不来）
  if id mongodb >/dev/null 2>&1; then
    chown -R mongodb:mongodb "$PREFIX_MONGODB/data" "$PREFIX_MONGODB/log" 2>/dev/null || true
  fi

  # 3) 清陈旧锁（仅在确认无任何 mongod 进程持有时）
  [[ -f $lock ]] && ! pgrep -x mongod >/dev/null 2>&1 && rm -f "$lock"

  # 4) 启动（restart 不行就 start），最终以"进程是否真在跑"判定成败
  #    svc_* 自带双路径：有 systemd 走 systemctl，无 systemd（容器）直启二进制。
  #    （systemctl restart/start 退出码、is-active 退出码在 forking 单元下都不可靠，
  #     用 _svc_is_up：is-active 优先，失败时以 pgrep 进程存在性兜底）
  svc_restart mongodb 2>/dev/null || svc_start mongodb 2>/dev/null || true
  if _svc_is_up mongod mongodb; then
    return 0
  fi

  # 5) 仍失败：最后手段 —— 以 mongodb 用户 --repair 修复数据文件
  warn "  mongod 常规启动失败，尝试 mongod --repair"
  if id mongodb >/dev/null 2>&1; then
    su mongodb -s /bin/bash -c "'$bin' --config '$conf' --repair" >/dev/null 2>&1 \
      || "$bin" --config "$conf" --repair >/dev/null 2>&1 || true
    chown -R mongodb:mongodb "$PREFIX_MONGODB/data" 2>/dev/null || true
  fi
  systemctl start mongod 2>/dev/null || svc_start mongodb 2>/dev/null || true
  _svc_is_up mongod mongodb && return 0

  # 6) 失败：打印真实错误，便于定位（不再静默）
  warn "  mongod 启动失败，最近日志："
  tail -n 20 "$PREFIX_MONGODB/log/mongod.log" 2>/dev/null | sed 's/^/    /' || true
  return 1
}
