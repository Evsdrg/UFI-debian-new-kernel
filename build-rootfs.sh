#!/usr/bin/env bash
# 103s - Debian 13 (trixie) arm64 rootfs builder for OpenStick UFI103s (ufi003)
# Rootless: mmdebstrap unshare mode + qemu-user binfmt, 后处理经 --customize-hook
#
# 网络方案: systemd-networkd + wpa_supplicant (固定化配置)，不装 NetworkManager。
#   wlan0   -> wpa_supplicant@wlan0 认证, systemd-networkd 配 IP/DHCP
#   4G/短信 -> ModemManager (mmcli/qmicli), qrtr-ns/rmtfs 基础服务
set -euo pipefail

WORKDIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="$WORKDIR/out"
ROOTFS="$OUT_DIR/trixie-arm64"
MIRROR="https://mirrors.tuna.tsinghua.edu.cn/debian"

PKGS_EXTRA="openssh-server,wpasupplicant,systemd-resolved,kmod,udev,wireless-regdb,iproute2,iw,nano,less,\
e2fsprogs,modemmanager,libqmi-utils,qrtr-tools,rmtfs,usb-modeswitch,\
ca-certificates,locales"

mkdir -p "$OUT_DIR"

# ---- 准备要 copy-in 的素材 (hook 以映射uid执行, 需放宽读权限) ----
STAGE="$OUT_DIR/stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"

# fstab: only root is listed here. systemd owns /tmp and other virtual mounts.
mkdir -p "$STAGE/etc"
cat > "$STAGE/etc/fstab" <<'EOF'
# root by PARTUUID (mmcblk0p14)
PARTUUID=a7ab80e8-e9d1-e8cd-f157-93f69b1d141e  /      ext4  errors=remount-ro  0 1
EOF

# wpa_supplicant 固定配置: 连这台 Wi-Fi (REDACTED_SSID)
mkdir -p "$STAGE/etc/wpa_supplicant"
cat > "$STAGE/etc/wpa_supplicant/wpa_supplicant-wlan0.conf" <<'EOF'
ctrl_interface=/run/wpa_supplicant
update_config=1
country=CN

network={
    ssid="REDACTED_SSID"
    psk="qw123123"
    priority=10
}
EOF
chmod 600 "$STAGE/etc/wpa_supplicant/wpa_supplicant-wlan0.conf"

# systemd-networkd: wlan0 用 DHCP
mkdir -p "$STAGE/etc/systemd/network"
cat > "$STAGE/etc/systemd/network/20-wlan0.network" <<'EOF'
[Match]
Name=wlan0

[Network]
DHCP=yes
IPv6AcceptRA=yes
EOF

# zram: 461MiB RAM, use zstd and enable at boot
mkdir -p "$STAGE/etc/systemd/system" "$STAGE/etc/modules-load.d"
cat > "$STAGE/etc/systemd/system/zram-setup.service" <<'EOF'
[Unit]
Description=Setup zram swap (zstd)
After=local-fs.target
Before=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c "modprobe zram && echo zstd > /sys/block/zram0/comp_algorithm && echo 350M > /sys/block/zram0/disksize && mkswap /dev/zram0 && swapon -p 100 /dev/zram0"
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
cat > "$STAGE/etc/modules-load.d/ufi003.conf" <<'EOF'
# UFI103s mainline hardware
wcn36xx
qcom_wcnss_pil
qcom_q6v5_mss
qcom_bam_dmux
qrtr_smd
zram
EOF

# 内核模块(精简版 6.18.48-ufix0x) + 固件(现机完整 firmware)
mkdir -p "$STAGE/lib/modules" "$STAGE/lib/firmware"
cp -a "$OUT_DIR/modules-ufix0x/lib/modules/"* "$STAGE/lib/modules/"
cp -a "$WORKDIR/firmware-from-device/." "$STAGE/lib/firmware/"
# wireless-regdb is installed by the Debian package above; do not overwrite
# its /usr/lib/firmware/regulatory.db alternatives symlink.

