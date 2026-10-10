#!/bin/sh
# native-net.service 的有界准备/清理；规则所有权仅为 inet openstick_usb。
set -eu
NFT=${NFT:-/usr/sbin/nft}
IP=${IP:-/usr/sbin/ip}
SYSCTL=${SYSCTL:-/usr/sbin/sysctl}
RULES=${USB_SHARE_RULES:-/etc/nftables.d/nat.nft}
case "${1:-}" in
start)
    ready=0
    for _ in $(seq 1 30); do
        if "$IP" -4 -o address show dev usb0 2>/dev/null | grep -q ' inet 10\.42\.0\.1/24 '; then
            ready=1; break
        fi
        sleep 1
    done
    [ "$ready" = 1 ] || { echo 'usb-share-native: usb0 地址未就绪' >&2; exit 1; }
    "$SYSCTL" -w net.ipv4.ip_forward=1 >/dev/null
    "$NFT" -f "$RULES"
    ;;
stop)
    # 表不存在是幂等停止；权限/内核错误不能被当成“表不存在”。
    tables=$("$NFT" list tables)
    if printf '%s\n' "$tables" | grep -qx 'table inet openstick_usb'; then
        "$NFT" delete table inet openstick_usb
    fi
    ;;
*) echo 'usage: usb-share-native.sh start|stop' >&2; exit 2 ;;
esac
