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

# 把 config.ini 的 upload_dirs 拼成正则分支（uploads|upload|data…）。
# 目录名只允许常见字符，其它一律丢掉：值要拼进 nginx 正则，不能原样透传。
# 用 read -a 拆而不是裸 ${...} 展开：后者会把值当 glob，配 `upload_dirs=*`
# 就把当前目录的文件名当成目录名拼进正则了。
upload_dirs_regex() {
  local -a list=()
  local d out=""
  read -r -a list <<<"${CFG_upload_dirs:-uploads upload data tmp files}"
  for d in "${list[@]}"; do
    [[ $d =~ ^[A-Za-z0-9_.-]+$ ]] || { warn "  upload_dirs 里 ${d} 含非法字符，已忽略"; continue; }
    out+="${out:+|}${d//./\\.}"
  done
  [[ -n $out ]] || out="uploads|upload|data|tmp|files"
  printf '%s' "$out"
}

gen_snippets() {  # gen_snippets <snippets 目录> <fastcgi_params 路径>
  local dir="$1" fcgi="$2" dirs
  dirs="$(upload_dirs_regex)"
  mkdir -p "$dir"

  cat > "$dir/lnmp-upload-guard.conf" <<EOF
# 由 lnmp 安装器生成（重跑会覆盖，请勿手改；要改目录名改 config.ini 的 upload_dirs）
# 上传/可写目录里的脚本文件一律不交给 php-fpm。命中即 404，不透露"这里有什么"。
# 覆盖任意层级与 path info：/uploads/x.php、/a/upload/x.php、/uploads/shell.jpg/x.php
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
    # 请求的 .php 必须真实存在，否则 404。少了这一行，/uploads/shell.jpg/nonexistent.php
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
