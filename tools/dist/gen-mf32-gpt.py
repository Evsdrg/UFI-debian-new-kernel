#!/usr/bin/env python3
"""生成 OpenStick 形式的 MF32 GPT（方案 A，2026-10-29 定案）。

原则：
- boot 之前的固件/校准分区条目**原样拷贝**（LBA、GUID、type、flags 全不动）；
- boot 扩为 64MB（对齐 UFI 表），其后 devinfo(1MB) → persist(32MB 迁移) →
  rootfs(直到 last usable)；system/cache/config/recovery/userdata 移除。
- 输入 = 整盘镜像的开头（protective MBR + 主 header + PMT）。
- 输出：
    gpt-main.bin  34 扇区，`edl w gpt` 从 LBA0 写（MBR 原样 + 新 header/PMT）
    gpt-back.bin  33 扇区，`edl ws <pmt备份起点> 33` 写盘尾（PMT + 备份 header）

UEFI GPT header 偏移（相对 header 起点）：
    8 Revision | 12 HeaderSize | 16 HdrCRC32 | 24 MyLBA | 32 AltLBA
    40 FirstUsable | 48 LastUsable | 56 DiskGUID | 72 PmtLBA
    80 EntryCount | 84 EntrySize | 88 PmtCRC32

用法：python3 tools/dist/gen-mf32-gpt.py <emmc-full.bin> <outdir>
"""
import struct, sys, uuid, zlib, pathlib

SS = 512

def parse_hdr(hb):
    assert hb[:8] == b"EFI PART", hb[:8]
    rev, hdrsz = struct.unpack_from("<II", hb, 8)
    hcrc = struct.unpack_from("<I", hb, 16)[0]
    my, alt, fu, lu = struct.unpack_from("<4Q", hb, 24)
    dguid = uuid.UUID(bytes_le=bytes(hb[56:72]))
    pmtlba, n, es, pcrc = struct.unpack_from("<QII4x", hb, 72)[:3] + (struct.unpack_from("<I", hb, 88)[0],)
    return dict(hdrsz=hdrsz, hcrc=hcrc, my=my, alt=alt, fu=fu, lu=lu, dguid=dguid,
                pmtlba=pmtlba, n=n, es=es, pcrc=pcrc)

def parse_entry(e):
    return dict(type=uuid.UUID(bytes_le=e[0:16]), own=uuid.UUID(bytes_le=e[16:32]),
                first=struct.unpack_from("<Q", e, 32)[0],
                last=struct.unpack_from("<Q", e, 40)[0],
                flags=struct.unpack_from("<Q", e, 48)[0],
                name=e[56:128].decode("utf-16-le").rstrip("\x00"))

def make_entry(p):
    e = bytearray(128)
    e[0:16] = p["type"].bytes_le
    e[16:32] = p["own"].bytes_le
    struct.pack_into("<QQQ", e, 32, p["first"], p["last"], p["flags"])
    nm = p["name"].encode("utf-16-le")
    e[56:56+len(nm)] = nm
    return bytes(e)

def fix_header(hb, hdrsz, pmt_crc):
    """重算 PMTCRC 与 header CRC（先清 @16 与 @88，CRC 覆盖 0..hdrsz）。"""
    out = bytearray(hb[:hdrsz])
    out += bytes(hb[hdrsz:SS])
    struct.pack_into("<I", out, 88, pmt_crc)
    struct.pack_into("<I", out, 16, 0)
    struct.pack_into("<I", out, 16, zlib.crc32(bytes(out[:hdrsz])) & 0xFFFFFFFF)
    return bytes(out)

