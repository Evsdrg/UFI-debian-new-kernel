#!/bin/bash
# CPU frequency vs throughput vs sustained temperature for the UFI103s.
#
# WHY THIS EXISTS: msm8916 exposes no CPU voltage control, so frequency is the
# only knob for power/heat.  Use the table this prints to pick a cap:
#   cap 800-998.4 MHz -> still real-time 1080p->720p, several degrees cooler
#   cap 1209.6 MHz    -> max throughput, hottest
#
# Measured (300-frame 1080p H.264 -> 720p736 transcode, cool start, 3 reps):
#   400 MHz  ~18.8 fps   800 MHz  ~34.9 fps   998.4 MHz ~41.3 fps   1209.6 MHz ~46.9 fps
# Sustained all-core steady state: 400->53C  800->64C  998.4->68C  1209.6->73C
set -u
cd /tmp
CPUS="0 1 2 3"
SCALE="scale=1280:720:flags=fast_bilinear,pad=1280:736:0:8,format=nv12"

pin() { for c in $CPUS; do
	echo performance > /sys/devices/system/cpu/cpu$c/cpufreq/scaling_governor
	echo "$1" > /sys/devices/system/cpu/cpu$c/cpufreq/scaling_max_freq
	echo "$1" > /sys/devices/system/cpu/cpu$c/cpufreq/scaling_min_freq; done; sleep 0.3; }
cput() { local m=0; for z in /sys/class/thermal/thermal_zone*/; do
	t=$(cat $z/type 2>/dev/null); case "$t" in cpu*) v=$(cat $z/temp)
		[ "$v" -gt "$m" ] && m=$v;; esac; done; echo $((m/1000)); }

ffmpeg -hide_banner -loglevel error -y -f lavfi \
  -i "testsrc2=duration=10:size=1920x1080:rate=30" -pix_fmt yuv420p \
  -c:v libx264 -preset ultrafast -g 30 /tmp/s.h264 2>/dev/null

echo "throughput (3 short reps, cool start); real-time = 30 fps"
for f in 400000 800000 998400 1209600; do
	printf '  %7s kHz: ' "$f"
	for r in 1 2 3; do
		pin $f
		t0=$(date +%s%N)
		ffmpeg -hide_banner -loglevel error -y -i /tmp/s.h264 -vf "$SCALE" \
		  -pix_fmt nv12 -c:v h264_v4l2m2m -b:v 4M -g 30 \
		  -fps_mode passthrough -f null - 2>/dev/null
		t1=$(date +%s%N)
		printf '%5.1f ' "$(awk "BEGIN{print 300*1000/(($t1-$t0)/1000000)}")"
	done
	printf ' fps (now %dC)\n' "$(cput)"
	sleep 8
done

for c in $CPUS; do
	echo schedutil > /sys/devices/system/cpu/cpu$c/cpufreq/scaling_governor
	echo 200000 > /sys/devices/system/cpu/cpu$c/cpufreq/scaling_min_freq
	echo 998400 > /sys/devices/system/cpu/cpu$c/cpufreq/scaling_max_freq
done
rm -f /tmp/s.h264
echo "restored to schedutil / max 998400"
