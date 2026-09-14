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
ROOTFS="${ROOTFS_PATH:-$OUT_DIR/trixie-arm64}"
MMDEBSTRAP_FORMAT="${MMDEBSTRAP_FORMAT:-directory}"
MIRROR="https://mirrors.cernet.edu.cn/debian"
KERNEL_RELEASE="${KERNEL_RELEASE:-6.18.48-ufi003-dirty}"
MODULE_TREE="${MODULE_TREE:-$OUT_DIR/modules-ufi003}"
RPMSG_MODULE_DIR="${RPMSG_MODULE_DIR:-$OUT_DIR/rpmsg-wwan-final}"

PKGS_EXTRA="login,openssh-server,wpasupplicant,systemd-resolved,chrony,tzdata,kmod,udev,wireless-regdb,iproute2,iw,nano,less,\
e2fsprogs,modemmanager,libqmi-utils,qrtr-tools,rmtfs,usb-modeswitch,\
iperf3,\
ca-certificates,locales"

# Variant hook: comma-separated extra packages (e.g. ffmpeg,v4l-utils) and
# additional module trees to ship alongside the primary one, so a variant
# kernel can boot from this image and a baseline kernel can still fall back.
if [[ -n "${EXTRA_PKGS:-}" ]]; then
    PKGS_EXTRA="$PKGS_EXTRA,$EXTRA_PKGS"
fi

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

# Headless appliance: never let debconf pick a dialog/Readline frontend.  The
# image ships no dialog/whiptail and no Term::ReadLine, so a frontend left at
# debconf's default (Dialog) makes every apt run print three "falling back to
# frontend" warnings.  This is the environment half of the fix; debconf's own
# database is seeded to Noninteractive by a hook further below.
printf 'DEBIAN_FRONTEND=noninteractive\n' > "$STAGE/etc/environment"

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
mkdir -p "$STAGE/etc/systemd/system" "$STAGE/etc/modules-load.d" "$STAGE/usr/local/sbin" "$STAGE/root"
mkdir -p "$STAGE/etc/systemd/system/rmtfs.service.d" "$STAGE/etc/systemd/system/sysinit.target.wants"

# Watchdog: the PM8916 PON watchdog accepts at most 127 s
# (drivers/watchdog/pm8916_wdt.c PM8916_WDT_MAX_TIMEOUT; DTS timeout-sec=60).
# systemd 257 defaults RebootWatchdogSec to 10min, which the hardware rejects
# ("Failed to set watchdog hardware timeout to 10min: Invalid argument") -- so a
# shutdown that wedges (e.g. remoteproc teardown) has no hardware recovery and
# the board hangs until a manual power cycle.  RuntimeWatchdogSec also makes
# ordinary kernel hangs self-recovering: verified on this board that a watchdog
# expiry does a clean PMIC hard reset and the system boots back (wdctl then
# reports CARDRESET=1, back online in ~20 s).
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
# LED status service and the Venus test harness live in tools/ as the single
# source of truth for both files and units.
install -D -m 755 "$WORKDIR/tools/ufi-led-state.sh" "$STAGE/usr/local/sbin/ufi-led-state.sh"
install -D -m 644 "$WORKDIR/tools/ufi-led-state.service" "$STAGE/etc/systemd/system/ufi-led-state.service"
install -D -m 755 "$WORKDIR/tools/venus-test.sh" "$STAGE/root/venus-test.sh"
install -D -m 755 "$WORKDIR/tools/venus-transcode.sh" "$STAGE/usr/local/sbin/venus-transcode.sh"
# Stable /dev/video-decoder + /dev/video-encoder names: the m2m node numbers are
# allocated dynamically and swap between boots (see the rule file for details).
install -D -m 644 "$WORKDIR/tools/70-venus-video.rules" "$STAGE/etc/udev/rules.d/70-venus-video.rules"
cat > "$STAGE/etc/modules-load.d/ufi003.conf" <<'EOF'
# UFI103s mainline hardware
wcn36xx
qcom_wcnss_pil
qcom_q6v5_mss
rmtfs_mem
qcom_bam_dmux
qrtr_smd
rpmsg_wwan_ctrl
zram
EOF

# rmtfs must start after the kernel has created its shared-memory device.
# The node is created by the rmtfs_mem module, so the matching systemd .device
# unit is not reliably active at boot and rmtfs would be skipped.  Start it from
# a udev rule when the node appears, and keep a short retry in the unit.
cat > "$STAGE/etc/udev/rules.d/60-rmtfs-autostart.rules" <<'EOF'
ACTION=="add", KERNEL=="qcom_rmtfs_mem1", SUBSYSTEM=="rmtfs", TAG+="systemd", ENV{SYSTEMD_WANTS}+="rmtfs.service"
EOF
mkdir -p "$STAGE/etc/systemd/system/rmtfs.service.d"
cat > "$STAGE/etc/systemd/system/rmtfs.service.d/ufi003.conf" <<'EOF'
[Unit]
Wants=systemd-modules-load.service
After=systemd-modules-load.service

