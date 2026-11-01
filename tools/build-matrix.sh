#!/usr/bin/env bash
# 全板型 rootfs 构建器。
#
# 一个入口覆盖所有板型，板型差异集中在本文件的 board_* 函数里，不再散落临时脚本。
#
# 用法：
#   tools/build-matrix.sh                      # 默认构建全部板型的默认档位
#   tools/build-matrix.sh --board ufi103s      # 只构建 UFI103s（默认 7 档）
#   tools/build-matrix.sh --board mf32         # 只构建 MF32（basic）
#   tools/build-matrix.sh --board mf601sl      # 只构建 MF601SL（basic）
#   tools/build-matrix.sh --board mf32 basic   # 指定板型 + 指定档位
#
# 前置：tools/build-board-set.sh 已产出对应板型的内核与模块树。
#
# 镜像不预置 Wi-Fi（见 build-rootfs.sh 文件头）：刷到无屏棒子上后先靠 USB RNDIS
# 共享进系统（插电脑就自动开出 10.42.0.1 并 DHCP），再用 nmtui/nmcli 配无线。
#
# root 口令：环境变量 > .local-creds，统一经 tools/lib-creds.sh 的 cred_opt 读取
# （由 shell 解析掉 .local-creds 里的引号，不要再自己 grep/cut——那会把引号
# 当成口令内容写进镜像，无屏设备上直接锁死）。
set -uo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$BASE"
. tools/kver.sh
. tools/lib-creds.sh

ROOTFS_ROOT_PASSWORD="$(cred_opt ROOTFS_ROOT_PASSWORD)"

# ---------------------------------------------------------------- 板型参数
# 每块板型只描述"与 UFI103s 不同的部分"，其余交给 build-rootfs.sh 的默认值。
#
#   board_flavors        该板型支持的档位（首个为不带参数时的默认）
#   board_release        档位 → 内核 release 名（决定模块树 vermagic）
#   board_root_device    root= 的写法；留空则用 build-rootfs.sh 的缺省
#   board_extlinux       是否在 rootfs 内放 /extlinux + /boot（lk2nd 启动链）
#   board_extra_*        该板型独有的构建输入
board_flavors() {
    case "$1" in
        ufi103s) echo "max basic slim micro basic-native slim-native micro-native" ;;
        mf32)    echo "basic" ;;
        mf601sl) echo "basic" ;;
        *) echo "未知板型: $1（可选 ufi103s|mf32|mf601sl）" >&2; return 2 ;;
    esac
}

# 档位 → (内核 release 后缀, 需要叠加的额外模块树, venus 固件, 额外包, 桌面)
# UFI103s 的档位与内核板型是固定配对，别改：
#   max → venus-4g-gpu（GPU 内核）；basic → 4g；slim/micro → 无后缀（WiFi-only）
board_release() {
    local board="$1" flavor="$2"
    case "$board" in
        ufi103s)
            case "$flavor" in
                max)   echo "$KERNEL_VERSION$KERNEL_LOCALVERSION-venus-4g-gpu-dirty" ;;
                basic) echo "$KERNEL_VERSION$KERNEL_LOCALVERSION-4g-dirty" ;;
                *)     echo "$KERNEL_VERSION$KERNEL_LOCALVERSION-dirty" ;;
            esac
            ;;
        mf32)    echo "$KERNEL_VERSION$KERNEL_LOCALVERSION-mf32-dirty" ;;
        mf601sl) echo "$KERNEL_VERSION$KERNEL_LOCALVERSION-mf601sl-dirty" ;;
    esac
}

board_spec() {
    local board="$1" flavor="$2"
    BOARD_EXTRA_TREES=""
    BOARD_EXTRA_FW=""
    BOARD_EXTRA_PKGS=""
    BOARD_DESKTOP=0
    case "$board" in
        ufi103s)
            case "$flavor" in
                max)
                    BOARD_EXTRA_TREES="$ARTIFACTS_MODULES/$KERNEL_VERSION$KERNEL_LOCALVERSION-dirty"
                    BOARD_EXTRA_FW="$ARTIFACTS_FIRMWARE/ufi103s-venus"
                    BOARD_EXTRA_PKGS="ffmpeg,v4l-utils"
                    BOARD_DESKTOP=1
                    ;;
            esac
            ;;
    esac
}

# root= 写法。UFI103s 保持 build-rootfs.sh 的缺省（已实机验证，不动）；
# 新板型用固定分区路径/标签，别人刷进去不必改 cmdline。
board_root_device() {
    case "$1" in
        mf32)    echo "PARTLABEL=rootfs" ;;
        mf601sl) echo "/dev/mmcblk0p14" ;;
        *)       echo "" ;;
    esac
}

