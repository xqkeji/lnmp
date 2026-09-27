#!/usr/bin/env bash
# ============================================================================
# lib/preflight.sh - 环境预检
#
# 拆成 4 个独立检查，是为了让子脚本能只检查自己关心的项：
#   装 nginx    -> preflight + require_ports 80        + require_disk
#   装 mongodb  -> preflight + require_avx + require_ports 27017 + require_disk
#   全量安装    -> 四项全查
#
# 不合并成一个 preflight，否则单独重跑 nginx 会被 mongodb 的端口/AVX 检查拦下。
# ============================================================================

[[ -n ${_LNMP_LIB_PREFLIGHT:-} ]] && return 0
readonly _LNMP_LIB_PREFLIGHT=1

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/os.sh"

# 基础检查：root 权限、必需命令、发行版、CPU 架构
preflight() {
  step "预检运行环境"

  [[ $EUID -eq 0 ]] || die "请以 root 执行：sudo $0"

  detect_os
  case "$OS_FAMILY" in
    debian | rhel) ;;
    suse) die "暂不支持 openSUSE/SLES（框架已预留 OS_FAMILY=suse，欢迎补充包表）" ;;
    *) die "本脚本支持 Debian/Ubuntu 与 RHEL/Rocky/Alma/CentOS/openEuler，当前是 ${OS_PRETTY}" ;;
  esac
  info "  系统：${OS_PRETTY}（家族 ${OS_FAMILY}，包管理器 ${PKG}）"

  # 最小化镜像（如 debian:12）可能连 curl 都没有：先顺手用系统包管理器补装，
  # 补不上（离线/未知发行版）再由 need_cmd 给出明确报错
  if ! command -v curl >/dev/null 2>&1; then
    warn "  缺少 curl，尝试用 ${PKG} 自动安装"
    pkg_install "下载工具" curl ca-certificates || true
  fi
  need_cmd curl
  need_cmd tar
  need_cmd sha256sum

  # MongoDB 官方 tarball 只发了 x86_64 / aarch64，这里限定 x86_64 以免选错包
  ARCH="$(uname -m)"
  [[ $ARCH == x86_64 ]] || die "当前架构 $ARCH 不受支持（脚本只处理 x86_64 的 MongoDB 包）"

  info "  基础预检通过"
}

# require_ports <端口...>：被其它进程占用才中止；被本套装自身服务占用则放行
# （重装 / 幂等场景下，nginx / php-fpm / mongod 本来就在跑，属正常）
require_ports() {
  local p
  for p in "$@"; do
    if port_busy "$p"; then
      if port_owned_by_us "$p"; then
        warn "  端口 $p 已被本套装服务（$(port_owner "$p" 2>/dev/null)）占用，属重装/幂等场景，跳过检查"
      else
        die "端口 $p 已被其它进程占用，请先释放后再安装"
      fi
    fi
  done
  info "  端口检查通过"
}

# MongoDB 5.0+ 的 tarball 强制要求 AVX 指令集，缺了会直接启动失败
require_avx() {
  grep -qw avx /proc/cpuinfo \
    || die "CPU 不支持 AVX 指令集，MongoDB 无法启动（常见于老旧 VPS）"
  info "  CPU 支持 AVX"
}

# 编译 PHP + nginx 大约需要 8G 可用空间
require_disk() {
  local avail
  avail=$(df -Pk /usr/local | awk 'NR==2 {print $4}')
  ((avail >= 8 * 1024 * 1024)) \
    || die "磁盘空间不足，/usr/local 至少需要 8GB 可用，当前 $((avail / 1024))MB"
  info "  磁盘空间充足（$((avail / 1024))MB 可用）"
}
