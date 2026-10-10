#!/bin/sh
# OpenStick 三色状态灯监控（red / blue / green）
#
# 适用机型：UFI103s/UFI003、UFI001b、UFI001c、SP970、UZ801
# 这些板子的三颗状态灯在设备树里的语义完全一致，只有 GPIO 编号不同：
#     blue  = LED_FUNCTION_WLAN        -> sysfs 名 blue:wlan
#     green = LED_FUNCTION_WAN         -> sysfs 名 green:wan
#     red   = LED_FUNCTION_HEARTBEAT   -> sysfs 名 red:heartbeat
# GPIO 差异由各自的 DTB 承担，所以本脚本不需要按机型分支。
#
# 三颗灯都是 gpio-leds、max_brightness=1，只能开关；红灯明显比另外两颗亮。
# 因此**故意不用软件 PWM**：内核 blink timer 每次翻转都会把 CPU 从深空闲拉出
# （实测 4ms/16ms 翻转约 100 次/秒，深空闲退出 +101 次/秒）。红灯改用负载档位：
#
#   red    DC 常亮：CPU 总负载 >= 70% 时亮，降到 65% 以下时灭
#          （释放点更低是滞回，避免灯在阈值附近抖动）
#   blue   Wi-Fi：常亮 = 已连接，慢闪 = 无链路，快闪 = 正在关联
#   green  4G：  常亮 = 数据会话已建立，慢闪 = 已注册/搜索中，
#                快闪 = 正在连接，灭 = 无 SIM / 已锁 / 无模块
#
# 空闲稳定态（无 CPU 负载、Wi-Fi 已连、无 SIM）是 红灯灭 + 蓝灯常亮 + 绿灯灭，
# 此时没有任何灯由定时器驱动。
#
# 可用 /etc/default/ufi-led-state 覆盖默认值（见下方"配置"段的变量）。

set -u

# ---------------------------------------------------------------- 配置

# 灯与网口的发现方式：设备树里三颗状态灯的默认（function,color）组合在所有
# 机型上都是 WLAN/blue、WAN/green、HEARTBEAT/red。sysfs 里没有 color/function
# 属性，所以先按已知名字匹配，匹配不到再按名字里的颜色词兜底。
LED_BLUE_HINT=${LED_BLUE_HINT:-blue:wlan}
LED_GREEN_HINT=${LED_GREEN_HINT:-green:wan}
LED_RED_HINT=${LED_RED_HINT:-red:heartbeat}

WIFI_IFACE=${WIFI_IFACE:-}
MODEM_MGMT=${MODEM_MGMT:-auto}      # auto | nm | mm  (auto：有 nmcli 用 nm，否则 mmcli)

RED_ON_PCT=${RED_ON_PCT:-70}
RED_OFF_PCT=${RED_OFF_PCT:-65}
POLL_SECS=${POLL_SECS:-3}
NET_EVERY=${NET_EVERY:-20}

# 允许用 /etc/default/ufi-led-state 覆盖上面的默认值（发行版惯例）
[ -r /etc/default/ufi-led-state ] && . /etc/default/ufi-led-state

STATE=/run/ufi-led-state
CUR=$STATE/modes
REDMEM=$STATE/red
CPUPREV=$STATE/cpu
OVERRIDE=$STATE/override

# ---------------------------------------------------------------- LED 发现

