#!/usr/bin/env bash
# Build an out-of-tree kernel variant from the authoritative source tree.
#
#   tools/build-kernel-variant.sh <variant-name> <config-fragment> <modules-dest>
#
# All heavy output goes to build/variant-<name>/ so the source tree stays clean
# and the baseline build directory is never touched.
set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$BASE/source/linux-6.18.49"
NAME="${1:?usage: build-kernel-variant.sh <variant> <fragment> <modules-dest>}"
FRAGMENT="${2:?missing config fragment}"
MODDEST="${3:?missing modules destination}"
BUILD="$BASE/build/variant-$NAME"
BASE_CFG="$BASE/source/configs/common-6.18.49-os.config"

# make -C chdirs into the source tree, so relative paths (fragment, install
# dest) must be absolutized before use.
FRAGMENT="$(readlink -f "$FRAGMENT")"
MODDEST="$(mkdir -p "$MODDEST" && readlink -f "$MODDEST")"

JOBS="$(nproc)"

# arm64 is not the host arch, so ARCH/CROSS_COMPILE must be explicit;
# without ARCH the top-level Makefile has no Image.gz target, and without
# CROSS_COMPILE the host gcc rejects -mlittle-endian.
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
KMAKE=(make -C "$SRC" O="$BUILD" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE")

mkdir -p "$BUILD" "$MODDEST"
printf '==> variant=%s jobs=%s\n' "$NAME" "$JOBS"

cp "$BASE_CFG" "$BUILD/.config"
"$SRC/scripts/kconfig/merge_config.sh" -m -O "$BUILD" "$BUILD/.config" "$FRAGMENT" >/dev/null
"${KMAKE[@]}" olddefconfig >/dev/null

RELEASE="$("${KMAKE[@]}" kernelrelease 2>/dev/null | grep -v '目录')"
printf '==> kernel release: %s\n' "$RELEASE"

printf '==> building Image.gz + modules ...\n'
"${KMAKE[@]}" -j"$JOBS" Image.gz modules

printf '==> installing modules to %s ...\n' "$MODDEST"
rm -rf "$MODDEST/lib/modules"
"${KMAKE[@]}" INSTALL_MOD_PATH="$MODDEST" modules_install >/dev/null

printf '==> done\n'
printf 'release=%s\n' "$RELEASE"
ls -l "$BUILD/arch/arm64/boot/Image.gz"
find "$MODDEST/lib/modules" -maxdepth 1 -mindepth 1 -type d -print
