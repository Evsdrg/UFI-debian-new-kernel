#!/bin/bash
# mf601sl-ledctl 逻辑自测：假 sysfs + 假 evdev + 假 netlink，注水验证状态机。
# 不依赖实机；跑完输出 PASS/FAIL，全部通过退出 0。
set -u
cd "$(dirname "$0")/.."
BIN=${MF601SL_LEDCTL_BIN:-/tmp/mf601sl-ledctl}
[ -x "$BIN" ] || { echo "缺少 $BIN（先交叉编译）" >&2; exit 1; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
LEDS=$T/leds; PSY=$T/psy/bms; NET=$T/net; NM=$T/nm; ST=$T/state
mkdir -p "$LEDS" "$PSY" "$NET" "$NM" "$ST"

# MF601SL 实机 6 灯（sysfs 名 = <color>:<function>）
for l in red:power green:power red:wan green:wan red:wlan green:wlan; do
    mkdir -p "$LEDS/$l"
    for a in brightness trigger delay_on delay_off; do : > "$LEDS/$l/$a"; done
    echo none > "$LEDS/$l/trigger"
done
for i in wlan0 wwan0; do mkdir -p "$NET/$i"; echo down > "$NET/$i/operstate"; done
echo 4200000 > "$PSY/voltage_now"; echo Discharging > "$PSY/status"
echo running > "$T/remoteproc"

pass=0; fail=0
chk() {  # chk <场景> <led> <属性=期望>...
    local scen=$1 led=$2; shift 2
    local bad=""
    for want in "$@"; do
        local k=${want%%=*} v=${want#*=}
        local got; got=$(cat "$LEDS/$led/$k" 2>/dev/null | tr -d '[:space:]')
        # 假 sysfs 是普通文件：把 "none" 写到 "timer" 上会残留成 "noner"。
        # 真实 sysfs 每次写入都是完整替换，因此 trigger 用前缀匹配。
        if [ "$k" = trigger ]; then
            case "$got" in "$v"*) ;; *) bad="$bad [$led]$k=$got(期望$v)" ;; esac
        else
            [ "$got" = "$v" ] || bad="$bad [$led]$k=$got(期望$v)"
        fi
    done
    if [ -z "$bad" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL($scen)$bad"; fi
}

# 用 FIFO 作按键设备，避免依赖真实 evdev
mkfifo "$T/evdev"

export MF601SL_LED_SYS="$LEDS" MF601SL_PSY_BAT="$PSY" MF601SL_NET_DIR="$NET" \
       MF601SL_REMOTEPROC="$T/remoteproc" MF601SL_NM_CONN_DIR="$NM" \
       MF601SL_STATE="$ST" MF601SL_INPUT_DEV="$T/evdev" \
       MF601SL_REG_STATE="$T/regstate"
# 默认注册正常（空文件 → 既非 denied 也非 limited）
: > "$T/regstate"

start() { "$BIN" & PID=$!; exec 9>"$T/evdev"; sleep 0.3; }
stop()  { kill $PID 2>/dev/null; wait $PID 2>/dev/null; exec 9>&-; }

# 发送一个按键事件：press(1) 或 release(0)，时间戳由内核时间给出
key() {  # key <press|release> <持续毫秒后> [时长毫秒]
    local val=$1 dur=$2
    # struct input_event64: sec(8) usec(8) type(2) code(2) value(4)
    python3 - "$T/evdev" "$val" "$dur" <<'PY'
import os, struct, sys, time
path, val, dur = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
t = time.clock_gettime(time.CLOCK_MONOTONIC)
sec = int(t); usec = int((t - sec) * 1e6)
ev = struct.pack('<QQHHi', sec, usec, 1, 116, val)
with open(path, 'wb') as f:
    f.write(ev)
PY
    sleep "$(awk "BEGIN{print $3/1000}")"
}

echo "=== S1 初始：MODE_DEFAULT，电量组全灭 ==="
start
chk S1 red:power brightness=0
chk S1 green:power brightness=0
stop

echo "=== S2 短按：peek 点亮电量组 3 秒（4200mV，未充电 → 绿灯） ==="
start
key 1 0 100; key 0 0 0
sleep 0.3
chk S2 green:power brightness=1
chk S2 red:power brightness=0
sleep 3
chk S2b green:power brightness=0
stop

echo "=== S3 长按 2.5s：切换模式 0→1（常亮） ==="
start
key 1 0 2500; key 0 0 0
sleep 0.3
echo "  mode 文件=$(cat $ST/mode 2>/dev/null)"
sleep 0.5
chk S3 green:power brightness=1
stop

echo "=== S4 常亮模式下重启仍保持（持久化） ==="
start
chk S4 green:power brightness=1
stop

echo "=== S5 再长按 2.5s：模式 1→2（全灭） ==="
start
key 1 0 2500; key 0 0 0
sleep 0.3
echo "  mode 文件=$(cat $ST/mode 2>/dev/null)"
chk S5 green:power brightness=0
chk S5 green:wan brightness=0
chk S5 green:wlan brightness=0
stop

echo "=== S6 全灭模式下短按：仍显示 3 秒 ==="
start
key 1 0 100; key 0 0 0
sleep 0.3
chk S6 green:power brightness=1
sleep 3
chk S6b green:power brightness=0
stop

echo "=== S7 再长按：模式 2→0 回默认 ==="
start
key 1 0 2500; key 0 0 0
sleep 0.3
echo "  mode 文件=$(cat $ST/mode 2>/dev/null)"
chk S7 green:power brightness=0
stop

echo "=== S8 危急低电（3.2V，未充电）：红灯快闪（任意模式） ==="
echo 3200000 > "$PSY/voltage_now"
start
chk S8 red:power trigger=timer delay_on=250 delay_off=250
chk S8 green:power brightness=0
stop
echo 4200000 > "$PSY/voltage_now"

echo "=== S9 低电（3.30V = 15%）：红灯常亮 ==="
echo 3300000 > "$PSY/voltage_now"
start
key 1 0 100; key 0 0 0
sleep 0.3
chk S9 red:power brightness=1
chk S9 green:power brightness=0
stop
echo 4200000 > "$PSY/voltage_now"

echo "=== S10 充电中：绿灯慢闪 ==="
echo Charging > "$PSY/status"
start
key 1 0 100; key 0 0 0
sleep 0.3
chk S10 green:power trigger=timer delay_on=1000 delay_off=1000
chk S10 red:power brightness=0
stop
echo Discharging > "$PSY/status"

echo "=== S11 WiFi 已连接：绿常亮，红灭 ==="
echo up > "$NET/wlan0/operstate"
printf '[connection]\ntype=wifi\n' > "$NM/home.nmconnection"
start
chk S11 green:wlan brightness=1 trigger=none
chk S11 red:wlan brightness=0
stop
echo down > "$NET/wlan0/operstate"

echo "=== S12 WiFi 已配置未连接：红慢闪 ==="
start
chk S12 red:wlan trigger=timer delay_on=1000 delay_off=1000
chk S12 green:wlan brightness=0
stop
rm -f "$NM/home.nmconnection"

echo "=== S13 WiFi 无配置：两组全灭 ==="
start
chk S13 red:wlan brightness=0
chk S13 green:wlan brightness=0
stop

echo "=== S14 4G 数据会话：绿灯常亮 ==="
echo up > "$NET/wwan0/operstate"
start
chk S14 green:wan brightness=1
chk S14 red:wan brightness=0
stop
echo down > "$NET/wwan0/operstate"

echo "=== S15 模组故障/no SIM：红灯慢闪 ==="
echo offline > "$T/remoteproc"
start
chk S15 red:wan brightness=1
chk S15 red:wan trigger=timer
chk S15 green:wan brightness=0
stop
echo running > "$T/remoteproc"

echo "=== S16 模组正常但未注册：两灯全灭 ==="
start
chk S16 red:wan brightness=0
chk S16 green:wan brightness=0
stop

echo "=== S17 注册被拒（registration-denied）：红灯常亮 ==="
echo denied > "$T/regstate"
start
chk S17 red:wan brightness=1
chk S17 red:wan trigger=none
chk S17 green:wan brightness=0
stop

echo "=== S18 registration-limited 同样按被拒处理 ==="
echo limited > "$T/regstate"
start
chk S18 red:wan brightness=1
chk S18 green:wan brightness=0
stop

# 恢复：注册态清空，供后续场景（如果有）使用
: > "$T/regstate"

echo "----------------------------------------"
echo "PASS=$pass FAIL=$fail"
[ "$fail" = 0 ]
