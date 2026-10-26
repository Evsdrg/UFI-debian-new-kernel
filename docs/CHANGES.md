# 改动清单：相对上游做了什么

给使用者的**交付层 diff 清单** —— 一眼看清这套东西与「上游 Linux + 上游
Debian 13」差在哪里。每项都指向权威定义处。

「为什么这么改」和踩坑经过在 `CONTRIBUTING.md`（贡献须知）与 `ISSUES.md`（问题清单），
本文件只列改动本身。

---

## 一、内核（Linux 7.2.9）

### 1.1 补丁：4 个，均在 `source/patches/`

在 `source/patches/`，在 pristine 7.2.9 上按序干净套用
（无 fuzz、无 reject），反向套用也干净。分发镜像（`builds/`）由同一份源码与
补丁编出，`tools/dist/gen-manifest.sh` 把哈希写进各自的 `build.json`。

| 补丁 | 作用 | 上游状态 |
|---|---|---|
| `0001` wcn36xx feat-caps 可读 | 通过 debugfs 暴露固件 feature caps。上游把该文件注册成 `0200`（只写）却挂了读回调，谁都读不到 | 独立的上游 bug |
| `0002` wcn36xx MAX_MEDIUM_TIME 6000→20000 | **真正的上行速率修复**：6000 太小，固件速率自适应卡在 MCS0（约 6 Mbit/s）；改后 45–50 Mbit/s | 未上游 |
| `0003` wcn36xx cfg override 诊断 | `cfg_override` 模块参数 + debugfs 旋钮，运行时把 `WCN36XX_HAL_CFG_*` 推给固件，不必每个值重编一次 | 诊断用，未上游 |
| `0005` venus HFI 1xx 编码修复 | 四项：8x8 transform 只发给 HFI 4xx/6xx；1xx 强制 in-band headers；`vdec` G_FMT 等 reconf 事件；对外广告真实的 128x32 对齐 | 未上游 |

三个 wcn36xx 补丁都通过 `checkpatch --strict`，无 error 无 warning。

**已知缺陷（已修）**：`0005` 原本还含一份与 `0004` 逐字节重复的 `hfi_parser.c`
改动，导致按序号套用必然冲突。已把该段从 0005 删除（0004 本身随后随 7.2.9
退场，因为上游已含该修复）。规则：**每个文件只有一个归属**。

### 1.2 设备树：11 个自写文件

权威副本在 `boards/*/*/dts/` 与 `source/dts/common/`，**不在内核树里**。
构建时用独立的 `cpp` + `dtc` 就地编译，只把内核树当 include 来源
（不往内核树拷文件、不改内核 `Makefile`）。

- 共享基础：`source/dts/common/msm8916-handsome-openstick-common.dtsi`
- 每板一个基础 DTS：UFI103s 另有 4 个功能变体（`-4g`、`-venus`、`-venus-4g`、
  `-venus-4g-gpu`），合计 5 个功能组合；UFI001b / UFI001c / SP970 / UZ801 各 1 个。
- **每型专属 `compatible`**（`handsome,ufi103s` / `ufi001b` / `ufi001c` /
  `sp970` / `uz801`），不再共用 `handsome,openstick`。
- 相对原厂 DTB 的板级定制、引脚来源与逐字节 diff 见 `boards/README.md`
  与各板 README。

### 1.3 内核配置

`source/configs/`：`common-7.2.9-os.config`（主配置，自 7.1.13 迁移）+ 变体片段
（`ufi103s-venus.config`、`ufi103s-gpu.config`、`kernel-size.config`）。

相对 Debian 默认配置的实质改动：

- **GPU**：`CONFIG_DRM_MSM_KMS=n`，且显式关掉 `DRM_MSM_MDP4/MDP5/DPU`
  （它们在 Kconfig 里是 `default y` 且会 `select DRM_MSM_KMS`）。
  配合 `options msm separate_gpu_kms=1` 走 render-only。
- **USB gadget 链**：`CONFIG_USB_CONFIGFS`、`CONFIG_USB_CONFIGFS_RNDIS`、
  `EXTCON_USB_GPIO`、`PHY_QCOM_USB_HS` 等，支撑 USB 网络共享。
