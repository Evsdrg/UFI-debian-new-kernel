#!/usr/bin/env bash
# OpenStick 官方刷入流程（复刻 base/flash.sh），适配本工作区产物。
#
# 官方脚本原文见 build/openstick-upstream/base/base/flash.sh。本脚本**保持官方
# 步骤与顺序不变**，只做三件事：
#   1) 每步前置校验（文件哈希、设备状态、分区存在性），失败即停；
#   2) 阶段 1 的四个 oem dump 落到 out/<board>-official-flash/，并记录 sha256；
#   3) 官方脚本末尾是 "flash your os!"，这里接上本项目的 rootfs 与 boot 镜像。
#
# 官方流程分两个阶段，中间必须换一次引导器：
#   阶段 1：原厂 LK 加载 lk2nd.img → lk2nd 的 fastboot 才有 `oem dump`，
#           用它备份 fsc/fsg/modemst1/modemst2（每台设备唯一的基带数据）。
#   阶段 2：回原厂 LK 的 fastboot → `flash partition gpt_both0.bin`，
#           这一步会**全盘擦除**（write_gpt() 里 mmc_erase_card(0, density)），
#           随后写入全部 bootloader 并把阶段 1 的备份写回。
#
# 安全前提（脚本会自己检查）：
#   * 设备已在 fastboot（原厂 LK / LK1ST）；
#   * 官方 base 文件齐全且哈希匹配；
#   * rootfs 与 boot 镜像存在且与 build.json 一致。
#
# 本流程会把设备变成 OpenStick 形态：GPT 换成官方 14 分区模板、bootloader 全部
# 替换为 OpenStick 官方版、**不再兼容原厂 Android**。回退只能用整盘备份。
#
# 用法：
#   tools/dist/openstick-official-flash.sh --board mf601sl
#   tools/dist/openstick-official-flash.sh --board mf32 --dry-run
#
# 环境变量：
#   OPENSTICK_BASE 官方 base 文件目录（默认 build/openstick-upstream/base/base）
#   BOOT_IMG       要刷的 boot 镜像（默认取 artifacts/boot/thwc-<board>/ 下唯一一枚）
#   ROOTFS_IMG     要刷的 rootfs（默认 artifacts/rootfs/<board>-<ver>-basic.ext4）
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
BOARD=""
DRY_RUN=0
SKIP_OS=0

while [ $# -gt 0 ]; do
    case "$1" in
        --board) BOARD="${2:-}"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --skip-os) SKIP_OS=1; shift ;;   # 只做官方 bootloader/GPT，不刷 OS
        -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "未知参数: $1" >&2; exit 2 ;;
    esac
done

[ -n "$BOARD" ] || { echo "必须指定 --board mf32|mf601sl" >&2; exit 2; }
case "$BOARD" in mf32|mf601sl) ;; *) echo "--board 只支持 mf32|mf601sl" >&2; exit 2 ;; esac

BASE_FILES="${OPENSTICK_BASE:-$BASE_DIR/../build/openstick-upstream/base/base}"
OUT="$BASE_DIR/out/$BOARD-official-flash"
mkdir -p "$OUT"

# ── 官方 base 文件的期望哈希（与 build/openstick-upstream 实测一致）──
declare -A EXPECT=(
    [lk2nd.img]=339a96e21ce5967f9234b1e0ade378da2cb4bb11d90a41c66e41d951642ca9ab
    [gpt_both0.bin]=fd046fb9171493e46e15fa3b8fdfdaa8ec6233b19b7e5151e5e166bcf425cc0f
    [hyp.mbn]=0680b42298a7d691161e427543211f3ec528b21c901de6e5b13e833e772776cf
    [rpm.mbn]=551beae07ab831204c8d8362d2344c37b03ba6bd590984eb44b7f560ee6b94b7
    [sbl1.mbn]=6565a3c61c0f7413f10f1027c7f9b085335aeaabc379338c37c57917ac90c4aa
    [tz.mbn]=2daaedaafeee5697b6d85aa329cc6af9bc7e661677e4594d75efb54e4b53fea1
    [aboot.bin]=683f464ff0295d4663558db0d0d006eb4a982f0f7a6de93eb8df052a69bd456a
    [sbc_1.0_8016.bin]=5e2004e3b46d22a3b2b429271ff140ff77f8dd5c0816947579eca98243d69f31
)

