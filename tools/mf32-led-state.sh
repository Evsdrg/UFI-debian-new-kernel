#!/bin/sh
# MF32 LED 状态机（实测校准版，2026-10-30）
#
# 硬件实测（设备 e81940f，逐个点亮确认）：
#   wifistatus (GPIO73) = WiFi 蓝灯
#   4g_1       (GPIO71) = LTE 蓝灯
#   4g_type    (GPIO72) = LTE 红灯
#   bat1/batl2/batl3/batl4 (GPIO0/91/1/100) = 电池条，物理顺序低→高
#   ftest(GPIO32) / 4g_2(GPIO70) = 无灯珠（电平正常但不亮，不驱动）
#
# 注意：原厂 DTB 里的命名与实际功能错位（wifistatus 实为 WiFi 灯、
# 4g_1 实为 LTE 蓝灯、4g_type 实为 LTE 红灯），以实测为准。
#
# 设计原则：稳态只允许常亮/灭；闪烁只存在于异常/瞬态/充电填充。
#
# 用法：mf32-led-state.sh monitor | once | off
#
# LED 与 power_supply 的 sysfs 根可用 MF32_LED_SYS / MF32_PSY_SYS 替换
# （自测注水用）；其余可调项见文件尾的 /etc/default/mf32-led-state。

set -u

LED_SYS=${MF32_LED_SYS:-/sys/class/leds}
PSY_SYS=${MF32_PSY_SYS:-/sys/class/power_supply}
DEFAULTS=/etc/default/mf32-led-state

# ---------------------------------------------------------------- 配置

LED_WIFI=${LED_WIFI:-wifistatus}        # WiFi 蓝灯
LED_LTE_BLUE=${LED_LTE_BLUE:-4g_1}      # LTE 蓝灯
LED_LTE_RED=${LED_LTE_RED:-4g_type}     # LTE 红灯
BAT_LEDS=${BAT_LEDS:-bat1 batl2 batl3 batl4}   # 物理顺序：低 → 高

BATT_PSY=${BATT_PSY:-auto}
POLL_SECS=${POLL_SECS:-2}
NET_EVERY=${NET_EVERY:-10}

LOW_PCT=${LOW_PCT:-15}
CRIT_PCT=${CRIT_PCT:-8}
BAR_STEP_DOWN_DELTA=${BAR_STEP_DOWN_DELTA:-3}

QUIET=${QUIET:-0}

T_FAST_ON=250;  T_FAST_OFF=250
T_SLOW_ON=1000; T_SLOW_OFF=1000
T_FILL_ON=500;  T_FILL_OFF=500

# 电池 OCV 表（µV → 百分比），与 DTS 的 ocv-capacity-table-0 保持一致。
# 必须与 boards/thwc-mf32/dts/msm8916-thwc-mf32.dts 同步修改。
# 格式：每行 "电压uV 百分比"，从高到低。
OCV_TABLE=${OCV_TABLE:-"4350000 100
4300000 98
4250000 96
4200000 94
4100000 90
4050000 87
4000000 84
3950000 80
3900000 75
3850000 70
3800000 65
3750000 60
3700000 55
3650000 50
3600000 45
3550000 40
3500000 35
3450000 30
3400000 25
3350000 20
3300000 15
3250000 10
3200000 5
3150000 3
3100000 1
3000000 0"}

# 充电时端电压高于 OCV，查表前做补偿（µV）
CHARGE_COMPENSATION=${CHARGE_COMPENSATION:-80000}
# 放电时端电压低于 OCV，查表前做补偿（µV）
DISCHARGE_COMPENSATION=${DISCHARGE_COMPENSATION:-0}

[ -r "$DEFAULTS" ] && . "$DEFAULTS"

STATE=${MF32_STATE:-/run/mf32}
mkdir -p "$STATE" 2>/dev/null || true

# ---------------------------------------------------------------- LED 原语

led_path() { echo "$LED_SYS/$1"; }

led_off() {
    [ -d "$(led_path "$1")" ] || return 0
    printf 'none\n' > "$(led_path "$1")/trigger" 2>/dev/null || true
    printf '0\n'     > "$(led_path "$1")/brightness" 2>/dev/null || true
}

led_solid() {
    [ -d "$(led_path "$1")" ] || return 0
    printf 'none\n' > "$(led_path "$1")/trigger" 2>/dev/null || true
    printf '1\n'    > "$(led_path "$1")/brightness" 2>/dev/null || true
}

led_blink() {  # led on_ms off_ms
    [ -d "$(led_path "$1")" ] || return 0
    printf 'none\n'    > "$(led_path "$1")/trigger" 2>/dev/null || true
    printf '1\n'       > "$(led_path "$1")/brightness" 2>/dev/null || true
    printf 'timer\n'   > "$(led_path "$1")/trigger" 2>/dev/null || { led_off "$1"; return 0; }
    printf '%s\n' "$2" > "$(led_path "$1")/delay_on"  2>/dev/null || true
    printf '%s\n' "$3" > "$(led_path "$1")/delay_off" 2>/dev/null || true
}

led_set() {  # led none|solid|fast|slow|fill
    case "$2" in
        none)  led_off   "$1" ;;
        solid) led_solid "$1" ;;
        fast)  led_blink "$1" $T_FAST_ON  $T_FAST_OFF ;;
        slow)  led_blink "$1" $T_SLOW_ON  $T_SLOW_OFF ;;
        fill)  led_blink "$1" $T_FILL_ON  $T_FILL_OFF ;;
    esac
}

