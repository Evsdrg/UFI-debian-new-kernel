#!/usr/bin/env bash
# Debian 13 (trixie) arm64 rootfs builder for OpenStick (默认板 UFI103s)
# Rootless: mmdebstrap unshare mode + qemu-user binfmt, 后处理经 --customize-hook
#
# 网络方案（ROOTFS_NET 二选一，见 BUILD-MATRIX.md）:
#   nm     NetworkManager（nmtui/nmcli，方便上手；默认）
#   native systemd-networkd + wpa_supplicant + dnsmasq + nftables（精简/省内存）
#   wlan0   -> NM 管理 Wi-Fi（/etc/NetworkManager/system-connections/*.nmconnection）
#   4G/短信 -> ModemManager (mmcli/qmicli) + NM 管 wwan0，qrtr-ns/rmtfs 基础服务
#   交互    -> nmcli / nmtui（带中文，见 network-manager-l10n）
# 语言: zh_CN.UTF-8 为默认 locale。
#
# 用法与环境变量（四个都容易漏，漏了会得到坏镜像或直接失败）：
#   MMDEBSTRAP_FORMAT=ext4   不写则默认 directory —— 只产出目录树，没有 .ext4 可刷
#   KERNEL_RELEASE=<release> 要与之配套的内核 release（默认从 kernel-version.env 派生）
#   MODULE_TREE=<dir>        该 release 的模块树根（含 lib/modules/<release>/）
#   EXTRA_MODULE_TREES=<dir>[,<dir>...]
#                            额外一并装入的模块树。给变体内核用时，把基线树也放进去，
#                            这样换回基线内核只刷 boot、不必重刷 rootfs。
#   EXTRA_FIRMWARE_DIR=<dir> 变体固件叠加（如 ufi103s-venus 的 venus.mbn）
#   EXTRA_PKGS=<pkg,...>     变体额外软件包（如 ffmpeg,v4l-utils）
#   ROOTFS_DESKTOP=0|1       是否装桌面/xrdp（默认 1）
#   ROOTFS_WIFI_SSID / ROOTFS_WIFI_PSK
#                            预置 Wi-Fi。**不传则镜像不带任何网络配置**，
#                            刷到无屏幕的棒子上会直接失联 —— 给别人刷机时务必传。
#   TMPDIR=<大盘上的目录>    mmdebstrap 的临时目录。若落在小容量 tmpfs（本机
#                            /tmp 是 11G tmpfs）上，装桌面包时会 "No space left
#                            on device" 而失败。
set -euo pipefail

WORKDIR="$(cd "$(dirname "$0")" && pwd)"
. "$WORKDIR/tools/kver.sh"
OUT_DIR="$WORKDIR/out"
# 默认产物名带档位与网络栈（ROOTFS_NET 在下方档位段解析后重建该默认值；
# 显式传 ROOTFS_PATH 时以显式值为准）。
ROOTFS="${ROOTFS_PATH:-}"
MMDEBSTRAP_FORMAT="${MMDEBSTRAP_FORMAT:-directory}"
MIRROR="https://mirrors.cernet.edu.cn/debian"
# KERNEL_RELEASE 由 tools/kver.sh 从 source/kernel-version.env 派生；
# MODULE_TREE 默认也指向该版本对应的模块树（可用环境变量覆盖）。
MODULE_TREE="${MODULE_TREE:-$MODULES_DIR}"
RPMSG_MODULE_DIR="${RPMSG_MODULE_DIR:-$OUT_DIR/rpmsg-wwan-final}"

# network-manager-l10n 是 NetworkManager 的中文（及其它语言）翻译包，
# NM 主包只 Recommends 它，不显式安装的话 nmcli/nmtui 输出全是英文。
# manpages-zh 提供中文 man 手册；man-db 是 man 命令本身（缺它则 manpages-zh
# 只是躺在那儿的文件、`man` 命令根本不存在）。
#
# 桌面 / 远程桌面（可选，用 DESKTOP=1 控制，见下方 ROOTFS_DESKTOP）：
#   xrdp + xorgxrdp      RDP 服务端（xorgxrdp 提供 xrdpdev_drv，纯软件虚拟显示，
#                        不依赖 DRM —— 这点很重要，我们的 GPU 是 render-only）
#   xserver-xorg-core    X 服务器
#   xserver-xorg-video-dummy  无头虚拟显示（xrdp 用得上）
#   xserver-xorg-legacy  Xwrapper.config 需要（放行非 console 用户启动 Xorg）
#   i3-wm/i3status/dmenu 轻量窗口管理器（376MB 内存下比 LXQt 合适）
#   xterm/x11-utils     基础 X 客户端与调试工具
#   fonts-wqy-microhei  中文点阵/矢量字体（5MB，比 fonts-noto-cjk 的 91MB 轻）

# ---- 基础包（所有档位都要）----
# login/shell/SSH/网络/时间/存储/固件加载 —— 这些是 Linux 的"核心功能"底座。
#
# systemd-sysv 必须**显式**列出来：它提供 /usr/sbin/init（→ /lib/systemd/systemd）。
# 它只是 systemd 的 Recommends，不显式要就会靠依赖链"碰巧"带进来——实测 tiny
# 档位移除 4G 包后那条链断了，镜像里没有 /sbin/init，内核找不到 init 直接落到
# /bin/sh，**系统起不来**（这种镜像刷上去就是砖，只能按复位键走 EDL 恢复）。
# 注意：网络管理器不在这里——NM 档加 network-manager，native 档用
# systemd-networkd + wpa_supplicant（wpasupplicant 两种栈都要，留在基线）。
PKGS_BASE="login,openssh-server,systemd-sysv,nano,less,bash,coreutils,util-linux,procps,\
wpasupplicant,wireless-regdb,iproute2,iw,iputils-ping,\
chrony,tzdata,kmod,udev,e2fsprogs,ca-certificates,dnsmasq"

