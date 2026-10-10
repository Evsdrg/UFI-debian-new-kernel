#!/usr/bin/env bash
# Bounded serial access to the UFI103s console.
#
# 波特率默认 115200，两端一致：内核 cmdline 是 `console=ttyMSM0,115200`，
# 设备侧 `stty -F /dev/ttyMSM0` 也报 115200。实测（2026-09-14，主机侧逐档抓包）
# 只有 115200 能解出可读内容，57600 / 230400 是乱码、9600 无输出——说明这个
# CH343（USB 1a86:55d3，CDC-ACM 模式）确实遵守主机设的波特率，**不存在"适配器
# 时钟偏差"这回事**。
#
# 曾误记为"需要 57600"，来源是：串口的速率会被 getty 沿用，而
# serial-getty@ttyMSM0 用 `--keep-baud`，会把端口保持在上次遗留的速率上。
# 若发现解不出内容，先在设备上 `stty -F /dev/ttyMSM0 115200` 复位，再按 115200 抓。
#
# PORT 必须重derive：同一类适配器曾先后以 ch341-uart(/dev/ttyUSB0) 与
# cdc_acm(/dev/ttyACM0) 绑定，重插后 tty 名与 USB 序列号都会变。
# 用 `ufi-console.sh id` 确认；不确定时用波特率扫描（115200 等）识别端口。
set -u

PORT="${UFI_CONSOLE_PORT:-/dev/ttyACM0}"
BAUD="${UFI_CONSOLE_BAUD:-115200}"
. "$(dirname "$0")/lib-creds.sh"
# 本机 sudo 口令：环境变量 > .local-creds；缺失时 cred 会给出提示并退出。
SUDO_PW="$(cred SUDO_PW '访问串口需要 sudo')"

sudo_do() { echo "$SUDO_PW" | sudo -S "$@" 2>/dev/null; }

configure() {
    sudo_do stty -F "$PORT" "$BAUD" cs8 -cstopb -parenb raw -echo
}

# Read the console for N seconds, optionally sending command lines first.
# Usage: ufi-console.sh read <seconds>
#        ufi-console.sh send <seconds> <line> [line...]
read_for() {
    local secs=$1; shift
    configure
    local f
    f=$(mktemp /tmp/ufi-console.XXXXXX)
    sudo_do timeout "$secs" cat "$PORT" >"$f" &
    local catpid=$!
    if [ "$#" -gt 0 ]; then
        sleep 1
        local line
        for line in "$@"; do
            sudo_do sh -c "printf '%s\r' > '$PORT'"
            sleep 2
        done
    fi
    wait "$catpid" 2>/dev/null
    cat "$f"
    rm -f "$f"
}

case "${1:-}" in
    id)
        echo "port=$PORT baud=$BAUD"
        echo "resolved: $(readlink -f "$PORT" 2>/dev/null)"
        readlink -f "/sys/class/tty/${PORT##*/}/device" 2>/dev/null
        ;;
    read) shift; read_for "${1:-5}" ;;
    send) shift; read_for "${1:-8}" "${@:2}" ;;
    *)
        echo "usage: $0 {id|read <secs>|send <secs> <line>...}" >&2
        exit 2
        ;;
esac
