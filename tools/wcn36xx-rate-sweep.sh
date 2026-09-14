#!/bin/sh
# Autonomous fixed-rate sweep on the device.
#
# The firmware latches its rate configuration when the MAC is started, so a
# runtime update-cfg is accepted but ignored.  Setting the module parameter is
# therefore not enough -- the link has to be re-started.  This script does that
# by itself (down/up), which tears down the SSH session used to launch it, so it
# must be run detached and write its results to a file.
#
# usage: sweep.sh <host> <port> <value> [value...]
HOST=$1; PORT=$2; shift 2
P=/sys/module/wcn36xx/parameters
OUT=/root/sweep.out
: > "$OUT"

for V in "$@"; do
    echo "$V" > "$P/fixed_rate"
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
    echo "fixed=$V  $(( (b1 - b0) * 8 / 18 / 1000000 )) Mbit/s  tx=[$r]" >>"$OUT"
done

echo DONE >>"$OUT"