# ---- 4G / 蜂窝（可用 ROOTFS_4G=0 关掉）----
# modemmanager 管 ModemManager 服务；qmi/qrtr/rmtfs 是 QMI 通道与 NV 存取；
# usb-modeswitch 处理模组从存储模式切到 modem 模式。
PKGS_4G="modemmanager,libqmi-utils,qrtr-tools,rmtfs,usb-modeswitch"

# ---- 中文化（可用 ROOTFS_ZH=0 关掉）----
# locales        ：提供 locale-gen/update-locale 与 /usr/share/i18n（**17MB 的大头**）
# network-manager-l10n：nmcli/nmtui 的中文翻译（NM 主包只 Recommends 它）
#   关掉中文时这两项都不装，LANG 改设 C.UTF-8 —— 它由 libc-bin 内建提供，
#   不依赖 locales 包，所以不装也能有 UTF-8 环境。
# network-manager-l10n 只在 NM 档追加（见下方 ROOTFS_NET 分支）
PKGS_ZH="locales"

# ---- 蓝牙（可用 ROOTFS_BT=0 关掉）----
# bluez 是 daemon + bluetoothctl/hciconfig 等工具（约 5.2MB）。
# 注意：`network-manager` 本身依赖 `libbluetooth3`（336KB），那个小库去不掉，
# 所以关蓝牙省的是 bluez 那 5MB，不是全部蓝牙相关。
PKGS_BT="bluez,rfkill"

# ---- 桌面 / 远程桌面（仅 full 档位）----
# xrdp + xorgxrdp 提供 RDP 服务端（xrdpdev_drv 是纯软件虚拟显示，不依赖 DRM
# —— 我们的 GPU 是 render-only，这点很重要）；i3 在 376MB 内存下比 LXQt 合适；
# fonts-wqy-microhei 是中文点阵/矢量字体（5MB，比 fonts-noto-cjk 的 91MB 轻）。
DESKTOP_PKGS="xrdp,xorgxrdp,xserver-xorg-core,xserver-xorg-video-dummy,xserver-xorg-legacy,\
xinit,x11-xserver-utils,x11-utils,dbus-x11,i3-wm,i3status,dmenu,xterm,scrot,rofi,autotiling,dunst,maim,slop,cbatticon,network-manager-gnome,\
fonts-wqy-microhei,fonts-dejavu-core,libgl1-mesa-dri,libgbm1,libegl1,libgles2,mesa-utils"

# ---- 文档（man 命令 + 中文手册）----
PKGS_DOC="man-db,manpages-zh"

# ---- 基准测试工具 ----
PKGS_BENCH="iperf3"

# 镜像档位与默认开关（2026-09-15 矩阵定稿，见 BUILD-MATRIX.md）：
#   max（F1 功能拉满）   桌面 i3+xrdp/GPU + 4G + 中文 + 蓝牙 + man + bench
#   basic（F2 基础套件） 4G + 中文 + 蓝牙，无 GPU/桌面
#   slim（F3 精简）      只保留 WiFi + 中文
#   micro（F4 深度精简） 只保留 WiFi，无中文
# 旧名兼容：full→max、minimal→basic、tiny→micro。
#
# 中文/蓝牙/4G 是三个**正交**维度，可用独立开关覆盖档位默认：
#   ROOTFS_ZH=0|1 / ROOTFS_BT=0|1 / ROOTFS_4G=0|1
# 网络栈由 ROOTFS_NET 选择：
#   ROOTFS_NET=nm|native（NM=NetworkManager；native=networkd+wpa_supplicant+
#   dnsmasq+nftables，USB 共享双档都是网关 10.42.0.1/24）
ROOTFS_FLAVOR="${ROOTFS_FLAVOR:-max}"
ROOTFS_NET="${ROOTFS_NET:-nm}"

case "$ROOTFS_NET" in
nm|native) ;;
*) echo "未知 ROOTFS_NET: $ROOTFS_NET（可选 nm|native）" >&2; exit 2 ;;
esac

case "$ROOTFS_FLAVOR" in
max|full)
    PKGS_EXTRA="$PKGS_BASE,$PKGS_DOC,$PKGS_BENCH,$DESKTOP_PKGS"
    _def_zh=1; _def_bt=1; _def_4g=1
    ;;
basic|minimal)
    PKGS_EXTRA="$PKGS_BASE"
    _def_zh=1; _def_bt=1; _def_4g=1
    ;;
slim)
    PKGS_EXTRA="$PKGS_BASE"
    _def_zh=1; _def_bt=0; _def_4g=0
    ;;
micro|tiny)
    PKGS_EXTRA="$PKGS_BASE"
    _def_zh=0; _def_bt=0; _def_4g=0
    ;;
*)
    echo "未知 ROOTFS_FLAVOR: $ROOTFS_FLAVOR（可选 max|basic|slim|micro，兼容 full|minimal|tiny）" >&2
    exit 2
    ;;
esac

case "$ROOTFS_NET" in
nm)
    # 两套网络栈都通过 nft 管理共享 NAT；NM 包本身不保证携带 nft。
    PKGS_EXTRA="network-manager,nftables,$PKGS_EXTRA"
    ;;
