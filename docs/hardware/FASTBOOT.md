# fastboot 刷机

本文说明当前 7.2.9 产物的刷机方法。旧内核和已删除镜像的历史实测不再保留；
分区与刷机前的原始备份仍按项目要求保存。

## 刷机前

1. **先备份。** 用 Miko 做整片 eMMC 备份；至少读回准备修改的分区。
2. 只允许修改 `boot`（`mmcblk0p12`）和 `rootfs`（`mmcblk0p14`）。
   不要修改 GPT、aboot、modem、NV 或其它分区。
3. 确认 boot 镜像与模块树属于同一 release，rootfs 中也装有对应模块。
4. 刷入前核对同目录 `build.json` 中的 sha256。

设备 USB 数据口必须连接到运行 fastboot 的电脑。LK 没有 fastboot 超时退出机制，
只接充电器时设备会停在 fastboot 界面。

## 进入 fastboot

在设备当前系统中执行：

```sh
systemctl reboot --reboot-argument=bootloader
```

必须使用 `--reboot-argument=`；`systemctl reboot bootloader` 会报参数错误。
主机侧可能需要等待约一分半，再确认：

```sh
fastboot devices
```

LK 的 USB ID 为 `18d1:d00d`。

## 刷入

下面以 UFI103s 的 `venus-4g-gpu` 变体为例，实际文件按板型和变体调整：

```sh
# boot：内核与 appended DTB
fastboot flash boot artifacts/boot/ufi103s-ufi003/boot-board-venus-4g-gpu-7.2.9.img

# rootfs：纯 ext4 文件系统镜像，不是整分区 dump
# LK 的 max-download-size 为 256MB，大镜像需要分片
fastboot -S 200M flash rootfs artifacts/rootfs/ufi103s-7.2.9-max.ext4

fastboot reboot
```

也可以使用 `flash.sh fastboot-flash`，它会校验 `build.json`。
分区名按设备 GPT 填写；本项目设备使用小写的 `boot` 和 `rootfs`。

新镜像的 `/etc/fstab` 带有 `x-systemd.growfs`，首次启动会自动扩展根文件系统，
不需要手动执行 `resize2fs`。

## root= 与 cmdline

实际 cmdline 以各镜像 `build.json` 为准：

- **UFI103s 已发布镜像**使用 `root=PARTUUID=a7ab80e8-e9d1-e8cd-f157-93f69b1d141e`。
  该值来自作者机器的 GPT；用于其它机器或不同分区表时，需要按实际情况覆盖。
- **MF601SL** 使用 `root=/dev/mmcblk0p14`，不依赖 GPT UUID。前提是 p14 确实是
  rootfs；容量不匹配时 fastboot 写入会直接失败。

需要临时覆盖时，不必重新打包：

```sh
fastboot -c "earlycon console=ttyMSM0,115200 root=<实际值> rw rootwait" boot <boot.img>
```

## 常见问题

| 情况 | 处理 |
|---|---|
| 重启后电脑没有 fastboot 设备 | 检查 USB 数据线；LK 只从 USB 接收 fastboot 命令 |
| 等了一分钟仍未出现 | 继续等待并重新运行 `fastboot devices`，不要立即判定失败 |
| 不刷机，直接启动 | `fastboot continue` |
| rootfs 报 `size too large` | 检查是否误刷了整分区 dump；应刷 `artifacts/rootfs/*.ext4`，并使用 `-S 200M` |
| 刷错 boot 变体 | 重新刷入正确变体，并确认 rootfs 中的模块树匹配 |
| 刷完无法启动 | 回 fastboot 刷回已验证镜像；必要时使用分区读回副本 |
| 完全无法进入系统或 fastboot | 按 reset 进 EDL，用 Miko 恢复备份 |

## 进入 EDL

- fastboot 中可执行 `fastboot oem reboot-edl`。
- 也可按住 reset 键（或短接 reset 触点与地）后接入电脑。

EDL 恢复涉及整片和底层分区，操作前必须确认备份与 loader 与设备匹配。
本项目只使用 Miko 自带的 MSM8916 loader；公开 Firehose loader 不被这些设备接受。

## 机制说明

`systemctl reboot --reboot-argument=bootloader` 会把参数交给内核。
重启准备阶段，`qcom-pon` 驱动将设备树 `mode-bootloader` 对应的值写入 PM8916
的 PON 寄存器；LK 随后读取该状态并进入 fastboot。普通重启不写这个模式值。

该功能由 mainline 的 `qcom-pon` 与 `reboot-mode` 提供，不需要本项目额外补丁。
`fastboot continue` 直接继续启动，`fastboot reboot` 则重新经过 LK。
