#!/usr/bin/env bash
# ============================================================================
# scripts/80-nginx-conf.sh - 生成 nginx 主配置、公共片段与默认站点
#
# 只写骨架：文件已存在就保留，不吃掉用户改动。
# 负责 ngx_http_acme_module 的接入：
#   - 在 nginx.conf 注入 load_module（main 上下文，events 之前）
#   - 生成 conf.d/acme.conf：resolver + acme_issuer + acme_shared_zone
#   - 生成 conf.d/xqkeji.cn.conf：xqkeji.cn / www.xqkeji.cn 的自动 HTTPS
#
# 上传安全（防 webshell 落地执行）：
#   - snippets/lnmp-upload-guard.conf：上传目录里的脚本文件 return 404，目录名取
#     config.ini 的 upload_dirs；每次重跑按配置重新生成。
#   - snippets/lnmp-php.conf：PHP 转发段，带 try_files $uri =404（挡 path info）。
#   - 新生成的站点直接 include 这两段；已存在的站点由本脚本按 server 块自动注入
#     guard（原文件留 .bak-lnmp 备份），注入前后各跑一次 nginx -t，失败即回滚。
#
# 本地测试 HTTPS（config.ini 的 local_tls_names 非空时）：
#   - 自建一份 CA（/usr/local/lnmp/tls/lnmp-local-ca.crt，已存在就复用），用它
#     签一张带 SAN 的站点证书，装进本机信任库；设备侧导入同一个 CA。
#   - 生成 conf.d/local-tls.conf：443 + 这份证书，server_name 取同一份名单，
#     所以 https://localhost、https://127.0.0.1、https://任意子域.xqkeji.dev 都能
#     直接访问本机站点，不用公网域名也不走 ACME。
#
# apt 路线（默认）：nginx.conf 由 nginx.org 包提供，本脚本不动它，只注入
#   load_module 绝对路径 + 生成 conf.d；html 根用 /usr/share/nginx/html，
#   acme 状态目录属主用 nginx（包建的用户）。
# src 路线：自行生成骨架，路径用 $PREFIX_NGINX。
#
# 单独执行：sudo ./scripts/80-nginx-conf.sh
# ============================================================================

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
source "$LIB_DIR/config.sh"
source "$LIB_DIR/preflight.sh"

# --- 公共配置片段（snippets）------------------------------------------------
# 站点里重复的两段抽成文件：上传目录拦截 + PHP 转发。
# 放 snippets/ 而不是 conf.d/：conf.d 被 `include conf.d/*.conf` 在 http 上下文
# 自动加载，而这两段是 server 上下文的 location/include 行，放进去 nginx -t 直接报错。

# 把 config.ini 的 upload_dirs 拼成正则分支（upload|asset…）。
# 目录名只允许常见字符，其它一律丢掉：值要拼进 nginx 正则，不能原样透传。
# 用 read -a 拆而不是裸 ${...} 展开：后者会把值当 glob，配 `upload_dirs=*`
# 就把当前目录的文件名当成目录名拼进正则了。
upload_dirs_regex() {
  local -a list=()
  local d out=""
  read -r -a list <<<"${CFG_upload_dirs:-$UPLOAD_DIRS_DEFAULT}"
  for d in "${list[@]}"; do
    [[ $d =~ ^[A-Za-z0-9_.-]+$ ]] || { warn "  upload_dirs 里 ${d} 含非法字符，已忽略"; continue; }
    out+="${out:+|}${d//./\\.}"
  done
  [[ -n $out ]] || out="${UPLOAD_DIRS_DEFAULT// /|}"
  printf '%s' "$out"
}

