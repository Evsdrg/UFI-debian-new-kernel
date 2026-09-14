#!/bin/bash
# 1080p -> 720p transcode + stream for UFI103s (MSM8916 Venus hardware encoder).
#
# Usage:
#   venus-transcode.sh <input> [output]
#     input   file, or a URL ffmpeg can read (http/rtsp/rtmp/srt/...)
#     output  default: rtmp://127.0.0.1/live/stream
#             "-" writes to stdout; a local path (e.g. /tmp/out.flv) lets you
#             test the whole pipeline without a streaming server.
#
# Why this shape (all measured on the stick, see WORKSPACE-INDEX.txt):
#   * Decode in software, encode in hardware.  Using v4l2m2m for BOTH in one
#     ffmpeg process truncates the output to a single frame, so the decoder
#     must stay software.  Software H.264 1080p decode runs ~78fps, plenty.
#   * fast_bilinear scaling: the default bilinear scaler caps the pipeline at
#     ~23fps (below real-time); fast_bilinear reaches ~32-38fps.
#   * The Venus encoder needs BOTH dimensions 32-aligned.  Measured: 640x480,
#     1280x736, 1280x768 and 1920x1088 encode fine; 1280x720 (H%32=16) and
#     1920x1080 (H%32=24) make the firmware report
#     "Err_Fatal - VenusCoreCtrl_AhbVbifErrorIRQ" and the ffmpeg process dies
#     with SIGSEGV.  So scale to 1280x720 and pad to 1280x736 (small black bar
#     at the bottom) -- 1280 is already a multiple of 32.
#   * -fps_mode passthrough: the encoder reports timestamp 0 per frame, so the
#     default vsync would drop almost every frame.
#
# Throughput (measured, 300-frame 1080p clip):
#   H.264 source -> 720p : ~32-38 fps  (real-time OK)
#   H.265 source -> 720p : ~23 fps     (NOT real-time)
#   H.265 720p source    -> 720p : ~47 fps (real-time OK)
# MSM8916 has NO hardware H.265 decode (Venus 1.8 predates it), so H.265 input
# is decoded in software, and a 1080p H.265 source cannot hold real time here.
set -euo pipefail

IN=${1:?usage: $0 <input> [output]}
OUT=${2:-rtmp://127.0.0.1/live/stream}
ENC_W=${ENC_W:-1280}
ENC_H=${ENC_H:-736}
VF="scale=${ENC_W}:$(( ENC_H - 16 )):flags=fast_bilinear,pad=${ENC_W}:${ENC_H}:0:8,format=nv12"

# Venus firmware requires both dimensions to be multiples of 32; feeding it a
# non-aligned size makes it report a VBIF error and kills the process.  Fail
# loudly here instead of producing a mystery SIGSEGV mid-stream.
if (( ENC_W % 32 != 0 || ENC_H % 32 != 0 )); then
	echo "venus-transcode: encoder size ${ENC_W}x${ENC_H} is not 32-aligned" >&2
	echo "  (Venus needs both dimensions to be multiples of 32; e.g. 1280x736," >&2
	echo "   1920x1088. Non-aligned sizes crash the encoder firmware.)" >&2
	exit 2
fi

# Pick the muxer from the output: streaming URLs use FLV (RTMP's payload),
# local files use their extension, "-" lets ffmpeg guess from the codec.
case "$OUT" in
	-)
		MUX=(-f h264) ;;
	rtmp://*|rtmps://*|rtmpt://*)
		MUX=(-f flv) ;;
	*.flv)	MUX=(-f flv) ;;
	*.ts)	MUX=(-f mpegts) ;;
	*.mkv)	MUX=(-f matroska) ;;
	*.mp4)	MUX=(-f mp4 -movflags +frag_keyframe+empty_moov) ;;
	rtsp://*|srt://*|udp://*|mpegts://*)
		MUX=(-f mpegts) ;;
	http://*|https://*)
		MUX=() ;;
	*)
		MUX=() ;;
esac

# Recommended systemd settings when wrapping this:
#   Restart=always
#   RestartSec=5
# so a transient network or input error does not leave the service dead.

exec ffmpeg -hide_banner -loglevel warning \
	-re -i "$IN" \
	-map 0:v:0 -an \
	-vf "$VF" -pix_fmt nv12 \
	-c:v h264_v4l2m2m -b:v 4M -g 60 -fps_mode passthrough \
	"${MUX[@]}" "$OUT"
