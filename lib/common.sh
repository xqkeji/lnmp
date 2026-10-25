#!/usr/bin/env bash
# ============================================================================
# lib/common.sh - 公共库：路径常量、日志、下载、幂等状态
#
# 只被 install.sh 与 scripts/*.sh source，不单独执行。
# 目的：常量和工具函数全工程只留一份定义，组件脚本里只写"怎么装"。
# ============================================================================

# 重复 source 时直接返回：本文件全是 readonly 常量，二次执行会报错
[[ -n ${_LNMP_LIB_COMMON:-} ]] && return 0
readonly _LNMP_LIB_COMMON=1

set -Eeuo pipefail

# --- 仓库目录 ---------------------------------------------------------------
# ROOT_DIR  = 本仓库根目录（install.sh 所在处）
# LIB_DIR   = 公共库
# STEPS_DIR = 各组件安装脚本
readonly ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly LIB_DIR="$ROOT_DIR/lib"
readonly STEPS_DIR="$ROOT_DIR/scripts"

# --- 组件安装路径 -----------------------------------------------------------
# 源码路线（nginx_install=src）使用下面的 PREFIX_* 前缀
readonly PREFIX_NGINX="/usr/local/nginx"
readonly PREFIX_MONGODB="/usr/local/mongodb"
readonly PREFIX_PHP="/usr/local/php"
readonly PREFIX_COMPOSER="/usr/local/composer"
readonly PREFIX_PIE="/usr/local/pie"
# ocserv 用 meson 装进 /usr/local 的 sbin/bin（无独立前缀目录）；配置统一放 /etc/ocserv
readonly OCSERV_SYS="/etc/ocserv"

# apt 路线（nginx_install=apt）使用 nginx.org 官方包的标准路径（仅 apt 路线下引用）
readonly NGINX_ETC="/etc/nginx"                # apt 安装后配置目录
readonly NGINX_MODULES="/usr/lib/nginx/modules"  # 官方动态模块 .so 落点
# 当前生效的 nginx 安装方式（config.ini 的 nginx_install，默认 src）
nginx_route() { printf '%s' "${CFG_nginx_install:-apt}"; }

# --- 系统抽象层（detect_os / pkg_install 等） -------------------------------
source "$LIB_DIR/os.sh"

# --- 运行时路径 -------------------------------------------------------------
readonly SRC_DIR="/usr/local/src/lnmp"      # 源码/安装包存放地，保留便于排查
readonly STATE_DIR="/usr/local/lnmp/state"  # 各组件已装版本，用于幂等判断
readonly LOG_FILE="/var/log/lnmp-install.log"
readonly CONFIG_NAME="config.ini"           # 版本配置（兼容旧名 lnmp.ini）

# --- 端口 -------------------------------------------------------------------
readonly PORT_NGINX=80
readonly PORT_PHP_FPM=9000
readonly PORT_MONGODB=27017

# 并行编译线程数；config.ini 里的 jobs 会覆盖它
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 2)}"

# ---------------------------------------------------------------------------
# 日志
# ---------------------------------------------------------------------------
# 日志统一走 stderr：避免被 $(...) 命令替换误捕获（曾导致 mongod_distro 的
# warn 行污染下载 URL）。tee 仍把日志写入 LOG_FILE。
_log() { printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$2" | tee -a "$LOG_FILE" >&2; }
info() { _log "INFO " "$*"; }
warn() { _log "WARN " "$*"; }
step() { _log "STEP " "$*"; }
die()  { _log "FATAL" "$*"; exit 1; }

on_err() {
  local rc=$?
  _log "FATAL" "第 ${1:-?} 行执行失败（退出码 ${rc}），完整日志：${LOG_FILE}"
  exit "$rc"
}
trap 'on_err $LINENO' ERR

init_log() {
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"
  chmod 0600 "$LOG_FILE"
}

# ---------------------------------------------------------------------------
# 小工具
# ---------------------------------------------------------------------------
trim() { local s="$*"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"; }

# 系统用户不存在就建一个
ensure_user() {
  local u="$1"
  id -u "$u" >/dev/null 2>&1 \
    || useradd --system --no-create-home --shell /usr/sbin/nologin "$u"
}

# 端口是否被占用：有 ss 用 ss，没有就退回到 /proc/net/tcp 的十六进制匹配
port_busy() {
  if command -v ss >/dev/null 2>&1; then
    ss -H -ltn "sport = :$1" 2>/dev/null | grep -q . && return 0
    return 1
  fi
  local hex; hex=$(printf '%04X' "$1")
  grep -qi ":${hex} .*0A " /proc/net/tcp /proc/net/tcp6 2>/dev/null && return 0
  return 1
}

# 返回监听在指定端口上的进程名（comm），空闲则输出空。需要 root（ss -p）。
port_owner() {
  local p="$1" owner=""
  if command -v ss >/dev/null 2>&1; then
    owner=$(ss -H -ltnp "sport = :${p}" 2>/dev/null \
            | sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | head -1)
  fi
  printf '%s' "$owner"
}

# 该端口是否被本套装自身服务占用（nginx / php-fpm / mongod）
port_owned_by_us() {
  local owner; owner="$(port_owner "$1")"
  [[ -z $owner ]] && return 1
  case "$owner" in
    nginx | php-fpm | php-fpm* | mongod | ocserv-main) return 0 ;;
    *) return 1 ;;
  esac
}

