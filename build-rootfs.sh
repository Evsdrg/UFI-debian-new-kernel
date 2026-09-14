#!/usr/bin/env bash
# Debian 13 (trixie) arm64 rootfs builder for OpenStick (UFI103s/ufi003 为默认板)
# Rootless: mmdebstrap unshare mode + qemu-user binfmt, 后处理经 --customize-hook
#
# 网络方案: NetworkManager（为了方便用户上手；替代早期的 networkd + wpa_supplicant）。
#   wlan0   -> NM 管理 Wi-Fi（/etc/NetworkManager/system-connections/*.nmconnection）
#   4G/短信 -> ModemManager (mmcli/qmicli) + NM 管 wwan0，qrtr-ns/rmtfs 基础服务
#   交互    -> nmcli / nmtui（带中文，见 network-manager-l10n）
# 语言: zh_CN.UTF-8 为默认 locale。
set -euo pipefail

WORKDIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="$WORKDIR/out"
ROOTFS="${ROOTFS_PATH:-$OUT_DIR/trixie-arm64}"
MMDEBSTRAP_FORMAT="${MMDEBSTRAP_FORMAT:-directory}"
MIRROR="https://mirrors.cernet.edu.cn/debian"
KERNEL_RELEASE="${KERNEL_RELEASE:-6.18.48-ufi003-dirty}"
MODULE_TREE="${MODULE_TREE:-$OUT_DIR/modules-ufi003}"
RPMSG_MODULE_DIR="${RPMSG_MODULE_DIR:-$OUT_DIR/rpmsg-wwan-final}"

# network-manager-l10n 是 NetworkManager 的中文（及其它语言）翻译包，
# NM 主包只 Recommends 它，不显式安装的话 nmcli/nmtui 输出全是英文。
# manpages-zh 提供中文 man 手册；man-db 是 man 命令本身（缺它则 manpages-zh
# 只是躺在那儿的文件、`man` 命令根本不存在）。
PKGS_EXTRA="login,openssh-server,network-manager,network-manager-l10n,wpasupplicant,chrony,tzdata,kmod,udev,wireless-regdb,iproute2,iw,nano,less,\
e2fsprogs,modemmanager,libqmi-utils,qrtr-tools,rmtfs,usb-modeswitch,\
iperf3,\
ca-certificates,locales,man-db,manpages-zh"

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
# x-systemd.growfs 让 systemd 开机自动把文件系统撑满分区：rootfs 镜像是
# ~1G，而 p14 分区有 3.4G，不拉伸的话装完只剩一百多 MB 可用。有了它就不必
# 再手工 resize2fs（构建脚本仍会在刷机提示里提一句，作为兜底）。
mkdir -p "$STAGE/etc"
cat > "$STAGE/etc/fstab" <<'EOF'
# root by PARTUUID (mmcblk0p14)
PARTUUID=a7ab80e8-e9d1-e8cd-f157-93f69b1d141e  /      ext4  errors=remount-ro,x-systemd.growfs  0 1
EOF

# Headless appliance: never let debconf pick a dialog/Readline frontend.  The
# image ships no dialog/whiptail and no Term::ReadLine, so a frontend left at
# debconf's default (Dialog) makes every apt run print three "falling back to
# frontend" warnings.  This is the environment half of the fix; debconf's own
# database is seeded to Noninteractive by a hook further below.
printf 'DEBIAN_FRONTEND=noninteractive\n' > "$STAGE/etc/environment"

# ---------------------------------------------------------------- 语言（中文）
# 系统默认中文。仅写 locale.gen 是不够的：mmdebstrap 的 apt variant 不会跑
# locale-gen，不生成的话 `locale -a` 里没有 zh_CN，中文全是乱码/回退到 C。
# 真正的 locale-gen 与 LANG 在下面的 customize-hook 里做（需要 chroot）。
mkdir -p "$STAGE/etc/default"
cat > "$STAGE/etc/default/locale" <<'EOF'
# 由镜像构建脚本写入：系统默认中文（简体，UTF-8）
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

# ---------------------------------------------------------------- 网络（NetworkManager）
# 用 NetworkManager 而不是 networkd + wpa_supplicant：更方便用户上手
# （nmcli / nmtui 可交互配置，中文界面）。
mkdir -p "$STAGE/etc/NetworkManager/system-connections" \
         "$STAGE/etc/NetworkManager/conf.d"

