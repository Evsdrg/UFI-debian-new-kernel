#!/bin/bash
# mf32-powerkey.sh 状态机自测：simulate 模式喂按键序列，断言动作。
# systemctl 以假 shim 捕获（不真关机）。全过退出 0。
set -u
cd "$(dirname "$0")/.."
SCRIPT=tools/mf32-powerkey.sh
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

STATE=$T/state; mkdir -p "$STATE"
SHIM=$T/bin; mkdir -p "$SHIM"
cat > "$SHIM/systemctl" <<EOF
#!/bin/sh
[ "\$1 \$2" = "poweroff " ] || [ "\$*" = "poweroff" ] && echo poweroff >> "$T/poweroff.log"
exit 0
EOF
chmod +x "$SHIM/systemctl"

export MF32_STATE="$STATE" PATH="$SHIM:$PATH"

pass=0; fail=0
expect_none() {  # 不应关机、不应 peek
    local scen=$1
    if [ -s "$T/poweroff.log" ]; then fail=$((fail+1)); echo "FAIL($scen) 意外关机"; else pass=$((pass+1)); fi
    if [ -s "$STATE/peek_until" ] && [ "$(cat $STATE/peek_until)" != 0 ]; then
        fail=$((fail+1)); echo "FAIL($scen) 意外 peek"
    else
        pass=$((pass+1))
    fi
    rm -f "$STATE/peek_until" "$T/poweroff.log"
}
expect_poweroff() {
    local scen=$1
    if [ -s "$T/poweroff.log" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL($scen) 未关机"; fi
    rm -f "$T/poweroff.log"
}
expect_peek() {  # peek_until ≈ now+3s，且不应关机
    local scen=$1 pu now
    now=$(date +%s); pu=$(cat "$STATE/peek_until" 2>/dev/null || echo 0)
    if [ "$pu" -gt "$now" ] && [ "$pu" -le $((now + 4)) ]; then pass=$((pass+1))
    else fail=$((fail+1)); echo "FAIL($scen) peek_until=$pu now=$now"; fi
    if [ -s "$T/poweroff.log" ]; then fail=$((fail+1)); echo "FAIL($scen) 意外关机"; fi
    rm -f "$STATE/peek_until" "$T/poweroff.log"
}
sim() {
    local args=("$@") i
    {
        for ((i = 0; i < ${#args[@]}; i += 2)); do
            echo "${args[i]} ${args[i + 1]}"
        done
    } | "$SCRIPT" simulate
}

# S1 双击关机：按-放-按-放（间隔 <500ms）
sim 1 1000 0 1200 1 1500 0 1700
expect_poweroff S1

# S2 单击 peek：一次快速点击
sim 1 5000 0 5200
expect_peek S2

# S3 双击间隔过长（第二次按下距首次释放 >500ms）→ 两次独立单击，只有 peek
rm -f "$T/poweroff.log"
sim 1 10000 0 10200 1 12000 0 12200
expect_peek S3

# S4 长按（>1500ms）→ 无动作（PON 兜底），即使此前有一次单击
sim 1 20000 0 20200 1 21000 0 23000
expect_peek S4

# S5 纯长按 → 无动作
sim 1 30000 0 33000
expect_none S5

# S6 双击里夹一次长按 → 长按吞掉状态，不关机
sim 1 40000 0 40200 1 40600 0 42500
expect_peek S6

# S7 三连击 → 第二对是双击，关机
sim 1 50000 0 50100 1 50300 0 50500 1 50700 0 50900
expect_poweroff S7

# S8 慢速单击（600ms 按压，<CLICK_MS=800）→ peek
sim 1 60000 0 60600
expect_peek S8

# S9 超慢按压（>CLICK_MS 但 <LONG_MS）→ 无动作无 peek
sim 1 70000 0 71200
expect_none S9

echo "----------------------------------------"
echo "PASS=$pass FAIL=$fail"
[ "$fail" = 0 ]
