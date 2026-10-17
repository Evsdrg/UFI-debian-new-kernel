#!/bin/sh
# Regenerate build.json for each builds/boot/<variant>/.
#
# sha256, vermagic and the boot cmdline are read from the files. Anything
# that cannot be read is fixed text, and that text does not claim a flash
# or a retest: these directories are the 7.2.9 ufi103s set; the generic
# sentence below says "not flashed", and any directory whose verification
# state differs carries its own STATUS.txt.
#
# One directory must contain exactly one *.img and exactly one wcn36xx.ko.
# A single kernel_release stamped onto a mixed directory was a real bug in
# the old 6.18.49 ufi103s drop (venus images labeled with the non-venus
# release).

set -eu

# This script lives in tools/dist/; the repository root is two levels up.
BASE=$(cd "$(dirname "$0")/../.." && pwd)
NOW=$(date -u +%FT%TZ)
STATUS="packaged from the 7.2.9 ufi103s board set; this exact image has not been flashed. The WiFi patch was measured on the author's ufi103s (WCN3620) on 6.18.49; this package is not that retest."

# Per-variant status override: drop a one-line text file next to the image.
# Used where a variant's verification state differs from the generic sentence
# above (e.g. booted in RAM on hardware but never flashed).
status_for() {
    sf="$1/STATUS.txt"
    if [ -f "$sf" ]; then tr '\n' ' ' < "$sf" | sed 's/  */ /g; s/ *$//'; else echo "$STATUS"; fi
}

hash_block() {
    dir=$1
    first=1
    for f in "$dir"/*.ko "$dir"/*.img "$dir"/*.dtb; do
        [ -f "$f" ] || continue
        name=$(basename "$f")
        sum=$(sha256sum "$f" | cut -d' ' -f1)
        [ "$first" = 1 ] || printf ',\n'
        printf '    "%s": "%s"' "$name" "$sum"
        first=0
    done
    [ "$first" = 1 ] || printf '\n'
}

cmdline_of() {
    # Android boot header v0: cmdline is 512 bytes at offset 64.
    dd if="$1" bs=1 skip=64 count=512 2>/dev/null | tr '\0' '\n' | head -n 1
}

found=0
for D in "$BASE"/builds/boot/*; do
    [ -d "$D" ] || continue
    found=1
    board=$(basename "$D")
    set -- "$D"/*.img
    if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then
        echo "need exactly one boot image in $D" >&2
        exit 1
    fi
    img=$1
    ko=$D/wcn36xx.ko
    if [ ! -f "$ko" ]; then
        echo "missing $ko" >&2
        exit 1
    fi
    vermagic=$(modinfo -F vermagic "$ko")
    release=${vermagic%% *}
    cmdline=$(cmdline_of "$img")
    status=$(status_for "$D")
    case "$cmdline$vermagic" in
        *\"*|*\\*)
            echo "refusing to embed a quote or backslash from $D" >&2
            exit 1
            ;;
    esac
    {
        printf '{\n'
        printf '  "board": "%s",\n' "$board"
        printf '  "contents": "Android legacy boot image (header v0, page 2048): kernel + appended DTB only. wcn36xx.ko sits beside the image, not inside it, and loads only on the vermagic below.",\n'
        printf '  "cmdline": "%s",\n' "$cmdline"
        printf '  "kernel_release": "%s",\n' "$release"
        printf '  "vermagic": "%s",\n' "$vermagic"
        printf '  "status": "%s",\n' "$status"
        printf '  "generated_utc": "%s",\n' "$NOW"
        printf '  "files": {\n'
        hash_block "$D"
        printf '  }\n'
        printf '}\n'
    } > "$D/build.json"
    echo "wrote $D/build.json ($release)"
done

[ "$found" = 1 ] || {
    echo "no builds/boot/* directories" >&2
    exit 1
}
