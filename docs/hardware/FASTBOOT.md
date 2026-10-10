# fastboot 刷机（MSM8916 OpenStick）

> **时效注记**：下面的分步实测做于 6.18.49 时代（镜像名如 `boot-venus-oc-100.img`
> 已随旧内核清理删除），但 fastboot 流程本身（进 fastboot、双分区、-S 分片、
> growfs）至今未变，命令里的镜像名按当前 `boot-board-<板型>-7.2.9.img` 换算即可。
> 7.2.9 的升级/回退流程见 `boards/ufi00x/ufi103s-ufi003/README.md`。

**结论：可以在 Linux 里直接重启进 fastboot，已在本机实机验证通过。**

```sh
systemctl reboot --reboot-argument=bootloader
```

> **注意命令形式**：必须用 `--reboot-argument=`。写成 `systemctl reboot bootloader`
> 会报 `Too many arguments`（systemd 257 实测）；写成 `/sbin/reboot bootloader`
> 也不行，因为 Debian 里 `/sbin/reboot` 是 `systemctl` 的符号链接，参数不透传。
> `--reboot-argument=` 是 systemd 257 起的选项（Debian 13 自带就是 257.13）。

## 实测结果（2026-09-14，本机 6.18.49-ufi003-venus-dirty）

### 1. 进入 fastboot：双向对照

| 测试 | 命令 | 串口上 LK 的行为 | 结果 |
|---|---|---|---|
| A | `systemctl reboot`（无参数） | `[860] booting linux @ 0x80000000 …` | 回 Linux，未进 fastboot |
| B | `systemctl reboot --reboot-argument=bootloader` | `Rebooting with argument 'bootloader'.` → `[320] fastboot_init()` | **进 fastboot** |

B 做了两次都进 fastboot（可重复）。A/B 对照说明**是参数在起作用**，不是 LK 因
引导失败而 fallback。

进入 fastboot 后主机看到：

```
$ fastboot devices
<device-serial>	 fastboot
```

USB 上设备是 `18d1:d00d`（Android/fastboot 标准 ID），实测出现在主机 USB hub 的
`3-2.4.4` 端口（换机器/换口会变）。

**耗时**：从发出命令到 fastboot 可用约 **96 秒**（关机 + LK 探测）。这是实测值，
`flash.sh` 的等待窗口据此设为 150 秒——不要按 30 秒判失败。

### 2. 刷 boot：验证内核真的换了

设备原本跑 `boot-venus-oc-100.img`（逐字节比对确认）。刷入 `boot-baseline.img`
（内核 release 不同）后重启：

| | 刷前 | 刷后 |
|---|---|---|
| `uname -r` | `6.18.49-ufi003-venus-dirty` | `6.18.49-ufi003-dirty` |
| 内核编译时间 | 9/11 21:22 | 9/4 17:59 |

写日志：`Sending 'boot' (7360 KB) OKAY [0.233s]` / `Writing 'boot' OKAY [0.740s]`。
随后刷回 `boot-venus-oc-100.img`，p12 的 sha256 与测试前备份**逐字节一致**。

### 3. 刷 rootfs：可行，但有两个坑

刷 `venus.ext4`（1019M）成功：

```
Sending sparse 'rootfs' 1/4 (190568 KB)  OKAY
Writing 'rootfs'                         OKAY [  23.555s]
... 4 个分片 ...
Finished. Total time: 202.691s
```

刷完 fs UUID 精确变成镜像的 `0a861856…`、Block count 与镜像一致，系统正常启动。

**坑 1：`-S` 是必需的，且分片上限受 LK 约束。**
`fastboot getvar max-download-size` 实测 = `0x10000000`（256 M）。~1G 的镜像
一次传不完，必须 `-S`（官方用 `-S 200M`；实测 1019M 的镜像分 5 片、204 秒）。

**坑 2：不处理的话可用空间只剩 111M——现已由镜像自动解决。**
rootfs 镜像（~1G）比 `rootfs` 分区（3.4G）小，写入后文件系统仍是镜像的大小：

```
$ df -h /
/dev/root  930M  755M  111M  88% /      <- 不做处理时的状态
```

镜像的 `/etc/fstab` 现在给 root 行带了 `x-systemd.growfs`，开机时
`systemd-growfs-root.service` 自动拉伸。**实测刷完即 `3.3G 总 / 2.4G 可用`，
无需任何手工步骤。** 老镜像没有这一项，需要手动：

```sh
resize2fs /dev/mmcblk0p14
# => The filesystem on /dev/mmcblk0p14 is now 871931 (4k) blocks long.
```

`verify-layout.sh` 会断言 `x-systemd.growfs` 存在。

**不要刷「等于分区大小的整分区读回」。** 我一开始拿 3.4G 的整分区备份回刷，LK
直接拒绝：

```
error: write_sparse_skip_chunk: don't care size ... is not a multiple of the block size 4096
Writing 'rootfs'  FAILED (remote: 'size too large')
```

要刷的是 **rootfs 文件系统镜像**（`artifacts/rootfs/*.ext4`），不是分区 dump。

### 4. 返回 Linux

