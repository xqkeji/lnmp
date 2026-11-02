#!/usr/bin/env bash
# ============================================================================
# lib/os/rhel.sh - RHEL / Rocky / AlmaLinux / CentOS / Fedora / openEuler 家族
#                  （dnf / yum）实现
#
# 契约函数的 rhel 侧实现，由 lib/os/common.sh 按 OS_FAMILY=rhel 分发进来。
# 新增依赖组时，记得同时改 lib/os/debian.sh 的组名，两边组名必须一一对应。
# ============================================================================

[[ -n ${_LNMP_LIB_OS_RHEL:-} ]] && return 0
readonly _LNMP_LIB_OS_RHEL=1

# dnf/yum 的 install 自带元数据刷新，没有 apt 那种"不 update 就用旧索引"的问题，
# 所以本家族不需要 update 动作；真装不上时 pkg_install_any 会把包管理器的
# 原始报错打出来，够用。
pkg_update_rhel() { return 0; }

pkg_installed_rhel() { rpm -q "$1" >/dev/null 2>&1; }

# Rocky/CentOS 的 base 镜像自带 curl-minimal，与 curl 互斥；
# --allowerasing 让 dnf 自动换包，否则整批安装直接报错。
# yum（CentOS 7 / openEuler 老版）没有这个选项，也不会有 curl-minimal 冲突。
pkg_install_rhel() {
  case "$PKG" in
    dnf) dnf install -y --allowerasing "$@" ;;
    yum) yum install -y "$@" ;;
    *) die "未知包管理器（PKG=$PKG），无法安装：$*" ;;
  esac
}

# ---------------------------------------------------------------------------
# 额外仓库：PHP 依赖里 oniguruma / libsodium 等需要 EPEL，
# libargon2 / 部分 devel 包在 CRB（RHEL 上叫 codeready-builder）。
# 幂等：仓库已启用时命令返回非 0 也无碍，失败只告警。
# ---------------------------------------------------------------------------
pkg_enable_extra_repos_rhel() {
  if command -v rpm >/dev/null 2>&1 && ! rpm -q epel-release >/dev/null 2>&1; then
    info "  启用 EPEL 仓库（oniguruma / libsodium 等来自 EPEL）"
    "$PKG" install -y epel-release \
      || { warn "  epel-release 安装失败（openEuler 等无 EPEL 的发行版属正常），继续"; \
           # openEuler 自带源里有 oniguruma/libsodium，失败不致命
           true; }
  fi

  if [[ $PKG == dnf && $OS_MAJOR -ge 9 ]] && \
     command -v dnf >/dev/null 2>&1 && \
     ! dnf repolist enabled 2>/dev/null | grep -qiE '\b(crb|codeready-builder)\b'; then
    info "  启用 CRB/codeready-builder 仓库（部分 -devel 包在此）"
    if grep -qi 'red hat enterprise' /etc/os-release 2>/dev/null; then
      dnf config-manager --set-enabled codeready-builder-for-rhel-"$OS_MAJOR"-x86_64-rpms >/dev/null 2>&1 || true
    else
      dnf config-manager --set-enabled crb >/dev/null 2>&1 || \
        dnf -y --enablerepo=crb install >/dev/null 2>&1 || true
    fi
  fi
}

# --- 依赖组包名表（rhel 家族）-----------------------------------------------
# 每组"为什么要装"的说明放在 scripts/00-deps.sh 的对应 deps_* 函数里，
# 那份理由两个家族通用，这里只记包名。
pkgs_for_rhel() {
  case "$1" in
    common)
      # re2c / pkg-config 在本家族有叫法差异且非硬依赖，由 deps_common 用
      # pkg_install_any 单独处理，不进本表
      printf '%s\n' \
        gcc gcc-c++ make autoconf automake libtool bison unzip xz procps-ng \
        git curl wget ca-certificates tar gzip findutils iproute ;;
    nginx_src)
      printf '%s\n' pcre2-devel zlib-devel openssl-devel ;;
    nginx_acme)
      printf '%s\n' clang-devel ;;
    nginx_repo)
      # apt 路线专用组（装 apt 仓库密钥工具），本家族永远不该问到
      die "依赖组 nginx_repo 仅适用于 debian 家族（apt 路线）" ;;
    php)
      # oniguruma 在 RHEL 系来自 EPEL，靠 pkg_enable_extra_repos_rhel 先启用
      printf '%s\n' \
        libxml2-devel libcurl-devel oniguruma-devel sqlite-devel \
        libzip-devel libpng-devel libjpeg-turbo-devel freetype-devel \
        libwebp-devel libargon2-devel libsodium-devel libxslt-devel \
        openssl-devel zlib-devel ;;
    mongodb)
      printf '%s\n' libcurl openssl ;;
    ocserv)
      printf '%s\n' gnutls-devel nettle-devel libev-devel \
        libseccomp-devel meson ninja-build pam-devel readline-devel ;;
    *) die "未知依赖组：$1" ;;
  esac
}
