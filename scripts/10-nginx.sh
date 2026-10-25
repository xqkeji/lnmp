#!/usr/bin/env bash
# ============================================================================
# scripts/10-nginx.sh - nginx 安装（apt 路线 / 源码路线双支持）
#
# nginx_install=src（默认）：源码编译 + 自行编译 ngx_http_acme_module 动态模块；
#   acme 模块源码默认走 config.ini 的 nginx_acme_url（gitcode 归档），失败自动
#   回退 GitHub 代理/直连，最后兜底 git clone。
# nginx_install=apt：nginx.org 官方 apt 包 + nginx-module-acme 预编译模块，
#   自动尝试国内镜像（TUNA/nyist），无需 Rust、无需 GitHub。
#
# 关键事实：
#   - apt 路线的 acme 模块由 nginx-module-acme 包提供，与同仓库 nginx 版本
#     ABI 100% 匹配，.so 落在 /usr/lib/nginx/modules/。
#   - 两种路线不能混用：动态模块必须与 nginx 同构建；apt 的 .so 无法加载到
#     源码编译的 nginx 上，反之亦然。故切到 apt 时会先把旧的源码 nginx 清理掉。
#
# 拆分的函数：
#   fetch_nginx / fetch_nginx_acme / install_nginx / build_nginx_acme （src 路线）
#   setup_nginx_apt_repo / migrate_source_nginx / install_nginx_apt  （apt 路线）
#   step_nginx   依赖 + 按 nginx_install 选路线
#
# 单独执行：sudo ./scripts/10-nginx.sh
# ============================================================================

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
source "$LIB_DIR/config.sh"
source "$LIB_DIR/preflight.sh"

# ===========================================================================
# apt 路线
# ===========================================================================

# 配置 nginx.org apt 仓库。自动尝试多个 base URL，直到 apt-get update 能拿到
# nginx 包为止：用户指定 > 清华 TUNA > 南阳理工 nyist > 官方源。
# 签名 key 用 nginx.org 官方 key（镜像是同一份包的镜像，key 不变）。
# 仓库路径按发行版分 debian / ubuntu 两套（nginx.org/packages/{debian,ubuntu}）。
setup_nginx_apt_repo() {
  info "  配置 nginx.org apt 仓库（自动尝试国内镜像，失败回退官方源）"

  local keyring=/usr/share/keyrings/nginx-archive-keyring.gpg
  if ! curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor -o "$keyring" 2>/dev/null; then
    curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor -o "$keyring" \
      || die "无法下载 nginx 官方签名 key"
  fi

  local repo_os codename
  [[ -n ${OS_FAMILY:-} ]] || detect_os
  repo_os=debian
  [[ ${OS_ID:-} == ubuntu ]] && repo_os=ubuntu
  codename="${OS_CODENAME:-}"
  [[ -n $codename ]] || { warn "  取不到 VERSION_CODENAME，按 ${repo_os} 默认代号处理"; codename=$([[ $repo_os == ubuntu ]] && echo focal || echo trixie); }

  local -a bases=(
    "${CFG_nginx_apt_repo:-}"
    "https://mirrors.tuna.tsinghua.edu.cn/nginx/${repo_os}"
    "https://mirror4.nyist.edu.cn/nginx/${repo_os}"
    "https://nginx.org/packages/${repo_os}"
  )
  local base list=/etc/apt/sources.list.d/nginx.list ok=0
  for base in "${bases[@]}"; do
    [[ -n $base ]] || continue
    echo "deb [signed-by=$keyring] $base $codename nginx" > "$list"
    # 仓库优先级：若同时存在多个源，优先 nginx.org 官方包
    printf 'Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n' \
      > /etc/apt/preferences.d/99nginx
    info "  尝试仓库：$base"
    if apt-get update -qq >/dev/null 2>&1 && apt-cache show nginx >/dev/null 2>&1; then
      ok=1; info "  仓库可用：$base"; break
    fi
  done
  ((ok)) || die "无法配置可用的 nginx apt 仓库（请检查网络或手动配置 /etc/apt/sources.list.d/nginx.list）"
}

