#!/usr/bin/env bash
# ============================================================================
# scripts/75-ocserv.sh - ocserv（OpenConnect / Cisco AnyConnect SSL VPN 服务端）
#
#   fetch_ocserv        官网源码包下载（ftp.infradead.org，1.5 起仅发布 meson 源码包）
#   install_ocserv      meson 编译安装到 /usr/local/{sbin,bin}
#   config_ocserv       生成 /etc/ocserv/ocserv.conf + 自签证书 + PAM 无关的
#                       plain[passwd] 账号文件；开 IPv4 转发；firewalld 放行+伪装
#   ocserv_create_user  创建首个 VPN 账号：交互式直接走 ocpasswd 原生输密；
#                       非交互用 config.ini 的 ocserv_user/ocserv_pass；都没有则跳过
#   step_ocserv         依赖 + 以上全部 + systemd 单元 + 启动
#
# 监听端口 / 客户端网段 / 下发 DNS 全部来自 config.ini（ocserv_* 键）。
#
# 单独执行：sudo ./scripts/75-ocserv.sh
# ============================================================================

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
source "$LIB_DIR/config.sh"
source "$LIB_DIR/preflight.sh"
source "$LIB_DIR/service.sh"

readonly OCSERV_BIN_PATH="/usr/local/sbin/ocserv"
readonly OCSERV_PASSWD="$OCSERV_SYS/ocpasswd"

# --- 下载 -------------------------------------------------------------------
fetch_ocserv() {
  step "下载 ocserv ${CFG_ocserv}"
  # 官网只走 FTP 协议（ftp.infradead.org 的 https 目录是 403）；
  # 内网/墙内机器可用 config.ini 的 ocserv_url 覆盖为镜像站完整 URL
  local url="${CFG_ocserv_url:-ftp://ftp.infradead.org/pub/ocserv/ocserv-${CFG_ocserv}.tar.xz}"
  fetch "$url" "$SRC_DIR/ocserv-${CFG_ocserv}.tar.xz" "${CFG_ocserv_sha256:-}"
}

# --- 编译安装 ---------------------------------------------------------------
install_ocserv() {
  step "编译安装 ocserv ${CFG_ocserv}"

  if [[ "$(installed_version ocserv)" == "${CFG_ocserv}" && -x $OCSERV_BIN_PATH ]]; then
    info "  已是 ${CFG_ocserv}，跳过编译"
    return 0
  fi

  local tarball="$SRC_DIR/ocserv-${CFG_ocserv}.tar.xz"
  [[ -s $tarball ]] || fetch_ocserv
  need_cmd xz

  rm -rf "$SRC_DIR/ocserv-${CFG_ocserv}"
  tar -xJf "$tarball" -C "$SRC_DIR"

  # 1.5.0 起官方包只有 meson 构建（无 configure 脚本）；meson 后端固定是 ninja
  (
    cd "$SRC_DIR/ocserv-${CFG_ocserv}"
    # --prefix=/usr/local -> 二进制落在 /usr/local/sbin/ocserv、
    # ocpasswd/occtl 落在 /usr/local/bin；pam/systemd 探测到就启用（feature=auto）
    meson setup build --prefix=/usr/local --buildtype=release
    ninja -C build -j "$JOBS"
    ninja -C build install
  )

  [[ -x $OCSERV_BIN_PATH ]] || die "编译完成但未找到 $OCSERV_BIN_PATH，请检查 meson 安装日志"
  ln -sf "$OCSERV_BIN_PATH" /usr/local/bin/ocserv
  mark_installed ocserv "${CFG_ocserv}"
  info "  ocserv ${CFG_ocserv} 编译安装完成：$("$OCSERV_BIN_PATH" --version 2>&1 | head -1)"
}