gen_snippets() {  # gen_snippets <snippets 目录> <fastcgi_params 路径>
  local dir="$1" fcgi="$2" dirs
  dirs="$(upload_dirs_regex)"
  mkdir -p "$dir"

  cat > "$dir/lnmp-upload-guard.conf" <<EOF
# 由 lnmp 安装器生成（重跑会覆盖，请勿手改；要改目录名改 config.ini 的 upload_dirs）
# 上传/可写目录里的脚本文件一律不交给 php-fpm。命中即 404，不透露"这里有什么"。
# 覆盖任意层级与 path info：/upload/x.php、/a/upload/x.php、/asset/x.php、
# /upload/shell.jpg/x.php
# 必须在站点里 include 到 \`location ~ \.php\$ \` 之前——nginx 的正则 location
# 按配置文件里出现的先后顺序命中，排后面就等于不生效。
location ~* "(^|/)(${dirs})/.*\.(php[0-9]*|phtml|phps|phar|cgi|pl|py|sh)\$" {
    return 404;
}
EOF

  cat > "$dir/lnmp-php.conf" <<EOF
# 由 lnmp 安装器生成（重跑会覆盖，请勿手改）
# PHP 转发段。顺序要求：先 include lnmp-upload-guard.conf，再 include 本文件。
location ~ \.php\$ {
    # 请求的 .php 必须真实存在，否则 404。少了这一行，/upload/shell.jpg/nonexistent.php
    # 会带着 fix_pathinfo 交给 php-fpm，落到已存在的 shell.jpg 上被执行。
    try_files \$uri =404;
    fastcgi_pass   127.0.0.1:${PORT_PHP_FPM};
    fastcgi_index  index.php;
    fastcgi_param  SCRIPT_FILENAME  \$document_root\$fastcgi_script_name;
    include        ${fcgi};
}
EOF
  info "  已生成 snippets/lnmp-upload-guard.conf（${dirs//|/ }）与 snippets/lnmp-php.conf"
}

