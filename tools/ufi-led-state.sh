#!/bin/sh
# UFI103s three-colour LED status (red / blue / green).
#
# The LEDs are gpio-leds with max_brightness=1: on/off only, and the red lamp is
# much brighter than the other two.  Software PWM is deliberately NOT used -- the
# kernel blink timer arms once per transition and every toggle pulls the CPU out
# of deep idle (4ms/16ms measured ~100 extra idle exits per second).  Red is a
# load gear instead:
#
#   red    DC on while aggregate CPU load >= 70%, off once it drops below 65%
#          (the lower release point is hysteresis so the lamp cannot chatter)
#   blue   wifi  -- solid = carrier + IPv4 route, slow = no link,
#                   fast = associating
#   green  modem -- solid = data session, slow = registered or searching,
#                   fast = connecting, off = no SIM / locked / no modem
#
# Idle state (no CPU load, wifi associated, no SIM) is red off + blue solid +
# green off, and no LED is driven by a timer.
set -u

RED=/sys/class/leds/red:heartbeat
BLUE=/sys/class/leds/blue:wlan
GREEN=/sys/class/leds/green:wan

STATE=/run/ufi-led-state
CUR=$STATE/modes
REDMEM=$STATE/red
CPUPREV=$STATE/cpu
OVERRIDE=$STATE/override

RED_ON_PCT=${RED_ON_PCT:-70}
RED_OFF_PCT=${RED_OFF_PCT:-65}
POLL_SECS=${POLL_SECS:-3}
NET_EVERY=${NET_EVERY:-20}

led_off() {
    [ -d "$1" ] || return 0
    printf 'none\n' > "$1/trigger" 2>/dev/null || true
    printf '0\n' > "$1/brightness" 2>/dev/null || true
}

led_solid() {
    [ -d "$1" ] || return 0
    printf 'none\n' > "$1/trigger" 2>/dev/null || true
    printf '1\n' > "$1/brightness" 2>/dev/null || true
}

# Blink only the low-rate blue/green states; red is never put on a timer.
led_blink() {
    [ -d "$1" ] || return 0
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

# CPU utilisation (%) over the interval since the previous call; 0 on first call.
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

# Red gear with hysteresis.  Prints on / off.
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

apply() {
    red=$1; blue=$2; green=$3

    case "$red" in
        on) led_solid "$RED" ;;
        *)  led_off "$RED" ;;
    esac

    case "$blue" in
        solid) led_solid "$BLUE" ;;
        fast)  led_blink "$BLUE" 100 100 ;;
        *)     led_blink "$BLUE" 100 1900 ;;
    esac

    case "$green" in
        solid) led_solid "$GREEN" ;;
        fast)  led_blink "$GREEN" 100 100 ;;
        slow)  led_blink "$GREEN" 100 900 ;;
        *)     led_off "$GREEN" ;;
    esac
}

wifi_mode() {
    [ -e /sys/class/net/wlan0 ] || { echo slow; return 0; }

    state=''
    if command -v wpa_cli >/dev/null 2>&1; then
        state=$(wpa_cli -i wlan0 status 2>/dev/null |
            while IFS= read -r l; do
                case "$l" in wpa_state=*) echo "${l#wpa_state=}" ;; esac
            done)
    fi
    carrier=$(cat /sys/class/net/wlan0/carrier 2>/dev/null || echo 0)

    case "$state" in
        ASSOCIATING|AUTHENTICATING|ASSOCIATED) echo fast; return 0 ;;
    esac
    [ "$carrier" = 1 ] || { echo slow; return 0; }

    if [ -n "$state" ]; then
        [ "$state" = COMPLETED ] && echo solid || echo slow
        return 0
    fi

    # No wpa_cli: fall back to a default IPv4 route on wlan0.
    if awk '$1 == "wlan0" && $2 == "00000000" { found = 1 } END { exit !found }' /proc/net/route 2>/dev/null; then
        echo solid
    else
        echo slow
    fi
}

modem_mode() {
    command -v mmcli >/dev/null 2>&1 || { echo off; return 0; }

    modem=$(mmcli -L 2>/dev/null | sed -n 's#.*Modem/\([0-9][0-9]*\).*#\1#p' | head -1)
    [ -n "$modem" ] || { echo off; return 0; }

    details=$(mmcli -m "$modem" --output-keyvalue 2>/dev/null || true)
    state=$(echo "$details" | sed -n 's/^modem\.generic\.state[[:space:]]*:[[:space:]]*//p' | head -1)
    reason=$(echo "$details" | sed -n 's/^modem\.generic\.state-failed-reason[[:space:]]*:[[:space:]]*//p' | head -1)

    case "$state" in
        connected)                echo solid ;;
        connecting|disconnecting) echo fast ;;
        registered)               echo slow ;;
        failed)
            case "$reason" in
                sim-missing|sim-not-inserted|sim-pin|sim-puk) echo off ;;
                *) echo slow ;;
            esac ;;
        searching|enabled|initializing|enabling|disabling) echo slow ;;
        *) echo off ;;
    esac
}

# Print an active debug override for red, or nothing.  These only affect red and
# expire by themselves; they exist for the Venus regression script.
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
    apply_modes "$(red_for_load "$(cpu_busy_pct)")" "$(wifi_mode)" "$(modem_mode)"
}

monitor() {
    mkdir -p "$STATE"
    trap 'apply off off off' INT TERM EXIT
    blue=slow
    green=off
    tick=0
    while :; do
        if [ $(( tick % NET_EVERY )) -eq 0 ]; then
            blue=$(wifi_mode)
            green=$(modem_mode)
        fi
        red=$(override_red)
        [ -n "$red" ] || red=$(red_for_load "$(cpu_busy_pct)")
        apply_modes "$red" "$blue" "$green"
        tick=$(( tick + 1 ))
        sleep "$POLL_SECS"
    done
}

case "${1:-}" in
    monitor) monitor ;;
    auto|ready) auto_once ;;
    status) cat "$CUR" 2>/dev/null || echo none ;;
    testing|pass|fail) set_override "$1" ;;
    off) apply off off off; echo "off,off,off" > "$CUR" ;;
    *)
        echo "usage: $0 {monitor|auto|status|testing|pass|fail|off}" >&2
        exit 2
        ;;
esac
