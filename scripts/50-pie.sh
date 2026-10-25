#!/usr/bin/env bash
# ============================================================================
# scripts/50-pie.sh - 安装 PIE（PHP 扩展安装器，phar）
#
# 单独执行：sudo ./scripts/50-pie.sh
# ============================================================================

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
source "$LIB_DIR/config.sh"
source "$LIB_DIR/preflight.sh"

fetch_pie() {
  step "下载 PIE ${CFG_pie}"
  mkdir -p "$PREFIX_PIE"
  fetch "https://github.com/php/pie/releases/download/${CFG_pie}/pie.phar" \
        "$PREFIX_PIE/pie.phar" ""
}

install_pie() {
  step "安装 PIE ${CFG_pie}"

  local phar="$PREFIX_PIE/pie.phar"
  if [[ $(installed_version pie) == "${CFG_pie}" && -x $phar ]]; then
    info "  已是 ${CFG_pie}，跳过"
    return 0
  fi

  fetch_pie

  chmod +x "$phar"
  ln -sf "$phar" /usr/local/bin/pie
  mark_installed pie "${CFG_pie}"
  info "  PIE ${CFG_pie} 安装完成"
}

step_pie() {
  fetch_pie
  install_pie
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  bootstrap
  step_pie
fi
