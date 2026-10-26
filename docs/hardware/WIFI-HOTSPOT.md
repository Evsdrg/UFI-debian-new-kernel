# WiFi 热点（AP）实现调研

> 状态：源码与配置路径调研，**尚未完成实机热点验证**。
> 当前发布镜像仍只实现 WiFi STA，不会自动创建热点。

## 驱动能力

本机使用的 WCN3620 由 mainline `wcn36xx` 驱动。7.2.9 源码中有明确的 AP 路径：

- `main.c` 的 `wcn36xx_add_interface()` 接受 `NL80211_IFTYPE_AP`。
- `wiphy->interface_modes` 包含 `NL80211_IFTYPE_AP`。
- `smd.c` 有 `WCN36XX_HAL_INFRA_AP_MODE` 与 `WCN36XX_HAL_STA_SAP_MODE`。
- beacon、BSS、STA 与 CCMP 加密路径均存在。

因此不能把当前没有热点归因于“驱动完全不支持 AP”。但最终能力仍需在设备上用
`iw list` 和真实客户端连接验证，尤其要检查固件行为。

## 用户态方案

优先使用现有 NetworkManager，不另起一套 hostapd/networkd 配置：

```ini
[connection]
type=wifi
autoconnect=true

[wifi]
mode=ap
ssid=<由用户设置>
band=bg

[wifi-security]
key-mgmt=wpa-psk
psk=<由用户设置>

[ipv4]
method=shared
address1=<独立的 AP 网段>

[ipv6]
method=ignore
```

NM 会通过 wpa_supplicant 建立 AP，并在 `ipv4.method=shared` 下处理 DHCP、
DNS 和 NAT。WCN3620 只有 2.4GHz，不能用 5GHz 作为首版前提。

## 与 USB RNDIS 的冲突

当前 `usb-share.nmconnection` 使用：

```text
10.42.0.1/24
```

WiFi AP 如果也直接使用 NM shared 的默认地址，会出现两个相同网段。
**AP 必须使用独立网段**，或者另行设计桥接。首版建议保留 USB 网段不变，
给 AP 单独分配地址，不在没有实测的情况下引入桥接复杂度。

## 上行与并发边界

首版应按 **4G 上行 + WiFi AP 下行**设计，USB RNDIS 作为管理和备用链路。

驱动源码没有声明 STA+AP 的 `iface_combinations`，因此不能承诺“设备一边连接
别的热点、一边再发射热点”。AP+STA 并发必须单独实测，不能作为默认能力。

## 默认配置与发布约束

公开镜像目前不预置 WiFi SSID、密码或自动连接配置。自动热点也不能简单写成
所有设备相同的公开凭据后就当成完成。

建议提供热点配置工具：用户先通过 USB 登录，设置自己的 SSID 与密码，生成
`autoconnect=true` 的 AP profile；之后的启动才自动开启热点。这样既满足后续
自动启用，也不把固定 WiFi 凭据塞进公开镜像。

## 实机验收清单

1. `iw list` 确认 AP 模式和接口组合。
2. 创建 AP 后，外部客户端能扫描到 SSID 并完成 WPA2 关联。
3. 客户端能获得 AP 网段地址、网关和 DNS。
4. 只有该 AP 网卡的隔离客户端能通过设备访问真实上游，验证不是本机绕过 NAT。
5. USB RNDIS 同时仍可使用 `10.42.0.1` 管理，两个网段无冲突。
6. 重启后 AP 自动恢复；4G 未注册或断开时，热点本身仍可登录管理。
7. 验证客户端断开重连、多个客户端、长时间运行和固件错误后的恢复。
8. 单独测试 STA+AP 并发；未通过前不写入支持清单。
