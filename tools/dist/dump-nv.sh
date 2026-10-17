#!/bin/sh
# Dump this unit's WiFi calibration ("NV") data.
#
# Why this matters: WCNSS_qcom_wlan_nv.bin holds per-device radio calibration
# (transmit power, frequency offsets).  It is not interchangeable between
# physical units.  Any rootfs image built by someone else carries *their*
# calibration, which on your stick can mean no association, wrong power, or
# wrong channels.
#
# Run this on your device BEFORE flashing anything, keep the copy off the
# device, and restore it afterwards.
#
#   On the device:  ./dump-nv.sh [output-dir]
#
# The official path is what wcn36xx loads by default:
#   /lib/firmware/wlan/prima/WCNSS_qcom_wlan_nv.bin
# The driver honours a "firmware-name" property on the remoteproc node, so a
# board may point somewhere else; both are checked.

set -u

OUTDIR=${1:-.}
NAME=WCNSS_qcom_wlan_nv.bin

find_nv() {
    # Preferred: the exact path the driver is documented to use.
    if [ -f "/lib/firmware/wlan/prima/$NAME" ]; then
        echo "/lib/firmware/wlan/prima/$NAME"
        return
    fi
    # Fallback: whatever firmware-name the DT asks for.
    alt=$(cat /sys/firmware/devicetree/base/soc@0/remoteproc@a204000/firmware-name 2>/dev/null | tr -d '\0')
    if [ -n "${alt:-}" ] && [ -f "/lib/firmware/$alt" ]; then
        echo "/lib/firmware/$alt"
        return
    fi
    # Last resort: search, and report if it is ambiguous.
    hits=$(find /lib/firmware -name "$NAME" 2>/dev/null)
    n=$(echo "$hits" | grep -c . )
    if [ "$n" = 1 ]; then
        echo "$hits"
    elif [ "$n" -gt 1 ]; then
        echo "MULTIPLE:$hits"
    fi
}

SRC=$(find_nv)

case "$SRC" in
    MULTIPLE:*)
        echo "more than one $NAME found, refusing to guess:" >&2
        echo "$SRC" | tr ':' '\n' | sed '1d' >&2
        exit 1
        ;;
    '')
        echo "could not find $NAME under /lib/firmware" >&2
        echo "if your kernel was built with a different path, copy it manually" >&2
        exit 1
        ;;
esac

mkdir -p "$OUTDIR" || exit 1
DEST="$OUTDIR/$NAME"
cp "$SRC" "$DEST" || exit 1

echo "source=$SRC"
echo "saved=$DEST"
echo "size=$(wc -c < "$DEST")"
echo "sha256=$(sha256sum "$DEST" | cut -d' ' -f1)"
echo "mac=$(cat /sys/class/net/wlan0/address 2>/dev/null || echo unknown)"
echo
echo "Keep this file off the device. To restore after flashing:"
echo "  cp $DEST /lib/firmware/wlan/prima/$NAME && reboot"
