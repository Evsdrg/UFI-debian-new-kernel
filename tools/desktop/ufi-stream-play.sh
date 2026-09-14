#!/bin/bash
# 在桌面窗口里播放 OpenStick 推来的 MPEG-TS/H.264 流。
#
# 用法:
#   ufi-stream-play.sh                  监听 udp://0.0.0.0:5000 并全屏播放
#   PORT=5001 ./ufi-stream-play.sh
#   WINDOWED=1 ./ufi-stream-play.sh     不开全屏
#   OUT=/tmp/s.ts ./ufi-stream-play.sh  只录制不播放
#
# 会自动探测本机是 Wayland(Plasma/Sway) 还是 X11，并设好 xauth，
# 这样从 ssh 里调用也能把窗口开在真实桌面上。
set -u

PORT=${PORT:-5000}
WINDOWED=${WINDOWED:-0}
OUT=${OUT:-}
URL="udp://@:${PORT}"

# --- 探测图形会话 ---
UID_=$(id -u)
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$UID_}
if [ -z "${WAYLAND_DISPLAY:-}" ]; then
	for s in "$XDG_RUNTIME_DIR"/wayland-*; do
		case "$s" in *.lock) continue ;; esac
		[ -S "$s" ] && { WAYLAND_DISPLAY=$(basename "$s"); export WAYLAND_DISPLAY; break; }
	done
fi
if [ -z "${DISPLAY:-}" ]; then
	for a in /run/user/"$UID_"/xauth_* "$HOME"/.Xauthority; do
		[ -f "$a" ] && { XAUTHORITY=$a; export XAUTHORITY; break; }
	done
	# Xwayland 常是 :0/:1；挑一个 socket 存在的
	for d in /tmp/.X11-unix/X*; do
		[ -S "$d" ] && { DISPLAY=:$(basename "$d" | tr -d X); export DISPLAY; break; }
	done
fi
echo "会话: WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-<无>} DISPLAY=${DISPLAY:-<无>} XAUTHORITY=${XAUTHORITY:-<无>}"
echo "输入: $URL"

if [ -n "$OUT" ]; then
	echo "只录制 -> $OUT"
	exec ffmpeg -hide_banner -loglevel info \
		-i "$URL" -c copy -f mpegts "$OUT"
fi

command -v mpv >/dev/null || { echo "缺少 mpv" >&2; exit 1; }

MODE=(--fs --no-border)
[ "$WINDOWED" = 1 ] && MODE=(--geometry=1280x736+40+30)

exec mpv --title="OpenStick GPU Stream" "${MODE[@]}" \
	--profile=low-latency \
	--cache=no --demuxer-max-bytes=16MiB \
	--demuxer-lavf-format=mpegts \
	--force-window=yes --hwdec=no --no-osc \
	"$URL"