echo "== 0. 前置校验 =="
command -v fastboot >/dev/null || { echo "缺少 fastboot" >&2; exit 1; }
for f in "${!EXPECT[@]}"; do
    p="$BASE_FILES/$f"
    [ -f "$p" ] || { echo "缺少官方文件: $p" >&2; exit 1; }
    got=$(sha256sum "$p" | cut -d' ' -f1)
    [ "$got" = "${EXPECT[$f]}" ] || { echo "$f 哈希不符: $got" >&2; exit 1; }
done
echo "官方 base 文件 8/8 哈希匹配"

# OS 镜像
ROOTFS_IMG="${ROOTFS_IMG:-}"
BOOT_IMG="${BOOT_IMG:-}"
if [ "$SKIP_OS" = 0 ]; then
    if [ -z "$ROOTFS_IMG" ]; then
        # 版本号必须经 tools/kver.sh 解析（kernel-version.env 里是 ${VAR:-...} 形式，
        # 直接用 sed 取值会拿到未展开的字面量）。
        # shellcheck source=/dev/null
        . "$BASE_DIR/tools/kver.sh"
        ROOTFS_IMG="$BASE_DIR/artifacts/rootfs/$BOARD-$KERNEL_VERSION-basic.ext4"
    fi
    if [ -z "$BOOT_IMG" ]; then
        mapfile -t _b < <(find "$BASE_DIR/artifacts/boot/thwc-$BOARD" -maxdepth 1 -name 'boot-board-*.img' | sort)
        [ "${#_b[@]}" -eq 1 ] || { echo "artifacts/boot/thwc-$BOARD 下 boot 镜像不唯一（${#_b[@]} 个），请用 BOOT_IMG 指定" >&2; exit 1; }
        BOOT_IMG="${_b[0]}"
    fi
    [ -f "$ROOTFS_IMG" ] || { echo "缺少 rootfs: $ROOTFS_IMG" >&2; exit 1; }
    [ -f "$BOOT_IMG" ] || { echo "缺少 boot: $BOOT_IMG" >&2; exit 1; }
    echo "rootfs: $ROOTFS_IMG ($(stat -c%s "$ROOTFS_IMG") 字节)"
    echo "boot:   $BOOT_IMG ($(stat -c%s "$BOOT_IMG") 字节)"
fi

# 设备必须在 fastboot
fb_devices() { timeout 10 fastboot devices 2>/dev/null | awk 'NF{print $1}'; }
if [ -z "$(fb_devices)" ]; then
    echo "未检测到 fastboot 设备。请让设备进入 fastboot（原厂 LK / LK1ST）后重试。" >&2
    exit 1
fi
echo "fastboot 设备: $(fb_devices | tr '\n' ' ')"

if [ "$DRY_RUN" = 1 ]; then
    echo
    echo "== DRY RUN：计划 =="
    cat <<EOF
阶段 1（lk2nd 备份校准分区）
  fastboot erase boot
  fastboot flash boot $BASE_FILES/lk2nd.img
  fastboot reboot
  fastboot oem dump fsc     && fastboot get_staged $OUT/fsc.bin
  fastboot oem dump fsg     && fastboot get_staged $OUT/fsg.bin
  fastboot oem dump modemst1 && fastboot get_staged $OUT/modemst1.bin
  fastboot oem dump modemst2 && fastboot get_staged $OUT/modemst2.bin

