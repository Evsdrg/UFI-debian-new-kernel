#!/bin/sh
# USB 网络共享 gadget 装配（configfs + RNDIS）
#
# 把设备的 USB 口变成 RNDIS 网卡：Windows / Linux / macOS 免驱识别，
# 配合 NM 的 shared 连接（或 native 档的 dnsmasq+nftables），设备向 PC
# 共享网络，网关 10.42.0.1/24。
#
# 内核要求：CONFIG_USB_CONFIGFS / CONFIG_USB_F_RNDIS / CONFIG_CONFIGFS_FS
# 全部内建（common-*-os.config 已设）。
#
# 用法：usb-gadget.sh start|stop|status
#
# Windows 兼容说明：写入 MS OS 描述符（compatible_id=RNDIS），Win8+ 免驱
# 直接认成 RNDIS 网卡，不需要 inf。

set -u

GADGET_NAME=openstick
VENDOR_ID=0x0525       # Linux-USB gadget 惯用厂商号（netchip）
PRODUCT_ID=0xa4a2      # Linux-USB Ethernet/RNDIS 惯用产品号
SERIAL=ufi$(uname -n 2>/dev/null | tr -cd '0-9a-z' | head -c 8)

CFG=/sys/kernel/config/usb_gadget
udc_fail() { echo "usb-gadget: $*" >&2; exit 1; }

wait_udc() {
    _try=0
    while [ ! -d /sys/class/udc ] || [ -z "$(ls /sys/class/udc 2>/dev/null)" ]; do
        _try=$((_try + 1))
        [ "$_try" -ge 20 ] && udc_fail "无 UDC（USB 控制器未就绪）"
        sleep 0.5
    done
    ls /sys/class/udc | head -1
}

mounted_configfs() {
    grep -q usb_gadget /proc/mounts 2>/dev/null
}

start() {
    [ -d "$CFG" ] || udc_fail "configfs 未挂载（检查 CONFIG_CONFIGFS_FS）"
    if [ -e "$CFG/$GADGET_NAME/UDC" ] && [ -s "$CFG/$GADGET_NAME/UDC" ]; then
        echo "usb-gadget: 已装配（UDC=$(cat "$CFG/$GADGET_NAME/UDC" 2>/dev/null)）"
        exit 0
    fi

    UDC=$(wait_udc)

    mkdir -p "$CFG/$GADGET_NAME" || udc_fail "无法创建 gadget"
    cd "$CFG/$GADGET_NAME" || exit 1

    echo "$VENDOR_ID"  > idVendor
    echo "$PRODUCT_ID" > idProduct
    echo 0x0100        > bcdDevice
    echo 0x0200        > bcdUSB           # USB 2.0

    mkdir -p strings/0x409
    echo "OpenStick"      > strings/0x409/manufacturer
    echo "USB Network Gadget" > strings/0x409/product
    echo "$SERIAL"        > strings/0x409/serialnumber

    # 配置 1：RNDIS（单配置，全平台通吃）
    mkdir -p configs/c.1/strings/0x409
    echo "RNDIS Network"  > configs/c.1/strings/0x409/configuration
    echo 200              > configs/c.1/MaxPower       # 2W，够网卡用

    mkdir -p functions/rndis.usb0
    ln -s functions/rndis.usb0 configs/c.1/

    # Windows 免驱：MS OS 描述符声明 RNDIS
    echo 1        > os_desc/use
    echo 0xcd     > os_desc/b_vendor_code
    echo "MSFT100" > os_desc/qw_sign
    echo 0x40     > functions/rndis.usb0/os_desc/interface.rndis/b_vendor_code
    echo "RNDIS"   > functions/rndis.usb0/os_desc/interface.rndis/compatible_id
    echo "5162001" > functions/rndis.usb0/os_desc/interface.rndis/sub_compatible_id
    ln -s configs/c.1 os_desc/c.1

    echo "$UDC" > UDC || udc_fail "绑定 UDC $UDC 失败"
    echo "usb-gadget: 已绑定 $UDC（rndis.usb0）"
}

stop() {
    if [ -e "$CFG/$GADGET_NAME/UDC" ]; then
        echo "" > "$CFG/$GADGET_NAME/UDC" 2>/dev/null || true
        # 解绑后 configfs 子树才可删
        rm -f "$CFG/$GADGET_NAME/os_desc/c.1" 2>/dev/null || true
        rm -f "$CFG/$GADGET_NAME/configs/c.1/rndis.usb0" 2>/dev/null || true
        rmdir "$CFG/$GADGET_NAME/functions/rndis.usb0" 2>/dev/null || true
        rmdir "$CFG/$GADGET_NAME/configs/c.1/strings/0x409" 2>/dev/null || true
        rmdir "$CFG/$GADGET_NAME/configs/c.1" 2>/dev/null || true
        rmdir "$CFG/$GADGET_NAME/strings/0x409" 2>/dev/null || true
        rmdir "$CFG/$GADGET_NAME" 2>/dev/null || true
    fi
    echo "usb-gadget: 已卸载"
}

status() {
    if [ -e "$CFG/$GADGET_NAME/UDC" ] && [ -s "$CFG/$GADGET_NAME/UDC" ]; then
        echo "active UDC=$(cat "$CFG/$GADGET_NAME/UDC")"
    else
        echo "inactive"
    fi
}

case "${1:-start}" in
    start)  start ;;
    stop)   stop ;;
    status) status ;;
    *) echo "usage: $0 start|stop|status" >&2; exit 2 ;;
esac
