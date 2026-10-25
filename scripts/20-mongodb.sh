#!/usr/bin/env bash
# ============================================================================
# scripts/20-mongodb.sh - 下载 + 部署 MongoDB（官方预编译 tarball）
#
# MongoDB 官方只发预编译 tarball，没有源码编译这回事，所以这里是"下载 + 解压 + 配置"。
#   fetch_mongodb / install_mongodb   主程序
#   fetch_mongosh / install_mongosh   命令行客户端（6.0+ 的 tarball 不再自带）
#
# 单独执行：sudo ./scripts/20-mongodb.sh
# ============================================================================

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
source "$LIB_DIR/config.sh"
source "$LIB_DIR/preflight.sh"
source "$LIB_DIR/service.sh"

# 官方预编译 tarball 的构建名映射（以 downloads.mongodb.org/current.json 的
# target 字段为准，8.x 系列实测命名）：
#   Debian  12 -> debian12；13+ 没有 debian13 构建，回退 debian12
#   Ubuntu  20.04/22.04/24.04 -> ubuntu2004/2204/2404
#   RHEL 家族 9 -> rhel93（9.3+ 构建，实测 el9 都能跑），8 -> rhel8，10 -> rhel10
#   openEuler 无官方构建 -> 先用 rhel8 包（glibc 基线最低 2.28，openEuler 22.03 的
#               glibc 2.34 可直接运行），失败自动回退 rhel93
# 若官方将来改了命名，在下面 case 里更新即可；config.ini 的 mongodb_distro
# 可强制指定构建名绕过本映射。
mongod_distro_candidates() {
  # 输出候选构建名（每行一个，按优先级）
  if [[ -n ${OS_FAMILY:-} || -n ${OS_ID:-} ]]; then :; else detect_os; fi
  case "${OS_ID:-}" in
    *ubuntu* | ubuntu)
      case "$OS_MAJOR" in
        20) printf 'ubuntu2004\n' ;;
        22) printf 'ubuntu2204\n' ;;
        *)  printf 'ubuntu2404\nubuntu2204\n' ;;   # 24.04 及更新版
      esac
      printf 'debian12\n' ;;
    *openEuler* | *openeuler* | *euleros*)
      printf 'rhel8\nrhel93\n' ;;
    *)
      case "${OS_FAMILY:-}" in
        rhel)
          case "$OS_MAJOR" in
            8)  printf 'rhel8\n' ;;
            10) printf 'rhel10\nrhel93\n' ;;
            *)  printf 'rhel93\n' ;;
          esac ;;
        *) # debian 家族
          case "$OS_MAJOR" in
            11) printf 'debian11\ndebian12\n' ;;
            12) printf 'debian12\n' ;;
            *)  printf 'debian12\n' ;;
          esac ;;
      esac ;;
  esac
}

# 取当前选定的构建名（第一个候选；带一次进程内缓存，避免重复探测/下载判断）
mongod_distro() {
  local distro="${CFG_mongodb_distro:-auto}"
  if [[ $distro != auto ]]; then
    printf '%s' "$distro"
    return 0
  fi
  if [[ -z ${_MONGOD_DISTRO_CACHE:-} ]]; then
    _MONGOD_DISTRO_CACHE="$(mongod_distro_candidates | sed -n 1p)"
  fi
  printf '%s' "$_MONGOD_DISTRO_CACHE"
}

# --- 下载 -------------------------------------------------------------------
# 按候选构建名依次尝试（如 openEuler 先 rhel8 后 rhel93），soft 失败自动换下一个；
# 成功后把实际构建名记到 $STATE_DIR/mongodb_distro，供 install 与日志复用。
fetch_mongodb() {
  local -a cands=()
  if [[ -n ${CFG_mongodb_distro:-} && ${CFG_mongodb_distro:-auto} != auto ]]; then
    cands=("$CFG_mongodb_distro")
  else
    mapfile -t cands < <(mongod_distro_candidates)
  fi

  step "下载 MongoDB ${CFG_mongodb}（候选构建：${cands[*]}）"
  local d name okd=""
  for d in "${cands[@]}"; do
    name="mongodb-linux-x86_64-${d}-${CFG_mongodb}"
    [[ -n $okd ]] && break
    if [[ $d != "${cands[0]}" ]]; then
      warn "  ${cands[0]} 构建不可用，回退 ${d}"
    fi
    if fetch "https://fastdl.mongodb.org/linux/${name}.tgz" \
             "$SRC_DIR/${name}.tgz" "${CFG_mongodb_sha256:-}" soft; then
      okd="$d"
    else
      rm -f "$SRC_DIR/${name}.tgz"
    fi
  done
  [[ -n $okd ]] || die "MongoDB ${CFG_mongodb} 所有候选构建都下载失败（已尝试：${cands[*]}）。可在 config.ini 用 mongodb_distro 强制指定构建名。"
  mkdir -p "$STATE_DIR"
  printf '%s\n' "$okd" > "$STATE_DIR/mongodb_distro"
}

