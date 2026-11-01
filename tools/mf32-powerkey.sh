#!/bin/sh
# MF32 电源键语义：双击 = 关机，单击 = 电量 peek，长按 = 交给 PON 硬件兜底
#
# 前提：logind 的 HandlePowerKey 已置 ignore（否则短按会先被 logind 关机）。
# 落地件：/etc/systemd/logind.conf.d/mf32-powerkey.conf（见
# tools/mf32-logind-powerkey.conf）+ tools/mf32-powerkey.service。
#
# 用法：
#   mf32-powerkey.sh monitor    服务主循环（读 evdev，阻塞式）
#   mf32-powerkey.sh simulate   从 stdin 读 "val ts_ms" 行喂状态机（自测）
#
# 状态机（无定时器：pending 状态不在到期时动作，而是靠"第二次按下"推进，
# 单击的 peek 立即触发、双击时由关机路径覆盖，因此永不空转）：
#   press  （pending 且距上次 release ≤ DOUBLE_MS）→ 进入双击武装
#   press  （其余）                                  → 武装单击
#   release 按压时长 > LONG_MS                       → 长按，无动作（PON 兜底）
#   release 双击武装                                 → **关机**
#   release 单击武装                                 → 电量 peek 3s
#
# 可注入：MF32_INPUT_DEV（evdev 节点）、MF32_STATE（状态目录，含 peek_until）。

set -u

INPUT_DEV=${MF32_INPUT_DEV:-auto}
STATE=${MF32_STATE:-/run/mf32}
DEFAULTS=/etc/default/mf32-powerkey

DOUBLE_MS=${DOUBLE_MS:-500}    # 两次按下间隔上限（判定双击）
LONG_MS=${LONG_MS:-1500}       # 超过视为长按（无动作）
CLICK_MS=${CLICK_MS:-800}      # 单击按压时长上限
PEEK_SECS=${PEEK_SECS:-3}      # peek 持续时间（LED 条）

[ -r "$DEFAULTS" ] && . "$DEFAULTS"
mkdir -p "$STATE" 2>/dev/null || true

KEY_POWER=116      # EV_KEY 代码，pwrkey binding：缺省即 KEY_POWER
EV_KEY=1

# ---------------------------------------------------------------- 动作

do_peek() {
    _now=$(date +%s)
    echo $((_now + PEEK_SECS)) > "$STATE/peek_until"
}

do_poweroff() {
    echo 0 > "$STATE/peek_until" 2>/dev/null || true
    # 关机走系统标准路径；logind 已 ignore 电源键，这里显式触发
    systemctl poweroff
}

# ---------------------------------------------------------------- 状态机
# 变量：state=idle|armed|pending|darmed  press_ts / release_ts (ms)

init_state() {
    state=idle; press_ts=0; release_ts=0
}
init_state

handle_key() {  # $1=value(1 press/0 release/2 repeat)  $2=ts_ms
    [ "$1" = 2 ] && return 0          # autorepeat 不参与
    if [ "$1" = 1 ]; then
        if [ "$state" = pending ] && [ $(($2 - release_ts)) -le "$DOUBLE_MS" ]; then
            state=darmed              # 第二次按下：双击武装
        else
            state=armed
        fi
        press_ts=$2
        return 0
    fi
    # release
    _dur=$(($2 - press_ts))
    if [ "$_dur" -gt "$LONG_MS" ]; then
        state=idle                    # 长按：软件不动作，PON 硬复位兜底
    elif [ "$state" = darmed ]; then
        state=idle
        do_poweroff
    elif [ "$state" = armed ] && [ "$_dur" -le "$CLICK_MS" ]; then
        state=pending; release_ts=$2
        do_peek
    else
        state=idle
    fi
    return 0
}

# ---------------------------------------------------------------- evdev 循环

find_pwrkey_dev() {
    for _i in /sys/class/input/input*; do
        [ -r "$_i/name" ] || continue
        grep -q pm8941_pwrkey "$_i/name" 2>/dev/null || continue
        for _e in "$_i"/event*; do
            [ -d "$_e" ] && { basename "$_e"; return 0; }
        done
    done
    return 1
}

open_dev() {
    if [ "$INPUT_DEV" != auto ]; then
        DEV="$INPUT_DEV"
    else
        _name=$(find_pwrkey_dev) || return 1
        DEV="/dev/input/$_name"
    fi
    [ -r "$DEV" ] || return 1
    return 0
}

# evdev 事件 24 字节（arm64 64 位 timeval: 16 + type 2 + code 2 + value 4）。
# 关键：设备只在 cmd_monitor 里 open 一次（fd 3），所有 dd 共享同一个 fd。
# 早期版本每轮 dd if="$DEV" 重新 open，多个 dd 并发读同一 evdev 节点会互相
# 抢事件（实测 ps 可见 2 个 dd + 3 层 fork 的 monitor 子 shell），按键丢失。
# arm64 Linux 的 struct input_event 是 24 字节：
#   struct timeval { __kernel_time64_t tv_sec(8); long tv_usec(8); }
#   __u16 type; __u16 code; __s32 value;
# od -An -tu8 -N24 得到 3 个 64 位数：
#   $1 = tv_sec  $2 = tv_usec
#   $3 = type(低16) | code(<<16) | value(<<32)
# 输出 "type code value ts_ms"（ts_ms 由事件自带时间戳换算，不依赖 date，
# 也避免把 code 误当时间戳——旧版正是在这里把 EV_SYN 当按键，导致按一下即关机）。
read_event() {
    _raw=$(dd bs=24 count=1 <&3 2>/dev/null | od -An -tu8 -N24 2>/dev/null) || return 1
    [ -n "${_raw:-}" ] || return 1
    set -- $_raw
    [ $# -ge 3 ] || return 1
    _sec=$1; _usec=$2; _packed=$3
    _type=$(( _packed & 0xffff ))
    _code=$(( (_packed >> 16) & 0xffff ))
    _value=$(( (_packed >> 32) & 0xffffffff ))
    _ts=$(( _sec * 1000 + _usec / 1000 ))
    echo "$_type $_code $_value $_ts"
}

cmd_monitor() {
    trap 'exec 3<&- 2>/dev/null; exit 0' TERM INT
    while :; do
        if open_dev; then
            if exec 3<"$DEV"; then
                while :; do
                    ev=$(read_event) || break
                    [ -n "$ev" ] || break
                    # shellcheck disable=SC2086
                    set -- $ev
                    # 只处理 EV_KEY(1) / KEY_POWER(116)；EV_SYN 等一律忽略
                    if [ "$1" = 1 ] && [ "$2" = 116 ]; then
                        handle_key "$3" "$4"
                    fi
                done
                exec 3<&-
            fi
        fi
        # 设备不在（模块未加载/热插拔）或读失败：稍后重扫
        sleep 3
    done
}

cmd_simulate() {
    while read -r _v _t; do
        [ -n "${_v:-}" ] || continue
        handle_key "$_v" "$_t"
    done
}

case "${1:-monitor}" in
    monitor)  cmd_monitor ;;
    simulate) cmd_simulate ;;
    *)
        echo "usage: $0 monitor|simulate" >&2
        exit 2
        ;;
esac
