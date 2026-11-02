#!/usr/bin/env bash
# ============================================================================
# lib/os.sh - 发行版探测 + 包管理器抽象（分发器）
#
# 本文件只做 source 编排，不含实现。实现按家族拆在 lib/os/ 下：
#   lib/os/common.sh   家族无关：detect_os、契约分发、pkg_install 幂等包装
#   lib/os/debian.sh   apt 家族：包管理实现 + 依赖组包名表
#   lib/os/rhel.sh     dnf/yum 家族：包管理实现 + EPEL/CRB + 依赖组包名表
#
# 组件脚本只认 common.sh 给出的对外契约，不直接写 apt-get / dnf：
#   detect_os / os_is_debian / os_is_rhel
#   pkg_update_once / pkg_installed / pkg_install / pkg_install_any
#   pkgs_for <组名> / pkg_enable_extra_repos
#
# detect_os 产出的变量（全项目只认这些）：
#   OS_ID      os-release 的 ID（debian / ubuntu / rocky / openEuler...）
#   OS_FAMILY  debian | rhel | suse | unknown —— 契约函数按它分发
#   OS_MAJOR   主版本号（纯数字，取不到为 0）
#   OS_CODENAME  VERSION_CODENAME（Debian 的 trixie、Ubuntu 的 noble 等）
#   OS_PRETTY  PRETTY_NAME，用于日志展示
#   PKG        apt | dnf | yum | unknown
#
# 新增一个家族：在 lib/os/ 下加 <family>.sh，实现 common.sh 头部列出的 5 个契约
# 函数，再在本文件加一行 source。契约没实现全就调用，die 会直接点名缺哪个函数。
# ============================================================================

[[ -n ${_LNMP_LIB_OS:-} ]] && return 0
readonly _LNMP_LIB_OS=1

# shellcheck disable=SC1091
source "$LIB_DIR/os/common.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/os/debian.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/os/rhel.sh"