all_off() {
    for _l in "$LED_WIFI" "$LED_LTE_BLUE" "$LED_LTE_RED" $BAT_LEDS; do led_off "$_l"; done
}

# ---------------------------------------------------------------- 采集

find_batt_psy() {
    [ "$BATT_PSY" != auto ] && { echo "$BATT_PSY"; return 0; }
    # pm8916_bms_vm 没有 capacity，靠 voltage_now 识别
    for _d in "$PSY_SYS"/*/; do
        [ -r "${_d}voltage_now" ] && [ -r "${_d}status" ] && { basename "$_d"; return 0; }
    done
    return 1
}

# 电压 → 百分比（OCV 表线性插值）
voltage_to_pct() {  # $1=voltage_uV $2=status
    _v=$1
    _st=${2:-}
    case "$_st" in
        Charging|Full) _v=$(( _v - CHARGE_COMPENSATION )) ;;
        *)             _v=$(( _v + DISCHARGE_COMPENSATION )) ;;
    esac
    [ "$_v" -lt 3000000 ] && _v=3000000
    [ "$_v" -gt 4350000 ] && _v=4350000

    _prev_v=; _prev_p=
    echo "$OCV_TABLE" | while read -r _tv _tp; do
        [ -z "${_tv:-}" ] && continue
        if [ -n "${_prev_v:-}" ] && [ "$_v" -ge "$_tv" ] && [ "$_v" -le "$_prev_v" ]; then
            # 线性插值：_tv <= _v <= _prev_v
            _span=$(( _prev_v - _tv ))
            if [ "$_span" -le 0 ]; then echo "$_tp"; return 0; fi
            _frac=$(( (_v - _tv) * 100 / _span ))
            echo $(( _tp + (_prev_p - _tp) * _frac / 100 ))
            return 0
        fi
        _prev_v=$_tv; _prev_p=$_tp
    done
}

# 网络：wifi=0|1；wwan=session|connecting|idle
net_state() {
    _w=0; _g=idle
    if command -v nmcli >/dev/null 2>&1; then
        nmcli -t -f NAME,TYPE,DEVICE,STATE con show 2>/dev/null \
            | grep -qE ':802-11-wireless:wlan[0-9]+:activated' && _w=1
        nmcli -t -f DEVICE,STATE dev show 2>/dev/null \
            | grep -qE '^wwan0:connected'  && _g=session
        nmcli -t -f DEVICE,STATE dev show 2>/dev/null \
            | grep -qE '^wwan0:connecting' && _g=connecting
    fi
    echo "wifi=$_w wwan=$_g"
    return 0
}

# ---------------------------------------------------------------- 渲染

# WiFi 蓝灯：已配置但未连接 → 慢闪；连接 → 常亮；无配置 → 灭
render_wifi() {  # $1=wifi_ok $2=wifi_configured
    if [ "$2" != 1 ]; then led_off "$LED_WIFI"; return 0; fi
    if [ "$1" = 1 ]; then led_solid "$LED_WIFI"; else led_blink "$LED_WIFI" $T_SLOW_ON $T_SLOW_OFF; fi
}

# LTE 灯：会话建立 → 蓝常亮；拨号中 → 蓝快闪；无 SIM/失败 → 红常亮；
#         已注册无会话 → 蓝灭（省电，不闪）
render_lte() {  # $1=wwan_state $2=modem_failed
    if [ "$2" = 1 ]; then
        led_off "$LED_LTE_BLUE"
        led_solid "$LED_LTE_RED"
        return 0
    fi
    led_off "$LED_LTE_RED"
    case "$1" in
        session)    led_solid "$LED_LTE_BLUE" ;;
        connecting) led_blink "$LED_LTE_BLUE" $T_FAST_ON $T_FAST_OFF ;;
        *)          led_off "$LED_LTE_BLUE" ;;
    esac
}

render_bar() {  # $1=pct $2=charging $3=prev_level; 输出新档位
    _pct=$1; _chg=$2; _prev=$3
    _lvl=1
    [ "$_pct" -gt 25 ] && _lvl=2
    [ "$_pct" -gt 50 ] && _lvl=3
    [ "$_pct" -gt 75 ] && _lvl=4
    if [ -n "$_prev" ] && [ "$_lvl" -lt "$_prev" ] && [ "$_pct" -ge $(( (_prev-1)*25 - BAR_STEP_DOWN_DELTA )) ]; then
        _lvl=$_prev
    fi

    _i=1
    for _l in $BAT_LEDS; do
        if [ "$_i" -le "$_lvl" ]; then
            led_solid "$_l"
        elif [ "$_chg" = 1 ] && [ "$_i" -eq $((_lvl + 1)) ] && [ "$_pct" -lt 100 ]; then
            led_set "$_l" fill
        else
            led_off "$_l"
        fi
        _i=$((_i + 1))
    done
    if [ "$_pct" -le "$CRIT_PCT" ] && [ "$_chg" != 1 ]; then
        led_set "${BAT_LEDS%% *}" fast
    fi
    echo "$_lvl"
}

once() {
    _force=${1:-}

    # --- 电池 ---
    _psy=$(find_batt_psy 2>/dev/null) || _psy=
    _pct=; _chg=0; _st=
    if [ -n "$_psy" ]; then
        _uv=$(cat "$PSY_SYS/$_psy/voltage_now" 2>/dev/null || echo "")
        _st=$(cat "$PSY_SYS/$_psy/status" 2>/dev/null || echo "")
        case "$_st" in Charging|Full) _chg=1 ;; esac
        if [ -n "$_uv" ]; then
            _pct=$(voltage_to_pct "$_uv" "$_st")
        fi
    fi

    # --- 系统异常 ---
    _failed=0
    if command -v systemctl >/dev/null 2>&1; then
        systemctl --failed --no-legend --plain 2>/dev/null | grep -q . && _failed=1
    fi

    # --- 网络（限频）---
    _now=$(date +%s 2>/dev/null || echo 0)
    _last=$(cat "$STATE/net_ts" 2>/dev/null || echo 0)
    if [ $((_now - _last)) -ge "$NET_EVERY" ] || [ "$_force" = force ]; then
        net_state > "$STATE/net"
        echo "$_now" > "$STATE/net_ts"
    fi
    eval "$(cat "$STATE/net" 2>/dev/null || echo 'wifi=1 wwan=idle')"

    # --- WiFi / LTE 状态灯 ---
    _wifi_cfg=0
    if command -v nmcli >/dev/null 2>&1; then
        nmcli -t -f NAME,TYPE con show 2>/dev/null \
            | grep -qE ':802-11-wireless$' && _wifi_cfg=1
    fi
    render_wifi "${wifi:-1}" "$_wifi_cfg"

    _modem_failed=0
    if [ "${wwan:-idle}" = idle ] && command -v mmcli >/dev/null 2>&1; then
        _mstate=$(mmcli -m 0 2>/dev/null | grep -E '^\s+state:' | head -1)
        case "$_mstate" in
            *failed*|*locked*) _modem_failed=1 ;;
        esac
    fi
    render_lte "${wwan:-idle}" "$_modem_failed"

    # --- 电量条：默认全灭，仅短按 peek 期间显示；危急低电常驻快闪 ---
    _peek=0
    _pu=$(cat "$STATE/peek_until" 2>/dev/null || echo 0)
    [ "$_now" -lt "$_pu" ] && _peek=1
    _crit=0
    if [ -n "${_pct:-}" ] && [ "$_pct" -le "$CRIT_PCT" ] && [ "$_chg" != 1 ]; then
        _crit=1
    fi

    if [ "$_crit" = 1 ]; then
        # 危急低电：第 1 颗常驻快闪（安全警示，QUIET 也不关）
        for _l in $BAT_LEDS; do led_off "$_l"; done
        led_set "${BAT_LEDS%% *}" fast
    elif [ "$_peek" = 1 ] && [ "$QUIET" != 1 ]; then
        if [ -n "${_pct:-}" ]; then
            _prev=$(cat "$STATE/level" 2>/dev/null || echo "")
            _lvl=$(render_bar "$_pct" "$_chg" "$_prev")
            echo "$_lvl" > "$STATE/level"
        else
            for _l in $BAT_LEDS; do led_off "$_l"; done
        fi
    else
        for _l in $BAT_LEDS; do led_off "$_l"; done
    fi

    # 系统异常时 LTE 红灯也用作告警（无 RGB 硬件）
    if [ "$_failed" = 1 ]; then
        led_blink "$LED_LTE_RED" $T_SLOW_ON $T_SLOW_OFF
    fi

    {
        echo "pct=${_pct:-NA} uv=${_uv:-NA} st=${_st:-NA} chg=$_chg wifi=${wifi:-?} wwan=${wwan:-?} failed=$_failed peek=$_peek"
    } > "$STATE/status"
}

cmd_off() {
    all_off
}

case "${1:-monitor}" in
    monitor)
        trap 'all_off; exit 0' TERM INT
        while :; do once; sleep "$POLL_SECS"; done
        ;;
    once)   once force ;;
    off)    cmd_off ;;
    *)      echo "usage: $0 monitor|once|off" >&2; exit 2 ;;
esac
