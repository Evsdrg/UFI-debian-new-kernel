# 分发产物

本目录存放**可直接刷入的 boot 镜像**与配套的 `wcn36xx.ko`，以及它们的元数据。
只含 Linux **7.2.9** 产物。

```
builds/boot/<variant>/    一个 boot 镜像 + 同 vermagic 的 wcn36xx.ko + build.json
builds/README.md          本文件
```

主仓库其余部分（内核源码、设备树、构建脚本）不跟踪 `*.img` / `*.ko`——见根
`artifacts/README.md` 的入库规则。本目录是**唯一**跟踪镜像的地方，因为它们本身就
是分发内容。

## 变体

六个变体，都是 ufi103s。`ufi001b` / `ufi001c` / `sp970` / `uz801` 不在这里：主仓
保留了它们的设备树，但没有对应的 7.2.9 boot 镜像，本仓不为"指不出内核"的产物背书。

| 目录 | kernel release | 在 WiFi/BT 之上增加什么 |
|---|---|---|
| `ufi103s-baseline` | `7.2.9-ufix0x-dirty` | 无 |
| `ufi103s-4g` | `7.2.9-ufix0x-4g-dirty` | 4G |
| `ufi103s-venus` | `7.2.9-ufix0x-venus-dirty` | Venus |
| `ufi103s-venus-4g` | `7.2.9-ufix0x-venus-4g-dirty` | Venus + 4G |
| `ufi103s-venus-4g-gpu` | `7.2.9-ufix0x-venus-4g-gpu-dirty` | Venus + 4G + GPU |
| `ufi103s-minimal` | `7.2.9-ufix0x-minimal-dirty` | **反向裁剪**：只留 WiFi + USB 共享 + zram |

最后一行是特例：其余五个变体之间是**增加设备树功能**，而 `minimal` 保留基线
（WiFi-only）设备树、改为裁剪**内核配置本身**——去掉 SCSI/MTD/ATA/NVMe、其它
SoC 的 pinctrl/clk/interconnect 驱动、无关文件系统、蓝牙、多媒体。它面向
`slim` / `micro` rootfs 档位（这些链本来就用不上）。实机实测：boot 镜像
5.94 MB vs 8.00 MB，模块 460 vs 696；`MemTotal` 与 `ufi103s-baseline` 相同
（那里约 +97 MB 的收益来自设备树，不是内核配置）。详见主仓
`docs/build/BUILD-MATRIX.md`。

两个依赖必须保持开启，否则内核会静默死掉——`QCOM_APCS_IPC`（它管着
`QCOM_CLK_APCS_MSM8916`，msm8916 的 CPU 时钟控制器）与 `INPUT_KEYBOARD`
（设备树里 `gpio-keys` 的 Reset 键在它后面）。这两个坑的完整记录见主仓
`docs/ISSUES.md`。

release 令牌是 `-ufix0x`（家族名，2026-09-30 起；更早是单板名 `-ufi103s`，
再早是 PCB 号 `-ufi003`）。为某个 release 编译的模块不能加载到另一个上——见
下面的 vermagic。

## 模块与 boot 镜像不是一回事

每个目录同时放两个文件，因为它们必须成对使用；放在一起也正是为了防止把
venus 的模块说成基线内核的模块。但它们的安装方式不同：

- `.img` 是 Android legacy boot 镜像（header v0，page 2048）：内核 + 追加的
  设备树。**不含任何模块**。
- `wcn36xx.ko` 是 WiFi 修复。它只能加载到该目录 `build.json` 里记录的那个
  `vermagic` 上。刷 `.img` 不会安装它。

`tools/dist/install-module.sh` 会校验 vermagic，不匹配就拒绝安装。

## 刷入状态（务必先读）

| 变体 | 状态 |
|---|---|
| `ufi103s-venus-4g-gpu` | **已刷入**作者机器（p12，2026-10-16）并从闪存启动：分区头哈希等于本镜像 sha256，首启自动开 USB RNDIS、无预置 WiFi |
| `ufi103s-minimal` | 2026-10-17 `fastboot boot` **内存启动**（未写 p12）：WiFi 关联、USB RNDIS 真实 NAT 出网、zram zstd、8 个 LED、gpio-keys Reset 键、32 MB 传输均通过 |
| 其余四个 | 未在硬件上启动 |

一个变体在一台机器上刷入，**不能**替其它变体或其它机器背书。每个目录的
`STATUS.txt`（若存在）会被 `tools/dist/gen-manifest.sh` 读进 `build.json` 的
`status` 字段；没有 `STATUS.txt` 的用通用说明。

## Cmdline

镜像的 `root=` 有两种写法，看各自 `build.json` 的 `cmdline`：

- **本目录的 UFI103s 镜像**：`root=PARTUUID=a7ab80e8-e9d1-e8cd-f157-93f69b1d141e`。
  那是作者机器 GPT 里 p14 的 GUID，换机器要改。
- **其它板型**：以各自 `build.json` 的 `cmdline` 为准；MF601SL 当前使用
  `root=/dev/mmcblk0p14`，不依赖 GPT UUID。

刷之前先读 `build.json` 里的 `cmdline`，那是该镜像的实际值。

## 刻意不含的东西

- 不含 rootfs。为某台机器构建的 rootfs 会带上那台机器的 WiFi 校准数据。
- 不含固件与校准 blob。
- 不含旧内核产物。
- 不含四块 WCN3660B 板的 boot 镜像。

`tools/dist/gen-manifest.sh` 会从目录里的文件重写每个 `build.json`（哈希、
vermagic、cmdline）。它不会编造 kernel release。
