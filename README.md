# OpenStick

面向 **MSM8916（高通 410）USB 4G 上网棒** 的 Debian 13 (trixie) arm64 系统与
自编译 Linux 内核（当前 **7.2.9**）。把一根几十块钱的上网棒，做成一台能跑
Debian 的小电脑：WiFi、4G、USB 网络共享、GPU 硬件渲染、Venus 硬编解码、
桌面与远程桌面。

目标机型是 Handsome OpenStick 家族：**UFI103s / UFI003 / UFI001b / UFI001c /
SP970 / UZ801**。每型有专属设备树标识（`compatible` 各不相同，`model` 写明型号），
不靠共用字符串区分。

## 它是什么

| | |
|---|---|
| **硬件** | MSM8916（4× Cortex-A53）、376 MB 内存 / 32 MB CMA、Adreno 306 GPU（render-only）、Venus 1.8 编解码 |
| **系统** | Debian 13 arm64，默认简体中文（`zh_CN.UTF-8`），NetworkManager 管网络 |
| **内核** | 自编译 Linux 7.2.9 + 4 个本地补丁（3 个 WiFi 上行速率/诊断 + 1 个 Venus 编码修复） |
| **产物** | 各板 boot 镜像（内核 + 追加 DTB）＋ 共享 rootfs（max/basic/slim/micro 四档 × NM/native 双网络栈 = 7 张） |

根文件系统**不预置任何 WiFi 凭据**：设备插到电脑上会自动作为 USB 网卡（RNDIS）
出现，电脑拿到 `10.42.0.x` 即可登录管理；配无线用 `nmtui` / `nmcli`。
这样无屏设备开箱即可用，也避免凭据被静默写坏后刷完失联。

## 快速上手

以主力机型 **UFI103s** 为例（其余四块板目前只有设备树，见下表）。

**1. 选一个变体。** 日常用 `venus-4g-gpu`（功能最全）；只要 WiFi + USB 共享 +
内存最大化，选 `minimal`。变体与档位配对见
[`docs/build/BUILD-MATRIX.md`](docs/build/BUILD-MATRIX.md)。

**2. 拿到镜像。** 可直接用本仓 [`builds/`](builds/README.md) 里的 7.2.9 boot
镜像；或自己构建（见下「构建」）。rootfs 需本机构建，不随仓分发
（它带设备相关校准数据）。

**3. 备份再刷机。** 先用 Miko 做整片 eMMC 全量备份（**必做**，见
[`docs/dist/backup-and-restore.md`](docs/dist/backup-and-restore.md)）。
只动 `boot`（p12）与 `rootfs`（p14）两个分区，**不动** GPT / aboot / modem / NV。
刷机命令与坑见 [`docs/hardware/FASTBOOT.md`](docs/hardware/FASTBOOT.md)。

**4. 插电脑进系统。** 设备插入电脑 USB 口，会自动出现 RNDIS 网卡，
电脑拿到 `10.42.0.x` 后：

```sh
ssh root@10.42.0.1
```

**5. 配无线。** `nmtui`（中文界面）或
`nmcli device wifi connect <SSID> password <PSK>`。
之后设备即可作为 NAT 网关给电脑共享网络。

## 支持的机型

| 机型 | WiFi | 设备树 | 7.2.9 产物 | 状态 |
|---|---|---|---|---|
| **UFI103s / UFI003** | WCN3620 | 5 个功能组合 + minimal | 6 个 boot + 7 张 rootfs | 主力开发板，已整机刷入验收 |
| UFI001b | WCN3660b | 1 | 仅 DTB | 未出 7.2.9 镜像，无对应硬件 |
| UFI001c | WCN3660b | 1 | 仅 DTB | 同上 |
| SP970 | WCN3660b | 1 | 仅 DTB | 同上 |
| UZ801 | WCN3660b | 1 | 仅 DTB | 同上 |

后四块板 DTS 引脚定义继承自上游已验证项目，但本工作区没有对应硬件，因此只
产出 DTB、不出可刷镜像。UFI103s 的 5 个功能组合（WiFi/BT only、+4G、+Venus、
+Venus+4G、+Venus+4G+GPU）与档位配对见 [`docs/build/BUILD-MATRIX.md`](docs/build/BUILD-MATRIX.md)。
另有 **`minimal`** 变体：设备树同 WiFi-only 基线，但**内核配置**再裁一档，
只留 WiFi + USB 共享 + zram，供 slim / micro 档位（内存最大化）使用。

## 能力一览