# 已安装版本：没装过返回空串。installed_version <组件名>
installed_version() {
  local f="$STATE_DIR/$1.version"
  [[ -f $f ]] && cat "$f" || printf ''
}

# mark_installed <组件名> <版本>
mark_installed() {
  mkdir -p "$STATE_DIR"
  printf '%s\n' "$2" > "$STATE_DIR/$1.version"
}

# 归档完整性检查：sha256 没 pin 时（多源回退各源字节不同，故意不 pin），
# 半途断流的残包在下一个源会被"已存在且校验通过"当成有效包，直到 tar 才炸。
# 这里按扩展名做一次解压级校验——只信"能完整解开"的包。非归档扩展直接放过。
archive_ok() {
  local f="$1"
  [[ -s $f ]] || return 1
  case "$f" in
    *.tar.gz|*.tgz)   gzip -t "$f" ;;
    *.tar.xz|*.txz)   xz -t "$f" ;;
    *.tar.bz2|*.tbz2) bzip2 -t "$f" ;;
    *)                return 0 ;;
  esac
}

# 下载（断点续传 + 可选 sha256 + 归档完整性）。fetch <url> <dest> [sha256] [soft]
# soft 非空时：下载/校验失败返回 1 而非 die（供多源回退调用方使用）
#
# 只在全部校验通过后才把文件落成 $dest：下载先进 $dest.part，成功后 mv 过去。
# 因此 $dest 一旦存在就一定是完整可用的包，$part 才是可以继续续传的半成品。
#
# UA 用浏览器串而非默认 curl/x.x：部分站点（含 gitcode）的 WAF 会看 UA。
# 但实测 gitcode 归档的 418 主要按出口 IP 判——家宽用默认 curl UA 也 200，
# 云主机段换了浏览器 UA 仍 418，所以这个头只能算"尽力而为"，真正兜底在
# scripts/70-xqkeji.sh 的 git clone 回退。
# 需要临时改回：FETCH_UA=curl/8.0 ./install.sh
readonly FETCH_UA="${FETCH_UA:-Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36}"

fetch() {
  local url="$1" dest="$2" want="${3:-}" soft="${4:-}"
  mkdir -p "$(dirname "$dest")"
  local part="$dest.part"

  # $dest 已存在但未通过校验 = 上次留下的残包/错误页，删掉重来，绝不复用
  if [[ -s $dest ]] && verify_file "$dest" "$want" && archive_ok "$dest"; then
    info "  已存在且校验通过，跳过下载：$(basename "$dest")"
    return 0
  fi
  if [[ -s $dest ]]; then
    warn "  已有包未通过校验（残包或错误页），丢弃后重下：$(basename "$dest")"
    rm -f "$dest"
  fi

  # 续传只对同一个 URL 有意义：多源回退时 $part 可能来自别的镜像，
  # 拼上去必然得到"能下载但解不开"的混合包，所以用 $part.url 记住来源
  if [[ -e $part ]] && [[ "$(cat "$part.url" 2>/dev/null)" != "$url" ]]; then
    warn "  丢弃来自其它源的半成品：$(basename "$part")"
    rm -f "$part"
  fi

  info "  下载 $(basename "$dest")"
  info "    <- $url"
  printf '%s' "$url" > "$part.url"
  local i ok=0
  for ((i = 1; i <= 3; i++)); do
    if curl -fL --retry 3 --retry-delay 3 --connect-timeout 20 \
         -A "$FETCH_UA" -H 'Accept: */*' -C - -o "$part" "$url"; then
      ok=1; break
    fi
    warn "  第 $i 次下载失败"
  done

  # 失败清理：换源或重跑都从干净状态开始（残包留在盘上只会误导下一次）
  if (( ! ok )); then
    rm -f "$part" "$part.url"
    [[ $soft == soft ]] && return 1
    die "下载失败（已重试 3 次）：$url"
  fi

  # 防代理/服务端返回 HTML 错误页被当成成功（gzip/tar 首字节必为二进制，不可能以 '<' 开头）
  if [[ "$(head -c 1 "$part" 2>/dev/null)" == '<' ]]; then
    warn "  下载到的不是压缩包（疑似代理/服务端错误页），视为失败"
    rm -f "$part" "$part.url"
    [[ $soft == soft ]] && return 1
    die "下载内容异常（非压缩包）：$url"
  fi

  if ! verify_file "$part" "$want" || ! archive_ok "$part"; then
    warn "  包体不完整或校验不符，丢弃：$(basename "$part")"
    rm -f "$part" "$part.url"
    [[ $soft == soft ]] && return 1
    die "下载内容不可用（sha256 或归档完整性不通过）：$(basename "$dest")"
  fi

  mv -f "$part" "$dest"
  rm -f "$part.url"
  info "  校验通过"
}

# Composer / PIE 的运行环境：独立 HOME，避免污染安装目录
composer_env() {
  export COMPOSER_HOME="$PREFIX_COMPOSER/home"
  export COMPOSER_ALLOW_SUPERUSER=1
}

# verify_file <file> [sha256]；没给期望值就跳过
verify_file() {
  local f="$1" want="${2:-}"
  [[ -n $want ]] || return 0
  [[ -f $f ]] || return 1
  local got
  got=$(sha256sum "$f" | awk '{print $1}')
  [[ $got == "$want" ]] || { warn "sha256 不符：期望 $want 实际 $got"; return 1; }
}
