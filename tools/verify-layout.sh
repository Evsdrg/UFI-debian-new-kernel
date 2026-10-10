#!/usr/bin/env bash
set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
. "$BASE/tools/kver.sh"
ROOTFS="${ROOTFS_IMAGE:-$ROOTFS_BASE}"
MODULES="$MODULES_DIR/lib/modules/$KERNEL_RELEASE"
SRC="$KERNEL_SRC"

# 源码侧的板目录（DTS 所在），boards/<family>/<board> 或 boards/<board>。
board_dir() {
  if [ -d "$BASE/boards/ufi00x/$1" ]; then
    printf '%s\n' "$BASE/boards/ufi00x/$1"
  else
    printf '%s\n' "$BASE/boards/$1"
  fi
}
# 产物目录（boot 镜像与 build.json），统一在 artifacts/boot/<board>。
boot_dir() {
  printf '%s\n' "$ARTIFACTS_BOOT/$1"
}

printf '== shell ==\n'
# 对脚本做语法检查。注意 tools/flash.sh 已于 2026-09-14 删除（它是根
# flash.sh 的旧子集且引用了不存在的路径；权威版本在仓库根）。
# tools/build-gpu-variant.sh 已于 2026-10-11 删除（自我声明废弃，默认 DTS
# 已不存在；GPU 板型由 tools/build-board-set.sh 构建）。
# tools/build-boot-images.sh 已于 2026-10-11 删除（引用了已删除的 oc12.dts，
# 实测必然失败；各板出镜像用 tools/package-boards.py）。
# tools/wcn36xx-rate-sweep{,2}.sh 已于 2026-10-11 删除（依赖 7.2.9 内核里
# 不存在的 fixed_rate / ra_start_rate 模块参数，会静默跑出误导结果）。
bash -n "$BASE/build-rootfs.sh" "$BASE/flash.sh" \
        "$BASE/tools/build-rootfs.sh" \
        "$BASE/tools/build-kernel-variant.sh" \
        "$BASE/tools/verify-layout.sh" "$BASE/tools/ufi-console.sh" \
        "$BASE/tools/usb-gadget.sh" "$BASE/tools/net-native/usb-share.sh"
printf 'scripts=OK\n'

printf '\n== source ==\n'
test -f "$SRC/Makefile"
test -f "$BASE/source/dts/common/msm8916-handsome-openstick-common.dtsi"
for board in ufi103s-ufi003 ufi001b ufi001c sp970 uz801; do
  case "$board" in
    ufi103s-ufi003) f=msm8916-handsome-openstick-ufi103s.dts ;;
    ufi001b) f=msm8916-handsome-openstick-ufi001b.dts ;;
    ufi001c) f=msm8916-handsome-openstick-ufi001c.dts ;;
    sp970) f=msm8916-handsome-openstick-sp970.dts ;;
    uz801) f=msm8916-handsome-openstick-uz801.dts ;;
  esac
  test -f "$(board_dir "$board")/dts/$f"
  printf '%s=source-present\n' "$board"
done

printf '\n== common modules ==\n'
for f in modules.dep modules.alias; do test -f "$MODULES/$f"; done
for f in \
  kernel/drivers/net/wwan/wwan.ko \
  kernel/drivers/net/wwan/rpmsg_wwan_ctrl.ko \
  kernel/drivers/net/wwan/qcom_bam_dmux.ko \
  kernel/drivers/soc/qcom/rmtfs_mem.ko \
  kernel/drivers/remoteproc/qcom_q6v5_mss.ko \
  kernel/drivers/remoteproc/qcom_wcnss_pil.ko \
  kernel/net/qrtr/qrtr-smd.ko \
  kernel/drivers/block/zram/zram.ko; do
  test -f "$MODULES/kernel/$f" 2>/dev/null || test -f "$MODULES/$f"
done
printf 'modules=OK\n'

printf '\n== USB sharing delivery ==\n'
python3 "$BASE/tools/verify-usb-sharing.py" "$ROOTFS"