- **nftables 共享**：`NFT_CT`、`NFT_REJECT` =m，并由此派生
  `NFT_REJECT_INET/_IPV4/_IPV6` 与 `NF_REJECT_IPV4/_IPV6`。
  （NetworkManager 的共享模式需要这些；缺了它 NAT 规则整批提交失败。）
- **wcn36xx 调试**：`CONFIG_DEBUG_FS`、`CONFIG_CFG80211_DEBUGFS`、
  `CONFIG_MAC80211_DEBUGFS`、`CONFIG_WCN36XX_DEBUGFS`。
- **体积**：`kernel-size.config` 追加可得 `Image.gz` **-8.4%**
  （代价：oops 无符号名，且必须用同配置重编的模块树）。

---

## 二、rootfs（Debian 13 trixie arm64）

构建器：`build-rootfs.sh`（mmdebstrap unshare 模式 + qemu-user）。

### 2.1 四档 × 双栈 = 7 个镜像

档位 `max/basic/slim/micro`，网络栈 `nm`（NetworkManager）/`native`
（networkd + wpa_supplicant + dnsmasq + nftables）。体积与取舍见
`docs/build/TRIMMING.md`，矩阵定义见 `docs/build/BUILD-MATRIX.md`。

四个**正交开关**可单独覆盖档位默认值：`ROOTFS_ZH`、`ROOTFS_BT`、`ROOTFS_4G`、
`ROOTFS_NET`。

### 2.2 相对上游 Debian 的定制

| 项 | 改动 |
|---|---|
| 语言 | 默认简体中文 `zh_CN.UTF-8`（真跑 `locale-gen`，不只改 `locale.gen`）；装 `network-manager-l10n`（NM 只 Recommends 它）、`man-db` + `manpages-zh` |
| 网络 | 用 NetworkManager；**移除** `systemd-networkd`（含 socket 与 `.service`）与每接口的 `wpa_supplicant@wlan0`。**不删全局 `wpa_supplicant.service`**（那是 NM 的 D-Bus 后端） |
| 连接文件 | NM keyfile 必须 `600`，否则 NM 静默忽略 |
| 分区 | fstab 带 `x-systemd.growfs`：镜像约 1 GB 而 p14 有 3.3 GB，开机自动撑满 |
| 看门狗 | `system.conf.d/10-watchdog.conf` 把 `RuntimeWatchdogSec` 与 `RebootWatchdogSec` 设为 60s（PM8916 PON 只接受 1..127 s，默认 10 分钟会让武装失败、关机卡死） |
| 监管域 | 固定用 upstream 变体 `regulatory.db`（Debian 签名变体过不了内核内建 cert 校验，会静默退回 world domain 并忽略 `iw reg set CN`） |
| zram | 350 MB zstd swap（`zram-setup.service`） |
| 时区 | `Asia/Shanghai`；chrony 用 `makestep` |
| debconf | 固化 `DEBIAN_FRONTEND=noninteractive`，并把 `debconf/frontend` 设为 Noninteractive（否则每次 apt 刷三行回退警告） |
| 串口 | `serial-getty@ttyMSM0` |
| 桌面（`max`） | xrdp + xorgxrdp + i3 + 中文字体 + 托盘/截图配件栈 |
| 凭据 | **镜像不含任何预置 Wi-Fi**（2026-10-16 起；原因见 `docs/ISSUES.md` 第 15 条），首次进系统靠 USB RNDIS。root 口令可选传入（经文件写入、用完即删），不传则 root 无口令。**仓库里不含任何真实凭据** |
| 软件包 | 显式加 `systemd-sysv`（只是 `systemd` 的 Recommends；缺它时精简档镜像没有 `/sbin/init`，系统落到 `/bin/sh` 起不来） |

### 2.3 USB 网络共享（所有档默认）

设备插 PC = USB 网卡 + NAT 网关，网关固定 `10.42.0.1/24`。

- **gadget**：`tools/usb-gadget.sh` + `usb-gadget.service`（单 RNDIS 配置）。
  读取实际 UDC 内容判状态、每步检查失败、失败回滚、幂等启停。
- **NM 档**：`usb-share.nmconnection`（`ipv4.method=shared` + 显式
  `address1=10.42.0.1/24`），并用 `20-usb-managed.conf` 覆盖 Debian udev 的
  `NM_UNMANAGED`（**只匹配 usb0**，不全局放开）。