# --- 自签服务端证书 ----------------------------------------------------------
# AnyConnect 客户端连自签证书会提示指纹确认（属预期）；要消除告警就把自己
# CA 签的证书替换到 server-cert / server-key 指向的路径。已存在则不覆盖。
gen_ocserv_cert() {
  local cert="$OCSERV_SYS/server-cert.pem" key="$OCSERV_SYS/server-key.pem"
  [[ -s $cert && -s $key ]] && { info "  服务端证书已存在，不覆盖"; return 0; }
  command -v certtool >/dev/null 2>&1 \
    || die "缺少 certtool（gnutls 工具），无法生成服务端证书：先跑 ./scripts/00-deps.sh ocserv"

  # CN 取 acme_domains 第一个域名，没有就用主机名
  local cn="${CFG_acme_domains:-}"
  cn="${cn%% *}"; cn="${cn:-$(hostname -f 2>/dev/null || hostname)}"

  (
    cd "$OCSERV_SYS"
    certtool --generate-privkey --outfile server-key.pem --bits 2048
    cat > cert.info <<EOF
cn = ${cn}
expiration_days = 3650
signing_key
encryption_key
tls_www_server
EOF
    certtool --generate-self-signed --load-privkey server-key.pem \
             --template cert.info --outfile server-cert.pem
    rm -f cert.info
  )
  chmod 600 "$key"
  info "  已生成自签服务端证书（CN=${cn}，10 年有效）"
}

# --- 主配置 -----------------------------------------------------------------
config_ocserv() {
  step "生成 ocserv 配置"
  mkdir -p "$OCSERV_SYS"
  touch "$OCSERV_PASSWD"
  chmod 640 "$OCSERV_PASSWD"

  local conf="$OCSERV_SYS/ocserv.conf"
  if [[ -f $conf ]]; then
    warn "  $conf 已存在，不覆盖（想按 config.ini 重新生成请先删除该文件）"
    return 0
  fi

  local port="${CFG_ocserv_port:-4443}"
  local net="${CFG_ocserv_network:-10.10.10.0}"
  local mask="${CFG_ocserv_netmask:-255.255.255.0}"
  local dns="${CFG_ocserv_dns:-119.29.29.29 223.5.5.5}"
  local d

  cat > "$conf" <<EOF
# 由 lnmp 安装器生成（ocserv ${CFG_ocserv}）
# 参数改 config.ini 的 ocserv_*；改了已生成的本文件不会被覆盖
auth = "plain[passwd=${OCSERV_PASSWD}]"

# 监听端口（config.ini: ocserv_port）
tcp-port = ${port}
udp-port = ${port}

socket-file = /run/ocserv-socket
pid-file = /run/ocserv.pid
use-occtl = true
device = vpns

server-cert = ${OCSERV_SYS}/server-cert.pem
server-key = ${OCSERV_SYS}/server-key.pem

max-clients = 128
max-same-clients = 5
isolate-workers = true
keepalive = 32400
dpd = 90
mobile-dpd = 1800
switch-to-tcp-timeout = 25
auth-timeout = 240
cookie-timeout = 300
rekey-time = 172800
rekey-method = ssl
tls-priorities = "NORMAL:%SERVER_PRECEDENCE:%COMPAT:-VERS-SSL3.0"

# 客户端地址段（config.ini: ocserv_network / ocserv_netmask）
ipv4-network = ${net}
ipv4-netmask = ${mask}
predictable-ips = true

# 客户端 DNS（config.ini: ocserv_dns）
EOF
  for d in $dns; do printf 'dns = %s\n' "$d" >> "$conf"; done

  cat >> "$conf" <<EOF

cisco-client-compat = true
client-bypass-protocol = false
EOF
  info "  已生成 $conf（端口 ${port}，地址段 ${net}/${mask}，DNS：${dns}）"
}