# ---------------------------------------------------------------- 主流程
BOARD=""
TARGETS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --board) BOARD="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) TARGETS+=("$1"); shift ;;
    esac
done

if [ -z "$BOARD" ]; then
    if [ ${#TARGETS[@]} -gt 0 ]; then
        # 只给了档位（兼容旧用法）：默认只构建 UFI103s，不牵连其它板型。
        ALL_BOARDS=(ufi103s)
    else
        ALL_BOARDS=(ufi103s mf32 mf601sl)
    fi
else
    ALL_BOARDS=("$BOARD")
fi

mkdir -p "$ARTIFACTS_ROOTFS" "$BASE/out/tmp"

rc_total=0
for board in "${ALL_BOARDS[@]}"; do
    case "$board" in
        ufi103s|mf32|mf601sl) ;;
        *) echo "未知板型: $board（可选 ufi103s|mf32|mf601sl）" >&2; rc_total=1; continue ;;
    esac
    # board_flavors 返回空格分隔的一行，要切成数组；mapfile 会把整行当一个元素。
    read -r -a flavors <<< "$(board_flavors "$board")"
    if [ ${#TARGETS[@]} -gt 0 ] && [ -n "$BOARD" ]; then
        # 指定了板型又给了档位：只构建这些档位
        use_flavors=("${TARGETS[@]}")
    else
        use_flavors=("${flavors[@]}")
    fi

    for t in "${use_flavors[@]}"; do
        flavor="${t%-native}"
        net="nm"; [[ "$t" == *-native ]] && net="native"
        # native 只对 nm 栈存在的档位有意义；max 没有 native 变体
        if [[ "$net" == "native" && "$flavor" == "max" ]]; then
            echo "!! $board: max 档没有 native 变体，跳过" >&2
            continue
        fi

        release="$(board_release "$board" "$flavor")"
        tree="$ARTIFACTS_MODULES/$release"
        if [ ! -d "$tree" ]; then
            echo "!! $board/$t: 模块树不存在: $tree" >&2
            echo "   先跑 tools/build-board-set.sh $( [ "$board" = ufi103s ] && echo '' || echo "$board" )" >&2
            rc_total=1
            continue
        fi

        board_spec "$board" "$flavor"
        root_dev="$(board_root_device "$board")"

        # extlinux 启动链（lk2nd）：需要内核镜像与 DTB 两个构建输入
        extlinux_kernel=""
        extlinux_dtb=""
        if [ "$board" = mf32 ]; then
            extlinux_kernel="$BASE/build/variant-$KERNEL_VERSION-board-mf32/arch/arm64/boot/Image.gz"
            extlinux_dtb="$BASE/build/boards/thwc-mf32/board-mf32-7.2.9.dtb"
            for f in "$extlinux_kernel" "$extlinux_dtb"; do
                [ -f "$f" ] || { echo "!! $board: 缺 extlinux 输入 $f" >&2; rc_total=1; continue 2; }
            done
        fi

        echo "=============================================="
        echo "==> 构建 $board/$t（flavor=$flavor net=$net）"
        echo "    kernel=$release tree=$tree root=$root_dev"

        MMDEBSTRAP_FORMAT=ext4 \
        TMPDIR="$BASE/out/tmp" \
        KERNEL_RELEASE="$release" \
        MODULE_TREE="$tree" \
        EXTRA_MODULE_TREES="${BOARD_EXTRA_TREES}" \
        EXTRA_FIRMWARE_DIR="${BOARD_EXTRA_FW}" \
        EXTRA_PKGS="${BOARD_EXTRA_PKGS}" \
        ROOTFS_FLAVOR="$flavor" \
        ROOTFS_NET="$net" \
        ROOTFS_BOARD="$board" \
        ROOTFS_DESKTOP="$BOARD_DESKTOP" \
        ROOTFS_ROOT_DEVICE="$root_dev" \
        ROOTFS_EXTLINUX_KERNEL="$extlinux_kernel" \
        ROOTFS_EXTLINUX_DTB="$extlinux_dtb" \
        ROOTFS_PATH="$ARTIFACTS_ROOTFS/$board-$KERNEL_VERSION-$t.ext4" \
        ROOTFS_ROOT_PASSWORD="${ROOTFS_ROOT_PASSWORD:-}" \
        bash build-rootfs.sh
        rc=$?
        if [ $rc -ne 0 ]; then
            echo "!! $board/$t 构建失败 (rc=$rc)" >&2
            rc_total=$rc
            continue
        fi
        ls -lh "$ARTIFACTS_ROOTFS/$board-$KERNEL_VERSION-$t.ext4"
    done
done

echo "=============================================="
[ $rc_total -eq 0 ] && echo "全部构建完成" || echo "存在失败项（见上方日志）"
exit $rc_total
