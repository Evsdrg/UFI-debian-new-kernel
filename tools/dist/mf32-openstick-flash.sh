# MF32 转 OpenStick 分区形式 + lk2nd 引导的一次性 9008 会话。
# 前提：
#   1. 设备已物理进 9008（本脚本不能把它弄进去）；
#   2. 整盘备份 out/mf32-device-backup/emmc-full.bin 已校验（回退底牌）；
#   3. 原厂 boot/system/persist 分区级读回在 out/mf32-device-backup/。
# 每步前置校验、失败即停；重跑幂等（已写入的内容重写无害）。
# 顺序刻意保守：先只动备份 GPT（主表未改，原厂 LK 视角一切正常），
# 验证后再动主表；写 rootfs（新位置）一定排在 GPT 变更之后。
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
BACK_PMT_LBA=7634911   # 备份 PMT 起点（= last_usable+1，gen-mf32-gpt.py 已断言）

edl() { timeout 420 "$V" "$E" "$@" --loader="$L" --sectorsize=512; }

echo "== 0. 设备确认 =="
lsusb | grep -q '05c6:9008' || { echo "设备不在 9008，中止"; exit 1; }

echo "== 1. 写备份 GPT（LBA$BACK_PMT_LBA 起，33 扇区；主表未动，仍安全）=="
edl ws "$BACK_PMT_LBA" "$G/gpt-back.bin"

echo "== 2. 写新 GPT 主表（LBA0..33，protective MBR 原样）=="
edl w gpt "$G/gpt-main.bin"

echo "== 3. 校验：edl 按新表识别分区 =="
edl printgpt | tee /tmp/mf32-gpt-new.log | grep -E '^(boot|rootfs|devinfo|persist):'
grep -q 'rootfs:' /tmp/mf32-gpt-new.log || { echo "新表未被识别，中止"; exit 1; }

echo "== 4. boot = lk2nd.img =="
[ -f "$P/lk2nd-msm8916.img" ] || { echo "缺 lk2nd 镜像"; exit 1; }
edl w boot "$P/lk2nd-msm8916.img"

echo "== 5. rootfs = Debian basic（含 extlinux；LBA 已变，必须排在 GPT 之后）=="
edl w rootfs "$ROOT/out/mf32-build/rootfs-mf32-7.2.9-basic.ext4"

echo "== 6. persist 迁移（源=原厂读回；新位置 LBA529504 与原 persist 重叠，
   放在最后写，中途失败时旧 persist 内容仍可被旧位置读到）=="
edl w persist "$D/persist.bin"

echo "== 7. 收尾：读回新表确认 =="
edl printgpt >/dev/null && echo "GPT OK"

echo
echo "完成。请【拔电+取电池静置 10 秒再上电】（不要 edl reset——需要 PMIC 完全复位，"
echo "      并清掉 LK 可能残留的 fastboot 模式标志）。"
echo "预期：原厂 LK → boot 分区=lk2nd（ATAG 路径加载，不查 DTB）"
echo "      → lk2nd 读 rootfs /extlinux/extlinux.conf → Debian mainline。"
echo
echo "回退（任何时刻可执行，回到原厂形态）："
echo "  edl w boot $D/boot.bin                                  # 原厂 boot"
echo "  edl w system $D/system.bin                              # 原厂 system（按新表写入会落到旧 system 的字节区）"
echo "  edl w gpt  $D/emmc-full.bin 前34扇区（dd 提取）        # 原 GPT 主表"
echo "  edl ws 7634911 原备份33扇区（dd 提取）                 # 原 GPT 备份"
echo "  或最粗粒度：edl wf $D/emmc-full.bin 整盘还原"
echo "  （回退件提取命令见本仓 boards/thwc-mf32/README.md）"
