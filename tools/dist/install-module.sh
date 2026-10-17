#!/bin/sh
# Install a wcn36xx.ko over the running system's copy, with a backup and a
# vermagic check.
#
#   ./install-module.sh <path-to-wcn36xx.ko> [--revert]
#
# The module must match the running kernel exactly; the kernel refuses to load
# one whose vermagic differs, so this checks first rather than leaving you with
# a non-booting wireless stack.  The replaced module is copied aside so reverting
# is a single command.
#
# Nothing here is specific to the fix: it is just the safest way to swap one
# module on a live system.

set -u

BACKUP=/root/wcn36xx.ko.backup
DIR=/usr/lib/modules/$(uname -r)/kernel/drivers/net/wireless/ath/wcn36xx
TARGET=$DIR/wcn36xx.ko

usage() {
    echo "usage: $0 <wcn36xx.ko>   install a module (backs up the current one)" >&2
    echo "       $0 --revert         restore the backup" >&2
    exit 2
}

if [ "${1:-}" = "--revert" ]; then
    if [ ! -f "$BACKUP" ]; then
        echo "no backup at $BACKUP" >&2
        exit 1
    fi
    cp "$BACKUP" "$TARGET" || exit 1
    depmod -a
    echo "restored $BACKUP -> $TARGET"
    echo "reboot to take effect"
    exit 0
fi

[ $# -ge 1 ] || usage
SRC=$1
[ -f "$SRC" ] || { echo "not a file: $SRC" >&2; exit 1; }

command -v modinfo >/dev/null 2>&1 || { echo "modinfo missing (kmod not installed?)" >&2; exit 1; }

RUNNING=$(cat /proc/version | awk '{print $3}')
NEW=$(modinfo -F vermagic "$SRC" 2>/dev/null | awk '{print $1}')
[ -n "$NEW" ] || { echo "cannot read vermagic from $SRC" >&2; exit 1; }

echo "running kernel : $RUNNING"
echo "module vermagic: $NEW"

if [ "$RUNNING" != "$NEW" ]; then
    echo
    echo "REFUSING: vermagic mismatch." >&2
    echo "This module was built against a different kernel and will not load." >&2
    echo "Build it against the kernel you are running, or use a matching boot image." >&2
    exit 1
fi

if [ ! -f "$TARGET" ]; then
    echo "current module not found at $TARGET" >&2
    echo "check the path for your kernel, or that wcn36xx is modular (not built-in)" >&2
    exit 1
fi

if [ ! -f "$BACKUP" ]; then
    cp "$TARGET" "$BACKUP" || exit 1
    echo "backed up the current module to $BACKUP"
else
    echo "backup already exists at $BACKUP (kept as-is)"
fi

# Same file on both sides is a legitimate no-op test, and `cp` complains about it.
if [ "$(readlink -f "$SRC")" != "$(readlink -f "$TARGET")" ]; then
    cp "$SRC" "$TARGET" || exit 1
fi
depmod -a || exit 1

echo "installed $SRC -> $TARGET"
echo "sha256(new)=$(sha256sum "$TARGET" | cut -d' ' -f1)"
echo
echo "reboot to load it, then run tools/wifi-tx-test.sh to measure"
echo "to undo: $0 --revert"
