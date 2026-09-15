#!/bin/sh
# MF32 LED 状态机（RGB 系统状态 + 4 颗 LED 电量条）
#
# 设计文档：boards/thwc-mf32/LED-SCHEME.md。要点：
#   * RGB 一次只亮一个通道，优先级仲裁（红系 > 蓝慢闪 > 绿系 > 蓝常亮）
#   * 4 颗独立 LED = 电量条（档位 + 充电填充 + 危急快闪）
#   * 稳态只允许常亮/灭；闪烁只存在于瞬态、异常、充电填充
#
# 用法：mf32-led-state.sh monitor | once | off
#   monitor  服务主循环（systemd）
#   once     渲染一轮后退出（自测/手动刷新）
#   off      全灭（systemd ExecStop：先红常亮 2s 再全灭）
#
# LED 与 power_supply 的 sysfs 根可用 MF32_LED_SYS / MF32_PSY_SYS 替换
# （自测注水用）；其余可调项见文件尾的 /etc/default/mf32-led-state。

set -u

LED_SYS=${MF32_LED_SYS:-/sys/class/leds}
PSY_SYS=${MF32_PSY_SYS:-/sys/class/power_supply}
DEFAULTS=/etc/default/mf32-led-state

# ---------------------------------------------------------------- 配置

LED_RED=${LED_RED:-red:status}
LED_GREEN=${LED_GREEN:-green:status}
LED_BLUE=${LED_BLUE:-blue:status}
BAT_LEDS=${BAT_LEDS:-bat:1 bat:2 bat:3 bat:4}   # 物理顺序，DTS 定，此处兜底

BATT_PSY=${BATT_PSY:-auto}          # auto: 找第一个有 capacity 的 psy
POLL_SECS=${POLL_SECS:-2}
NET_EVERY=${NET_EVERY:-10}          # 每 N 轮查一次网络（nmcli 开销大）

LOW_PCT=${LOW_PCT:-15}              # 红常亮警告
CRIT_PCT=${CRIT_PCT:-8}             # 红快闪 / 条快闪（关机倒计时）
BAR_STEP_DOWN_DELTA=${BAR_STEP_DOWN_DELTA:-3}   # 档位滞回

QUIET=${QUIET:-0}                   # 1=夜间静音：稳态灯全灭

T_FAST_ON=250;  T_FAST_OFF=250      # 快闪
T_SLOW_ON=1000; T_SLOW_OFF=1000     # 慢闪
T_FILL_ON=500;  T_FILL_OFF=500      # 充电填充

[ -r "$DEFAULTS" ] && . "$DEFAULTS"

STATE=${MF32_STATE:-/run/mf32-led-state}
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

# RGB 一次只亮一个通道：先全灭，再点亮目标色
rgb_set() {  # red|green|blue:none|solid|fast|slow
    _c=${1%%:*}; _m=${1#*:}
    case "$_c" in
        red)   _target=$LED_RED   ;;
        green) _target=$LED_GREEN ;;
        blue)  _target=$LED_BLUE  ;;
        *) return 0 ;;
    esac
    for _ch in "$LED_RED" "$LED_GREEN" "$LED_BLUE"; do
        [ "$_ch" = "$_target" ] || led_off "$_ch"
    done
    [ "$_m" = none ] && return 0
    led_set "$_target" "$_m"
}

all_off() {
    for _l in "$LED_RED" "$LED_GREEN" "$LED_BLUE" $BAT_LEDS; do led_off "$_l"; done
}

# ---------------------------------------------------------------- 采集