# 迁移：若此前用源码装过 nginx（/usr/local/nginx），先停掉并清理，避免与
# apt 包冲突（两个 nginx 二进制、两个 nginx.service、80 端口争抢）。
migrate_source_nginx() {
  [[ -x $PREFIX_NGINX/sbin/nginx ]] || return 0
  info "  检测到此前源码安装的 nginx（${PREFIX_NGINX}），执行迁移清理"

  systemctl stop nginx 2>/dev/null || "$PREFIX_NGINX/sbin/nginx" -s quit 2>/dev/null || true
  sleep 1

  # 备份旧配置，防丢
  if [[ -d $PREFIX_NGINX/conf ]]; then
    local bak="/usr/local/nginx.conf.bak-$(date +%Y%m%d%H%M%S)"
    cp -a "$PREFIX_NGINX/conf" "$bak" && info "  已备份旧配置到 $bak"
  fi

  # 删掉我们写的 unit，否则会覆盖 apt 包自带的 unit（/etc 优先级高于 /lib）
  if [[ -f /etc/systemd/system/nginx.service ]]; then
    rm -f /etc/systemd/system/nginx.service
    systemctl daemon-reload 2>/dev/null || true
  fi

  rm -rf "$PREFIX_NGINX"
  rm -f "$STATE_DIR/nginx.version" "$STATE_DIR/nginx_acme.version"
  info "  旧源码 nginx 已清理"
}

# 迁移：若此前用系统包管理器装过 nginx（apt 的 /usr/sbin/nginx 或 dnf 的包），
# 切回 src 路线时先清理，避免两个 nginx 二进制 / 两个 unit / 80 端口争抢。
# 仅在 src 路线入口调用。
migrate_apt_nginx() {
  # debian 侧要覆盖元包与风味包（只认 nginx 会漏 nginx-full 直装的情况）；
  # rhel 侧一般是 nginx 包 + nginx-mod-* 模块包
  local -a pkgs=()
  if os_is_debian; then
    pkgs=(nginx nginx-full nginx-light nginx-core nginx-module-acme)
  else
    pkgs=(nginx)
  fi

  local p found=""
  for p in "${pkgs[@]}"; do
    if pkg_installed "$p"; then found="$p"; break; fi
  done
  [[ -n $found ]] || return 0
  info "  检测到此前 ${PKG} 安装的 nginx（${found}），执行迁移清理（切回源码路线）"
  systemctl stop nginx 2>/dev/null || true
  sleep 1
  # 备份发行版配置与站点（防丢）
  if [[ -d /etc/nginx ]]; then
    local bak="/usr/local/nginx.apt-etc.bak-$(date +%Y%m%d%H%M%S)"
    cp -a /etc/nginx "$bak" && info "  已备份 ${PKG} nginx 配置到 $bak"
  fi
  if [[ -d /usr/share/nginx ]]; then
    local bak2="/usr/local/nginx.apt-share.bak-$(date +%Y%m%d%H%M%S)"
    cp -a /usr/share/nginx "$bak2" && info "  已备份 ${PKG} nginx 站点根到 $bak2"
  fi
  case "$PKG" in
    apt) DEBIAN_FRONTEND=noninteractive apt-get remove -y --purge \
           nginx nginx-full nginx-light nginx-core nginx-module-acme 2>/dev/null || true ;;
    dnf | yum) "$PKG" remove -y nginx 'nginx-*' 2>/dev/null || true ;;
  esac
  rm -f /etc/systemd/system/nginx.service /lib/systemd/system/nginx.service
  rm -rf /etc/nginx /usr/share/nginx
  systemctl daemon-reload 2>/dev/null || true
  rm -f "$STATE_DIR/nginx.version" "$STATE_DIR/nginx_acme.version"
  info "  旧 ${PKG} nginx 已清理"
}

install_nginx_apt() {
  step "安装 nginx（apt：nginx.org 官方包 + acme 模块）"

  migrate_source_nginx

  # 已通过 apt 装好且 acme 模块在，则跳过
  if command -v nginx >/dev/null 2>&1 \
     && pkg_installed nginx-module-acme \
     && [[ -f $NGINX_MODULES/ngx_http_acme_module.so ]]; then
    info "  nginx（含 acme 模块）已通过 apt 安装，跳过"
  else
    setup_nginx_apt_repo
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      nginx nginx-module-acme \
      || die "apt 安装 nginx / nginx-module-acme 失败"
  fi

  command -v nginx >/dev/null 2>&1 || die "nginx 未安装成功"
  [[ -f $NGINX_MODULES/ngx_http_acme_module.so ]] || die "nginx-module-acme 未生成 .so"

  local ver; ver="$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  mark_installed nginx "$ver"
  mark_installed nginx_acme "$ver"
  info "  nginx $(nginx -v 2>&1 | sed -n 1p) + acme 模块 就绪"
}

# ===========================================================================
# 源码路线（nginx_install=src）
# ===========================================================================

