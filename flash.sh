#!/usr/bin/env bash
# 103s - UFI103s 刷机脚本
#
# 阶段1: 仅刷 boot.img (6.18内核) — 保留现有 Debian 11 rootfs, 验证内核启动
#   用法: ./flash.sh boot
# 阶段2: 替换 rootfs 为 Debian 13 trixie (需阶段1验证通过后执行)
#   用法: ./flash.sh rootfs
#
# 设备: root@192.0.2.14  密码: REDACTED
# 分区: boot=mmcblk0p12 (64MB)  rootfs=mmcblk0p14 (3.4GB, PARTUUID a7ab80e8-...)
set -euo pipefail

WORKDIR="$(cd "$(dirname "$0")" && pwd)"
DEV=root@192.0.2.14
PW=REDACTED

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

push_dev() {  # push_dev <local> <remote>
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
	echo "--- 推送 boot.img ---"
	push_dev "$WORKDIR/out/boot/boot-ufi003-6.18.img" /tmp/boot-new.img
	echo "--- 备份原boot(设备侧双保险) + 写入 ---"
	run_dev "dd if=/dev/mmcblk0p12 of=/root/boot-backup-5.15.img bs=1M 2>/dev/null; \
	          dd if=/tmp/boot-new.img of=/dev/mmcblk0p12 bs=1M conv=fsync; \
	          sync; echo FLASH_DONE; dd if=/dev/mmcblk0p12 bs=512 count=8 2>/dev/null | xxd | head -1"
	echo "=== 完成。手动重启设备验证: ssh 重启后 uname -r 应为 6.18.48 ==="
	;;
rootfs)
	echo "=== 阶段2: 替换 rootfs 为 Debian 13 trixie ==="
	TAR="$WORKDIR/out/trixie-rootfs.tar.gz"
	if [ ! -f "$TAR" ]; then
		echo "缺少 $TAR，先跑 ./build-rootfs.sh"
		exit 1
	fi
	echo "--- 推送到设备 ---"
	push_dev "$TAR" /root/trixie-rootfs.tar.gz
	echo "--- 设备端原地替换rootfs（运行中系统操作，失败会变砖，请先完成阶段1） ---"
	run_dev "cd / && \
	  mkdir -p /root/old-rootfs-bak && \
	  find / -maxdepth 1 -mindepth 1 ! -name root ! -name proc ! -name sys ! -name dev ! -name tmp ! -name old-rootfs-bak -exec rm -rf {} + 2>/dev/null; \
	  tar -xzf /root/trixie-rootfs.tar.gz -C / && sync && echo ROOTFS_REPLACED"
	echo "=== 完成。重启后系统为 Debian 13 + 6.18.48 ==="
	;;
*)
	echo "用法: $0 boot|rootfs"
	echo "  boot   - 阶段1: 刷6.18内核(保留Debian 11用户空间)"
	echo "  rootfs - 阶段2: 替换为Debian 13 trixie rootfs"
	exit 1
	;;
esac
