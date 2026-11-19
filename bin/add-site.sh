#!/usr/bin/env bash
# ============================================================================
# bin/add-site.sh - 为已有项目登记一个站点：nginx 虚拟主机 + 重载 nginx
#
# 域名交互选择（与 dnmmp 的 bin/add-site.sh 对等）：
#   - 回车用默认 <name>.xqkeji.dev：命中 config.ini 的 local_tls_names 名单时
#     走本地测试证书（80-nginx-conf.sh 已生成，无需重签）+ /etc/hosts 解析；
#   - 其它域名：ngx_http_acme_module 自动签发/续期 Let's Encrypt 证书
#     （复用 conf.d/acme.conf，不写 hosts）。
#
# 项目结构参照 dnmmp：默认项目目录 www/<name>，站点入口 <项目目录>/www
# （必须已存在，否则报错且不写任何配置）。与 dnmmp 不同的是本机为原生安装、
# 没有容器挂载限制，第二个参数可以指定任意位置的项目目录。
#
# 前提：
#   - 本地路径：local_tls_names 非空且本地测试证书已生成；
#   - 公网路径：nginx_acme 非空、80-nginx-conf.sh 已跑过（load_module 与
#     conf.d/acme.conf 就绪）、域名 DNS A 记录指向本机公网 IP（防火墙已放行
#     80/443，HTTP-01 验证走 80）。
#
# 幂等：conf.d/<name>.conf 已存在就不覆盖（可能已被手工改过）；域名已被别的
# 虚拟主机 server_name 占用就不再抢；hosts 里已解析该域名就不再追加。
# nginx -t 失败会删掉刚生成的配置，原有站点不受影响。全程不碰 default.conf
# 与任何已存在的文件，也不声明 default_server：无 SNI 的 IP 访问
# （https://127.0.0.1/）归 conf.d 字母序最前的 443 站点（lnmp 现有约定）。
#
# 单独执行：sudo ./bin/add-site.sh <name> [project-dir]
# 非交互环境（钩子/管道）不提问直接用默认域名；ADD_SITE_DOMAIN 可显式指定。
# ============================================================================

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
source "$LIB_DIR/config.sh"

readonly DOMAIN_SUFFIX=xqkeji.dev
# 本次运行新生成的文件；nginx -t 失败时全部删掉，不留半成品
CREATED_FILES=()
# 便于测试/非标准系统覆盖
HOSTS_FILE=${HOSTS_FILE:-/etc/hosts}

usage() {
  cat >&2 <<'EOF'
用法：sudo ./bin/add-site.sh <name> [project-dir]
      默认项目目录 <仓库根>/www/<name>，站点入口 <项目目录>/www（须已存在）
      域名交互选择：默认 <name>.xqkeji.dev（本地测试证书 + hosts），
      其它域名用 ACME 模块自动签发 Let's Encrypt 证书（需公网 DNS 与 80 端口）
      例：sudo ./bin/add-site.sh crm
EOF
  exit 1
}