printf '\n== rootfs ==\n'
test -f "$ROOTFS"
e2fsck -fn "$ROOTFS" >/tmp/ufi-layout-e2fsck.log 2>&1
printf 'rootfs=%s\n' "$ROOTFS"
sha256sum "$ROOTFS"
for path in \
  /etc/chrony/chrony.conf \
  /etc/apt/sources.list \
  /usr/sbin/chronyd \
  /etc/localtime \
  /etc/timezone \
  /etc/systemd/system/multi-user.target.wants/chrony.service \
  /etc/systemd/system/rmtfs.service.d/ufi103s.conf \
  /usr/lib/modules/${KERNEL_RELEASE}/kernel/drivers/soc/qcom/rmtfs_mem.ko; do
  debugfs -R "stat $path" "$ROOTFS" >/dev/null 2>&1 || true
  debugfs -R "stat $path" "$ROOTFS" 2>/dev/null | grep -q '^Inode:' || { printf 'rootfs:%s=MISSING\n' "$path" >&2; exit 1; }
  printf 'rootfs:%s=present\n' "$path"
done
debugfs -R 'stat /lib/systemd/system/systemd-timesyncd.service' "$ROOTFS" 2>/dev/null | grep -q '^Inode:' && { printf 'ERROR: systemd-timesyncd present\n' >&2; exit 1; }
printf 'systemd-timesyncd=absent\n'

# 网络栈现在是 NetworkManager（早期用 networkd + wpa_supplicant，已切换）。
# 这里断言 NM 在、且 networkd / wpa_supplicant@ 的启用软链不在（避免两者抢网卡）。
for path in /usr/sbin/NetworkManager /usr/bin/nmcli /usr/bin/nmtui \
            /var/lib/dpkg/info/network-manager.list \
            /usr/share/locale/zh_CN/LC_MESSAGES/NetworkManager.mo \
            /etc/systemd/system/multi-user.target.wants/NetworkManager.service \
            /etc/NetworkManager/NetworkManager.conf; do
  debugfs -R "stat $path" "$ROOTFS" 2>/dev/null | grep -q '^Inode:' || { printf 'rootfs:%s=MISSING\n' "$path" >&2; exit 1; }
  printf 'rootfs:%s=present\n' "$path"
done
printf 'NetworkManager=present\n'
for path in /etc/systemd/system/multi-user.target.wants/systemd-networkd.service \
            /etc/systemd/system/multi-user.target.wants/wpa_supplicant@wlan0.service \
            /etc/systemd/network/20-wlan0.network \
            /etc/wpa_supplicant/wpa_supplicant-wlan0.conf; do
  if debugfs -R "stat $path" "$ROOTFS" 2>/dev/null | grep -q '^Inode:'; then
    printf 'ERROR: legacy networkd/wpa_supplicant artifact still present: %s\n' "$path" >&2
    exit 1
  fi
done
printf 'networkd_wpa_supplicant=removed\n'
# NM 的 Wi-Fi 连接由 keyfile 承载（预置账号时才存在，故只做格式校验不做存在性断言）
printf 'nm_backend=keyfile\n'

# 中文化：locale 必须真正生成，只写 locale.gen 是不够的（apt variant 不跑
# locale-gen，`locale -a` 里没有 zh_CN 时中文会回退成 C）。
# Debian 13 把 /etc/default/locale 做成了指向 /etc/locale.conf 的符号链接
# （update-locale 写的是后者），所以这里两个路径都要看，不能只读链接。
_loc="$(debugfs -R 'cat /etc/locale.conf' "$ROOTFS" 2>/dev/null || true)"
[ -n "$_loc" ] || _loc="$(debugfs -R 'cat /etc/default/locale' "$ROOTFS" 2>/dev/null || true)"
case "$_loc" in
  *LANG=zh_CN.UTF-8*) printf 'locale_default=zh_CN.UTF-8\n' ;;
  *) printf 'ERROR: default locale does not select zh_CN.UTF-8 (looked at /etc/locale.conf and /etc/default/locale)\n' >&2; exit 1 ;;
