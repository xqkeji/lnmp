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
# --with-sodium 的硬前提：configure 用 pkg-config 找 libsodium.pc。
# 探不到就摘掉这个开关——硬写上去 ./configure 会 abort（PKG_CHECK_MODULES 是硬
# 失败），整个 PHP 步骤连带装不上，比少一个扩展严重得多。
php_has_libsodium() {
  local pc
  for pc in pkg-config pkgconf; do
    if command -v "$pc" >/dev/null 2>&1 && "$pc" --exists libsodium 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

install_php() {
  step "编译 PHP ${CFG_php}（php-fpm）"

  local -a cfg=(
    --prefix="$PREFIX_PHP"
    --with-config-file-path="$PREFIX_PHP/etc"
    --with-config-file-scan-dir="$PREFIX_PHP/etc/conf.d"
    --enable-fpm
    --with-fpm-user=www-data
    --with-fpm-group=www-data
    --disable-cgi
    --enable-gd --with-jpeg --with-freetype --with-webp
    --with-openssl --with-zlib --with-curl
    --enable-mbstring --enable-bcmath --enable-sockets
    --with-mysqli=mysqlnd --with-pdo-mysql=mysqlnd
  )
  # 注意：PHP 8.5 起 opcache 无条件内置编译，不再有 --enable-opcache 开关
  # （写了会得到 "configure: WARNING: unrecognized options"，且什么也不改变）
  # 刻意不加 --with-zip：zip 按要求交给 PIE 装（pecl/zip），
  # 两处同时开会让 zip 模块重复加载，PHP 直接报 "Module 'zip' already loaded"
  #
  # sodium 必须显式写：php-src 的 ext/sodium/config.m4 里
  #   PHP_ARG_WITH([sodium], [for sodium support], [帮助文本])
  # 省略了第 4 参（默认值），而 build/php.m4 的 PHP_ARG_WITH 缺省第 4 参时取 "no"。
  # 也就是源码编译默认根本不启用 sodium——光装 libsodium-devel 不会自动带上，
  # 这就是此前编出来的 PHP 没有 sodium 的原因（openssl/zlib 的默认值是 yes，所以它们在）。
  if php_has_libsodium; then
    cfg+=(--with-sodium)
  else
    warn "  未找到 libsodium.pc，本次编译不含 sodium；补上依赖后重跑本脚本即可自动带上："
    if os_is_debian; then
      warn "    apt-get install -y pkg-config libsodium-dev"
    else
      warn "    dnf install -y epel-release && dnf install -y pkgconf-pkg-config libsodium-devel"
    fi
  fi

  # 幂等判断：只比版本会漏掉"改了开关后重跑"——命中"已是 8.5.x，跳过"，
  # 新开关永远进不去。所以把本次要用的 configure 参数指纹一起记下来，
  # 版本相同但指纹不同（或没有指纹，即老版本装的）就重编。
  local cfg_hash cfg_file="$STATE_DIR/php.configure" saved=""
  cfg_hash="$(printf '%s\n' "${cfg[@]}" | sha256sum | cut -d' ' -f1)"

  if [[ "$(installed_version php)" == "${CFG_php}" ]]; then
    saved="$(cat "$cfg_file" 2>/dev/null)" || true
    if [[ $saved == "$cfg_hash" ]]; then
      info "  已是 ${CFG_php} 且编译参数未变，跳过"
      return 0
    fi
    info "  已是 ${CFG_php}，但 configure 参数与上次记录不一致，重新编译"
    rm -f "$STATE_DIR/php.version"
  fi

  local tarball="$SRC_DIR/php-${CFG_php}.tar.gz"
  fetch_php

  rm -rf "$SRC_DIR/php-${CFG_php}"
  tar -xzf "$tarball" -C "$SRC_DIR"

  (
    cd "$SRC_DIR/php-${CFG_php}"
    ./configure "${cfg[@]}"
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
  mkdir -p "$STATE_DIR"
  printf '%s\n' "$cfg_hash" > "$cfg_file"
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
