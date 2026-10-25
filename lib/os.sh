#!/usr/bin/env bash
# ============================================================================
# lib/os.sh - 发行版探测 + 包管理器抽象
#
# 全项目只认这里给出的变量，组件脚本不再直接写 apt-get / dnf：
#   OS_ID      os-release 的 ID（debian / ubuntu / rocky / openEuler...）
#   OS_FAMILY  debian | rhel | suse | unknown
#   OS_MAJOR   主版本号（纯数字，取不到为 0）
#   OS_CODENAME  VERSION_CODENAME（Debian 的 trixie、Ubuntu 的 noble 等）
#   OS_PRETTY  PRETTY_NAME，用于日志展示
#   PKG        apt | dnf | yum | unknown
#
# 支持范围：
#   debian 家族：Debian、Ubuntu 及 ID_LIKE 含 debian 的衍生版（apt）
#   rhel   家族：RHEL、Rocky、AlmaLinux、CentOS、Fedora、openEuler 等（dnf/yum）
# ============================================================================

[[ -n ${_LNMP_LIB_OS:-} ]] && return 0
readonly _LNMP_LIB_OS=1

detect_os() {
  [[ -r /etc/os-release ]] || die "无法识别系统（缺 /etc/os-release）"
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_MAJOR="${VERSION_ID%%.*}"
  [[ $OS_MAJOR =~ ^[0-9]+$ ]] || OS_MAJOR=0
  OS_CODENAME="${VERSION_CODENAME:-}"
  OS_PRETTY="${PRETTY_NAME:-$OS_ID}"

  OS_FAMILY=unknown
  case ":${ID_LIKE:-}:" in
    *debian*) OS_FAMILY=debian ;;
    *rhel* | *fedora* | *centos*) OS_FAMILY=rhel ;;
    *suse*) OS_FAMILY=suse ;;
  esac
  # ID_LIKE 缺失时按 ID 兜底；openEuler 通常不带 ID_LIKE
  if [[ $OS_FAMILY == unknown ]]; then
    case "$OS_ID" in
      debian | ubuntu | deepin | linuxmint) OS_FAMILY=debian ;;
      rocky | almalinux | centos | rhel | fedora) OS_FAMILY=rhel ;;
      *)
        case "${OS_ID,,}" in
          *openeuler* | *euleros*) OS_FAMILY=rhel ;;
        esac ;;
    esac
  fi

  case "$OS_FAMILY" in
    debian) PKG=apt ;;
    rhel)
      if command -v dnf >/dev/null 2>&1; then PKG=dnf; else PKG=yum; fi ;;
    *) PKG=unknown ;;
  esac

  # 兼容旧代码里引用 DEBIAN_MAJOR 的地方
  DEBIAN_MAJOR="$OS_MAJOR"
  export OS_ID OS_FAMILY OS_MAJOR OS_CODENAME OS_PRETTY PKG
}

# ---------------------------------------------------------------------------
# 包管理统一入口
# ---------------------------------------------------------------------------

PKG_UPDATED="${PKG_UPDATED:-0}"

# apt 需要显式 update；dnf/yum 的 install 自带元数据刷新，这里只给 apt 做事
pkg_update_once() {
  ((PKG_UPDATED)) && return 0
  case "$PKG" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      info "  apt-get update"
      apt-get update -qq
      ;;
  esac
  PKG_UPDATED=1
}

pkg_installed() {
  local p="$1"
  case "$PKG" in
    apt) dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "install ok installed" ;;
    dnf | yum) rpm -q "$p" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

# 真正调包管理器的安装命令（已被 pkg_install / pkg_install_any 过滤过）
__pkg_run_install() {
  case "$PKG" in
    apt) DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" ;;
    # Rocky/CentOS 的 base 镜像自带 curl-minimal，与 curl 互斥；
    # --allowerasing 让 dnf 自动换包，否则整批安装直接报错
    dnf) dnf install -y --allowerasing "$@" ;;
    yum) yum install -y "$@" ;;
    *) die "未知包管理器（PKG=$PKG），无法安装：$*" ;;
  esac
}

# pkg_install <说明> <包...>：已装的跳过，一个都不缺就不调包管理器
pkg_install() {
  local desc="$1"; shift
  pkg_update_once

  local missing=() p
  for p in "$@"; do
    pkg_installed "$p" || missing+=("$p")
  done

  if ((${#missing[@]} == 0)); then
    info "  ${desc}：已全部安装，跳过"
    return 0
  fi

  info "  ${desc}：安装 ${missing[*]}"
  __pkg_run_install "${missing[@]}"
}

# pkg_install_any <说明> <候选包...>：同一工具在各发行版叫法不同、
# 或某发行版源里根本没有的可选依赖。任一候选已装即跳过；否则逐个尝试，
# 装成一个就返回；全部失败只告警不中止（如 openEuler 无 re2c，
# PHP 官方 tarball 自带生成的 parse.c，缺它不影响编译）。
pkg_install_any() {
  local desc="$1"; shift
  local p
  for p in "$@"; do
    if pkg_installed "$p"; then
      info "  ${desc}：已安装（${p}），跳过"
      return 0
    fi
  done
  pkg_update_once
  local out reasons=""
  for p in "$@"; do
    if out="$(__pkg_run_install "$p" 2>&1)"; then
      info "  ${desc}：已安装 ${p}"
      return 0
    fi
    # 只留报错末尾：dnf/apt 的真话都在最后几行（No match for argument /
    # Cannot download metadata），前面那堆下载进度条只会把重点淹掉
    reasons+="${p} <- $(printf '%s' "$out" | tr '\n\r' '  ' | tail -c 160)"$'\n'
  done
  # 原话只说"源中都不可用"会误导：真实原因可能是源里没这个包，也可能是源不可达、
  # 元数据过期。这几种的处置完全不同，必须把包管理器的报错带出来。
  warn "  ${desc}：候选包全部安装失败（$*），跳过"
  local line
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    warn "    ${line}"
  done <<<"$reasons"
  return 0
}

os_is_debian() { [[ ${OS_FAMILY:-} == debian ]]; }
os_is_rhel() { [[ ${OS_FAMILY:-} == rhel ]]; }

# ---------------------------------------------------------------------------
# rhel 家族的额外仓库：PHP 依赖里 oniguruma / libsodium 等需要 EPEL，
# libargon2 / 部分 devel 包在 CRB（RHEL 上叫 codeready-builder）。
# 幂等：仓库已启用时命令返回非 0 也无碍，失败只告警。
# ---------------------------------------------------------------------------
rhel_enable_extra_repos() {
  os_is_rhel || return 0

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
