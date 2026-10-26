# native 网络栈资产

`build-rootfs.sh` 的 basic/slim/micro-native 档按本目录装配：

- `wpa_supplicant@wlan0` + `/etc/wpa_supplicant/wpa_supplicant-wlan0.conf`。
- systemd-networkd：wlan0 DHCP、usb0 固定 `10.42.0.1/24`；basic-native 另带 wwan0 配置。
- `usb-gadget.service` 先创建 usb0，再拉起 `native-net.service`（native 专用 drop-in）。
- native-net 有界等待 USB IPv4 地址，然后原子加载自己的 `inet openstick_usb` 表。
- dnsmasq 前台运行，由 systemd 守护；启动前检查配置，异常退出会重启，反复失败会限流。
- 停止/启动失败后只清理自己的 nft 表，不关闭系统共享的全局 forwarding，不清空其它表。

`nat.nft` 只对 USB 子网发起的 IPv4 流量做 NAT，由默认路由选择上游；允许已建立的
返回流量，拒绝其它到 USB 的转发。两套网络栈均需要 nft CT/reject 支持与 nftables 包。
全局 `dnsmasq.service` 被 mask，防止另起实例占用端口。

文件：

| 文件 | 安装位置/用途 |
|---|---|
| `10-usb0.network` | `/etc/systemd/network/`，USB 地址与 forwarding |
| `20-wlan0.network` | WiFi DHCP |
| `25-wwan0.network` | basic-native 的蜂窝地址配置 |
| `dnsmasq.conf` | `/etc/dnsmasq.d/usb-share.conf`，USB DHCP/DNS |
| `nat.nft` | `/etc/nftables.d/nat.nft`，幂等替换自己的表 |
| `usb-share.sh` | `/usr/local/sbin/usb-share-native.sh`，有界准备/清理 |
| `native-net.service` | `/etc/systemd/system/`，监督前台 dnsmasq |

回归：`python3 tools/test-usb-sharing.py`、`python3 tools/verify-usb-sharing.py`。
实机证据与范围见 `../../docs/validation/2026-10-10-usb-fix.md`；QEMU 无真实 USB gadget，不能替代 NAT 验收。
`mm-connect.sh` 的实际蜂窝拨号/DHCP行为仍需有 SIM 后单独验证。