find_batt_psy() {
    [ "$BATT_PSY" != auto ] && { echo "$BATT_PSY"; return 0; }
    for _d in "$PSY_SYS"/*/; do
        [ -r "${_d}capacity" ] && { basename "$_d"; return 0; }
    done
    return 1
}

# 网络：wifi=0|1（已配置的 WiFi 是否连着）；wwan=session|connecting|idle
# 借用 ufi-led-state 的来源链：nmcli 优先，没有 nmcli 时按"正常"处理不误报。
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

render_rgb() {  # $1=crit $2=failed $3=low $4=wifi_ok $5=wwan_state
    if [ "$1" = 1 ]; then rgb_set red:fast;   return 0; fi
    if [ "$2" = 1 ]; then rgb_set red:slow;   return 0; fi
    if [ "$3" = 1 ]; then rgb_set red:solid;  return 0; fi
    if [ "$4" = 0 ]; then rgb_set blue:slow;  return 0; fi
    case "$5" in
        session)    rgb_set green:solid ;;
        connecting) rgb_set green:fast ;;
        *)          [ "$QUIET" = 1 ] && rgb_set blue:none || rgb_set blue:solid ;;
    esac
}

render_bar() {  # $1=pct $2=charging $3=prev_level; 输出新档位
    _pct=$1; _chg=$2; _prev=$3
    # 设计阈值：>75→4，>50→3，>25→2，其余→1
    _lvl=1
    [ "$_pct" -gt 25 ] && _lvl=2
    [ "$_pct" -gt 50 ] && _lvl=3
    [ "$_pct" -gt 75 ] && _lvl=4
    # 滞回：降档要比标称门槛低 BAR_STEP_DOWN_DELTA（防边界抖动）
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
    # 充满：4 常亮由 _lvl=4 覆盖；危急快闪由调用方在 RGB 侧联动 + 此处 bat:1
    if [ "$_pct" -le "$CRIT_PCT" ] && [ "$_chg" != 1 ]; then
        led_set "${BAT_LEDS%% *}" fast
    fi
    echo "$_lvl"
}

once() {
    # --- 电量 ---
    _psy=$(find_batt_psy 2>/dev/null) || _psy=
    _pct=; _chg=0
    if [ -n "$_psy" ]; then
        read -r _pct < "$PSY_SYS/$_psy/capacity" 2>/dev/null || _pct=
        read -r _st  < "$PSY_SYS/$_psy/status"   2>/dev/null || _st=
        case "$_st" in Charging|Full) _chg=1 ;; esac
    fi

    # --- 系统异常：关键单元 failed（尽力而为，读不到不算失败）---
    _failed=0
    if command -v systemctl >/dev/null 2>&1; then
        systemctl --failed --no-legend --plain 2>/dev/null | grep -q . && _failed=1
    fi

    # --- 网络（限频）---
    _now=$(date +%s 2>/dev/null || echo 0)
    _last=$(cat "$STATE/net_ts" 2>/dev/null || echo 0)
    if [ $((_now - _last)) -ge "$NET_EVERY" ] || [ "$1" = force ]; then
        net_state > "$STATE/net"
        echo "$_now" > "$STATE/net_ts"
    fi
    eval "$(cat "$STATE/net" 2>/dev/null || echo 'wifi=1 wwan=idle')"

    # --- RGB ---
    _crit=0; _low=0
    if [ -n "${_pct:-}" ]; then
        [ "$_pct" -le "$CRIT_PCT" ] && [ "$_chg" != 1 ] && _crit=1
        [ "$_pct" -le "$LOW_PCT"  ] && [ "$_chg" != 1 ] && _low=1
    fi
    _wifi_ok=${wifi:-1}
    render_rgb "$_crit" "$_failed" "$_low" "$_wifi_ok" "${wwan:-idle}"

    # --- 电量条 ---
    # QUIET（夜间静音）下稳态条全灭；电源键 peek（mf32-powerkey.sh 写入
    # peek_until）临时点亮 PEEK_SECS 秒。
    _peek=0
    _pu=$(cat "$STATE/peek_until" 2>/dev/null || echo 0)
    [ "$_now" -lt "$_pu" ] && _peek=1
    if [ -n "${_pct:-}" ]; then
        if [ "$QUIET" = 1 ] && [ "$_peek" != 1 ]; then
            for _l in $BAT_LEDS; do led_off "$_l"; done
        else
            _prev=$(cat "$STATE/level" 2>/dev/null || echo "")
            _lvl=$(render_bar "$_pct" "$_chg" "$_prev")
            echo "$_lvl" > "$STATE/level"
        fi
    else
        for _l in $BAT_LEDS; do led_off "$_l"; done
    fi

    # 状态快照（调试/外巡检用）
    {
        echo "pct=${_pct:-NA} chg=$_chg crit=$_crit low=$_low wifi_ok=$_wifi_ok wwan=${wwan:-idle} failed=$_failed peek=$_peek"
    } > "$STATE/status"
}

cmd_off() {
    rgb_set red:solid
    sleep "${OFF_RED_SECS:-2}"
    all_off
}

case "${1:-monitor}" in
    monitor)
        # systemd 停服务发 TERM；确认干净的退出码让 Restart=always 不竞争
        trap 'all_off; exit 0' TERM INT
        while :; do once; sleep "$POLL_SECS"; done
        ;;
    once)   once force ;;
    off)    cmd_off ;;
    *)      echo "usage: $0 monitor|once|off" >&2; exit 2 ;;
esac
