#!/usr/bin/env bash
# ============================================================================
# scripts/90-systemd.sh - systemd 单元文件 + 服务启动
#
# step_systemd  写单元文件、daemon-reload、设为开机自启
# step_start    拉起 mongod / php-fpm / nginx
#
# 容器里通常没有 systemd，两步都会自动跳过，手动用二进制启动即可。
#
# 单独执行：sudo ./scripts/90-systemd.sh
# ============================================================================

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
source "$LIB_DIR/config.sh"
source "$LIB_DIR/preflight.sh"
source "$LIB_DIR/service.sh"

step_systemd() {
  step "生成 systemd 单元"

  if ! have_systemd; then
    warn "  未检测到 systemd，跳过单元文件（可用各组件二进制直接启动）"
    return 0
  fi

  # nginx unit：仅源码路线自己写。apt 路线用 nginx.org 包自带的 unit，
  # 若我们也写 /etc/systemd/system/nginx.service 会覆盖它（/etc 优先级更高），
  # 导致 apt 的 nginx 二进制没被用上。
  if [[ ${CFG_nginx_install:-apt} != apt ]]; then
    cat > /etc/systemd/system/nginx.service <<EOF
[Unit]
Description=LNMP nginx
After=network.target remote-fs.target nss-lookup.target

[Service]
Type=forking
PIDFile=/run/nginx.pid
ExecStartPre=${PREFIX_NGINX}/sbin/nginx -t
ExecStart=${PREFIX_NGINX}/sbin/nginx
ExecReload=${PREFIX_NGINX}/sbin/nginx -s reload
ExecStop=${PREFIX_NGINX}/sbin/nginx -s quit
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
  fi

  cat > /etc/systemd/system/php-fpm.service <<EOF
[Unit]
Description=LNMP PHP-FPM
After=network.target

[Service]
Type=simple
PIDFile=/run/php-fpm.pid
ExecStart=${PREFIX_PHP}/sbin/php-fpm --nodaemonize --fpm-config ${PREFIX_PHP}/etc/php-fpm.conf
ExecReload=/bin/kill -USR2 \$MAINPID

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/mongod.service <<EOF
[Unit]
Description=LNMP MongoDB
After=network.target

[Service]
Type=forking
User=mongodb
PIDFile=${PREFIX_MONGODB}/data/mongod.pid
ExecStart=${PREFIX_MONGODB}/bin/mongod --config ${PREFIX_MONGODB}/mongod.conf

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload 2>/dev/null \
    || warn "  systemctl daemon-reload 失败（容器里 systemd 非 PID1？跳过），单元文件已写入"
  enable_boot_services

  # RHEL 家族（Rocky/openEuler 等）两个不影响安装、但影响外部访问的点：
  if os_is_rhel; then
    # 本套组件二进制在 /usr/local，systemd 拉起后走 unconfined 域，Enforcing
    # 一般不拦；真遇到 Permission denied 先 setenforce 0 验证再考虑写策略
    if command -v getenforce >/dev/null 2>&1 && [[ $(getenforce) == Enforcing ]]; then
      warn "  SELinux 为 Enforcing：服务异常时先用 getenforce/setenforce 排查是否策略拦截"
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
      warn "  firewalld 在运行：对外提供 HTTP 需放行：firewall-cmd --permanent --add-service=http --add-service=https && firewall-cmd --reload（27017 建议不对外开放）"
    fi
  fi

  info "  systemd 单元已生成"
}

# mongod 比较娇贵：先清掉可能残留的孤儿进程 / 修正数据目录属主 / 清陈旧锁，
# 再起。逻辑见 lib/service.sh 的 start_mongod_safe（账号恢复流程可能以 root
# 起过实例，导致数据目录属主变 root，systemd 用户启动会 Permission denied）。

step_start() {
  if ! have_systemd; then
    warn "无 systemd，跳过启动"
    return 0
  fi

  step "启动服务"
  # nginx / php-fpm 重启失败仅告警，不阻断整体安装
  systemctl restart nginx  2>/dev/null || warn "  nginx 重启失败，请检查：systemctl status nginx"
  systemctl restart php-fpm 2>/dev/null || warn "  php-fpm 重启失败，请检查：systemctl status php-fpm"
  # mongod 单独处理（清孤儿 / 陈旧锁后启动），失败也只告警不中止
  start_mongod_safe \
    || warn "  mongod 启动失败，请检查：journalctl -xeu mongod.service"
  info "  服务已启动"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  bootstrap
  case "${1:-all}" in
    all)    step_systemd; step_start ;;
    units)  step_systemd ;;
    start)  step_start ;;
    *)      die "用法：$0 [all|units|start]" ;;
  esac
fi
