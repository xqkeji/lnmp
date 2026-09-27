#!/usr/bin/env bash
# ============================================================================
# install.sh - 一键构建 LNMP（nginx + MongoDB + PHP-FPM）环境
#
#   支持系统：Debian / Ubuntu（apt 家族）；RHEL / Rocky / Alma / CentOS / openEuler（dnf/yum）
#   组件            安装路径              端口     方式
#   --------------  --------------------  -------  --------------------------
#   nginx           /usr/local/nginx     80       源码编译（默认；config.ini 设 nginx_install=apt 走 nginx.org 包）
#                                              acme 模块源码来自国内 Gitee 镜像（见 config.ini nginx_acme_url）
#                                              apt 路线仅 Debian/Ubuntu；RHEL 家族固定源码编译
#   MongoDB         /usr/local/mongodb   27017    官方预编译 tarball
#   PHP (php-fpm)   /usr/local/php       9000     源码编译（含 gd）
#   ocserv          /usr/local/sbin      4443     官网源码编译（meson；端口见 config.ini）
#   Composer        /usr/local/composer  -        phar
#   PIE             /usr/local/pie       -        phar
#   PHP 扩展        zip / mongodb（PIE） + xqkeji（预编译 .so）
#
# 代码结构（本文件只负责编排，活都在 scripts/ 下）：
#   install.sh             主入口
#   config.ini             所有版本号，改这里即可升级
#   lib/common.sh          常量、日志、下载、幂等状态
#   lib/os.sh              发行版探测 + apt/dnf 包管理抽象
#   lib/config.sh          读 config.ini（键名白名单，不 eval）
#   lib/preflight.sh       环境预检
#   lib/service.sh         服务启停控制（systemd / 无 systemd 双路径）
#   scripts/00-deps.sh     系统依赖库（apt/dnf 包名表），按 nginx / php / mongodb 分组
#   scripts/10-nginx.sh    nginx：apt 安装（默认）/ 源码编译
#   scripts/20-mongodb.sh  MongoDB + mongosh：下载 + 部署 + 账号初始化
#   scripts/30-php.sh      PHP：下载 + 编译
#   scripts/40-composer.sh Composer
#   scripts/50-pie.sh      PIE
#   scripts/60-php-exts.sh PHP 扩展（PIE）
#   scripts/70-xqkeji.sh   xqkeji 扩展
#   scripts/75-ocserv.sh   ocserv SSL VPN（下载 + meson 编译 + 配置/账号/证书）
#   scripts/80-nginx-conf.sh nginx 配置骨架
#   scripts/90-systemd.sh  systemd 单元 + 启动
#   scripts/99-verify.sh   结果自检
#   ctrl.sh                服务管理：start/stop/restart/status（仓库根目录）
#
# 设计约定：
#   1. 幂等：版本记在 /usr/local/lnmp/state/<名>.version，重复执行自动跳过
#   2. 不 eval 配置：ini 键名走白名单，值只做赋值
#   3. 有 sha256 就校验，没填就跳过
#   4. 每个 scripts/*.sh 都能单独 sudo 执行
# ============================================================================

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
source "$LIB_DIR/config.sh"
source "$LIB_DIR/preflight.sh"
source "$LIB_DIR/service.sh"

# ---------------------------------------------------------------------------
# 步骤清单：别名 -> 入口函数（数组顺序即执行顺序）
# ---------------------------------------------------------------------------
readonly STEP_ALIASES=(deps nginx mongodb mongosh php composer pie phpext xqkeji ocserv nginxconf systemd start mongoinit verify)

declare -A STEP_FUNCS=(
  [deps]=step_deps
  [nginx]=step_nginx
  [mongodb]=step_mongodb
  [mongosh]=step_mongosh
  [php]=step_php
  [composer]=step_composer
  [pie]=step_pie
  [phpext]=step_php_exts
  [xqkeji]=step_xqkeji
  [ocserv]=step_ocserv
  [nginxconf]=step_nginx_conf
  [systemd]=step_systemd
  [start]=step_start
  [mongoinit]=init_mongodb
  [verify]=step_verify
)

declare -A STEP_DESC=(
  [deps]="系统依赖库（apt/dnf）"
  [nginx]="nginx（按 nginx_install：源码编译+acme 模块 / 官方仓库包）"
  [mongodb]="MongoDB（下载 + 部署）"
  [mongosh]="mongosh 命令行客户端"
  [php]="PHP-FPM（下载 + 编译）"
  [composer]="Composer"
  [pie]="PIE"
  [phpext]="PHP 扩展 zip/mongodb（PIE）"
  [xqkeji]="xqkeji 扩展"
  [ocserv]="ocserv SSL VPN（官网源码编译 + 配置 + 账号）"
  [nginxconf]="nginx 主配置 + 默认站点"
  [systemd]="systemd 单元 + 开机自启"
  [start]="启动全部服务"
  [mongoinit]="MongoDB 账号初始化（root/xqkeji.cn）"
  [verify]="安装结果自检"
)

# --download-only 时按序执行的下载函数（src 路线额外下 nginx 源码与 acme 模块源码；
# 实际列表在 run_download 里按 nginx_install 动态拼装，因为此处解析时配置尚未加载）