# NM 主配置：keyfile 后端（Debian 默认），并让 NM 在启动时读取连接配置。
cat > "$STAGE/etc/NetworkManager/NetworkManager.conf" <<'EOF'
[main]
plugins=keyfile
# 让 NM 生成的配置也用 keyfile 格式，便于手工编辑
[keyfile]
unmanaged-devices=none
EOF

# WPA 漫游/节能等无线策略：交给 NM 默认值；这里只确保不把 wlan0 设为 unmanaged。
cat > "$STAGE/etc/NetworkManager/conf.d/10-openstick.conf" <<'EOF'
[device]
# wwan 由 ModemManager + NM 共同管理（NM 负责建立数据连接）
# 这里显式声明，避免某些版本把 wwan 当 unmanaged
match-device=type:wwan;type:wifi

[connection]
# DHCP 客户端拿不到地址时不要无限等待，快速失败便于换网络
ipv4.dhcp-timeout=30
ipv6.dhcp-timeout=30
EOF

# 预置 Wi-Fi 连接（keyfile 格式）。变量由环境提供；未提供则镜像不带预置 Wi-Fi，
# 用户可用 nmtui / nmcli 自己配。
if [[ -n "${ROOTFS_WIFI_SSID:-}" && -n "${ROOTFS_WIFI_PSK:-}" ]]; then
    _nm_wifi="$STAGE/etc/NetworkManager/system-connections/openstick-wifi.nmconnection"
    cat > "$_nm_wifi" <<EOF
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
    # NM 要求连接文件对其它用户不可读
    chmod 600 "$_nm_wifi"
fi

# 无线监管域（country），NM 自己有 wifi.country？NM 不自管监管域：由 wireless-regdb
# 与内核 cfg80211 决定，镜像里已把 regulatory.db 固定为 upstream 变体（见下方 hook）。
# 这里不改。