[Service]
Restart=on-failure
RestartSec=2
ExecStartPre=/bin/sh -c 'for i in $(seq 1 60); do [ -e /dev/qcom_rmtfs_mem1 ] && exit 0; sleep 0.2; done; echo "rmtfs_mem1 never appeared" >&2; exit 1'
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

# The board has no battery-backed RTC: chronyd steps the 1970 clock on the
# first NTP reply (makestep), then keeps drift discipline across reboots.
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

# 内核模块(精简版 6.18.48-ufi003) + 固件(现机完整 firmware)
mkdir -p "$STAGE/lib/modules" "$STAGE/lib/firmware"
if [[ ! -d "$MODULE_TREE/lib/modules/$KERNEL_RELEASE" ]]; then
    echo "缺少匹配内核模块树: $MODULE_TREE/lib/modules/$KERNEL_RELEASE" >&2
    exit 1
fi
cp -a "$MODULE_TREE/lib/modules/"* "$STAGE/lib/modules/"
for module in wwan.ko rpmsg_wwan_ctrl.ko; do
    if [[ ! -f "$RPMSG_MODULE_DIR/$module" ]]; then
        echo "缺少匹配内核模块: $RPMSG_MODULE_DIR/$module" >&2
        exit 1
    fi
    install -D -m 0644 "$RPMSG_MODULE_DIR/$module" \
        "$STAGE/lib/modules/$KERNEL_RELEASE/kernel/drivers/net/wwan/$module"
done
if command -v depmod >/dev/null 2>&1; then
    depmod -b "$STAGE" "$KERNEL_RELEASE"
else
    echo "缺少 depmod，无法为 rootfs 生成模块索引" >&2
    exit 1
fi

