#!/bin/sh
# Sweep ENABLE_DYNAMIC_RA_START_RATE (hal.h says MCS n => 0x80|n).
HOST=$1; PORT=$2; shift 2
P=/sys/module/wcn36xx/parameters
OUT=/root/sweep2.out
: > "$OUT"
echo 0 > "$P/fixed_rate"
for V in "$@"; do
    echo "$V" > "$P/ra_start_rate"
    ip link set wlan0 down 2>/dev/null; sleep 2; ip link set wlan0 up 2>/dev/null
    i=0; while [ "$i" -lt 40 ]; do iw dev wlan0 link 2>/dev/null | grep -q Connected && break; sleep 2; i=$((i+1)); done
    sleep 3
    b0=$(cat /sys/class/net/wlan0/statistics/tx_bytes)
    timeout 18 python3 /root/wifitest.py "$HOST" "$PORT" 200 >/dev/null 2>&1
    b1=$(cat /sys/class/net/wlan0/statistics/tx_bytes)
    r=$(iw dev wlan0 station dump 2>/dev/null | sed -n 's/.*tx bitrate:[[:space:]]*//p' | head -1)
    echo "ra_start=$V  $(( (b1-b0)*8/18/1000000 )) Mbit/s  tx=[$r]" >> "$OUT"
done
echo DONE >> "$OUT"
