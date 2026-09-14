#!/usr/bin/env bash
set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
ROOTFS="${ROOTFS_IMAGE:-$BASE/shared/rootfs/debian13-arm64-ufi103s-6.18.49-chrony.ext4}"
MODULES="$BASE/shared/modules/6.18.49-ufi003-dirty/lib/modules/6.18.49-ufi003-dirty"
SRC="$BASE/source/linux-6.18.49"

# boards/<family>/<board> for grouped families, boards/<board> for single-member
# ones.  Kept in one place so every check below resolves the same way.
board_dir() {
  local board=$1
  if [ -d "$BASE/boards/ufi00x/$board" ]; then
    printf '%s\n' "$BASE/boards/ufi00x/$board"
  else
    printf '%s\n' "$BASE/boards/$board"
  fi
}

printf '== shell ==\n'
bash -n "$BASE/tools/build-rootfs.sh" "$BASE/tools/flash.sh" "$BASE/tools/build-boot-images.sh"
printf 'scripts=OK\n'

printf '\n== source ==\n'
test -f "$SRC/Makefile"
test -f "$BASE/source/dts/common/msm8916-handsome-openstick-common.dtsi"
for board in ufi103s-ufi003 ufi001b ufi001c sp970 uz801; do
  case "$board" in
    ufi103s-ufi003) f=msm8916-handsome-openstick-ufi103s.dts ;;
    ufi001b) f=msm8916-handsome-openstick-ufi001b.dts ;;
    ufi001c) f=msm8916-handsome-openstick-ufi001c.dts ;;
    sp970) f=msm8916-handsome-openstick-sp970.dts ;;
    uz801) f=msm8916-handsome-openstick-uz801.dts ;;
  esac
  test -f "$(board_dir "$board")/dts/$f"
  printf '%s=source-present\n' "$board"
done

printf '\n== common modules ==\n'
for f in modules.dep modules.alias; do test -f "$MODULES/$f"; done
for f in \
  kernel/drivers/net/wwan/wwan.ko \
  kernel/drivers/net/wwan/rpmsg_wwan_ctrl.ko \
  kernel/drivers/net/wwan/qcom_bam_dmux.ko \
  kernel/drivers/soc/qcom/rmtfs_mem.ko \
  kernel/drivers/remoteproc/qcom_q6v5_mss.ko \
  kernel/drivers/remoteproc/qcom_wcnss_pil.ko \
  kernel/net/qrtr/qrtr-smd.ko \
  kernel/drivers/block/zram/zram.ko; do
  test -f "$MODULES/kernel/$f" 2>/dev/null || test -f "$MODULES/$f"
done
printf 'modules=OK\n'

printf '\n== rootfs ==\n'
test -f "$ROOTFS"
e2fsck -fn "$ROOTFS" >/tmp/ufi-layout-e2fsck.log 2>&1
printf 'rootfs=%s\n' "$ROOTFS"
sha256sum "$ROOTFS"
for path in \
  /etc/chrony/chrony.conf \
  /etc/apt/sources.list \
  /usr/sbin/chronyd \
  /etc/localtime \
  /etc/timezone \
  /etc/systemd/system/multi-user.target.wants/chrony.service \
  /etc/systemd/system/rmtfs.service.d/ufi003.conf \
  /usr/lib/modules/6.18.49-ufi003-dirty/kernel/drivers/soc/qcom/rmtfs_mem.ko; do
  debugfs -R "stat $path" "$ROOTFS" >/dev/null 2>&1 || true
  debugfs -R "stat $path" "$ROOTFS" 2>/dev/null | grep -q '^Inode:' || { printf 'rootfs:%s=MISSING\n' "$path" >&2; exit 1; }
  printf 'rootfs:%s=present\n' "$path"
done
debugfs -R 'stat /lib/systemd/system/systemd-timesyncd.service' "$ROOTFS" 2>/dev/null | grep -q '^Inode:' && { printf 'ERROR: systemd-timesyncd present\n' >&2; exit 1; }
printf 'systemd-timesyncd=absent\n'
if debugfs -R 'stat /usr/bin/NetworkManager' "$ROOTFS" 2>&1 | grep -q '^Inode:'; then
  printf 'ERROR: NetworkManager executable present\n' >&2
  exit 1
