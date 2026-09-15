# 非 NM 网络栈资产（F2/F3/F4 的 native 变体）

回归 systemd-networkd + wpa_supplicant 的老方案（当年迁移到 NM 的原因、
以及全部坑，见 ../NETWORK.md）。设计要点：

- wpa_supplicant：全局服务 + `/etc/wpa_supplicant/wpa_supplicant.conf`
  （构建时预置凭据；不再用会抢网卡的每接口 `wpa_supplicant@` 实例）
- systemd-networkd：wlan0 DHCP、usb0 静态 10.42.0.1/24、wwan0 DHCP
- DNS + DHCP(USB)：dnsmasq 一个实例包办（监听 usb0，DNS 转发公共服务器）
- NAT：nftables masquerade（NF_TABLES=m 内核配置已有）
- 4G（仅 F2）：ModemManager + mmcli 拨号脚本 → networkd 对 wwan0 DHCP

文件清单（build-rootfs.sh 的 native 变体按此装入）：
  10-usb0.network      USB 共享口：10.42.0.1/24 + ip_forward
  20-wlan0.network     Wi-Fi DHCP
  25-wwan0.network     4G DHCP（F2）
  wpa_supplicant.conf  凭据模板（构建时填入）
  dnsmasq.conf         usb0 上的 DHCP + DNS
  nat.nft              nftables masquerade 表
  native-net.service   启动 dnsmasq + nft + ip_forward 的 oneshot
