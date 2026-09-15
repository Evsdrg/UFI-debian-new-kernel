#!/bin/bash
# mf32-led-state.sh 逻辑自测：假 sysfs 注水，覆盖 RGB 优先级与电量条场景。
# 不依赖实机；跑完输出 PASS/FAIL 明细，全部通过退出 0。
set -u
cd "$(dirname "$0")/.."
SCRIPT=tools/mf32-led-state.sh
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# 假 sysfs 骨架
LEDS=$T/sys/class/leds; PSY=$T/sys/class/power_supply
mkdir -p "$LEDS" "$PSY/bms"
for l in red:status green:status blue:status bat:1 bat:2 bat:3 bat:4; do
    mkdir -p "$LEDS/$l"
    : > "$LEDS/$l/brightness"; : > "$LEDS/$l/trigger"
    : > "$LEDS/$l/delay_on";   : > "$LEDS/$l/delay_off"
done
echo 0 > "$PSY/bms/capacity"; echo Unknown > "$PSY/bms/status"

# 假 nmcli/systemctl：内容由 $T/nmcli-* / $T/systemctl-failed 控制
SHIM=$T/bin; mkdir -p "$SHIM"
cat > "$SHIM/nmcli" <<EOF
#!/bin/sh
case "\$*" in
  *con\ show*)  [ -f "$T/nmcli-wifi" ]  && echo "home:802-11-wireless:wlan0:activated" ;;
  *dev\ show*)  [ -f "$T/nmcli-wwan" ]  && cat "$T/nmcli-wwan" ;;
esac
exit 0
EOF
cat > "$SHIM/systemctl" <<EOF
#!/bin/sh
[ -f "$T/systemctl-failed" ] && cat "$T/systemctl-failed"
exit 0
EOF
chmod +x "$SHIM/nmcli" "$SHIM/systemctl"

export MF32_LED_SYS="$LEDS" MF32_PSY_SYS="$PSY" MF32_STATE="$T/state" PATH="$SHIM:$PATH"

pass=0; fail=0
chk() {  # chk <场景> <led> <属性期望: bright=1,trigger=timer,delay_on=250...>
    local scen=$1 led=$2; shift 2
    local bad=""
    local dir="$LEDS/$led"
    for want in "$@"; do
        local k=${want%%=*} v=${want#*=}
        local got; got=$(cat "$dir/$k" 2>/dev/null | tr -d '[:space:]')
        [ "$got" = "$v" ] || bad="$bad [$led]$k=$got(期望$v)"
    done
    if [ -z "$bad" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL($scen)$bad"; fi
}

run() { "$SCRIPT" once force >/dev/null 2>&1; }
setbatt() { echo "$1" > "$PSY/bms/capacity"; echo "${2:-Discharging}" > "$PSY/bms/status"; }

# 场景 1：满电未充，WiFi 好，无 4G 会话 → 4 常亮 + 蓝常亮
setbatt 100 Discharging; touch "$T/nmcli-wifi"; rm -f "$T/nmcli-wwan"
run
chk S1 bat:1 brightness=1 trigger=none
chk S1 bat:4 brightness=1 trigger=none
chk S1 blue:status brightness=1 trigger=none
chk S1 red:status brightness=0

# 场景 2：50% 充电中 → 2 常亮 + bat:3 填充闪 + 蓝常亮
setbatt 50 Charging
run
chk S2 bat:2 brightness=1
chk S2 bat:3 trigger=timer delay_on=500 delay_off=500
chk S2 bat:4 brightness=0
chk S2 blue:status brightness=1

# 场景 3：10% 未充 → 1 常亮 + 红常亮（低电警告）
setbatt 10 Discharging
run
chk S3 bat:1 brightness=1 trigger=none
chk S3 bat:2 brightness=0
chk S3 red:status brightness=1 trigger=none

# 场景 4：5% 未充 → bat:1 快闪 + 红快闪（危急）
setbatt 5 Discharging
run
chk S4 bat:1 trigger=timer delay_on=250 delay_off=250
chk S4 red:status trigger=timer delay_on=250 delay_off=250

# 场景 5：危急但充电中 → 不进红快闪，条按充电渲染
setbatt 5 Charging
run
chk S5 red:status brightness=0
chk S5 bat:2 trigger=timer delay_on=500 delay_off=500

# 场景 6：4G 会话 → 绿常亮
setbatt 90 Discharging; echo "wwan0:connected" > "$T/nmcli-wwan"
run
chk S6 green:status brightness=1 trigger=none
chk S6 blue:status brightness=0

# 场景 7：4G 连接中 → 绿快闪
echo "wwan0:connecting" > "$T/nmcli-wwan"
run
chk S7 green:status trigger=timer delay_on=250 delay_off=250

# 场景 8：WiFi 断 → 蓝慢闪（优先于绿系）
rm -f "$T/nmcli-wifi"; echo "wwan0:connected" > "$T/nmcli-wwan"
run
chk S8 blue:status trigger=timer delay_on=1000 delay_off=1000
chk S8 green:status brightness=0

# 场景 9：档位滞回 —— 从 100%（4 档）降到 73%，应保持 4 档；再降到 70% 才降 3 档
setbatt 73 Discharging; touch "$T/nmcli-wifi"
run
chk S9a bat:4 brightness=1
setbatt 70 Discharging
run
chk S9b bat:4 brightness=0
chk S9b bat:3 brightness=1

# 场景 10：once 后状态快照存在
[ -s "$T/state/status" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL(S10) 无状态快照"; }

# off 命令：先红常亮再全灭（跳过 2s 睡眠无法 mock，直接查终态）
OFF_RED_SECS=0 "$SCRIPT" off >/dev/null 2>&1
chk OFF red:status brightness=0 trigger=none
chk OFF bat:3 brightness=0 trigger=none


# 场景 11：QUIET=1 稳态条全灭（蓝灯也不亮）
setbatt 80 Discharging; touch "$T/nmcli-wifi"; rm -f "$T/nmcli-wwan"
QUIET=1 run
chk S11 bat:2 brightness=0
chk S11 blue:status brightness=0

# 场景 12：QUIET 下 peek（peek_until 在未来）→ 条恢复显示
echo $(( $(date +%s) + 3 )) > "$T/state/peek_until"
QUIET=1 run
chk S12 bat:4 brightness=1
chk S12 blue:status brightness=0
rm -f "$T/state/peek_until"

echo "----------------------------------------"
echo "PASS=$pass FAIL=$fail"
[ "$fail" = 0 ]
