#!/bin/sh
# WiFi TX throughput test for the Handsome OpenStick family (wcn36xx radio).
#
# This is a read-only measurement: it changes no configuration, writes no
# partition, and needs nothing installed beyond iperf3, iw and ip.  Run it on
# the stick with an iperf3 server listening on another machine.
#
#   On the peer:   iperf3 -s
#   On the stick:  ./wifi-tx-test.sh <peer-ip> [seconds]
#
# The upload direction (stick -> peer) is the one that matters for the
# MAX_MEDIUM_TIME issue; download is measured too so a regression in the other
# direction is visible.
#
# Output is a block of key=value lines, one per fact, so it can be pasted into a
# report without reformatting.

set -u

PEER=${1:-}
DURATION=${2:-10}

if [ -z "$PEER" ]; then
    echo "usage: $0 <iperf3-server-ip> [seconds]" >&2
    exit 2
fi

for bin in iperf3 iw ip; do
    command -v "$bin" >/dev/null 2>&1 || {
        echo "missing required tool: $bin" >&2
        exit 2
    }
done

IFACE=${IFACE:-wlan0}
STA=$(iw dev "$IFACE" link 2>/dev/null | sed -n 's/^Connected to \([0-9a-f:]*\).*/\1/p')
AP_SSID=$(iw dev "$IFACE" link 2>/dev/null | sed -n 's/^\s*SSID: //p')
FREQ=$(iw dev "$IFACE" link 2>/dev/null | sed -n 's/^\s*freq: //p')
SIGNAL=$(iw dev "$IFACE" link 2>/dev/null | sed -n 's/^\s*signal: \(.*\) dBm/\1/p')

# Rate as reported by the station table, sampled while idle and mid-transfer.
rate_line() {
    iw dev "$IFACE" station dump 2>/dev/null |
        sed -n 's/.*\(tx bitrate:[[:space:]]*\|rx bitrate:[[:space:]]*\)\(.*\)/\1\2/p'
}

# One iperf3 run in a given direction, printing the transfer throughput in
# Mbit/s and the retransmit count.
#
# Direction is expressed from the stick's point of view:
#   up    = stick sends  -> the "sender" line of a normal run is the stick
#   down  = stick receives -> with -R the "sender" line is the peer, so the
#           value we want is the "receiver" line of that run
# The plain text output is parsed rather than -J, because the target systems
# only have busybox-grade tooling.
iperf_run() {
    dir=$1
    if [ "$dir" = up ]; then
        out=$(iperf3 -c "$PEER" -t "$DURATION" 2>/dev/null)
        line=$(echo "$out" | grep -E '[[:space:]]sender[[:space:]]*$' | tail -1)
    else
        out=$(iperf3 -c "$PEER" -t "$DURATION" -R 2>/dev/null)
        line=$(echo "$out" | grep -E '[[:space:]]receiver[[:space:]]*$' | tail -1)
    fi
    mbps=$(echo "$line" | awk '{for (i = 1; i <= NF; i++) if ($i == "Mbits/sec") print $(i - 1)}')
    # The retransmit count sits immediately after the bitrate.
    retr=$(echo "$line" | awk '{for (i = 1; i <= NF; i++) if ($i == "Mbits/sec") print $(i + 1)}')
    case "$retr" in ''|*[!0-9]*) retr=unknown ;; esac

    echo "${mbps:-unknown} ${retr}"
}

echo "# ==== wifi-tx-test ===="
echo "kernel=$(uname -r)"
echo "hostname=$(hostname)"
echo "iface=$IFACE"
echo "ap_ssid=$AP_SSID"
echo "ap_freq_mhz=$FREQ"
echo "signal_dbm=$SIGNAL"
# The radio model lives on the remoteproc's iris child node; its compatible
# string is what the driver maps to a config table (qcom,wcn3620 /
# qcom,wcn3660b / qcom,wcn3680).  Report it verbatim -- for this bug the model
# is the single most important fact, because WCN3620 and WCN3660B share one
# config table and WCN3680 uses a different one.
wifi_chip=$(cat /sys/firmware/devicetree/base/soc@0/remoteproc@a204000/iris/compatible 2>/dev/null |
                tr -d '\0')
[ -n "$wifi_chip" ] || wifi_chip=$(find /sys/firmware/devicetree/base -path '*iris/compatible' 2>/dev/null |
                head -1 | xargs -r cat 2>/dev/null | tr -d '\0')
echo "wifi_chip=${wifi_chip:-unknown}"
echo "firmware=$(dmesg 2>/dev/null | sed -n "s/.*wcn36xx: firmware WLAN version '\([^']*\)'.*/\1/p" | tail -1)"
echo "driver_vermagic=$(modinfo -F vermagic wcn36xx 2>/dev/null)"
echo "driver_srcver=$(modinfo -F srcversion wcn36xx 2>/dev/null)"
echo "--- rates before traffic ---"
rate_line | sed 's/^/  /'

# Sample the PHY rate while a transfer is actually running: an idle link often
# reports a management/legacy rate, which is not the data rate under load.
( iperf3 -c "$PEER" -t "$DURATION" >/dev/null 2>&1 ) &
IPERF_PID=$!
sleep $(( DURATION / 2 ))
RATE_DURING=$(rate_line | tr '\n' ' ')
wait $IPERF_PID 2>/dev/null

up=$(iperf_run up)
echo "upload_mbps=$(echo "$up" | cut -d' ' -f1)"
echo "upload_retrans=$(echo "$up" | cut -d' ' -f2)"
echo "rate_during_upload=${RATE_DURING:-unknown}"

down=$(iperf_run down)
echo "download_mbps=$(echo "$down" | cut -d' ' -f1)"

echo "tx_retries=$(iw dev "$IFACE" station dump 2>/dev/null | sed -n 's/.*tx retries:[[:space:]]*//p' | head -1)"
echo "tx_failed=$(iw dev "$IFACE" station dump 2>/dev/null | sed -n 's/.*tx failed:[[:space:]]*//p' | head -1)"
echo "# ==== end ===="