native)
    # nft 提供 nft 二进制（NAT）；networkd/dnsmasq 随 systemd/dnsmasq 已在
    PKGS_EXTRA="nftables,$PKGS_EXTRA"
    ;;
esac

ROOTFS_ZH="${ROOTFS_ZH:-$_def_zh}"
ROOTFS_BT="${ROOTFS_BT:-$_def_bt}"
ROOTFS_4G="${ROOTFS_4G:-$_def_4g}"
for _v in ZH BT 4G; do
    eval "_cur=\$ROOTFS_$_v"
    case "$_cur" in 0|1) ;; *) echo "ROOTFS_$_v 只能是 0 或 1（得到 '$_cur'）" >&2; exit 2 ;; esac
done
# 产物默认路径（带档位与网络栈；显式 ROOTFS_PATH 优先）
NETSFX=""; [[ "$ROOTFS_NET" == native ]] && NETSFX="-native"
ROOTFS="${ROOTFS_PATH:-$OUT_DIR/rootfs-$KERNEL_VERSION-$ROOTFS_FLAVOR$NETSFX}"

[[ "$ROOTFS_ZH" == 1 ]] && PKGS_EXTRA="$PKGS_EXTRA,$PKGS_ZH"
# NM 中文翻译只属于 nm 档
[[ "$ROOTFS_NET" == nm && "$ROOTFS_ZH" == 1 ]] && PKGS_EXTRA="$PKGS_EXTRA,network-manager-l10n"
[[ "$ROOTFS_BT" == 1 ]] && PKGS_EXTRA="$PKGS_EXTRA,$PKGS_BT"
[[ "$ROOTFS_4G" == 1 ]] && PKGS_EXTRA="$PKGS_EXTRA,$PKGS_4G"

# 桌面默认在 full 档位下装上；其它档位强制关闭（ROOTFS_DESKTOP=0 亦可显式关闭）。
ROOTFS_DESKTOP="${ROOTFS_DESKTOP:-$([[ $ROOTFS_FLAVOR == max || $ROOTFS_FLAVOR == full ]] && echo 1 || echo 0)}"
if [[ "$ROOTFS_DESKTOP" == 1 && "$ROOTFS_FLAVOR" != max && "$ROOTFS_FLAVOR" != full ]]; then
    echo "ROOTFS_DESKTOP=1 与 ROOTFS_FLAVOR=$ROOTFS_FLAVOR 冲突（该档位不含桌面）" >&2
    exit 2
fi
# 桌面需要中文字体/中文环境，和关中文是矛盾的。
if [[ "$ROOTFS_DESKTOP" == 1 && "$ROOTFS_ZH" == 0 ]]; then
    echo "ROOTFS_DESKTOP=1 需要 ROOTFS_ZH=1（桌面含中文字体）" >&2
    exit 2
fi

# ---- 体积裁剪：文档 / man / locale ----
# mmdebstrap 用 --dpkgopt 传 dpkg 的 path-exclude/path-include（不是 debootstrap
# 那种顶层 --path-exclude，写成后者会 "Unknown option" 直接失败）。
# 只在精简档位启用；copyright 按 Debian 政策必须保留，所以单独 include 回来。
PATH_EXCLUDES=()
if [[ "$ROOTFS_FLAVOR" != max && "$ROOTFS_FLAVOR" != full ]]; then
    PATH_EXCLUDES=(
        "--dpkgopt=path-exclude=/usr/share/doc/*"
        "--dpkgopt=path-include=/usr/share/doc/*/copyright"
        "--dpkgopt=path-exclude=/usr/share/man/*"
        "--dpkgopt=path-exclude=/usr/share/locale/*"
        "--dpkgopt=path-include=/usr/share/locale/locale.alias"
    )
    # 保留中文翻译仅当需要中文时；关掉中文则连 /usr/share/locale 下的中文一并裁掉。
    if [[ "$ROOTFS_ZH" == 1 ]]; then
        PATH_EXCLUDES+=("--dpkgopt=path-include=/usr/share/locale/zh_CN/*")
    fi
fi

# Variant hook: comma-separated extra packages (e.g. ffmpeg,v4l-utils) and
# additional module trees to ship alongside the primary one, so a variant
# kernel can boot from this image and a baseline kernel can still fall back.
if [[ -n "${EXTRA_PKGS:-}" ]]; then
    PKGS_EXTRA="$PKGS_EXTRA,$EXTRA_PKGS"
fi

mkdir -p "$OUT_DIR"

# ---- 准备要 copy-in 的素材 (hook 以映射uid执行, 需放宽读权限) ----
# STAGE 必须每次构建唯一：早先固定为 "$OUT_DIR/stage"，两个构建并行（或一个
# 刚删完 stage 另一个还在读）会互相踩——实测过 minimal 的镜像里混进了 tiny 的
# modules-load 内容，就是因为共用了这个目录。带上 flavor 与 PID 即可隔离。
STAGE="$OUT_DIR/stage-$ROOTFS_FLAVOR-$$"
rm -rf "$STAGE"; mkdir -p "$STAGE"
trap 'rm -rf "$STAGE"' EXIT

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

