"""内核版本的单一事实来源（Python 侧）。

与 tools/kver.sh 读同一个文件 source/kernel-version.env，保证 shell 与
Python 两条脚本链派生出完全一致的路径。

版本文件里写成 ${VAR:-默认值} 以便用环境变量覆盖；这里做同样的解析，
使 `KERNEL_VERSION=6.18.49 python3 ...` 与 shell 侧行为一致。
"""

import os
import pathlib
import re

BASE = pathlib.Path(__file__).resolve().parent.parent

# ${NAME:-默认值} 或 ${NAME-默认值}
_SHELL_DEFAULT = re.compile(r"^\$\{([A-Za-z_][A-Za-z0-9_]*):?-?(.*)\}$")


def _resolve(key: str, raw: str) -> str:
    m = _SHELL_DEFAULT.match(raw)
    if m:
        name, default = m.group(1), m.group(2)
        return os.environ.get(name, default)
    return os.environ.get(key, raw)


def _load_env() -> dict:
    env = BASE / "source/kernel-version.env"
    if not env.is_file():
        raise SystemExit(f"kver.py: 找不到 {env}（内核版本单一事实来源）")
    vals = {}
    for line in env.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, val = line.split("=", 1)
        vals[key.strip()] = _resolve(key.strip(), val.strip())
    return vals


_V = _load_env()

KERNEL_VERSION = _V["KERNEL_VERSION"]
KERNEL_LOCALVERSION = _V.get("KERNEL_LOCALVERSION", "-ufix0x")

KERNEL_SRC = BASE / f"source/linux-{KERNEL_VERSION}"
KERNEL_BASE_CFG = BASE / f"source/configs/common-{KERNEL_VERSION}-os.config"

# 见 tools/kver.sh 里对 -dirty 的说明。
KERNEL_RELEASE = f"{KERNEL_VERSION}{KERNEL_LOCALVERSION}-dirty"
KERNEL_RELEASE_VENUS = f"{KERNEL_VERSION}{KERNEL_LOCALVERSION}-venus-dirty"

KERNEL_BUILD_DIR = BASE / f"out/build-ufi103s-{KERNEL_VERSION}-os"
IMAGE_GZ = KERNEL_BUILD_DIR / "arch/arm64/boot/Image.gz"

MODULES_DIR = BASE / f"shared/modules/{KERNEL_RELEASE}"
MODULES_DIR_VENUS = BASE / f"shared/modules/{KERNEL_VERSION}{KERNEL_LOCALVERSION}-venus"
MODULES_DIR_GPU = BASE / f"shared/modules/{KERNEL_VERSION}{KERNEL_LOCALVERSION}-gpu"

ROOTFS_BASE = BASE / f"shared/rootfs/debian13-arm64-ufi103s-{KERNEL_VERSION}.ext4"
ROOTFS_VENUS = BASE / f"shared/rootfs/debian13-arm64-ufi103s-{KERNEL_VERSION}-venus.ext4"