# Extra module trees for variant kernels (comma-separated paths, each a
# MODULE_TREE-style root holding lib/modules/<release>/). Keeping the baseline
# tree in the image means a variant kernel can be reverted with a boot-only
# reflash. Indexes are rebuilt per release by depmod.
if [[ -n "${EXTRA_MODULE_TREES:-}" ]]; then
    IFS=',' read -r -a _extra_trees <<< "$EXTRA_MODULE_TREES"
    for _tree in "${_extra_trees[@]}"; do
        [[ -d "$_tree/lib/modules" ]] || { echo "缺少扩展模块树: $_tree" >&2; exit 1; }
        cp -a "$_tree/lib/modules/." "$STAGE/lib/modules/"
    done
    for _rel in "$STAGE"/lib/modules/*/; do
        depmod -b "$STAGE" "$(basename "$_rel")"
    done
fi

# Variant firmware overlay (e.g. venus.mbn naming for the Venus codec).
if [[ -n "${EXTRA_FIRMWARE_DIR:-}" ]]; then
    [[ -d "$EXTRA_FIRMWARE_DIR" ]] || { echo "缺少扩展固件目录: $EXTRA_FIRMWARE_DIR" >&2; exit 1; }
    cp -a "$EXTRA_FIRMWARE_DIR/." "$STAGE/lib/firmware/"
fi
cp -a "$WORKDIR/shared/firmware/common/." "$STAGE/lib/firmware/"
# wireless-regdb is installed by the Debian package above; do not overwrite
# its /usr/lib/firmware/regulatory.db alternatives symlink.

# Empty mountpoint directories need a placeholder to survive tar/copy hooks.
for dir in "$STAGE/dev/hugepages" "$STAGE/dev/mqueue" "$STAGE/run/lock" "$STAGE/tmp"; do
	mkdir -p "$dir"
	touch "$dir/.keep"
done
# wireless-regdb uses these exact filenames with cfg80211
cp -a "$WORKDIR/shared/firmware/common/"regulatory.db* "$STAGE/lib/firmware/" 2>/dev/null || true

# hook 以映射uid运行, 必须放宽stage目录读权限
chmod -R a+rX "$STAGE"

# ---- 构建 ----
echo "==> Building trixie arm64 rootfs (rootless, unshare + hooks) ..."
MMDEBSTRAP_ARGS=(
	--arch=arm64
	--mode=unshare
	--variant=apt
	--format="$MMDEBSTRAP_FORMAT"
	--include="$PKGS_EXTRA"
	'--customize-hook=echo ufi103s > $1/etc/hostname'
	'--customize-hook=printf '\''127.0.0.1\tlocalhost\n127.0.1.1\tufi103s\n::1\t\tlocalhost ip6-localhost ip6-loopback\n'\'' > $1/etc/hosts'
	'--customize-hook=ln -sf /lib/systemd/system/serial-getty@.service $1/etc/systemd/system/getty.target.wants/serial-getty@ttyMSM0.service'
	'--customize-hook=echo Asia/Shanghai > $1/etc/timezone && ln -sf /usr/share/zoneinfo/Asia/Shanghai $1/etc/localtime'
	'--customize-hook=echo '\''zh_CN.UTF-8 UTF-8'\'' >> $1/etc/locale.gen'
	"--customize-hook=mkdir -p \$1/root \$1/usr && cp -a --no-preserve=ownership $STAGE/etc/. \$1/etc/ && cp -a --no-preserve=ownership $STAGE/lib/. \$1/usr/lib/ && cp -a --no-preserve=ownership $STAGE/usr/. \$1/usr/ && cp -a --no-preserve=ownership $STAGE/root/. \$1/root/"
	'--customize-hook=mkdir -p $1/dev/hugepages $1/dev/mqueue $1/run/lock $1/tmp && touch $1/dev/hugepages/.keep $1/dev/mqueue/.keep $1/run/lock/.keep $1/tmp/.keep'
	'--customize-hook=rm -f $1/etc/systemd/system/systemd-resolved.service.d/override.conf'
	'--customize-hook=mkdir -p $1/etc/systemd/system/multi-user.target.wants && ln -sf /lib/systemd/system/systemd-networkd.service $1/etc/systemd/system/multi-user.target.wants/systemd-networkd.service && ln -sf /lib/systemd/system/systemd-resolved.service $1/etc/systemd/system/multi-user.target.wants/systemd-resolved.service && ln -sf /lib/systemd/system/wpa_supplicant@.service $1/etc/systemd/system/multi-user.target.wants/wpa_supplicant@wlan0.service && ln -sf /lib/systemd/system/ModemManager.service $1/etc/systemd/system/multi-user.target.wants/ModemManager.service && ln -sf /lib/systemd/system/rmtfs.service $1/etc/systemd/system/multi-user.target.wants/rmtfs.service && ln -sf /lib/systemd/system/qrtr-ns.service $1/etc/systemd/system/multi-user.target.wants/qrtr-ns.service && ln -sf /etc/systemd/system/zram-setup.service $1/etc/systemd/system/multi-user.target.wants/zram-setup.service && ln -sf /lib/systemd/system/chrony.service $1/etc/systemd/system/multi-user.target.wants/chrony.service && ln -sf /etc/systemd/system/ufi-led-state.service $1/etc/systemd/system/multi-user.target.wants/ufi-led-state.service && ln -sf /lib/systemd/system/multi-user.target $1/etc/systemd/system/default.target'
	'--customize-hook=printf '\''root:REDACTED\n'\'' | chroot $1 /usr/sbin/chpasswd'
	'--customize-hook=echo "debconf debconf/frontend select Noninteractive" | chroot $1 debconf-set-selections'
	# cfg80211 verifies regulatory.db against certificates built into the kernel.
	# This kernel carries the upstream certs (net/wireless/certs/wens.hex,
	# sforshee.hex), but wireless-regdb's postinst registers the Debian-signed
	# variant with priority 100 and upstream with 50, so the selected db fails
	# signature verification and cfg80211 silently falls back to the world
	# domain (country 00) -- which also ignores `iw reg set CN`.  Both variants
	# ship byte-identical db content (same sha256); they differ only in signer,
	# so selecting upstream changes no regulatory rule, only the signature.
	'--customize-hook=chroot $1 update-alternatives --set regulatory.db /lib/firmware/regulatory.db-upstream'
	'--customize-hook=chroot $1 readlink /etc/alternatives/regulatory.db | grep -q regulatory.db-upstream'
	'--customize-hook=mkdir -p $1/etc/ssh/sshd_config.d && printf '\''PermitRootLogin yes\nPasswordAuthentication yes\n'\'' > $1/etc/ssh/sshd_config.d/99-root-login.conf'
	trixie
	"$ROOTFS"
	"$MIRROR"
)
DEBIAN_FRONTEND=noninteractive mmdebstrap "${MMDEBSTRAP_ARGS[@]}"

rm -rf "$STAGE"
echo "==> rootfs ready at $ROOTFS"
du -sh "$ROOTFS" || true
