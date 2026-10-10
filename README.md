# OpenStick 工作区

> **2026-10-10 实机验收与修复**：7.2.9 `venus-4g-gpu` 已RAM启动并验证回退，
> 未正式刷写。**USB NAT已完成修复，NM/native共享路径均实测出网**；持续负载
> 散热限制、MPEG-4固件错误仍未解决，不能称为全功能通过。
> 见 [USB修复回归](docs/validation/USB-FIX-7.2.9.md)、[原验收报告](docs/validation/VALIDATION-7.2.9.md)；
> 根因核对与踩坑记录见 [问题清单](docs/ISSUES.md)，改动面见 [改动清单](docs/CHANGES.md)。

面向 **MSM8916 高通 410 USB 棒** 的 Debian 13 (trixie) arm64 + 自编译
Linux **7.2.9** 工程。目标机型：Handsome OpenStick **UFI103s / UFI003 /
UFI001b / UFI001c / SP970 / UZ801**。

每个机型有**专属的设备树标识**（`compatible` 各不相同，`model` 写明具体型号），
不靠共用字符串区分。详见各板 README。

> **内核版本单一事实来源**：`source/kernel-version.env`。所有脚本从它派生
> 路径与 release 字符串，升级内核只改这一个文件。当前是 **7.2.9**，且**只保留
> 这一套**：6.18.49 与 7.1.13 的内核树、模块树、rootfs、boot 镜像都已于
> 2026-10-07 清理，回退靠 `recovery/` 与 `out/rollback/` 里的分区读回
> （见 `AGENTS.md` §1.2），不再靠并列的旧内核树。

> **旧文档已作废**：本工作区早期（9 月 2 日）的 README 把目标设备写成
> IPQ4019 + ath10k + 内核 5.15，那是拆机前的误判；实机是 MSM8916 + wcn36xx。
> 那份错误文档已随 2026-10-07 的历史归档清理移除（结论本身不变）。

> **先读哪个**：`AGENTS.md` 是给在这个仓库里干活的人/agent 看的——硬约束、
> 平台限制、以及我们相对上游做过的所有改动；下面这些专题文档讲的是具体怎么做。
> 违反 `AGENTS.md` 里的约束往往不会立刻报错，而是静默出错或把设备变砖。

## 目录结构

```
openstick/
├── README.md              本文件（结构与整体状态）
├── AGENTS.md              ★ 给 agent 的作业须知：硬约束、平台限制、我们做过的改动
├── docs/                  专题文档（按主题分组）
│   ├── CHANGES.md         改动清单：相对上游改了什么
│   ├── ISSUES.md          问题清单：已定案的踩坑 + 尚未闭环的问题
│   ├── build/             构建矩阵、精简档位、工具清单
│   │   ├── BUILD-MATRIX.md    设备 × 档位 × 网络栈矩阵与实施顺序
│   │   ├── TRIMMING.md        系统精简：max/basic/slim/micro 四档 × nm|native、QEMU 冒烟测试
│   │   └── TOOLING.md         工具清单与缺口
│   ├── hardware/          硬件能力与踩坑
│   │   ├── CPU-POWER.md       CPU 频率/电压/散热（含降压为何不可行）
│   │   ├── DESKTOP.md         桌面 / xrdp / GPU 硬件渲染（含实测与踩坑）
│   │   ├── GPU-STREAMING.md   GPU 渲染桌面 + Venus 推流（已端到端跑通，含实测与踩坑）
│   │   ├── VIDEO-CODEC.md     编解码实测数据
│   │   ├── NETWORK.md         网络（NetworkManager）与中文说明
│   │   ├── BLUETOOTH.md       蓝牙（内核侧就绪、装 bluez 即用，含实测）
│   │   ├── LED.md             LED 跨型号适配说明
│   │   └── FASTBOOT.md        fastboot 刷机（含实测数据与两个坑）
│   └── validation/        实机验收报告（2026-10-10）
│       ├── VALIDATION-7.2.9.md   无串口 RAM 预演：通过项与阻塞项
│       └── USB-FIX-7.2.9.md      USB 共享全链修复与回归
├── boards/                各机型产物，按硬件家族分组
│   ├── README.md          家族划分依据（含 DTS 逐字节 diff 表）
│   ├── ufi00x/            ufi103s-ufi003 / ufi001b / ufi001c
│   ├── sp970/
│   └── uz801/
│       └── <机型>/{dts,boot}/    该板的 DTS 与 boot 镜像
├── source/                共享源码
│   ├── kernel-version.env ★ 内核版本单一事实来源（升级只改这里）
│   ├── linux-7.2.9/       当前内核树（2.0G，一份，所有机型共用）
│   ├── patches/           内核补丁（权威，与分发仓逐字节一致）
│   ├── configs/           内核配置与片段（common-7.2.9-os.config + 变体片段）
│   └── dts/common/        共享 dtsi
├── shared/                板无关产物
│   ├── rootfs/            rootfs 镜像（ufi103s-7.2.9-<档>.ext4）
│   ├── modules/           内核模块树（7.2.9-ufix0x-*，五个板型各一棵）
│   └── firmware/          固件集（common / ufi103s-venus）
├── tools/                 构建与验证脚本
│   ├── kver.sh / kver.py  ★ 版本派生的 shell / Python 实现
│   └── desktop/           桌面与推流脚本
├── upstream/              上游参考树（HandsomeMod 等，只读参考）
├── edl-tools/             EDL / Miko 刷机工具链
├── recovery/              备份、原始分区读回、刷机证据（不可替代）
├── ufi00x-mainline/       分发仓（自带 git，父仓 .gitignore 排除）
└── build/ out/            构建与打包中间产物
```

