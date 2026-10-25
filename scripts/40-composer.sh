#!/usr/bin/env bash
# ============================================================================
# scripts/40-composer.sh - 安装 Composer（phar）
#
# 单独执行：sudo ./scripts/40-composer.sh
# ============================================================================

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
source "$LIB_DIR/config.sh"
source "$LIB_DIR/preflight.sh"

fetch_composer() {
  step "下载 Composer ${CFG_composer}"
  mkdir -p "$PREFIX_COMPOSER/home"
  fetch "https://getcomposer.org/download/${CFG_composer}/composer.phar" \
        "$PREFIX_COMPOSER/composer.phar" ""
}

install_composer() {
  step "安装 Composer ${CFG_composer}"

  local phar="$PREFIX_COMPOSER/composer.phar"
  if [[ $(installed_version composer) == "${CFG_composer}" && -x $phar ]]; then
    info "  已是 ${CFG_composer}，跳过"
    return 0
  fi

  fetch_composer

  chmod +x "$phar"
  ln -sf "$phar" /usr/local/bin/composer
  composer_env

  if [[ -n ${CFG_composer_mirror:-} ]]; then
    info "  使用 Packagist 镜像：${CFG_composer_mirror}"
    composer config -g repos.packagist composer "$CFG_composer_mirror"
  fi

  mark_installed composer "${CFG_composer}"
  info "  Composer ${CFG_composer} 安装完成"
}

step_composer() {
  fetch_composer
  install_composer
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  bootstrap
  step_composer
fi
