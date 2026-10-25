#!/usr/bin/env bash
# ============================================================================
# scripts/78-firewall.sh - 主机防火墙收紧：对外只放行 80 / 443 / ocserv 端口
#
# step_firewall   自动识别 firewalld（RHEL 系常态）或 iptables（Debian 系），
#                 应用下面的策略并尽力持久化（重启后仍生效）。
#                 两者都拿不到时（源里没 iptables 的精简系统）只告警并打印手工
#                 补规则的命令，不中止安装——中断会把后面的 systemd/启动/自检一起带走。
#   - 放行：80/tcp、443/tcp（nginx/acme）、ocserv 端口 tcp+udp（config.ini ocserv_port）
#   - 22/tcp：拒绝一切外部来源，只放行本机回环与 ocserv 地址段
#             （如 10.10.10.0/24）——外部必须先连上 VPN 才能 SSH。
#             安全闸：ocserv 没装或没在跑时本次不收紧 22，避免把自己锁在门外；
#             收紧时已建立的 SSH 会话靠 conntrack ESTABLISHED 放行，不会断线
#   - 其余端口（含 MongoDB 27017、PHP-FPM 9000）：全部拒绝对外
#   - NAT：为 VPN 客户端补 MASQUERADE（ocserv 已安装时）
#
# firewall_undo   还原：恢复 22 对外访问、删除本套规则（应急逃生口）
#
# 单独执行：
#   sudo ./scripts/78-firewall.sh          # 应用收紧策略
#   sudo ./scripts/78-firewall.sh undo     # 还原（恢复 SSH 对外开放）
#
# 由 step_ocserv 在 ocserv 装完/起来后自动调用，不需要单独跑。
# ============================================================================

# 允许被重复 source（load_steps 全量 source 一次 + 75-ocserv.sh 顶部再 source 一次）
[[ -n ${_LNMP_SCRIPT_FIREWALL:-} ]] && return 0
readonly _LNMP_SCRIPT_FIREWALL=1

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
source "$LIB_DIR/config.sh"
source "$LIB_DIR/preflight.sh"
source "$LIB_DIR/service.sh"

readonly FW_SSH_PORT=22
readonly FW_IPT_CHAIN="LNMP-IN"   # iptables 双路径共用的自定义链名

