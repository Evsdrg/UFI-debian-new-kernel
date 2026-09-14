#!/usr/bin/env python3
"""Package a board DTS + variant Image.gz into a legacy Android boot image.

Reuses the already-validated UFI103s boot layout:
  Image.gz + appended DTB, page 2048, base 0x80000000, header v0.

Usage:
  tools/package-boot-variant.py <variant> <dts-name> <image-gz> <modules-release> <out-dir>
"""
import hashlib
import json
import pathlib
import struct
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import kver  # noqa: E402  (版本单一事实来源，见 tools/kver.py)

BASE = kver.BASE
SRC = kver.KERNEL_SRC
MKBOOTIMG = BASE / "mkbootimg/mkbootimg"
BOARD_DIR = BASE / "build/boards/ufi103s-ufi003"
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
CMDLINE = (
    "earlycon console=ttyMSM0,115200 "
    "root=PARTUUID=a7ab80e8-e9d1-e8cd-f157-93f69b1d141e rw rootwait"
)


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
    if len(sys.argv) != 6:
        print(__doc__)
        return 2
    variant, dts_name, image_gz, modules_release, out_dir = sys.argv[1:6]

    image_path = pathlib.Path(image_gz)
    if not image_path.is_file():
        raise SystemExit(f"missing Image.gz: {image_path}")

    dts_path = BOARD / "dts" / dts_name
    if not dts_path.is_file():
        raise SystemExit(f"missing DTS: {dts_path}")

    BOARD_DIR.mkdir(parents=True, exist_ok=True)
    out = pathlib.Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)

    dtb = BOARD_DIR / f"{variant}.dtb"
    compile_dtb(dts_path, dtb)
    print(f"dtb={dtb} ({dtb.stat().st_size} bytes)")

    kernel_dtb = out / f"kernel-{variant}-dtb"
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

    data = boot.read_bytes()
    assert data[:8] == b"ANDROID!", "boot magic missing"
    kernel_size = struct.unpack_from("<I", data, 8)[0]
    page_size = struct.unpack_from("<I", data, 36)[0]
    # The kernel payload starts at the second page; the appended DTB sits at
    # the very end of it, i.e. (kernel payload offset) + len(Image.gz).
    payload_off = page_size
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
        "image_gz_sha256": hashlib.sha256(image_path.read_bytes()).hexdigest(),
        "dtb_sha256": hashlib.sha256(dtb.read_bytes()).hexdigest(),
        "boot_sha256": hashlib.sha256(data).hexdigest(),
        "flash_status": "not flashed",
    }
    (out / f"{variant}-build.json").write_text(json.dumps(meta, indent=2) + "\n")
    print(json.dumps(meta, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
