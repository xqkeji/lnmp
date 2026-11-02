#!/usr/bin/env bash
# ============================================================================
# scripts/00-deps.sh - 系统依赖：装哪一组、为什么装
#
# 包名清单不在这里。每个家族的表在 lib/os/debian.sh / lib/os/rhel.sh 的
# pkgs_for_<family> 里，本文件通过 pkgs_for <组名> 拿到当前家族的那一份：
#   common / nginx_src / nginx_acme / nginx_repo / php / mongodb / ocserv
# 新增依赖组 = 两个家族表各加一个 case 分支（组名必须一一对应），
# "为什么装"的理由写在这里对应的 deps_* 函数——那份理由两个家族通用。
#
# 装法：deps_common 编译工具链（gcc/build-essential/git/curl...）
#       deps_nginx   nginx 编译依赖
#       deps_php     PHP 编译依赖
#       deps_mongodb mongod 运行时依赖
#       deps_ocserv  ocserv 编译依赖
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

# install_group <说明> <组名>：把当前家族的包名表喂给 pkg_install
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
  # unzip：PIE 内部用 composer 下载 zip 格式的扩展包，php 没编 zip 扩展前
  # 必须有 unzip/7z 兜底（Debian 官方镜像预装了，最小化 Rocky/openEuler 没有）
  # xz：ocserv 官方源码包是 tar.xz，最小化镜像里没有 xz 工具
  # procps：lib/service.sh 的 pgrep 状态兜底依赖它（rocky:9 最小镜像不带）
  # iproute：lib/common.sh 的 port_owner 靠 ss -p 认端口归属，最小镜像不带 ss
  # 时 port_owned_by_us 永远返回"不是我家的"，第二次重跑 install.sh 会在
  # preflight 直接 die「端口 27017 已被其它进程占用」
  pkg_enable_extra_repos
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
  # openssl/zlib 必须在 php 组里：30-php.sh 的 --with-openssl --with-zlib 是硬要求。
  # 以前全量安装能过，只是因为步骤顺序上 deps_nginx 的 nginx_src 组先把这两个
  # 包装上了；单独跑 ./scripts/00-deps.sh php + ./install.sh php（README 里写着
  # 的用法）时它们不在，./configure 直接报错。
  deps_common
  install_group "PHP 编译依赖" php
  ensure_user www-data
}

deps_mongodb() {
  # mongod 运行时链接 libc/libcrypto/libssl/libcurl；最小化系统里 libcurl 未必有
  install_group "MongoDB 运行时依赖" mongodb
}

deps_ocserv() {
  # ocserv 1.5+ 用 meson 构建；硬依赖只有 gnutls/nettle/libev，
  # talloc/llhttp/protobuf-c 有内嵌兜底，不必装开发包
  # readline 开发包不是硬依赖，但必须装：1.6.0 的 occtl 在"没有原生 readline"
  # 的分支里把 whitespace() 映射到 gnulib 的 c_isspace，而 meson 构建根本没带
  # gnulib，链接直接 undefined reference to 'c_isspace'（libedit 也算这个分支，
  # 只有 HAVE_ORIG_READLINE=1 才绕开）。装了它 occtl 还能用行编辑。
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