# 当前应使用的 tarball 名：优先用 fetch 记录的构建，其次按本系统首选构建推断
mongodb_tarball_name() {
  local d="" f="$STATE_DIR/mongodb_distro"
  [[ -s $f ]] && d="$(cat "$f")"
  [[ -n $d ]] || d="$(mongod_distro)"
  printf 'mongodb-linux-x86_64-%s-%s' "$d" "${CFG_mongodb}"
}

# --- 安装 -------------------------------------------------------------------
install_mongodb() {
  step "部署 MongoDB ${CFG_mongodb}"

  if [[ "$(installed_version mongodb)" == "${CFG_mongodb}" ]]; then
    info "  已是 ${CFG_mongodb}，跳过"
    return 0
  fi

  local name; name="$(mongodb_tarball_name)"
  local tarball="$SRC_DIR/${name}.tgz"
  if [[ ! -s $tarball ]]; then
    fetch_mongodb
    name="$(mongodb_tarball_name)"
    tarball="$SRC_DIR/${name}.tgz"
  fi
  [[ -s $tarball ]] || die "找不到已下载的 MongoDB 包：$tarball"
  local distro="${name#mongodb-linux-x86_64-}"; distro="${distro%-*}"

  mkdir -p "$PREFIX_MONGODB"
  tar -xzf "$tarball" -C "$PREFIX_MONGODB" --strip-components=1

  mkdir -p "$PREFIX_MONGODB"
  tar -xzf "$tarball" -C "$PREFIX_MONGODB" --strip-components=1

  ensure_user mongodb
  mkdir -p "$PREFIX_MONGODB/data" "$PREFIX_MONGODB/log"
  chown -R mongodb:mongodb "$PREFIX_MONGODB/data" "$PREFIX_MONGODB/log"

  # 这里只放开 127.0.0.1；需要容器/内网访问时自行改 bindIp
  if [[ ! -f $PREFIX_MONGODB/mongod.conf ]]; then
    cat > "$PREFIX_MONGODB/mongod.conf" <<EOF
# MongoDB 配置（由 lnmp 安装器生成）
net:
  port: ${PORT_MONGODB}
  bindIp: 127.0.0.1
storage:
  dbPath: ${PREFIX_MONGODB}/data
systemLog:
  destination: file
  path: ${PREFIX_MONGODB}/log/mongod.log
  logAppend: true
processManagement:
  fork: true
  pidFilePath: ${PREFIX_MONGODB}/data/mongod.pid
EOF
  fi

  mark_installed mongodb "${CFG_mongodb}"
  info "  MongoDB ${CFG_mongodb} 部署完成（${distro} 构建）"
}

# --- mongosh ----------------------------------------------------------------
# config.ini 里 mongosh 留空则整个跳过
mongosh_enabled() { [[ -n ${CFG_mongosh:-} ]]; }

fetch_mongosh() {
  mongosh_enabled || { info "跳过 mongosh（config.ini 未配置 mongosh）"; return 0; }

  local ver="$CFG_mongosh"
  step "下载 mongosh ${ver}"
  fetch "https://downloads.mongodb.com/compass/mongosh-${ver}-linux-x64.tgz" \
        "$SRC_DIR/mongosh-${ver}-linux-x64.tgz" ""
}