# ---------------------------------------------------------------------------
# 加载全部组件脚本（只定义函数，不执行）
# ---------------------------------------------------------------------------
load_steps() {
  local f
  for f in "$STEPS_DIR"/*.sh; do
    [[ -r $f ]] || continue
    # shellcheck disable=SC1090
    source "$f"
  done
}

usage() {
  cat <<EOF
用法：sudo ./install.sh [选项] [组件...]

不加参数 = 全量安装。指定组件时按依赖顺序执行，且只跑你点的那几个。

选项：
  --check            只做环境预检，不安装
  --download-only    只下载源码包（校验 sha256），不编译不安装
  --only=<组件>      只装指定组件，等价于直接写组件名
  --list             列出可单独安装的组件
  -h, --help         显示本帮助

示例：
  sudo ./install.sh                      全量安装
  sudo ./install.sh nginx php            只装 nginx 和 PHP（会自动补对应系统依赖）
  sudo ./install.sh --only=mongodb       只装 MongoDB
  sudo ./install.sh --download-only      先把包下齐，之后离线再装
  sudo ./install.sh --check              只体检

也可以绕开主入口，直接跑单个组件脚本：
  sudo ./scripts/30-php.sh
  sudo ./scripts/00-deps.sh php          只装 PHP 的编译依赖

配置文件：config.ini（所有版本号都在里面）
EOF
}

list_steps() {
  printf '可单独安装的组件（按依赖顺序）：\n'
  local a
  for a in "${STEP_ALIASES[@]}"; do
    printf '  %-10s %s\n' "$a" "${STEP_DESC[$a]}"
  done
  printf '\n也可以直接执行 scripts/ 下的对应脚本。\n'
}

# 按 STEP_ALIASES 的顺序执行指定别名（传空 = 全部）
run_steps() {
  local -a wanted=("$@")
  local a w all=0
  ((${#wanted[@]})) || all=1

  for a in "${STEP_ALIASES[@]}"; do
    if ((all)); then
      step ">>> ${STEP_DESC[$a]}"
      "${STEP_FUNCS[$a]}"
      continue
    fi
    for w in "${wanted[@]}"; do
      if [[ $w == "$a" ]]; then
        step ">>> ${STEP_DESC[$a]}"
        "${STEP_FUNCS[$a]}"
      fi
    done
  done

  # 兜底：确保已安装的服务开机自启。覆盖选装模式（如只装 nginx）未显式跑
  # systemd 步骤的情况；幂等，与 step_systemd 内的 enable 不冲突。
  enable_boot_services
}

run_download() {
  local -a funcs=(
    fetch_mongodb fetch_mongosh fetch_php
    fetch_composer fetch_pie fetch_xqkeji fetch_ocserv
  )
  [[ ${CFG_nginx_install:-apt} == src ]] && funcs+=(fetch_nginx fetch_nginx_acme)
  local fn
  for fn in "${funcs[@]}"; do
    "$fn"
  done
  info "全部源码包已下载到 $SRC_DIR"
}

main() {
  local -a wanted=()
  local mode=all

  while (($#)); do
    case "$1" in
      -h | --help)        usage; exit 0 ;;
      --check)            mode=check; shift ;;
      --list)             list_steps; exit 0 ;;
      --download-only)    mode=download; shift ;;
      --only=*)           wanted+=("${1#--only=}"); mode=select; shift ;;
      -*)                 die "未知参数：$1（用 --help 查看用法）" ;;
      *)                  wanted+=("$1"); mode=select; shift ;;
    esac
  done

  init_log
  load_steps

  # --list 在解析阶段已处理；这里开始需要配置
  load_config
  JOBS="${CFG_jobs:-$(nproc 2>/dev/null || echo 2)}"

  info "=============================================================================="
  info "LNMP 安装开始：nginx ${CFG_nginx} / mongodb ${CFG_mongodb} / php ${CFG_php}"
  info "=============================================================================="

  preflight

  case "$mode" in
    check)
      require_avx
      require_ports "$PORT_NGINX" "$PORT_PHP_FPM" "$PORT_MONGODB"
      require_disk
      info "--check 模式：预检通过，不执行安装"
      exit 0
      ;;
    download)
      run_download
      exit 0
      ;;
    all)
      require_avx
      require_ports "$PORT_NGINX" "$PORT_PHP_FPM" "$PORT_MONGODB"
      require_disk
      run_steps
      ;;
    select)
      local w
      for w in "${wanted[@]}"; do
        [[ -n ${STEP_FUNCS[$w]:-} ]] || die "未知组件：$w（用 --list 查看可选组件）"
      done
      # 最小必要预检：root/系统/架构必查；AVX 仅选 MongoDB 时查；
      # 端口只查所选组件用到的；磁盘始终查
      preflight
      for w in "${wanted[@]}"; do
        [[ $w == mongodb || $w == mongosh ]] && { require_avx; break; }
      done
      local -a ports=()
      for w in "${wanted[@]}"; do
        case "$w" in
          nginx)              ports+=(80) ;;
          php)                ports+=(9000) ;;
          mongodb | mongosh)  ports+=(27017) ;;
          ocserv)             ports+=("${CFG_ocserv_port:-4443}") ;;
        esac
      done
      ((${#ports[@]})) && require_ports "${ports[@]}"
      require_disk
      run_steps "${wanted[@]}"
      ;;
  esac
}

main "$@"
