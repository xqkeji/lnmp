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
# 顺序按"gitcode 优先"排，关键是 gitcode 有两条互不相干的通道：
#   1) config.ini 的 xqkeji_url（自己的镜像整段 URL）
#   2) gitcode 归档（raw.gitcode.com）——它的反爬按出口 IP 判：家宽用默认 curl UA
#      也能 200，云主机段即便带浏览器 UA 仍回 418；"浏览器能下"是因为浏览器在他自己的
#      电脑上而不是那台服务器上，所以这条只能尽力而为
#   3) gitcode 的 git clone——smart HTTP，不经归档那条 WAF，实测归档 418 的机器上克隆
#      照常成功，拿到的 xqkeji.so 与归档字节一致，所以紧跟归档，排在 GitHub 代理之前
#   4) GitHub 归档 + 内置国内代理 -> GitHub 直连 -> GitHub 克隆（境外或前面全废才走到）
# 各归档源的包顶层目录名不一致（gitcode 带 v、GitHub 不带），统一用
# --strip-components=1 抹平；也因此不能跨源 pin 同一个 sha256，故不校验。
fetch_xqkeji() {
  local tag="${CFG_xqkeji}"
  [[ -n $tag ]] || die "config.ini 缺少 xqkeji 版本号"
  step "获取 xqkeji ${tag}"

  local dir="$SRC_DIR/php-xqkeji-${tag}"
  local tarball="$SRC_DIR/php-xqkeji-${tag}.tar.gz"
  # 就绪判据是自写的 .lnmp-ok 标记，不是"目录里有 xqkeji.so"（见 src_ready）
  if src_ready "$dir" "$tag"; then
    info "  源码目录已就绪，跳过下载：$dir"
    return 0
  fi

  # 候选源统一成 "方式|地址"，tar=下载归档后解压，git=直接克隆
  local rel="xqkeji/php-xqkeji/archive/refs/tags/${tag}.tar.gz"
  local -a candidates=()
  if [[ -n ${CFG_xqkeji_url:-} ]]; then
    candidates+=("tar|${CFG_xqkeji_url}")
  fi
  candidates+=("tar|https://raw.gitcode.com/xqkeji/php-xqkeji/archive/refs/heads/${tag}.tar.gz")
  candidates+=("git|https://gitcode.com/xqkeji/php-xqkeji.git")
  local p
  for p in ghproxy.net ghfast.top mirror.ghproxy.com hub.gitmirror.com; do
    candidates+=("tar|https://${p}/https://github.com/${rel}")
  done
  candidates+=("tar|https://github.com/${rel}")
  candidates+=("git|https://github.com/xqkeji/php-xqkeji.git")

  local c kind spec
  for c in "${candidates[@]}"; do
    kind="${c%%|*}"; spec="${c#*|}"
    case "$kind" in
      tar)
        info "  尝试归档源：$spec"
        if ! fetch "$spec" "$tarball" "" soft; then
          warn "  该源不可用，尝试下一个"
          continue
        fi
        rm -rf "$dir"
        mkdir -p "$dir"
        if ! tar -xzf "$tarball" -C "$dir" --strip-components=1 || [[ ! -f "$dir/xqkeji.so" ]]; then
          warn "  已下载但包里没有 xqkeji.so，尝试下一个"
          continue
        fi
        ;;
      git)
        info "  尝试 git clone：$spec"
        if ! git_clone_at "$tag" "$dir" "$spec" || [[ ! -f "$dir/xqkeji.so" ]]; then
          warn "  克隆不可用，尝试下一个"
          continue
        fi
        ;;
    esac
    mark_src_ready "$dir" "$tag"
    return 0
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

  # 只有旧命名（v1.2.1-php8.5）的 tag 里带 PHP 小版本，可以先粗比对一次；
  # 新命名（v1.2.2）不带，因为那种后缀会让 Composer/Packagist 判成非法版本号。
  # 不带后缀时这里没得比，真正的判定是下面那次"让 PHP 试着加载"。
  local php_mm
  php_mm="$("$php_bin" -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;')"
  if [[ $tag == *-php* && $tag != *"-php${php_mm}" ]]; then
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
  # 优先 php-config --phpapi；但 8.5 的 php-config 根本没这个选项，它会把
  # "Usage: ... [OPTION]" 整段用法打到 stdout 再退 1，所以必须确认取到的是纯数字，
  # 否则回退到 php -i 里的 "PHP API =>" 行。两步都非致命。
  api_php="$("$PREFIX_PHP/bin/php-config" --phpapi 2>/dev/null)" || true
  [[ $api_php =~ ^[0-9]+$ ]] || api_php="$("$php_bin" -i 2>/dev/null | grep -i 'PHP API' | head -1 | grep -oE '20[0-9]{6}')"
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
    # 把文件指纹一起打出来：这段加载失败最常见的成因就是包体被截断
    # （下载源半途断流），只看 PHP 那行报错分辨不出是"包坏了"还是"真不兼容"。
    die "xqkeji.so 加载异常，放弃安装：
${load_out:-  （PHP 没有任何输出，通常是 .so 本身有问题导致进程直接退出）}
  文件：$so
        大小 $(stat -c %s "$so" 2>/dev/null) 字节  sha256 $(sha256sum "$so" 2>/dev/null | awk '{print $1}')
  如果大小和官方仓库里的 xqkeji.so 差很多，就是包被截断了，删掉源码目录重下：
    sudo rm -rf \"$SRC_DIR/php-xqkeji-${tag}\" && sudo ./install.sh xqkeji"
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
