#!/usr/bin/env bash
# 103s - Debian 13 (trixie) arm64 rootfs builder for OpenStick UFI103s (ufi003)
# Run as normal user on x86_64 host with proot + qemu-user-static (binfmt) available.
set -euo pipefail

WORKDIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="$WORKDIR/out"
ROOTFS="$OUT_DIR/trixie-arm64"
MIRROR="https://mirrors.tuna.tsinghua.edu.cn/debian"
# 如需官方源换成 http://deb.debian.org/debian

PKGS_EXTRA="openssh-server,wpasupplicant,iproute2,iw,nano,less,e2fsprogs,\
systemd-resolved,modemmanager,libqmi-utils,qrtr-tools,rmtfs,usb-modeswitch,\
ca-certificates,apt-utils,locales"

mkdir -p "$OUT_DIR"

echo "==> Building trixie arm64 rootfs (rootless, proot mode) ..."
mmdebstrap --arch=arm64 \
	--mode=proot \
	--variant=apt \
	--include="$PKGS_EXTRA" \
	trixie "$ROOTFS" "$MIRROR"

echo "==> Injecting hostname / hosts ..."
echo "ufi103s" > "$ROOTFS/etc/hostname"
cat > "$ROOTFS/etc/hosts" <<'EOF'
127.0.0.1	localhost
127.0.1.1	ufi103s
::1		localhost ip6-localhost ip6-loopback
EOF

echo "==> Configuring serial console ..."
# msm8916 console 是 ttyMSM0 (blsp_uart2)
ln -sf /lib/systemd/system/serial-getty@.service \
	"$ROOTFS/etc/systemd/system/getty.target.wants/serial-getty@ttyMSM0.service"

echo "==> Network: wlan0 DHCP via systemd-networkd ..."
mkdir -p "$ROOTFS/etc/systemd/network"
cat > "$ROOTFS/etc/systemd/network/10-wlan0.network" <<'EOF'
[Match]
Name=wlan0

[Network]
DHCP=yes
EOF
mkdir -p "$ROOTFS/etc/systemd/system/systemd-networkd.service.wants"
ln -sf /lib/systemd/system/systemd-networkd.service \
	"$ROOTFS/etc/systemd/system/systemd-networkd.service.wants/systemd-networkd.service"
ln -sf /lib/systemd/system/systemd-resolved.service \
	"$ROOTFS/etc/systemd/system/systemd-networkd.service.wants/systemd-resolved.service"
ln -sf /run/systemd/resolve/stub-resolv.conf "$ROOTFS/etc/resolv.conf"

echo "==> Enabling services ..."
mkdir -p "$ROOTFS/etc/systemd/system/multi-user.target.wants"
for svc in ssh wpa_supplicant@wlan0 ModemManager rmtfs; do
	ln -sf "/lib/systemd/system/${svc}.service" \
		"$ROOTFS/etc/systemd/system/multi-user.target.wants/${svc}.service" 2>/dev/null || true
done

echo "==> Injecting firmware (from live device, known-good set) ..."
FW="$WORKDIR/firmware-from-device"
mkdir -p "$ROOTFS/lib/firmware"
cp -a "$FW/." "$ROOTFS/lib/firmware/"

echo "==> rootfs ready at $ROOTFS"
du -sh "$ROOTFS"