# ---------------------------------------------------------------- 语言
# 中文档位（ROOTFS_ZH=1）：系统默认中文。仅写 locale.gen 是不够的：
# mmdebstrap 的 apt variant 不会跑 locale-gen，不生成的话 `locale -a` 里没有
# zh_CN，中文全是乱码/回退到 C。真正的 locale-gen 在下面的 customize-hook 里做。
#
# 关中文档位（ROOTFS_ZH=0）：不装 locales 包，改用 **C.UTF-8** —— 它由 libc-bin
# 内建提供（/usr/lib/locale/C.utf8），不装 locales 也有 UTF-8 环境，只是没有
# 中文翻译与中文 locale 定义。
#
# 写的是 **/etc/locale.conf**，不是 /etc/default/locale：Debian 13 里后者是指向
# ../locale.conf 的符号链接，往它里面 cp 会两难——链接悬空时 cp 直接拒绝
# （"not writing through dangling symlink"），而它是否有效取决于 locales 包是否
# 安装。写规范目标 locale.conf 即可绕开（systemd 与 PAM 都直接读它）。
mkdir -p "$STAGE/etc"
if [[ "$ROOTFS_ZH" == 1 ]]; then
    cat > "$STAGE/etc/locale.conf" <<'EOF'
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
else
    cat > "$STAGE/etc/locale.conf" <<'EOF'
# 由镜像构建脚本写入：关掉中文的档位，用 C.UTF-8（libc-bin 内建提供）。
LANG=C.UTF-8
EOF
fi

# ---------------------------------------------------------------- 网络
# nm 档：NetworkManager（nmtui/nmcli，中文界面，方便上手）。
# native 档：systemd-networkd + wpa_supplicant@wlan0 + dnsmasq + nftables
# （USB 共享两档都是网关 10.42.0.1/24；当年的坑清单见 NETWORK.md）。
if [[ "$ROOTFS_NET" == nm ]]; then
mkdir -p "$STAGE/etc/NetworkManager/system-connections" \
         "$STAGE/etc/NetworkManager/conf.d"

# NM 主配置：keyfile 后端（Debian 默认），并让 NM 在启动时读取连接配置。
cat > "$STAGE/etc/NetworkManager/NetworkManager.conf" <<'EOF'
[main]
plugins=keyfile
firewall-backend=nftables
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
install -D -m 644 "$WORKDIR/tools/nm-connections/20-usb-managed.conf" \
    "$STAGE/etc/NetworkManager/conf.d/20-usb-managed.conf"

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

else
# ---------------- native（非 NM）网络栈 ----------------
NETDIR="$WORKDIR/tools/net-native"
mkdir -p "$STAGE/etc/systemd/network" "$STAGE/etc/dnsmasq.d" \
         "$STAGE/etc/nftables.d" "$STAGE/etc/wpa_supplicant" \
         "$STAGE/etc/systemd/system/multi-user.target.wants" \
         "$STAGE/etc/systemd/system/sockets.target.wants"

# networkd：usb0 固定网关 10.42.0.1，wlan0/wwan0 DHCP
install -D -m 644 "$NETDIR/10-usb0.network"  "$STAGE/etc/systemd/network/10-usb0.network"
install -D -m 644 "$NETDIR/20-wlan0.network" "$STAGE/etc/systemd/network/20-wlan0.network"
if [[ "$ROOTFS_4G" == 1 ]]; then
    install -D -m 644 "$NETDIR/25-wwan0.network" "$STAGE/etc/systemd/network/25-wwan0.network"
fi

# Wi-Fi 凭据（构建时预置；未提供则配置在位但不含网络，用户手改 conf）
WPA_CONF="$STAGE/etc/wpa_supplicant/wpa_supplicant-wlan0.conf"
{
    echo "# 由镜像构建脚本写入：native 档 wpa_supplicant 配置"
    echo "country=CN"
    echo "ctrl_interface=DIR=/run/wpa_supplicant GROUP=netdev"
    echo "update_config=1"
    if [[ -n "${ROOTFS_WIFI_SSID:-}" && -n "${ROOTFS_WIFI_PSK:-}" ]]; then
        echo "network={"
        echo "    ssid=\"${ROOTFS_WIFI_SSID}\""
        echo "    psk=\"${ROOTFS_WIFI_PSK}\""
        echo "    key_mgmt=WPA-PSK"
        echo "}"
    fi
} > "$WPA_CONF"
chmod 600 "$WPA_CONF"

# USB 共享：dnsmasq（DHCP+DNS）+ NAT 表 + 汇总服务
install -D -m 644 "$NETDIR/dnsmasq.conf" "$STAGE/etc/dnsmasq.d/usb-share.conf"
install -D -m 644 "$NETDIR/nat.nft"      "$STAGE/etc/nftables.d/nat.nft"
install -D -m 644 "$NETDIR/native-net.service" "$STAGE/etc/systemd/system/native-net.service"
install -D -m 755 "$NETDIR/usb-share.sh" "$STAGE/usr/local/sbin/usb-share-native.sh"
mkdir -p "$STAGE/etc/systemd/system/usb-gadget.service.d"
cat > "$STAGE/etc/systemd/system/usb-gadget.service.d/native.conf" <<'EOF'
[Unit]
Wants=native-net.service
EOF
if [[ "$ROOTFS_4G" == 1 ]]; then
    install -D -m 755 "$NETDIR/mm-connect.sh" "$STAGE/usr/local/sbin/mm-connect.sh"
fi

# 使能：networkd（服务+socket）、wpa_supplicant@wlan0、native-net
ln -sf /lib/systemd/system/systemd-networkd.service \
       "$STAGE/etc/systemd/system/multi-user.target.wants/systemd-networkd.service"
