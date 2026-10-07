# 构建矩阵规划：设备 × 档位 × 网络栈

2026-09-15 规划定稿。命名规则见 AGENTS.md §5.1：内核 release 的设备令牌是
`KERNEL_LOCALVERSION`（当前 `-ufix0x`，2026-09-30 从 `-ufi103s` 改来；更早的
`-ufi003` 已弃用）。

**2026-10-07：矩阵整体在 7.2.9 上重建。** 7.1.13 / 6.18.49 的内核树、模块树与
rootfs 已清理；下表的 release 后缀现在是 `7.2.9-ufix0x*`，boot 产物为
`boot-board-<板型>-7.2.9.img`。

## 一、档位矩阵

| 档位 | 网络栈 | GPU | 编解码 | 4G | GPS | BT | 中文 | 桌面 | USB 共享 |
|---|---|---|---|---|---|---|---|---|---|
| **F1 功能拉满** | NM | ✓ | ✓ | ✓ | n/a* | ✓ | ✓ | i3+xrdp | ✓ |
| **F2 基础** | NM | ✗ | ✗ | ✓ | n/a* | ✓ | ✓ | ✗ | ✓ |
| F2-native | 非 NM | ✗ | ✗ | ✓ | n/a* | ✓ | ✓ | ✗ | ✓ |
| **F3 精简** | NM | ✗ | ✗ | ✗ | ✗ | ✗ | ✓ | ✗ | ✓ |
| F3-native | 非 NM | ✗ | ✗ | ✗ | ✗ | ✗ | ✓ | ✗ | ✓ |
| **F4 深度精简** | NM | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✓ |
| F4-native | 非 NM | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✓ |

\* GPS 只有 MF32 有，且已定案删除（README 定制清单 #1）。
共 **7 个 rootfs**。F1 只有 NM（用户指定）；USB 网络共享是所有档的默认能力。

## 二、内核与 DTB 板型映射（ufi103s）

**板型级命名 + 正向功能后缀**（2026-09-16 定稿）：内核 release = 
`<ver>-ufix0x<板型后缀>-dirty`，后缀只写"有的功能"（无 4G 不写 -no4g，
就什么都不写）；CPU OC（三档 OPP + 85C 被动冷却）已全员化进 common dtsi，
不占名字。9 个实验板型收敛为 5 个功能组合
（`tools/build-board-set.sh` 表驱动构建）：

| 板型（DTS 后缀） | 功能集 | 对应档位 |
|---|---|---|
| （空） | WiFi/BT only，4G 链与 venus 全关 | **slim / micro**（MemTotal ≈469MB） |
| 4g | +4G | **basic** |
| venus | +硬件编解码，无 4G | （备用） |
| venus-4g | +硬件编解码 +4G | （备用） |
| venus-4g-gpu | +硬件编解码 +4G +GPU | **max** |

每板型独立内核 release 与模块树（vermagic 含 release，不可复用），
boot 镜像 `boot-board-<板型>-7.2.9.img`。刷机配对：max↔venus-4g-gpu、
basic↔4g、slim/micro↔空，boot 与 rootfs 必须成对。

## 三、USB 网络共享（所有档默认）

设备插 PC = USB 网卡 + NAT 网关，网关地址 **10.42.0.1/24**（NM shared 模式默认值，
两套网络栈保持一致）：

- **内核**（一次，所有档共用）：需新增 `CONFIG_USB_CONFIGFS=y`、
  `CONFIG_USB_F_RNDIS=y`（Windows 兼容）+ ECM（Linux/Mac）双配置 gadget；
  ci_hdrc 做_UDC。当前配置只有 `USB_GADGET=y`，CONFIGFS/RNDIS 全关——
  **这是新内核需求**，做好后 fastboot boot 干跑验证枚举。
- **gadget 装配**：oneshot 服务写 configfs（VID/PID、`rndis.usb0`+`ecm.usb1`、
  UDC 绑定），开机自动执行。
- **NM 档**：预置连接 `usb0 ethernet ipv4.method=shared` → 10.42.0.1、DHCP、
  DNS、NAT 全部 NM 自动。nftables 后端已在配置里（NF_TABLES=m）。
- **非 NM 档**：usb0 静态 10.42.0.1/24（networkd）+ dnsmasq（DHCP 池
  10.42.0.10-50 + DNS 转发）+ nftables `masquerade usb0 → wlan0/wwan0` +
  `ip_forward=1`，一个 oneshot unit 串起来。

## 四、非 NM 网络栈（F2/F3/F4 的 native 变体）

回归被 NM 替代前的 networkd 方案（NETWORK.md 有全部踩坑记录），要点：

- `systemd-networkd` + 全局 `wpa_supplicant`（凭据构建时预置
  `/etc/wpa_supplicant/wpa_supplicant.conf`）
