#!/bin/bash
# GPU 合成桌面 -> venus 硬编 -> MPEG-TS/UDP
#   sway(headless + gles2, Adreno 306) 合成
#   wf-recorder 抓帧 -> rawvideo BGRA -> FIFO
#   ffmpeg 转 NV12 -> h264_v4l2m2m(venus) -> mpegts -> udp
#
# 用法:
#   ufi-stream-push.sh              启动（默认推到 192.0.2.13:5000）
#   ufi-stream-push.sh stop         停掉整条链
#   TARGET=192.0.2.12 ./ufi-stream-push.sh
#
# 关键点 1：venus 驱动只注册了 V4L2_CID_MPEG_VIDEO_H264_I_PERIOD，
# 而 ffmpeg 的 v4l2m2m 封装只设 GOP_SIZE（驱动忽略它），所以 -g 形同虚设 ——
# 实测 180 帧只有 1 个 IDR。必须用 -force_key_frames，它会按 pict_type 触发
# V4L2_CID_MPEG_VIDEO_FORCE_KEY_FRAME，才能周期出 IDR；否则中途加入的播放器
# 永远拿不到 SPS/PPS，只能报 "non-existing PPS 0 referenced"。
#
# 关键点 2：sv/ 下内容默认放一个实时时钟终端，便于肉眼确认推流是实时的。
#
# 关键点 3：pgrep -x 匹配超过 15 字符的进程名会零匹配（内核 comm 截断），
# 所以收尾一律用完整路径/pidfile，不用进程名。
set -u

R=${R:-/tmp/stream}
TARGET=${TARGET:-192.0.2.13}
PORT=${PORT:-5000}
W=${W:-1280}
H=${H:-736}
FPS=${FPS:-30}
BITRATE=${BITRATE:-4M}
KEYINT=${KEYINT:-1}          # 每隔几秒强制一个 IDR
CONTENT=${CONTENT:-clock}    # clock | egl | none

PIDFILE=$R/pids

# 单板只有一个 venus 编码器和 32MB CMA，所以绝不能让两条链同时活着：
# 第二条链会拿不到编码器/CMA，帧率掉到个位数，还很难查。
# 这里不能按名字 kill：pgrep -x 匹配超过 15 字符的进程名会零匹配
# （内核 comm 截断），sway 又会和别的会话重名。改为扫 /proc 拿到完整
# cmdline，用「本板绝对路径」这种只有我们自己才会用的特征来定位，
# 顺便避开把当前 ssh 命令行一起杀掉的老坑。
sweep_stragglers() {
	local p cmd
	for d in /proc/[0-9]*; do
		p=${d#/proc/}
		[ "$p" = "$$" ] && continue
		[ -r "$d/cmdline" ] || continue
		cmd=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null) || continue
		if [ -z "$cmd" ]; then continue; fi
		case "$cmd" in
		*"/tmp/stream/p.yuv"*) kill -9 "$p" 2>/dev/null; continue ;;
		*"sway -c $R/sway.conf"*) kill -9 "$p" 2>/dev/null; continue ;;
		esac
		# 本链的 ffmpeg 唯一特征：往本端口发的 mpegts
		if [ "${cmd#*udp://}" != "$cmd" ] && [ "${cmd#*:${PORT}?pkt_size=1316}" != "$cmd" ]; then
			kill -9 "$p" 2>/dev/null
		fi
	done 2>/dev/null
}

stop_chain() {
	if [ -f "$PIDFILE" ]; then
		while read -r p; do
			[ -n "$p" ] && kill -9 "$p" 2>/dev/null
		done < "$PIDFILE"
	fi
	sweep_stragglers
	# 等内核真正回收设备：venus/CMA 是异步释放的，立即重启会失败
	for _ in $(seq 1 30); do
		alive=0
		for d in /proc/[0-9]*; do
			[ -r "$d/cmdline" ] || continue
			cmd=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null) || continue
			case "$cmd" in
			*"/tmp/stream/p.yuv"*) alive=1 ;;
			esac
		done 2>/dev/null
		[ "$alive" = 0 ] && break
		sleep 0.2
	done
	sleep 1
	rm -f "$PIDFILE" "$R/p.yuv"
	echo "已停止"
}