| 命令 | 实测结果 |
|---|---|
| `fastboot continue` | `Resuming boot OKAY`，直接引导内核，设备正常回 Linux |
| `fastboot reboot` | 重新走一遍 LK，正常回 Linux |

### 5. 一个容易误判的打印

LK 会打印 `pm8x41_get_is_cold_boot: cold boot`，**A 和 B 两种情况都会打印它**，
所以它反映的是上电/复位类型，不能用来判断有没有进 bootloader 模式。判断依据是
有没有出现 `fastboot_init()`。

LK 支持的命令（`fastboot oem help` 实测输出）：

```
upload            download:         getvar:           oem help
oem dump-speedbin oem dump-rpm-data-ram  oem dump-saw2   oem dump-boot-rom
oem dump-smd-rpm  oem dump-regulators    oem reboot-edl  oem lk_log  oem dump
reboot-bootloader reboot            continue          boot
erase:            flash:
```

返回 Linux 的两种方式（都实测通过）：

```sh
fastboot continue     # 直接引导内核，不重新走 LK 上电流程
fastboot reboot       # 重新启动（会重新走一遍 LK）
```

## 为什么能行：完整链路

```
systemctl reboot --reboot-argument=bootloader
  → systemd 把 "bootloader" 存为 reboot 参数（logind set-reboot-parameter）
  → systemd-shutdown 读取该参数，打印 "Rebooting with argument 'bootloader'."
  → reboot(2) 把 "bootloader" 传给内核
  → kernel_restart_prepare() 先跑 reboot notifier（kernel/reboot.c:100-106）
  → qcom-pon 驱动匹配到 mode-bootloader，把 0x2 写进 PM8916 的
    PON_SOFT_RB_SPARE（0x8f），位域 bits[7:2]
  → machine_restart() 复位
  → aboot（LK）启动时读 pon_reason，看到 2 → 进入 fastboot
```

关键点：写魔法值发生在**复位之前**（`kernel_restart_prepare` 里的 notifier
链先执行，`machine_restart` 在其后），所以顺序不会反。

另外，只有 cmd 命中已配置的 mode 才会写寄存器（`reboot-mode.c` 的
`get_reboot_mode_magic()` 匹配不上就返回 0，`magic` 为 0 时**不写**）。
这正是 A 测试（无参数 → `"normal"` → 我们没配 `mode-normal`）不进 fastboot 的原因，
也说明这个机制**不会污染普通重启**。

## 证据（都是实测/实机读出来的，不是推测）

| 环节 | 证据 |
|---|---|
| 内核支持 | `CONFIG_POWER_RESET_QCOM_PON=m`、`CONFIG_REBOOT_MODE=y`；`drivers/power/reset/qcom-pon.c` 存在 |
| 驱动已加载 | 实机 `lsmod` 有 `qcom_pon`；`/sys/bus/platform/drivers/qcom-pon/200f000.spmi:pmic@0:pon@800` 已绑定 |
| 设备树已配 | 实机 `.../pon@800/of_node/` 下确实有 `mode-bootloader`，值为 `00000002`，`mode-recovery` 为 `00000001` |
| 用的是 PON 寄存器 | `qcom-pon.c` 写 `PON_SOFT_RB_SPARE(0x8f)`，pm8916 用 `GEN1_REASON_SHIFT=2` |
| aboot 是 OpenStick LK | 设备 `mmcblk0p11` 前 287488 字节与 OpenStick release 的 `base/aboot.bin` 逐字节相同（sha256 `683f464f…`），串口实测打印 `OpenStick Bootloader V0.01` |
| 官方就是这么刷的 | OpenStick `base/flash.sh` 里直接写了 `fastboot reboot bootloader` |

内核侧默认值来自 mainline：`arch/arm64/boot/dts/qcom/pm8916.dtsi` 的 `pon@800`
本来就带 `mode-bootloader = <0x2>`，我们的板级 DTS 没有改它，所以**不需要任何
补丁**。

## 刷机流程

### 前提（重要）

**设备的 USB 数据口必须连到执行 fastboot 的那台机器上。** LK 的 fastboot 只从
USB 收命令，没有超时自动回落（aboot 里没有任何 fastboot timeout 逻辑）。如果数据
口只接了充电器，重启进 fastboot 后设备会停在那里，直到有人把数据线插到电脑上。
实测时设备接在主机 USB hub 的 `3-2.4.4` 端口。

### 步骤

```sh
# 1) 进入 fastboot（从在跑的 Linux 里；主机侧约需等 96 秒才枚举出来）
systemctl reboot --reboot-argument=bootloader

# 2) 主机上确认设备出现（LK 的 fastboot VID:PID 是 18d1:d00d）
fastboot devices

# 3) 刷 boot（本板变体见 boards/ufi00x/ufi103s-ufi003/README.md）
fastboot flash boot artifacts/boot/ufi103s-ufi003/boot-board-venus-4g-gpu-7.2.9.img

# 4) 刷 rootfs。-S 必需：LK 的 max-download-size 只有 256M，而 max 档己 2G。
#    刷的是 rootfs 文件系统镜像，不是 3.4G 的整分区 dump（后者会被 LK 拒绝）。
fastboot -S 200M flash rootfs artifacts/rootfs/ufi103s-7.2.9-max.ext4

# 5) 正常启动
fastboot reboot

# 6) 不需要手动撑满：镜像 fstab 里的 x-systemd.growfs 会在开机时自动拉伸。
#    只有刷老镜像（fstab 无该项）时才需要：
#    ssh root@<设备IP> resize2fs /dev/mmcblk0p14
```