fetch_nginx() {
  step "下载 nginx ${CFG_nginx}"
  local tarball="$SRC_DIR/nginx-${CFG_nginx}.tar.gz"
  fetch "https://nginx.org/download/nginx-${CFG_nginx}.tar.gz" \
        "$tarball" "${CFG_nginx_sha256:-}"
}

# 目标：让 $SRC_DIR/nginx-acme-<ver>/ 里有一份可编译的源码（就绪与否看 .lnmp-ok 标记，
# 见 lib/common.sh 的 src_ready；不能用"有没有 Cargo.toml"判，截断的包也有它）。
# 候选顺序（tar=下载归档后解压，git=直接克隆），gitcode 有两条互不相干的通道：
#   1) 用户显式完整 URL（nginx_acme_url，默认就是 gitcode 镜像归档）
#   2) 用户配置的镜像前缀
#   3) gitcode 的 git clone——归档的反爬按出口 IP 判（云主机段必 418，带浏览器 UA
#      也没用，"浏览器能下"是因为浏览器不在那台机器上），而 smart HTTP 是另一条路，
#      实测归档 418 的机器克隆照常成功，所以排在所有 GitHub 代理之前
#   4) 内置国内代理镜像（前缀式，任一失效自动跳过）+ 替换式镜像 kgithub
#   5) 直连 GitHub 归档、GitHub 上游克隆
# 各归档源顶层目录名不一致（gitcode 带 v、release 包不带），统一用
# --strip-components=1 抹平；也因此不能跨源 pin 同一个 sha256。
fetch_nginx_acme() {
  local mver="${CFG_nginx_acme:-}"
  [[ -n $mver ]] || { info "  config.ini 未配置 nginx_acme，跳过模块下载"; return 0; }
  step "获取 ngx_http_acme_module ${mver}"

  local dir="$SRC_DIR/nginx-acme-${mver}"
  local tarball="$SRC_DIR/nginx-acme-${mver}.tar.gz"
  if src_ready "$dir" "$mver"; then
    info "  源码目录已就绪，跳过下载：$dir"
    return 0
  fi

  local rel="nginx/nginx-acme/releases/download/v${mver}/nginx-acme-${mver}.tar.gz"
  local -a candidates=()
  if [[ -n ${CFG_nginx_acme_url:-} ]]; then
    candidates+=("tar|${CFG_nginx_acme_url}")
  fi
  if [[ -n ${CFG_nginx_acme_mirror:-} ]]; then
    candidates+=("tar|${CFG_nginx_acme_mirror%/}/${rel}")
  fi
  candidates+=("git|https://gitcode.com/xqkeji/nginx-acme.git")

  # 国内代理镜像（公共服务，可能偶发失效；按经验靠前排更稳的两个）
  local -a proxies=(
    ghproxy.net
    ghfast.top
    mirror.ghproxy.com
    ghproxy.com
    github.akams.cn
    hub.gitmirror.com
  )
  local p
  for p in "${proxies[@]}"; do
    candidates+=("tar|https://${p}/https://github.com/${rel}")
  done
  # 域名替换式镜像 + 直连 GitHub + 上游克隆
  candidates+=("tar|https://kgithub.com/${rel}")
  candidates+=("tar|https://github.com/${rel}")
  candidates+=("git|https://github.com/nginx/nginx-acme.git")

  local c kind spec
  for c in "${candidates[@]}"; do
    kind="${c%%|*}"; spec="${c#*|}"
    case "$kind" in
      tar)
        info "  尝试归档源：$spec"
        if ! fetch "$spec" "$tarball" "${CFG_nginx_acme_sha256:-}" soft; then
          warn "  该源不可用，尝试下一个"
          continue
        fi
        rm -rf "$dir"
        mkdir -p "$dir"
        if ! tar -xzf "$tarball" -C "$dir" --strip-components=1 || [[ ! -f "$dir/Cargo.toml" ]]; then
          warn "  已下载但包里没有 Cargo.toml，尝试下一个"
          continue
        fi
        ;;
      git)
        info "  尝试 git clone：$spec"
        if ! git_clone_at "v${mver}" "$dir" "$spec" || [[ ! -f "$dir/Cargo.toml" ]]; then
          warn "  克隆不可用，尝试下一个"
          continue
        fi
        ;;
    esac
    mark_src_ready "$dir" "$mver"
    return 0
  done

  die "ngx_http_acme_module ${mver} 所有下载源（含归档与 git clone）均失败。
  可手动下载归档并放到：$tarball（放好后重跑即可自动解压使用）
    GitHub: https://github.com/nginx/nginx-acme/releases/download/v${mver}/nginx-acme-${mver}.tar.gz
  或在 config.ini 配置以下任一项（推荐用你自己的镜像整段 URL）：
    nginx_acme_url=https://raw.gitcode.com/xqkeji/nginx-acme/archive/refs/heads/v${mver}.tar.gz
      注意：gitcode 归档的反爬按出口 IP 判，云主机上即使带浏览器 UA 也会 418
      （这种情况下脚本会自动改用 gitcode 的 git clone，同版本号字节一致）
    nginx_acme_mirror=https://ghproxy.net/https://github.com
  配置/放置后重新运行 sudo ./install.sh"
}