esac
# 已生成的 locale 存档（/usr/lib/locale/locale-archive 或 zh_CN 目录）
if debugfs -R 'stat /usr/lib/locale/locale-archive' "$ROOTFS" 2>/dev/null | grep -q '^Inode:'; then
  printf 'locale_generated=locale-archive\n'
elif debugfs -R 'stat /usr/lib/locale/zh_CN.utf8' "$ROOTFS" 2>/dev/null | grep -q '^Inode:'; then
  printf 'locale_generated=zh_CN.utf8-dir\n'
else
  printf 'ERROR: zh_CN locale was not generated (only locale.gen was edited)\n' >&2
  exit 1
fi

# fstab 必须带 x-systemd.growfs：镜像只有 ~1G 而分区 3.4G，不自动拉伸的话
# 刷完只剩一百多 MB 可用（实测过）。
_fstab="$(debugfs -R 'cat /etc/fstab' "$ROOTFS" 2>/dev/null || true)"
case "$_fstab" in
  *x-systemd.growfs*) printf 'rootfs_growfs=auto\n' ;;
  *) printf 'ERROR: /etc/fstab lacks x-systemd.growfs on / (rootfs will not auto-grow)\n' >&2; exit 1 ;;
esac

printf '\n== LED and test assets ==\n'
for path in /usr/local/sbin/ufi-led-state.sh /etc/systemd/system/ufi-led-state.service /etc/systemd/system/multi-user.target.wants/ufi-led-state.service /etc/default/ufi-led-state /root/venus-test.sh; do
  debugfs -R "stat $path" "$ROOTFS" 2>/dev/null | grep -q '^Inode:' || { printf 'rootfs:%s=MISSING\n' "$path" >&2; exit 1; }
  printf 'rootfs:%s=present\n' "$path"
done
printf 'led_policy=three-colour-red-load-gear\n'
# 脚本现在是机型中立的：按颜色发现灯、自动找网口，不再硬编码某一机型的路径。
grep -q 'find_led()' "$BASE/tools/ufi-led-state.sh"
grep -q 'find_wifi_iface()' "$BASE/tools/ufi-led-state.sh"
grep -q 'LED_BLUE_HINT=${LED_BLUE_HINT:-blue:wlan}' "$BASE/tools/ufi-led-state.sh"
grep -q 'RED_ON_PCT=${RED_ON_PCT:-70}' "$BASE/tools/ufi-led-state.sh"
grep -q 'on) led_solid "\$RED"' "$BASE/tools/ufi-led-state.sh"
# 旧的硬编码路径必须已经消失，否则说明回退到了非通用版本
if grep -qE '^(RED|BLUE|GREEN)=/sys/class/leds/' "$BASE/tools/ufi-led-state.sh"; then
  printf 'ERROR: ufi-led-state.sh still hardcodes an LED sysfs path\n' >&2
  exit 1
fi
grep -q 'ExecStart=/usr/local/sbin/ufi-led-state.sh monitor' "$BASE/tools/ufi-led-state.service"
printf 'led_discovery=auto\n'

printf '\n== board boot status ==\n'
for board in ufi103s-ufi003 ufi001b ufi001c sp970 uz801; do
  if [[ -f "$(boot_dir "$board")/boot-board-baseline-$KERNEL_VERSION.img" ]]; then
    printf '%s=board-specific-boot\n' "$board"
  else
    printf '%s=no-%s-boot-image; do-not-flash\n' "$board" "$KERNEL_VERSION"
  fi
done

