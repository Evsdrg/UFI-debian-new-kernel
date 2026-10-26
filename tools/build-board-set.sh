#!/usr/bin/env bash
# 板型（DTS）级内核构建器：每个使用不同设备树的板型一个独立的内核
# release 名与模块树。release = <ver>-ufix0x<板型后缀>-dirty。
# 设备令牌取 source/kernel-version.env 的 KERNEL_LOCALVERSION，不在这里写死。
#
# 命名规则（AGENTS.md §5.1）：设备名 + 板型（DTS 后缀）。
# 同一内核配置但不同 LOCALVERSION 的构建必须真分家——vermagic 里含
# release 字符串，模块树不能跨 release 复用。
#
# 用法：tools/build-board-set.sh [板型名 ...]   缺省构建全部未完成的。
#   可用板型（键 = DTS 后缀，空 = 基线）：
#     "" 4g venus venus-4g venus-4g-gpu minimal   （UFI103s）
#     mf601sl                                      （THWC MF601SL_CT_V07，电池型 4G MiFi）
#
# 板型表每条为：后缀 | 内核片段 | DTS 文件 | 板目录（可选）| root= 写法（可选）
# 板目录不同的板型会构建到 artifacts/boot/<板目录名>/ 下。
# root= 写法缺省保持 PARTUUID（不动已实机验证的 UFI103s 镜像）；
# 新板型用 /dev/mmcblk0p14，别人刷进去不必改 cmdline。
set -uo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$BASE"
. tools/kver.sh

BOARD_DIR="$BASE/boards/ufi00x/ufi103s-ufi003"
DTS_PREFIX="msm8916-handsome-openstick-ufi103s"
VENUS_FRAG="$BASE/source/configs/ufi103s-venus.config"
GPU_FRAG="$BASE/source/configs/ufi103s-gpu.config"
BASE_FRAG="$BASE/source/configs/ufi103s-baseline.config"
MINIMAL_FRAG="$BASE/source/configs/ufi103s-minimal.config"
MF601SL_FRAG="$BASE/source/configs/mf601sl.config"
MF601SL_BOARD="$BASE/boards/thwc-mf601sl"
MF32_FRAG="$BASE/source/configs/mf32.config"
MF32_BOARD="$BASE/boards/thwc-mf32"

# 板型表：后缀 | 内核片段 | DTB
# 后缀空 = 基线；gpu 板型叠加 gpu 片段（render-only 校验在下方）。
# 板型 = 正交功能组合，后缀只写"有的功能"（无 4G 不写 -no4g，就什么都不写）：
#   （空）        WiFi/BT only（4G 链与 venus 全关，内存最大化——slim/micro 配）
#   4g            +4G（basic 配）
#   venus         +硬件编解码，无 4G
#   venus-4g      +硬件编解码 +4G
#   venus-4g-gpu  +硬件编解码 +4G +GPU（max 配）
#   minimal       WiFi + USB 网络共享 + zram，其余全裁（内存最大化；配 slim/micro）
# CPU OC（三档 OPP + 85C 被动冷却）已全员化进 common dtsi，不再占名字。
#
# minimal 与 baseline 的差别在**内核配置**而非设备树：两者共用 WiFi-only 的
# 基线 DTS，但 minimal 在 common 配置之上再叠 ufi103s-minimal.config，把
# SCSI/MTD/ATA/其它 SoC 平台驱动/无关文件系统/蓝牙/多媒体等全部关掉。
TYPES=(
  "|$BASE_FRAG|$DTS_PREFIX.dts"
  "4g|$BASE_FRAG|$DTS_PREFIX-4g.dts"
  "venus|$VENUS_FRAG|$DTS_PREFIX-venus.dts"
  "venus-4g|$VENUS_FRAG|$DTS_PREFIX-venus-4g.dts"
  "venus-4g-gpu|$VENUS_FRAG:$GPU_FRAG|$DTS_PREFIX-venus-4g-gpu.dts"
  "minimal|$BASE_FRAG:$MINIMAL_FRAG|$DTS_PREFIX.dts"
  "mf601sl|$MF601SL_FRAG|msm8916-thwc-mf601sl-v07.dts|$MF601SL_BOARD|/dev/mmcblk0p14"
  "mf32|$MF32_FRAG|msm8916-thwc-mf32.dts|$MF32_BOARD|PARTLABEL=rootfs"
)

