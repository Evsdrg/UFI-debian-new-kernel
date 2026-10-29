#!/usr/bin/env python3
"""Package a board DTS + variant Image.gz into a legacy Android boot image.

Reuses the already-validated UFI103s boot layout:
  Image.gz + appended DTB, page 2048, base 0x80000000, header v0.

Usage:
  tools/package-boot-variant.py <variant> <dts-name> <image-gz> <modules-release> <out-dir> [board-dir]

board-dir 缺省为 boards/ufi00x/ufi103s-ufi003（兼容既有调用）；
其它板型（如 boards/thwc-mf601sl）作为第 6 个参数传入。
"""
import hashlib
import json
import os
import pathlib
import struct
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import kver  # noqa: E402  (版本单一事实来源，见 tools/kver.py)

BASE = kver.BASE
SRC = kver.KERNEL_SRC
MKBOOTIMG = BASE / "mkbootimg/mkbootimg"
# 中间产物（.dtb 与拼接前的 kernel-dtb）留在 build/ 下，属可再生中间态。
# 目录名随板目录变化（build/boards/<board-basename>），避免不同板型互相覆盖。
BUILD_BOARDS = BASE / "build/boards"
# This board's DTS live under its board directory, not inside the kernel tree;
# see boards/README.md for the layout.
BOARD = BASE / "boards/ufi00x/ufi103s-ufi003"

# Legacy UFI103s layout, unchanged from the validated baseline images.
PAGE_SIZE = 2048
BASE_ADDR = "0x80000000"
KERNEL_OFFSET = "0x00080000"
RAMDISK_OFFSET = "0x02000000"
SECOND_OFFSET = "0x00f00000"
TAGS_OFFSET = "0x01e00000"
# root= 的写法有两种，用环境变量 BOOT_ROOT 选择（缺省保持 PARTUUID）：
#
#   PARTUUID=<guid>      取自 GPT。每台机器的分区 GUID 都不同，所以这个值只对
#                        作者这台机器成立——别人的机器刷进来会找不到根分区。
#                        保留为缺省是为了不动已经实机验证过、已发布的 UFI103s
#                        镜像（内核不可逐位复现，重编会换哈希）。
#   /dev/mmcblk0p14      设备节点，与 GPT 内容无关，同一型号 eMMC 枚举名固定。
#                        新板型（如 mf601sl）用这个，别人刷进去不必改 cmdline。
#                        前提是 p14 确实是 rootfs 分区：容量不一致时 fastboot
#                        写入就会失败，不会出现"刷进去了但起不来"的静默错配。
#
# 内核支持的形式见 source/linux-7.2.9/block/early-lookup.c（/dev/<disk><part>）。
DEFAULT_ROOT = "PARTUUID=a7ab80e8-e9d1-e8cd-f157-93f69b1d141e"
ROOT = os.environ.get("BOOT_ROOT") or DEFAULT_ROOT
CMDLINE = f"earlycon console=ttyMSM0,115200 root={ROOT} rw rootwait"


def compile_dtb(dts_path: pathlib.Path, out_dtb: pathlib.Path) -> None:
    includes = [
        BASE / "source/dts/common",
        dts_path.parent,
        SRC / "arch/arm64/boot/dts/qcom",
        SRC / "include",
    ]
    cpp_cmd = ["cpp", "-nostdinc", "-undef", "-D__DTS__", "-x", "assembler-with-cpp"]
    for inc in includes:
        cpp_cmd += ["-I", str(inc)]
    cpp_cmd.append(str(dts_path))
    pre = subprocess.check_output(cpp_cmd)
    subprocess.run(
        ["dtc", "-q", "-I", "dts", "-O", "dtb", "-o", str(out_dtb)],
        input=pre,
        check=True,
    )


