#!/usr/bin/env bash
# ============================================================================
# scripts/00-deps.sh - 系统依赖库（apt / dnf 双支持）
#
# 包名按发行版家族分成两组表（DEBIAN_PKGS / RHEL_PKGS），由 pkgs_for 选择：
#   deps_common   编译工具链（gcc/build-essential/git/curl...）
#   deps_nginx    nginx 编译依赖
#   deps_php      PHP 编译依赖
#   deps_mongodb  mongod 运行时依赖
#
# 支持：Debian/Ubuntu（apt 家族）；RHEL/Rocky/Alma/CentOS/Fedora/openEuler（rhel 家族）
# rhel 家族会先启用 EPEL / CRB（oniguruma、libsodium 等来自那里）。
#
# 单独执行：
#   sudo ./scripts/00-deps.sh          # 全装
#   sudo ./scripts/00-deps.sh php      # 只装 PHP 编译依赖
# ============================================================================

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
source "$LIB_DIR/config.sh"
source "$LIB_DIR/preflight.sh"

# --- 包名表 -----------------------------------------------------------------
# 约定：每组两行数组，[debian]=Debian/Ubuntu 包名，[rhel]=RHEL/Rocky/openEuler 包名。
# 新增包时两个家族都要补；某家族确实没有对应包就留空串并在旁边注明。

pkgs_for() {  # pkgs_for <组名>：按 OS_FAMILY 输出对应包名数组（eval 复制，只读白名单组名）
  local group="$1"
  case "$group" in
    common)
      # unzip：PIE 内部用 composer 下载 zip 格式的扩展包，php 没编 zip 扩展前
      # 必须有 unzip/7z 兜底（Debian 官方镜像预装了，最小化 Rocky/openEuler 没有）
      # xz：ocserv 官方源码包是 tar.xz，最小化镜像里没有 xz 工具
      # procps：lib/service.sh 的 pgrep 状态兜底依赖它（rocky:9 最小镜像不带）
      # iproute：lib/common.sh 的 port_owner 靠 ss -p 认端口归属，最小镜像不带 ss
      # 时 port_owned_by_us 永远返回"不是我家的"，第二次重跑 install.sh 会在
      # preflight 直接 die「端口 27017 已被其它进程占用」
      if os_is_debian; then printf '%s\n' \
        build-essential autoconf automake libtool bison re2c pkg-config unzip xz-utils \
        procps git curl wget ca-certificates tar gzip findutils iproute2
      else printf '%s\n' \
        gcc gcc-c++ make autoconf automake libtool bison unzip xz procps-ng \
        git curl wget ca-certificates tar gzip findutils iproute
      fi ;;
    nginx_src)
      if os_is_debian; then printf '%s\n' libpcre2-dev zlib1g-dev libssl-dev
      else printf '%s\n' pcre2-devel zlib-devel openssl-devel; fi ;;
    nginx_acme)
      # ngx_http_acme_module 用 Rust 写，rust-bindgen 需要 libclang
      if os_is_debian; then printf '%s\n' libclang-dev
      else printf '%s\n' clang-devel; fi ;;
    nginx_repo)
      # apt 路线仓库工具（仅 debian 家族会走到）
      printf '%s\n' curl gnupg2 ca-certificates lsb-release debian-archive-keyring ;;
    php)
      if os_is_debian; then printf '%s\n' \
        libxml2-dev libcurl4-openssl-dev libonig-dev libsqlite3-dev \
        libzip-dev libpng-dev libjpeg-dev libfreetype-dev libwebp-dev \
        libargon2-dev libsodium-dev libxslt1-dev
      else printf '%s\n' \
        libxml2-devel libcurl-devel oniguruma-devel sqlite-devel \
        libzip-devel libpng-devel libjpeg-turbo-devel freetype-devel \
        libwebp-devel libargon2-devel libsodium-devel libxslt-devel; fi ;;
    mongodb)
      # mongod 运行时链接 libc/libcrypto/libssl/libcurl；最小化系统里 libcurl 未必有
      if os_is_debian; then printf '%s\n' libcurl4 libssl3
      else printf '%s\n' libcurl openssl; fi ;;
    ocserv)
      # ocserv 1.5+ 用 meson 构建；硬依赖只有 gnutls/nettle/libev，
      # talloc/llhttp/protobuf-c 有内嵌兜底，不必装开发包
      # readline 开发包不是硬依赖，但必须装：1.6.0 的 occtl 在"没有原生 readline"
      # 的分支里把 whitespace() 映射到 gnulib 的 c_isspace，而 meson 构建根本没带
      # gnulib，链接直接 undefined reference to 'c_isspace'（libedit 也算这个分支，
      # 只有 HAVE_ORIG_READLINE=1 才绕开）。装了它 occtl 还能用行编辑。
      if os_is_debian; then printf '%s\n' libgnutls28-dev nettle-dev libev-dev \
        libseccomp-dev meson ninja-build pkg-config libpam0g-dev libreadline-dev
      else printf '%s\n' gnutls-devel nettle-devel libev-devel \
        libseccomp-devel meson ninja-build pam-devel readline-devel; fi ;;
    *) die "未知依赖组：$group" ;;
  esac
}