分区名用 GPT 里的名字，小写：`boot`（p12）、`rootfs`（p14）。LK 侧打印的分区表：

```
ptn[11]:Name[boot]    First[526336] Last[657407]
ptn[13]:Name[rootfs]  First[659456] Last[7634910]
```

只刷这两个，不要碰 `aboot`/`modem`/`NV` 等。

**关于空间**：镜像 ~1G、分区 3.4G，镜像的 fstab 带 `x-systemd.growfs`，
开机自动撑满（实测刷完即 2.4G 可用）。若刷的是不带该项的老镜像，仍需手动
`resize2fs /dev/mmcblk0p14`。见上面「实测结果 3」。

`flash.sh` 已经把这套流程封装好了，见 `flash.sh enter-fastboot` 等子命令
（`fastboot-flash rootfs` 会打印 resize2fs 提醒）。

## OpenStick 官方原文（对照）

`base/flash.sh`（装 aboot/GPT 等底层，**本工作区不需要**，因为我们的 GPT 与
aboot 已就绪）：

```sh
fastboot erase boot
fastboot flash boot lk2nd.img
fastboot reboot
...
fastboot reboot bootloader
```

`debian/flash.sh`（装系统，与我们要做的对应）：

```sh
fastboot -S 200M flash rootfs rootfs.img
fastboot flash boot boot.img
fastboot reboot
```

注意官方的 `base/flash.sh` 会**重写 GPT 和 aboot**（腾空间、换引导）。我们的
分区表是原厂的，`rootfs` 有 3.4GB，装 0.4–1GB 的 rootfs 绰绰有余，所以**不要**
跑那个 base 流程。

## 进 EDL 的两种路子

- **从 fastboot 进**：`fastboot oem reboot-edl`（LK 自带，`oem help` 里已确认，
  OpenStick wiki 也有记录）。比按 reset 按钮方便。**未实测**（不想无故进 EDL）。
- **按 reset 按钮（或把 reset 触点与地短接）后插电脑**：最可靠，任何时候都能用。

另外 mainline 的 `qcom_scm` 支持 `qcom,dload-mode`（通过 `download_mode` 模块参数
设置后下次热启动进下载模式），这条**未实测**且语义与 EDL 不完全等同，先不要依赖。

## 风险与恢复

| 情况 | 处理 |
|---|---|
| 重启进 fastboot 后电脑看不到设备 | 数据线没接到这台机器。把数据口插到电脑即可，LK 会立刻被识别 |
| 等了几十秒还没出现 fastboot 设备 | 正常。实测需约 96 秒，别急着判定失败 |
| 在 fastboot 里想放弃刷机直接开机 | `fastboot continue`（实测可用） |
| 刷 rootfs 报 `size too large` | 刷错对象了。要刷 `artifacts/rootfs/*.ext4`（~1G），不是 3.4G 的整分区 dump |
| 刷完 rootfs 后 `df /` 只有 930M | 镜像缺 `x-systemd.growfs`（老镜像）。手动 `resize2fs /dev/mmcblk0p14` 可从 111M 恢复到 2.4G |
| fastboot 下刷错变体 | 重新 `fastboot flash boot <正确变体>` |
| 刷完开不了机 | 回到 fastboot 刷回原变体；必要时用 `recovery/original/boot-original-p12.img` |
| 完全进不去 | 按 reset 进 EDL，用 Miko 恢复整片备份 |

**刷任何东西之前先用 Miko 做整片 eMMC 全量备份**，这是硬要求。

## 实测记录

- 2026-09-14，本机 6.18.49-ufi003-venus-dirty：
  - **进 fastboot**：A（无参数 → 回 Linux）/ B（`--reboot-argument=bootloader` →
    进 fastboot），B 重复 2 次都成功；耗时约 96 秒。
  - **刷 boot**：`boot-baseline.img` 刷入后 `uname -r` 由
    `…-venus-dirty` 变为 `…-dirty`；再刷回 `boot-venus-oc-100.img`，p12 的 sha256
    与测试前备份逐字节一致。
  - **刷 rootfs**：`venus.ext4`（1019M）用 `-S 200M` 分 5 片、204 秒刷入成功，
    fs UUID 与 Block count 均与镜像一致。踩到并解决了两个坑：整分区 dump 会被拒
    （size too large）；后续镜像加了 fstab 的 x-systemd.growfs，刷完自动撑满
    （111M → 2.4G 无需手工）。
  - **返回**：`fastboot continue` 与 `fastboot reboot` 均正常回 Linux。
  - 测试后设备 state：systemd running、0 failed、WiFi 与 ModemManager 正常。
