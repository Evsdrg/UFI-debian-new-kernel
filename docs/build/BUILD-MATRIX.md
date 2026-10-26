# 构建矩阵：设备 × 档位 × 网络栈

本文说明当前 7.2.9 产物如何选择。命名规则见
[`CONTRIBUTING.md`](../../CONTRIBUTING.md) §4.1：release 由
`source/kernel-version.env` 中的版本与 `KERNEL_LOCALVERSION` 派生。

## 一、rootfs 档位

| 档位 | 网络栈 | GPU | 编解码 | 4G | BT | 中文 | 桌面 | USB 共享 |
|---|---|---|---|---|---|---|---|---|
| **max** | NM | ✓ | ✓ | ✓ | ✓ | ✓ | i3+xrdp | ✓ |
| **basic** | NM | ✗ | ✗ | ✓ | ✓ | ✓ | ✗ | ✓ |
| basic-native | native | ✗ | ✗ | ✓ | ✓ | ✓ | ✗ | ✓ |
| **slim** | NM | ✗ | ✗ | ✗ | ✗ | ✓ | ✗ | ✓ |
| slim-native | native | ✗ | ✗ | ✗ | ✗ | ✓ | ✗ | ✓ |
| **micro** | NM | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✓ |
| micro-native | native | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✓ |

共 **7 个 rootfs**。max 只有 NM 变体；USB 网络共享是所有档的默认能力。
所有档**都不预置任何 Wi-Fi 凭据**，首次进系统靠 USB RNDIS。

## 二、内核与 DTB 板型映射（ufi103s + mf601sl）

**板型级命名 + 正向功能后缀**：内核 release =
`<ver>-ufix0x<板型后缀>-dirty`，后缀只写实际包含的功能。
`tools/build-board-set.sh` 用板型表驱动构建：

| 板型（DTS 后缀） | 功能集 | 对应档位 |
|---|---|---|
| （空） | WiFi/BT only，4G 链与 venus 全关 | **slim / micro** |
| 4g | +4G | **basic** |
| venus | +硬件编解码，无 4G | （备用） |
| venus-4g | +硬件编解码 +4G | （备用） |
| venus-4g-gpu | +硬件编解码 +4G +GPU | **max** |
| minimal | **WiFi + USB 共享 + zram，其余全裁**（内存最大化） | slim / micro |
| mf601sl | **THWC MF601SL_CT_V07 电池型 4G MiFi**（不同板目录，独立 DTS） | basic |

**mf601sl 是另一块板**，DTS 在 `boards/thwc-mf601sl/`、内核片段是
`source/configs/mf601sl.config`。它保留完整 4G 链、启用 LBC 充电 + BMS 电量计，
release 为 `7.2.9-ufix0x-mf601sl-dirty`。**不能套用 minimal 的内存裁剪**
（会关掉 modem 链）。详见 [`docs/hardware/MF601SL.md`](../hardware/MF601SL.md)。

**minimal 与其它板型的区别**：DTS 与空板型相同（同一个 WiFi-only 设备树），
差异**全在内核配置**——在 common 配置之上再叠
`source/configs/ufi103s-minimal.config`，关掉 SCSI/MTD/ATA/NVMe、其它 SoC 的
pinctrl/clk/interconnect、无关文件系统（nfs/cifs/fuse/overlay…）、蓝牙、
多媒体、大多数 USB HID 等。保留项严格限于：

- **WiFi**：wcn36xx + mac80211/cfg80211 + WCNSS PIL/remoteproc 链
- **USB 网络共享**：configfs + RNDIS + nftables（`NFT_CT`/`NFT_REJECT` 等）
- **内存压缩**：zram + zsmalloc + zstd
- **起不来就白搭**：eMMC（MMC_SDHCI_MSM）、ext4、pinctrl/clk/regulator/thermal
  的 msm8916 部分、`QCOM_APCS_IPC`（见下）、状态灯（PWM→LEDS_LPG）、
  `gpio-keys` Reset 键、`pm8941_pwrkey`

**两处决不能被裁的依赖（2026-10-17 实机踩到）**：

1. `QCOM_APCS_IPC`：它是 msm8916 的 APCS IPC mailbox 驱动，而
   `QCOM_CLK_APCS_MSM8916`（msm8916 的 CPU 时钟控制器）`depends on` 它。
   关掉会让 CPU 时钟驱动**整个符号消失**，内核在早期 CPU 频率初始化时
   **硬挂死**——无 panic、无任何串口/USB 输出，只能物理断电。
   ⚠️ **QEMU 冒烟抓不到**：QEMU 没有 msm8916 APCS 硬件，照样能启动到 login。
2. `INPUT_KEYBOARD`：DTS 的 `gpio-keys`（"Reset" 键，`KEY_RESTART`）需要
   `CONFIG_KEYBOARD_GPIO`，而它在 `if INPUT_KEYBOARD` 内。关掉会静默丢失
   Reset 按键（只剩 `pm8941_pwrkey`），没有报错。

**实机实测收益（2026-10-17，与 GPU 版对比）**：

