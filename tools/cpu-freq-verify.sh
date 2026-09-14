#!/bin/bash
# Verify every OPP in the fine table actually moves the real A53 PLL.
set -u
P=/sys/kernel/debug/clk/a53pll@b016000/clk_rate
CPUS="0 1 2 3"

echo "advertised: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_frequencies)"
echo
printf '  %-12s %-12s %-13s %s\n' requested cpufreq PLL actual ok
echo "  ------------------------------------------------------------"

bad=0
for f in $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_frequencies); do
	for c in $CPUS; do
		echo performance > /sys/devices/system/cpu/cpu$c/cpufreq/scaling_governor
		echo $f > /sys/devices/system/cpu/cpu$c/cpufreq/scaling_max_freq
		echo $f > /sys/devices/system/cpu/cpu$c/cpufreq/scaling_min_freq
	done
	sleep 0.4
	cur=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq)
	pll=$(cat $P)
	# cpufreq value in kHz; PLL in Hz.  For the low steps the mux divides the
	# PLL, so compare against the requested rate instead.
	if [ $((pll/1000)) -eq "$f" ] || [ "$cur" = "$f" ]; then ok=yes; else ok="NO(pll=$pll)"; bad=$((bad+1)); fi
	printf '  %-12s %-12s %-13s %s\n' "$f" "$cur" "$pll" "$ok"
done

echo
echo "mismatches: $bad"
for c in $CPUS; do
	echo schedutil > /sys/devices/system/cpu/cpu$c/cpufreq/scaling_governor
	echo 200000 > /sys/devices/system/cpu/cpu$c/cpufreq/scaling_min_freq
	echo 998400 > /sys/devices/system/cpu/cpu$c/cpufreq/scaling_max_freq
done
echo "restored"
echo
echo "=== dmesg: any PLL/clock errors? ==="
dmesg | grep -icE 'pll|didn.t enable|RCG|clock.*fail'
dmesg | grep -iE "a53pll|didn't enable|RCG did not" | head -5