printf '\n== venus codec variant ==\n'
# 这一段校验 max 档的三件套配套：boot（GPU 内核，含 venus）+ rootfs
# （含 baseline 与 venus-4g-gpu 两棵模块树、venus 固件、ffmpeg）+ venus 模块。
# boot 镜像名随板型构建走：boot-board-<板型>-<内核版本>.img。
_venus_boot_dir="$(boot_dir ufi103s-ufi003)"
VENUS_BOOT="$_venus_boot_dir/boot-board-venus-4g-gpu-$KERNEL_VERSION.img"
VENUS_ROOTFS="$ROOTFS_VENUS"
VENUS_REL="${KERNEL_VERSION}${KERNEL_LOCALVERSION}-venus-4g-gpu-dirty"
VENUS_MODS="$MODULES_DIR_GPU/lib/modules/$VENUS_REL"
test -f "$VENUS_BOOT"
test -f "$VENUS_ROOTFS"
test -f "$BASE/source/configs/ufi103s-venus.config"

# 配置片段静态检查：片段本身必须打开 venus 与 media platform 支持。
grep -q '^CONFIG_VIDEO_QCOM_VENUS=m' "$BASE/source/configs/ufi103s-venus.config"
grep -q '^CONFIG_MEDIA_PLATFORM_SUPPORT=y' "$BASE/source/configs/ufi103s-venus.config"

# 动态检查：产物里必须真的有这三个模块。这条同时兜住了"合并失败"的情形——
# 若基线把 MEDIA_SUPPORT 关掉、片段没顶回来，就不会有这些 .ko。
for m in venus-core venus-dec venus-enc; do
  test -f "$VENUS_MODS/kernel/drivers/media/platform/qcom/venus/$m.ko"
  printf 'module:%s=present\n' "$m"
done

# 构建树还在时（未清理中间产物）做一次解析后配置的强校验；
# 构建树是可再生中间态，清掉后降级到片段检查（上面已断言片段内容）。
VENUS_BUILD="$BASE/build/variant-$KERNEL_VERSION-board-venus-4g-gpu"
if [ -f "$VENUS_BUILD/.config" ]; then
  grep -q 'CONFIG_VIDEO_QCOM_VENUS=m' "$VENUS_BUILD/.config"
  grep -q 'CONFIG_MEDIA_PLATFORM_SUPPORT=y' "$VENUS_BUILD/.config"
  printf 'venus_config=OK (resolved)\n'
else
  printf 'venus_config=OK (fragment; build tree cleaned)\n'
fi
python3 - "$VENUS_BOOT" <<'PY'
import struct, sys
data = open(sys.argv[1], 'rb').read()
assert data[:8] == b'ANDROID!', 'boot magic'
page = struct.unpack_from('<I', data, 36)[0]
off = data.find(bytes.fromhex('d00dfeed'), page)
assert off > 0, 'appended DTB not found'
size = struct.unpack_from('>I', data, off + 4)[0]
assert off + size <= len(data) and len(data) - (off + size) < page
print(f'venus_boot_layout=OK dtb_offset={off}')
PY
for path in \
  /usr/lib/modules/${VENUS_REL}/kernel/drivers/media/platform/qcom/venus/venus-core.ko \
  /usr/lib/modules/${KERNEL_RELEASE}/kernel/drivers/net/wwan/rpmsg_wwan_ctrl.ko \
  /usr/bin/ffmpeg \
  /usr/bin/v4l2-ctl \
  /lib/firmware/qcom/venus-1.8/venus.mbn \
  /lib/firmware/qcom/venus-1.8/venus.b02; do
  debugfs -R "stat $path" "$VENUS_ROOTFS" 2>/dev/null | grep -q '^Inode:' \
    || { printf 'venus_rootfs:%s=MISSING\n' "$path" >&2; exit 1; }
  printf 'venus_rootfs:%s=present\n' "$path"
done
e2fsck -fn "$VENUS_ROOTFS" >/dev/null 2>&1
printf 'venus_rootfs=%s\n' "$VENUS_ROOTFS"
printf 'venus_rootfs_e2fsck=OK\n'