| 项 | minimal | venus-4g-gpu | 差 |
|---|---:|---:|---:|
| `MemTotal` | 484176 kB | 384632 kB | **+97 MB** |
| `MemAvailable`（空载） | 382348 kB | 282536 kB | **+98 MB** |
| boot 镜像 | 5.94 MB | 8.00 MB | −26% |
| 解压内核 | 15.85 MB | 21.72 MB | −27% |
| 模块树 `.ko` 数 | 460 | 696 | −34% |

⚠️ 注意归因：**那 ~97 MB 来自 DTS**（空板型关掉 mpss/mba/rmtfs/venus_mem
预留），已在 baseline 变体上存在；内核配置裁剪的收益是镜像体积 / rodata /
模块数，**不是** MemTotal。minimal 的价值是在同样内存下把内核足迹压到最小。

内存与体积实测详见 [`../validation/2026-10-16-validation.md`](../validation/2026-10-16-validation.md)。

每板型独立内核 release 与模块树（vermagic 含 release，不可复用），
boot 镜像 `boot-board-<板型>-7.2.9.img`。刷机配对：max↔venus-4g-gpu、
basic↔4g、slim/micro↔空或 minimal，boot 与 rootfs 必须成对。

## 三、USB 网络共享（所有档默认）

设备插 PC = USB 网卡 + NAT 网关，网关地址 **10.42.0.1/24**（NM shared 模式默认值，
两套网络栈保持一致）。完整实现与实机回归见
[`../validation/2026-10-10-usb-fix.md`](../validation/2026-10-10-usb-fix.md)。

- **内核**（所有档共用）：`CONFIG_USB_CONFIGFS=y` + `CONFIG_USB_F_RNDIS=y` +
  nftables 族（`CONFIG_NFT_CT` / `CONFIG_NFT_REJECT` 等）。缺这些时 NM 会显示
  "已激活"但 NAT 实际不工作。
- **gadget**：`usb-gadget.service` 写 configfs（单 RNDIS 配置）并绑定 UDC，
  按 UDC 实际内容判状态、失败回滚、幂等启停。
- **NM 档**：`usb-share.nmconnection`（`ipv4.method=shared`、`address1=10.42.0.1/24`），
  用 `20-usb-managed.conf` 只对 usb0 覆盖 udev 的 `NM_UNMANAGED`。
- **native 档**：`native-net.service` 监督 dnsmasq；`usb-share.sh` 有界等待
  USB 地址、原子加载自己的 nft 表、停止时只删自己的表。

## 四、native 网络栈（basic/slim/micro 的 native 变体）

回归被 NM 替代前的 networkd 方案（[`../hardware/NETWORK.md`](../hardware/NETWORK.md)
有全部踩坑记录），要点：

- `systemd-networkd` + 全局 `wpa_supplicant`
- **两类网络栈的互斥要求**：NM 档要禁 networkd.socket / wpa_supplicant@，
  native 档则要它们就位且**不装 NM**（不装即无抢占问题）
- DNS：dnsmasq 统一（与 USB 共享共用一个实例）
- basic-native 的 4G：ModemManager + `mmcli` 拨号脚本 + networkd 对 wwan0 DHCP
  （NM 档的 4G 是 NM 直接管，这条是 native 档唯一新增件）
- **不预置 Wi-Fi 凭据**：首次进系统靠 USB RNDIS，配网用 `nmtui` / `nmcli`；
  native 档同样不预置。

## 五、max 档的 i3 桌面

max 档使用 **i3 + xrdp**（X11/RDP），适配小内存设备；推流所用的 sway
只属于 GPU-STREAMING 链路，与桌面档无关。

预配置已落地（`tools/desktop/i3-config` + `tools/desktop/i3status.conf`，
build-rootfs.sh 自动装入镜像）：

- Mod4(Super) 修饰键；文泉驿微米黑中文字体；纯深色背景 + 细边框 + 4px 间隙
  （RDP 压缩友好）
- 易用快捷键：Super+Enter 终端 / Super+d dmenu / **Super+n 网络管理
  （nmtui，非 NM 档自动回退 wpa_cli）** / **Super+s 截图到 ~/Pictures**
  （scrot 已加入 max 档包集）/ Super+u 进程表 / Print 截图
- i3status 底栏：WiFi/以太 IP、负载、时间
- xrdp 栈沿用已验证配置（Xwrapper allowed_users=anybody、xsession 入口）
- **配件栈**：rofi、autotiling、dunst、maim+slop、nm-applet；
  不装 picom/壁纸/polybar/flameshot（RDP 带宽或体积原因）。
  全部 `command -v` 守卫，常驻内存增量约 35MB。

## 六、尚未覆盖的验证

- UFI103s 其余功能变体的硬件启动，以及 max 以外 rootfs 的整机矩阵
- minimal 从闪存启动的完整验收
- SIM 实际业务、Windows/macOS RNDIS 兼容性
- 长期稳定性与掉电测试

已完成的结果按日期记录在 `../validation/`，不要把规划项当成已验证能力。
