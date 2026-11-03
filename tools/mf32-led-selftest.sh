#!/bin/bash
# mf32-led-state.sh 逻辑自测（实测硬件版，2026-10-30）
# 假 sysfs 注水，覆盖三颗状态灯优先级 + 电量条 peek/危急/充电填充/滞回。
# 不依赖实机；跑完输出 PASS/FAIL 明细，全部通过退出 0。
set -u
cd "$(dirname "$0")/.."
# 临时目录放 scratch，不占 /tmp（见 tools/kver.sh 的 SCRATCH 说明）。
. tools/kver.sh
mkdir -p "$SCRATCH_TMP"
SCRIPT=tools/mf32-led-state.sh
T=$(TMPDIR="$SCRATCH_TMP" mktemp -d)
trap 'rm -rf "$T"' EXIT

# 假 sysfs 骨架：只建实机存在的 7 颗灯
LEDS=$T/sys/class/leds; PSY=$T/sys/class/power_supply
mkdir -p "$LEDS" "$PSY/bms"
for l in wifistatus 4g_1 4g_type bat1 batl2 batl3 batl4; do
    mkdir -p "$LEDS/$l"
    : > "$LEDS/$l/brightness"; : > "$LEDS/$l/trigger"
    : > "$LEDS/$l/delay_on";   : > "$LEDS/$l/delay_off"
done
# bms：只有 voltage_now/status，没有 capacity（与实机一致）
echo 4350000 > "$PSY/bms/voltage_now"; echo Discharging > "$PSY/bms/status"

# 假命令：内容由 $T/nmcli-* / $T/systemctl-failed / $T/mmcli-state 控制
SHIM=$T/bin; mkdir -p "$SHIM"
cat > "$SHIM/nmcli" <<EOF
#!/bin/sh
case "\$*" in
  *NAME,TYPE,DEVICE,STATE*con\ show*)
      [ -f "$T/nmcli-wifi" ] && echo "home:802-11-wireless:wlan0:activated" ;;
  *NAME,TYPE*con\ show*)
      # 只有配置存在（nmcli-wifi-cfg）才报有 WiFi profile
      [ -f "$T/nmcli-wifi-cfg" ] && echo "home:802-11-wireless" ;;
  *dev\ show*)  [ -f "$T/nmcli-wwan" ]  && cat "$T/nmcli-wwan" ;;
esac
exit 0
EOF
cat > "$SHIM/systemctl" <<EOF
#!/bin/sh
[ -f "$T/systemctl-failed" ] && cat "$T/systemctl-failed"
exit 0
EOF
cat > "$SHIM/mmcli" <<EOF
#!/bin/sh
[ -f "$T/mmcli-state" ] && echo "       state: \$(cat "$T/mmcli-state")"
exit 0
EOF
chmod +x "$SHIM/nmcli" "$SHIM/systemctl" "$SHIM/mmcli"

export MF32_LED_SYS="$LEDS" MF32_PSY_SYS="$PSY" MF32_STATE="$T/state" PATH="$SHIM:$PATH"