install_mongosh() {
  mongosh_enabled || { info "跳过 mongosh（config.ini 未配置 mongosh）"; return 0; }

  local ver="$CFG_mongosh"
  step "安装 mongosh ${ver}"

  if [[ $(installed_version mongosh) == "$ver" && -x $PREFIX_MONGODB/bin/mongosh ]]; then
    info "  已是 ${ver}，跳过"
    return 0
  fi

  local tarball="$SRC_DIR/mongosh-${ver}-linux-x64.tgz"
  fetch_mongosh

  rm -rf "$SRC_DIR/mongosh-${ver}-linux-x64"
  tar -xzf "$tarball" -C "$SRC_DIR"

  # mongosh 依赖同目录的 mongosh_crypt_v1.so，两个文件必须一起放
  local d="$SRC_DIR/mongosh-${ver}-linux-x64"
  [[ -f $d/bin/mongosh ]] || die "mongosh 包内结构异常：$d/bin/mongosh 不存在"
  install -m 0755 "$d/bin/mongosh" "$PREFIX_MONGODB/bin/mongosh"
  if [[ -f $d/bin/mongosh_crypt_v1.so ]]; then
    install -m 0755 "$d/bin/mongosh_crypt_v1.so" "$PREFIX_MONGODB/bin/mongosh_crypt_v1.so"
  fi
  ln -sf "$PREFIX_MONGODB/bin/mongosh" /usr/local/bin/mongosh

  mark_installed mongosh "$ver"
  info "  mongosh ${ver} 安装完成"
}

# --- 初始账号 ---------------------------------------------------------------
# 像 wnmmp 那样建一个 root / 指定密码的账号，并开启访问认证。
# 幂等：账号已存在或认证已开启都直接跳过。需要先装好 mongosh 且 mongod 在跑。
init_mongodb() {
  mongosh_enabled || { warn "未配置 mongosh，无法初始化账号，跳过（请手动建）"; return 0; }
  [[ -n ${CFG_mongodb_root_user:-} && -n ${CFG_mongodb_root_pass:-} ]] \
    || { info "config.ini 未配置 mongodb_root_user / mongodb_root_pass，跳过账号初始化"; return 0; }

  local mongo="$PREFIX_MONGODB/bin/mongosh"
  [[ -x $mongo ]] || { warn "$mongo 不存在，跳过账号初始化"; return 0; }

  step "初始化 MongoDB 账号（${CFG_mongodb_root_user} / ${CFG_mongodb_root_pass}）"

  # mongod 必须先跑起来（无认证状态下才能建账号）。
  # 用 start_mongod_safe：会先修正数据目录属主（recover 曾以 root 起实例导致
  # 属主错乱），失败也不再中止整个安装，只跳过账号初始化并给出补救命令。
  start_mongod_safe \
    || { warn "mongod 未能启动，账号初始化跳过（修复后重跑：sudo ./install.sh mongoinit）"; return 0; }

  # 是否已开过认证（只认真正的 authorization: 配置行）
  local auth_on=false
  grep -qE '^\s*authorization:' "$PREFIX_MONGODB/mongod.conf" && auth_on=true

  # 用临时 JS 文件建账号，避免密码里特殊字符破坏 -e 参数。
  # 注意：mongosh 把位置参数当作连接 URI，文件必须用 --file 传入，否则报 Invalid URI。
  local js out
  js=$(mktemp)
  cat > "$js" <<EOF
const u = "${CFG_mongodb_root_user}";
const admin = db.getSiblingDB("admin");
if (admin.getUser(u) !== null) {
  print("EXISTS");
} else {
  admin.createUser({ user: u, pwd: "${CFG_mongodb_root_pass}", roles: [{ role: "root", db: "admin" }] });
  print("CREATED");
}
EOF

  if $auth_on; then
    out=$("$mongo" --quiet --port "$PORT_MONGODB" -u "$CFG_mongodb_root_user" \
          -p "$CFG_mongodb_root_pass" --authenticationDatabase admin --file "$js" 2>&1) || true
  else
    out=$("$mongo" --quiet --port "$PORT_MONGODB" --file "$js" 2>&1) || true
  fi
  rm -f "$js"

  # 判定结果；若已开认证却建不出账号（典型：认证已开但无用户 → 锁死），走无认证恢复
  if [[ $out == *CREATED* || $out == *EXISTS* ]]; then
    info "  root 账号就绪"
  else
    warn "  直接建账号失败（${out//$'\n'/ }）"
    warn "  疑似「认证已开但无用户」锁死，尝试临时无认证恢复"
    recover_mongodb_account \
      || die "  无认证恢复失败，未改动认证配置，请手动处理"
    info "  root 账号就绪（经恢复流程）"
    auth_on=true   # 恢复后认证仍在配置里，下面不再重复开启
  fi

  # 开启认证（幂等：仅在未开过、且账号已就绪时）
  if ! $auth_on; then
    cat >> "$PREFIX_MONGODB/mongod.conf" <<EOF

security:
  authorization: enabled
EOF
    info "  已启用 MongoDB 认证，重启使生效"
    svc_restart mongodb || true
    sleep 2
  fi

  # 用新账号验证能连上
  out=$("$mongo" --quiet --port "$PORT_MONGODB" -u "$CFG_mongodb_root_user" \
        -p "$CFG_mongodb_root_pass" --authenticationDatabase admin \
        --eval 'db.runCommand({ping:1}).ok' 2>&1) || true
  [[ $out == *"1"* ]] && info "  认证连接验证通过" \
                        || warn "  认证连接验证未通过，请检查：$out"

  mark_installed mongodb_account "${CFG_mongodb_root_user}"
}