[ "${1:-}" = stop ] && { stop_chain; exit 0; }

stop_chain
rm -rf "$R"
mkdir -p "$R"

export XDG_RUNTIME_DIR=/tmp/xdg-sway
rm -rf "$XDG_RUNTIME_DIR"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

cat > "$R/sway.conf" <<EOF
output HEADLESS-1 resolution ${W}x${H}
EOF

WLR_BACKENDS=headless WLR_RENDERER=gles2 WLR_HEADLESS_OUTPUTS=1 \
	sway -c "$R/sway.conf" -d > "$R/sway.log" 2>&1 &
SWAY_PID=$!

for _ in $(seq 1 60); do
	[ -S "$XDG_RUNTIME_DIR/wayland-1" ] && break
	sleep 0.2
done
export WAYLAND_DISPLAY=wayland-1

if ! [ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]; then
	echo "FATAL: sway 未起来" >&2
	tail -20 "$R/sway.log" >&2
	exit 1
fi

swaymsg -t get_outputs 2>/dev/null | grep -E '"name"|"width"|"height"' | head -6

if grep -qi 'FD3' "$R/sway.log"; then
	echo "GPU: Adreno (freedreno) 已启用"
else
	echo "WARN: sway 日志里没看到 freedreno（会退回软件渲染），见 $R/sway.log"
fi

# 桌面内容：默认放一个实时时钟终端，让"画面在动"这件事一眼可辨
case "$CONTENT" in
clock)
	CLOCK=${CLOCK:-/usr/local/bin/ufi-stream-clock.sh}
	[ -x "$CLOCK" ] || CLOCK=$(dirname "$0")/ufi-stream-clock.sh
	# 时钟窗口里要显示真实目标，所以把 TARGET/PORT 传进去
	setsid env TARGET="$TARGET" PORT="$PORT" \
		weston-terminal --shell="$CLOCK" > "$R/wterm.log" 2>&1 &
	CONTENT_PID=$!
	;;
egl)
	weston-simple-egl > "$R/egl.log" 2>&1 &
	CONTENT_PID=$!
	;;
none) CONTENT_PID= ;;
esac
sleep 2

mkfifo "$R/p.yuv"
wf-recorder -g "0,0 ${W}x${H}" -c rawvideo -r "$FPS" -D -f "$R/p.yuv" \
	> "$R/wf.log" 2>&1 &
WF_PID=$!
sleep 1

ffmpeg -hide_banner -loglevel info \
	-f rawvideo -pix_fmt bgra -s "${W}x${H}" -r "$FPS" -i "$R/p.yuv" \
	-vf format=nv12 -pix_fmt nv12 \
	-c:v h264_v4l2m2m -b:v "$BITRATE" \
	-force_key_frames "expr:gte(t,n_forced*${KEYINT})" \
	-fps_mode passthrough \
	-bsf:v dump_extra=freq=keyframe \
	-flush_packets 1 -muxdelay 0 -muxpreload 0 \
	-f mpegts "udp://${TARGET}:${PORT}?pkt_size=1316" \
	> "$R/ff.log" 2>&1 &
FF_PID=$!

printf '%s\n%s\n%s\n%s\n' "$SWAY_PID" "$WF_PID" "$FF_PID" "${CONTENT_PID:-}" \
	| grep -v '^$' > "$PIDFILE"

echo "sway=$SWAY_PID wf=$WF_PID ffmpeg=$FF_PID content=${CONTENT_PID:-none}"
echo "target=${TARGET}:${PORT}  ${W}x${H}@${FPS}  keyint=${KEYINT}s  content=${CONTENT}"

# 12 秒后汇报状态
sleep 12
echo "--- 进程 ---"
for n in "$SWAY_PID" "$WF_PID" "$FF_PID"; do
	if kill -0 "$n" 2>/dev/null; then
		echo "  pid $n 存活: $(tr '\0' ' ' < /proc/$n/cmdline | cut -c1-70)"
	else
		echo "  pid $n 已退出"
	fi
done
echo "--- ffmpeg 尾 ---"
tail -c 300 "$R/ff.log" | tr '\r' '\n' | tail -2 | sed 's/^/    /'
