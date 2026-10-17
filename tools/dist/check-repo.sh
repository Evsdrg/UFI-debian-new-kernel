#!/bin/sh
# Self-check for this repository.
#
# Verifies the things that silently rot: shell syntax, that every patch still
# applies to a pristine tree, that the hashes recorded in each build.json match
# the artifacts beside them, and that every local path referenced from the
# documentation exists.
#
#   ./tools/dist/check-repo.sh [path-to-kernel-tree]
#
# The kernel tree argument is a *git working tree* whose HEAD is the pristine
# upstream state (the patched files may be modified in the working copy; the
# check reads the committed versions).  Without it, the patch-apply check is
# skipped.

set -u

BASE=$(cd "$(dirname "$0")/../.." && pwd)
KERNEL=${1:-}
FAIL=0

ok()  { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=1; }

echo "== shell scripts =="
for f in "$BASE"/tools/dist/*.sh; do
    [ -f "$f" ] || continue
    if sh -n "$f" 2>/dev/null; then ok "$(basename "$f")"; else bad "$(basename "$f") syntax"; fi
done

echo
echo "== patches present =="
n=0
for p in "$BASE"/source/patches/*.patch; do
    [ -f "$p" ] || continue
    ok "$(basename "$p")"
    n=$((n + 1))
done
[ "$n" -gt 0 ] || bad "no patches found"

if [ -n "$KERNEL" ]; then
    echo
    echo "== patches apply to pristine tree (git HEAD) =="
    rel=drivers/net/wireless/ath/wcn36xx
    if git -C "$KERNEL" rev-parse --git-dir >/dev/null 2>&1 && \
       git -C "$KERNEL" cat-file -e "HEAD:$rel/smd.c" 2>/dev/null; then
        for p in "$BASE"/source/patches/000[123]-wifi-*.patch; do
            [ -f "$p" ] || continue
            TMP=$(mktemp -d)
            mkdir -p "$TMP/$rel"
            # Pristine content straight out of the commit, not the working tree.
            for f in debug.c debug.h main.c smd.c wcn36xx.h; do
                git -C "$KERNEL" show "HEAD:$rel/$f" > "$TMP/$rel/$f" 2>/dev/null
            done
            if (cd "$TMP" && patch -p1 --dry-run < "$p" >/dev/null 2>&1); then
                ok "$(basename "$p") applies"
            else
                bad "$(basename "$p") does not apply to HEAD"
            fi
            rm -rf "$TMP"
        done
    else
        bad "not a usable git tree: $KERNEL"
    fi
else
    echo
    echo "== patches apply =="
    echo "  skipped (pass a kernel git tree as \$1 to enable)"
fi

echo
echo "== artifact hashes match their build.json =="
found_manifest=0
for j in "$BASE"/builds/boot/*/build.json; do
    [ -f "$j" ] || continue
    found_manifest=1
    dir=$(dirname "$j")
    # Manifest lists files as "name": "sha256" inside the files block.
    awk '/"files"[[:space:]]*:/,/^[[:space:]]*}/' "$j" |
        grep -oE '"[A-Za-z0-9_.-]+"[[:space:]]*:[[:space:]]*"[0-9a-f]{64}"' |
    while IFS= read -r line; do
        name=$(echo "$line" | sed 's/^"\([^"]*\)".*/\1/')
        want=$(echo "$line" | sed 's/.*"\([0-9a-f]\{64\}\)"$/\1/')
        f="$dir/$name"
        if [ ! -f "$f" ]; then
            bad "${dir#$BASE/}/$name listed but missing"
        elif [ "$(sha256sum "$f" | cut -d' ' -f1)" = "$want" ]; then
            ok "${dir#$BASE/}/$name"
        else
            bad "${dir#$BASE/}/$name hash mismatch"
        fi
    done
done
[ "$found_manifest" = 1 ] || bad "no build.json manifests found"

echo
echo "== every artifact is covered by a manifest =="
for d in "$BASE"/builds/boot/*; do
    [ -d "$d" ] || continue
    for f in "$d"/*.ko "$d"/*.img "$d"/*.dtb; do
        [ -f "$f" ] || continue
        name=$(basename "$f")
        if grep -q "\"$name\"" "$d/build.json" 2>/dev/null; then
            :
        else
            bad "${d#$BASE/}/$name has no recorded hash"
        fi
    done
done
ok "artifact coverage"

echo
echo "== documentation links resolve =="
for md in "$BASE"/README.md "$BASE"/docs/*.md "$BASE"/docs/dist/*.md "$BASE"/builds/README.md; do
    [ -f "$md" ] || continue
    d=$(dirname "$md")
    grep -oE '\]\([^)]+\)' "$md" 2>/dev/null |
        sed 's/^](//; s/)$//' | sort -u |
    while IFS= read -r link; do
        case "$link" in
            http*|\#*) continue ;;
        esac
        case "$link" in
            *".md"|*".sh"|*".patch"|*".json"|*".ko"|*".img") ;;
            *) continue ;;
        esac
        if [ -e "$d/$link" ] || [ -e "$BASE/$link" ]; then
            ok "$(basename "$md") -> $link"
        else
            bad "$(basename "$md") -> $link (missing)"
        fi
    done
done

echo
if [ "$FAIL" = 0 ]; then
    echo "ALL CHECKS PASSED"
else
    echo "SOME CHECKS FAILED"
fi
exit "$FAIL"
