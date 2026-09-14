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

# network-manager-l10n 提供 NetworkManager 的 zh_CN 翻译（主包只 Recommends 它）：
# 不装的话 nmcli/nmtui 输出是英文。manpages-zh 是中文 man 手册，man-db 是 man
# 命令本身（缺它则只有手册文件、没有 man 命令）。
PKGS_EXTRA="login,openssh-server,network-manager,network-manager-l10n,wpasupplicant,chrony,tzdata,kmod,udev,wireless-regdb,iproute2,iw,e2fsprogs,modemmanager,libqmi-utils,qrtr-tools,rmtfs,usb-modeswitch,iperf3,ca-certificates,locales,man-db,manpages-zh"
STAGE="$WORKDIR/build/rootfs-stage-common"
rm -rf "$STAGE"; mkdir -p "$STAGE/etc" "$STAGE/etc/NetworkManager/system-connections" "$STAGE/etc/NetworkManager/conf.d" "$STAGE/etc/systemd/system/rmtfs.service.d" "$STAGE/etc/systemd/system/sysinit.target.wants" "$STAGE/etc/modules-load.d" "$STAGE/lib/modules" "$STAGE/lib/firmware"

  if [[ -n "${ROOTFS_ROOT_PARTUUID:-}" ]]; then
    # x-systemd.growfs：开机自动把文件系统撑满分区（镜像比分区小，不拉伸会只剩
    # 一百多 MB 可用空间）。
    printf 'PARTUUID=%s / ext4 errors=remount-ro,x-systemd.growfs 0 1\n' "$ROOTFS_ROOT_PARTUUID" > "$STAGE/etc/fstab"
  else
  : > "$STAGE/etc/fstab"
fi
# Headless appliance: never let debconf pick a dialog/Readline frontend.  The
# image ships no dialog/whiptail and no Term::ReadLine, so a frontend left at
# debconf's default (Dialog) makes every apt run print three "falling back to
# frontend" warnings.  debconf's database is also seeded by a hook below.
printf 'DEBIAN_FRONTEND=noninteractive\n' > "$STAGE/etc/environment"

# 默认中文（真正生成在 customize-hook 里做）
mkdir -p "$STAGE/etc/default"
cat > "$STAGE/etc/default/locale" <<'EOF'
LANG=zh_CN.UTF-8
LANGUAGE=zh_CN:zh
LC_TIME=zh_CN.UTF-8
LC_MONETARY=zh_CN.UTF-8
LC_PAPER=zh_CN.UTF-8
LC_NAME=zh_CN.UTF-8
LC_ADDRESS=zh_CN.UTF-8
LC_TELEPHONE=zh_CN.UTF-8
LC_MEASUREMENT=zh_CN.UTF-8
EOF

