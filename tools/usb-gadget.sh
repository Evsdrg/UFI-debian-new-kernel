#!/bin/sh
# RNDIS configfs gadget；Linux 已验，Windows/macOS 兼容性须独立测试。
# 单一配置，网络策略由 NM shared 或 native-net 接管。
set -eu

GADGET_NAME=openstick
CFG=${USB_GADGET_CONFIGFS:-/sys/kernel/config/usb_gadget}
UDCS=${USB_GADGET_UDCS:-/sys/class/udc}
LOCK=${USB_GADGET_LOCK:-/run/lock/openstick-usb-gadget.lock}
G=$CFG/$GADGET_NAME
BUILDING=0

fail() { echo "usb-gadget: $*" >&2; exit 1; }
value() { [ -f "$1" ] && tr -d '\000\n' <"$1"; }
write_attr() {
    # configfs 属性不允许凭空创建，缺属性即失败（也便于离线模拟）。
    [ -f "$G/$1" ] || fail "缺少属性 $1"
    printf '%s\n' "$2" >"$G/$1" || fail "写入 $1 失败"
}
remove_tree() {
    [ -d "$G" ] || return 0
    bound=$(value "$G/UDC" || true)
    if [ -n "$bound" ]; then
        # 正常解绑。若内核侧已经解绑（UDC 目录已不存在），写空可能失败；
        # 这种情况下内核已经没有可解绑的对象，继续清 configfs 残留是安全的。
        if ! printf '\n' >"$G/UDC" 2>/dev/null; then
            [ ! -d "$UDCS/$bound" ] || return 1
        fi
    fi
    for link in os_desc/c.1 configs/c.1/rndis.usb0; do
        if [ -L "$G/$link" ]; then rm "$G/$link" || return 1; fi
    done
    # 只删本脚本拥有的对象；遇到额外函数/配置时失败，不 rm -rf configfs。
    for dir in functions/rndis.usb0 configs/c.1/strings/0x409 configs/c.1 strings/0x409; do
        if [ -d "$G/$dir" ]; then rmdir "$G/$dir" || return 1; fi
    done
    rmdir "$G"
}
finish() {
    rc=$?
    trap - 0
    if [ "$BUILDING" = 1 ]; then
        remove_tree || { echo 'usb-gadget: 回滚失败，保留现场供检查' >&2; rc=1; }
    fi
    exit "$rc"
}
trap finish 0
trap 'exit 130' INT
trap 'exit 143' TERM

# 装配/解绑串行化，避免两个 systemd/人工调用互相踩 configfs。
exec 9>"$LOCK"
flock -w 10 9 || fail '等待装配锁超时'

complete() {
    [ -n "$(value "$G/UDC" || true)" ] || return 1
    [ "$(value "$G/idVendor")" = 0x0525 ] || return 1
    [ "$(value "$G/idProduct")" = 0xa4a2 ] || return 1
    [ "$(value "$G/os_desc/use")" = 1 ] || return 1
    [ "$(value "$G/os_desc/b_vendor_code")" = 0xcd ] || return 1
    [ "$(value "$G/os_desc/qw_sign")" = MSFT100 ] || return 1
    [ "$(value "$G/functions/rndis.usb0/os_desc/interface.rndis/compatible_id")" = RNDIS ] || return 1
    [ "$(value "$G/functions/rndis.usb0/os_desc/interface.rndis/sub_compatible_id")" = 5162001 ] || return 1
    [ -L "$G/configs/c.1/rndis.usb0" ] || return 1
    [ -L "$G/os_desc/c.1" ] || return 1
    [ "$(readlink -f "$G/configs/c.1/rndis.usb0")" = "$G/functions/rndis.usb0" ] || return 1
    [ "$(readlink -f "$G/os_desc/c.1")" = "$G/configs/c.1" ] || return 1
    [ -d "$UDCS/$(value "$G/UDC")" ]
}
start() {
    [ -d "$CFG" ] || fail 'configfs 未挂载或 USB_CONFIGFS 不可用'
    bound=$(value "$G/UDC" || true)
    if [ -n "$bound" ]; then
        if complete; then
            echo "usb-gadget: 已装配（UDC=$bound）"
            return
        fi
        # 两种可能：
        #   1) 有别的 gadget 占着、配置与期望不符 → 不该擅自拆
        #   2) 内核侧已解绑但 configfs 的 UDC 属性仍留着旧名字
        #      （configfs_composite_unbind 不清 udc_name）→ 这是"断开后
        #      不恢复"的典型状态，必须允许重建
        # 判据：该 UDC 目录是否还存在。不存在 = 内核侧确实已无此 UDC，
        # 清掉残留对象重建是安全的。
        if [ -d "$UDCS/$bound" ]; then
            fail '已有绑定 gadget 与期望配置不一致；请先明确停止'
        fi
        echo "usb-gadget: UDC $bound 已不存在，清理残留后重建" >&2
    fi
    # 清理上次失败留下的未绑定对象，再按同一份描述符重新构建。
    remove_tree || fail '无法清理未绑定 gadget'
    # 最多等 30 秒。TimeoutStartSec=60 留出一半余量；之前只等 10 秒，
    # 慢速启动时脚本会先于 systemd 超时自己放弃，触发一次无谓的重启。
    udc=
    for _ in $(seq 1 60); do
        for path in "$UDCS"/*; do
            [ -d "$path" ] || continue
            udc=${path##*/}; break
        done
        [ -z "$udc" ] || break
        sleep 0.5
    done
    [ -n "$udc" ] || fail '无 UDC（USB 控制器未就绪）'
    BUILDING=1
    mkdir "$G"
    write_attr idVendor 0x0525
    write_attr idProduct 0xa4a2
    write_attr bcdDevice 0x0100
    write_attr bcdUSB 0x0200
    mkdir "$G/strings/0x409"
    write_attr strings/0x409/manufacturer OpenStick
    write_attr strings/0x409/product 'USB Network Gadget'
    serial=ufi$(uname -n | tr -cd '0-9a-z' | head -c 8)
    write_attr strings/0x409/serialnumber "$serial"
    mkdir "$G/configs/c.1"
    mkdir "$G/configs/c.1/strings/0x409"
    write_attr configs/c.1/strings/0x409/configuration 'RNDIS Network'
    # configfs 单位 mA。500 是 USB 2.0 单个配置允许的上限；带电池机型
    # （MF32/MF601SL）充电时功耗会超过 200mA，声明过低时严格的 hub 可能限流。
    write_attr configs/c.1/MaxPower 500
    mkdir "$G/functions/rndis.usb0"
    ln -s "$G/functions/rndis.usb0" "$G/configs/c.1/rndis.usb0"
    write_attr os_desc/use 1
    write_attr os_desc/b_vendor_code 0xcd
    write_attr os_desc/qw_sign MSFT100
    write_attr functions/rndis.usb0/os_desc/interface.rndis/compatible_id RNDIS
    write_attr functions/rndis.usb0/os_desc/interface.rndis/sub_compatible_id 5162001
    ln -s "$G/configs/c.1" "$G/os_desc/c.1"
    write_attr UDC "$udc"
    complete || fail '绑定后配置核验失败'
    BUILDING=0
    echo "usb-gadget: 已绑定 $udc（rndis.usb0）"
}
case "${1:-start}" in
start) start ;;
stop) remove_tree || fail '解绑/删除失败'; echo 'usb-gadget: 已卸载' ;;
status)
    if complete; then echo "active UDC=$(value "$G/UDC")"
    else echo inactive; exit 3; fi
    ;;
*) echo 'usage: usb-gadget.sh start|stop|status' >&2; exit 2 ;;
esac