# install_group <说明> <组名>：把包名表喂给 pkg_install
install_group() {
  local desc="$1" group="$2"
  local -a list=()
  mapfile -t list < <(pkgs_for "$group")
  # 过滤空项
  local -a pkgs=() p
  for p in "${list[@]}"; do [[ -n $p ]] && pkgs+=("$p"); done
  pkg_install "$desc" "${pkgs[@]}"
}

# --- 分组 -------------------------------------------------------------------

# 所有组件都要用的工具链
deps_common() {
  rhel_enable_extra_repos
  install_group "基础编译工具" common
  if os_is_rhel; then
    # pkg-config 各发行版叫法不同；re2c 部分源（如 openEuler）没有，
    # PHP 官方 tarball 自带生成好的 parse.c，缺了也能编译
    pkg_install_any "pkg-config" pkgconf-pkg-config pkgconfig
    pkg_install_any "re2c（可选）" re2c
    pkg_install_any "which（可选）" which
  fi
  # nginx / php-fpm 都以它跑，最小化镜像里不一定存在
  ensure_user www-data
}

deps_nginx() {
  # 单独选装（bare 机器只跑 ./install.sh nginx）时没有编译器，先补 common 工具链；
  # pkg_install 幂等，全量安装时重复调用零开销（与 deps_ocserv 同一处理）
  deps_common
  # apt 路线：只需 apt 仓库所需的密钥/工具，编译依赖由 nginx 包自带
  if [[ ${CFG_nginx_install:-apt} == apt ]] && os_is_debian; then
    install_group "nginx apt 依赖" nginx_repo
    ensure_user www-data
    return 0
  fi
  # src 路线：源码编译依赖
  install_group "nginx 编译依赖" nginx_src
  # ngx_http_acme_module 用 Rust 写，rust-bindgen 需要 libclang
  # 必须写 if：set -e 下「[[ ]] && install_group」在没开 acme 时整行返回 1，会中止函数
  if [[ -n ${CFG_nginx_acme:-} ]]; then
    install_group "nginx-acme 模块编译依赖" nginx_acme
  fi
  ensure_user www-data
}

deps_php() {
  deps_common
  install_group "PHP 编译依赖" php
  ensure_user www-data
}

deps_mongodb() {
  install_group "MongoDB 运行时依赖" mongodb
}

deps_ocserv() {
  # 单独选装 ocserv（bare 机器只跑 ./install.sh ocserv）时没有编译器，
  # 先把 common 工具链补齐；pkg_install 幂等，全量安装时重复调用零开销
  deps_common
  install_group "ocserv 编译依赖" ocserv
  # meson 探测依赖走 pkg-config；单独跑本组时 common 组可能没装过
  os_is_rhel && pkg_install_any "pkg-config" pkgconf-pkg-config pkgconfig
  # certtool：给 ocserv 生成自签服务端证书用（gnutls 工具，装不上会在
  # 75-ocserv.sh 里报明确错误）
  if os_is_debian; then pkg_install_any "certtool（gnutls 工具）" gnutls-bin
  else pkg_install_any "certtool（gnutls 工具）" gnutls-utils; fi
}

# --- 入口 -------------------------------------------------------------------
step_deps() {
  step "安装系统依赖（${PKG}）"
  deps_common
  deps_nginx
  deps_php
  deps_mongodb
  deps_ocserv
  info "  依赖安装完成"
}

# 单独执行本文件时才触发；被 install.sh source 时不会走到这里
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  bootstrap
  case "${1:-all}" in
    all)      step_deps ;;
    common)   deps_common ;;
    nginx)    deps_nginx ;;
    php)      deps_php ;;
    mongodb)  deps_mongodb ;;
    ocserv)   deps_ocserv ;;
    *)        die "用法：$0 [all|common|nginx|php|mongodb|ocserv]" ;;
  esac
fi
