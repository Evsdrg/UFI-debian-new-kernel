#!/bin/sh
# Autonomous firmware-config sweep using the wcn36xx cfg_override parameter.
#
# Each case sets cfg_override to "id=value" pairs, re-starts the link (the
# firmware latches its config at MAC start), then measures TX throughput and the
# PHY rate.  Launched detached because the link restart kills the SSH session.
#
# usage: sweepcfg.sh <host> <port> <case1> <case2> ...
#   each case: "<label>:<id>=<value>[,<id>=<value>...]"
HOST=$1; PORT=$2; shift 2
P=/sys/module/wcn36xx/parameters
OUT=/root/sweepcfg.out
: > "$OUT"

for CASE in "$@"; do
    LABEL=${CASE%%:*}
    CFG=${CASE#*:}
    [ "$LABEL" = "$CFG" ] && CFG=""

    printf '%s' "$CFG" > "$P/cfg_override" 2>/dev/null || true

    ip link set wlan0 down 2>/dev/null
    sleep 2
    ip link set wlan0 up 2>/dev/null

    i=0
    while [ "$i" -lt 40 ]; do
        iw dev wlan0 link 2>/dev/null | grep -q Connected && break
        sleep 2
        i=$((i + 1))
    done
    sleep 3

    b0=$(cat /sys/class/net/wlan0/statistics/tx_bytes)
    timeout 18 python3 /root/wifitest.py "$HOST" "$PORT" 200 >/dev/null 2>&1
    b1=$(cat /sys/class/net/wlan0/statistics/tx_bytes)
    r=$(iw dev wlan0 station dump 2>/dev/null |
            sed -n 's/.*tx bitrate:[[:space:]]*//p' | head -1)
    echo "$LABEL [$CFG] $(( (b1 - b0) * 8 / 18 / 1000000 )) Mbit/s tx=[$r]" >>"$OUT"
done

echo DONE >>"$OUT"