# 255.255.255.0 -> 24；结果异常时兜底 24，避免写出非法 CIDR
netmask_to_cidr() {
  local mask="${1:-255.255.255.0}" octet n bits=0
  for octet in ${mask//./ }; do
    # 用赋值形式而非 ((x >>= 1))：算术结果为 0 时 ((...)) 返回 1，set -e 下会中断函数
    n=$((10#$octet))
    while ((n)); do
      bits=$((bits + (n & 1)))
      n=$((n >> 1))
    done
  done
  ((bits >= 1 && bits <= 32)) || bits=24
  printf '%s' "$bits"
}

has_firewalld() {
  command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1
}

# --- firewalld 路径（RHEL/Rocky 常态） --------------------------------------
# 永久区操作幂等（重复 add 不产生副作用），22 的 rich 规则先清后加，
# 改过 ocserv_network 再重跑不会残留旧网段。
lock_firewalld() {
  local port="$1" vpn_blk="$2" ssh_locked="$3"
  local zone old
  zone="$(firewall-cmd --get-default-zone)"
  local -a per=(--permanent --zone="$zone")

  firewall-cmd "${per[@]}" --add-service=http --add-service=https \
    --add-port="${port}/tcp" --add-port="${port}/udp" --add-masquerade \
    >/dev/null 2>&1 || warn "  firewalld：放行 80/443/${port} 失败，请手动检查"

  # 清掉历史 22 rich 规则：--list-rich-rules 回显带引号（port port="22"），
  # 先剥引号再比对，改过 ocserv_network 重跑也不残留
  local old plain
  while IFS= read -r old; do
    plain="${old//\"/}"
    [[ -n $plain && $plain == *"port port=${FW_SSH_PORT}"* ]] || continue
    firewall-cmd "${per[@]}" --remove-rich-rule="$old" >/dev/null 2>&1 || true
  done < <(firewall-cmd --permanent --zone="$zone" --list-rich-rules 2>/dev/null || true)

  if ((ssh_locked)); then
    firewall-cmd "${per[@]}" --remove-service=ssh >/dev/null 2>&1 || true
    firewall-cmd "${per[@]}" \
      --add-rich-rule="rule family=ipv4 source address=${vpn_blk} port port=${FW_SSH_PORT} protocol=tcp accept" \
      >/dev/null 2>&1 || warn "  firewalld：22 端口 rich 规则添加失败"
    info "  firewalld（zone ${zone}）：对外仅 80/443/${port}；SSH 仅限本机与 ${vpn_blk}（VPN 内）"
  else
    firewall-cmd "${per[@]}" --add-service=ssh >/dev/null 2>&1 || true
    info "  firewalld（zone ${zone}）：对外放行 80/443/${port} + SSH（ocserv 未就绪，22 暂不收紧）"
  fi
  firewall-cmd --reload >/dev/null 2>&1 || warn "  firewalld reload 失败"
}

# --- iptables 路径（无 firewalld 的机器，含 Debian 系默认） -------------------
# 自建 LNMP-IN 链并挂在 INPUT 首位：重复执行先拆后建（幂等），不动机器上
# 已有的其它规则；链内先放 lo + 已建立连接（保住当前 SSH），再放行业务端口，
# 末尾 REJECT 一切。IPv6 没有对应的 VPN 段，收紧时 SSH 仅本机可达。
reset_chain() {
  local ipt="$1"
  $ipt -D INPUT -j "$FW_IPT_CHAIN" 2>/dev/null || true
  $ipt -F "$FW_IPT_CHAIN" 2>/dev/null || true
  $ipt -X "$FW_IPT_CHAIN" 2>/dev/null || true
}

lock_iptables() {
  local port="$1" vpn_blk="$2" ssh_locked="$3"
  # 最小化镜像（debian:12 等）没有 iptables 命令，先软装再检查
  command -v iptables >/dev/null 2>&1 || pkg_install_any "iptables" iptables
  # 装不上就到此为止，不能 die：这里是安装流程的后段，中断会让 systemd 单元、
  # 服务启动与 99-verify 自检全部不跑，机器停在"半装"状态比没收紧更糟。
  # 而且 mongod/php-fpm 都只 bind 127.0.0.1，跳过收紧只是维持原样，不是新开的洞。
  if ! command -v iptables >/dev/null 2>&1; then
    warn "  没有 iptables 命令，本次未收紧防火墙（其余安装步骤照常继续）"
    warn "  手工补上（任选其一，然后重跑 sudo ${ROOT_DIR}/scripts/78-firewall.sh）："
    warn "    1) ${PKG:-dnf} install -y iptables   # 上面已打印装不上的真实原因"
    command -v firewall-cmd >/dev/null 2>&1 && \
      warn "    2) 本机有 firewall-cmd 但 firewalld 没在跑：systemctl start firewalld"
    command -v nft >/dev/null 2>&1 && \
      warn "    3) 本机只有 nftables(nft)：本脚本暂不用它下规则，需手工放行 80/443/${port}"
    return 1
  fi
  iptables -S >/dev/null 2>&1 \
    || { warn "  当前环境无权操作 iptables（容器缺 NET_ADMIN？），本次未收紧"; return 1; }

  # IPv4
  reset_chain iptables
  iptables -N "$FW_IPT_CHAIN"
  iptables -A "$FW_IPT_CHAIN" -i lo -j ACCEPT
  iptables -A "$FW_IPT_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  iptables -A "$FW_IPT_CHAIN" -p icmp -j ACCEPT
  iptables -A "$FW_IPT_CHAIN" -p tcp -m multiport --dports "80,443,${port}" -j ACCEPT
  iptables -A "$FW_IPT_CHAIN" -p udp --dport "$port" -j ACCEPT
  if ((ssh_locked)); then
    iptables -A "$FW_IPT_CHAIN" -s "$vpn_blk" -p tcp --dport "$FW_SSH_PORT" -j ACCEPT
  else
    iptables -A "$FW_IPT_CHAIN" -p tcp --dport "$FW_SSH_PORT" -j ACCEPT
  fi
  iptables -A "$FW_IPT_CHAIN" -j REJECT --reject-with icmp-port-unreachable
  iptables -C INPUT -j "$FW_IPT_CHAIN" 2>/dev/null || iptables -I INPUT -j "$FW_IPT_CHAIN"

  # IPv6（有 ip6tables 且有权操作时才做）
  if command -v ip6tables >/dev/null 2>&1 && ip6tables -S >/dev/null 2>&1; then
    reset_chain ip6tables
    ip6tables -N "$FW_IPT_CHAIN"
    ip6tables -A "$FW_IPT_CHAIN" -i lo -j ACCEPT
    ip6tables -A "$FW_IPT_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    ip6tables -A "$FW_IPT_CHAIN" -p ipv6-icmp -j ACCEPT
    ip6tables -A "$FW_IPT_CHAIN" -p tcp -m multiport --dports "80,443,${port}" -j ACCEPT
    ip6tables -A "$FW_IPT_CHAIN" -p udp --dport "$port" -j ACCEPT
    if (( ! ssh_locked )); then
      ip6tables -A "$FW_IPT_CHAIN" -p tcp --dport "$FW_SSH_PORT" -j ACCEPT
    fi
    ip6tables -A "$FW_IPT_CHAIN" -j DROP
    ip6tables -C INPUT -j "$FW_IPT_CHAIN" 2>/dev/null || ip6tables -I INPUT -j "$FW_IPT_CHAIN"
  fi

  # VPN 客户端出网伪装（ocserv 装了才有意义；vpns+ 通配 vpns0/vpns1…，
  # VPN 内部互访不伪装，只有真正往外发的流量才 MASQUERADE）
  local -a nat=(POSTROUTING -s "$vpn_blk" '!' -o vpns+ -j MASQUERADE)
  if [[ -x /usr/local/sbin/ocserv ]]; then
    iptables -t nat -C "${nat[@]}" 2>/dev/null \
      || iptables -t nat -A "${nat[@]}" 2>/dev/null \
      || warn "  MASQUERADE 添加失败，VPN 客户端出网需手动配置"
  fi

  if ((ssh_locked)); then
    info "  iptables（${FW_IPT_CHAIN} 链）：对外仅 80/443/${port}，其余端口（含 27017）拒绝"
    info "  SSH(${FW_SSH_PORT})：仅本机与 ${vpn_blk}（VPN 内）可连；IPv6 侧 SSH 仅本机"
  else
    info "  iptables（${FW_IPT_CHAIN} 链）：对外仅 80/443/${port} + SSH（ocserv 未就绪，22 暂不收紧）"
  fi
  persist_iptables
}

# --- 规则持久化（无 systemd 的容器里只落盘，enable 静默失败） ----------------
persist_iptables() {
  if os_is_debian; then
    pkg_install_any "iptables 规则持久化" iptables-persistent >/dev/null 2>&1 || true
    if command -v netfilter-persistent >/dev/null 2>&1 \
       && netfilter-persistent save >/dev/null 2>&1; then
      info "  规则已持久化（iptables-persistent，开机自动恢复）"
      return 0
    fi
    # 装不上 iptables-persistent：至少把当前规则落盘，供手动恢复
    if mkdir -p /etc/iptables \
       && iptables-save > /etc/iptables/rules.v4 2>/dev/null; then
      command -v ip6tables >/dev/null 2>&1 \
        && ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
      info "  规则已导出 /etc/iptables/rules.v4（重启后用 iptables-restore 恢复）"
    else
      warn "  规则未能持久化，重启后需重跑 sudo ${ROOT_DIR}/scripts/78-firewall.sh"
    fi
  else
    pkg_install_any "iptables 规则持久化" iptables-services >/dev/null 2>&1 || true
    if iptables-save > /etc/sysconfig/iptables 2>/dev/null; then
      have_systemd && systemctl enable iptables >/dev/null 2>&1 || true
      info "  规则已持久化（/etc/sysconfig/iptables + iptables.service）"
    else
      warn "  规则未能持久化（缺 iptables-services？），重启后需重跑 sudo ${ROOT_DIR}/scripts/78-firewall.sh"
    fi
  fi
}

# --- 收紧入口 ---------------------------------------------------------------
step_firewall() {
  step "收紧主机防火墙（对外仅 80 / 443 / ${CFG_ocserv_port:-4443}）"

  local port net vpn_blk ssh_locked=1
  port="${CFG_ocserv_port:-4443}"
  net="${CFG_ocserv_network:-10.10.10.0}"
  vpn_blk="${net}/$(netmask_to_cidr "${CFG_ocserv_netmask:-255.255.255.0}")"

  # 安全闸：VPN 通道不存在时锁 22 = 远程失联，只收紧其余端口
  if [[ ! -x /usr/local/sbin/ocserv ]]; then
    ssh_locked=0
    warn "  ocserv 未安装：22 端口保持对外开放（无 VPN 通道，收紧 SSH 会失联）"
  elif ! svc_status ocserv; then
    ssh_locked=0
    warn "  ocserv 未在运行：本次不收紧 22（先 ./ctrl.sh start ocserv 再重跑收紧）"
  fi

  if has_firewalld; then
    lock_firewalld "$port" "$vpn_blk" "$ssh_locked" \
      || warn "  firewalld 规则应用失败，请手动检查 firewall-cmd"
  else
    lock_iptables "$port" "$vpn_blk" "$ssh_locked" || true
  fi
  info "  如需恢复 SSH 对外访问：sudo ${ROOT_DIR}/scripts/78-firewall.sh undo"
}

# --- 还原（逃生口） -----------------------------------------------------------
# 只回滚本脚本引入的东西：firewalld 的 ssh 服务开关 + 22 的 rich 规则；
# iptables 的 LNMP-IN 链 + MASQUERADE。其它既有规则一律不动。
firewall_undo() {
  step "还原防火墙设置（恢复 SSH 对外访问）"

  local vpn_blk="${CFG_ocserv_network:-10.10.10.0}/$(netmask_to_cidr "${CFG_ocserv_netmask:-255.255.255.0}")"

  if has_firewalld; then
    local zone old plain
    zone="$(firewall-cmd --get-default-zone)"
    local -a per=(--permanent --zone="$zone")
    while IFS= read -r old; do
      plain="${old//\"/}"
      [[ -n $plain && $plain == *"port port=${FW_SSH_PORT}"* ]] || continue
      firewall-cmd "${per[@]}" --remove-rich-rule="$old" >/dev/null 2>&1 || true
    done < <(firewall-cmd --permanent --zone="$zone" --list-rich-rules 2>/dev/null || true)
    firewall-cmd "${per[@]}" --add-service=ssh >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    info "  firewalld：已恢复 ssh 服务放行"
  fi

  local ipt
  for ipt in iptables ip6tables; do
    command -v "$ipt" >/dev/null 2>&1 || continue
    "$ipt" -S >/dev/null 2>&1 || continue
    reset_chain "$ipt"
  done
  local -a nat=(POSTROUTING -s "$vpn_blk" '!' -o vpns+ -j MASQUERADE)
  while iptables -t nat -C "${nat[@]}" 2>/dev/null; do
    iptables -t nat -D "${nat[@]}" 2>/dev/null || break
  done
  if command -v iptables >/dev/null 2>&1 && iptables -S >/dev/null 2>&1; then
    info "  iptables：${FW_IPT_CHAIN} 链与 MASQUERADE 已移除"
    persist_iptables || true
  fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  bootstrap
  case "${1:-apply}" in
    apply) step_firewall ;;
    undo)  firewall_undo ;;
    *)     die "用法：$0 [apply|undo]" ;;
  esac
fi