ln -sf /lib/systemd/system/systemd-networkd.socket \
       "$STAGE/etc/systemd/system/sockets.target.wants/systemd-networkd.socket"
ln -sf /lib/systemd/system/wpa_supplicant@.service \
       "$STAGE/etc/systemd/system/multi-user.target.wants/wpa_supplicant@wlan0.service"
ln -sf /etc/systemd/system/native-net.service \
       "$STAGE/etc/systemd/system/multi-user.target.wants/native-net.service"
fi
# ---------------------------------------------------------------- /网络

# 无线监管域（country），NM 自己有 wifi.country？NM 不自管监管域：由 wireless-regdb
# 与内核 cfg80211 决定，镜像里已把 regulatory.db 固定为 upstream 变体（见下方 hook）。
# 这里不改。

# ---------------------------------------------------------------- zram 等

# zram: 376MiB RAM (measured), use zstd and enable at boot
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
# 开机加载的模块。4G 那一组（qcom_q6v5_mss / rmtfs_mem / qcom_bam_dmux /
# qrtr_smd / rpmsg_wwan_ctrl）只在 ROOTFS_4G=1 时列出；关掉 4G 就不加载它们，
# 免得为一个用不上的功能把 modem 固件拉起来、白占内存与功耗。
{
    echo "# UFI103s mainline hardware"
    echo "wcn36xx"
    echo "qcom_wcnss_pil"
    if [[ "$ROOTFS_4G" == 1 ]]; then
        echo "qcom_q6v5_mss"
        echo "rmtfs_mem"
        echo "qcom_bam_dmux"
        echo "qrtr_smd"
        echo "rpmsg_wwan_ctrl"
    fi
    echo "zram"
} > "$STAGE/etc/modules-load.d/ufi103s.conf"

# --- Adreno 306 GPU（render-only）---
# 只在 full 档位启用：精简档位不装 mesa（libgl1-mesa-dri 等），带上 drm/msm
# 只会白白占用内存与启动时间，而没有任何用户态能用它。
# gpu 节点在 msm8916.dtsi 里是 disabled，板级 DTS 打开后内核会建出 platform
# device；msm.ko 需要 separate_gpu_kms=1 才会走 render-only 路径（否则它会去
# 找不存在的显示组件）。详见 tools/msm-gpu-render-only.conf 的说明。
if [[ "$ROOTFS_FLAVOR" == max || "$ROOTFS_FLAVOR" == full ]]; then
    install -D -m 644 "$WORKDIR/tools/msm-gpu-render-only.conf" \
        "$STAGE/etc/modprobe.d/msm-gpu-render-only.conf"
    cat > "$STAGE/etc/modules-load.d/openstick-gpu.conf" <<'EOF'
# Adreno 306 GPU（render-only）。参数在 /etc/modprobe.d/msm-gpu-render-only.conf。
# 编解码（venus）与本项无关：venus 是独立的 V4L2 m2m 设备。
drm
msm
EOF
fi

# 上面写了"开机加载 drm/msm"，但如果主模块树里根本没有这两个模块，开机只会
# 静默失败（modprobe 报 "Module drm not found"），表现为 /dev/dri 缺失、GL 退回
# llvmpipe。GPU 模块只在 venus-4g-gpu 板型的模块树里
# （<版本>-ufix0x-venus-4g-gpu-dirty），纯 venus 板型（<版本>-ufix0x-venus-dirty）
# 不含它们——这里必须挡住这个错配。
if [[ "$ROOTFS_FLAVOR" == max || "$ROOTFS_FLAVOR" == full ]] && [[ ! -f "$STAGE/lib/modules/$KERNEL_RELEASE/kernel/drivers/gpu/drm/msm/msm.ko" ]]; then
    echo "警告：模块树里没有 msm.ko，但我们会启用开机加载 drm/msm。" >&2
    echo "      MODULE_TREE=$MODULE_TREE" >&2
    echo "      GPU 模块在 $MODULES_DIR_GPU（由 tools/build-gpu-variant.sh 产出）。" >&2
    echo "      若这块板子确实不要 GPU，请用 ROOTFS_FLAVOR=minimal 构建；" >&2
    echo "      若要 GPU，请把 MODULE_TREE 指向 GPU 树（并附 baseline 作 EXTRA_MODULE_TREES）。" >&2
fi

# --- 桌面 / 远程桌面（xrdp + i3）---
if [[ "$ROOTFS_DESKTOP" == 1 ]]; then
    # xrdp 以服务身份（非 console 用户）启动 Xorg；Debian 默认
    # allowed_users=console 会拒绝，必须放行。
    mkdir -p "$STAGE/etc/X11"
    cat > "$STAGE/etc/X11/Xwrapper.config" <<'EOF'
# 由 OpenStick 构建脚本写入：xrdp 会话需要非 console 用户也能启动 Xorg。
allowed_users=anybody
needs_root_rights=yes
EOF

    # root 的 xrdp 会话入口（登录后由 sesman 执行）
    install -D -m 755 "$WORKDIR/tools/desktop/xsession" "$STAGE/root/.xsession"

    # i3 配置：镜像里给 root 预置一份，避免首次登录弹配置向导
    install -D -m 644 "$WORKDIR/tools/desktop/i3-config" "$STAGE/root/.config/i3/config"

    # i3status 数据源（网络/负载/时间；MF32 电量模块实机校准后加）
    install -D -m 644 "$WORKDIR/tools/desktop/i3status.conf" "$STAGE/etc/i3status.conf"

    # 排错用的辅助脚本（在桌面里点开就能看 GPU/编解码/中文状态）
    install -D -m 755 "$WORKDIR/tools/desktop/gpu-status.sh" "$STAGE/usr/local/bin/gpu-status.sh"
    install -D -m 755 "$WORKDIR/tools/desktop/zh-check.sh" "$STAGE/usr/local/bin/zh-check.sh"
