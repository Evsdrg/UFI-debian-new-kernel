#!/bin/sh
# native（非 NM）档的 4G 数据会话：ModemManager simple-connect。
# APN 在 /etc/default/mm-connect 里配置（APN=cmnet 等）；缺省用空 APN
# （多数国内运营商物联网卡可免 APN 或自动）。
[ -r /etc/default/mm-connect ] && . /etc/default/mm-connect
APN_ARG=""
[ -n "${APN:-}" ] && APN_ARG="apn=${APN},"

echo "== 拨号（APN=${APN:-<空>}）=="
mmcli -m any --simple-connect="${APN_ARG}ip-type=ipv4" || exit 1
sleep 2
echo "== 数据接口状态 =="
ip -br addr show wwan0 2>/dev/null || ip -br addr | grep -E "wwan" || echo "(无 wwan 接口)"
echo "如未拿到地址：systemd-networkd 会对 wwan0 跑 DHCP（25-wwan0.network）"