printf '\n== desktop / xrdp / GPU ==\n'
# 桌面是默认组件（ROOTFS_DESKTOP=1）；若镜像是纯服务端构建，这里会提示缺失。
for path in /usr/sbin/xrdp /usr/sbin/xrdp-sesman \
            /usr/lib/xorg/modules/drivers/xrdpdev_drv.so \
            /usr/bin/i3 /usr/bin/xterm /usr/bin/i3status \
            /etc/X11/Xwrapper.config \
            /root/.xsession /root/.config/i3/config; do
  if debugfs -R "stat $path" "$ROOTFS" 2>/dev/null | grep -q '^Inode:'; then
    printf 'rootfs:%s=present\n' "$path"
  else
    printf 'rootfs:%s=absent (desktop image not built with ROOTFS_DESKTOP=1?)\n' "$path"
  fi
done
# xrdp 以服务身份启动 Xorg，Xwrapper 必须放行非 console 用户
_wrap="$(debugfs -R 'cat /etc/X11/Xwrapper.config' "$ROOTFS" 2>/dev/null || true)"
case "$_wrap" in
  *allowed_users=anybody*) printf 'xwrapper=anybody\n' ;;
  *allowed_users=console*) printf 'ERROR: Xwrapper.config still limits Xorg to console users; xrdp sessions will fail\n' >&2; exit 1 ;;
  *) printf 'xwrapper=missing-or-empty (skipped)\n' ;;
esac
# GPU：modprobe 参数与开机加载列表
grep -q '^options msm separate_gpu_kms=1' "$BASE/tools/msm-gpu-render-only.conf" \
  || { printf 'ERROR: msm-gpu-render-only.conf lacks separate_gpu_kms=1\n' >&2; exit 1; }
printf 'gpu_render_only_param=ok\n'
# GPU 内核片段必须显式关掉显示后端，否则 DRM_MSM_KMS 会被 select 成 y
for opt in CONFIG_DRM_MSM_MDP4 CONFIG_DRM_MSM_MDP5 CONFIG_DRM_MSM_DPU \
           CONFIG_DRM_MSM_DSI CONFIG_DRM_MSM_HDMI; do
  grep -q "^# $opt is not set" "$BASE/source/configs/ufi103s-gpu.config" \
    || { printf 'ERROR: gpu fragment does not disable %s (DRM_MSM_KMS would be force-enabled)\n' "$opt" >&2; exit 1; }
done
grep -q '^CONFIG_DRM_MSM=m' "$BASE/source/configs/ufi103s-gpu.config" \
  || { printf 'ERROR: gpu fragment lacks CONFIG_DRM_MSM=m\n' >&2; exit 1; }
printf 'gpu_config_fragment=ok\n'
# GPU boot 产物（若已构建）。镜像名与 tools/build-board-set.sh 一致。
if [ -f "$(boot_dir ufi103s-ufi003)/boot-board-venus-4g-gpu-$KERNEL_VERSION.img" ]; then
  printf 'gpu_boot=present\n'
else
  printf 'gpu_boot=absent (run tools/build-board-set.sh venus-4g-gpu to build it)\n'
fi

printf '\n== venus 32-alignment guard ==\n'
# Venus 固件要求宽高都是 32 的倍数；不对齐会让固件报 VBIF 错误并让进程崩溃。
# 我们的 transcode 脚本必须带这个校验，否则以后有人改分辨率就会踩坑。
grep -q 'ENC_W % 32' "$BASE/tools/venus-transcode.sh" \
  || { printf 'ERROR: venus-transcode.sh lacks the 32-alignment guard\n' >&2; exit 1; }
grep -q 'ENC_H % 32' "$BASE/tools/venus-transcode.sh" \
  || { printf 'ERROR: venus-transcode.sh lacks the 32-alignment guard\n' >&2; exit 1; }
# 默认编码尺寸本身必须对齐
grep -q 'ENC_H=${ENC_H:-736}' "$BASE/tools/venus-transcode.sh" \
  || { printf 'ERROR: default ENC_H is not 736 (32-aligned)\n' >&2; exit 1; }
printf 'venus_alignment_guard=ok (default 1280x736)\n'