**内部分工**：`boards/` 放“每个板子不同的东西”，`shared/` 放“所有板子
共用的东西”，`source/` 放“源码”。刷机包 = 某板的 boot 镜像 + 共享 rootfs。

## 各机型状态

| 机型 | 家族 | WiFi | DTS | 7.2.9 boot 镜像 | 实机验证 |
|---|---|---|---|---|---|
| UFI103s / UFI003 | ufi00x | WCN3620 | 5 个功能组合 | 5 个 | 仅 GPU 组合做过 7.2.9 RAM 验收，有阻塞项 |
| UFI001b | ufi00x | WCN3660b | 1 | 无 | 无 7.2.y 产物 |
| UFI001c | ufi00x | WCN3660b | 1 | 无 | 无 7.2.y 产物 |
| SP970 | sp970 | WCN3660b | 1 | 无 | 无 7.2.y 产物 |
| UZ801 | uz801 | WCN3660b | 1 | 无 | 无 7.2.y 产物 |

后四块板目前**只有 DTS，没有 7.2.y 的 boot 镜像**：它们 6.18.49 时代的产物
（只做过离线校验，从未刷入实机）已随 2026-10-07 的清理移除。要给它们出
7.2.9 镜像，需先跑 `tools/build-boot-images.sh` 或相应板型的构建。它们的
DTS 引脚定义继承自上游已验证项目，但本工作区没有对应硬件。

### UFI103s 的 5 个功能组合

2026-09-16 起，9 个实验变体（含 `oc12`、`venus-oc-100`、`venus-oc-burst`）
收敛为 5 个功能组合；CPU 超频（三档 OPP + 85°C 被动冷却）已全员化进公共
dtsi，不再占名字。每个组合一棵独立模块树（vermagic 含 release，不可混用）。

| DTS | 功能 | 对应 rootfs 档位 |
|---|---|---|
| `msm8916-handsome-openstick-ufi103s.dts` | WiFi/BT，4G 链与 venus 全关 | slim / micro |
| `…-ufi103s-4g.dts` | +4G | basic |
| `…-ufi103s-venus.dts` | +Venus 硬编解码，无 4G | （备用） |
| `…-ufi103s-venus-4g.dts` | +Venus +4G | （备用） |
| `…-ufi103s-venus-4g-gpu.dts` | +Venus +4G +GPU | max |

矩阵与配对规则的完整说明在 `docs/build/BUILD-MATRIX.md`。

## 关键事实

- **内核共享、DTB 不共享**：`Image.gz` 所有机型同一份，板间差异只在追加的
  DTB。所以不要跨机型复用 boot 镜像。
- **root 定位**：`boards/ufi00x/ufi103s-ufi003/boot/*-build.json` 记录每张
  boot 镜像的 cmdline，7.2.9 这批统一为
  `root=PARTUUID=a7ab80e8-e9d1-e8cd-f157-93f69b1d141e`。**这个 PARTUUID 只对
  本工程构建的 rootfs 成立**，刷别处的根文件系统要在 fastboot 时改 cmdline。
- **WiFi 上行速率**：核心修复是 `MAX_MEDIUM_TIME` 6000→20000（见
  `source/patches/0002`），6.18.49 上实测 6 → 44–50 Mbit/s；2026-10-10
  在 7.2.9 GPU 组合复测上行 49.24、下行 62.76 Mbit/s（非重新做补丁前后 A/B）。
  响应非单调，详见分发仓 `docs/wifi-tx-throughput.md`。