def main() -> int:
    if len(sys.argv) not in (6, 7):
        print(__doc__)
        return 2
    variant, dts_name, image_gz, modules_release, out_dir = sys.argv[1:6]
    board_root = pathlib.Path(sys.argv[6]) if len(sys.argv) == 7 else BOARD

    image_path = pathlib.Path(image_gz)
    if not image_path.is_file():
        raise SystemExit(f"missing Image.gz: {image_path}")

    dts_path = board_root / "dts" / dts_name
    if not dts_path.is_file():
        raise SystemExit(f"missing DTS: {dts_path}")

    BOARD_DIR = BUILD_BOARDS / board_root.name
    BOARD_DIR.mkdir(parents=True, exist_ok=True)
    out = pathlib.Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)

    dtb = BOARD_DIR / f"{variant}.dtb"
    compile_dtb(dts_path, dtb)
    print(f"dtb={dtb} ({dtb.stat().st_size} bytes)")

    # DTB 布局（环境变量 BOOT_DTB_LAYOUT，默认 inline）：
    #   inline  = Image.gz+dtb 拼接体整体作为 kernel，header kernel_size 含 dtb。
    #             UFI103s 的新版 LK 在 kernel 区内扫描 magic，实测可用，保持不动。
    #   padded  = 面向老 LK（MF32）。LE.1.1 dev_tree.c find_dt_image_offset()
    #             在 kernel_buf + ROUNDUP(kernel_size, page) 找 DTB，即要求
    #             kernel_size 只含内核本体、DTB 挂在其后页对齐空档。2026-10-29
    #             由该板 aboot.bin 反汇编确认。
    dtb_layout = os.environ.get("BOOT_DTB_LAYOUT", "inline")
    kernel_dtb = out / f"kernel-{variant}-dtb"
    if dtb_layout == "padded":
        kernel_dtb.write_bytes(image_path.read_bytes())
    else:
        kernel_dtb.write_bytes(image_path.read_bytes() + dtb.read_bytes())

    ramdisk = out / "empty-ramdisk"
    ramdisk.write_bytes(b"")

    boot = out / f"boot-{variant}.img"
    subprocess.run(
        [
            str(MKBOOTIMG),
            "--kernel", str(kernel_dtb),
            "--ramdisk", str(ramdisk),
            "--base", BASE_ADDR,
            "--kernel_offset", KERNEL_OFFSET,
            "--ramdisk_offset", RAMDISK_OFFSET,
            "--second_offset", SECOND_OFFSET,
            "--tags_offset", TAGS_OFFSET,
            "--pagesize", str(PAGE_SIZE),
            "--header_version", "0",
            "--cmdline", CMDLINE,
            "--output", str(boot),
        ],
        check=True,
    )

    data = bytearray(boot.read_bytes())
    assert data[:8] == b"ANDROID!", "boot magic missing"
    kernel_size = struct.unpack_from("<I", data, 8)[0]
    page_size = struct.unpack_from("<I", data, 36)[0]
    payload_off = page_size
    if dtb_layout == "padded":
        # DTB 放到 kernel_size 页对齐之后的第一个位置（老 LK 的搜索点）。
        gz_len = image_path.stat().st_size
        assert kernel_size == gz_len, f"padded 布局 kernel_size 应恰为 Image.gz 长度: {kernel_size} != {gz_len}"
        dtb_offset = payload_off + ((gz_len + page_size - 1) // page_size) * page_size
        data = data[:dtb_offset]  # 裁掉 mkbootimg 对空 ramdisk 写的补零页
        data += dtb.read_bytes()
        boot.write_bytes(bytes(data))
    else:
        # inline：payload 起点 + len(Image.gz) 处就是拼接的 DTB。
        dtb_offset = payload_off + image_path.stat().st_size
    assert data[dtb_offset:dtb_offset + 4] == b"\xd0\x0d\xfe\xed", "appended DTB missing"
    dtb_total = struct.unpack_from(">I", data, dtb_offset + 4)[0]
    tail = len(data) - (dtb_offset + dtb_total)
    assert 0 <= tail < page_size, f"unexpected trailing bytes: {tail}"

    meta = {
        "variant": variant,
        "kernel_release": modules_release,
        "dts": dts_name,
        "cmdline": CMDLINE,
        "boot_image": boot.name,
        "boot_size": len(data),
        "kernel_size": kernel_size,
        "appended_dtb_offset": dtb_offset,
        "appended_dtb_size": dtb.stat().st_size,
        "dtb_layout": dtb_layout,
        "image_gz_sha256": hashlib.sha256(image_path.read_bytes()).hexdigest(),
        "dtb_sha256": hashlib.sha256(dtb.read_bytes()).hexdigest(),
        "boot_sha256": hashlib.sha256(data).hexdigest(),
        # 刷入状态由板 README 人工维护；这里只写“未刷”默认值。
        # 已刷入的镜像需在板 README 与验证报告中记录事实——打包脚本
        # 无法知道镜像是否被 fastboot flash 过，而每次重编都会重写本文件，
        # 所以不要指望这个字段保留历史。
        "flash_status": "not flashed",
    }
    (out / f"{variant}-build.json").write_text(json.dumps(meta, indent=2) + "\n")
    print(json.dumps(meta, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