- **当年两坑反向利用**：NM 档要禁 networkd.socket / wpa_supplicant@，
  native 档则要它们就位且**不装 NM**（不装即无抢占问题）
- DNS：dnsmasq 统一（与 USB 共享共用一个实例）
- F2-native 的 4G：ModemManager + `mmcli` 拨号脚本 + networkd 对 wwan0 DHCP
  （NM 档的 4G 是 NM 直接管，这条是 native 档唯一新增件）
- 预置 Wi-Fi 凭据机制沿用（STAGE 拷入 + 600 权限的坑已修）

## 五、F1 的 i3 桌面（已定稿：i3 + xrdp，避开 VNC）

2026-09-15 定稿：F1 桌面从 sway 改回 **i3wm**——i3+ xrdp 是本工作区
**已实测跑通**的栈（X11/RDP，376MB 内存实测可用，GPU 推流时 sway 仅作为
GPU-STREAMING 推流链的合成器使用，与桌面档无关），完全避开 VNC 通道。

预配置已落地（`tools/desktop/i3-config` + `tools/desktop/i3status.conf`，
build-rootfs.sh 自动装入镜像）：

- Mod4(Super) 修饰键；文泉驿微米黑中文字体；纯深色背景 + 细边框 + 4px 间隙
  （RDP 压缩友好）
- 易用快捷键：Super+Enter 终端 / Super+d dmenu / **Super+n 网络管理
  （nmtui，非 NM 档自动回退 wpa_cli）** / **Super+s 截图到 ~/Pictures**
  （scrot 已加入 F1 包集）/ Super+u 进程表 / Print 截图
- i3status 底栏：WiFi/以太 IP、负载、时间（MF32 实机后加 battery 模块）
- xrdp 栈沿用已验证配置（Xwrapper allowed_users=anybody、xsession 入口）
- **配件栈**（2026-09-15 研究定稿，详表见 DESKTOP.md）：rofi（启动/切窗）、
  autotiling（自动分屏）、dunst（通知）、maim+slop（区域截图）、
  nm-applet+cbatticon（托盘）；刻意不装 picom/壁纸/polybar/flameshot
  （RDP 带宽或体积原因）。全部 `command -v` 守卫，常驻内存增量 ~35MB。

## 六、MF32 专项更新（拆解/实测结论入库）

- **SD 卡**：驱动零缺口（`qcom,sdhci-msm-v4` 与 eMMC 同驱动，已在 103s 验证）；
  DTB 已使能（4-bit、cd=GPIO38 低有效、vmmc=l11/vqmmc=l12）。唯一缺口：CD
  引脚的 `pmx-sdc2-cd-pin-state` 定义了但 pinctrl-0 **未引用**（GPIO38 上拉
  可能缺失）→ 加入定制清单 #6，实机插卡验证。
- **RGB 拆解**：红蓝灯珠相邻、混色效果好；绿灯单独放置。→ LED 方案新增
  **品红（R+B）= 充电中**状态；绿通道继续禁止混色。已改 `mf32-led-state.sh`
  （`rgb_set` 支持 magenta，自测扩至 34 项）。
- **按键拆解**：全机只有 pwrkey + reset（GPIO34）可用，第三键只有焊盘未上件
  → resin 永久 disabled，不再考虑启用。
- USB 共享对 MF32 同样适用（电池+USB 双场景）；SD 挂载策略属 rootfs 档位：
  F1/F2 可带 udisks2 自动挂载，F3/F4 手动 mount。

## 七、实施顺序

| 步骤 | 内容 | 验证 |
|---|---|---|
| 1 ✓ | 内核命名统一（→`-ufi103s`，后统一为 `-ufix0x`） | kver 推导 + 提交 |
| 2 ✓ | USB 共享内核 config + gadget 脚本 + NM shared 连接 | 真机 E2E：PC 侧拿到 10.42.0.x 并可用网关出网 |
| 3 ✓ | 非 NM 网络栈资产（networkd/wpa/dnsmasq/nft 模板 + `ROOTFS_NET` 开关） | QEMU 冒烟 |
| 4 ✓ | 档位矩阵化：F1..F4 × NET 写进 build-rootfs.sh（产物名带档位+栈） | 7 个镜像构建 |
| 5 ✓ | F1 i3 预配置资产（i3-config/i3status.conf/scrot） | QEMU 到 i3 会话 + RDP 截图 |
| 6 ✓ | 7 个 ufi103s rootfs 全量构建 + 冒烟 | 7/7 QEMU 到 login、0 非预期 FAILED |
| 7 ✓ | 内核升到 7.2.9，全链重建（5 板型内核/boot + 7 rootfs） | build-board-set + build-matrix + smoke-all 全过 |
| 8 | 7.2.9 刷真机复测（GPU/Venus/4G/WiFi） | 实机 |
| 9 | mf32 bring-up 后套用（起步 F4-native） | 实机 |
