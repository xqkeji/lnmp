#!/usr/bin/env bash
# ============================================================================
# scripts/70-xqkeji.sh - 部署 xqkeji 扩展
#
# 两个反直觉的点，决定了它不能按常规方式装：
#   1. gitee 仓库里只有预编译二进制（xqkeji.so），没有 C 源码
#      -> 没法 phpize 编译，只能把 .so 直接放进 extension_dir
#   2. 它没发布到 packagist
#      -> PIE 也装不了
#
# 因此这里做的是：下载仓库 tarball -> 校验 .so 的 PHP API 版本 -> 部署 + 写 conf.d
#
# 单独执行：sudo ./scripts/70-xqkeji.sh
# ============================================================================

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
source "$LIB_DIR/config.sh"
source "$LIB_DIR/preflight.sh"

# 准备 $SRC_DIR/php-xqkeji-<tag>/ 目录，里面有 xqkeji.so 即成功；失败 die。
# 依次尝试：
#   1) config.ini 的 xqkeji_url（自己的镜像整段 URL）
#   2) gitcode 归档 —— 国内首选。但它的反爬按出口 IP 判：家宽用默认 curl UA 也
#      能 200，云主机段即便带浏览器 UA 仍回 418，所以这条只能排在前面尽力而为，
#      必须留后面的兜底
#   3) GitHub 同名仓库的 tag 归档 + 内置国内代理
#   4) git clone（gitcode / GitHub）——走 smart HTTP，和归档不是同一条通道，
#      被归档 WAF 拦掉的机器一般还能克隆
# 各源的包顶层目录名不一致（gitcode 带 v、GitHub 不带），统一用
# --strip-components=1 抹平；也因此不能跨源 pin 同一个 sha256，故不校验。
fetch_xqkeji() {
  local tag="${CFG_xqkeji}"
  [[ -n $tag ]] || die "config.ini 缺少 xqkeji 版本号"
  step "获取 xqkeji ${tag}"

  local dir="$SRC_DIR/php-xqkeji-${tag}"
  local tarball="$SRC_DIR/php-xqkeji-${tag}.tar.gz"
  if [[ -f "$dir/xqkeji.so" ]]; then
    info "  源码目录已就绪，跳过下载：$dir"
    return 0
  fi

  local -a urls=()
  [[ -n ${CFG_xqkeji_url:-} ]] && urls+=("${CFG_xqkeji_url}")
  urls+=("https://raw.gitcode.com/xqkeji/php-xqkeji/archive/refs/heads/${tag}.tar.gz")

  local rel="xqkeji/php-xqkeji/archive/refs/tags/${tag}.tar.gz"
  local p
  for p in ghproxy.net ghfast.top mirror.ghproxy.com hub.gitmirror.com; do
    urls+=("https://${p}/https://github.com/${rel}")
  done
  urls+=("https://github.com/${rel}")

  local u
  for u in "${urls[@]}"; do
    info "  尝试归档源：$u"
    if fetch "$u" "$tarball" "" soft; then
      rm -rf "$dir"
      mkdir -p "$dir"
      if tar -xzf "$tarball" -C "$dir" --strip-components=1 && [[ -f "$dir/xqkeji.so" ]]; then
        return 0
      fi
      warn "  已下载但包里没有 xqkeji.so，尝试下一个"
    else
      warn "  该源不可用，尝试下一个"
    fi
  done

  local r
  for r in https://gitcode.com/xqkeji/php-xqkeji.git https://github.com/xqkeji/php-xqkeji.git; do
    info "  尝试 git clone：$r"
    rm -rf "$dir"
    if git clone --quiet --depth 1 --branch "$tag" "$r" "$dir" && [[ -f "$dir/xqkeji.so" ]]; then
      return 0
    fi
    warn "  克隆不可用，尝试下一个"
  done

  die "xqkeji ${tag} 归档与 git 克隆全部失败。可选：
  1) 手动下载后放到 $tarball（存在即跳过下载），再重跑 sudo ./install.sh
     gitcode: https://raw.gitcode.com/xqkeji/php-xqkeji/archive/refs/heads/${tag}.tar.gz
     GitHub : https://github.com/xqkeji/php-xqkeji/archive/refs/tags/${tag}.tar.gz
     （浏览器里能正常下，下完传到服务器即可）
  2) 在 config.ini 配 xqkeji_url=<你自己的镜像完整 URL>"
}

