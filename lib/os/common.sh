#!/usr/bin/env bash
# ============================================================================
# lib/os/common.sh - 系统抽象层里与发行版家族无关的部分
#
# 本文件不写任何具体包名，也不直接调 apt-get / dnf：那些都在 lib/os/debian.sh、
# lib/os/rhel.sh 里。这里只做三件事：探测家族、把契约函数分发给家族实现、
# 提供家族无关的幂等包装（pkg_install / pkg_install_any）。
#
# 家族实现文件必须提供下列契约函数（后缀就是 OS_FAMILY 的值）：
#   pkg_update_<family>                 刷新包索引
#   pkg_installed_<family> <包>          单包是否已装
#   pkg_install_<family> <包...>         真正调包管理器安装
#   pkgs_for_<family> <组名>             该家族的依赖组包名表
#   pkg_enable_extra_repos_<family>      启用 EPEL/CRB 这类额外仓库
#   ca_install_trust_<family> <证书文件> 把自签 CA 装进系统信任（两个家族都要实现）
# 缺哪个就 die，不会静默跳过（静默跳过的后果是编译到一半才发现缺依赖）。
#
# 对外契约（组件脚本只用这些）：
#   detect_os / os_is_debian / os_is_rhel
#   pkg_update_once / pkg_installed / pkg_install / pkg_install_any
#   pkgs_for / pkg_enable_extra_repos / ca_install_trust
# ============================================================================

[[ -n ${_LNMP_LIB_OS_COMMON:-} ]] && return 0
readonly _LNMP_LIB_OS_COMMON=1

# ---------------------------------------------------------------------------
# 探测：OS_ID / OS_FAMILY / OS_MAJOR / OS_CODENAME / OS_PRETTY / PKG
#   debian 家族：Debian、Ubuntu 及 ID_LIKE 含 debian 的衍生版（apt）
#   rhel   家族：RHEL、Rocky、AlmaLinux、CentOS、Fedora、openEuler 等（dnf/yum）
# ---------------------------------------------------------------------------
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

os_is_debian() { [[ ${OS_FAMILY:-} == debian ]]; }
os_is_rhel() { [[ ${OS_FAMILY:-} == rhel ]]; }

# ---------------------------------------------------------------------------
# 契约分发
# ---------------------------------------------------------------------------
__os_dispatch() {  # __os_dispatch <契约名> <参数...>
  local fn="$1_${OS_FAMILY:-unknown}"
  shift
  # 函数名只由"契约名 + detect_os 白名单里的家族名"拼成，不接受外部输入
  declare -F "$fn" >/dev/null \
    || die "未适配的发行版家族：${OS_FAMILY:-未探测}（缺 $fn，请在 lib/os/ 下补该家族实现）"
  "$fn" "$@"
}

pkg_installed() { __os_dispatch pkg_installed "$1"; }
pkgs_for() { __os_dispatch pkgs_for "$1"; }
pkg_enable_extra_repos() { __os_dispatch pkg_enable_extra_repos; }

# ca_install_trust <CA 证书文件>：把自签 CA 装进"本机"信任库，让本机 curl /
# php / openssl verify 认这份证书。只影响服务器自己；访问者的设备要各自导入，
# 那一步在 README 里说明。装不上（缺 ca-certificates / ca-trust 工具）只告警：
# 证书本身照样能用，浏览器点"继续访问"即可，不该因此中断整个 nginx 配置步骤。
ca_install_trust() { __os_dispatch ca_install_trust "$1"; }

# 元数据刷新全流程只做一次：apt 不显式 update 就用旧索引，dnf/yum 的 install
# 自带刷新（所以 rhel 那边的实现是空函数，见 lib/os/rhel.sh）
PKG_UPDATED="${PKG_UPDATED:-0}"
pkg_update_once() {
  ((PKG_UPDATED)) && return 0
  __os_dispatch pkg_update
  PKG_UPDATED=1
}

# 真正调包管理器的安装命令（已被 pkg_install / pkg_install_any 过滤过）
__pkg_run_install() { __os_dispatch pkg_install "$@"; }

# ---------------------------------------------------------------------------
# 家族无关的幂等包装
# ---------------------------------------------------------------------------

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