pass=0; fail=0
chk() {  # chk <场景> <led> <属性期望: brightness=1,trigger=timer,delay_on=250...>
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
setbatt() { echo "$1" > "$PSY/bms/voltage_now"; echo "${2:-Discharging}" > "$PSY/bms/status"; }
peek() { echo $(( $(date +%s) + ${1:-3} )) > "$T/state/peek_until"; }
unpeek() { rm -f "$T/state/peek_until"; }

# ---------------- 状态灯 ----------------

# S1 常态（满电、WiFi 已连、无 4G）：电量条全灭，WiFi 蓝常亮，LTE 全灭
setbatt 4350000 Discharging; touch "$T/nmcli-wifi" "$T/nmcli-wifi-cfg"; rm -f "$T/nmcli-wwan" "$T/mmcli-state"
run
chk S1 bat1 brightness=0
chk S1 batl4 brightness=0
chk S1 wifistatus brightness=1 trigger=none
chk S1 4g_1 brightness=0
chk S1 4g_type brightness=0

# S2 无 WiFi 配置：WiFi 灯灭
rm -f "$T/nmcli-wifi" "$T/nmcli-wifi-cfg"
run
chk S2 wifistatus brightness=0

# S3 WiFi 已配置但断开：慢闪
touch "$T/nmcli-wifi-cfg"; rm -f "$T/nmcli-wifi"
run
chk S3 wifistatus trigger=timer delay_on=1000 delay_off=1000

# S4 4G 会话建立：LTE 蓝常亮
setbatt 4350000 Discharging; echo "wwan0:connected" > "$T/nmcli-wwan"
run
chk S4 4g_1 brightness=1 trigger=none
chk S4 4g_type brightness=0

# S5 4G 拨号中：LTE 蓝快闪
echo "wwan0:connecting" > "$T/nmcli-wwan"
run
chk S5 4g_1 trigger=timer delay_on=250 delay_off=250

# S6 4G 失败（mmcli failed）：LTE 红常亮
rm -f "$T/nmcli-wwan"; echo failed > "$T/mmcli-state"
run
chk S6 4g_type brightness=1 trigger=none
chk S6 4g_1 brightness=0

# S7 系统异常：LTE 红慢闪（压过其它 LTE 态）
rm -f "$T/mmcli-state"; echo "x.service loaded failed failed" > "$T/systemctl-failed"
run
chk S7 4g_type trigger=timer delay_on=1000 delay_off=1000
rm -f "$T/systemctl-failed"

# ---------------- 电量条 peek ----------------

# S8 peek 满电：4 颗常亮
setbatt 4350000 Discharging; peek; run
chk S8 bat1 brightness=1 trigger=none
chk S8 batl4 brightness=1 trigger=none

# S9 peek 50%（3650000→50%）未充电：2 常亮、第 3 颗不填充
setbatt 3650000 Discharging; peek; run
chk S9 batl2 brightness=1
chk S9 batl3 brightness=0 trigger=none
chk S9 batl4 brightness=0

# S10 peek 50% 充电中：同样 2 常亮 + 第 3 颗填充
setbatt 3650000 Charging; peek; run
chk S10 batl2 brightness=1
chk S10 batl3 trigger=timer delay_on=500 delay_off=500

# S11 peek 到期：电量条全灭
setbatt 4350000 Discharging; unpeek; run
chk S11 bat1 brightness=0
chk S11 batl4 brightness=0

# S12 危急低电（3200000→5%，未充）：bat1 常驻快闪，无需 peek
setbatt 3200000 Discharging; unpeek; run
chk S12 bat1 trigger=timer delay_on=250 delay_off=250
chk S12 batl2 brightness=0

# S13 低电 10%（3250000）未充、无 peek：电量条全灭（不常驻显示）
setbatt 3250000 Discharging; unpeek; run
chk S13 bat1 brightness=0

# S14 滞回：先 100%（4 档），再降到 74%（仍在 4 档滞回内），再降到 70% 才降档
setbatt 4350000 Discharging; peek; run
chk S14 batl4 brightness=1
setbatt 3880000 Discharging; peek; run   # ~74%，滞回保持 4 档
chk S14b batl4 brightness=1
setbatt 3500000 Discharging; peek; run   # 35%，降到 2 档
chk S14c batl2 brightness=1
chk S14c batl3 brightness=0

# ---------------- QUIET / off / 快照 ----------------

# S15 QUIET=1 + peek：电量条也不显示
setbatt 4350000 Discharging; peek; QUIET=1 run
chk S15 batl4 brightness=0

# S16 off：全灭
"$SCRIPT" off >/dev/null 2>&1
for l in wifistatus 4g_1 4g_type bat1 batl2 batl3 batl4; do
    chk S16 "$l" brightness=0 trigger=none
done

# S17 状态快照存在
[ -s "$T/state/status" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL(S17) 无状态快照"; }

echo "----------------------------------------"
echo "PASS=$pass FAIL=$fail"
[ "$fail" = 0 ]
