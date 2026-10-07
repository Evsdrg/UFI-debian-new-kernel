#!/usr/bin/env bash
# 对矩阵全部镜像跑 QEMU 冒烟（配对各档内核）。
# max 用 GPU 内核（模块配对），其余用基线内核。
set -u
BASE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$BASE"
. tools/kver.sh
V="$KERNEL_VERSION"

declare -A K=(
  [max]="$BASE/build/variant-$V-board-venus-4g-gpu/arch/arm64/boot/Image.gz"
  [basic]="$BASE/build/variant-$V-board-4g/arch/arm64/boot/Image.gz"
  [slim]="$BASE/build/variant-$V-board-baseline/arch/arm64/boot/Image.gz"
  [micro]="$BASE/build/variant-$V-board-baseline/arch/arm64/boot/Image.gz"
)

rc=0
for t in max basic slim micro basic-native slim-native micro-native; do
  img="shared/rootfs/ufi103s-$V-$t.ext4"
  if [ ! -f "$img" ]; then
    echo "SMOKE[$t] SKIP（镜像不存在）"
    continue
  fi
  gz="${K[${t%-native}]}"
  if [ ! -f "$gz" ]; then
    echo "SMOKE[$t] SKIP（内核 $gz 不存在）"
    continue
  fi
  tools/qemu-smoke.sh "$img" "$gz" || rc=1
done
exit $rc
