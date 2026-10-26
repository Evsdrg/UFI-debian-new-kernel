# OpenStick

为 **MSM8916（高通 410）设备**构建 Debian 13 arm64 系统与 Linux 内核。
目前主要支持 Handsome OpenStick USB 4G 上网棒，也已加入 THWC MF601SL 电池型
4G MiFi 的板级支持。当前内核版本为 **7.2.9**。

项目包含设备树、内核补丁与配置、rootfs 构建脚本，以及刷机和实机验证文档。

## 支持情况

| 设备 | 当前状态 |
|---|---|
| **UFI103s / UFI003** | 主力机型。WiFi、4G、USB 网络共享、GPU、Venus、桌面均有对应变体；7.2.9 已整机刷入验证 |
| **UFI103s minimal** | 只保留 WiFi、USB 网络共享和 zram 的精简内核；已通过内存启动验证 |
| **THWC MF601SL_CT_V07** | 已提供设备树、内核与 rootfs 测试包；**尚未在本项目实机验证** |
| **THWC MF32_MB_V02** | 已提供设备树、内核、rootfs 和 LED/电源键测试包；**尚未在本项目实机验证** |
| **UFI001b / UFI001c / SP970 / UZ801** | 有设备树和 DTB，暂无 7.2.9 可刷镜像；本项目没有对应硬件 |

不同机型的验证范围并不相同，不能把某一机型的结果直接套到其它机型。
具体边界见[实机验收记录](docs/validation/README.md)。

## 主要功能

- Debian 13 arm64，默认简体中文，使用 NetworkManager 管理网络。
- 支持 WiFi、4G、蓝牙，以及 ModemManager / QMI 控制通道。
- 插入电脑后提供 **USB RNDIS 网卡**，设备地址为 `10.42.0.1`，可用于首次登录和网络共享。
- UFI103s 可选 Adreno GPU、Venus 硬件编解码、i3 桌面、xrdp 和推流。
- 提供 minimal 精简内核，减少不必要的驱动与功能。
- 发布镜像**不预置 WiFi 名称或密码**；首次通过 USB 登录后，再用 `nmtui` 或 `nmcli` 配网。

## 使用与构建

UFI103s 的可分发 boot 镜像位于 [`builds/`](builds/README.md)。
MF601SL 的构建与测试包说明见[板级文档](boards/thwc-mf601sl/README.md)。
rootfs 按目标设备和所需功能在本机构建；项目不分发设备的基带固件和 NV 校准数据。

**刷机前先备份。** 只允许修改 `boot` 与 `rootfs` 分区，不要修改 GPT、aboot、
modem 或 NV。具体操作见[刷机指南](docs/hardware/FASTBOOT.md)，不同机型还应先读对应的
[`boards/`](boards/README.md) 说明。

典型首次登录方式：

```sh
ssh root@10.42.0.1
# 登录后配置 WiFi
nmtui
```

自行构建、选择内核变体和 rootfs 档位，请从[构建文档](docs/build/README.md)开始。
修改代码前请阅读[贡献须知](CONTRIBUTING.md)，其中记录了分区保护、驱动、
设备树和构建方面的限制。

## 文档导航

| 内容 | 文档 |
|---|---|
| 刷机、回退与分区注意事项 | [刷机指南](docs/hardware/FASTBOOT.md) |
| 内核变体、rootfs 档位与构建方法 | [构建文档](docs/build/README.md) |
| 各硬件子系统的能力与限制 | [硬件文档](docs/hardware/README.md) |
| MF601SL 设备树依据与未确认项 | [MF601SL 适配说明](docs/hardware/MF601SL.md) |
| 实机测试范围与结果 | [验收记录](docs/validation/README.md) |
| 相对上游的改动 | [改动清单](docs/CHANGES.md) |
| 已知问题与排查记录 | [问题清单](docs/ISSUES.md) |
| 给其他机主的测试、备份与反馈说明 | [分发文档](docs/dist/README.md) |
| 可分发 boot 镜像 | [产物说明](builds/README.md) |

## 许可

本项目自写的补丁、设备树、脚本和文档采用 **GPL-2.0-only**，见
[`LICENSE`](LICENSE) 与 [`NOTICE`](NOTICE)。
Qualcomm 固件和设备校准数据不在本项目的授权与分发范围内。