# Empty mountpoint directories need a placeholder to survive tar/copy hooks.
for dir in "$STAGE/dev/hugepages" "$STAGE/dev/mqueue" "$STAGE/run/lock" "$STAGE/tmp"; do
	mkdir -p "$dir"
	touch "$dir/.keep"
done
# wireless-regdb uses these exact filenames with cfg80211
cp -a "$WORKDIR/firmware-from-device/"regulatory.db* "$STAGE/lib/firmware/" 2>/dev/null || true

# hook 以映射uid运行, 必须放宽stage目录读权限
chmod -R a+rX "$STAGE"

# ---- 构建 ----
echo "==> Building trixie arm64 rootfs (rootless, unshare + hooks) ..."
mmdebstrap --arch=arm64 \
	--mode=unshare \
	--variant=apt \
	--include="$PKGS_EXTRA" \
	--customize-hook="echo ufi103s > \$1/etc/hostname" \
	--customize-hook="printf '127.0.0.1\tlocalhost\n127.0.1.1\tufi103s\n::1\t\tlocalhost ip6-localhost ip6-loopback\n' > \$1/etc/hosts" \
	--customize-hook="ln -sf /lib/systemd/system/serial-getty@.service \$1/etc/systemd/system/getty.target.wants/serial-getty@ttyMSM0.service" \
	--customize-hook="echo Asia/Shanghai > \$1/etc/timezone" \
	--customize-hook="echo 'zh_CN.UTF-8 UTF-8' >> \$1/etc/locale.gen" \
	--customize-hook="mkdir -p \$1/root \$1/usr/lib && cp -a $STAGE/etc/. \$1/etc/ && cp -a $STAGE/lib/. \$1/usr/lib/" \
	--customize-hook="mkdir -p \$1/dev/hugepages \$1/dev/mqueue \$1/run/lock \$1/tmp && touch \$1/dev/hugepages/.keep \$1/dev/mqueue/.keep \$1/run/lock/.keep \$1/tmp/.keep" \
	--customize-hook="rm -f \$1/etc/systemd/system/systemd-resolved.service.d/override.conf" \
	--customize-hook="mkdir -p \$1/etc/systemd/system/multi-user.target.wants && ln -sf /lib/systemd/system/systemd-networkd.service \$1/etc/systemd/system/multi-user.target.wants/systemd-networkd.service && ln -sf /lib/systemd/system/systemd-resolved.service \$1/etc/systemd/system/multi-user.target.wants/systemd-resolved.service && ln -sf /lib/systemd/system/wpa_supplicant@.service \$1/etc/systemd/system/multi-user.target.wants/wpa_supplicant@wlan0.service && ln -sf /lib/systemd/system/ModemManager.service \$1/etc/systemd/system/multi-user.target.wants/ModemManager.service && ln -sf /lib/systemd/system/rmtfs.service \$1/etc/systemd/system/multi-user.target.wants/rmtfs.service && ln -sf /lib/systemd/system/qrtr-ns.service \$1/etc/systemd/system/multi-user.target.wants/qrtr-ns.service && ln -sf /etc/systemd/system/zram-setup.service \$1/etc/systemd/system/multi-user.target.wants/zram-setup.service && ln -sf /lib/systemd/system/multi-user.target \$1/etc/systemd/system/default.target" \
	--customize-hook="printf 'root:REDACTED\\n' | chroot \$1 /usr/sbin/chpasswd" \
	--customize-hook="mkdir -p \$1/etc/ssh/sshd_config.d && printf 'PermitRootLogin yes\\nPasswordAuthentication yes\\n' > \$1/etc/ssh/sshd_config.d/99-root-login.conf" \
	trixie "$ROOTFS" "$MIRROR"

rm -rf "$STAGE"
echo "==> rootfs ready at $ROOTFS"
du -sh "$ROOTFS" || true
