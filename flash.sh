#!/usr/bin/env bash
# 103s - UFI103s 刷机辅助脚本
#
# boot           通过已验证的 SSH 通道刷写 boot（保留原流程）
# fastboot-info  只读显示 fastboot 设备和分区变量
# fastboot-rootfs <partition> 仅刷写明确指定的 rootfs 分区
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

case "${1:-}" in
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
	echo "用法: $0 boot | fastboot-info | fastboot-rootfs <partition>" >&2
	exit 2
	;;
esac