- **WiFi**：wcn36xx，上行速率经补丁修复（6 → 45–50 Mbit/s）。详见 [`docs/hardware/NETWORK.md`](docs/hardware/NETWORK.md)
- **4G**：ModemManager + 蜂窝数据链（驱动与控制通道已验证；SIM 业务待实机）
- **GPU**：Adreno 306 render-only，freedreno `FD307`，非 llvmpipe。详见 [`docs/hardware/DESKTOP.md`](docs/hardware/DESKTOP.md)
- **硬编解码**：Venus H.264 / VP8 硬解、H.264 硬编（宽高须 32 对齐）。实测见 [`docs/hardware/VIDEO-CODEC.md`](docs/hardware/VIDEO-CODEC.md)
- **桌面 / 远程桌面**：i3 + xrdp，客户端用 `/sec:tls`
- **推流**：GPU 合成桌面 → Venus 硬编 → MPEG-TS/UDP，实测 1280×736 约 26–28 fps。见 [`docs/hardware/GPU-STREAMING.md`](docs/hardware/GPU-STREAMING.md)
- **USB 网络共享**：设备插 PC 即作 NAT 网关（`10.42.0.1/24`），NM 与 native 双路径均实测出网
- **LED / 蓝牙 / CPU 调频**：跨型号通用脚本；详见 [`docs/hardware/`](docs/hardware/README.md)
- **minimal 内核**：裁到只剩 WiFi / USB 共享 / zram，boot 镜像 −26%、模块 −34%
  （`MemTotal` 的 +97 MB 来自设备树，非内核配置）。见 [`docs/build/BUILD-MATRIX.md`](docs/build/BUILD-MATRIX.md)

## 当前状态

**最新实机验收（2026-10-16 整机刷入；2026-10-17 补 minimal）**：7.2.9 已整机
刷入 UFI103s，验证通过 22 项、已知限制 6 项、失败 1 项（Venus MPEG-4 固件 bug，
7.1.13 同样复现，非回归）。USB 共享全链、编解码、推流、xrdp+i3、
无 WiFi 开箱即用均通过；`minimal` 变体 RAM 验证（WiFi/USB 共享 NAT/zram/
LED/Reset 键）通过。**散热仍是限制项**（满载约 45–160 秒触 80°C 保护），
不能宣称长稳满载。

完整数据与保留风险见 [`docs/validation/2026-10-16-validation.md`](docs/validation/2026-10-16-validation.md)。

## 仓库结构

```
openstick/
├── CONTRIBUTING.md      ★ 动手前必读：硬约束、平台限制、常见坑
├── docs/                专题文档
│   ├── CHANGES.md       改动清单（相对上游改了什么）
│   ├── ISSUES.md        问题清单（已定案的坑 + 尚未闭环的问题）
│   ├── build/           构建矩阵 / 精简档位 / 工具清单
│   ├── hardware/        各硬件子系统的能力与踩坑
│   ├── validation/      实机验收报告（按日期归档）
│   └── dist/            对机主分发：测试、备份、回报、重编
├── boards/              各机型设备树源码（只放 DTS）
├── source/              共享源码：内核树、补丁、配置、共享 dtsi
│   └── kernel-version.env  ★ 内核版本单一事实来源（升级只改这里）
├── artifacts/           ★ 构建产物（boot / rootfs / modules / dtb / firmware）
├── builds/              ★ 可分发镜像集（7.2.9 boot + wcn36xx.ko，入库）
├── tools/               构建与验证脚本（tools/dist/ 是分发侧工具）
├── recovery/            分区读回与刷机证据（不可再生，勿删）
├── edl-tools/           EDL / Miko 刷机工具链
└── build/ out/          构建中间态与验证记录（不入库）
```

分工原则：`boards/` 放**源码**（每板不同的 DTS），`source/` 放**共享源码**，
`artifacts/` 放**全部构建产物**。脚本不拼 `artifacts/...` 字面路径，一律用
`tools/kver.sh` / `kver.py` 派生的变量（详见 [`artifacts/README.md`](artifacts/README.md)）。
`builds/` 是唯一入库的二进制产物（它们本身就是交付内容）。

## 构建

```sh
# 六个板型的内核、模块树与 boot 镜像（表驱动，缺省只建未完成的）
bash tools/build-board-set.sh

# 7 张 rootfs（四档 × 双栈）
bash tools/build-matrix.sh

# 布局与产物自检（应 exit 0）
bash tools/verify-layout.sh
```

刷机用 `flash.sh fastboot-flash`（会先比对 `build.json` 的 sha256）。
进 fastboot 用 `systemctl reboot --reboot-argument=bootloader`。

## 许可

**GPL-2.0-only**。`LICENSE` 是 GPL-2.0 全文（与内核树 `LICENSES/preferred/GPL-2.0`
正文逐字节一致），`NOTICE` 说明覆盖范围。覆盖范围：`source/patches/` 的内核补丁、
本项目自写的设备树 / 脚本 / 文档。**不覆盖也不包含** Qualcomm 固件与每台机器唯一
的校准值（NV/modem）——那些从你自己的设备导出，按其原始条款使用。

## 文档索引

| 我想… | 看 |
|---|---|
| 快速上手（选变体/刷机/进系统） | 上文「快速上手」 |
| 在这个仓库里干活（硬约束、平台限制、改过什么） | [`CONTRIBUTING.md`](CONTRIBUTING.md) |
| 知道相对上游改了什么 | [`docs/CHANGES.md`](docs/CHANGES.md) |
| 查某个坎是怎么过的 | [`docs/ISSUES.md`](docs/ISSUES.md) |
| 选档位 / 看构建矩阵 | [`docs/build/`](docs/build/README.md) |
| 调某个硬件子系统 | [`docs/hardware/`](docs/hardware/README.md) |
| 看实机验收数据 | [`docs/validation/`](docs/validation/README.md) |
| 给别的机主测 / 备份 / 回报 / 重编 | [`docs/dist/`](docs/dist/README.md) |
| 拿现成的可刷镜像 | [`builds/`](builds/README.md) |
