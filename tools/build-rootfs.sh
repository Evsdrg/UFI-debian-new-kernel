#!/usr/bin/env bash
# Thin wrapper: the canonical UFI103s device-image builder lives at the repo
# root. Env overrides (KERNEL_RELEASE, MODULE_TREE, RPMSG_MODULE_DIR,
# ROOTFS_PATH, MMDEBSTRAP_FORMAT, MIRROR) pass through.
set -euo pipefail
BASE="$(cd "$(dirname "$0")/.." && pwd)"
exec "$BASE/build-rootfs.sh"