def main():
    src = pathlib.Path(sys.argv[1])
    out = pathlib.Path(sys.argv[2]); out.mkdir(parents=True, exist_ok=True)

    with src.open("rb") as f:
        mbr = f.read(SS)
        hraw = f.read(SS)
        f.seek(0)
        head34 = f.read(34 * SS)
    mh = parse_hdr(hraw)
    n, es, pmtlba = mh["n"], mh["es"], mh["pmtlba"]
    assert n * es <= 32 * SS and n >= 25, (n, es)  # 厂商表可能 n=28（容量=实际），留够新条目
    with src.open("rb") as f:
        f.seek(pmtlba * SS); pmt = f.read(n * es)
        # 备份 header 就在 alt_lba（本盘 = 盘最后一个扇区），备份 PMT 在它前面
        f.seek(mh["alt"] * SS); bhdr = f.read(SS)
    bh = parse_hdr(bhdr)
    assert bh["my"] == mh["alt"] and bh["alt"] == mh["my"] and bh["pmtlba"] == mh["lu"] + 1
    back_pmt_lba = bh["pmtlba"]

    parts = []
    for i in range(n):
        e = pmt[i*es:(i+1)*es]
        if e[:16] == b"\x00"*16: break
        parts.append(parse_entry(e))
    by = {p["name"]: p for p in parts}
    boot_old, persist_old, system_old = by["boot"], by["persist"], by["system"]

    NEW = []
    for p in parts:                      # 1) boot 之前原样保留
        if p["first"] >= boot_old["first"]: break
        NEW.append(dict(p))
    def add(name, first, sectors, ptype, flags=0):
        NEW.append(dict(type=ptype, own=uuid.uuid4(), first=first,
                        last=first + sectors - 1, flags=flags, name=name))
    add("boot", boot_old["first"], 131072, boot_old["type"])          # 64MB
    nxt = boot_old["first"] + 131072
    add("devinfo", nxt, 2048, by["misc"]["type"]); nxt += 2048         # 1MB
    add("persist", nxt, 65536, persist_old["type"], persist_old["flags"]); nxt += 65536
    add("rootfs", nxt, mh["lu"] - nxt + 1, system_old["type"])         # 到盘尾

    newpmt = bytearray()
    for p in NEW:
        newpmt += make_entry(p)
    assert len(newpmt) <= n * es, "条目超出 header EntryCount 容量"
    newpmt += bytes(n * es - len(newpmt))          # CRC 覆盖区 = n*es
    pmt_crc = zlib.crc32(bytes(newpmt)) & 0xFFFFFFFF
    area = bytearray(newpmt) + bytes(32 * SS - n * es)  # 写入区铺满 32 扇区

    m = bytearray(head34)
    m[SS:SS+mh["hdrsz"]] = fix_header(head34[SS:2*SS], mh["hdrsz"], pmt_crc)[:mh["hdrsz"]]
    m[2*SS:2*SS+len(area)] = area
    (out / "gpt-main.bin").write_bytes(bytes(m[:34*SS]))

    b = bytearray(33 * SS)
    b[0:len(area)] = area
    nb = bytearray(bhdr)
    nb[0:bh["hdrsz"]] = fix_header(bytes(bhdr), bh["hdrsz"], pmt_crc)[:bh["hdrsz"]]
    b[32*SS:32*SS+bh["hdrsz"]] = nb[:bh["hdrsz"]]
    (out / "gpt-back.bin").write_bytes(bytes(b))
    assert back_pmt_lba == mh["lu"] + 1 == mh["alt"] - 32, back_pmt_lba

    print(f"保留条目 {len(NEW)-4} + 新增 4 = {len(NEW)}/{n}   PMT CRC {pmt_crc:#010x}")
    prev = 0
    for p in NEW:
        assert p["first"] >= prev and p["first"] >= 34 and p["last"] <= mh["lu"], p["name"]
        prev = p["last"] + 1
        print(f"  {p['name']:<10} LBA{p['first']}..{p['last']}  ({(p['last']-p['first']+1)*SS/2**20:9.1f} MiB)")
    assert NEW[-1]["last"] == mh["lu"], "rootfs 必须到 last usable"
    print(f"主表: LBA0..33（写 edl w gpt）\n备份: PMT@LBA{back_pmt_lba} + header@LBA{mh['alt']}"
          f" → 写 `edl ws {back_pmt_lba} 33 gpt-back.bin`")
    print("OK")

if __name__ == "__main__":
    main()
