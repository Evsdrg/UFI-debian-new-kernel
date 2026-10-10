#!/bin/sh
# 在 GPU 合成的 sway 桌面上显示实时时钟（用于证明推流是实时的）
while true; do
	clear
	printf '\n'
	printf '   OpenStick UFI103s  /  MSM8916  /  Debian 13 arm64\n'
	printf '\n'
	printf '   host   : %s\n' "$(hostname)"
	printf '   kernel : %s\n' "$(uname -r)"
	printf '   gpu    : %s\n' "$(cat /sys/class/drm/card0/device/gpu_busy_percent 2>/dev/null >/dev/null; ls /sys/class/drm/renderD128 >/dev/null 2>&1 && echo Adreno-306 || echo none)"
	printf '   codec  : venus V4L2 m2m  h264_v4l2m2m\n'
	printf '\n'
	printf '   %s\n' "$(cat /proc/loadavg)"
	printf '\n'
	printf '   >>>  %s   <<<\n' "$(date '+%Y-%m-%d %H:%M:%S')"
	printf '\n'
	printf '   push ->  udp://%s:%s  (MPEG-TS/H.264)\n' \
		"${TARGET:-192.0.2.10}" "${PORT:-5000}"
	printf '\n'
	printf '   PID %s   uptime %s\n' "$$" "$(cut -d. -f1 /proc/uptime)s"
	sleep 1
done
