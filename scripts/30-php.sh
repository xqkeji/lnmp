#!/usr/bin/env bash
# ============================================================================
# scripts/30-php.sh - 下载 + 编译安装 PHP（php-fpm）
#
#   fetch_php     只下载源码包
#   install_php   解压 + configure + make + 生成最小可用配置
#   step_php      依赖 + 上面两步
#
# 单独执行：sudo ./scripts/30-php.sh
# ============================================================================

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
source "$LIB_DIR/config.sh"
source "$LIB_DIR/preflight.sh"

# --- 下载 -------------------------------------------------------------------
fetch_php() {
  step "下载 PHP ${CFG_php}"
  fetch "https://www.php.net/distributions/php-${CFG_php}.tar.gz" \
        "$SRC_DIR/php-${CFG_php}.tar.gz" "${CFG_php_sha256:-}"
}

# --- 编译安装 ---------------------------------------------------------------
install_php() {
  step "编译 PHP ${CFG_php}（php-fpm）"

  if [[ "$(installed_version php)" == "${CFG_php}" ]]; then
    info "  已是 ${CFG_php}，跳过"
    return 0
  fi

  local tarball="$SRC_DIR/php-${CFG_php}.tar.gz"
  [[ -s $tarball ]] || fetch_php

  rm -rf "$SRC_DIR/php-${CFG_php}"
  tar -xzf "$tarball" -C "$SRC_DIR"

  (
    cd "$SRC_DIR/php-${CFG_php}"
    ./configure \
      --prefix="$PREFIX_PHP" \
      --with-config-file-path="$PREFIX_PHP/etc" \
      --with-config-file-scan-dir="$PREFIX_PHP/etc/conf.d" \
      --enable-fpm \
      --with-fpm-user=www-data \
      --with-fpm-group=www-data \
      --disable-cgi \
      --enable-gd --with-jpeg --with-freetype --with-webp \
      --with-openssl --with-zlib --with-curl \
      --enable-mbstring --enable-bcmath --enable-sockets \
      --with-mysqli=mysqlnd --with-pdo-mysql=mysqlnd
    # 注意：PHP 8.5 起 opcache 无条件内置编译，不再有 --enable-opcache 开关
    # （写了会得到 "configure: WARNING: unrecognized options"，且什么也不改变）
    # 刻意不加 --with-zip：zip 按要求交给 PIE 装（pecl/zip），
    # 两处同时开会让 zip 模块重复加载，PHP 直接报 "Module 'zip' already loaded"
    make -j"$JOBS"
    make install
  )

  # 生成最小可用配置（已存在则不覆盖，避免吃掉用户改动）
  mkdir -p "$PREFIX_PHP/etc/conf.d"
  [[ -f $PREFIX_PHP/etc/php.ini ]] \
    || cp "$SRC_DIR/php-${CFG_php}/php.ini-production" "$PREFIX_PHP/etc/php.ini"

  if [[ ! -f $PREFIX_PHP/etc/php-fpm.conf ]]; then
    cp "$PREFIX_PHP/etc/php-fpm.conf.default" "$PREFIX_PHP/etc/php-fpm.conf"
    # 默认模板把 pid 注释掉了，systemd 需要真实 pid 文件
    sed -i "s|^;pid = run/php-fpm.pid|pid = /run/php-fpm.pid|" "$PREFIX_PHP/etc/php-fpm.conf"
  fi

  if [[ ! -f $PREFIX_PHP/etc/php-fpm.d/www.conf ]]; then
    cp "$PREFIX_PHP/etc/php-fpm.d/www.conf.default" "$PREFIX_PHP/etc/php-fpm.d/www.conf"
    # 官方模板默认就是 127.0.0.1:9000，这里显式写死防止上游模板变动
    sed -i "s|^listen = .*|listen = 127.0.0.1:${PORT_PHP_FPM}|" "$PREFIX_PHP/etc/php-fpm.d/www.conf"
  fi

  ln -sf "$PREFIX_PHP/bin/php" /usr/local/bin/php
  mark_installed php "${CFG_php}"
  info "  PHP ${CFG_php} 编译安装完成"
}

# --- 入口 -------------------------------------------------------------------
step_php() {
  deps_php
  fetch_php
  install_php
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  bootstrap
  require_ports "$PORT_PHP_FPM"
  require_disk
  step_php
fi