fi

# --- USB 网络共享（棒子本职：插 PC 即 RNDIS 网卡，网关 10.42.0.1/24）---
# 内核侧需要 CONFIGFS/RNDIS/extcon/HS-PHY 全内建（common-*-os.config 已设）。
# NM 档：usb-share 连接 ipv4.method=shared，NM 自动 DHCP/DNS/NAT（dnsmasq 按需
# 拉起，系统 dnsmasq 服务必须压制，否则抢 53 端口）；native 档资产在
# tools/net-native/；包与管理策略按 ROOTFS_NET 分支装配。
install -D -m 755 "$WORKDIR/tools/usb-gadget.sh" "$STAGE/usr/local/sbin/usb-gadget.sh"
install -D -m 644 "$WORKDIR/tools/usb-gadget.service" "$STAGE/etc/systemd/system/usb-gadget.service"
if [[ "$ROOTFS_NET" == nm ]]; then
    install -D -m 600 "$WORKDIR/tools/nm-connections/usb-share.nmconnection" \
        "$STAGE/etc/NetworkManager/system-connections/usb-share.nmconnection"
fi

# rmtfs must start after the kernel has created its shared-memory device.
# The node is created by the rmtfs_mem module, so the matching systemd .device
# unit is not reliably active at boot and rmtfs would be skipped.  Start it from
# a udev rule when the node appears, and keep a short retry in the unit.
cat > "$STAGE/etc/udev/rules.d/60-rmtfs-autostart.rules" <<'EOF'
ACTION=="add", KERNEL=="qcom_rmtfs_mem1", SUBSYSTEM=="rmtfs", TAG+="systemd", ENV{SYSTEMD_WANTS}+="rmtfs.service"
EOF
mkdir -p "$STAGE/etc/systemd/system/rmtfs.service.d"
cat > "$STAGE/etc/systemd/system/rmtfs.service.d/ufi103s.conf" <<'EOF'
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

# 内核模块($KERNEL_RELEASE) + 固件(现机完整 firmware)
mkdir -p "$STAGE/lib/modules" "$STAGE/lib/firmware"
if [[ ! -d "$MODULE_TREE/lib/modules/$KERNEL_RELEASE" ]]; then
    echo "缺少匹配内核模块树: $MODULE_TREE/lib/modules/$KERNEL_RELEASE" >&2
    exit 1
fi
  cp -a "$MODULE_TREE/lib/modules/"* "$STAGE/lib/modules/"
  # shared 的 nft CT/reject 是两栈的共同需求，缺模块时拒绝生成“可共享”镜像。
  for _m in net/netfilter/nft_ct.ko net/netfilter/nft_reject.ko \
            net/ipv4/netfilter/nft_reject_ipv4.ko net/ipv4/netfilter/nf_reject_ipv4.ko; do
      test -f "$STAGE/lib/modules/$KERNEL_RELEASE/kernel/$_m" || {
          echo "USB 共享缺模块: $_m" >&2; exit 1;
      }
  done
  # rpmsg-wwan 早期是单独交付的模块；现在各个模块树已经把它们
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

# 固件是体积大头：common/ 里 modem.* 有 39MB，而 WiFi/BT 只占 3MB。
# 关掉 4G 的档位不装 ModemManager、modules-load 也不拉 modem 模块，
# 这些固件永远不会被加载 —— 留着纯属浪费（能少 39MB，约 12% 的镜像）。
if [[ "$ROOTFS_4G" != 1 ]]; then
    rm -f "$STAGE/lib/firmware/"modem.* "$STAGE/lib/firmware/mba.mbn"
fi

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
# ---- 语言相关 hook（按 ROOTFS_ZH 生成）----
# 必须在数组字面量**之外**构建：bash 的数组字面量里只能放词或展开项，
# 不能写 if/赋值语句（写进去会 "未预期的记号 ("）。
LOCALE_HOOKS=()
if [[ "$ROOTFS_ZH" == 1 ]]; then
	# 中文 locale：既要写 locale.gen，也要真正生成（apt variant 不会自动跑
	# locale-gen）。不生成的话 LANG=zh_CN.UTF-8 无效，中文会回退成 C。
	# LANG 本身已由 $STAGE/etc/locale.conf 给到，这里不再用 update-locale
	# （它写的是 /etc/default/locale，而那是指向 locale.conf 的符号链接）。
	LOCALE_HOOKS=(
		'--customize-hook=sed -i '\''s/^# *\(zh_CN.UTF-8 UTF-8\)/\1/'\'' $1/etc/locale.gen'
		'--customize-hook=grep -q "^zh_CN.UTF-8 UTF-8" $1/etc/locale.gen || echo "zh_CN.UTF-8 UTF-8" >> $1/etc/locale.gen'
		'--customize-hook=chroot $1 locale-gen'
		'--customize-hook=chroot $1 locale -a | grep -qi "^zh_CN.utf8"'
		'--customize-hook=grep -q "^LANG=zh_CN.UTF-8" $1/etc/locale.conf'
	)