# 在 /sys/class/leds 里找一个灯：$1 首选名，$2 颜色兜底。
# 找到就打印目录路径；找不到返回 1。
find_led() {
    _want=$1
    _color=$2
    if [ -d "/sys/class/leds/$_want" ]; then
        printf '%s\n' "/sys/class/leds/$_want"
        return 0
    fi
    # 兜底：名字里含该颜色词。按通配展开顺序取第一个，保证可重复。
    for _d in /sys/class/leds/*"$_color"*; do
        [ -d "$_d" ] || continue
        printf '%s\n' "$_d"
        return 0
    done
    return 1
}

led_paths() {
    RED=$(find_led "$LED_RED_HINT" red)
    BLUE=$(find_led "$LED_BLUE_HINT" blue)
    GREEN=$(find_led "$LED_GREEN_HINT" green)
}

# 找无线网口：优先配置值，其次第一个 wlan*。
find_wifi_iface() {
    if [ -n "$WIFI_IFACE" ]; then
        [ -e "/sys/class/net/$WIFI_IFACE" ] && { printf '%s\n' "$WIFI_IFACE"; return 0; }
    fi
    for _d in /sys/class/net/wlan*; do
        [ -e "$_d" ] || continue
        printf '%s\n' "$(basename "$_d")"
        return 0
    done
    return 1
}

# ---------------------------------------------------------------- LED 原语

led_off() {
    [ -n "${1:-}" ] && [ -d "$1" ] || return 0
    printf 'none\n' > "$1/trigger" 2>/dev/null || true
    printf '0\n' > "$1/brightness" 2>/dev/null || true
}

led_solid() {
    [ -n "${1:-}" ] && [ -d "$1" ] || return 0
    printf 'none\n' > "$1/trigger" 2>/dev/null || true
    printf '1\n' > "$1/brightness" 2>/dev/null || true
}

# 只让低速的蓝/绿闪；红灯永远不上定时器。
led_blink() {
    [ -n "${1:-}" ] && [ -d "$1" ] || return 0
    printf 'none\n' > "$1/trigger" 2>/dev/null || true
    printf '1\n' > "$1/brightness" 2>/dev/null || true
    if ! printf 'timer\n' > "$1/trigger" 2>/dev/null; then
        led_off "$1"
        return 0
    fi
    printf '%s\n' "$2" > "$1/delay_on" 2>/dev/null || true
    printf '%s\n' "$3" > "$1/delay_off" 2>/dev/null || true
    printf '1\n' > "$1/brightness" 2>/dev/null || true
}

# ---------------------------------------------------------------- 状态采集

# 自上次调用以来的 CPU 占用率（%）；首次调用返回 0。
cpu_busy_pct() {
    read -r _ u n s i w irq sirq st rest _ < /proc/stat 2>/dev/null || { echo 0; return 0; }

    idle=$(( i + w ))
    total=$(( u + n + s + i + w + irq + sirq + st ))

    pi=''; pt=''
    [ -r "$CPUPREV" ] && read -r pi pt < "$CPUPREV"
    echo "$idle $total" > "$CPUPREV"

    [ -n "$pi" ] && [ "$pt" -gt 0 ] 2>/dev/null || { echo 0; return 0; }
    di=$(( idle - pi ))
    dt=$(( total - pt ))
    [ "$dt" -gt 0 ] || { echo 0; return 0; }
    [ "$di" -ge 0 ] || di=0
    echo $(( 100 * (dt - di) / dt ))
}

# 红灯档位，带滞回。打印 on / off。
red_for_load() {
    busy=$1
    last=$(cat "$REDMEM" 2>/dev/null || echo 0)
    on=0
    if [ "$last" = 1 ]; then
        [ "$busy" -ge "$RED_OFF_PCT" ] && on=1
    else
        [ "$busy" -ge "$RED_ON_PCT" ] && on=1
    fi
    echo "$on" > "$REDMEM"
    [ "$on" = 1 ] && echo on || echo off
}

# --- Wi-Fi ---
# 优先用 nmcli（NetworkManager 是现在的默认网络栈），退回 wpa_cli，再退回路由表。
wifi_state_nm() {
    command -v nmcli >/dev/null 2>&1 || return 1
    _if=$1
    # 设备状态行形如：wlan0:wifi:connected:<SSID>
    _line=$(nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device status 2>/dev/null |
        awk -F: -v want="$_if" '$1 == want { print; exit }')
    [ -n "$_line" ] || return 1
    _st=$(printf '%s\n' "$_line" | cut -d: -f3)
    case "$_st" in
        connected)                echo solid; return 0 ;;
        connecting|disconnecting) echo fast;  return 0 ;;
        *)                        echo slow;  return 0 ;;
    esac
}

wifi_state_wpa() {
    command -v wpa_cli >/dev/null 2>&1 || return 1
    _if=$1
    _st=$(wpa_cli -i "$_if" status 2>/dev/null |
        while IFS= read -r l; do
            case "$l" in wpa_state=*) echo "${l#wpa_state=}" ;; esac
        done)
    case "$_st" in
        ASSOCIATING|AUTHENTICATING|ASSOCIATED) echo fast;  return 0 ;;
        COMPLETED)                             echo solid; return 0 ;;
        '')                                    return 1 ;;
        *)                                     echo slow;  return 0 ;;
    esac
}

wifi_mode() {
    _if=$(find_wifi_iface) || { echo slow; return 0; }

    wifi_state_nm "$_if" && return 0
    wifi_state_wpa "$_if" && return 0

    # 都没有：只看载波与默认 IPv4 路由。
    _carrier=$(cat "/sys/class/net/$_if/carrier" 2>/dev/null || echo 0)
    [ "$_carrier" = 1 ] || { echo slow; return 0; }
    if awk -v d="$_if" '$1 == d && $2 == "00000000" { found = 1 } END { exit !found }' \
         /proc/net/route 2>/dev/null; then
        echo solid
    else
        echo slow
    fi
}

# --- 4G ---
# 数据会话优先问 NetworkManager（wwan0 由 NM 管）；没有 nmcli 时退回 mmcli。
modem_state_nm() {
    command -v nmcli >/dev/null 2>&1 || return 1
    # 没有任何 wwan 设备说明模块没起来
    _has=$(nmcli -t -f DEVICE,TYPE,STATE device status 2>/dev/null | awk -F: '$2 == "wwan" { print; exit }')
    [ -n "$_has" ] || return 1
    _st=$(printf '%s\n' "$_has" | cut -d: -f3)
    case "$_st" in
        connected)                echo solid; return 0 ;;
        connecting|disconnecting) echo fast;  return 0 ;;
        *)                        echo slow;  return 0 ;;
    esac
}

modem_state_mm() {
    command -v mmcli >/dev/null 2>&1 || return 1
    _modem=$(mmcli -L 2>/dev/null | sed -n 's#.*Modem/\([0-9][0-9]*\).*#\1#p' | head -1)
    [ -n "$_modem" ] || return 1

    _details=$(mmcli -m "$_modem" --output-keyvalue 2>/dev/null || true)
    _st=$(printf '%s\n' "$_details" | sed -n 's/^modem\.generic\.state[[:space:]]*:[[:space:]]*//p' | head -1)
    _reason=$(printf '%s\n' "$_details" | sed -n 's/^modem\.generic\.state-failed-reason[[:space:]]*:[[:space:]]*//p' | head -1)

    case "$_st" in
        connected)                echo solid; return 0 ;;
        connecting|disconnecting) echo fast;  return 0 ;;
        registered)               echo slow;  return 0 ;;
        failed)
            case "$_reason" in
                sim-missing|sim-not-inserted|sim-pin|sim-puk) echo off; return 0 ;;
                *) echo slow; return 0 ;;
            esac ;;
        searching|enabled|initializing|enabling|disabling) echo slow; return 0 ;;
        '') return 1 ;;
        *)  echo off; return 0 ;;
    esac
}