# 网络改由 NetworkManager 管理
cat > "$STAGE/etc/NetworkManager/NetworkManager.conf" <<'EOF'
[main]
plugins=keyfile
[keyfile]
unmanaged-devices=none
EOF
cat > "$STAGE/etc/NetworkManager/conf.d/10-openstick.conf" <<'EOF'
[device]
match-device=type:wwan;type:wifi
[connection]
ipv4.dhcp-timeout=30
ipv6.dhcp-timeout=30
EOF
if [[ -n "${ROOTFS_WIFI_SSID:-}" && -n "${ROOTFS_WIFI_PSK:-}" ]]; then
cat > "$STAGE/etc/NetworkManager/system-connections/openstick-wifi.nmconnection" <<EOF
[connection]
id=openstick-wifi
type=wifi
autoconnect=true
autoconnect-priority=10
[wifi]
mode=infrastructure
ssid=${ROOTFS_WIFI_SSID}
[wifi-security]
key-mgmt=wpa-psk
psk=${ROOTFS_WIFI_PSK}
[ipv4]
method=auto
[ipv6]
method=auto
addr-gen-mode=stable-privacy
EOF
chmod 600 "$STAGE/etc/NetworkManager/system-connections/openstick-wifi.nmconnection"
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
  '--customize-hook=chmod 600 $1/etc/NetworkManager/system-connections/*.nmconnection 2>/dev/null || true' \
  '--customize-hook=ln -sf /usr/share/zoneinfo/Asia/Shanghai $1/etc/localtime && echo Asia/Shanghai > $1/etc/timezone' \
  '--customize-hook=sed -i "s/^# *\(zh_CN.UTF-8 UTF-8\)/\1/" $1/etc/locale.gen' \
  '--customize-hook=grep -q "^zh_CN.UTF-8 UTF-8" $1/etc/locale.gen || echo "zh_CN.UTF-8 UTF-8" >> $1/etc/locale.gen' \
  '--customize-hook=chroot $1 locale-gen' \
  '--customize-hook=chroot $1 locale -a | grep -qi "^zh_CN.utf8"' \
  '--customize-hook=chroot $1 update-locale LANG=zh_CN.UTF-8 LANGUAGE=zh_CN:zh' \
  '--customize-hook=mkdir -p $1/dev/hugepages $1/dev/mqueue $1/run/lock $1/tmp && touch $1/dev/hugepages/.keep $1/dev/mqueue/.keep $1/run/lock/.keep $1/tmp/.keep' \
  '--customize-hook=mkdir -p $1/etc/systemd/system/multi-user.target.wants $1/etc/systemd/system/sysinit.target.wants $1/etc/systemd/system/network-online.target.wants && ln -sf /lib/systemd/system/NetworkManager.service $1/etc/systemd/system/multi-user.target.wants/NetworkManager.service && ln -sf /lib/systemd/system/NetworkManager-wait-online.service $1/etc/systemd/system/network-online.target.wants/NetworkManager-wait-online.service && ln -sf /lib/systemd/system/systemd-resolved.service $1/etc/systemd/system/multi-user.target.wants/systemd-resolved.service && ln -sf /lib/systemd/system/ModemManager.service $1/etc/systemd/system/multi-user.target.wants/ModemManager.service && ln -sf /lib/systemd/system/rmtfs.service $1/etc/systemd/system/multi-user.target.wants/rmtfs.service && ln -sf /etc/systemd/system/zram-setup.service $1/etc/systemd/system/multi-user.target.wants/zram-setup.service && ln -sf /lib/systemd/system/chrony.service $1/etc/systemd/system/multi-user.target.wants/chrony.service && ln -sf /lib/systemd/system/multi-user.target $1/etc/systemd/system/default.target' \
  # 清掉会与 NetworkManager 抢 wlan0 的启用项（含 networkd 的 socket 激活）与
  # 早期 networkd 方案遗留的每接口 wpa_supplicant 配置。详见 build-rootfs.sh 里
  # 同段注释：只要 wpa_supplicant@wlan0 还在，NM 就抓不到网卡。
  '--customize-hook=for u in systemd-networkd.service systemd-networkd.socket wpa_supplicant@wlan0.service wpa_supplicant.service; do rm -f $1/etc/systemd/system/multi-user.target.wants/$u $1/etc/systemd/system/sockets.target.wants/$u; done; rm -f $1/etc/systemd/system/dbus-org.freedesktop.network1.service $1/etc/wpa_supplicant/wpa_supplicant-wlan0.conf' \
  '--customize-hook=test -L $1/etc/systemd/system/multi-user.target.wants/NetworkManager.service' \
  '--customize-hook=test ! -e $1/etc/systemd/system/multi-user.target.wants/systemd-networkd.service' \
  '--customize-hook=test ! -e $1/etc/systemd/system/multi-user.target.wants/wpa_supplicant@wlan0.service' \
  '--customize-hook=echo "debconf debconf/frontend select Noninteractive" | chroot $1 debconf-set-selections' \
  '--customize-hook=chroot $1 update-alternatives --set regulatory.db /lib/firmware/regulatory.db-upstream' \
  '--customize-hook=chroot $1 readlink /etc/alternatives/regulatory.db | grep -q regulatory.db-upstream' \
  '--customize-hook=mkdir -p $1/etc/ssh/sshd_config.d && printf "PasswordAuthentication no\nPermitRootLogin prohibit-password\n" > $1/etc/ssh/sshd_config.d/99-default-root-login.conf' \
  trixie "$ROOTFS" "$MIRROR"
rm -rf "$STAGE"
