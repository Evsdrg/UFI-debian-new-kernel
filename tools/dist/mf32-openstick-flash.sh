#!/usr/bin/env bash
# MF32 → OpenStick 分区形式 + lk2nd 引导的一次性 9008 会话。
# 前提：设备已物理进 9008；整盘备份 out/mf32-device-backup/emmc-full.bin 已校验。
# 每一步都可单独重跑；任何一步失败即停止，重跑本脚本会跳过已完成项。
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT=$PWD
V=$ROOT/edl-tools/venv/bin/python
E=$ROOT/edl-tools/edl/edl.py
L=$ROOT/edl-tools/Miko/loader-audit/generic
D=$ROOT/out/mf32-device-backup
G=$ROOT/out/mf32-gpt
P=$ROOT/out/mf32-build/package
SS=512
BACK_PMT_LBA=7634911   # 备份 PMT 起点（= last_usable+1，由 gen-mf32-gpt.py 验证）

edl() { timeout 420 "$V" "$E" "$@" --loader="$L" --sectorsize=512; }

echo "== 0. 设备确认 =="
lsusb | grep -q '05c6:9008' || { echo "设备不在 9008，中止"; exit 1; }

echo "== 1. 写新 GPT 主表（LBA0..33，含 protective MBR 原样）=="
edl w gpt "$G/gpt-main.bin"

echo "== 2. 写备份 GPT（LBA$BACK_PMT_LBA 起 33 扇区）=="
edl ws "$BACK_PMT_LBA" "$G/gpt-back.bin"

echo "== 3. 校验：edl 应能按新表识别分区 =="
edl printgpt | tee /tmp/mf32-gpt-new.log | grep -E '^(boot|rootfs|devinfo|persist):' 
grep -q 'rootfs:' /tmp/mf32-gpt-new.log || { echo "新表未被识别，中止"; exit 1; }

echo "== 4. persist 迁移（原内容 → 新位置，分区层写；先校验源文件）=="
sha256sum -c <(grep ' persist.bin$' "$D/SHA256SUMS.txt") 
edl w persist "$D/persist.bin"

echo "== 5. boot = lk2nd.img =="
[ -f "$P/lk2nd-msm8916.img" ] || { echo "缺 lk2nd 镜像"; exit 1; }
edl w boot "$P/lk2nd-msm8916.img"

echo "== 6. rootfs = Debian basic（含 extlinux）=="
sha256sum -c <(grep 'rootfs-mf32-7.2.9-basic.ext4$' "$P/SHA256SUMS.txt")
edl w rootfs "$ROOT/out/mf32-build/rootfs-mf32-7.2.9-basic.ext4"

echo "== 7. 收尾校验 =="
edl printgpt >/dev/null && echo "GPT OK"

echo
echo "完成。断电重上电（不要 edl reset——让 PMIC 完全放电复位），"
echo "预期：原厂 LK 加载 boot=lk2nd → lk2nd 读 rootfs /extlinux → Debian。"
echo "回退路径：edl w boot $D/boot.bin && edl w system $D/system.bin && 写回原表 $D/... gpt 区段。"
