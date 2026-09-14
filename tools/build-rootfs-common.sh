#!/usr/bin/env bash
set -euo pipefail

WORKDIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$WORKDIR/shared/rootfs}"
ROOTFS="${ROOTFS_PATH:-$OUT_DIR/debian13-arm64-common-6.18.49.ext4}"
MMDEBSTRAP_FORMAT="${MMDEBSTRAP_FORMAT:-ext4}"
MIRROR="${MIRROR:-https://mirrors.cernet.edu.cn/debian}"
KERNEL_RELEASE="${KERNEL_RELEASE:-6.18.49-ufi003-dirty}"
MODULE_TREE="${MODULE_TREE:-$WORKDIR/shared/modules/6.18.49-ufi003-dirty}"
FIRMWARE_DIR="${FIRMWARE_DIR:-$WORKDIR/shared/firmware/common}"
PROFILE="${ROOTFS_PROFILE:-$WORKDIR/tools/rootfs-common.env}"
[[ -f "$PROFILE" ]] && . "$PROFILE"

PKGS_EXTRA="login,openssh-server,wpasupplicant,systemd-resolved,chrony,tzdata,kmod,udev,wireless-regdb,iproute2,iw,e2fsprogs,modemmanager,libqmi-utils,qrtr-tools,rmtfs,usb-modeswitch,iperf3,ca-certificates,locales"
STAGE="$WORKDIR/build/rootfs-stage-common"
rm -rf "$STAGE"; mkdir -p "$STAGE/etc" "$STAGE/etc/systemd/network" "$STAGE/etc/wpa_supplicant" "$STAGE/etc/systemd/system/rmtfs.service.d" "$STAGE/etc/systemd/system/sysinit.target.wants" "$STAGE/etc/modules-load.d" "$STAGE/lib/modules" "$STAGE/lib/firmware"

if [[ -n "${ROOTFS_ROOT_PARTUUID:-}" ]]; then
  printf 'PARTUUID=%s / ext4 errors=remount-ro 0 1\n' "$ROOTFS_ROOT_PARTUUID" > "$STAGE/etc/fstab"
else
  : > "$STAGE/etc/fstab"
fi
# Headless appliance: never let debconf pick a dialog/Readline frontend.  The
# image ships no dialog/whiptail and no Term::ReadLine, so a frontend left at
# debconf's default (Dialog) makes every apt run print three "falling back to
# frontend" warnings.  debconf's database is also seeded by a hook below.
printf 'DEBIAN_FRONTEND=noninteractive\n' > "$STAGE/etc/environment"
cat > "$STAGE/etc/systemd/network/20-wlan0.network" <<'EOF'
[Match]
Name=wlan0
[Network]
DHCP=yes
IPv6AcceptRA=yes
EOF
if [[ -n "${ROOTFS_WIFI_SSID:-}" && -n "${ROOTFS_WIFI_PSK:-}" ]]; then
cat > "$STAGE/etc/wpa_supplicant/wpa_supplicant-wlan0.conf" <<EOF
ctrl_interface=/run/wpa_supplicant
update_config=1
country=CN
network={
    ssid="$ROOTFS_WIFI_SSID"
    psk="$ROOTFS_WIFI_PSK"
}
EOF
chmod 600 "$STAGE/etc/wpa_supplicant/wpa_supplicant-wlan0.conf"
fi
cat > "$STAGE/etc/modules-load.d/openstick-common.conf" <<'EOF'
wcn36xx
qcom_wcnss_pil
qcom_q6v5_mss
rmtfs_mem
qcom_bam_dmux
qrtr_smd
rpmsg_wwan_ctrl
zram
EOF
cat > "$STAGE/etc/systemd/system/rmtfs.service.d/common.conf" <<'EOF'
[Unit]
Wants=systemd-modules-load.service dev-qcom_rmtfs_mem1.device
After=systemd-modules-load.service dev-qcom_rmtfs_mem1.device
EOF
# CERNET apt mirror, baked into the image (verified: 302 -> 200, apt follows).
mkdir -p "$STAGE/etc/apt"
cat > "$STAGE/etc/apt/sources.list" <<'EOF'
deb https://mirrors.cernet.edu.cn/debian/ trixie main contrib non-free non-free-firmware
# deb-src https://mirrors.cernet.edu.cn/debian/ trixie main contrib non-free non-free-firmware

deb https://mirrors.cernet.edu.cn/debian/ trixie-updates main contrib non-free non-free-firmware
# deb-src https://mirrors.cernet.edu.cn/debian/ trixie-updates main contrib non-free non-free-firmware

deb https://mirrors.cernet.edu.cn/debian/ trixie-backports main contrib non-free non-free-firmware
# deb-src https://mirrors.cernet.edu.cn/debian/ trixie-backports main contrib non-free non-free-firmware

# 以下安全更新软件源为镜像站配置
deb https://mirrors.cernet.edu.cn/debian-security trixie-security main contrib non-free non-free-firmware
# deb-src https://mirrors.cernet.edu.cn/debian-security trixie-security main contrib non-free non-free-firmware
EOF