modem_mode() {
    case "$MODEM_MGMT" in
        nm) modem_state_nm || { echo off; return 0; } ;;
        mm) modem_state_mm || { echo off; return 0; } ;;
        *)
            # auto：先看 NM，再看 mmcli；两者都问不到就按"无模块"处理。
            _r=$(modem_state_nm) && { printf '%s\n' "$_r"; return 0; }
            _r=$(modem_state_mm) && { printf '%s\n' "$_r"; return 0; }
            echo off
            ;;
    esac
}

# ---------------------------------------------------------------- 应用

apply() {
    _red=$1; _blue=$2; _green=$3

    case "$_red" in
        on) led_solid "$RED" ;;
        *)  led_off "$RED" ;;
    esac

    case "$_blue" in
        solid) led_solid "$BLUE" ;;
        fast)  led_blink "$BLUE" 100 100 ;;
        *)     led_blink "$BLUE" 100 1900 ;;
    esac

    case "$_green" in
        solid) led_solid "$GREEN" ;;
        fast)  led_blink "$GREEN" 100 100 ;;
        slow)  led_blink "$GREEN" 100 900 ;;
        *)     led_off "$GREEN" ;;
    esac
}

# ---------------------------------------------------------------- 调试覆盖

# 打印生效中的红灯覆盖值，没有则打印空。这些只影响红灯且会自行过期；
# 供 Venus 回归脚本使用。
override_red() {
    [ -r "$OVERRIDE" ] || return 0
    set -- $(cat "$OVERRIDE" 2>/dev/null)
    case "${2:-0}" in
        ''|0) ;;
        *[!0-9]*) rm -f "$OVERRIDE"; return 0 ;;
        *) [ "$(date +%s)" -lt "$2" ] || { rm -f "$OVERRIDE"; return 0; } ;;
    esac
    case "${1:-}" in
        testing|fail) echo on ;;
        pass)         echo off ;;
        *)            rm -f "$OVERRIDE" ;;
    esac
}