# --- 内核转发 + 防火墙 --------------------------------------------------------
# VPN 客户端要出公网必须有 ip_forward + MASQUERADE；firewalld 在跑就顺手配好，
# 否则只开转发并打印对应命令（iptables/nft 机型差异大，不乱动）。
setup_ocserv_forward() {
  if [[ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" != 1 ]]; then
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || warn "  ip_forward 设置失败（容器里常见），客户端出网需宿主机开启"
  fi
  if [[ -w /etc/sysctl.d || -d /etc/sysctl.d ]] && mkdir -p /etc/sysctl.d 2>/dev/null; then
    grep -q '^net.ipv4.ip_forward' /etc/sysctl.d/99-ocserv.conf 2>/dev/null \
      || printf 'net.ipv4.ip_forward = 1\n' > /etc/sysctl.d/99-ocserv.conf
  fi

  local port="${CFG_ocserv_port:-4443}"
  if have_systemd && command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${port}/tcp" --add-port="${port}/udp" \
      --add-masquerade >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    info "  firewalld：已放行 ${port}/tcp+udp 并开启 MASQUERADE"
  else
    info "  未检测到运行中的 firewalld。客户端出网请确认 NAT 伪装，例如 iptables："
    info "    iptables -t nat -A POSTROUTING -s ${CFG_ocserv_network:-10.10.10.0}/24 -o <外网网卡> -j MASQUERADE"
  fi
}

# --- 账号 -------------------------------------------------------------------
# 优先级：config.ini 给了 ocserv_user(+pass) -> 非交互直写；
#         终端交互 -> 用户名回显确认 + ocpasswd 原生输密；都没有 -> 跳过并提示。
ocserv_create_user() {
  local user="${CFG_ocserv_user:-}" pass="${CFG_ocserv_pass:-}"

  if [[ -z $user ]] && [[ -t 0 ]]; then
    info "  （可留空跳过，之后随时用 ocpasswd 添加账号）"
    read -rp "  请输入 ocserv VPN 账号用户名: " user || user=""
  fi

  if [[ -z $user ]]; then
    warn "  未创建初始账号。手动添加：ocpasswd -c ${OCSERV_PASSWD} <用户名>"
    return 0
  fi

  local ocpasswd_bin
  ocpasswd_bin="$(command -v ocpasswd || printf /usr/local/bin/ocpasswd)"

  if [[ -z $pass ]] && [[ -t 0 ]]; then
    # 让官方 ocpasswd 自己提示两次密码： crypt 加密落盘，明文不进 shell/history
    "$ocpasswd_bin" -c "$OCSERV_PASSWD" "$user"
    info "  账号 ${user} 已创建"
    return 0
  fi

  [[ -n $pass ]] || die "非交互模式下必须同时提供 ocserv_user 和 ocserv_pass（或在 config.ini 留空跳过）"
  # 非交互：openssl 做 crypt(6) 后直接写 ocpasswd 文件（格式 user:group:hash）
  need_cmd openssl
  local hash
  hash="$(openssl passwd -6 "$pass")"
  local tmp="$OCSERV_PASSWD.tmp"
  { [[ -f $OCSERV_PASSWD ]] && grep -v "^${user}:" "$OCSERV_PASSWD" || true; \
    printf '%s::%s\n' "$user" "$hash"; } > "$tmp"
  mv "$tmp" "$OCSERV_PASSWD"
  chmod 640 "$OCSERV_PASSWD"
  info "  账号 ${user} 已创建（非交互模式）"
}

# --- systemd 单元 -------------------------------------------------------------
ocserv_unit() {
  have_systemd || { warn "  无 systemd，跳过单元文件（容器里用 ctrl.sh ocserv 管理）"; return 0; }
  cat > /etc/systemd/system/ocserv.service <<EOF
[Unit]
Description=LNMP ocserv SSL VPN
After=network-online.target

[Service]
Type=simple
PIDFile=/run/ocserv.pid
ExecStart=${OCSERV_BIN_PATH} --foreground --pid-file /run/ocserv.pid --config ${OCSERV_SYS}/ocserv.conf
ExecReload=/bin/kill -HUP \$MAINPID

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload 2>/dev/null || true
  info "  已生成 /etc/systemd/system/ocserv.service"
}

# --- 入口 -------------------------------------------------------------------
step_ocserv() {
  step "安装 ocserv SSL VPN（端口 ${CFG_ocserv_port:-4443}）"
  deps_ocserv
  install_ocserv
  config_ocserv
  gen_ocserv_cert
  setup_ocserv_forward
  ocserv_create_user
  ocserv_unit
  enable_boot_services

  # 起服务：失败只告警不阻断安装（如容器缺 tun 设备、证书问题）
  local port="${CFG_ocserv_port:-4443}"
  if port_busy "$port" && ! port_owned_by_us "$port"; then
    warn "  端口 ${port} 已被其它进程占用，ocserv 未启动（改 config.ini 的 ocserv_port 后重跑）"
    return 0
  fi
  if svc_restart ocserv 2>/dev/null || svc_start ocserv 2>/dev/null; then
    info "  ocserv 已运行，客户端连 https://<服务器IP>:${port}/ 即可（AnyConnect/OpenConnect）"
  else
    warn "  ocserv 启动失败。排查：journalctl -xeu ocserv 或 ${OCSERV_BIN_PATH} -c ${OCSERV_SYS}/ocserv.conf"
  fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  bootstrap
  step_ocserv
fi