init_log
[[ $# -ge 1 ]] || usage
NAME=$1
[[ $NAME =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] || die "站点名只能包含字母、数字和连字符，且以字母或数字开头：$NAME"

load_config
# 只检查本脚本关心的项（见 lib/preflight.sh 头部）：root + 配置。
# 不装包，不做发行版/端口/架构预检。
[[ $EUID -eq 0 ]] || die "请以 root 执行：sudo $0"

# 路径按 nginx 安装路线取（与 80-nginx-conf.sh 的 step_nginx_conf 一致）
route="${CFG_nginx_install:-apt}"
if [[ $route == src ]]; then
  ETC="$PREFIX_NGINX/conf"
  SNIPPETS="$ETC/snippets"
  NGINX_BIN="$PREFIX_NGINX/sbin/nginx"
else
  ETC="$NGINX_ETC"
  SNIPPETS="$NGINX_SNIPPETS"
  NGINX_BIN="$(command -v nginx || true)"
fi
readonly CONFD="$ETC/conf.d"
readonly INC_UPLOAD="$SNIPPETS/lnmp-upload-guard.conf"
readonly INC_PHP="$SNIPPETS/lnmp-php.conf"
[[ -d $CONFD ]] || die "缺少 $CONFD，请先运行 sudo ./install.sh（或 sudo ./scripts/80-nginx-conf.sh）"
[[ -f $INC_UPLOAD && -f $INC_PHP ]] || die "缺少公共片段 $INC_UPLOAD / $INC_PHP，请先运行 sudo ./scripts/80-nginx-conf.sh"

PROJ_ARG=${2:-$ROOT_DIR/www/$NAME}
[[ -d $PROJ_ARG ]] || die "找不到项目目录：$PROJ_ARG（请先把项目创建好，或用第二个参数指定）"
PROJ=$(cd -- "$PROJ_ARG" && pwd)
readonly DOCROOT="$PROJ/www"
[[ -d $DOCROOT ]] || die "找不到站点入口目录：$DOCROOT（结构参照 dnmmp：<项目目录>/www）"

readonly CONF="$CONFD/$NAME.conf"

# 域名交互：默认本地域名走本地证书+hosts；其它域名走 ACME。
# 非交互（钩子/管道）不提问直接用默认；ADD_SITE_DOMAIN 可显式指定。
if [[ -n ${ADD_SITE_DOMAIN:-} ]]; then
  DOMAIN=$ADD_SITE_DOMAIN
elif [[ -t 0 ]]; then
  read -r -p "站点域名 [$NAME.$DOMAIN_SUFFIX]（回车用默认；其它域名将用 ACME 自动签发证书）: " DOMAIN || DOMAIN=
  DOMAIN=${DOMAIN:-$NAME.$DOMAIN_SUFFIX}
else
  DOMAIN="$NAME.$DOMAIN_SUFFIX"
  info "非交互环境，使用默认域名 $DOMAIN"
fi
DOMAIN=$(printf '%s' "$DOMAIN" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
[[ $DOMAIN =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]] \
  || die "域名格式不正确：$DOMAIN"

# 本地判定按实际 local_tls_names 名单（可配、可留空关闭）：精确命中或一级
# 通配命中。用 read -a 拆而不是裸展开：后者会把 *.xqkeji.dev 当 glob。
# 注意 *.xqkeji.dev 不含主域 xqkeji.dev 本身（与 80-nginx-conf.sh 同语义）。
LOCAL_MODE=
if [[ -n ${CFG_local_tls_names:-} ]]; then
  read -r -a TLS_NAMES <<<"$CFG_local_tls_names"
  for n in "${TLS_NAMES[@]}"; do
    n="${n,,}"
    if [[ $n == "$DOMAIN" ]]; then LOCAL_MODE=1; break; fi
    if [[ $n == \*.* && $DOMAIN == *".${n#\*.}" ]]; then
      label=${DOMAIN%".${n#\*.}"}
      if [[ -n $label && $label != *.* ]]; then LOCAL_MODE=1; break; fi
    fi
  done
fi

if [[ -n $LOCAL_MODE ]]; then
  [[ -s $LOCAL_TLS_CRT && -s $LOCAL_TLS_KEY ]] \
    || die "本地测试证书不存在（$LOCAL_TLS_CRT），请先运行 sudo ./scripts/80-nginx-conf.sh 生成"
  info "添加本地站点：$DOMAIN"
else
  # 占位域名保护：local_tls_names 关闭或不含它时，默认域名不能悄悄走 ACME
  case "$DOMAIN" in
    "$DOMAIN_SUFFIX" | *."$DOMAIN_SUFFIX")
      die "$DOMAIN_SUFFIX 是本地测试占位域名，不能走 ACME 公网签发：在 config.ini 的 local_tls_names 里加上它并重跑 sudo ./scripts/80-nginx-conf.sh，或改用真实公网域名" ;;
  esac
  [[ -n ${CFG_nginx_acme:-} ]] \
    || die "config.ini 的 nginx_acme 为空（ACME 未启用）：填上版本号后重跑 sudo ./scripts/80-nginx-conf.sh"
  [[ -f $CONFD/acme.conf ]] \
    || die "缺少 $CONFD/acme.conf，请先运行 sudo ./scripts/80-nginx-conf.sh 生成 ACME 公共配置"
  grep -q ngx_http_acme_module "$ETC/nginx.conf" \
    || die "nginx.conf 未注入 load_module ngx_http_acme_module，请重跑 sudo ./scripts/80-nginx-conf.sh"
  info "添加公网域名站点：$DOMAIN（ACME 自动签发证书）"
fi

# hosts 里是否已有该域名：按“主机名 token”精确比对，先剥掉注释，
# 再逐个比较一行里的每个名字，所以 othercrm.xqkeji.dev 不算 crm.xqkeji.dev，
# 被注释掉的那行也不算。
hosts_has() {
  [[ -r $HOSTS_FILE ]] || return 1
  awk -v d="$DOMAIN" '
    { sub(/#.*/, "")
      for (i = 2; i <= NF; i++) if (tolower($i) == tolower(d)) found = 1 }
    END { exit !found }' "$HOSTS_FILE"
}

add_hosts() {
  if hosts_has; then
    info "hosts 里已有 $DOMAIN 的解析，不重复添加"
    return 0
  fi
  local text="127.0.0.1 $DOMAIN"
  # 原文件末尾没有换行时先补一个，否则会和最后一行黏在一起
  if [[ -s $HOSTS_FILE && -n $(tail -c1 "$HOSTS_FILE" 2>/dev/null) ]]; then
    text=$'\n'"$text"
  fi
  printf '%s\n' "$text" >> "$HOSTS_FILE"
  info "hosts 已添加：127.0.0.1 $DOMAIN"
}

# 域名是否已被 conf.d 里某个虚拟主机占用：只比 server_name 行的完整 token，
# 子串不算（othercrm.xqkeji.dev 不占用 crm.xqkeji.dev），通配符也不算
# （*.xqkeji.dev 覆盖到的名字仍可新建精确 server 块，nginx 精确名优先）。
domain_claimed() {
  local f
  for f in "$CONFD"/*.conf; do
    [[ -f $f ]] || continue
    if awk -v d="$DOMAIN" '
      /^[[:space:]]*server_name[[:space:]]/ {
        for (i = 2; i <= NF; i++) {
          t = $i; sub(/;$/, "", t)
          if (tolower(t) == tolower(d)) found = 1
        }
      }
      END { exit !found }' "$f"; then
      return 0
    fi
  done
  return 1
}

write_conf() {
  local cert_block challenge_block=""
  if [[ -n $LOCAL_MODE ]]; then
    cert_block="    ssl_certificate     $LOCAL_TLS_CRT;
    ssl_certificate_key $LOCAL_TLS_KEY;"
  else
    cert_block='    acme_certificate letsencrypt;
    ssl_certificate     $acme_certificate;
    ssl_certificate_key $acme_certificate_key;
    ssl_certificate_cache max=2;'
    challenge_block='    # 留空即可，ngx_http_acme_module 会在此路径注入 ACME 挑战响应
    location /.well-known/acme-challenge/ {
    }
'
  fi
  cat > "$CONF" <<EOF
# 由 bin/add-site.sh 生成：$DOMAIN（可自由修改，重跑不会覆盖已存在的文件）
server {
    listen 80;
    server_name $DOMAIN;

$challenge_block    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name $DOMAIN;

    root   $DOCROOT;
    index  index.php index.html;

$cert_block
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    location / {
        try_files \$uri \$uri/ =404;
    }

    # 上传目录禁执行 + PHP 转发（公共片段，顺序不能换：guard 必须在 \.php 之前）
    include $INC_UPLOAD;
    include $INC_PHP;
}
EOF
  CREATED_FILES+=("$CONF")
  info "已生成 $CONF"
}

cleanup_created() {
  local f
  for f in ${CREATED_FILES[@]+"${CREATED_FILES[@]}"}; do
    rm -f "$f"
  done
}

# nginx 可用才自检+重载；找不到可执行文件就留给下次启动，配置照样写好。
reload_nginx() {
  if [[ -z $NGINX_BIN || ! -x $NGINX_BIN ]]; then
    warn "未找到可执行的 nginx（${NGINX_BIN:-未找到}），跳过自检与重载：配置已写好，nginx 可用后执行 sudo ./ctrl.sh restart nginx"
    return 0
  fi
  if ! "$NGINX_BIN" -t; then
    cleanup_created
    die "nginx 自检未通过，已删除刚生成的配置，原有站点未受影响"
  fi
  "$NGINX_BIN" -s reload || { warn "重载失败，请手动执行：$NGINX_BIN -s reload（或 sudo ./ctrl.sh restart nginx）"; return 0; }
  info "已通知 nginx 重新加载配置"
}

SKIP_CONF=
if [[ -e $CONF ]]; then
  info "配置已存在，不覆盖：$CONF"
  SKIP_CONF=1
elif domain_claimed; then
  info "$DOMAIN 已被 conf.d 里其它配置的 server_name 使用，不再重复添加"
  SKIP_CONF=1
fi

if [[ -z $SKIP_CONF ]]; then
  write_conf
  reload_nginx
fi

if [[ -n $LOCAL_MODE ]]; then
  add_hosts
  CERT_NOTE="证书用本地测试 CA（$LOCAL_TLS_CRT），名单已覆盖该域名，无需重签；设备侧导入 $LOCAL_TLS_CA 即可无告警"
else
  info "公网域名不写 hosts：请确保 $DOMAIN 的 DNS A 记录已指向本机公网 IP（防火墙已放行 80/443）"
  CERT_NOTE="证书由 nginx ACME 模块自动向 Let's Encrypt 签发并续期（首次需几秒到几十秒；进度与失败原因见 /var/log/nginx/error.log）"
fi

cat <<EOF

站点目录：$DOCROOT
访问地址：https://$DOMAIN/（http://$DOMAIN/ 自动跳转 https）
$CERT_NOTE
请用域名访问：https://127.0.0.1/ 这类无 SNI 的 IP 访问归 conf.d 字母序最前的 443 站点（本脚本不声明 default_server）
EOF