set_override() {
    mkdir -p "$STATE"
    now=$(date +%s)
    case "$1" in
        testing) echo "testing $((now + 120))" > "$OVERRIDE" ;;
        pass)    echo "pass $((now + 15))"     > "$OVERRIDE" ;;
        fail)    echo "fail $((now + 60))"     > "$OVERRIDE" ;;
        *)       return 2 ;;
    esac
}

apply_modes() {
    modes="$1,$2,$3"
    [ "$(cat "$CUR" 2>/dev/null)" = "$modes" ] && return 0
    apply "$1" "$2" "$3"
    echo "$modes" > "$CUR"
}

auto_once() {
    mkdir -p "$STATE"
    led_paths
    apply_modes "$(red_for_load "$(cpu_busy_pct)")" "$(wifi_mode)" "$(modem_mode)"
}

monitor() {
    mkdir -p "$STATE"
    led_paths
    # 收到 TERM/INT 时关灯并**真正退出**。只 apply 不 exit 会让进程继续跑循环，
    # systemd 只能等 TimeoutStopSec 到点后 SIGKILL，于是 `systemctl stop/restart`
    # 每次都卡满超时（实测服务会停在 deactivating）。
    trap 'apply off off off; exit 0' INT TERM
    trap 'apply off off off' EXIT
    blue=slow
    green=off
    tick=0
    # 开机后 NetworkManager / ModemManager 往往还没连上，而正常刷新间隔是
    # NET_EVERY 个周期（默认 60s）。若只按常规节奏走，用户会先看到蓝灯慢闪
    # 一分钟才变常亮。所以前 WARMUP_TICKS 个周期每拍都刷新一次网络状态，
    # 让灯尽快反映真实状态；之后就回到低频刷新（避免频繁 fork nmcli/mmcli）。
    warmup=${WARMUP_TICKS:-8}
    while :; do
        if [ "$warmup" -gt 0 ] || [ $(( tick % NET_EVERY )) -eq 0 ]; then
            blue=$(wifi_mode)
            green=$(modem_mode)
            # 一旦已经连上，就没必要继续密集刷新了
            if [ "$warmup" -gt 0 ] && { [ "$blue" = solid ] || [ "$green" = solid ]; }; then
                warmup=0
            fi
            [ "$warmup" -gt 0 ] && warmup=$(( warmup - 1 ))
        fi
        red=$(override_red)
        [ -n "$red" ] || red=$(red_for_load "$(cpu_busy_pct)")
        apply_modes "$red" "$blue" "$green"
        tick=$(( tick + 1 ))
        # 用可被打断的等待代替 sleep：sleep 期间收到 TERM 要等它睡完才处理 trap，
        # 最长会拖一个 POLL_SECS。分片等待让停止几乎立刻生效。
        _left=$POLL_SECS
        while [ "$_left" -gt 0 ]; do
            sleep 1
            _left=$(( _left - 1 ))
        done
    done
}

# 打印本次发现的灯与网口，供排错（设备上跑 `ufi-led-state.sh paths` 即可核对）
show_paths() {
    led_paths
    printf 'red   = %s\n' "${RED:-<未找到>}"
    printf 'blue  = %s\n' "${BLUE:-<未找到>}"
    printf 'green = %s\n' "${GREEN:-<未找到>}"
    _if=$(find_wifi_iface) && printf 'wifi  = %s\n' "$_if" || printf 'wifi  = <未找到>\n'
    printf 'modem = %s\n' "$MODEM_MGMT"
}

# 子命令分发。
# 允许本脚本被 `. script` 引入（此时只定义函数，不应有任何动作或退出）。
# 判断依据：正常名字直接执行，或显式带了子命令，才进入分发。这样
#   - systemd 按固定路径执行          -> 分发
#   - 改名后带子命令执行              -> 分发
#   - 被 source（无参数）             -> 静默，只定义函数
# POSIX sh 无法可靠判断"是否被 source"，这是常见做法里最稳的一种。
if [ "${0##*/}" = "ufi-led-state.sh" ] || [ $# -gt 0 ]; then
case "${1:-}" in
    monitor) monitor ;;
    auto|ready) auto_once ;;
    status) cat "$CUR" 2>/dev/null || echo none ;;
    paths) show_paths ;;
    testing|pass|fail) set_override "$1" ;;
    off) led_paths; apply off off off; echo "off,off,off" > "$CUR" ;;
    *)
        echo "用法: $0 {monitor|auto|status|paths|testing|pass|fail|off}" >&2
        exit 2
        ;;
esac
fi
