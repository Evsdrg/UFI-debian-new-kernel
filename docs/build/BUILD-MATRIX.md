# 构建矩阵规划：设备 × 档位 × 网络栈

2026-09-15 规划定稿。命名规则见 [`CONTRIBUTING.md`](../../CONTRIBUTING.md) §4.1：内核
release 的设备令牌是 `KERNEL_LOCALVERSION`（当前 `-ufix0x`，2026-09-30 从 `-ufi103s`
改来；更早的 `-ufi003` 已弃用）。

> **档位命名对照**：规划时的 F1/F2/F3/F4 就是现在的 max/basic/slim/micro
> （`tools/build-matrix.sh` 与 `docs/build/TRIMMING.md` 用后者）。
> 下文表格保留 F1–F4 是为了与 9 月的实施记录对上，读的时候按此对照换算。

**2026-10-07：矩阵整体在 7.2.9 上重建。** 7.1.13 / 6.18.49 的内核树、模块树与
rootfs 已清理；下表的 release 后缀现在是 `7.2.9-ufix0x*`，boot 产物为
`boot-board-<板型>-7.2.9.img`。

## 一、档位矩阵

| 档位 | 网络栈 | GPU | 编解码 | 4G | BT | 中文 | 桌面 | USB 共享 |
|---|---|---|---|---|---|---|---|---|
| **F1 功能拉满** | NM | ✓ | ✓ | ✓ | ✓ | ✓ | i3+xrdp | ✓ |
| **F2 基础** | NM | ✗ | ✗ | ✓ | ✓ | ✓ | ✗ | ✓ |
| F2-native | 非 NM | ✗ | ✗ | ✓ | ✓ | ✓ | ✗ | ✓ |
| **F3 精简** | NM | ✗ | ✗ | ✗ | ✗ | ✓ | ✗ | ✓ |
| F3-native | 非 NM | ✗ | ✗ | ✗ | ✗ | ✓ | ✗ | ✓ |
| **F4 深度精简** | NM | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✓ |
| F4-native | 非 NM | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✓ |

共 **7 个 rootfs**。F1 只有 NM（用户指定）；USB 网络共享是所有档的默认能力。
所有档**都不预置任何 Wi-Fi 凭据**，首次进系统靠 USB RNDIS。

## 二、内核与 DTB 板型映射（ufi103s）

**板型级命名 + 正向功能后缀**（2026-09-16 定稿）：内核 release =
`<ver>-ufix0x<板型后缀>-dirty`，后缀只写"有的功能"（无 4G 不写 -no4g，
就什么都不写）；CPU OC（三档 OPP + 85C 被动冷却）已全员化进 common dtsi，
不占名字。9 个实验板型收敛为 5 个功能组合
（`tools/build-board-set.sh` 表驱动构建）：

| 板型（DTS 后缀） | 功能集 | 对应档位 |
|---|---|---|
| （空） | WiFi/BT only，4G 链与 venus 全关 | **slim / micro** |
| 4g | +4G | **basic** |
| venus | +硬件编解码，无 4G | （备用） |
| venus-4g | +硬件编解码 +4G | （备用） |
| venus-4g-gpu | +硬件编解码 +4G +GPU | **max** |

每板型独立内核 release 与模块树（vermagic 含 release，不可复用），
boot 镜像 `boot-board-<板型>-7.2.9.img`。刷机配对：max↔venus-4g-gpu、
basic↔4g、slim/micro↔空，boot 与 rootfs 必须成对。

## 三、USB 网络共享（所有档默认）

设备插 PC = USB 网卡 + NAT 网关，网关地址 **10.42.0.1/24**（NM shared 模式默认值，
两套网络栈保持一致）。完整实现与实机回归见
[`../validation/USB-FIX-7.2.9.md`](../validation/USB-FIX-7.2.9.md)。

- **内核**（所有档共用）：`CONFIG_USB_CONFIGFS=y` + `CONFIG_USB_F_RNDIS=y` +
  nftables 族（`CONFIG_NFT_CT` / `CONFIG_NFT_REJECT` 等）。缺这些时 NM 会显示
  "已激活"但 NAT 实际不工作。
- **gadget**：`usb-gadget.service` 写 configfs（单 RNDIS 配置）并绑定 UDC，
  按 UDC 实际内容判状态、失败回滚、幂等启停。
- **NM 档**：`usb-share.nmconnection`（`ipv4.method=shared`、`address1=10.42.0.1/24`），
  用 `20-usb-managed.conf` 只对 usb0 覆盖 udev 的 `NM_UNMANAGED`。