install_xqkeji() {
  step "部署 xqkeji 扩展（${CFG_xqkeji}）"

  local tag="${CFG_xqkeji}"
  local php_bin="$PREFIX_PHP/bin/php"
  local ext_dir
  ext_dir="$("$PREFIX_PHP/bin/php-config" --extension-dir)"

  # tag 里的 -phpX.Y 必须和实际装的 PHP 对得上
  local php_mm
  php_mm="$("$php_bin" -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;')"
  if [[ $tag != *"-php${php_mm}" ]]; then
    warn "  tag '$tag' 与已安装 PHP ${php_mm} 不匹配，继续但很可能加载失败"
  fi

  if [[ -f $ext_dir/xqkeji.so && $(installed_version xqkeji) == "$tag" ]]; then
    info "  已是 $tag，跳过"
    return 0
  fi

  # fetch_xqkeji 要么交出带 xqkeji.so 的目录，要么 die
  fetch_xqkeji
  local so="$SRC_DIR/php-xqkeji-${tag}/xqkeji.so"

  # 扩展的 ABI 必须和当前 PHP 一致，否则 PHP 会拒绝加载。
  # 最可靠的判断是"直接让 PHP 试着加载"——比从二进制里 grep 一个 8 位数字准得多
  # （grep 极易命中日期/时间戳等无关串，导致误判不匹配）。
  # 若 ABI 不兼容，PHP 会输出 "Unable to initialize module" + "module API" 这类字样。
  local load_out api_php
  # 取当前 PHP 的 API 号（仅用于提示信息，取不到也不影响安装）。
  # 优先 php-config --phpapi；取不到（某些 8.5 snapshot 的 php-config 对该选项返回非 0）
  # 则回退到 php -i 里的 "PHP API =>" 行。两步都非致命。
  api_php="$("$PREFIX_PHP/bin/php-config" --phpapi 2>/dev/null)" || true
  [[ -n $api_php ]] || api_php="$("$php_bin" -i 2>/dev/null | grep -i 'PHP API' | head -1 | grep -oE '20[0-9]{6}')"
  load_out="$("$php_bin" -n -d "extension=$so" -r 'echo "XQKEJI_OK";' 2>&1)" || true
  if [[ $load_out == *"Unable to initialize module"* || \
        ( $load_out == *"module API"* && $load_out == *"compiled with"* ) ]]; then
    local so_api php_api_compiled
    so_api=$(printf '%s\n' "$load_out" | grep -oE 'Module compiled with module API=[0-9]+' | grep -oE '[0-9]+$')
    php_api_compiled=$(printf '%s\n' "$load_out" | grep -oE 'PHP +compiled with module API=[0-9]+' | grep -oE '[0-9]+$')
    die "xqkeji.so 与当前 PHP 的 ABI 不兼容（.so API=${so_api:-?}  PHP API=${php_api_compiled:-${api_php:-?}}），放弃安装：
$load_out"
  fi
  if [[ $load_out != *"XQKEJI_OK"* ]]; then
    die "xqkeji.so 加载异常，放弃安装：
$load_out"
  fi
  info "  ABI 兼容性校验通过（PHP API ${api_php:-未知} 成功加载 xqkeji.so）"

  install -m 0755 "$so" "$ext_dir/xqkeji.so"

  # 用独立 conf.d 文件启用，比改动主 php.ini 干净
  printf '%s\n' "extension=xqkeji.so" > "$PREFIX_PHP/etc/conf.d/xqkeji.ini"
  mark_installed xqkeji "$tag"

  info "  xqkeji ${tag} 部署完成"
}

step_xqkeji() {
  fetch_xqkeji
  install_xqkeji
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  bootstrap
  step_xqkeji
fi