- **监管域**：镜像内已用 `update-alternatives` 固定为 upstream
  `regulatory.db`（含 `country CN`）。
- **网络栈是 NetworkManager**（不是早期的 networkd + wpa_supplicant）：用户可用
  `nmtui`/`nmcli` 交互配网，改网络不用重启。详见 `docs/hardware/NETWORK.md`。
- **系统默认简体中文**（`zh_CN.UTF-8`）：`nmcli`、`apt`、`man` 都有中文输出。
  注意 `network-manager-l10n`（NM 汉化）与 `man-db`（man 命令本身）必须显式
  安装，前者只是 NM 的 Recommends。详见 `docs/hardware/NETWORK.md`。
- **LED 脚本机型通用**：五机型的三颗状态灯语义一致、sysfs 名字一致，脚本按名字
  发现（失败时按颜色兜底），不需要按型号分支。详见 `docs/hardware/LED.md`。
- **桌面与远程桌面**：镜像默认带 i3 + xrdp（`ROOTFS_DESKTOP=1`），主机可用
  `xfreerdp`/`remmina` 连 3389。见 `docs/hardware/DESKTOP.md`。
- **桌面可实时推流**：GPU 合成桌面 → Venus 硬编 → MPEG-TS/UDP → 对端窗口全屏播放，
  已端到端跑通（1280x736@30，实测 26–28fps，延迟约 1 秒）。设备端
  `tools/desktop/ufi-stream-push.sh`，接收端 `ufi-stream-play.sh`。见
  `docs/hardware/GPU-STREAMING.md`。
- **GPU 可用但只出 render 节点**：Adreno 306 在主线是 a3xx 家族，设备无显示
  面板，所以用 `separate_gpu_kms=1` 走 render-only，得到 `/dev/dri/renderD128`
  与 freedreno（`FD307`）。**注意**：只有 `venus-4g-gpu` 这个板型的模块树里有
  `msm.ko`/`drm.ko`；拿纯 venus 板型的树去构建 rootfs，开机会静默退回 llvmpipe。
- **固件**：`shared/firmware/common/` 与 `ufi103s-venus/` 的差别只有多一个
  `qcom/venus-1.8/venus.mbn`（该固件也提供 Adreno 所需的 `a300_*.fw`）。
- **补丁只有一套**：`source/patches/` 与分发仓 `ufi00x-mainline/patches/`
  逐字节一致，共 **4 个**（3 个 wcn36xx + 1 个 venus）。原 `0004`
  （venus hfi_parser payload size）随 7.2.9 退场——上游已含该修复，再套会报
  `Reversed (or previously applied) patch detected`，依据与记录见同目录的
  `venus-backport-provenance.txt`。

## 验证

```sh
# 工作区布局与产物自检（默认校验 max 档镜像，可用 ROOTFS_IMAGE 换档）
bash tools/verify-layout.sh
ROOTFS_IMAGE=shared/rootfs/ufi103s-7.2.9-slim.ext4 bash tools/verify-layout.sh

# 分发仓自检（补丁可应用性、哈希、文档链接）
cd ufi00x-mainline
K=$(cd .. && . source/kernel-version.env && echo "$PWD/source/linux-$KERNEL_VERSION")
sh tools/check-repo.sh "$K"
```

`tools/verify-layout.sh` 现在应当全过（exit 0）。它默认校验 `max` 档镜像
（7.2.9 起 `ROOTFS_BASE` 指向它——它是功能最全的一张），覆盖：内核源码与配置、
共享模块树、rootfs 内容（chrony/rmtfs/rmtfs_mem）、**NetworkManager 已装且
networkd/wpa_supplicant 已移除**、**zh_CN locale 已生成**、**fstab 带
x-systemd.growfs**、LED 脚本与 unit、各板 boot 状态、Venus 三件套配套。

> 历史：重组前它会在最后一项报 `ufi-led-state.sh=MISSING`，因为当时
> `shared/rootfs/` 里几张镜像新旧不一（旧镜像没装 LED）。现在两张镜像都是
> 同一轮构建出来的（NetworkManager + 中文 + 通用 LED + growfs），这个不一致
> 已经消除。

## 刷机前必读

- **必须先做整片 eMMC 全量备份**（Miko 全盘 dump），再动手刷任何分区。
  注意这条目前**无法脚本化**：Miko 是 Windows GUI 工具，仓库里能依赖的是
  `recovery/backups/` 的分区级读回。动手前先确认目标分区有对应副本
  （见 `AGENTS.md` §1.2）。