- **native 档**：`native-net.service` 监督 dnsmasq；`usb-share.sh` 有界等待
  USB 地址、原子加载自己的 nft 表、停止时只删自己的表。

## 四、非 NM 网络栈（F2/F3/F4 的 native 变体）

回归被 NM 替代前的 networkd 方案（[`../hardware/NETWORK.md`](../hardware/NETWORK.md)
有全部踩坑记录），要点：

- `systemd-networkd` + 全局 `wpa_supplicant`
- **当年两坑反向利用**：NM 档要禁 networkd.socket / wpa_supplicant@，native 档则要它们
  就位且**不装 NM**（不装即无抢占问题）
- DNS：dnsmasq 统一（与 USB 共享共用一个实例）
- F2-native 的 4G：ModemManager + `mmcli` 拨号脚本 + networkd 对 wwan0 DHCP
  （NM 档的 4G 是 NM 直接管，这条是 native 档唯一新增件）
- **不预置 Wi-Fi 凭据**：首次进系统靠 USB RNDIS，配网用 `nmtui` / `nmcli`；
  native 档同样不预置。

## 五、F1 的 i3 桌面（已定稿：i3 + xrdp，避开 VNC）

2026-09-15 定稿：F1 桌面从 sway 改回 **i3wm**——i3 + xrdp 是本工程**已实测跑通**的栈
（X11/RDP，376MB 内存实测可用；GPU 推流时 sway 仅作为 GPU-STREAMING 推流链的合成器，
与桌面档无关），完全避开 VNC 通道。

预配置已落地（`tools/desktop/i3-config` + `tools/desktop/i3status.conf`，
build-rootfs.sh 自动装入镜像）：

- Mod4(Super) 修饰键；文泉驿微米黑中文字体；纯深色背景 + 细边框 + 4px 间隙
  （RDP 压缩友好）
- 易用快捷键：Super+Enter 终端 / Super+d dmenu / **Super+n 网络管理
  （nmtui，非 NM 档自动回退 wpa_cli）** / **Super+s 截图到 ~/Pictures**
  （scrot 已加入 F1 包集）/ Super+u 进程表 / Print 截图
- i3status 底栏：WiFi/以太 IP、负载、时间
- xrdp 栈沿用已验证配置（Xwrapper allowed_users=anybody、xsession 入口）
- **配件栈**（2026-09-15 研究定稿，详表见 DESKTOP.md）：rofi（启动/切窗）、
  autotiling（自动分屏）、dunst（通知）、maim+slop（区域截图）、
  nm-applet（托盘）；刻意不装 picom/壁纸/polybar/flameshot
  （RDP 带宽或体积原因）。全部 `command -v` 守卫，常驻内存增量 ~35MB。

## 六、实施顺序

| 步骤 | 内容 | 验证 |
|---|---|---|
| 1 ✓ | 内核命名统一（→`-ufi103s`，后统一为 `-ufix0x`） | kver 推导 + 提交 |
| 2 ✓ | USB 共享内核 config + gadget 脚本 + NM shared 连接 | 真机 E2E：PC 侧拿到 10.42.0.x 并可用网关出网 |
| 3 ✓ | 非 NM 网络栈资产（networkd/wpa/dnsmasq/nft 模板 + `ROOTFS_NET` 开关） | QEMU 冒烟 |
| 4 ✓ | 档位矩阵化：F1..F4 × NET 写进 build-rootfs.sh（产物名带档位+栈） | 7 个镜像构建 |
| 5 ✓ | F1 i3 预配置资产（i3-config/i3status.conf/scrot） | QEMU 到 i3 会话 + RDP 截图 |
| 6 ✓ | 7 个 ufi103s rootfs 全量构建 + 冒烟 | 7/7 QEMU 到 login、0 非预期 FAILED |
| 7 ✓ | 内核升到 7.2.9，全链重建（5 板型内核/boot + 7 rootfs） | build-board-set + build-matrix + smoke-all 全过 |
| 8 ✓ | 7.2.9 RAM 预演与 USB 修复（GPU 变体两次 `fastboot boot`，NM/native 真实 NAT 通过） | 实机，见 `../validation/USB-FIX-7.2.9.md` |
| 9 ✓ | 7.2.9 整机刷入（max + boot），无 Wi-Fi 开箱即用验收 | 实机，见 `../validation/VALIDATION-2026-10-16.md` |
| 10 | 其余变体 / 新 rootfs 的实机矩阵；SIM 业务；Windows/macOS 兼容性 | 实机 |
