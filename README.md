# OpenStick 工作区

面向 **MSM8916 高通 410 USB 棒** 的 Debian 13 (trixie) arm64 + 自编译
Linux 6.18.49 工程。目标机型：Handsome OpenStick **UFI103s / UFI003 /
UFI001b / UFI001c / SP970 / UZ801**。

> **旧文档已作废**：本工作区早期（9 月 2 日）的 README 把目标设备写成
> IPQ4019 + ath10k + 内核 5.15，那是拆机前的误判。实机是 MSM8916 +
> wcn36xx。该错误文档已移入 `archive/reports/`。

## 目录结构

```
openstick/
├── README.md              本文件
├── LED.md                 LED 跨型号适配说明
├── NETWORK.md             网络（NetworkManager）与中文说明
├── DESKTOP.md             桌面 / xrdp / GPU 硬件渲染（含实测与踩坑）
├── GPU-STREAMING.md       GPU 渲染桌面 + Venus 推流的可行性分析
├── FASTBOOT.md            fastboot 刷机（含实测数据与两个坑）
├── TOOLING.md             工具清单与缺口
├── boards/                各机型产物，按硬件家族分组
│   ├── README.md          家族划分依据（含 DTS 逐字节 diff 表）
│   ├── ufi00x/            ufi103s-ufi003 / ufi001b / ufi001c
│   ├── sp970/
│   └── uz801/
│       └── <机型>/{dts,boot}/    该板的 DTS 与 boot 镜像
├── source/                共享源码
│   ├── linux-6.18.49/     内核树（1.9G，一份，所有机型共用）
│   ├── patches/           内核补丁（权威，与分发仓逐字节一致）
│   ├── configs/           内核配置与片段
│   └── dts/common/        共享 dtsi
├── shared/                板无关产物
│   ├── rootfs/            3 个 rootfs 镜像
│   ├── modules/           2 套内核模块树
│   └── firmware/          固件集（common / ufi103s-venus）
├── tools/                 构建与验证脚本
├── upstream/              上游参考树（HandsomeMod 等，只读参考）
├── edl-tools/             EDL / Miko 刷机工具链
├── recovery/              备份、原始分区读回、刷机证据（不可替代）
├── build/ out/            构建与打包中间产物
└── archive/               历史归档（含 superseded-20260914/）
```

**内部分工**：`boards/` 放“每个板子不同的东西”，`shared/` 放“所有板子
共用的东西”，`source/` 放“源码”。刷机包 = 某板的 boot 镜像 + 共享 rootfs。

## 各机型状态

| 机型 | 家族 | WiFi | DTS | boot 镜像 | 实机验证 |
|---|---|---|---|---|---|
| UFI103s / UFI003 | ufi00x | WCN3620 | 6 个变体 | 6 个 | **已验证**（当前主力设备） |
| UFI001b | ufi00x | WCN3660b | 1 | 1 | 仅离线校验 |
| UFI001c | ufi00x | WCN3660b | 1 | 1 | 仅离线校验 |
| SP970 | sp970 | WCN3660b | 1 | 1 | 仅离线校验 |
| UZ801 | uz801 | WCN3660b | 1 | 1 | 仅离线校验 |

除 UFI103s 外，其余机型的 boot 镜像只做过**离线校验**（构建成功、
`build.json` 哈希自洽、DTB 布局正确），**从未刷入实机**。它们的 DTS 引脚
定义继承自上游已验证项目，但本工作区没有对应硬件。

### UFI103s 的 6 个 DTS 变体

| 变体 | 用途 |
|---|---|
| `ufi103s.dts` | 基线（200/400/800/998.4 MHz） |
| `ufi103s-oc12.dts` | 频率档 1094.4/1152/1209.6 MHz |
| `ufi103s-venus.dts` | 基线 + Venus 硬件编解码 |
| `ufi103s-venus-oc12.dts` | Venus + 频率档 |
| `ufi103s-venus-oc-100.dts` | Venus + 约 100 MHz 粒度的频率表 |
| `ufi103s-venus-oc-burst.dts` | Venus + burst 策略（已交付配置） |

## 关键事实

- **内核共享、DTB 不共享**：`Image.gz` 所有机型同一份，板间差异只在追加的
  DTB。所以不要跨机型复用 boot 镜像。
- **root 定位**：`boards/*/boot/build.json` 里记录各板的 cmdline，当前统一
  为 `root=PARTLABEL=rootfs`；实机 UFI103s 早期用的是 `root=PARTUUID=…`。
- **WiFi 上行速率**：核心修复是 `MAX_MEDIUM_TIME` 6000→20000（见
  `source/patches/0002`），实测 6 → 44–50 Mbit/s。响应非单调，详见
  `archive/reports/` 与分发仓 `docs/wifi-tx-throughput.md`。
