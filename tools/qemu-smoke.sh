#!/usr/bin/env bash
# QEMU 冒烟测试：验证 rootfs 镜像可启动到 login（不碰真机）。
# 通过标准：串口日志出现 login 提示；FAILED 单元均在预期假故障清单内
# （QEMU 无高通硬件，rmtfs/ttyMSM0/ModemManager 等失败属正常，见 TRIMMING.md）。
#
# 用法：tools/qemu-smoke.sh <rootfs.ext4> <Image.gz> [超时秒=240]
set -uo pipefail

IMG="${1:?用法: qemu-smoke.sh <rootfs.ext4> <Image.gz> [超时秒]}"
IMGGZ="${2:?缺少 Image.gz}"
TIMEOUT="${3:-240}"

BASE="$(cd "$(dirname "$0")/.." && pwd)"
. "$BASE/tools/lib-creds.sh"
# 本机 sudo 口令：环境变量 > .local-creds；缺失时 cred 会给出提示并退出。
SUDO_PW="$(cred SUDO_PW '准备 QEMU 测试镜像需要 sudo')"
# 并行回归必须使用不同目录，避免互相覆盖 test.ext4/Image 或卸载别人的挂载。
T="${QEMU_TEST_DIR:-$BASE/out/qemu-test}"
NAME="$(basename "$IMG" .ext4)"
mkdir -p "$T"

# 1) 裸内核
zcat "$IMGGZ" > "$T/Image"

# 2) 可写副本：fstab 改 /dev/vda + ttyAMA0 getty
cp "$IMG" "$T/test.ext4"
MNT="$T/mnt"
mkdir -p "$MNT"
# 预清理：上一次异常退出可能留下挂载
echo "$SUDO_PW" | sudo -S umount "$MNT" 2>/dev/null || true
LOOP=$(echo "$SUDO_PW" | sudo -S bash -c "
set -e
mount -o loop \"$T/test.ext4\" \"$MNT\"
sed -i 's|^PARTUUID.*|/dev/vda  /  ext4  defaults  0 1|' \"$MNT\"/etc/fstab
chroot \"$MNT\" ln -sf /lib/systemd/system/serial-getty@.service \
    /etc/systemd/system/getty.target.wants/serial-getty@ttyAMA0.service
umount \"$MNT\"
echo PREPARED-DONE" 2>&1 | tail -1)
case "$LOOP" in
  *PREPARED-DONE*) ;;
  *) echo "SMOKE[$NAME] FAIL: 测试副本准备失败（$LOOP）"; exit 1 ;;
esac

# 3) 启动（376MB，与真机一致），串口落盘
LOG="$T/$NAME.log"
timeout "$TIMEOUT" qemu-system-aarch64 -M virt -cpu cortex-a53 -smp 4 -m 376 \
    -kernel "$T/Image" \
    -append "console=ttyAMA0 root=/dev/vda rw rootwait" \
    -drive file="$T/test.ext4",if=none,id=d0,format=raw \
    -device virtio-blk-device,drive=d0 -nographic -no-reboot \
    > "$LOG" 2>&1
QRC=$?

# 4) 判定
if grep -q "ufi103s login:\|Debian GNU/Linux" "$LOG"; then
    # FAILED 单元统计（剔除 QEMU 无高通硬件导致的预期假故障）
    FAILED=$(grep -oE "Failed to start [^(]+." "$LOG" | sort -u | grep -viE \
        "rmtfs|ttyMSM0|ModemManager|qrtr|Modem|usb-gadget|native-net" || true)
    if [ -n "$FAILED" ]; then
        echo "SMOKE[$NAME] PASS（到 login，但存在非预期 FAILED）："
        echo "$FAILED" | sed 's/^/    /'
        exit 2
    fi
    echo "SMOKE[$NAME] PASS（到 login，无非预期 FAILED）"
    rc=0
else
    echo "SMOKE[$NAME] FAIL：${TIMEOUT}s 内未到 login（qrc=$QRC）"
    tail -20 "$LOG" | sed 's/^/    /'
    rc=1
fi
rm -f "$T/test.ext4"
exit $rc
