#!/usr/bin/env bash
# ============================================================================
# scripts/80-nginx-conf.sh - 生成 nginx 主配置与默认站点
#
# 只写骨架：文件已存在就保留，不吃掉用户改动。
# 负责 ngx_http_acme_module 的接入：
#   - 在 nginx.conf 注入 load_module（main 上下文，events 之前）
#   - 生成 conf.d/acme.conf：resolver + acme_issuer + acme_shared_zone
#   - 生成 conf.d/xqkeji.cn.conf：xqkeji.cn / www.xqkeji.cn 的自动 HTTPS
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

step_nginx_conf() {
  step "生成 nginx 配置"

  # 按路线决定路径与属主
  local route="${CFG_nginx_install:-apt}"
  local etc="$NGINX_ETC" html_root="/usr/share/nginx/html" fcgi="/etc/nginx/fastcgi_params"
  local lm="$NGINX_MODULES/ngx_http_acme_module.so" acme_user=nginx
  if [[ $route == src ]]; then
    etc="$PREFIX_NGINX/conf"; html_root="$PREFIX_NGINX/html"
    fcgi="$PREFIX_NGINX/conf/fastcgi_params"; lm="modules/ngx_http_acme_module.so"; acme_user=www-data
  fi

  mkdir -p "$etc/conf.d"

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

    # 转发给本机 php-fpm 默认端口
    location ~ \.php\$ {
        fastcgi_pass   127.0.0.1:${PORT_PHP_FPM};
        fastcgi_index  index.php;
        fastcgi_param  SCRIPT_FILENAME  \$document_root\$fastcgi_script_name;
        include        ${fcgi};
    }
}
EOF
  else
    info "  conf.d/default.conf 已存在，保留"
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

    location ~ \.php\$ {
        fastcgi_pass   127.0.0.1:${PORT_PHP_FPM};
        fastcgi_index  index.php;
        fastcgi_param  SCRIPT_FILENAME  \$document_root\$fastcgi_script_name;
        include        ${fcgi};
    }
}
EOF
      info "  已生成 conf.d/xqkeji.cn.conf（xqkeji.cn / www.xqkeji.cn 自动 HTTPS）"
    else
      info "  conf.d/xqkeji.cn.conf 已存在，保留"
    fi
  fi

  info "  nginx 配置就绪"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  bootstrap
  step_nginx_conf
fi
