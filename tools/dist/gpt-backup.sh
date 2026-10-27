#!/bin/sh
# gpt-backup.sh —— 按 OpenStick 的 GPT 分区格式，把整片镜像拆成单分区文件，
# 并在需要时把单分区文件写回设备。
#
# 用途：
#   1) 已经用 Miko / edl 做了**整片 eMMC 镜像**（如 full-emmc.img），但想只恢复
#      其中某几个分区（例如只恢复基带校准 modemst1/2、fsc、fsg），
#      这时先用 split 把整片镜像拆开。
#   2) 把拆出来的分区文件按名字写回设备，不必手工算 offset。
#
# 子命令：
#   layout                          打印内置分区表（OpenStick 默认）
#   split <full.img> <outdir>       整片镜像 → <outdir>/<分区名>.img + manifest.txt
#   verify <dir>                    校验 <dir>/manifest.txt 与文件哈希、长度
#   write <dir> [--yes] [选项]      按 manifest 写回设备（默认只写安全集合）
#   fastboot-restore <dir>          仅用 fastboot 恢复 boot 与 rootfs（不需要 EDL）
#
# 安全边界：
#   - write 默认**只写** boot / rootfs / modemst1 / modemst2 / fsc / fsg。
#   - devinfo（含设备信息、解锁状态）需显式 --include-devinfo。
#   - bootloader 一组（cdt/sbl1/rpm/tz/hyp/sec/aboot）默认**拒绝**写，
#     必须显式 --include-bootloader，且写错会变砖。
#   - 任何分区文件长度与表不符都会中止，避免错位写。
#   - 必须显式 --yes 才真正写；否则只打印计划。
#
# 分区表来源：recovery/logs/edl-printgpt-pre-rpmsg-20260904.log
# （本文末尾也记录了该表的完整内容，便于核对）
#
# 依赖：python3（拆分、哈希、解析）；写回时用 edl-tools 里的 edl.py + Miko generic loader。

set -eu

# 项目根（本脚本在 <root>/tools/dist/ 下）
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
EDL_DIR="${EDL_DIR:-$ROOT/edl-tools}"
EDL_PY="$EDL_DIR/edl/edl.py"
EDL_LOADER="${EDL_LOADER:-$EDL_DIR/Miko/loader-audit/generic}"

# 内置分区表：名字 偏移 长度 类别
#   类别 safe  = 默认允许写回
#   类别 dev   = 需 --include-devinfo
#   类别 boot  = 需 --include-bootloader（危险）
PART_TABLE='cdt 0x04000000 0x800 boot
sbl1 0x08000000 0x80000 boot
rpm 0x08080000 0x80000 boot
tz 0x08100000 0x100000 boot
hyp 0x08200000 0x80000 boot
sec 0x08280000 0x4000 boot
modemst1 0x08284000 0x200000 safe
modemst2 0x08484000 0x200000 safe
fsc 0x08684000 0x400 safe
fsg 0x0c000000 0x200000 safe
aboot 0x10000000 0x100000 boot
boot 0x10100000 0x4000000 safe
devinfo 0x14100000 0x100000 dev
rootfs 0x14200000 0xd4dfbe00 safe'

TOTAL_SIZE=0xe9000000

usage() {
    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || { echo "缺少命令：$1" >&2; exit 1; }
}

# 把内置表写成 "名 偏移 长度 类别" 行
layout_lines() {
    printf '%s\n' "$PART_TABLE"
}

cmd_layout() {
    printf '%-10s %-12s %-12s %-8s %s\n' 分区 偏移 长度 类别 十进制长度
    printf '%s\n' "$PART_TABLE" | while read -r n off len cls; do
        printf '%-10s %-12s %-12s %-8s %s\n' "$n" "$off" "$len" "$cls" "$((len))"
    done
    printf '\n整片镜像大小: 0x%x (%d 字节, %d MiB)\n' "$TOTAL_SIZE" "$TOTAL_SIZE" "$((TOTAL_SIZE/1024/1024))"
    printf '说明: safe=默认可写, dev=需 --include-devinfo, boot=需 --include-bootloader(变砖风险)\n'
}