# 无认证临时恢复：当 mongod 已开认证却没有任何用户（锁死）时，
# 停服 → 以 --noauth 临时起实例建账号 → 关临时实例 → 用正常（认证）方式重启。
# 全程只动 mongod 进程，不改 mongod.conf，因此恢复后认证配置保持原样。
recover_mongodb_account() {
  local bin="$PREFIX_MONGODB/bin/mongod"
  local mongo="$PREFIX_MONGODB/bin/mongosh"
  local conf="$PREFIX_MONGODB/mongod.conf"
  local log="$PREFIX_MONGODB/log/recover.log"

  # 停掉当前所有 mongod（无论怎么起的）
  svc_stop mongodb || pkill -x mongod 2>/dev/null || true
  sleep 2
  pkill -9 -x mongod 2>/dev/null || true
  sleep 1

  # 以 --noauth 覆盖配置里的认证，临时起一个 fork 实例
  "$bin" --config "$conf" --noauth --fork --logpath "$log" >/dev/null 2>&1 || true
  sleep 3

  # 此时无认证，必能建账号
  local js out
  js=$(mktemp)
  cat > "$js" <<EOF
const u = "${CFG_mongodb_root_user}";
const admin = db.getSiblingDB("admin");
if (admin.getUser(u) === null) {
  admin.createUser({ user: u, pwd: "${CFG_mongodb_root_pass}", roles: [{ role: "root", db: "admin" }] });
  print("CREATED");
} else {
  print("EXISTS");
}
EOF
  out=$("$mongo" --quiet --port "$PORT_MONGODB" --file "$js" 2>&1) || true
  rm -f "$js"
  info "  恢复过程建账号输出：${out//$'\n'/ }"

  # 关掉临时实例：优先 --shutdown，再兜底强杀，务必彻底退出，
  # 否则残留的 noauth 实例会占着 27017，导致下面 systemctl start 起不来
  "$bin" --config "$conf" --shutdown >/dev/null 2>&1 || true
  sleep 2
  pkill -x mongod 2>/dev/null || true
  sleep 2
  pkill -9 -x mongod 2>/dev/null || true
  sleep 1

  # ★ 关键：上面的 noauth 实例是 root 起的，数据目录会被写成 root 属主，
  # 而 systemd 单元用 User=mongodb 启动会 Permission denied。这里把属主改回
  # mongodb，并清掉陈旧锁，systemd 才能正常拉起。
  if id mongodb >/dev/null 2>&1; then
    chown -R mongodb:mongodb "$PREFIX_MONGODB/data" "$PREFIX_MONGODB/log" 2>/dev/null || true
  fi
  local lock="$PREFIX_MONGODB/data/mongod.lock"
  [[ -f $lock ]] && ! pgrep -x mongod >/dev/null 2>&1 && rm -f "$lock"

  # 用正常（认证）方式重新启动，与安装时一致（systemd 走 systemctl，容器走直启）
  svc_start mongodb || true
  sleep 3
}

# --- 入口 -------------------------------------------------------------------
step_mongodb() {
  deps_mongodb
  fetch_mongodb
  install_mongodb
}

step_mongosh() {
  fetch_mongosh
  install_mongosh
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  case "${1:-}" in
    init)
      bootstrap
      init_mongodb
      ;;
    *)
      bootstrap
      require_avx
      require_ports "$PORT_MONGODB"
      require_disk
      step_mongodb
      step_mongosh
      ;;
  esac
fi