# --- nginx ./configure 参数（被 install_nginx 与 build_nginx_acme 共用）--------
# 两处必须完全一致，否则动态模块与已装 nginx 的 ABI 不匹配、load_module 会失败。
# 关键：--with-compat 让编译出的 nginx 能加载动态模块。
nginx_configure_flags() {
  printf '%s ' \
    "--prefix=$PREFIX_NGINX" \
    "--sbin-path=$PREFIX_NGINX/sbin/nginx" \
    "--conf-path=$PREFIX_NGINX/conf/nginx.conf" \
    "--pid-path=/run/nginx.pid" \
    "--error-log-path=/var/log/nginx/error.log" \
    "--http-log-path=/var/log/nginx/access.log" \
    "--user=www-data" "--group=www-data" \
    "--with-http_ssl_module" "--with-http_v2_module" \
    "--with-http_realip_module" "--with-http_gzip_static_module" \
    "--with-http_stub_status_module" \
    "--with-threads" "--with-file-aio" "--with-compat"
}

# --- Rust 工具链（ngx_http_acme_module 是 Rust 写的，需要 >=1.81）-------------
rust_version_ok() {
  local v; v="$(cargo --version 2>/dev/null)" || return 1
  v="${v#cargo }"; v="${v%% *}"                 # "1.85.0"
  local maj="${v%%.*}" rest="${v#*.}"; local min="${rest%%.*}"
  (( maj > 1 || (maj == 1 && min >= 81) ))
}

ensure_rust() {
  # 让上次 rustup 装的 cargo 在本会话可见（sudo 下 HOME=/root，装在 /root/.cargo），
  # 避免重复下载 Rust 工具链
  export PATH="$HOME/.cargo/bin:$PATH"
  if command -v cargo >/dev/null 2>&1 && rust_version_ok; then
    info "  Rust 工具链已满足（>=1.81）"
    return 0
  fi
  info "  安装 Rust 工具链（rustup，ngx_http_acme_module 编译依赖）"

  # 国内镜像：默认 rsproxy.cn，可用 config.ini 的 rust_dist_server / rust_update_root
  # 或环境变量 RUSTUP_DIST_SERVER / RUSTUP_UPDATE_ROOT 覆盖（设为官方源可绕过镜像）
  local dist="${CFG_rust_dist_server:-${RUSTUP_DIST_SERVER:-https://rsproxy.cn}}"
  local upd="${CFG_rust_update_root:-${RUSTUP_UPDATE_ROOT:-https://rsproxy.cn/rustup}}"
  export RUSTUP_DIST_SERVER="$dist"
  export RUSTUP_UPDATE_ROOT="$upd"

  local tmp; tmp="$(mktemp)"
  info "  下载 rustup 安装脚本（镜像：$upd）"
  curl --proto '=https' --tlsv1.2 --connect-timeout 20 --max-time 180 \
       -fSL --progress-bar -o "$tmp" https://sh.rustup.rs \
    || curl --proto '=https' --tlsv1.2 --connect-timeout 20 --max-time 180 \
       -fSL --progress-bar -o "$tmp" "${upd}/rustup-init.sh"
  sh "$tmp" -y --default-toolchain stable --profile minimal
  rm -f "$tmp"

  # 让本进程及后续命令能找到 cargo
  export PATH="$HOME/.cargo/bin:$PATH"
  source "$HOME/.cargo/env" 2>/dev/null || true

  # 模块编译时 cargo 拉 crates.io 依赖也走国内镜像（否则同样很慢）
  if [[ -n ${HOME:-} ]]; then
    local cc="$HOME/.cargo/config.toml"
    if [[ ! -f $cc ]]; then
      mkdir -p "$HOME/.cargo"
      cat > "$cc" <<'EOF'
# lnmp 安装器写入：crates.io 国内镜像（rsproxy.cn）
[source.crates-io]
replace-with = 'rsproxy-sparse'
[source.rsproxy-sparse]
registry = "sparse+https://rsproxy.cn/index/"
[net]
git-fetch-with-cli = true
EOF
      info "  已写入 cargo 国内镜像配置：$cc"
    fi
  fi
}

