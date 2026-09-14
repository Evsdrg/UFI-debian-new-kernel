# fastboot 刷机（MSM8916 OpenStick）

**结论：可以在 Linux 里直接重启进 fastboot。** 在我们的 6.18 镜像上，机制是从
内核到 aboot 全程打通的；命令是

```sh
systemctl reboot bootloader
```

> 注意不能写 `reboot bootloader`：Debian 里 `/sbin/reboot` 是 `systemctl` 的
> 符号链接，参数不会像 busybox/Android 那样透传，必须用 `systemctl reboot <arg>`。

## 为什么能行：完整链路

```
systemctl reboot bootloader
  → systemd 把 "bootloader" 存为 reboot 参数（logind set-reboot-parameter）
  → systemd-shutdown 读取该参数
  → reboot(2) 把 "bootloader" 传给内核
  → kernel_restart_prepare() 先跑 reboot notifier（kernel/reboot.c:100-106）
  → qcom-pon 驱动匹配到 mode-bootloader，把 0x2 写进 PM8916 的
    PON_SOFT_RB_SPARE（0x8f），位域 bits[7:2]
  → machine_restart() 复位
  → aboot（LK）启动时读 pon_reason，看到 2 → 进入 fastboot
```

关键点：写魔法值发生在**复位之前**（`kernel_restart_prepare` 里的 notifier
链先执行，`machine_restart` 在其后），所以顺序不会反。

## 证据（都是实测/实机读出来的，不是推测）

| 环节 | 证据 |
|---|---|
| 内核支持 | `CONFIG_POWER_RESET_QCOM_PON=m`、`CONFIG_REBOOT_MODE=y`；`drivers/power/reset/qcom-pon.c` 存在 |
| 驱动已加载 | 实机 `lsmod` 有 `qcom_pon`；`/sys/bus/platform/drivers/qcom-pon/200f000.spmi:pmic@0:pon@800` 已绑定 |
| 设备树已配 | 实机 `.../pon@800/of_node/` 下确实有 `mode-bootloader`，值为 `00000002`，`mode-recovery` 为 `00000001` |
| 用的是 PON 寄存器 | `qcom-pon.c` 写 `PON_SOFT_RB_SPARE(0x8f)`，pm8916 用 `GEN1_REASON_SHIFT=2` |
| aboot 是 OpenStick LK | 设备 `mmcblk0p11` 前 287488 字节与 OpenStick release 的 `base/aboot.bin` 逐字节相同（sha256 `683f464f…`），含 `OpenStick Bootloader V0.01`、`fastboot`、`reboot-bootloader`、`oem reboot-edl` |
| 官方就是这么刷的 | OpenStick `base/flash.sh` 里直接写了 `fastboot reboot bootloader` |

内核侧默认值来自 mainline：`arch/arm64/boot/dts/qcom/pm8916.dtsi` 的 `pon@800`
本来就带 `mode-bootloader = <0x2>`，我们的板级 DTS 没有改它，所以**不需要任何
补丁**。

## 刷机流程

### 前提（重要）

**设备的 USB 数据口必须连到执行 fastboot 的那台机器上。** LK 的 fastboot 只从
USB 收命令，没有超时自动回落（aboot 里没有任何 fastboot timeout 逻辑）。如果数据
口只接了充电器，重启进 fastboot 后设备会停在那里，直到有人把数据线插到电脑上。

### 步骤

```sh
# 1) 进入 fastboot（从在跑的 Linux 里）
systemctl reboot bootloader

# 2) 主机上确认设备出现（LK 的 fastboot VID:PID 是 18d1:d00d）
fastboot devices

# 3) 刷 boot（本板变体见 boards/ufi00x/ufi103s-ufi003/README.md）
fastboot flash boot boards/ufi00x/ufi103s-ufi003/boot/boot-venus-oc-burst.img

# 4) 刷 rootfs（大镜像要带 -S，官方用 200M）
fastboot -S 200M flash rootfs shared/rootfs/debian13-arm64-ufi103s-6.18.49-venus-led.ext4

# 5) 正常启动
fastboot reboot
```

分区名用 GPT 里的名字，小写：`boot`（p12）、`rootfs`（p14）。只刷这两个，不要碰
`aboot`/`modem`/`NV` 等。

`flash.sh` 已经把这套流程封装好了，见 `flash.sh enter-fastboot` 等子命令。

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

- **从 fastboot 进**：`fastboot oem reboot-edl`（LK 自带，OpenStick wiki 有记）。
  这比按 reset 按钮方便。
- **从代码进**：mainline 的 `qcom_scm` 支持 `qcom,dload-mode`，通过
  `download_mode` 模块参数设置后下一次热启动会进下载模式。这条**没有实测**，
  且语义与 EDL 不完全等同，先不要依赖。
- **按 reset 按钮（或把 reset 触点与地短接）后插电脑**：最可靠，任何时候都能用。

## 风险与恢复

| 情况 | 处理 |
|---|---|
| 重启进 fastboot 后电脑看不到设备 | 数据线没接到这台机器。把数据口插到电脑即可，LK 会立刻被识别 |
| fastboot 下刷错变体 | 重新 `fastboot flash boot <正确变体>` |
| 刷完开不了机 | 回到 fastboot 刷回原变体；必要时用 `recovery/original/boot-original-p12.img` |
| 完全进不去 | 按 reset 进 EDL，用 Miko 恢复整片备份 |

**刷任何东西之前先用 Miko 做整片 eMMC 全量备份**，这是硬要求。

## 还没做的一步

本文的机制部分是**源码 + 实机只读检查**得出的，没有做「真的重启一次看它进不进
fastboot」的端到端实测——因为当前无法确认设备的数据口是否接在本机上，贸然重启
有把设备停在 fastboot 的风险（见上面的前提）。等确认数据线接在本机，跑一次
`flash.sh enter-fastboot` 即可补上这一步。