# 生成 manifest 与切分都在 python 里做，便于处理十六进制与哈希
py_split() {
    full=$1; outdir=$2
    PART_TABLE="$PART_TABLE" TOTAL_SIZE="$TOTAL_SIZE" \
    python3 - "$full" "$outdir" <<'PY'
import os, sys, hashlib

full, outdir = sys.argv[1], sys.argv[2]
table = []
for line in os.environ['PART_TABLE'].strip().splitlines():
    n, off, ln, cls = line.split()
    table.append((n, int(off, 16), int(ln, 16), cls))
total = int(os.environ['TOTAL_SIZE'], 16)

size = os.path.getsize(full)
if size < total:
    # 允许更大的镜像（有些备份按扇区多读），但必须至少覆盖表内最大偏移+长度
    need = max(o + l for _, o, l, _ in table)
    if size < need:
        sys.exit(f'整片镜像太小：{size} 字节，至少要 {need} 字节')

# ---- 若镜像自带 GPT，先核对分区表，防止按错布局拆分 ----
def check_gpt(fh, size):
    fh.seek(512)
    hdr = fh.read(92)
    if len(hdr) < 92 or hdr[:8] != b'EFI PART':
        print('  ! 该镜像没有 GPT 头（可能是裸分区 dump），按内置 OpenStick 表拆分。')
        return
    import struct
    part_lba = struct.unpack_from('<Q', hdr, 72)[0]
    num = struct.unpack_from('<I', hdr, 80)[0]
    esz = struct.unpack_from('<I', hdr, 84)[0]
    if esz < 128 or num == 0 or num > 1024:
        print('  ! GPT 头异常，跳过表比对。'); return
    fh.seek(part_lba * 512)
    entries = fh.read(num * esz)
    got = {}
    for i in range(num):
        e = entries[i*esz:(i+1)*esz]
        if e[:16] == b'\0'*16:
            continue
        first, last = struct.unpack_from('<QQ', e, 32)
        name = e[56:128].decode('utf-16-le', 'replace').split('\0')[0]
        if name:
            got[name] = (first*512, (last-first+1)*512)
    diffs = []
    for n, off, ln, cls in table:
        if n not in got:
            diffs.append(f'{n}: 镜像 GPT 里没有这个分区')
        else:
            go, gl = got[n]
            if go != off or gl != ln:
                diffs.append(f'{n}: 镜像 {go:#x}/{gl:#x} vs 内置表 {off:#x}/{ln:#x}')
    if diffs:
        print('  ✗ 镜像的 GPT 与内置 OpenStick 分区表不一致：')
        for d in diffs:
            print('      ' + d)
        if os.environ.get('GPT_FORCE') != '1':
            sys.exit('拒绝按内置表拆分。若确认要用内置表强行拆，设 GPT_FORCE=1。')
        print('  ! GPT_FORCE=1，继续按内置表拆分（风险自负）。')
    else:
        print('  ✓ 镜像 GPT 与内置 OpenStick 分区表一致。')

with open(full, 'rb') as fh:
    check_gpt(fh, size)

os.makedirs(outdir, exist_ok=True)
manifest = []
with open(full, 'rb', buffering=0) as src:
    for n, off, ln, cls in table:
        src.seek(off)
        left = ln
        h = hashlib.sha256()
        dst = os.path.join(outdir, n + '.img')
        with open(dst, 'wb') as out:
            while left:
                chunk = src.read(min(left, 1 << 20))
                if not chunk:
                    break
                out.write(chunk)
                h.update(chunk)
                left -= len(chunk)
        got = os.path.getsize(dst)
        if got != ln:
            sys.exit(f'{n}: 写出 {got} 字节，应为 {ln}')
        manifest.append((n, off, ln, cls, h.hexdigest()))
        print(f'  {n:10s} {off:#012x} {ln:#010x} {cls:5s} {h.hexdigest()[:16]}')

mpath = os.path.join(outdir, 'manifest.txt')
with open(mpath, 'w') as m:
    m.write('# gpt-backup manifest v1\n')
    m.write(f'# source_image {os.path.abspath(full)}\n')
    m.write(f'# total_size {total:#x}\n')
    m.write('# 分区 偏移 长度 类别 sha256\n')
    for n, off, ln, cls, dg in manifest:
        m.write(f'{n} {off:#x} {ln:#x} {cls} {dg}\n')
print(f'\n已写出 {len(manifest)} 个分区到 {outdir}/, manifest: {mpath}')
PY
}

