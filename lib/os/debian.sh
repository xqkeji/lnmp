#!/usr/bin/env bash
# ============================================================================
# lib/os/debian.sh - Debian / Ubuntu 家族（apt）实现
#
# 契约函数的 debian 侧实现，由 lib/os/common.sh 按 OS_FAMILY=debian 分发进来。
# 新增依赖组时，记得同时改 lib/os/rhel.sh 的组名，两边组名必须一一对应。
# ============================================================================

[[ -n ${_LNMP_LIB_OS_DEBIAN:-} ]] && return 0
readonly _LNMP_LIB_OS_DEBIAN=1

pkg_update_debian() {
  export DEBIAN_FRONTEND=noninteractive
  info "  apt-get update"
  apt-get update -qq
}

pkg_installed_debian() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

# --no-install-recommends：最小化镜像里 recommends 会拖进一堆 X/GTK 依赖
pkg_install_debian() {
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
}

# apt 家族没有"需要额外启用的仓库"这一说：源在 sources.list / apt 仓库里管，
# nginx.org 官方源的接入由 10-nginx.sh 完成。留空实现只为让契约成立。
pkg_enable_extra_repos_debian() { return 0; }

# 自签 CA 装进本机信任库：Debian/Ubuntu 只认 /usr/local/share/ca-certificates
# 下的 .crt（PEM 格式），再由 update-ca-certificates 汇总进
# /etc/ssl/certs/ca-certificates.crt。工具来自 ca-certificates 包（common 组已装）。
# 已装且内容一致就直接跳过：update-ca-certificates 每次都要重扫整个证书目录。
ca_install_trust_debian() {
  local dst="/usr/local/share/ca-certificates/$(basename "$1")" out
  if [[ -f $dst ]] && cmp -s "$1" "$dst"; then
    info "  本机信任库里已有该 CA：${dst}"
    return 0
  fi
  if ! command -v update-ca-certificates >/dev/null 2>&1; then
    warn "  缺 update-ca-certificates（ca-certificates 包），本机信任库未更新：$1"
    return 1
  fi
  mkdir -p /usr/local/share/ca-certificates
  install -m 644 "$1" "$dst"
  if ! out="$(update-ca-certificates 2>&1)"; then
    warn "  update-ca-certificates 执行失败：$(printf '%s' "$out" | tail -1)"
    return 1
  fi
  info "  CA 已装进本机信任库：${dst}（撤销：删掉该文件后跑 sudo update-ca-certificates --fresh）"
}

# --- 依赖组包名表（debian 家族）---------------------------------------------
# 每组"为什么要装"的说明放在 scripts/00-deps.sh 的对应 deps_* 函数里，
# 那份理由两个家族通用，这里只记包名。
pkgs_for_debian() {
  case "$1" in
    common)
      printf '%s\n' \
        build-essential autoconf automake libtool bison re2c pkg-config unzip xz-utils \
        procps git curl wget ca-certificates tar gzip findutils iproute2 ;;
    nginx_src)
      printf '%s\n' libpcre2-dev zlib1g-dev libssl-dev ;;
    nginx_acme)
      printf '%s\n' libclang-dev ;;
    nginx_repo)
      # 仅 apt 路线（nginx_install=apt）会问到本组
      printf '%s\n' curl gnupg2 ca-certificates lsb-release debian-archive-keyring ;;
    php)
      printf '%s\n' \
        libxml2-dev libcurl4-openssl-dev libonig-dev libsqlite3-dev \
        libzip-dev libpng-dev libjpeg-dev libfreetype-dev libwebp-dev \
        libargon2-dev libsodium-dev libxslt1-dev libssl-dev zlib1g-dev ;;
    mongodb)
      printf '%s\n' libcurl4 libssl3 ;;
    ocserv)
      printf '%s\n' libgnutls28-dev nettle-dev libev-dev \
        libseccomp-dev meson ninja-build pkg-config libpam0g-dev libreadline-dev ;;
    *) die "未知依赖组：$1" ;;
  esac
}
