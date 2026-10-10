#!/usr/bin/env bash
# 全矩阵 rootfs 构建：F1-F4 × nm|native 共 7 个镜像（ufi103s）。
#
# 前置：build-board-set.sh 产出的模块树（令牌来自 KERNEL_LOCALVERSION）
#   artifacts/modules/<ver>-ufix0x-dirty                 基线（slim/micro）
#   artifacts/modules/<ver>-ufix0x-4g-dirty              basic
#   artifacts/modules/<ver>-ufix0x-venus-4g-gpu-dirty    max
#
# Wi-Fi 预置：从环境读 ROOTFS_WIFI_SSID/ROOTFS_WIFI_PSK（不传则镜像不带
# 凭据，刷到无屏棒子上要靠 USB 网络共享进系统配网）。
#
# 用法：tools/build-matrix.sh [max basic slim micro basic-native slim-native micro-native]
set -uo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$BASE"
. tools/kver.sh
. tools/lib-creds.sh
# Wi-Fi 预置与 root 口令：环境变量 > .local-creds。未提供时不报错
# （镜像就不带预置网络；刷到无屏棒子上要靠 USB 共享进系统配网）。
ROOTFS_WIFI_SSID="$(cred_opt ROOTFS_WIFI_SSID)"
ROOTFS_WIFI_PSK="$(cred_opt ROOTFS_WIFI_PSK)"
ROOTFS_ROOT_PASSWORD="$(cred_opt ROOTFS_ROOT_PASSWORD)"

# 配对（板型级命名 + 正向功能后缀，见 tools/build-board-set.sh）：
#   max   → venus-4g-gpu 板型（GPU 内核）
#   basic → 4g 板型
#   slim/micro → 无后缀板型（WiFi-only，4G 链与 venus 全关，内存最大化）
REL_BASE="$KERNEL_VERSION$KERNEL_LOCALVERSION-dirty"
REL_4G="$KERNEL_VERSION$KERNEL_LOCALVERSION-4g-dirty"
REL_GPU="$KERNEL_VERSION$KERNEL_LOCALVERSION-venus-4g-gpu-dirty"
TREE_BASE="$ARTIFACTS_MODULES/$REL_BASE"
TREE_4G="$ARTIFACTS_MODULES/$REL_4G"
TREE_GPU="$ARTIFACTS_MODULES/$REL_GPU"
FIRMWARE_VENUS="$ARTIFACTS_FIRMWARE/ufi103s-venus"
OUTROOT="$ARTIFACTS_ROOTFS"

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
            KERNEL_RELEASE="$REL_GPU"
            MODULE_TREE="$TREE_GPU"
            EXTRA_TREES="$TREE_BASE"
            EXTRA_FW="$FIRMWARE_VENUS"
            EXTRA_PKGS="ffmpeg,v4l-utils"
            DESKTOP=1
            ;;
        basic)
            KERNEL_RELEASE="$REL_4G"
            MODULE_TREE="$TREE_4G"
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
    ROOTFS_ROOT_PASSWORD="${ROOTFS_ROOT_PASSWORD:-}" \
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