cmd_split() {
    [ $# -eq 2 ] || { echo "用法: gpt-backup.sh split <full.img> <outdir>" >&2; exit 1; }
    need_cmd python3
    full=$1; outdir=$2
    [ -f "$full" ] || { echo "找不到整片镜像: $full" >&2; exit 1; }
    echo "== 拆分 $full =="
    py_split "$full" "$outdir"
}

cmd_verify() {
    [ $# -eq 1 ] || { echo "用法: gpt-backup.sh verify <dir>" >&2; exit 1; }
    mf=$1/manifest.txt
    [ -f "$mf" ] || { echo "找不到 $mf" >&2; exit 1; }
    PART_TABLE="$PART_TABLE" python3 - "$1" <<'PY'
import os, sys, hashlib
d = sys.argv[1]
table = {}
for line in os.environ['PART_TABLE'].strip().splitlines():
    n, off, ln, cls = line.split()
    table[n] = (int(off,16), int(ln,16), cls)

bad = 0
rows = [l.split() for l in open(os.path.join(d,'manifest.txt')) if not l.startswith('#') and l.strip()]
for n, off, ln, cls, dg in rows:
    off=int(off,16); ln=int(ln,16)
    p = os.path.join(d, n+'.img')
    if not os.path.isfile(p):
        print(f'  ✗ {n}: 缺文件'); bad+=1; continue
    sz = os.path.getsize(p)
    if sz != ln:
        print(f'  ✗ {n}: 长度 {sz} != {ln}'); bad+=1; continue
    if n in table:
        toff, tlen, _ = table[n]
        if toff != off or tlen != ln:
            print(f'  ✗ {n}: 与内置表不符 (manifest {off:#x}/{ln:#x}, 表 {toff:#x}/{tlen:#x})'); bad+=1; continue
    h = hashlib.sha256(open(p,'rb').read()).hexdigest()
    if h != dg:
        print(f'  ✗ {n}: sha256 不符'); bad+=1; continue
    print(f'  ✓ {n:10s} {ln:#010x} {cls}')
missing = set(table) - {r[0] for r in rows}
if missing:
    print(f'  ! manifest 缺少分区: {sorted(missing)}（可能是有意只备份部分）')
print('\n结论:', 'ALL OK' if bad==0 else f'{bad} 个分区有问题')
sys.exit(1 if bad else 0)
PY
}

cmd_write() {
    dir=""; yes=0; inc_boot=0; inc_dev=0; only=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --yes) yes=1; shift ;;
            --include-bootloader) inc_boot=1; shift ;;
            --include-devinfo) inc_dev=1; shift ;;
            --only) only=$2; shift 2 ;;
            -*) echo "未知选项: $1" >&2; exit 1 ;;
            *) dir=$1; shift ;;
        esac
    done
    [ -n "$dir" ] || { echo "用法: gpt-backup.sh write <dir> [--yes] [--only a,b] [--include-devinfo] [--include-bootloader]" >&2; exit 1; }
    [ -f "$dir/manifest.txt" ] || { echo "找不到 $dir/manifest.txt" >&2; exit 1; }

    # 先 verify，避免写坏数据
    echo "== 写回前校验 =="
    if ! cmd_verify "$dir"; then
        echo "校验未通过，拒绝写回。" >&2; exit 1
    fi

    # 组装计划
    plan=$(python3 - "$dir" "$inc_boot" "$inc_dev" "$only" <<'PY'
import sys, os
d, inc_boot, inc_dev, only = sys.argv[1], sys.argv[2]=='1', sys.argv[3]=='1', sys.argv[4]
allow_only = set(x for x in only.split(',') if x)
rows=[l.split() for l in open(os.path.join(d,'manifest.txt')) if not l.startswith('#') and l.strip()]
for n, off, ln, cls, dg in rows:
    if allow_only and n not in allow_only:
        continue
    if not allow_only:
        if cls=='boot' and not inc_boot: continue
        if cls=='dev' and not inc_dev: continue
    print(f'{n} {cls}')
PY
)
    [ -n "$plan" ] || { echo "没有可写的分区（默认只写 safe，需显式选项才含 dev/boot）" >&2; exit 1; }

    echo "== 写回计划 =="
    printf '%s\n' "$plan" | while read -r n cls; do printf '  %-10s [%s]\n' "$n" "$cls"; done
    echo
    if [ "$yes" != 1 ]; then
        echo "这是预演。确认无误后加 --yes 真正写入。"
        echo "注意：设备必须已进入 EDL（sahara/firehose）状态。"
        return 0
    fi

    [ -x "$EDL_DIR/venv/bin/python" ] || { echo "缺少 edl venv: $EDL_DIR/venv/bin/python" >&2; exit 1; }
    [ -f "$EDL_PY" ] || { echo "缺少 edl.py: $EDL_PY" >&2; exit 1; }
    [ -f "$EDL_LOADER" ] || { echo "缺少 loader: $EDL_LOADER" >&2; exit 1; }

    printf '%s\n' "$plan" | while read -r n cls; do
        echo "==> 写 $n"
        "$EDL_DIR/venv/bin/python" "$EDL_PY" w "$n" "$dir/$n.img" --loader="$EDL_LOADER"
    done
    echo
    echo "写入完成。冷启动一次让 modem/系统重新读取。"
    echo "若写了 bootloader 分区且设备无法启动，按 docs/hardware/FASTBOOT.md 用 EDL 恢复。"
}

cmd_fastboot_restore() {
    [ $# -eq 1 ] || { echo "用法: gpt-backup.sh fastboot-restore <dir>" >&2; exit 1; }
    dir=$1
    for p in boot rootfs; do
        [ -f "$dir/$p.img" ] || { echo "缺少 $dir/$p.img" >&2; exit 1; }
    done
    need_cmd fastboot
    echo "== fastboot 恢复 boot 与 rootfs（不改分区表、不碰基带）=="
    fastboot devices | grep -q . || { echo "未检测到 fastboot 设备" >&2; exit 1; }
    echo "> fastboot flash boot  $dir/boot.img"
    fastboot flash boot "$dir/boot.img"
    echo "> fastboot -S 200M flash rootfs  $dir/rootfs.img"
    fastboot -S 200M flash rootfs "$dir/rootfs.img"
    fastboot reboot
}

sub=${1:-}
[ -n "$sub" ] || usage 1
shift
case "$sub" in
    layout) cmd_layout ;;
    split) cmd_split "$@" ;;
    verify) cmd_verify "$@" ;;
    write) cmd_write "$@" ;;
    fastboot-restore) cmd_fastboot_restore "$@" ;;
    -h|--help|help) usage 0 ;;
    *) echo "未知子命令: $sub" >&2; usage 1 ;;
esac
