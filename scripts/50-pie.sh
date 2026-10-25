#!/usr/bin/env bash
# ============================================================================
# scripts/50-pie.sh - 安装 PIE（PHP 扩展安装器，phar）
#
# 单独执行：sudo ./scripts/50-pie.sh
# ============================================================================

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
source "$LIB_DIR/config.sh"
source "$LIB_DIR/preflight.sh"

# PIE 的发布物只在 GitHub release 上，而国内云主机直连 github.com 常是 connect
# timeout（实测过：curl (28) Failed to connect to github.com port 443），所以按
# 候选源回退：国内代理前缀 -> GitHub 直连。代理转发的是同一个 release 资产，
# 但仍不 pin sha256（个别代理会改写响应），由 fetch 的 .part + 完整性判定兜底。
fetch_pie() {
  local ver="${CFG_pie}"
  [[ -n $ver ]] || die "config.ini 缺少 pie 版本号"
  step "下载 PIE ${ver}"
  mkdir -p "$PREFIX_PIE"
  local dest="$PREFIX_PIE/pie.phar"
  local rel="php/pie/releases/download/${ver}/pie.phar"

  local -a urls=()
  local p
  for p in ghproxy.net ghfast.top mirror.ghproxy.com hub.gitmirror.com; do
    urls+=("https://${p}/https://github.com/${rel}")
  done
  urls+=("https://github.com/${rel}")

  local u
  for u in "${urls[@]}"; do
    info "  尝试源：$u"
    if fetch "$u" "$dest" "" soft; then
      return 0
    fi
    warn "  该源不可用，尝试下一个"
  done

  die "PIE ${ver} 所有下载源均失败（含国内代理）。可手动下载后放到：$dest
    https://github.com/${rel}
  然后重新运行 sudo ./install.sh"
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