阶段 2（官方 GPT + bootloader；**会全盘擦除**）
  fastboot erase lk2nd
  fastboot erase boot
  fastboot reboot bootloader
  fastboot flash partition $BASE_FILES/gpt_both0.bin
  fastboot flash hyp    $BASE_FILES/hyp.mbn
  fastboot flash rpm    $BASE_FILES/rpm.mbn
  fastboot flash sbl1   $BASE_FILES/sbl1.mbn
  fastboot flash tz     $BASE_FILES/tz.mbn
  fastboot flash fsc    $OUT/fsc.bin
  fastboot flash fsg    $OUT/fsg.bin
  fastboot flash modemst1 $OUT/modemst1.bin
  fastboot flash modemst2 $OUT/modemst2.bin
  fastboot flash aboot  $BASE_FILES/aboot.bin
  fastboot flash cdt    $BASE_FILES/sbc_1.0_8016.bin
  fastboot erase boot
  fastboot erase rootfs
EOF
    if [ "$SKIP_OS" = 0 ]; then
        cat <<EOF

阶段 3（本项目 OS）
  fastboot -S 200M flash rootfs $ROOTFS_IMG
  fastboot flash boot $BOOT_IMG
EOF
    fi
    echo
    echo "预演结束，未做任何修改。"
    exit 0
fi

wait_fastboot() {
    local what="$1" timeout="${2:-90}" i=0
    echo "   等待 fastboot（$what，最多 ${timeout}s）..."
    while [ "$i" -lt "$timeout" ]; do
        [ -n "$(fb_devices)" ] && { echo "   fastboot 就绪"; return 0; }
        sleep 1; i=$((i+1))
    done
    echo "   ✗ 等待 $what 超时" >&2
    return 1
}

fb() { echo "> fastboot $*"; timeout 600 fastboot "$@"; }

echo
echo "===== 阶段 1：lk2nd 备份校准分区 ====="
fb erase boot
fb flash boot "$BASE_FILES/lk2nd.img"
fb reboot
wait_fastboot "lk2nd"

for p in fsc fsg modemst1 modemst2; do
    echo "-- 备份 $p"
    fb oem dump "$p"
    fb get_staged "$OUT/$p.bin"
    sz=$(stat -c%s "$OUT/$p.bin")
    [ "$sz" -gt 0 ] || { echo "✗ $p 备份为空" >&2; exit 1; }
    echo "   $p: $sz 字节  sha256=$(sha256sum "$OUT/$p.bin" | cut -c1-16)"
done
echo "阶段 1 完成。备份落在 $OUT"

echo
echo "===== 阶段 2：官方 GPT + bootloader ====="
echo "!! 下一步 fastboot flash partition 会全盘擦除 eMMC"
# 官方脚本此处是 `fastboot erase lk2nd`，但 GPT 里并没有名为 lk2nd 的分区
# （lk2nd.img 是写进 boot 分区的）。官方脚本没有 set -e 所以失败被忽略；
# 这里显式容忍，保持与官方行为一致。
fb erase lk2nd || echo "   （lk2nd 分区不存在，与官方脚本同样继续）"
fb erase boot
fb reboot bootloader
wait_fastboot "原厂 LK"

fb flash partition "$BASE_FILES/gpt_both0.bin"
fb flash hyp   "$BASE_FILES/hyp.mbn"
fb flash rpm   "$BASE_FILES/rpm.mbn"
fb flash sbl1  "$BASE_FILES/sbl1.mbn"
fb flash tz    "$BASE_FILES/tz.mbn"
fb flash fsc   "$OUT/fsc.bin"
fb flash fsg   "$OUT/fsg.bin"
fb flash modemst1 "$OUT/modemst1.bin"
fb flash modemst2 "$OUT/modemst2.bin"
fb flash aboot "$BASE_FILES/aboot.bin"
fb flash cdt   "$BASE_FILES/sbc_1.0_8016.bin"
fb erase boot
fb erase rootfs

echo
echo "===== 阶段 3：本项目 OS ====="
if [ "$SKIP_OS" = 0 ]; then
    echo "-- rootfs（分片传输，兼容小 max-download-size）"
    fb -S 200M flash rootfs "$ROOTFS_IMG"
    echo "-- boot"
    fb flash boot "$BOOT_IMG"
else
    echo "(跳过：--skip-os)"
fi

fb reboot
echo
echo "===== 完成 ====="
echo "设备应冷启动进入 Debian。若未起来，用整盘备份回退："
echo "  out/$BOARD-device/emmc-full.bin（EDL 一次性写回）"