- **监管域**：镜像内已用 `update-alternatives` 固定为 upstream
  `regulatory.db`（含 `country CN`）。
- **网络栈是 NetworkManager**（不是早期的 networkd + wpa_supplicant）：用户可用
  `nmtui`/`nmcli` 交互配网，改网络不用重启。详见 `NETWORK.md`。
- **系统默认简体中文**（`zh_CN.UTF-8`）：`nmcli`、`apt`、`man` 都有中文输出。
  注意 `network-manager-l10n`（NM 汉化）与 `man-db`（man 命令本身）必须显式
  安装，前者只是 NM 的 Recommends。详见 `NETWORK.md`。
- **LED 脚本机型通用**：五机型的三颗状态灯语义一致、sysfs 名字一致，脚本按名字
  发现（失败时按颜色兜底），不需要按型号分支。详见 `LED.md`。
- **桌面与远程桌面**：镜像默认带 i3 + xrdp（`ROOTFS_DESKTOP=1`），主机可用
  `xfreerdp`/`remmina` 连 3389。见 `DESKTOP.md`。
- **GPU 可用但只出 render 节点**：Adreno 306 在主线是 a3xx 家族，设备无显示
  面板，所以用 `separate_gpu_kms=1` 走 render-only，得到 `/dev/dri/renderD128`
  与 freedreno（`FD307`）。**注意**：需要专门的 GPU 内核变体
  （`tools/build-gpu-variant.sh`），默认内核里 `CONFIG_DRM` 是关的。
- **固件**：`shared/firmware/common/` 与 `ufi103s-venus/` 的差别只有多一个
  `qcom/venus-1.8/venus.mbn`（该固件也提供 Adreno 所需的 `a300_*.fw`）。
- **补丁只有一套**：`source/patches/` 与分发仓 `/opt/helloworld/ufi00x-mainline/patches/`
  逐字节一致，共 5 个（3 个 wcn36xx + 2 个 venus）。早期那个把几处改动揉在
  一起的合并版 `0003` 已归档到 `archive/superseded-20260914/patches/`。

## 验证

```sh
# 工作区布局与产物自检
bash tools/verify-layout.sh

# 分发仓自检（补丁可应用性、哈希、文档链接）
cd /opt/helloworld/ufi00x-mainline && sh tools/check-repo.sh \
  /opt/helloworld/openstick/source/linux-6.18.49
```

`tools/verify-layout.sh` 现在应当全过（exit 0）。它覆盖：内核源码与配置、
共享模块树、rootfs 内容（chrony/rmtfs/rmtfs_mem）、**NetworkManager 已装且
networkd/wpa_supplicant 已移除**、**zh_CN locale 已生成**、**fstab 带
x-systemd.growfs**、LED 脚本与 unit、各板 boot 产物、Venus 变体。

> 历史：重组前它会在最后一项报 `ufi-led-state.sh=MISSING`，因为当时
> `shared/rootfs/` 里几张镜像新旧不一（旧镜像没装 LED）。现在两张镜像都是
> 同一轮构建出来的（NetworkManager + 中文 + 通用 LED + growfs），这个不一致
> 已经消除。

## 刷机前必读

- **必须先做整片 eMMC 全量备份**（Miko 全盘 dump），再动手刷任何分区。
- 只能操作已确认的 `boot`（p12）与 `rootfs`（p14）分区；不动 GPT、aboot、modem、NV。
- **两条刷机路径**：
  - **fastboot**（推荐，速度最快）：在设备 Linux 里
    `systemctl reboot --reboot-argument=bootloader` 进 LK fastboot，然后
    `flash.sh fastboot-flash boot|rootfs <img>`。机制与完整流程见 `FASTBOOT.md`
    （已实机验证；注意必须用 `--reboot-argument=`，写成位置参数会报错）。
  - **EDL/9008**：按住 reset 按钮（或把 reset 触点与地短接）后插入电脑，用 Miko
    全片读写。这是任何情况下都能用的兜底路径。
- 从 fastboot 也能直接进 EDL：`fastboot oem reboot-edl`。
- 详见 `archive/reports/` 中的备份与刷机记录。

## 历史

- `archive/reports/`：各专题研究与交付证据（CPU 频率/电压、EDL、刷机证据等）
- `archive/superseded-20260914/`：本次重组中被取代的重复/分叉文件
- `WORKSPACE-INDEX.txt`：重组前的完整状态索引（保留作对照）
- `/opt/helloworld/103s/`：重组前的旧工作区，原样保留作回退
