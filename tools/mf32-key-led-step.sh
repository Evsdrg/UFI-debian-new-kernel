#!/bin/sh
# MF32 按键-灯位验证脚本
# 每按一次电源键（pm8941_pwrkey, KEY_POWER），切换点亮下一颗可用 LED。
# 可用灯（实测有灯珠）7 颗，按顺序循环：
#   4g_1( LTE 蓝 ) → 4g_type( LTE 红 ) → wifistatus( WiFi 蓝 )
#   → bat1 → batl2 → batl3 → batl4（电池条 低→高）
# 不可用：ftest(GPIO32)、4g_2(GPIO70) —— 实测无灯珠，不参与。
#
# 用法：mf32-key-led-step.sh [event节点]
# 默认 /dev/input/event2（pm8941_pwrkey）

set -u

DEV=${1:-/dev/input/event2}
LEDS="4g_1 4g_type wifistatus bat1 batl2 batl3 batl4"
IDX_FILE=/tmp/led-step.idx
EV_KEY=1
KEY_POWER=116

# 全灭
all_off() {
    for _l in $LEDS; do
        printf 'none\n' > "/sys/class/leds/$_l/trigger" 2>/dev/null || true
        printf '0\n'    > "/sys/class/leds/$_l/brightness" 2>/dev/null || true
    done
}
all_off

idx=$(cat "$IDX_FILE" 2>/dev/null || echo 0)
case "$idx" in ''|*[!0-9]*) idx=0 ;; esac
[ "$idx" -ge 7 ] && idx=0

echo "就绪：按键切换灯位（共 7 颗）"
echo "顺序：$LEDS"
echo "当前索引：$idx"

trap 'all_off; echo; echo "已退出，灯全灭"; exit 0' TERM INT

while :; do
    raw=$(dd if="$DEV" bs=24 count=1 2>/dev/null | od -An -tu4 -j16 -N8 2>/dev/null)
    [ -z "$raw" ] && { sleep 0.1; continue; }
    set -- $raw
    [ $# -ge 2 ] || continue
    type=$(( $1 & 0xffff ))
    code=$(( $1 >> 16 ))
    value=$2

    if [ "$type" -eq "$EV_KEY" ] && [ "$code" -eq "$KEY_POWER" ] && [ "$value" -eq 1 ]; then
        all_off
        # 取第 idx 颗（0-based）
        n=0
        hit=""
        for _l in $LEDS; do
            if [ "$n" -eq "$idx" ]; then
                printf 'none\n' > "/sys/class/leds/$_l/trigger" 2>/dev/null || true
                printf '1\n'    > "/sys/class/leds/$_l/brightness" 2>/dev/null || true
                hit=$_l
                break
            fi
            n=$((n + 1))
        done
        echo ">>> 第 $((idx + 1)) 颗：${hit:-?}"
        idx=$(( (idx + 1) % 7 ))
        echo "$idx" > "$IDX_FILE"
    fi
done