# ---------------------------------------------------------------- zram 等

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
# source of truth for both files and units.  The default file holds the knobs a
# board may need to override (LED names, wifi iface, red thresholds).
install -D -m 755 "$WORKDIR/tools/ufi-led-state.sh" "$STAGE/usr/local/sbin/ufi-led-state.sh"
install -D -m 644 "$WORKDIR/tools/ufi-led-state.service" "$STAGE/etc/systemd/system/ufi-led-state.service"
install -D -m 644 "$WORKDIR/tools/ufi-led-state.default" "$STAGE/etc/default/ufi-led-state"
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
  # rpmsg-wwan 是从 6.18.48 时代单独交付的模块；6.18.49 的模块树已经把它们
  # 编进去了（kernel/drivers/net/wwan/ 下就有）。所以这里只在树里确实缺
  # 这两个模块时才要求 RPMSG_MODULE_DIR，避免为了一个已经满足的前提而
  # 强迫使用者准备一份旧的 out/rpmsg-wwan-final。
  _wwandir="$STAGE/lib/modules/$KERNEL_RELEASE/kernel/drivers/net/wwan"
  for module in wwan.ko rpmsg_wwan_ctrl.ko; do
      if [[ -f "$_wwandir/$module" ]]; then
          continue
      fi
      if [[ -z "${RPMSG_MODULE_DIR:-}" || ! -f "$RPMSG_MODULE_DIR/$module" ]]; then
          echo "模块树里缺少 $_wwandir/$module，且 RPMSG_MODULE_DIR 未提供该文件" >&2
          echo "（请用 RPMSG_MODULE_DIR=<含 wwan.ko 与 rpmsg_wwan_ctrl.ko 的目录> 指定）" >&2
          exit 1
      fi
      install -D -m 0644 "$RPMSG_MODULE_DIR/$module" "$_wwandir/$module"
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
	# 中文 locale：既要写 locale.gen，也要真正生成（apt variant 不会自动跑
	# locale-gen）。不生成的话 LANG=zh_CN.UTF-8 无效，中文会回退成 C。
	'--customize-hook=sed -i '\''s/^# *\(zh_CN.UTF-8 UTF-8\)/\1/'\'' $1/etc/locale.gen'
	'--customize-hook=grep -q "^zh_CN.UTF-8 UTF-8" $1/etc/locale.gen || echo "zh_CN.UTF-8 UTF-8" >> $1/etc/locale.gen'
	'--customize-hook=chroot $1 locale-gen'
	'--customize-hook=chroot $1 locale -a | grep -qi "^zh_CN.utf8"'
	'--customize-hook=chroot $1 update-locale LANG=zh_CN.UTF-8 LANGUAGE=zh_CN:zh'
	"--customize-hook=mkdir -p \$1/root \$1/usr && cp -a --no-preserve=ownership $STAGE/etc/. \$1/etc/ && cp -a --no-preserve=ownership $STAGE/lib/. \$1/usr/lib/ && cp -a --no-preserve=ownership $STAGE/usr/. \$1/usr/ && cp -a --no-preserve=ownership $STAGE/root/. \$1/root/"
	# NetworkManager 会忽略组/其它用户可读的连接文件，预置 Wi-Fi 就失效了。
	# STAGE 上必须 chmod -R a+rX 才能让 hook 读到文件，那个会把这里的 600
	# 变成 644，所以拷进镜像后要重新收权。
	'--customize-hook=chmod 600 $1/etc/NetworkManager/system-connections/*.nmconnection 2>/dev/null || true'
	'--customize-hook=mkdir -p $1/dev/hugepages $1/dev/mqueue $1/run/lock $1/tmp && touch $1/dev/hugepages/.keep $1/dev/mqueue/.keep $1/run/lock/.keep $1/tmp/.keep'
	'--customize-hook=rm -f $1/etc/systemd/system/systemd-resolved.service.d/override.conf'
	# NetworkManager 接管网络：不再启用 networkd / 独立的 wpa_supplicant 实例。
	# NM 自己通过 D-Bus 拉起 wpa_supplicant（`wpa_supplicant -u -s` 那个全局
	# 实例），所以不需要 wpa_supplicant@<iface>.service，也不能让
	# wpa_supplicant.service 或 systemd-networkd 抢在 NM 前面占住 wlan0。
	#   （实测教训：只要 wpa_supplicant@wlan0 还在，NM 会反复报
	#    "wpa_supplicant couldn't grab this interface" 并最终放弃，
	#    设备开机后 wlan0 一直 unavailable。）
	'--customize-hook=mkdir -p $1/etc/systemd/system/multi-user.target.wants $1/etc/systemd/system/network-online.target.wants && ln -sf /lib/systemd/system/NetworkManager.service $1/etc/systemd/system/multi-user.target.wants/NetworkManager.service && ln -sf /lib/systemd/system/NetworkManager-wait-online.service $1/etc/systemd/system/network-online.target.wants/NetworkManager-wait-online.service && ln -sf /lib/systemd/system/systemd-resolved.service $1/etc/systemd/system/multi-user.target.wants/systemd-resolved.service && ln -sf /lib/systemd/system/ModemManager.service $1/etc/systemd/system/multi-user.target.wants/ModemManager.service && ln -sf /lib/systemd/system/rmtfs.service $1/etc/systemd/system/multi-user.target.wants/rmtfs.service && ln -sf /lib/systemd/system/qrtr-ns.service $1/etc/systemd/system/multi-user.target.wants/qrtr-ns.service && ln -sf /etc/systemd/system/zram-setup.service $1/etc/systemd/system/multi-user.target.wants/zram-setup.service && ln -sf /lib/systemd/system/chrony.service $1/etc/systemd/system/multi-user.target.wants/chrony.service && ln -sf /etc/systemd/system/ufi-led-state.service $1/etc/systemd/system/multi-user.target.wants/ufi-led-state.service && ln -sf /lib/systemd/system/multi-user.target $1/etc/systemd/system/default.target'
	# 清掉所有会与 NM 抢 wlan0 的启用项（networkd 的 socket 也要清，它会
	# 从 sockets.target 自动拉起 networkd）、以及早期 networkd 方案遗留的
	# 每接口 wpa_supplicant 配置。
	'--customize-hook=for u in systemd-networkd.service systemd-networkd.socket wpa_supplicant@wlan0.service wpa_supplicant.service; do rm -f $1/etc/systemd/system/multi-user.target.wants/$u $1/etc/systemd/system/sockets.target.wants/$u; done; rm -f $1/etc/systemd/system/dbus-org.freedesktop.network1.service $1/etc/wpa_supplicant/wpa_supplicant-wlan0.conf'
	# 断言：NM 已启用、networkd/每接口 wpa 未被启用（缺失符号链接即视为未启用）。
	'--customize-hook=test -L $1/etc/systemd/system/multi-user.target.wants/NetworkManager.service'
	'--customize-hook=test ! -e $1/etc/systemd/system/multi-user.target.wants/systemd-networkd.service'
	'--customize-hook=test ! -e $1/etc/systemd/system/sockets.target.wants/systemd-networkd.socket'
	'--customize-hook=test ! -e $1/etc/systemd/system/multi-user.target.wants/wpa_supplicant@wlan0.service'
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