else
	# 无中文档位没有 locales 包（没有 locale-gen/update-locale），所以既不生成
	# 也不断言 zh_CN。改成断言 **C.UTF-8 可用** —— 它由 libc-bin 内建提供，
	# 是关掉中文后系统的 UTF-8 基础；这条断言能挡住"连 UTF-8 都没有"的镜像。
	LOCALE_HOOKS=(
		'--customize-hook=test -d $1/usr/lib/locale/C.utf8'
		'--customize-hook=grep -q "^LANG=C.UTF-8" $1/etc/locale.conf'
	)
fi

MMDEBSTRAP_ARGS=(
	--arch=arm64
	--mode=unshare
	--variant=apt
	--format="$MMDEBSTRAP_FORMAT"
	"--include=$PKGS_EXTRA"
	# 精简档位的体积裁剪（doc/man/非中文 locale）。数组为空时不展开任何参数。
	"${PATH_EXCLUDES[@]}"
	'--customize-hook=echo ufi103s > $1/etc/hostname'
	'--customize-hook=printf '\''127.0.0.1\tlocalhost\n127.0.1.1\tufi103s\n::1\t\tlocalhost ip6-localhost ip6-loopback\n'\'' > $1/etc/hosts'
	'--customize-hook=ln -sf /lib/systemd/system/serial-getty@.service $1/etc/systemd/system/getty.target.wants/serial-getty@ttyMSM0.service'
	'--customize-hook=echo Asia/Shanghai > $1/etc/timezone && ln -sf /usr/share/zoneinfo/Asia/Shanghai $1/etc/localtime'

	"--customize-hook=mkdir -p \$1/root \$1/usr && cp -a --no-preserve=ownership $STAGE/etc/. \$1/etc/ && cp -a --no-preserve=ownership $STAGE/lib/. \$1/usr/lib/ && cp -a --no-preserve=ownership $STAGE/usr/. \$1/usr/ && cp -a --no-preserve=ownership $STAGE/root/. \$1/root/"
	# 语言 hooks 放在 STAGE 拷贝**之后**：它们要断言/依赖 $STAGE 里的文件
	# （如 /etc/default/locale）。放在拷贝之前会因文件还不存在而失败。
	"${LOCALE_HOOKS[@]}"
	# NetworkManager 会忽略组/其它用户可读的连接文件，预置 Wi-Fi 就失效了。
	# STAGE 上必须 chmod -R a+rX 才能让 hook 读到文件，那个会把这里的 600
	# 变成 644，所以拷进镜像后要重新收权。
	'--customize-hook=chmod 600 $1/etc/NetworkManager/system-connections/*.nmconnection $1/etc/wpa_supplicant/wpa_supplicant-wlan0.conf 2>/dev/null || true'
	'--customize-hook=if test -f $1/lib/systemd/system/dnsmasq.service; then ln -sf /dev/null $1/etc/systemd/system/dnsmasq.service; rm -f $1/etc/systemd/system/multi-user.target.wants/dnsmasq.service $1/lib/systemd/system/multi-user.target.wants/dnsmasq.service; fi' \
	'--customize-hook=mkdir -p $1/dev/hugepages $1/dev/mqueue $1/run/lock $1/tmp && touch $1/dev/hugepages/.keep $1/dev/mqueue/.keep $1/run/lock/.keep $1/tmp/.keep'
	'--customize-hook=rm -f $1/etc/systemd/system/systemd-resolved.service.d/override.conf'
	# NetworkManager 接管网络：不再启用 networkd / 独立的 wpa_supplicant 实例。
	# NM 自己通过 D-Bus 拉起 wpa_supplicant（`wpa_supplicant -u -s` 那个全局
	# 实例），所以不需要 wpa_supplicant@<iface>.service，也不能让
	# wpa_supplicant.service 或 systemd-networkd 抢在 NM 前面占住 wlan0。
	#   （实测教训：只要 wpa_supplicant@wlan0 还在，NM 会反复报
	#    "wpa_supplicant couldn't grab this interface" 并最终放弃，
	#    设备开机后 wlan0 一直 unavailable。）
	# 启用系统服务。用循环 + 存在性判断，这样精简档位（没有 ModemManager /
	# rmtfs / qrtr-ns 包）不会留下指向不存在单元的悬空软链。
	'--customize-hook=mkdir -p $1/etc/systemd/system/multi-user.target.wants $1/etc/systemd/system/network-online.target.wants && for s in NetworkManager.service ModemManager.service rmtfs.service qrtr-ns.service chrony.service bluetooth.service usb-gadget.service; do for d in /lib/systemd/system /etc/systemd/system; do if test -f $1$d/$s; then ln -sf $d/$s $1/etc/systemd/system/multi-user.target.wants/$s; break; fi; done; done && for n in NetworkManager-wait-online.service; do if test -f $1/lib/systemd/system/$n; then ln -sf /lib/systemd/system/$n $1/etc/systemd/system/network-online.target.wants/$n; fi; done && { test -f $1/lib/systemd/system/systemd-resolved.service && ln -sf /lib/systemd/system/systemd-resolved.service $1/etc/systemd/system/multi-user.target.wants/systemd-resolved.service || true; } && ln -sf /etc/systemd/system/zram-setup.service $1/etc/systemd/system/multi-user.target.wants/zram-setup.service && ln -sf /etc/systemd/system/ufi-led-state.service $1/etc/systemd/system/multi-user.target.wants/ufi-led-state.service && ln -sf /lib/systemd/system/multi-user.target $1/etc/systemd/system/default.target'
	# （仅 nm 档）清掉所有会与 NM 抢 wlan0 的启用项（networkd 的 socket 也要
	# 清，它会从 sockets.target 自动拉起 networkd）。native 档没有 NM，不存在
	# 抢占，反而依赖这些单元——上面的钩子按"镜像里有无 NM 二进制"自动跳过。
	'--customize-hook=if test -f $1/usr/sbin/NetworkManager; then for u in systemd-networkd.service systemd-networkd.socket wpa_supplicant@wlan0.service wpa_supplicant.service; do rm -f $1/etc/systemd/system/multi-user.target.wants/$u $1/etc/systemd/system/sockets.target.wants/$u; done; rm -f $1/etc/systemd/system/dbus-org.freedesktop.network1.service $1/etc/wpa_supplicant/wpa_supplicant-wlan0.conf; fi'
	'--customize-hook=test -x $1/usr/sbin/nft && test -x $1/usr/sbin/dnsmasq && test -x $1/usr/local/sbin/usb-gadget.sh'
	# USB 管理权不能靠开机后手工 nmcli；native 也必须携带自己的准备/清理程序。
	'--customize-hook=if test -f $1/usr/sbin/NetworkManager; then test -f $1/etc/NetworkManager/conf.d/20-usb-managed.conf && grep -q "^managed=1$" $1/etc/NetworkManager/conf.d/20-usb-managed.conf; else test -x $1/usr/local/sbin/usb-share-native.sh; fi'
	# 断言：NM 已启用、networkd/每接口 wpa 未被启用（缺失符号链接即视为未启用）。
	'--customize-hook=if test -f $1/usr/sbin/NetworkManager; then test -L $1/etc/systemd/system/multi-user.target.wants/NetworkManager.service; fi'
	'--customize-hook=if test -f $1/usr/sbin/NetworkManager; then test ! -e $1/etc/systemd/system/multi-user.target.wants/systemd-networkd.service; fi'
	'--customize-hook=if test -f $1/usr/sbin/NetworkManager; then test ! -e $1/etc/systemd/system/sockets.target.wants/systemd-networkd.socket; fi'
	'--customize-hook=if test -f $1/usr/sbin/NetworkManager; then test ! -e $1/etc/systemd/system/multi-user.target.wants/wpa_supplicant@wlan0.service; fi'
	# 桌面：启用 xrdp 与其会话管理器（xrdp 依赖 xrdp-sesman 拉起会话）。
	'--customize-hook=if test -f $1/lib/systemd/system/xrdp.service; then mkdir -p $1/etc/systemd/system/multi-user.target.wants && ln -sf /lib/systemd/system/xrdp.service $1/etc/systemd/system/multi-user.target.wants/xrdp.service && ln -sf /lib/systemd/system/xrdp-sesman.service $1/etc/systemd/system/multi-user.target.wants/xrdp-sesman.service; fi'
	'--customize-hook=if test -f $1/lib/systemd/system/xrdp.service; then test -L $1/etc/systemd/system/multi-user.target.wants/xrdp.service; fi'
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

# ---- 可选：收缩镜像文件体积 ----
# mmdebstrap 按内部估算给 ext4 留了很多空闲块与 inode 表，导致文件比实际内容大
# 几十 MB（实测 tiny：299MB 文件 vs 213MB 内容）。刷到设备后 fstab 的
# x-systemd.growfs 会把文件系统撑满分区，所以那些预留本来不占实机空间——但对
# **分发文件**来说是要下载/传输的体积。
#
# ROOTFS_SHRINK=1 时：先 resize2fs -M 压到最小，再放大到「内容 + 余量」。
# 必须留余量：-M 之后空闲块只剩几百个，作为可写根会立刻 "No space left on
# device"（实测 QEMU 里 13 个单元 FAILED）。余量默认 25%，不足则至少 32MB。
if [[ "${ROOTFS_SHRINK:-0}" == 1 && "$MMDEBSTRAP_FORMAT" == ext4 ]]; then
    echo "==> 收缩镜像文件体积..."
    _before=$(( $(stat -c%s "$ROOTFS") / 1048576 ))
    e2fsck -fy "$ROOTFS" >/dev/null 2>&1 || true
    if resize2fs -M "$ROOTFS" >/dev/null 2>&1; then
        # -M 之后文件大小就是「最小文件系统」大小，以此为基础加余量。
        # （注意别用 du -sm 去量：它对**文件**返回的是文件大小而非内容占用，
        #   在 -M 之前拿到的是 padding 后的大小，再加 25% 反而会变大。）
        # 余量给 32MB 固定值而不是百分比：设备上 fstab 的 x-systemd.growfs
        # 开机会把文件系统撑满 3.3GB 分区，所以镜像内的余量只用于「growfs 之前」
        # 那几秒的写入，不需要按比例留大。
        _min=$(( $(stat -c%s "$ROOTFS") / 1048576 ))
        _target=$(( _min + 32 ))
        (( _target > _before )) && _target=$_before   # 绝不比原文件更大
        resize2fs "$ROOTFS" "${_target}M" >/dev/null 2>&1 || true
        printf '    文件 %sMB → %sMB（最小 %sMB + %sMB 余量）\n' \
            "$_before" "$(( $(stat -c%s "$ROOTFS") / 1048576 ))" \
            "$_min" "$(( _target - _min ))"
    else
        echo "    resize2fs -M 不可用，跳过（仅影响文件体积，不影响内容）" >&2
    fi
fi

# STAGE 由 EXIT trap 清理（成功与失败都清）。
echo "==> rootfs ready at $ROOTFS"
du -sh "$ROOTFS" || true
