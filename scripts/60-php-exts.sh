#!/usr/bin/env bash
# ============================================================================
# scripts/60-php-exts.sh - 用 PIE 安装 PHP 扩展
#
# 装哪些扩展由 config.ini 的 pie_extensions 决定（空格分隔）。
#
# 关于 gd：它是 PHP 核心 bundled 扩展，packagist 上没有 php-ext/gd 包，PIE 装不了，
#          已在 30-php.sh 里用编译期 --enable-gd 打开。
#
# 单独执行：sudo ./scripts/60-php-exts.sh
# ============================================================================

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
source "$LIB_DIR/config.sh"
source "$LIB_DIR/preflight.sh"

# PIE 包名 -> php -m 里的扩展名。两者不是一回事，这个映射只用于幂等判断。
ext_name_of() {
  case "$1" in
    pecl/zip)                  printf 'zip' ;;
    mongodb/mongodb-extension) printf 'mongodb' ;;
    *)                         printf '%s' "${1##*/}" ;;
  esac
}

step_php_exts() {
  step "安装 PHP 扩展（PIE）"

  info "  gd：PHP 核心 bundled 扩展，packagist 上无 php-ext/gd 包，"
  info "      PIE 装不了，已由 30-php.sh 在编译期 --enable-gd 启用"

  composer_env

  local pkg ext_name
  for pkg in ${CFG_pie_extensions:-}; do
    ext_name="$(ext_name_of "$pkg")"

    # 已加载就跳过：PIE 对已安装的扩展会直接报错，重复跑脚本会中断
    if "$PREFIX_PHP/bin/php" -m 2>/dev/null | grep -qix "$ext_name"; then
      info "  $pkg（扩展名 $ext_name）已加载，跳过"
      continue
    fi

    info "  PIE 安装 $pkg"
    # --with-php-config / --with-phpize-path 必须显式给：
    # 系统上可能还有发行版自带的 php，不指定会装到别人家去
    pie install "$pkg" \
      --with-php-config="$PREFIX_PHP/bin/php-config" \
      --with-phpize-path="$PREFIX_PHP/bin/phpize" \
      -j "$JOBS" -n
  done
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  bootstrap
  step_php_exts
fi
