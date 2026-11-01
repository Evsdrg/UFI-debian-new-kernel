#!/bin/bash
# mf32-ledctl 逻辑自测：假 sysfs + 假 evdev + 假 netlink，注水验证状态机。
# 不依赖实机；跑完输出 PASS/FAIL，全部通过退出 0。
set -u
cd "$(dirname "$0")/.."
BIN=${MF32_LEDCTL_BIN:-/tmp/mf32-ledctl}
[ -x "$BIN" ] || { echo "缺少 $BIN（先交叉编译）" >&2; exit 1; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
LEDS=$T/leds; PSY=$T/psy/bms; NET=$T/net; NM=$T/nm; ST=$T/state
mkdir -p "$LEDS" "$PSY" "$NET" "$NM" "$ST"

for l in wifistatus 4g_1 4g_type bat1 batl2 batl3 batl4; do
    mkdir -p "$LEDS/$l"
    for a in brightness trigger delay_on delay_off; do : > "$LEDS/$l/$a"; done
    echo none > "$LEDS/$l/trigger"
done
for i in wlan0 wwan0; do mkdir -p "$NET/$i"; echo down > "$NET/$i/operstate"; done
echo 4350000 > "$PSY/voltage_now"; echo Discharging > "$PSY/status"
echo running > "$T/remoteproc"

pass=0; fail=0
chk() {  # chk <场景> <led> <属性=期望>...
    local scen=$1 led=$2; shift 2
    local bad=""
    for want in "$@"; do
        local k=${want%%=*} v=${want#*=}
        local got; got=$(cat "$LEDS/$led/$k" 2>/dev/null | tr -d '[:space:]')
        [ "$got" = "$v" ] || bad="$bad [$led]$k=$got(期望$v)"
    done
    if [ -z "$bad" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL($scen)$bad"; fi
}

# 用 FIFO 作按键设备，避免依赖真实 evdev
mkfifo "$T/evdev"

export MF32_LED_SYS="$LEDS" MF32_PSY_BAT="$PSY" MF32_NET_DIR="$NET" \
       MF32_REMOTEPROC="$T/remoteproc" MF32_NM_CONN_DIR="$NM" \
       MF32_STATE="$ST" MF32_INPUT_DEV="$T/evdev"

start() { "$BIN" & PID=$!; exec 9>"$T/evdev"; sleep 0.3; }
stop()  { kill $PID 2>/dev/null; wait $PID 2>/dev/null; exec 9>&-; }

# 发送一个按键事件：press(1) 或 release(0)，时间戳由内核时间给出（这里用当前时间）
key() {  # key <press|release> <持续毫秒后> [时长毫秒]
    local val=$1 dur=$2
    # struct input_event64: sec(8) usec(8) type(2) code(2) value(4)
    python3 - "$T/evdev" "$val" "$dur" <<'PY'
import os, struct, sys, time
path, val, dur = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
# 用单调时钟构造事件时间戳（与设备一致：CLOCK_MONOTONIC 秒/微秒）
t = time.clock_gettime(time.CLOCK_MONOTONIC)
sec = int(t); usec = int((t - sec) * 1e6)
ev = struct.pack('<QQHHi', sec, usec, 1, 116, val)
with open(path, 'wb') as f:
    f.write(ev)
PY
    sleep "$(awk "BEGIN{print $3/1000}")"
}

echo "=== S1 初始：MODE_DEFAULT，电量条全灭 ==="
start
chk S1 bat1 brightness=0
chk S1 batl4 brightness=0
stop

echo "=== S2 短按：peek 点亮电量条 3 秒 ==="
start
key 1 0 100; key 0 0 0
sleep 0.3
chk S2 bat1 brightness=1
chk S2 batl4 brightness=1
sleep 3
chk S2b bat1 brightness=0
chk S2b batl4 brightness=0
stop

echo "=== S3 长按 2.5s：切换模式 0→1（常亮） ==="
start
key 1 0 2500; key 0 0 0
sleep 0.3
echo "  mode 文件=$(cat $ST/mode 2>/dev/null)"
sleep 0.5
chk S3 bat1 brightness=1
chk S3 batl4 brightness=1
stop

echo "=== S4 常亮模式下重启仍保持（持久化） ==="
start
chk S4 bat1 brightness=1
stop

echo "=== S5 再长按 2.5s：模式 1→2（全灭） ==="
start
key 1 0 2500; key 0 0 0
sleep 0.3
echo "  mode 文件=$(cat $ST/mode 2>/dev/null)"
chk S5 bat1 brightness=0
chk S5 wifistatus brightness=0
stop

echo "=== S6 全灭模式下短按：仍显示 3 秒 ==="
start
key 1 0 100; key 0 0 0
sleep 0.3
chk S6 bat1 brightness=1
sleep 3
chk S6b bat1 brightness=0
stop

echo "=== S7 再长按：模式 2→0 回默认 ==="
start
key 1 0 2500; key 0 0 0
sleep 0.3
echo "  mode 文件=$(cat $ST/mode 2>/dev/null)"
chk S7 bat1 brightness=0
stop

echo "=== S8 危急低电：常驻快闪（任意模式） ==="
echo 3200000 > "$PSY/voltage_now"
start
chk S8 bat1 trigger=timer delay_on=250 delay_off=250
stop
echo 4350000 > "$PSY/voltage_now"

echo "=== S9 WiFi 已连接：常亮 ==="
echo up > "$NET/wlan0/operstate"
printf '[connection]\ntype=wifi\n' > "$NM/home.nmconnection"
start
chk S9 wifistatus brightness=1 trigger=none
stop
echo down > "$NET/wlan0/operstate"

echo "=== S10 WiFi 已配置未连接：慢闪 ==="
start
# 触发一次网络重采样：写 operstate 后发 SIGUSR1 不生效，改用重新读取——
# 简化：重启进程使初始采样看到 down + 有 profile
stop; start
chk S10 wifistatus trigger=timer delay_on=1000 delay_off=1000
stop

echo "=== S11 4G 数据会话：LTE 蓝常亮 ==="
echo up > "$NET/wwan0/operstate"
start
chk S11 4g_1 brightness=1
chk S11 4g_type brightness=0
stop
echo down > "$NET/wwan0/operstate"

echo "=== S12 模组故障：LTE 红常亮 ==="
echo offline > "$T/remoteproc"
start
chk S12 4g_type brightness=1
chk S12 4g_1 brightness=0
stop
echo running > "$T/remoteproc"

echo "----------------------------------------"
echo "PASS=$pass FAIL=$fail"
[ "$fail" = 0 ]
