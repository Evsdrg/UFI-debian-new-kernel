#!/bin/bash
# Venus (Qualcomm MSM8916) hardware codec verification.
#
# SAFETY: never rmmod/modprobe -r venus after a firmware error -- the unload
# path blocks and hangs the kernel. On failure: reboot only.
#
# Hardware encode/decode is driven through ffmpeg's h264_v4l2m2m wrapper.
# Note: ffmpeg's encoder forces HEADER_MODE_SEPARATE, which HFI 1xx cannot
# honour, so the driver keeps SPS/PPS in-band on msm8916 (see the venus
# HFI 1xx fixes in source/patches/). Decoding needs -fps_mode passthrough
# because the m2m driver reports the same timestamp for every frame.
set -u

LOG=${VENUS_LOG:-/root/venus-result.txt}
LED=/usr/local/sbin/ufi-led-state.sh
: > "$LOG"

log() { printf '%s\n' "$*" | tee -a "$LOG"; }
led() { [ -x "$LED" ] && "$LED" "$1" || true; }

log "=== Venus codec verification $(date -u +%FT%TZ) ==="
log "kernel: $(uname -r)"
led testing

modprobe venus_core >>"$LOG" 2>&1 || true
modprobe venus_dec >>"$LOG" 2>&1 || true
modprobe venus_enc >>"$LOG" 2>&1 || true
sleep 2

v4l2-ctl --list-devices 2>&1 | tee -a "$LOG"

enc=""; dec=""
# Prefer the stable udev names (70-venus-video.rules); fall back to matching the
# V4L2 card type, because /dev/videoN ordering swaps between boots.
if [ -e /dev/video-encoder ] && [ -e /dev/video-decoder ]; then
	enc=/dev/video-encoder
	dec=/dev/video-decoder
else
	for d in /dev/video*; do
		[ -e "$d" ] || continue
		case "$(v4l2-ctl -d "$d" -D 2>/dev/null | sed -n 's/.*Card type *: *//p')" in
			*encoder*) enc=$d ;;
			*decoder*) dec=$d ;;
		esac
	done
fi
log "encoder=$enc decoder=$dec"
[ -n "$enc" ] && [ -n "$dec" ] || { led fail; log "OVERALL: FAIL (video nodes missing)"; exit 0; }

rm -f /root/venus-test.h264 /root/venus-test.sw.yuv /root/venus-test.hw.yuv

log "--- encode: testsrc -> H.264 (hardware) ---"
if ! ffmpeg -hide_banner -loglevel error -y \
	-f lavfi -i "testsrc=duration=2:size=640x480:rate=15" \
	-vf format=nv12 -pix_fmt nv12 -c:v h264_v4l2m2m -b:v 1M \
	/root/venus-test.h264 >>"$LOG" 2>&1; then
	led fail
	log "OVERALL: FAIL (hardware encode failed)"
	exit 0
fi
log "encoded $(stat -c %s /root/venus-test.h264 2>/dev/null) bytes"

log "--- software decode reference ---"
ffmpeg -hide_banner -loglevel error -y -i /root/venus-test.h264 \
	-fps_mode passthrough -f rawvideo -pix_fmt nv12 /root/venus-test.sw.yuv >>"$LOG" 2>&1
sw=$(stat -c %s /root/venus-test.sw.yuv 2>/dev/null || echo 0)

log "--- decode: H.264 -> NV12 (hardware) ---"
ffmpeg -hide_banner -loglevel error -y -c:v h264_v4l2m2m \
	-i /root/venus-test.h264 -fps_mode passthrough \
	-f rawvideo -pix_fmt nv12 /root/venus-test.hw.yuv >>"$LOG" 2>&1
hw=$(stat -c %s /root/venus-test.hw.yuv 2>/dev/null || echo 0)
log "software=$sw bytes hardware=$hw bytes"

if [ "$sw" -gt 0 ] && [ "$sw" = "$hw" ] && cmp -s /root/venus-test.sw.yuv /root/venus-test.hw.yuv; then
	led pass
	log "OVERALL: PASS (encode+decode, hardware decode byte-identical to software)"
else
	led fail
	log "OVERALL: FAIL (sw=$sw hw=$hw)"
fi
log "--- kernel diagnostics ---"
dmesg | grep -iE 'venus.*(error|fail|timeout)|iommu.*fault|smmu.*fault' | tail -20 | tee -a "$LOG"
log "full log: $LOG"