- **native 档**：`native-net.service` 监督前台 dnsmasq；`usb-share.sh` 有界等待
  USB 地址、原子加载自己的 `inet openstick_usb` 表、停止时只删自己的表；
  `nat.nft` 限定 USB 来源。
- 全局 `dnsmasq.service` 被 mask，避免与共享口实例抢端口。

详见 `tools/net-native/README.md` 与 `docs/validation/2026-10-10-usb-fix.md`。

---

## 三、userspace 脚本（`tools/`）

| 脚本 | 作用 |
|---|---|
| `kver.sh` / `kver.py` / `source/kernel-version.env` | **版本单一事实来源**；其余脚本从它派生路径与 release |
| `lib-creds.sh` | 凭据统一入口（环境变量 > `.local-creds`），**仓库里无任何默认口令** |
| `build-board-set.sh` | 板型级构建（5 个功能组合 + minimal，表驱动） |
| `build-matrix.sh` | 7 个 rootfs 全矩阵 |
| `build-kernel-variant.sh` / `package-boot-variant.py` | 内核变体与 boot 打包（Android legacy header v0、page 2048、appended DTB） |
| `usb-gadget.sh` / `net-native/*` | USB 网络共享（见上） |
| `verify-layout.sh` / `verify-usb-sharing.py` | 布局与 USB 交付自检（离线断言） |
| `test-usb-sharing.py` | configfs 与 native 生命周期的故障注入回归（无特权） |
| `qemu-smoke.sh` / `smoke-all.sh` | QEMU 冒烟（不碰真机） |
| `ufi-led-state.sh`（+ `.service`、`.default`） | 五机型通用的三色状态灯 |
| `desktop/ufi-stream-push.sh` 等 | GPU 合成 → Venus 硬编 → 推流 |
| `ufi-console.sh` | 有界串口访问（端口名会变，先 `id` 确认） |
| `venus-test.sh` / `venus-transcode.sh` | Venus 硬编解码验证与转码 |
| `wcn36xx-cfg-sweep.sh` | WiFi 固件参数扫描（`cfg_override`，补丁 0003） |
| `cpu-freq-verify.sh` / `cpu-power-tradeoff.sh` | CPU 频率与功耗验证 |
| `flash.sh`（仓库根） | 刷机（`fastboot-flash` 刷前比对 build.json 的 sha256） |

---

## 四、不改的地方（刻意的边界）

- **不动引导链**：GPT、`aboot`、`modem`、`NV` 一律不写。只动 `mmcblk0p12`（boot）
  与 `mmcblk0p14`（rootfs）。
- **不做寄存器级试探**：不用 `devmem`、不 Firehose poke、不写猜测的寄存器值。
- **不打包私有数据**：Qualcomm 固件与每台机器的校准值不入库、不随镜像分发。
- **不改内核树**：补丁就地套用（HEAD 保持 pristine），DTS 走外包编译。

---

## 五、未完成的改动（候选，尚未实施）

见 `docs/ISSUES.md`「尚未闭环的问题」：

- Venus MPEG-4 硬解固件 fatal（已定位错误传播链，断言根因未闭环）
- 持续负载散热与推流 CPU 成本（已有隔离实验数据与候选顺序）
- 其余四个变体、七张新 rootfs 的实机验收；四块 WCN3660B 板；SIM 业务；
  Windows/macOS 兼容性

全片 eMMC 备份的脚本化（`docs/build/TOOLING.md` 的「缺口」）仍是最大缺口。

---

## 六、清理与保留

开发过程中会删掉大量可再生产物（旧内核树、旧模块树、旧镜像、构建中间态）。
原则只有一条：**只删能重新构建的东西；不可再生的东西——尤其是每台机器唯一的
分区读回——必须保留**。具体是：

- **可删**：`build/` 中间态、旧内核/模块树、被新构建取代的 rootfs 与 boot 镜像。
  这些都可用 `tools/` 下的脚本重建。
- **必留**：`recovery/`（原厂分区读回）与 `out/rollback/`（升级前 boot 分区读回）。
  写坏 NV/modem 不可从别处恢复，这两处是唯一的安全网。
- **删前核实**：先跑 `tools/verify-layout.sh` 确认现有产物齐全，并确认要删的
  内容能从 `artifacts/` 或重建得到。
