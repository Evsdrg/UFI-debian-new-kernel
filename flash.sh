#!/usr/bin/env bash
# UFI103s 刷机辅助脚本
#
# boot                   通过已验证的 SSH 通道刷写 boot（保留原流程）
# enter-fastboot         从在跑的 Linux 直接重启进 LK fastboot（见 FASTBOOT.md）
# fastboot-info          只读显示 fastboot 设备和分区变量
# fastboot-flash <part> <image>
#                        经 fastboot 刷指定分区（boot / rootfs），刷前校验 sha256
# fastboot-reboot        从 fastboot 回到正常启动
# fastboot-rootfs <partition>
#                        旧接口：不校验地刷一个 rootfs 分区名
#
# 刷任何分区前，必须先用 Miko 做整片 eMMC 全量备份。
set -euo pipefail

WORKDIR="$(cd "$(dirname "$0")" && pwd)"
# 设备地址是 DHCP 分配的，会变（历史上出现过 .102 与 .108）。用前先确认：
#   ping 一下，或 ip neigh 查 ARP 表。DEV 可用环境变量覆盖。
DEV="${DEV:-root@192.0.2.10}"
PW="${PW:-REDACTED}"
# 默认用本工作区的权威产物；均可用环境变量覆盖。
BOARD_DIR="${BOARD_DIR:-$WORKDIR/boards/ufi00x/ufi103s-ufi003/boot}"
ROOTFS_IMAGE="${ROOTFS_IMAGE:-$WORKDIR/shared/rootfs/debian13-arm64-ufi103s-6.18.49-chrony.ext4}"

run_dev() {
	expect -c "
	set timeout -1
	log_user 1
	spawn ssh -o StrictHostKeyChecking=no $DEV $*
	expect \"password:\"
	send \"$PW\r\"
	expect eof
	"
}

push_dev() {
	expect -c "
	set timeout -1
	log_user 0
	spawn scp -o StrictHostKeyChecking=no $1 $DEV:$2
	expect \"password:\"
	send \"$PW\r\"
	expect eof
	"
}

# 刷前对照同目录 build.json 里记录的 sha256，防止把变体刷错。
# 只有当 build.json 明确指向本镜像（boot_image 字段）或本镜像就是基线时，
# 才给出判定；否则只打印哈希，不做断言。
fb_verify() {
	local img="$1" sum
	sum="$(sha256sum "$img" | cut -d' ' -f1)"
	printf '  镜像  : %s\n  sha256: %s\n' "$img" "$sum"
	python3 - "$img" "$sum" <<'PY'
import json, glob, os, sys
img, sum_ = sys.argv[1], sys.argv[2]
base = os.path.basename(img)
strict = False
for j in sorted(glob.glob(os.path.join(os.path.dirname(img), '*build.json'))):
    try:
        d = json.load(open(j))
    except Exception:
        continue
    if not isinstance(d, dict):
        continue
    recs = [v for k, v in d.items()
            if k.endswith('sha256') and isinstance(v, str) and len(v) == 64]
    if d.get('boot_image') == base:
        strict = True
    elif base == 'boot-baseline.img' and not d.get('boot_image') and recs:
        strict = True
    else:
        continue
    if sum_ in recs:
        print(f"  校验  : 与 {os.path.basename(j)} 记录一致")
        sys.exit(0)
if strict:
    print("  校验  : 与 build.json 记录不一致，拒绝刷入", file=sys.stderr)
    sys.exit(1)
print("  校验  : 无随附记录可比对（仅打印哈希）")
PY
}

case "${1:-}" in
enter-fastboot)
	echo "=== 重启进 LK fastboot ==="
	cat >&2 <<'WARN'
警告：LK 的 fastboot 只从 USB 收命令，且没有超时自动回落。
      执行前请确认本机 USB 口接的是设备的数据口（不是只接了 UART 线或充电头）。
      接错的话设备会停在 fastboot，需要拔插一次才能回到 Linux。
WARN
	read -r -p "数据口已接在本机？输入 yes 继续: " _ack
	[[ "$_ack" == yes ]] || { echo "已取消。"; exit 1; }
	# 注意：不能写 `systemctl reboot bootloader` —— systemd 257 会报
	# "Too many arguments"，必须用 --reboot-argument=。已实测。
	run_dev "systemctl reboot --reboot-argument=bootloader" || true
	echo "已发出重启命令，等待 fastboot 设备出现…"
	# 实测：从发出命令到 fastboot 枚举完成约需 90-100 秒（关机 + LK 探测），
	# 所以这里给 150 秒窗口，别按 30 秒判失败。
	for _ in $(seq 1 75); do
		if fastboot devices 2>/dev/null | grep -q .; then
			echo "fastboot 设备已出现："
			fastboot devices
			exit 0
		fi
		sleep 2
	done
	echo "150 秒内未检测到 fastboot 设备。检查数据线；或按 reset 进 EDL 恢复。" >&2
	exit 1
	;;
