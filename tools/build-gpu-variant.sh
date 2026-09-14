#!/usr/bin/env bash
# 构建带 Adreno 306 GPU（render-only）的内核变体，并打包 boot 镜像。
#
# 这是对 tools/build-kernel-variant.sh 的薄封装：GPU 变体需要**两份**配置
# 片段（venus + gpu），因为它的 DTS 继承自 venus 变体、模块 release 也要
# 保持一致（-ufi003-venus），这样才能只换 boot 镜像而不用重刷 rootfs。
#
# 用法: tools/build-gpu-variant.sh [board] [dts-basename-without-.dts]
set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
BOARD="${1:-ufi103s-ufi003}"
DTS="${2:-msm8916-handsome-openstick-ufi103s-venus-oc-100-gpu}"
VARIANT="venus-oc-100-gpu"
MODDEST="$BASE/shared/modules/6.18.49-ufi003-gpu"
BOUT="$BASE/boards/ufi00x/$BOARD/boot"

echo "==> 构建内核（venus + gpu 片段）"
bash "$BASE/tools/build-kernel-variant.sh" gpu \
    "$BASE/source/configs/ufi103s-venus.config:$BASE/source/configs/ufi103s-gpu.config" \
    "$MODDEST"

echo
echo "==> 校验配置确实关掉了显示（DRM_MSM_KMS 必须不存在）"
CFG="$BASE/build/variant-gpu/.config"
if grep -q '^CONFIG_DRM_MSM_KMS=y' "$CFG"; then
    echo "错误：DRM_MSM_KMS=y —— 显示组件没关干净，GPU 会走组件绑定路径并失败" >&2
    echo "（检查 source/configs/ufi103s-gpu.config 里 MDP4/MDP5/DPU 是否显式 =n）" >&2
    exit 1
fi
grep -q '^CONFIG_DRM_MSM=m' "$CFG" || { echo "错误：DRM_MSM 未启用" >&2; exit 1; }
echo "    ok: DRM_MSM=m 且 DRM_MSM_KMS 未启用"

echo
echo "==> 打包 boot 镜像"
python3 "$BASE/tools/package-boot-variant.py" \
    "$VARIANT" "$DTS.dts" \
    "$BASE/build/variant-gpu/arch/arm64/boot/Image.gz" \
    "6.18.49-ufi003-venus-dirty" \
    "$BOUT"

echo
echo "==> 完成"
ls -l "$BOUT/boot-$VARIANT.img"

echo
echo "==> 重要：构建 rootfs 时主模块树要用这个 GPU 树"
echo "    GPU 变体的模块在 $MODDEST（含 msm.ko/drm.ko）"
echo "    而 shared/modules/6.18.49-ufi003-venus 里没有它们，"
echo "    若拿后者当 MODULE_TREE 构建 rootfs，开机 modprobe msm 会报"
echo "    \"Module drm not found\"，表现为 /dev/dri 缺失、渲染退回 llvmpipe。"
echo "    正确用法："
echo "      MODULE_TREE=$MODDEST EXTRA_MODULE_TREES=<baseline 树> bash build-rootfs.sh"
