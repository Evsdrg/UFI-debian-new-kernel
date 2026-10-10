#!/usr/bin/env python3
import hashlib
import json
import pathlib
import subprocess
import sys
import tempfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import kver  # noqa: E402  (版本单一事实来源，见 tools/kver.py)

BASE = kver.BASE
K = kver.KERNEL_SRC
IMAGE = kver.IMAGE_GZ
# board -> (family directory, DTS basename).  The family exists because several
# boards share a pin layout; see boards/README.md.  sp970 and uz801 are single
# member families, so their own directory is the family.
BOARDS = {
    'ufi103s-ufi003': ('ufi00x', 'ufi103s'),
    'ufi001b':        ('ufi00x', 'ufi001b'),
    'ufi001c':        ('ufi00x', 'ufi001c'),
    'sp970':          ('sp970',  'sp970'),
    'uz801':          ('uz801',  'uz801'),
}

def board_dir(board):
    """boards/<family>/<board> for grouped families, boards/<board> otherwise."""
    family = BOARDS[board][0]
    nested = BASE / 'boards' / family / board
    return nested if nested.is_dir() else BASE / 'boards' / family

def run(*args):
    subprocess.run([str(a) for a in args], check=True)

for board, (family, name) in BOARDS.items():
    bdir = board_dir(board)
    # 产物统一落到 artifacts/boot/<board>（见 artifacts/README.md）。
    out = kver.ARTIFACTS_BOOT / board
    build = BASE / 'build/boards' / board
    build.mkdir(parents=True, exist_ok=True)
    source = bdir / 'dts' / f'msm8916-handsome-openstick-{name}.dts'
    pre = subprocess.check_output(['cpp', '-nostdinc', '-undef', '-D__DTS__', '-x', 'assembler-with-cpp', '-I', str(BASE / 'source/dts/common'), '-I', str(K / 'arch/arm64/boot/dts/qcom'), '-I', str(K / 'include'), str(source)])
    subprocess.run(['dtc', '-q', '-I', 'dts', '-O', 'dtb', '-o', str(build / 'board.dtb')], input=pre, check=True)
    opp_path = '/opp-table-cpu'
    nodes = subprocess.check_output(['fdtget', '-l', str(build / 'board.dtb'), opp_path]).decode().split()
    for node in nodes:
        vals = subprocess.check_output(['fdtget', '-t', 'u', str(build / 'board.dtb'), opp_path + '/' + node, 'opp-hz']).decode().split()
        hz = (int(vals[0]) << 32) | int(vals[1])
        if hz not in (200000000, 400000000, 800000000, 998400000):
            run('fdtput', '-r', build / 'board.dtb', opp_path + '/' + node)
    (out / 'board.dtb').write_bytes((build / 'board.dtb').read_bytes())
    payload = IMAGE.read_bytes() + (out / 'board.dtb').read_bytes()
    (build / 'kernel-dtb').write_bytes(payload)
    (build / 'empty-ramdisk').write_bytes(b'')
    old = out / 'boot-baseline.img'
    cmdline = 'earlycon console=ttyMSM0,115200 root=PARTLABEL=rootfs rw rootwait'
    run(BASE / 'mkbootimg/mkbootimg', '--kernel', build / 'kernel-dtb', '--ramdisk', build / 'empty-ramdisk', '--base', '0x80000000', '--kernel_offset', '0x00080000', '--ramdisk_offset', '0x02000000', '--second_offset', '0x00f00000', '--tags_offset', '0x01e00000', '--pagesize', '2048', '--header_version', '0', '--cmdline', cmdline, '--output', old)
    metadata = {'board': board, 'kernel_release': kver.KERNEL_RELEASE, 'cmdline': cmdline, 'status': 'offline-validated; not flashed', 'firmware': 'board-specific firmware and calibration required', 'sha256': hashlib.sha256(old.read_bytes()).hexdigest()}
    (out / 'build.json').write_text(json.dumps(metadata, indent=2) + '\n')
    print(board, metadata['sha256'])