# --- 已存在站点的自动加固 ---------------------------------------------------
# 规则：每个 server 块最多插一次 guard include（同块插两次会得到重复的
# location，nginx -t 直接报 duplicate location）。判据是 awk 单遍扫描：
# 见到 `server {` 就重置标记，见到本块已有的 guard include 也置位，
# 直到第一个 php location 仍没有 guard 就在它前面补一行（沿用该行缩进）。
# 只认 `server {` 同一行的写法；`server` 与 `{` 分两行的配置文件会被跳过
# （不注入就不会破坏它，日志里会写明本文件未改动）。
inject_guard_include() {  # inject_guard_include <file> <include 目标>；有改动时返回 0
  local f="$1" inc="$2" tmp
  tmp="$(mktemp)"
  awk -v inc="$inc" '
    /^[[:space:]]*server[[:space:]]*\{/      { guarded = 0 }
    /^[[:space:]]*include[[:space:]]+[^;]*lnmp-upload-guard\.conf/ { guarded = 1 }
    !guarded && /^[[:space:]]*location[^;{]*\.php/ {
      pos = match($0, /[^[:space:]]/)
      printf "%*sinclude %s;\n", pos - 1, "", inc
      guarded = 1
      touched = 1
    }
    { print }
    END { exit (touched ? 0 : 1) }
  ' "$f" > "$tmp" || { rm -f "$tmp"; return 1; }

  cp -p "$f" "$f.bak-lnmp" 2>/dev/null || warn "  备份 $f 失败（将继续，改坏可用 git/快照回滚）"
  cat "$tmp" > "$f"
  rm -f "$tmp"
  _PATCHED_FILES+=" $f"
  info "  已向 $(basename "$f") 的 server 块注入 lnmp-upload-guard.conf"
  return 0
}

patch_existing_vhosts() {  # patch_existing_vhosts <conf.d 目录> <guard 的绝对路径>
  local confd="$1" inc="$2" f
  for f in "$confd"/*.conf; do
    [[ -f $f ]] || continue
    [[ "$(basename "$f")" == acme.conf ]] && continue   # http 上下文的公共配置，不含 location
    # 站点里没有 php location 就与本项加固无关
    grep -qE '^[[:space:]]*location[^;{]*\.php' "$f" || continue
    inject_guard_include "$f" "$inc" || true
  done
}

# nginx 配置语法守门：<nginx 命令> -t
nginx_conf_test() {  # nginx_conf_test <nginx 可执行文件>；通过返回 0
  local bin="$1" out
  [[ -x $bin ]] || return 2
  if out="$("$bin" -t 2>&1)"; then
    return 0
  fi
  warn "  nginx -t 未通过：$(printf '%s' "$out" | tr '\n' ' ' | tail -c 300)"
  return 1
}

# --- 本地测试 HTTPS（自签 CA + 站点证书）-----------------------------------
# 为什么是"一份 CA + CA 签的站点证书"，而不是直接自签一张站点证书：
# .dev / .app 这类后缀在浏览器 HSTS 预加载名单里，证书不受信时连"继续访问"
# 按钮都没有；有了自己的 CA，把 CA 导进设备信任库一次，之后站点证书到期或改
# 名字只管重签，设备不用再动第二次。
# 有效期照 mkcert 的取值：CA 10 年、站点证书 825 天（超过这个天数 macOS/iOS
# 直接拒绝，签 10 年的站点证书等于白签）。

# config.ini 的 local_tls_names → 规范化的名字列表（空格分隔，非法项丢掉）。
# 这份名单既进证书 SAN 也进 nginx 的 server_name，所以必须先过字面白名单：
# 值里带空格或引号就能往 nginx 配置里塞任意指令。
# 用 read -a 拆而不是裸 ${...}：后者会把 `*.xqkeji.dev` 当 glob 展开成当前目录
# 的真实文件名。
local_tls_names() {
  local -a list=()
  local n out=""
  read -r -a list <<<"${CFG_local_tls_names:-$LOCAL_TLS_NAMES_DEFAULT}"
  for n in "${list[@]}"; do
    [[ $n =~ ^(\*\.)?[A-Za-z0-9_-]+([.][A-Za-z0-9_-]+)*$ || $n =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
      || { warn "  local_tls_names 里 ${n} 含非法字符，已忽略"; continue; }
    out+="${out:+ }${n}"
  done
  [[ -n $out ]] || out="$LOCAL_TLS_NAMES_DEFAULT"
  printf '%s' "$out"
}

# 名字列表 → 每行一条的 SAN 条目（DNS:x / IP:x）。IPv4 必须写成 IP:：
# 只写 DNS:127.0.0.1 的话，证书里根本没有 127.0.0.1 这个 IP 项，浏览器按 IP
# 访问照样报名字不匹配。
tls_san_list() {  # tls_san_list <名字列表>
  local -a arr=()
  local n
  read -r -a arr <<<"$1"
  for n in "${arr[@]}"; do
    if [[ $n =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      printf 'IP:%s\n' "$n"
    else
      printf 'DNS:%s\n' "$n"
    fi
  done
}

# SAN 条目（按行从 stdin 读）→ openssl 配置的 [alt_names] 段：DNS.n 与 IP.n
# 各自独立编号，不能共用一个序号。
tls_alt_names() {
  local e dns=0 ip=0
  while IFS= read -r e; do
    [[ -n $e ]] || continue
    case "$e" in
      IP:*) printf 'IP.%d  = %s\n'  $((++ip))  "${e#IP:}" ;;
      *)    printf 'DNS.%d = %s\n' $((++dns)) "${e#DNS:}" ;;
    esac
  done
}

# 已签发证书里的 SAN → 与 tls_san_list 同格式的排序列表，用来判断名字集合变没变。
# -ext 需要 openssl ≥1.1.1（本仓库支持的发行版全部满足）；取不到就当没有。
tls_san_norm() {  # tls_san_norm <证书文件>
  openssl x509 -in "$1" -noout -ext subjectAltName 2>/dev/null \
    | tail -n +2 | tr ',' '\n' \
    | sed -e 's/^[[:space:]]*//' -e 's/^IP Address:/IP:/' \
    | { grep -E '^(DNS|IP):' || true; } \
    | LC_ALL=C sort -u
}

gen_local_tls() {  # gen_local_tls <名字列表>；把 CA 与站点证书准备到位
  local names="$1" want have cn serial
  want="$(tls_san_list "$names" | LC_ALL=C sort -u)"
  serial="$LOCAL_TLS_DIR/lnmp-local-ca.srl"

  need_cmd openssl
  mkdir -p "$LOCAL_TLS_DIR"
  chmod 755 "$LOCAL_TLS_DIR"

  # --- CA：已存在就复用。换 CA 意味着每台设备的信任都要重新导一遍 ------------
  if [[ ! -s $LOCAL_TLS_CA || ! -s $LOCAL_TLS_CA_KEY ]]; then
    if [[ -s $LOCAL_TLS_CA || -s $LOCAL_TLS_CA_KEY ]]; then
      warn "  CA 的证书或私钥只剩一个，重新生成一对（已导入旧 CA 的设备需重新导入）"
      rm -f "$LOCAL_TLS_CA" "$LOCAL_TLS_CA_KEY" "$serial"
    fi
    info "  生成本地测试 CA：${LOCAL_TLS_CA}"
    local ca_cnf
    ca_cnf="$(mktemp)"
    cat > "$ca_cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions    = ca_ext
prompt             = no

[dn]
O  = lnmp
CN = lnmp Local Testing CA

[ca_ext]
basicConstraints   = critical,CA:TRUE,pathlen:0
keyUsage           = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
EOF
    # umask 077：私钥落盘那一刻就不能被其它用户读到
    ( umask 077
      openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
        -keyout "$LOCAL_TLS_CA_KEY" -out "$LOCAL_TLS_CA" -config "$ca_cnf" ) >/dev/null 2>&1 \
      || { rm -f "$ca_cnf"; die "生成本地测试 CA 失败（openssl req -x509）"; }
    rm -f "$ca_cnf"
    chmod 644 "$LOCAL_TLS_CA"
  else
    info "  本地测试 CA 已存在，复用：${LOCAL_TLS_CA}"
  fi
  ca_install_trust "$LOCAL_TLS_CA" \
    || warn "  CA 没装进本机信任库（服务器自己 curl 本地 https 仍会报证书错误），设备侧要手动导入"

  # --- 站点证书：名字集合变了、链不通到当前 CA、或剩余有效期不足 30 天就重签 ---
  # 链这一项不能省：CA 只剩半个文件时上面会重建一对，旧站点证书是新 CA 签不出来的
  # 但名字集合没变、也没到期，只比这两样就会把一张链不通过的证书留在原地，
  # nginx 起得来、浏览器却报"证书链不完整"，而且每次重跑都发现不了。
  have=""
  if [[ -s $LOCAL_TLS_CRT && -s $LOCAL_TLS_KEY ]]; then
    have="$(tls_san_norm "$LOCAL_TLS_CRT")"
    openssl verify -CAfile "$LOCAL_TLS_CA" "$LOCAL_TLS_CRT" >/dev/null 2>&1 || have=""
  fi
  if [[ $have == "$want" ]] \
     && openssl x509 -in "$LOCAL_TLS_CRT" -noout -checkend 2592000 >/dev/null 2>&1; then
    info "  站点证书已覆盖这些名字且离到期还早，不重签：${LOCAL_TLS_CRT}"
    return 0
  fi

  cn="${names%% *}"
  cn="${cn#\*.}"
  info "  签发站点证书（$(printf '%s' "$want" | tr '\n' ' ')）"
  local srv_cnf srv_csr
  srv_cnf="$(mktemp)"
  srv_csr="$(mktemp)"
# 签名走 [x509_ext] 而不是 CSR 里的 [req_ext]：openssl x509 -req 默认不把 CSR 的
# 请求扩展带进证书，只签 req_ext 会得到一张只有 SAN、没有 basicConstraints/EKU
# 的证书——openssl verify -purpose sslserver 不通过，部分客户端也直接拒。
# 注意这段是无引号 heredoc：内容里出现反引号或 \$( ) 就是让 shell 现场执行它。
  {
    cat <<EOF
[req]
distinguished_name = dn
req_extensions     = req_ext
prompt             = no

[dn]
O  = lnmp
CN = ${cn}

[req_ext]
subjectAltName = @alt_names

[x509_ext]
basicConstraints     = critical,CA:FALSE
keyUsage             = critical,digitalSignature,keyEncipherment
extendedKeyUsage     = serverAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
subjectAltName       = @alt_names

[alt_names]
EOF
    tls_san_list "$names" | tls_alt_names
  } > "$srv_cnf"

  ( umask 077
    openssl req -new -newkey rsa:2048 -sha256 -nodes \
      -keyout "$LOCAL_TLS_KEY" -out "$srv_csr" -config "$srv_cnf"
    openssl x509 -req -sha256 -days 825 -in "$srv_csr" \
      -CA "$LOCAL_TLS_CA" -CAkey "$LOCAL_TLS_CA_KEY" -CAcreateserial -CAserial "$serial" \
      -extfile "$srv_cnf" -extensions x509_ext -out "$LOCAL_TLS_CRT" ) >/dev/null 2>&1 \
    || { rm -f "$srv_cnf" "$srv_csr"; die "生成本地站点证书失败（openssl req/x509）"; }
  rm -f "$srv_cnf" "$srv_csr"
  chmod 600 "$LOCAL_TLS_KEY"
  chmod 644 "$LOCAL_TLS_CRT" "$serial"
  info "  已生成 ${LOCAL_TLS_CRT}（825 天）；设备侧导入 ${LOCAL_TLS_CA} 即可无告警用 https"
}

# 本地测试站点：443 + 上述证书。放独立文件而不是往 default.conf 里加 listen，
# 是因为 default.conf 已存在就保留（不吃用户改动），加了也只在新建站点时生效。
gen_local_tls_vhost() {  # gen_local_tls_vhost <conf.d 目录> <名字列表> <站点根> <include...>
  local confd="$1" names="$2" html_root="$3" inc_upload="$4" inc_php="$5" f
  f="$confd/local-tls.conf"
  if [[ -f $f ]]; then
    info "  conf.d/local-tls.conf 已存在，保留（名字改了要改这份文件里的 server_name）"
    return 0
  fi
  cat > "$f" <<EOF
# 由 lnmp 安装器生成：本地测试 HTTPS（自签 CA，SAN=${names// /, }）
# 只在证书覆盖到的名字上生效；公网域名仍由各自的站点处理。
# 用 IP 直接访问（https://127.0.0.1/）时浏览器不发 SNI，nginx 只能按"该端口的
# 默认服务器"选证书——本文件在 conf.d 里排在 xqkeji.cn.conf 之前，所以默认就是它；
# 若你自己的站点写了 default_server，那条规则归你的站点，这里刻意不声明，
# 免得两处 default_server 撞成 nginx -t 报错（duplicate default server）。
# enforcing SELinux 下 nginx 读不到本证书时，日志是 Permission denied 而不是
# 语法错误：chcon -Rt cert_t ${LOCAL_TLS_DIR}
server {
    listen 443 ssl;
    server_name ${names};

    root   ${html_root};
    index  index.php index.html;

    ssl_certificate     ${LOCAL_TLS_CRT};
    ssl_certificate_key ${LOCAL_TLS_KEY};
    ssl_protocols TLSv1.2 TLSv1.3;
    # zone 名不能和 xqkeji.cn.conf 里的 shared:SSL 重名又给不同大小，那样 nginx -t 报错
    ssl_session_cache   shared:LocalTLS:10m;
    ssl_session_timeout 1d;

    location / {
        try_files \$uri \$uri/ =404;
    }

    # 上传目录禁执行 + PHP 转发（顺序不能换：guard 必须在 \.php 之前）
    include ${inc_upload};
    include ${inc_php};
}
EOF
  info "  已生成 conf.d/local-tls.conf（https://localhost 等名字走本地证书）"
}

step_nginx_conf() {
  step "生成 nginx 配置"

  # 按路线决定路径与属主
  local route="${CFG_nginx_install:-apt}"
  local etc="$NGINX_ETC" html_root="/usr/share/nginx/html" fcgi="/etc/nginx/fastcgi_params"
  local lm="$NGINX_MODULES/ngx_http_acme_module.so" acme_user=nginx
  local snippets="$NGINX_SNIPPETS" nginx_bin=""
  if [[ $route == src ]]; then
    etc="$PREFIX_NGINX/conf"; html_root="$PREFIX_NGINX/html"
    fcgi="$PREFIX_NGINX/conf/fastcgi_params"; lm="modules/ngx_http_acme_module.so"; acme_user=www-data
    snippets="$etc/snippets"
  fi
  # include 用绝对路径：相对路径按 nginx 的 prefix 解析，src 路线的 prefix
  # 与 conf 目录不同名，写相对会在错误的目录下找不到片段文件。
  local inc_upload="$snippets/lnmp-upload-guard.conf"
  local inc_php="$snippets/lnmp-php.conf"
  if [[ $route == src ]]; then
    nginx_bin="$PREFIX_NGINX/sbin/nginx"
  else
    nginx_bin="$(command -v nginx || true)"
  fi

  mkdir -p "$etc/conf.d"
  gen_snippets "$snippets" "$fcgi"

  # --- 主配置：仅 src 路线且文件不存在时生成骨架；apt 路线用包自带的 ---------
  if [[ $route == src && ! -f $etc/nginx.conf ]]; then
    cat > "$etc/nginx.conf" <<EOF
# 由 lnmp 安装器生成
user  www-data;
worker_processes  auto;

error_log  /var/log/nginx/error.log warn;
pid        /run/nginx.pid;

events {
    worker_connections  1024;
}

http {
    include       $etc/mime.types;
    default_type  application/octet-stream;

    sendfile        on;
    keepalive_timeout  65;

    include $etc/conf.d/*.conf;
}
EOF
  elif [[ $route == src ]]; then
    info "  nginx.conf 已存在，保留"
  else
    info "  apt 路线：nginx.conf 由 nginx.org 包提供，保留"
  fi

  # --- 保证 http 块 include conf.d/*.conf ----------------------------------
  # src 路线的 nginx.conf 若是 make install 生成的官方原版（http 块里没有
  # conf.d include），直接放 conf.d 文件不会生效，须在 http { 后补一行；
  # apt 包的 nginx.conf 自带该行，grep 守门不会重复注入
  if ! grep -qE '^[[:space:]]*include[[:space:]]+.*conf\.d' "$etc/nginx.conf"; then
    sed -i "0,/^[[:space:]]*http {/s|^[[:space:]]*http {|http {\\n    include $etc/conf.d/*.conf;|" "$etc/nginx.conf"
    info "  已在 http 块开头注入 include conf.d/*.conf"
  fi

  # --- 注入 load_module（ngx_http_acme_module 必须在 events 之前）-----------
  if [[ -n ${CFG_nginx_acme:-} ]]; then
    if ! grep -q "ngx_http_acme_module" "$etc/nginx.conf"; then
      sed -i "/^events {/i load_module $lm;" "$etc/nginx.conf"
      info "  已注入 load_module ngx_http_acme_module（$lm）"
    fi
  fi

  # --- ACME 公共配置（resolver / issuer / 共享内存区）----------------------
  if [[ -n ${CFG_nginx_acme:-} ]]; then
    local contact="${CFG_acme_contact:-admin@xqkeji.cn}"

    # 系统 CA 束路径按家族不同：RHEL/openEuler 用 /etc/pki/tls/certs/ca-bundle.crt，
    # Debian/Ubuntu 用 /etc/ssl/certs/ca-certificates.crt。这里必须给真实存在的路径：
    # 模块对不存在的 ssl_trusted_certificate 文件不是报配置错误，而是直接段错误
    # （实测 Rocky 上 nginx -t 退 139，一点提示都没有），找不到就整条不写。
    local ca="" f
    for f in /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt \
             /etc/ssl/ca-bundle.pem /etc/pki/tls/cert.pem; do
      if [[ -f $f ]]; then ca="$f"; break; fi
    done
    [[ -n $ca ]] || warn "  未找到系统 CA 束，acme 配置不写 ssl_trusted_certificate（由模块用内置默认）"
    # 找不到就别写这行：写成 `ssl_trusted_certificate ;` 是语法错误
    local ca_line=""
    if [[ -n $ca ]]; then ca_line="    ssl_trusted_certificate ${ca};"; fi

    if [[ ! -f $etc/conf.d/acme.conf ]]; then
      cat > "$etc/conf.d/acme.conf" <<EOF
# 由 lnmp 安装器生成（ngx_http_acme_module 公共配置）
# 自动从 Let's Encrypt 申请/续期证书，无需 certbot
resolver 8.8.8.8 1.1.1.1 valid=300s ipv6=off;

acme_issuer letsencrypt {
    uri https://acme-v02.api.letsencrypt.org/directory;
    contact mailto:${contact};
    # 账户密钥 / 已签发证书 / 私钥都落这里，重启也不丢；属主须为 ${acme_user}
    state_path /var/cache/nginx/acme;
    accept_terms_of_service;
${ca_line}
}

acme_shared_zone zone=ngx_acme_shared:1M;
EOF
      info "  已生成 conf.d/acme.conf（联系邮箱 ${contact}，CA 束 ${ca:-未指定}）"
    else
      # 早期版本按 Debian 路径写死了 ssl_trusted_certificate，在非 Debian 机器上
      # 那个文件不存在，nginx 起不来（段错误）。已存在的配置不覆盖，但这一行必须修
      local bad
      bad="$(sed -n 's|^[[:space:]]*ssl_trusted_certificate[[:space:]]\{1,\}\([^;]*\);.*|\1|p' "$etc/conf.d/acme.conf" | head -1)"
      if [[ -n $bad && ! -f $bad ]]; then
        if [[ -n $ca ]]; then
          sed -i "s|ssl_trusted_certificate[[:space:]]*${bad};|ssl_trusted_certificate ${ca};|" "$etc/conf.d/acme.conf"
          warn "  acme.conf 的 ssl_trusted_certificate 指向不存在的 ${bad}（会让 nginx 段错误），已改为 ${ca}"
        else
          sed -i "/ssl_trusted_certificate ${bad};/d" "$etc/conf.d/acme.conf"
          warn "  acme.conf 的 ssl_trusted_certificate 指向不存在的 ${bad}（会让 nginx 段错误），已删掉该行"
        fi
      fi
      info "  conf.d/acme.conf 已存在，保留"
    fi

    # state 目录：模块运行时写证书/私钥，须 ${acme_user} 可写
    mkdir -p /var/cache/nginx/acme
    chown -R "${acme_user}:${acme_user}" /var/cache/nginx/acme 2>/dev/null || true
  fi

  # --- 默认站点（localhost）------------------------------------------------
  if [[ ! -f $etc/conf.d/default.conf ]]; then
    cat > "$etc/conf.d/default.conf" <<EOF
server {
    listen       ${PORT_NGINX};
    server_name  localhost;

    root   ${html_root};
    index  index.php index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }

    # 上传目录禁执行 + 转发给本机 php-fpm（两段公共配置在 snippets/ 里，顺序不能换）
    include ${inc_upload};
    include ${inc_php};
}
EOF
  else
    info "  conf.d/default.conf 已存在，保留（稍后按 server 块自动注入上传防护）"
  fi

  # --- xqkeji.cn / www.xqkeji.cn 自动 HTTPS（HTTP-01）---------------------
  if [[ -n ${CFG_nginx_acme:-} ]]; then
    if [[ ! -f $etc/conf.d/xqkeji.cn.conf ]]; then
      cat > "$etc/conf.d/xqkeji.cn.conf" <<EOF
# 由 lnmp 安装器生成：xqkeji.cn + www.xqkeji.cn 自动 HTTPS（ngx_http_acme_module）
# HTTP-01：ACME 挑战由模块自动响应；其余路径 301 跳转 HTTPS
server {
    listen 80;
    server_name xqkeji.cn www.xqkeji.cn;

    # 留空即可，ngx_http_acme_module 会在此路径注入 ACME 挑战响应
    location /.well-known/acme-challenge/ {
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name xqkeji.cn www.xqkeji.cn;

    root   ${html_root};
    index  index.html index.php;

    # 由模块向 Let's Encrypt 自动申请并续期；标识名取自上面的 server_name
    acme_certificate letsencrypt;
    ssl_certificate     \$acme_certificate;
    ssl_certificate_key \$acme_certificate_key;
    ssl_certificate_cache max=2;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    location / {
        try_files \$uri \$uri/ =404;
    }

    # 上传目录禁执行 + PHP 转发（公共片段，顺序不能换：guard 必须在 \.php 之前）
    include ${inc_upload};
    include ${inc_php};
}
EOF
      info "  已生成 conf.d/xqkeji.cn.conf（xqkeji.cn / www.xqkeji.cn 自动 HTTPS）"
    else
      info "  conf.d/xqkeji.cn.conf 已存在，保留（稍后按 server 块自动注入上传防护）"
    fi
  fi

  # --- 本地测试 HTTPS（localhost / 127.0.0.1 / *.xqkeji.dev 之类）----------
  # 与 acme 那套公网 HTTPS 互不影响：这份只按 local_tls_names 命中，不声明
  # default_server，公网域名的请求不会被它截走。
  if [[ -n ${CFG_local_tls_names:-} ]]; then
    local tls_names
    tls_names="$(local_tls_names)"
    gen_local_tls "$tls_names"
    gen_local_tls_vhost "$etc/conf.d" "$tls_names" "$html_root" "$inc_upload" "$inc_php"
  fi

  # --- 给已存在的站点补上传防护 --------------------------------------------
  # 只在"基线配置本来就能通过 nginx -t"的前提下动手：本来就有语法问题的配置
  # 不去碰，免得把别人的故障算成这次注入的，也避免覆盖掉一个能跑的旧配置。
  # 找不到 nginx 可执行文件时（apt 路线上包还没装）照样注入：片段已经落盘，
  # 站点漏了 guard 就是漏了防护，只是改动当场没法校验，所以明确提示补跑。
  local no_nginx=0 skip_inject=0 rc=0
  if [[ -z $nginx_bin || ! -x $nginx_bin ]]; then
    no_nginx=1
    warn "  找不到可执行的 nginx（${nginx_bin:-未找到}），本次注入无法用 nginx -t 校验"
  else
    nginx_conf_test "$nginx_bin" || rc=$?
    if (( rc == 1 )); then
      skip_inject=1
      warn "  当前 nginx 配置本身就通不过 nginx -t，本次跳过上传防护注入（先修好配置再重跑本脚本）"
    fi
  fi

  if (( ! skip_inject )); then
    _PATCHED_FILES=""
    patch_existing_vhosts "$etc/conf.d" "$inc_upload"
    if [[ -z ${_PATCHED_FILES// /} ]]; then
      info "  现存站点无需注入（已含上传防护，或本来不含 PHP location）"
    elif (( no_nginx )); then
      warn "  已注入上传防护但未校验：nginx 可用后重跑 sudo ${ROOT_DIR}/scripts/80-nginx-conf.sh 自检"
    elif nginx_conf_test "$nginx_bin"; then
      info "  已对现存站点启用上传目录禁执行 PHP（nginx -t 通过）"
    else
      # 注入让配置语法不过了：逐个用 .bak-lnmp 还原，别留半坏的文件
      local bf
      for bf in $_PATCHED_FILES; do
        if [[ -f "$bf.bak-lnmp" ]]; then
          mv -f "$bf.bak-lnmp" "$bf"
          warn "  已回滚 $(basename "$bf")（用 .bak-lnmp 备份还原）"
        fi
      done
      die "注入上传防护后 nginx -t 失败，已改动的站点文件全部回滚；请检查这些文件里 php location 的写法，修好再重跑 sudo ${ROOT_DIR}/scripts/80-nginx-conf.sh"
    fi
  fi

  info "  nginx 配置就绪"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  bootstrap
  step_nginx_conf
fi
