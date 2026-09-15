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
STATE=${MF32_STATE:-/run/mf32-powerkey}
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

read_event() {  # 输出 "type code value"，一次一个 evdev 事件（24 字节，arm64 LE）
    set -- $(dd if="$DEV" bs=24 count=1 2>/dev/null | od -An -tu4 -j16 -N8) || return 1
    [ $# -ge 2 ] || return 1
    echo "$(($1 & 0xffff)) $(($1 >> 16)) $2"
}

cmd_monitor() {
    while :; do
        if open_dev; then
            trap 'exit 0' TERM INT
            while :; do
                ev=$(read_event) || break
                [ -n "$ev" ] || break
                handle_key $ev
            done
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