# --- 编译安装 ---------------------------------------------------------------
install_nginx() {
  step "编译安装 nginx ${CFG_nginx}"

  local need=0
  if [[ "$(installed_version nginx)" != "${CFG_nginx}" ]]; then
    need=1
  fi
  # 已装的 nginx 必须带 --with-compat，否则加载不了动态模块
  if ! "$PREFIX_NGINX/sbin/nginx" -V 2>&1 | grep -q with-compat; then
    need=1
  fi
  if ((need == 0)); then
    info "  已是 ${CFG_nginx}（含 with-compat），跳过"
    return 0
  fi

  local tarball="$SRC_DIR/nginx-${CFG_nginx}.tar.gz"
  fetch_nginx

  rm -rf "$SRC_DIR/nginx-${CFG_nginx}"
  tar -xzf "$tarball" -C "$SRC_DIR"

  (
    cd "$SRC_DIR/nginx-${CFG_nginx}"
    ./configure $(nginx_configure_flags)
    make -j"$JOBS"
    make install
  )

  mkdir -p /var/log/nginx
  mark_installed nginx "${CFG_nginx}"
  info "  nginx ${CFG_nginx} 安装完成"
}

# 编译 ngx_http_acme_module 动态模块（.so），由 nginx.conf load_module 加载。
# 用 --add-dynamic-module 方式编译，产出 objs/ngx_http_acme_module.so，
# 与 install_nginx 完全一致的参数（含 --with-compat）保证 ABI 匹配。
build_nginx_acme() {
  local mver="${CFG_nginx_acme:-}"
  [[ -n $mver ]] || { info "  config.ini 未设 nginx_acme，跳过模块编译"; return 0; }
  step "编译 ngx_http_acme_module 动态模块 ${mver}"

  local so="$PREFIX_NGINX/modules/ngx_http_acme_module.so"
  if [[ "$(installed_version nginx_acme)" == "$mver" \
        && "$(installed_version nginx)" == "${CFG_nginx}" \
        && -f $so ]]; then
    info "  模块已是 ${mver}（匹配 nginx ${CFG_nginx}），跳过"
    return 0
  fi

  ensure_rust
  fetch_nginx_acme

  # 确保 nginx 源码已解压（模块编译依赖其头文件与 objs）
  local ns="$SRC_DIR/nginx-${CFG_nginx}"
  if [[ ! -d $ns ]]; then
    local tb="$SRC_DIR/nginx-${CFG_nginx}.tar.gz"
    fetch_nginx
    rm -rf "$ns"; tar -xzf "$tb" -C "$SRC_DIR"
  fi

  # 源码目录由 fetch_nginx_acme 备好（归档解压或 git clone 都落在这一路径）
  local as="$SRC_DIR/nginx-acme-${mver}"

  (
    cd "$ns"
    # 以与已装 nginx 完全一致的参数重新 configure（含 --with-compat），
    # 再追加 --add-dynamic-module 产出动态模块 .so
    ./configure $(nginx_configure_flags) --add-dynamic-module="$as"
    make modules
  )

  mkdir -p "$PREFIX_NGINX/modules"
  cp -f "$ns/objs/ngx_http_acme_module.so" "$so"
  mark_installed nginx_acme "$mver"
  info "  ngx_http_acme_module ${mver} -> $so"
}

# --- 入口 -------------------------------------------------------------------
step_nginx() {
  # apt 路线（nginx.org 官方包）只发 deb；RHEL/openEuler 系请保持 nginx_install=src
  if [[ ${CFG_nginx_install:-apt} == apt ]] && ! os_is_debian; then
    die "nginx_install=apt 仅支持 Debian/Ubuntu；${OS_PRETTY:-当前系统} 请在 config.ini 设 nginx_install=src（源码编译）"
  fi
  deps_nginx
  if [[ ${CFG_nginx_install:-apt} == apt ]]; then
    install_nginx_apt
  else
    migrate_apt_nginx
    fetch_nginx
    install_nginx
    build_nginx_acme
  fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  bootstrap
  require_ports "$PORT_NGINX"
  require_disk
  step_nginx
fi