WANT=("$@")
rc_total=0

for entry in "${TYPES[@]}"; do
    IFS='|' read -r suffix frags dtsname board_dir_override board_root_override <<< "$entry"
    if [ ${#WANT[@]} -gt 0 ]; then
        keep=0
        for w in "${WANT[@]}"; do [ "$w" = "$suffix" ] && keep=1; done
        [ "$keep" = 1 ] || continue
    fi

    if [ -z "$suffix" ]; then
        RELEASE="$KERNEL_VERSION${KERNEL_LOCALVERSION}-dirty"
        VARIANT="baseline"
    else
        RELEASE="$KERNEL_VERSION${KERNEL_LOCALVERSION}-$suffix-dirty"
        VARIANT="$suffix"
    fi
    # 父目录带 -dirty（与 kver MODULES_DIR 惯例一致）
    TREE="$ARTIFACTS_MODULES/$RELEASE"
    THIS_BOARD_DIR="${board_dir_override:-$BOARD_DIR}"
    DTB_SRC="$THIS_BOARD_DIR/dts/$dtsname"
    BOARD_OUT_NAME="$(basename "$THIS_BOARD_DIR")"

    echo "=============================================="
    echo "==> 板型 [$VARIANT] release=$RELEASE"

    # 逐板型 LOCALVERSION 片段（临时文件，构建时最后合并、优先生效）
    LVFRAG=$(mktemp /tmp/lv-$VARIANT-XXXXXX.config)
    printf 'CONFIG_LOCALVERSION="%s"\n' "${KERNEL_LOCALVERSION}${suffix:+-$suffix}" > "$LVFRAG"

    BUILD_DIR="$BASE/build/variant-$KERNEL_VERSION-board-$VARIANT" \
    bash tools/build-kernel-variant.sh "board-$VARIANT" \
        "$frags:$LVFRAG" "$TREE" || { rc_total=1; rm -f "$LVFRAG"; continue; }
    rm -f "$LVFRAG"

    # GPU 板型：render-only 校验（原 build-gpu-variant.sh 的断言，该脚本已删除）
    case "$VARIANT" in
    *gpu)
        CFG="$BASE/build/variant-$KERNEL_VERSION-board-$VARIANT/.config"
        if grep -q '^CONFIG_DRM_MSM_KMS=y' "$CFG"; then
            echo "错误：DRM_MSM_KMS=y —— 显示组件没关干净" >&2; rc_total=1; continue
        fi
        grep -q '^CONFIG_DRM_MSM=m' "$CFG" || { echo "错误：DRM_MSM 未启用" >&2; rc_total=1; continue; }
        echo "    ok: DRM_MSM=m 且 DRM_MSM_KMS 未启用"
        ;;
    esac

    # 打包 boot 镜像（Image.gz + 板型 DTB）
    BOOT_ROOT="${board_root_override:-}" \
    python3 tools/package-boot-variant.py \
        "board-$VARIANT-$KERNEL_VERSION" "$dtsname" \
        "$BASE/build/variant-$KERNEL_VERSION-board-$VARIANT/arch/arm64/boot/Image.gz" \
        "$RELEASE" \
        "$ARTIFACTS_BOOT/$BOARD_OUT_NAME" "$THIS_BOARD_DIR" || { rc_total=1; continue; }
done

echo "=============================================="
[ $rc_total -eq 0 ] && echo "板型构建全部完成" || echo "存在失败板型"
exit $rc_total