fi
if debugfs -R 'stat /var/lib/dpkg/info/network-manager.list' "$ROOTFS" 2>&1 | grep -q '^Inode:'; then
  printf 'ERROR: NetworkManager package record present\n' >&2
  exit 1
fi
printf 'NetworkManager=absent\n'
printf '\n== LED and test assets ==\n'
for path in /usr/local/sbin/ufi-led-state.sh /etc/systemd/system/ufi-led-state.service /etc/systemd/system/multi-user.target.wants/ufi-led-state.service /root/venus-test.sh; do
  debugfs -R "stat $path" "$ROOTFS" 2>/dev/null | grep -q '^Inode:' || { printf 'rootfs:%s=MISSING\n' "$path" >&2; exit 1; }
  printf 'rootfs:%s=present\n' "$path"
done
printf 'led_policy=three-colour-red-load-gear\n'
grep -q 'GREEN=/sys/class/leds/green:wan' "$BASE/tools/ufi-led-state.sh"
grep -q 'RED_ON_PCT=${RED_ON_PCT:-70}' "$BASE/tools/ufi-led-state.sh"
grep -q 'on) led_solid "\$RED"' "$BASE/tools/ufi-led-state.sh"
grep -q 'ExecStart=/usr/local/sbin/ufi-led-state.sh monitor' "$BASE/tools/ufi-led-state.service"

printf '\n== board boot status ==\n'
for board in ufi103s-ufi003 ufi001b ufi001c sp970 uz801; do
  if [[ -f "$(board_dir "$board")/boot/boot-baseline.img" ]]; then
    printf '%s=board-specific-boot\n' "$board"
  else
    printf '%s=DTB-only-or-placeholder; do-not-flash\n' "$board"
  fi
done

printf '\n== venus codec variant ==\n'
VENUS_BOOT="$(board_dir ufi103s-ufi003)/boot/boot-venus.img"
VENUS_ROOTFS="$BASE/shared/rootfs/debian13-arm64-ufi103s-6.18.49-venus-led.ext4"
VENUS_MODS="$BASE/shared/modules/6.18.49-ufi003-venus/lib/modules/6.18.49-ufi003-venus-dirty"
test -f "$VENUS_BOOT"
test -f "$VENUS_ROOTFS"
test -f "$BASE/source/configs/ufi103s-venus.config"
for m in venus-core venus-dec venus-enc; do
  test -f "$VENUS_MODS/kernel/drivers/media/platform/qcom/venus/$m.ko"
  printf 'module:%s=present\n' "$m"
done
grep -q 'CONFIG_VIDEO_QCOM_VENUS=m' "$BASE/build/variant-venus/.config"
grep -q 'CONFIG_MEDIA_PLATFORM_SUPPORT=y' "$BASE/build/variant-venus/.config"
printf 'venus_config=OK\n'
python3 - "$VENUS_BOOT" <<'PY'
import struct, sys
data = open(sys.argv[1], 'rb').read()
assert data[:8] == b'ANDROID!', 'boot magic'
page = struct.unpack_from('<I', data, 36)[0]
off = data.find(bytes.fromhex('d00dfeed'), page)
assert off > 0, 'appended DTB not found'
size = struct.unpack_from('>I', data, off + 4)[0]
assert off + size <= len(data) and len(data) - (off + size) < page
print(f'venus_boot_layout=OK dtb_offset={off}')
PY
for path in \
  /usr/lib/modules/6.18.49-ufi003-venus-dirty/kernel/drivers/media/platform/qcom/venus/venus-core.ko \
  /usr/lib/modules/6.18.49-ufi003-dirty/kernel/drivers/net/wwan/rpmsg_wwan_ctrl.ko \
  /usr/bin/ffmpeg \
  /usr/bin/v4l2-ctl \
  /lib/firmware/qcom/venus-1.8/venus.mbn \
  /lib/firmware/qcom/venus-1.8/venus.b02; do
  debugfs -R "stat $path" "$VENUS_ROOTFS" 2>/dev/null | grep -q '^Inode:' \
    || { printf 'venus_rootfs:%s=MISSING\n' "$path" >&2; exit 1; }
  printf 'venus_rootfs:%s=present\n' "$path"
done
e2fsck -fn "$VENUS_ROOTFS" >/dev/null 2>&1
printf 'venus_rootfs=%s\n' "$VENUS_ROOTFS"
printf 'venus_rootfs_e2fsck=OK\n'
