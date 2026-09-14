# shellcheck shell=bash
# 内核版本的单一事实来源（shell 侧）。
#
# 用法（调用方先定义 BASE 或 WORKDIR 指向仓库根，二选一即可）：
#     . "$BASE/tools/kver.sh"
#     . "$WORKDIR/tools/kver.sh"
#
# 所有派生路径与 release 字符串都从 source/kernel-version.env 算出来，
# 升级内核只改那一个文件，不需要动脚本。
#
# 这个文件是被 source 的，不要在这里改 shell 选项或 exec。

# 仓库根：优先用调用方已定义的 BASE，其次 WORKDIR（根目录脚本用的是这个名字），
# 都没有就从本文件位置反推。有了它，两种命名习惯的脚本都能直接 source。
if [ -z "${BASE:-}" ]; then
	if [ -n "${WORKDIR:-}" ]; then
		BASE="$WORKDIR"
	else
		BASE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
	fi
fi

KVER_ENV="$BASE/source/kernel-version.env"
if [ ! -f "$KVER_ENV" ]; then
	echo "kver.sh: 找不到 $KVER_ENV（内核版本单一事实来源）" >&2
	# 被 source 时 return 才对；直接执行时用 exit。
	return 1 2>/dev/null || exit 1
fi
# shellcheck source=/dev/null
. "$KVER_ENV"

: "${KERNEL_VERSION:?kernel-version.env 里缺 KERNEL_VERSION}"
: "${KERNEL_LOCALVERSION:=-ufi003}"

KERNEL_SRC="${KERNEL_SRC:-$BASE/source/linux-$KERNEL_VERSION}"
KERNEL_BASE_CFG="${KERNEL_BASE_CFG:-$BASE/source/configs/common-$KERNEL_VERSION-os.config}"

# release 字符串。末尾的 -dirty 是内核 scripts/setlocalversion 对"有未提交
# 改动的工作树"自动加的后缀；我们总是就地打补丁，所以它一定在。若某次
# 把补丁提交进 git，release 会变成不带 -dirty 的版本——那时改这里即可。
#
# 全部用 ${VAR:-default} 形式，这样调用方仍可用环境变量单独覆盖某一项
# （保持升级前脚本的可覆盖语义），不设则从版本文件派生。
KERNEL_RELEASE="${KERNEL_RELEASE:-${KERNEL_VERSION}${KERNEL_LOCALVERSION}-dirty}"
KERNEL_RELEASE_VENUS="${KERNEL_RELEASE_VENUS:-${KERNEL_VERSION}${KERNEL_LOCALVERSION}-venus-dirty}"

# 模块树（modules_install 的 MODDEST 外层目录名；内层是上面的 release）。
MODULES_DIR="${MODULES_DIR:-$BASE/shared/modules/$KERNEL_RELEASE}"
MODULES_DIR_VENUS="${MODULES_DIR_VENUS:-$BASE/shared/modules/${KERNEL_VERSION}${KERNEL_LOCALVERSION}-venus}"
MODULES_DIR_GPU="${MODULES_DIR_GPU:-$BASE/shared/modules/${KERNEL_VERSION}${KERNEL_LOCALVERSION}-gpu}"

# rootfs 产物名。
ROOTFS_BASE="${ROOTFS_BASE:-$BASE/shared/rootfs/debian13-arm64-ufi103s-${KERNEL_VERSION}.ext4}"
ROOTFS_VENUS="${ROOTFS_VENUS:-$BASE/shared/rootfs/debian13-arm64-ufi103s-${KERNEL_VERSION}-venus.ext4}"

# 基线构建目录（Image.gz 所在）。
KERNEL_BUILD_DIR="${KERNEL_BUILD_DIR:-$BASE/out/build-ufi003-${KERNEL_VERSION}-os}"