fastboot-flash)
	_part="${2:-}"
	_img="${3:-}"
	case "$_part" in
		boot|rootfs) ;;
		*) echo "用法: $0 fastboot-flash <boot|rootfs> <image>" >&2; exit 2 ;;
	esac
	[[ -f "$_img" ]] || { echo "找不到镜像: $_img" >&2; exit 1; }
	echo "=== 刷前校验 ==="
	fb_verify "$_img"
	echo
	if [[ "$_part" == rootfs ]]; then
		# 实测：镜像（~964M）小于分区（3.4G），写入后文件系统仍是镜像的大小，
		# 不拉伸的话可用空间只剩 ~111M。LK 会拒绝等于分区大小的整分区镜像
		# （remote: 'size too large'），所以刷的必须是 rootfs 文件系统镜像本身。
		_img_sz=$(stat -c%s "$_img")
		echo "注意：刷完 rootfs 必须回系统执行 resize2fs 撑满分区，"
		echo "      否则可用空间只有镜像大小（实测约剩 111M）。"
		echo "      命令： ssh root@<设备> resize2fs /dev/mmcblk0p14"
		echo
	fi
	echo "目标分区: $_part"
	echo "刷任何分区前，请确认已用 Miko 做过整片 eMMC 全量备份。"
	fastboot devices
	if [[ "$_part" == rootfs ]]; then
		fastboot -S 200M flash "$_part" "$_img"
	else
		fastboot flash "$_part" "$_img"
	fi
	;;
fastboot-reboot)
	echo "=== 从 fastboot 回到正常启动 ==="
	fastboot devices
	fastboot reboot
	;;
boot)
	echo "=== 阶段1: 刷入 6.18 boot.img 到 mmcblk0p12 ==="
	BOOT_IMAGE="${BOOT_IMAGE:-$BOARD_DIR/boot-baseline.img}"
	if [[ ! -f "$BOOT_IMAGE" ]]; then
		echo "缺少 $BOOT_IMAGE" >&2
		echo "可用的本板镜像：" >&2
		ls "$BOARD_DIR"/boot-*.img >&2 2>/dev/null || echo "  (无)" >&2
		exit 1
	fi
	echo "设备: $DEV"
	echo "镜像: $BOOT_IMAGE"
	push_dev "$BOOT_IMAGE" /tmp/boot-new.img
	run_dev "dd if=/dev/mmcblk0p12 of=/root/boot-backup-5.15.img bs=1M 2>/dev/null; dd if=/tmp/boot-new.img of=/dev/mmcblk0p12 bs=1M conv=fsync; sync; echo FLASH_DONE"
	;;
fastboot-info)
	command -v fastboot >/dev/null
	fastboot devices
	fastboot getvar product 2>&1 || true
	fastboot getvar all 2>&1 || true
	;;
fastboot-rootfs)
	partition="${2:-}"
	if [[ -z "$partition" || "$partition" == -* || "$partition" == *[!A-Za-z0-9_.-]* ]]; then
		echo "用法: $0 fastboot-rootfs <已确认的 fastboot rootfs 分区名>" >&2
		exit 2
	fi
	if [[ ! -f "$ROOTFS_IMAGE" ]]; then
		echo "缺少 $ROOTFS_IMAGE，先运行 build-rootfs.sh 生成镜像" >&2
		exit 1
	fi
	echo "即将仅刷写 fastboot 分区: $partition"
echo "镜像: $ROOTFS_IMAGE"
	fastboot devices
	fastboot flash "$partition" "$ROOTFS_IMAGE"
	fastboot getvar product 2>&1 || true
	;;
rootfs)
	echo "已禁用运行中系统原地替换 rootfs；请使用 fastboot-rootfs <已确认分区名>。" >&2
	exit 2
	;;
*)
	echo "用法: $0 boot | enter-fastboot | fastboot-info | fastboot-reboot" >&2
	echo "      $0 fastboot-flash <boot|rootfs> <image>" >&2
	echo "      $0 fastboot-rootfs <partition>" >&2
	exit 2
	;;
esac