- 只能操作已确认的 `boot`（p12）与 `rootfs`（p14）分区；不动 GPT、aboot、modem、NV。
- **两条刷机路径**：
  - **fastboot**（推荐，速度最快）：在设备 Linux 里
    `systemctl reboot --reboot-argument=bootloader` 进 LK fastboot，然后
    `flash.sh fastboot-flash boot|rootfs <img>`。机制与完整流程见 `docs/hardware/FASTBOOT.md`
    （已实机验证；注意必须用 `--reboot-argument=`，写成位置参数会报错）。
  - **EDL/9008**：按住 reset 按钮（或把 reset 触点与地短接）后插入电脑，用 Miko
    全片读写。这是任何情况下都能用的兜底路径。
- 从 fastboot 也能直接进 EDL：`fastboot oem reboot-edl`。
- 详见 `docs/hardware/FASTBOOT.md` 与 `recovery/` 下的备份与刷机记录。

## 许可

本项目按 **GPL-2.0-only** 提供：`LICENSE` 是 GPL-2.0 全文（与内核树
`LICENSES/preferred/GPL-2.0` 正文逐字节一致），`NOTICE` 说明覆盖范围与
**不分发**的内容。

- 覆盖：`source/patches/` 的内核补丁、本项目自写的设备树/脚本/文档；
  设备树带有内核惯用的 `SPDX-License-Identifier: GPL-2.0-only` 头。
- **不覆盖也不包含**：Qualcomm 固件与每台机器唯一的校准值（NV/modem）。
  那些从你自己的设备导出，按其原始条款使用。

## 历史

> 本节是操作记录，写的是当时的状态。`archive/` 在 9 月的记录里出现过，
> 但已随 2026-10-07 的旧内核清理删除；不要按本节的旧路径去找文件。
> 同期存在的 `WORKSPACE-INDEX.txt`（重组前的状态索引）也已删除，
> 其中仍有价值的结论已归入 `docs/ISSUES.md`、`docs/hardware/CPU-POWER.md`
> 与 `docs/CHANGES.md`。

- **中间产物已清理（2026-09-14）**：删掉了约 **9 GB** 可再生产物——
  `out/` 下 4 个与 `shared/rootfs`、`archive/` 重复的 rootfs 镜像（3.0G）、
  内核构建树（`out/build-ufi003-*-os` + `build/variant-*`，3.8G）、boot 打包中间态
  （`out/` 与各板 `boot/` 下的 `kernel-*-dtb` 拼接物与 `-check` 解包目录，96M+）、
  6.18.48 时代的陈旧模块树与构建日志、以及被 9/14 版取代的
  `build/…-venus-led-v3.ext4`（751M；其 LED 脚本内容与 git 提交 `e761f9b` 逐字节
  相同，可从仓库重建）。清理后**已实测可重建并启动**：重编 → 打包 → 刷入 →
  p12 逐字节校验 → 启动 → 功能验证全通过。
  删除前逐个核实过：rootfs 镜像都有同内容副本；12 个 `kernel-*-dtb` 都能从对应
  `.img` 的内核载荷反解出来（逐字节相同）；另删了 1 个无对应产物的孤儿
  `kernel-venus-oc16-dtb`。
  保留：`out/rollback/`（设备 p12 读回）、`out/boot-*/` 与各板 `boot/` 的 `.img`
  产物（文档引用）、`shared/`、`boards/`、`recovery/`。
  同时归档了陈旧的 `tools/flash.sh`（根 `flash.sh` 的功能子集，引用失效路径）到
  `archive/superseded-20260914/tools/`，并让 `verify-layout.sh` 在构建树被清掉后
  自动降级为片段静态检查（不再依赖 `build/variant-*/.config`）。
- **旧内核全部清退（2026-10-07，内核升到 7.2.9）**：6.18.49 与 7.1.13 的内核树、
  模块树、旧命名的 rootfs 与 boot 镜像、`build/variant-7.1.13-*`、以及历史归档
  `archive/`（含 `archive/superseded-20260914/`）都已删除，共释放约 30 GB。
  内核回退**不再靠并列的旧内核树**，靠 `recovery/` 与 `out/rollback/` 的分区读回。
  7.2.9 全链重建后跑过 QEMU 冒烟：**7 个 rootfs 全过**。
- **旧工作区已删除**：重组前的 `/opt/helloworld/103s/` 已于 2026-09-14 清理。
  删前做过逐文件核对：本仓是它的**完整超集**——`recovery/` 备份、rootfs 镜像、
  内核树、上游克隆都有同内容副本；它那 4666 个“独有”文件里 4650 个是 `build/`
  下可再生目标文件，其余是本仓已更新过的同名脚本/文档；两个仓的提交历史同源，
  无独有提交。
