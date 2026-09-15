#!/usr/bin/env bash
# 全矩阵 rootfs 构建：F1-F4 × nm|native 共 7 个镜像（ufi103s）。
#
# 前置（一次性）：三棵模块树就位（build-kernel-variant / build-gpu-variant 产出）
#   shared/modules/7.1.13-ufi103s          基线（basic/slim/micro 及其 native）
#   shared/modules/7.1.13-ufi103s-venus    venus
#   shared/modules/7.1.13-ufi103s-gpu      GPU（max；.EXTRA_MODULE_TREES 带基线）
#
# Wi-Fi 预置：从环境读 ROOTFS_WIFI_SSID/ROOTFS_WIFI_PSK（不传则镜像不带
# 凭据，刷到无屏棒子上要靠 USB 网络共享进系统配网）。
#
# 用法：tools/build-matrix.sh [max basic slim micro basic-native slim-native micro-native]
set -uo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$BASE"
. tools/kver.sh

REL_BASE="$KERNEL_VERSION$KERNEL_LOCALVERSION-dirty"
REL_VENUS="$KERNEL_VERSION$KERNEL_LOCALVERSION-venus-dirty"
TREE_BASE="$BASE/shared/modules/$REL_BASE"
TREE_GPU="$BASE/shared/modules/$KERNEL_VERSION$KERNEL_LOCALVERSION-gpu"
FIRMWARE_VENUS="$BASE/shared/firmware/ufi103s-venus"
OUTROOT="$BASE/shared/rootfs"

TARGETS=("$@")
[ ${#TARGETS[@]} -eq 0 ] && TARGETS=(max basic slim micro basic-native slim-native micro-native)

mkdir -p "$OUTROOT" "$BASE/out/tmp"

rc_total=0
for t in "${TARGETS[@]}"; do
    flavor="${t%-native}"
    net="nm"; [[ "$t" == *-native ]] && net="native"

    # 每档的内核/模块/固件/额外包
    KERNEL_RELEASE="$REL_BASE"; MODULE_TREE="$TREE_BASE"
    EXTRA_TREES=""; EXTRA_FW=""; EXTRA_PKGS=""
    DESKTOP=0
    case "$flavor" in
        max)
            KERNEL_RELEASE="$REL_VENUS"
            MODULE_TREE="$TREE_GPU"
            EXTRA_TREES="$TREE_BASE"
            EXTRA_FW="$FIRMWARE_VENUS"
            EXTRA_PKGS="ffmpeg,v4l-utils"
            DESKTOP=1
            ;;
    esac

    echo "=============================================="
    echo "==> 构建 $t（flavor=$flavor net=$net）"
    echo "    kernel=$KERNEL_RELEASE tree=$MODULE_TREE"
    MMDEBSTRAP_FORMAT=ext4 \
    TMPDIR="$BASE/out/tmp" \
    KERNEL_RELEASE="$KERNEL_RELEASE" \
    MODULE_TREE="$MODULE_TREE" \
    EXTRA_MODULE_TREES="${EXTRA_TREES}" \
    EXTRA_FIRMWARE_DIR="${EXTRA_FW}" \
    EXTRA_PKGS="${EXTRA_PKGS}" \
    ROOTFS_FLAVOR="$flavor" \
    ROOTFS_NET="$net" \
    ROOTFS_DESKTOP="$DESKTOP" \
    ROOTFS_PATH="$OUTROOT/ufi103s-$KERNEL_VERSION-$t.ext4" \
    ROOTFS_WIFI_SSID="${ROOTFS_WIFI_SSID:-}" \
    ROOTFS_WIFI_PSK="${ROOTFS_WIFI_PSK:-}" \
    bash build-rootfs.sh
    rc=$?
    if [ $rc -ne 0 ]; then
        echo "!! $t 构建失败 (rc=$rc)" >&2
        rc_total=$rc
        continue
    fi
    ls -lh "$OUTROOT/ufi103s-$KERNEL_VERSION-$t.ext4"
done

echo "=============================================="
[ $rc_total -eq 0 ] && echo "全部构建完成" || echo "存在失败项（见上方日志）"
exit $rc_total
