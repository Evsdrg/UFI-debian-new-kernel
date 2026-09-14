#!/usr/bin/env bash
set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
. "$BASE/tools/kver.sh"
BUILD="$KERNEL_BUILD_DIR"
OUT="$BASE/out/boot-$KERNEL_VERSION"
MKBOOTIMG="$BASE/mkbootimg/mkbootimg"
CMDLINE='earlycon console=ttyMSM0,115200 root=PARTUUID=a7ab80e8-e9d1-e8cd-f157-93f69b1d141e rw rootwait'
# Compile the board DTS out of tree, the way the other packagers do: the sources
# live under boards/, and source/dts/common supplies the shared dtsi.
BOARD="$BASE/boards/ufi00x/ufi103s-ufi003"
K="$KERNEL_SRC"

build_dtb() {
    local dts="$1" dtb="$2"
    cpp -nostdinc -undef -D__DTS__ -x assembler-with-cpp \
        -I "$BASE/source/dts/common" \
        -I "$K/arch/arm64/boot/dts/qcom" \
        -I "$K/include" \
        "$dts" |
        dtc -q -I dts -O dtb -o "$dtb"
}
mkdir -p "$BUILD/dts"

mkdir -p "$OUT"
IMAGE_GZ="$BUILD/arch/arm64/boot/Image.gz"
RAMDISK="$OUT/empty-ramdisk"
: > "$RAMDISK"

build_one() {
    local name="$1"
    local dtb="$2"
    local kernel="$OUT/${name}.kernel-dtb"
    local boot="$OUT/${name}.img"
    cat "$IMAGE_GZ" "$dtb" > "$kernel"
    "$MKBOOTIMG" \
        --kernel "$kernel" \
        --ramdisk "$RAMDISK" \
        --base 0x80000000 \
        --kernel_offset 0x00080000 \
        --ramdisk_offset 0x02000000 \
        --second_offset 0x00f00000 \
        --tags_offset 0x01e00000 \
        --pagesize 2048 \
        --header_version 0 \
        --cmdline "$CMDLINE" \
        --output "$boot" >/dev/null
}

build_dtb "$BOARD/dts/msm8916-handsome-openstick-ufi103s.dts" \
    "$BUILD/dts/ufi103s.dtb"
build_dtb "$BOARD/dts/msm8916-handsome-openstick-ufi103s-oc12.dts" \
    "$BUILD/dts/ufi103s-oc12.dtb"

build_one "boot-ufi103s-$KERNEL_VERSION-baseline" "$BUILD/dts/ufi103s.dtb"
build_one "boot-ufi103s-$KERNEL_VERSION-oc12" "$BUILD/dts/ufi103s-oc12.dtb"

MANIFEST="$OUT/MANIFEST.txt"
{
    printf 'kernel_release=%s\n' "$KERNEL_RELEASE"
    printf 'image_gz='; sha256sum "$IMAGE_GZ"
    for name in boot-ufi103s-$KERNEL_VERSION-baseline boot-ufi103s-$KERNEL_VERSION-oc12; do
        boot="$OUT/${name}.img"
        kernel="$OUT/${name}.kernel-dtb"
        printf 'kernel_dtb='; sha256sum "$kernel"
        printf 'boot_image='; sha256sum "$boot"
        stat -c 'boot_size=%s %n' "$boot"
        printf 'dtb_magic_offsets='; python3 - "$kernel" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]).read_bytes()
needle=bytes.fromhex('d00dfeed')
o=0
vals=[]
while True:
    i=p.find(needle,o)
    if i < 0:
        break
    vals.append(str(i))
    o=i+1
print(','.join(vals))
PY
        "$BASE/mkbootimg/unpackbootimg" -i "$boot" -o "$OUT/${name}-unpacked" 2>&1 | rg 'BOARD_|magic' || true
    done
} > "$MANIFEST"

printf '%s\n' "$(< "$MANIFEST")"