# No-RTC boards: chronyd steps the clock on the first NTP reply.
mkdir -p "$STAGE/etc/chrony"
cat > "$STAGE/etc/chrony/chrony.conf" <<'EOF'
confdir /etc/chrony/conf.d
sourcedir /etc/chrony/sources.d
server ntp.aliyun.com iburst
server ntp1.aliyun.com iburst
server ntp2.aliyun.com iburst
server ntp3.aliyun.com iburst
driftfile /var/lib/chrony/chrony.drift
makestep 1.0 -1
logchange 0.5
EOF
mkdir -p "$STAGE/etc/systemd/system"

# Keep the PM8916 PON watchdog inside its hardware range (1..127 s) for both the
# normal runtime and shutdown paths; systemd's 10min default is rejected by the
# hardware and leaves a wedged shutdown with no recovery.  See the long comment
# in build-rootfs.sh.
mkdir -p "$STAGE/etc/systemd/system.conf.d"
cat > "$STAGE/etc/systemd/system.conf.d/10-watchdog.conf" <<'EOF'
[Manager]
RuntimeWatchdogSec=60s
RebootWatchdogSec=60s
EOF

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
for dir in "$STAGE/dev/hugepages" "$STAGE/dev/mqueue" "$STAGE/run/lock" "$STAGE/tmp"; do mkdir -p "$dir"; touch "$dir/.keep"; done
cp -a "$MODULE_TREE/lib/modules" "$STAGE/lib/"
cp -a "$FIRMWARE_DIR/." "$STAGE/lib/firmware/"
depmod -b "$STAGE" "$KERNEL_RELEASE"
chmod -R a+rX "$STAGE"
mkdir -p "$OUT_DIR"
DEBIAN_FRONTEND=noninteractive mmdebstrap --arch=arm64 --mode=unshare --variant=apt --format="$MMDEBSTRAP_FORMAT" --include="$PKGS_EXTRA" \
  "--customize-hook=echo ${ROOTFS_HOSTNAME:-openstick} > \$1/etc/hostname" \
  '--customize-hook=printf "127.0.0.1\tlocalhost\n::1\tlocalhost\n" > $1/etc/hosts' \
  '--customize-hook=ln -sf /lib/systemd/system/serial-getty@.service $1/etc/systemd/system/getty.target.wants/serial-getty@ttyMSM0.service' \
  "--customize-hook=mkdir -p \$1/root \$1/usr/lib && cp -a --no-preserve=ownership $STAGE/etc/. \$1/etc/ && cp -a --no-preserve=ownership $STAGE/lib/. \$1/usr/lib/" \
  '--customize-hook=ln -sf /usr/share/zoneinfo/Asia/Shanghai $1/etc/localtime && echo Asia/Shanghai > $1/etc/timezone' \
  '--customize-hook=mkdir -p $1/dev/hugepages $1/dev/mqueue $1/run/lock $1/tmp && touch $1/dev/hugepages/.keep $1/dev/mqueue/.keep $1/run/lock/.keep $1/tmp/.keep' \
  '--customize-hook=mkdir -p $1/etc/systemd/system/multi-user.target.wants $1/etc/systemd/system/sysinit.target.wants && ln -sf /lib/systemd/system/systemd-networkd.service $1/etc/systemd/system/multi-user.target.wants/systemd-networkd.service && ln -sf /lib/systemd/system/systemd-resolved.service $1/etc/systemd/system/multi-user.target.wants/systemd-resolved.service && ln -sf /lib/systemd/system/wpa_supplicant@.service $1/etc/systemd/system/multi-user.target.wants/wpa_supplicant@wlan0.service && ln -sf /lib/systemd/system/ModemManager.service $1/etc/systemd/system/multi-user.target.wants/ModemManager.service && ln -sf /lib/systemd/system/rmtfs.service $1/etc/systemd/system/multi-user.target.wants/rmtfs.service && ln -sf /etc/systemd/system/zram-setup.service $1/etc/systemd/system/multi-user.target.wants/zram-setup.service && ln -sf /lib/systemd/system/chrony.service $1/etc/systemd/system/multi-user.target.wants/chrony.service && ln -sf /lib/systemd/system/multi-user.target $1/etc/systemd/system/default.target' \
  '--customize-hook=echo "debconf debconf/frontend select Noninteractive" | chroot $1 debconf-set-selections' \
  '--customize-hook=chroot $1 update-alternatives --set regulatory.db /lib/firmware/regulatory.db-upstream' \
  '--customize-hook=chroot $1 readlink /etc/alternatives/regulatory.db | grep -q regulatory.db-upstream' \
  '--customize-hook=mkdir -p $1/etc/ssh/sshd_config.d && printf "PasswordAuthentication no\nPermitRootLogin prohibit-password\n" > $1/etc/ssh/sshd_config.d/99-default-root-login.conf' \
  trixie "$ROOTFS" "$MIRROR"
rm -rf "$STAGE"
