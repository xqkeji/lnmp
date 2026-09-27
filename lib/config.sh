#!/usr/bin/env bash
# ============================================================================
# lib/config.sh - 读取 config.ini，并给子脚本提供 bootstrap 引导
#
# 安全约定：不 eval 配置文件。键名走白名单正则，值只做一次赋值，
# 注入内容最多变成一个普通字符串，不会被二次解析执行。
# ============================================================================

# --- 已加载则跳过（被重复 source 时 readonly 会报错） -----------------------
[[ -n ${_LNMP_LIB_CONFIG:-} ]] && return 0
readonly _LNMP_LIB_CONFIG=1

# 读 config.ini。找不到时兼容旧文件名 lnmp.ini。
load_config() {
  local ini="$ROOT_DIR/$CONFIG_NAME"
  if [[ ! -r $ini && -r "$ROOT_DIR/lnmp.ini" ]]; then
    ini="$ROOT_DIR/lnmp.ini"
  fi
  [[ -r $ini ]] || die "找不到配置文件：$ROOT_DIR/$CONFIG_NAME"

  local line key value
  while IFS= read -r line || [[ -n $line ]]; do
    line="${line%%#*}"                                  # 去注释
    [[ $line =~ ^[[:space:]]*$ ]] && continue           # 跳空行
    [[ $line == *=* ]] || die "配置行不是 key=value 格式：$line"

    key="$(trim "${line%%=*}")"
    value="$(trim "${line#*=}")"

    # 去掉成对引号，让 "a b" 和 a b 都能用
    if [[ ${#value} -ge 2 && ${value:0:1} == "${value: -1}" \
       && ( ${value:0:1} == '"' || ${value:0:1} == "'" ) ]]; then
      value="${value:1:${#value}-2}"
    fi

    # 白名单：只允许小写字母数字下划线，杜绝键名污染环境变量
    [[ $key =~ ^[a-z_][a-z0-9_]*$ ]] || die "非法配置键名：$key"

    # 用 declare 而不是 eval：值不会被再次解析
    declare -g "CFG_${key}=${value}"
  done < "$ini"

  local k v
  for k in nginx mongodb php xqkeji composer pie ocserv; do
    v="CFG_$k"
    [[ -n ${!v:-} ]] || die "$CONFIG_NAME 缺少必需配置：$k"
  done

  info "已读取配置：$ini"
}

# 子脚本单独执行时的引导：建日志 -> 读配置 -> 算并行数 -> 基础预检
bootstrap() {
  init_log
  load_config
  JOBS="${CFG_jobs:-$(nproc 2>/dev/null || echo 2)}"
  preflight
}
