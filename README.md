# OpenStick

面向 **MSM8916（高通 410）USB 4G 上网棒** 的 Debian 13 (trixie) arm64 系统与
自编译 Linux 内核（当前 **7.2.9**）。把一根几十块钱的上网棒，做成一台能跑
Debian 的完整小电脑：带 GPU 硬件渲染、Venus 硬编解码、桌面与远程桌面、
USB 网络共享，并保留 4G 与 WiFi。

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

## 支持的机型

| 机型 | WiFi | 设备树 | 7.2.9 产物 | 状态 |
|---|---|---|---|---|
| **UFI103s / UFI003** | WCN3620 | 5 个功能组合 | 5 个 boot + 7 张 rootfs | 主力开发板，已整机刷入验收 |
| UFI001b | WCN3660b | 1 | 仅 DTB | 未出 7.2.9 镜像，无对应硬件 |
| UFI001c | WCN3660b | 1 | 仅 DTB | 同上 |
| SP970 | WCN3660b | 1 | 仅 DTB | 同上 |
| UZ801 | WCN3660b | 1 | 仅 DTB | 同上 |

后四块板 DTS 引脚定义继承自上游已验证项目，但本工作区没有对应硬件，因此只
产出 DTB、不出可刷镜像。UFI103s 的 5 个功能组合（WiFi/BT only、+4G、+Venus、
+Venus+4G、+Venus+4G+GPU）与档位配对见 [`docs/build/BUILD-MATRIX.md`](docs/build/BUILD-MATRIX.md)。

## 能力一览

- **WiFi**：wcn36xx，上行速率经补丁修复（6 → 45–50 Mbit/s）。详见 [`docs/hardware/NETWORK.md`](docs/hardware/NETWORK.md)
- **4G**：ModemManager + 蜂窝数据链（驱动与控制通道已验证；SIM 业务待实机）
- **GPU**：Adreno 306 render-only，freedreno `FD307`，非 llvmpipe。详见 [`docs/hardware/DESKTOP.md`](docs/hardware/DESKTOP.md)
- **硬编解码**：Venus H.264 / VP8 硬解、H.264 硬编（宽高须 32 对齐）。实测见 [`docs/hardware/VIDEO-CODEC.md`](docs/hardware/VIDEO-CODEC.md)
- **桌面 / 远程桌面**：i3 + xrdp，客户端用 `/sec:tls`
- **推流**：GPU 合成桌面 → Venus 硬编 → MPEG-TS/UDP，实测 1280×736 约 26–28 fps。见 [`docs/hardware/GPU-STREAMING.md`](docs/hardware/GPU-STREAMING.md)
- **USB 网络共享**：设备插 PC 即作 NAT 网关（`10.42.0.1/24`），NM 与 native 双路径均实测出网
- **LED / 蓝牙 / CPU 调频**：跨型号通用脚本；详见 [`docs/hardware/`](docs/hardware/)

## 当前状态

**最新实机验收（2026-10-16）**：7.2.9 已整机刷入 UFI103s，验证通过 22 项、
已知限制 6 项、失败 1 项（Venus MPEG-4 固件 bug，7.1.13 同样复现，非回归）。
USB 共享全链、编解码、推流、xrdp+i3、无 WiFi 开箱即用均通过。
**散热仍是限制项**（满载约 45–160 秒触 80°C 保护），不能宣称长稳满载。

完整数据与保留风险见 [`docs/validation/VALIDATION-2026-10-16.md`](docs/validation/VALIDATION-2026-10-16.md)。

## 仓库结构

```
openstick/
├── CONTRIBUTING.md      ★ 动手前必读：硬约束、平台限制、常见坑
├── docs/                专题文档
│   ├── CHANGES.md       改动清单（相对上游改了什么）
│   ├── ISSUES.md        问题清单（已定案的坑 + 尚未闭环的问题）
│   ├── build/           构建矩阵 / 精简档位 / 工具清单
│   ├── hardware/        各硬件子系统的能力与踩坑
│   └── validation/      实机验收报告
├── boards/              各机型设备树源码（只放 DTS）
├── source/              共享源码：内核树、补丁、配置、共享 dtsi
│   └── kernel-version.env  ★ 内核版本单一事实来源（升级只改这里）
├── artifacts/           ★ 所有产物（boot / rootfs / modules / dtb / firmware）
├── tools/               构建与验证脚本
├── recovery/            分区读回与刷机证据（不可再生，勿删）
├── edl-tools/           EDL / Miko 刷机工具链
├── ufi00x-mainline/     分发仓（独立 git，父仓 .gitignore 排除）
└── build/ out/          构建中间态与验证记录（不入库）
```

分工原则：`boards/` 放**源码**（每板不同的 DTS），`source/` 放**共享源码**，
`artifacts/` 放**全部产物**。脚本不拼 `artifacts/...` 字面路径，一律用
`tools/kver.sh` / `kver.py` 派生的变量（详见 [`artifacts/README.md`](artifacts/README.md)）。

## 开始使用

**构建**（内核 + 模块 + rootfs 全链）：

```sh
# 五个板型的内核、模块树与 boot 镜像（表驱动，缺省只建未完成的）
bash tools/build-board-set.sh

# 7 张 rootfs（四档 × 双栈）
bash tools/build-matrix.sh

# 布局与产物自检（应 exit 0）
bash tools/verify-layout.sh
```

**刷机**：只能动 `boot`（p12）与 `rootfs`（p14）两个分区，不动 GPT / aboot /
modem / NV。刷任何分区前**必须先有分区级读回备份**。进 fastboot 用
`systemctl reboot --reboot-argument=bootloader`。完整流程、镜像校验与回退见
[`docs/hardware/FASTBOOT.md`](docs/hardware/FASTBOOT.md)。

**首次进系统**：设备插电脑 → 自动出现 USB 网卡并拿到 `10.42.0.x` →
`ssh root@10.42.0.1` 登录 → `nmtui` 配无线。

## 许可

**GPL-2.0-only**。`LICENSE` 是 GPL-2.0 全文（与内核树 `LICENSES/preferred/GPL-2.0`
正文逐字节一致），`NOTICE` 说明覆盖范围。覆盖范围：`source/patches/` 的内核补丁、
本项目自写的设备树 / 脚本 / 文档。**不覆盖也不包含** Qualcomm 固件与每台机器唯一
的校准值（NV/modem）——那些从你自己的设备导出，按其原始条款使用。

## 文档索引

| 我想… | 看 |
|---|---|
| 在这个仓库里干活（硬约束、平台限制、改过什么） | [`CONTRIBUTING.md`](CONTRIBUTING.md) |
| 知道相对上游改了什么 | [`docs/CHANGES.md`](docs/CHANGES.md) |
| 查某个坎是怎么过的 | [`docs/ISSUES.md`](docs/ISSUES.md) |
| 选档位 / 看构建矩阵 | [`docs/build/`](docs/build/) |
| 调某个硬件子系统 | [`docs/hardware/`](docs/hardware/) |
| 看实机验收数据 | [`docs/validation/`](docs/validation/) |
