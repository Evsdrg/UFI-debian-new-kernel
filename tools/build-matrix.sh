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
#   tools/build-matrix.sh --board ufi103s --jobs 4   # 4 个档位并发（默认 1=串行）
#
# --jobs N：并发构建 N 个档位。每个任务有独立的 STAGE（build-rootfs.sh 用 $$）
# 与独立的 mmdebstrap 临时目录，互不干扰。并发时每任务输出写
# <scratch>/logs/<board>-<flavor>.log，控制台只打进度与结果。
# 本机 32 核 / 21 GB，实测单任务峰值 2–4 GB，建议 --jobs 3~5。
#
# 中间产物（内核编译树、mmdebstrap 临时目录、构建日志）默认落在
# /scratch/openstick（见 tools/kver.sh 的 SCRATCH）；工作区只保留
# artifacts/ 与 out/ 下的最终产物。用 OPENSTICK_SCRATCH 可改根。
#
# 产物输出位置与覆盖保护：
#   ROOTFS_OUT_DIR=<dir>   写到其他目录（默认 artifacts/rootfs）
#   ROOTFS_FORCE=1         允许覆盖已存在的同名产物
# 默认**拒绝覆盖**已存在的产物：artifacts/rootfs/ 里可能是已发布、已实机验证的
# 交付件，静默重建会把“已验证”和“刚构建未验证”混为一谈。要试构建，用：
#   ROOTFS_OUT_DIR=out/rebuild tools/build-matrix.sh --board mf601sl basic
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
JOBS=1
TARGETS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --board) BOARD="${2:-}"; shift 2 ;;
        --jobs|-j) JOBS="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) TARGETS+=("$1"); shift ;;
    esac
done
case "$JOBS" in
    ''|*[!0-9]*|0) echo "--jobs 需要一个正整数（收到 '$JOBS'）" >&2; exit 2 ;;
esac

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

mkdir -p "$ARTIFACTS_ROOTFS" "$SCRATCH_TMP" "$SCRATCH_LOGS"
LOG_DIR="$SCRATCH_LOGS"
mkdir -p "$LOG_DIR"

# 单个 (board,flavor) 的完整构建。抽成函数是为了 --jobs>1 时能放进子 shell
# 并发跑；每个子进程有独立的 STAGE（build-rootfs.sh 用 $$ 命名）与独立的
# mmdebstrap 临时目录（mmdebstrap 自己 mkdtemp），互不干扰。
# 返回值：0 成功，非 0 失败（与 build-rootfs.sh 的 rc 一致）。
run_one() {
    local board="$1" t="$2"
    local flavor net release tree root_dev extlinux_kernel extlinux_dtb rc out_path

    flavor="${t%-native}"
    net="nm"; [[ "$t" == *-native ]] && net="native"
    # native 只对 nm 栈存在的档位有意义；max 没有 native 变体
    if [[ "$net" == "native" && "$flavor" == "max" ]]; then
        echo "!! $board: max 档没有 native 变体，跳过" >&2
        return 0
    fi

    release="$(board_release "$board" "$flavor")"
    tree="$ARTIFACTS_MODULES/$release"
    if [ ! -d "$tree" ]; then
        echo "!! $board/$t: 模块树不存在: $tree" >&2
        echo "   先跑 tools/build-board-set.sh $( [ "$board" = ufi103s ] && echo '' || echo "$board" )" >&2
        return 1
    fi

    board_spec "$board" "$flavor"
    root_dev="$(board_root_device "$board")"

    # extlinux 启动链（lk2nd）：需要内核镜像与 DTB 两个构建输入
    extlinux_kernel=""
    extlinux_dtb=""
    if [ "$board" = mf32 ]; then
        extlinux_kernel="$SCRATCH_BUILD/variant-$KERNEL_VERSION-board-mf32/arch/arm64/boot/Image.gz"
        extlinux_dtb="$SCRATCH_BUILD/boards/thwc-mf32/board-mf32-7.2.9.dtb"
        for f in "$extlinux_kernel" "$extlinux_dtb"; do
            [ -f "$f" ] || { echo "!! $board: 缺 extlinux 输入 $f" >&2; return 1; }
        done
    fi

    echo "=============================================="
    echo "==> 构建 $board/$t（flavor=$flavor net=$net）"
    echo "    kernel=$release tree=$tree root=$root_dev"

    # 输出路径：默认直接覆盖 artifacts/rootfs/<board>-<ver>-<flavor>.ext4。
    # 但 artifacts/ 里可能是已发布、已实机验证的交付件——完整构建覆盖它们
    # 会把“已验证”和“刚构建未验证”混为一谈（规则 #1402）。
    # 所以：输出目录用 ROOTFS_OUT_DIR 覆盖（默认仍为 artifacts/rootfs，
    # 保持既有习惯）；若目标文件已存在且未设 ROOTFS_FORCE=1，则拒绝构建。
    out_path="${ROOTFS_OUT_DIR:-$ARTIFACTS_ROOTFS}/$board-$KERNEL_VERSION-$t.ext4"
    if [ -e "$out_path" ] && [ "${ROOTFS_FORCE:-0}" != 1 ]; then
        echo "!! $out_path 已存在；拒绝覆盖已验证的产物。" >&2
        echo "   要重建到其他位置：ROOTFS_OUT_DIR=out/rebuild tools/build-matrix.sh ..." >&2
        echo "   确认要覆盖：ROOTFS_FORCE=1 tools/build-matrix.sh ..." >&2
        return 1
    fi
    mkdir -p "$(dirname "$out_path")"

    MMDEBSTRAP_FORMAT=ext4 \
    TMPDIR="$SCRATCH_TMP" \
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
    ROOTFS_PATH="$out_path" \
    ROOTFS_ROOT_PASSWORD="${ROOTFS_ROOT_PASSWORD:-}" \
    bash build-rootfs.sh
    rc=$?
    if [ $rc -ne 0 ]; then
        echo "!! $board/$t 构建失败 (rc=$rc)" >&2
        return $rc
    fi
    ls -lh "$out_path"
    return 0
}

rc_total=0
declare -a _pids=()

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
        if [ "$JOBS" -le 1 ]; then
            run_one "$board" "$t" || rc_total=1
        else
            # 并发：每个任务独立日志 + 独立 rc 文件，避免交错输出。
            # 用 jobs -rp 计数做并发闸门（构建任务以分钟计，1 秒轮询开销可忽略）。
            while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do sleep 1; done
            ( run_one "$board" "$t"; echo $? > "$LOG_DIR/$board-$t.rc" ) \
                > "$LOG_DIR/$board-$t.log" 2>&1 &
            echo "    → 后台构建 $board/$t，日志 $LOG_DIR/$board-$t.log"
        fi
    done
done

if [ "$JOBS" -gt 1 ]; then
    wait
    for f in "$LOG_DIR"/*.rc; do
        [ -f "$f" ] || continue
        rc=$(cat "$f")
        name=$(basename "$f" .rc)
        if [ "$rc" -ne 0 ]; then
            echo "!! $name 构建失败 (rc=$rc)，见 $LOG_DIR/$name.log" >&2
            rc_total=1
        else
            echo "OK $name"
        fi
        rm -f "$f"
    done
fi

echo "=============================================="
[ $rc_total -eq 0 ] && echo "全部构建完成" || echo "存在失败项（见上方日志）"
exit $rc_total
