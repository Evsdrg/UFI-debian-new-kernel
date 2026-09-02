# 当前系统 vs 构建系统镜像大小对比

采样时间：2026-09-02
目标设备：Handsome OpenStick UFI103s (`qcom,msm8916`)

## Boot 分区

| 项目 | 当前原厂 | 构建的 6.18 GCC | 说明 |
|---|---:|---:|---|
| 分区容量 | 64MiB | 64MiB | `/dev/mmcblk0p12`，原厂分区固定容量 |
| boot.img 文件 | 64MiB dump（含大量尾部空闲） | 10.45MiB | 构建文件是写入分区时的有效镜像大小 |
| 解出的 kernel blob | 9.06MiB | 10.45MiB（Image.gz+DTB） | 原厂 kernel blob 也是 gzip+DTB |
| 解出的 ramdisk | 6.34MiB | 0 | 新镜像使用空 ramdisk，直接从 p14 挂 Debian rootfs |
| 原厂有效 payload | 约 15.40MiB | - | kernel + ramdisk，未计 boot header 对齐 |

新镜像和原镜像的 boot header 参数一致：page size 2048、kernel base `0x80078000`、kernel offset `0x8000`、ramdisk offset `0x1f88000`、second offset `0xe88000`、tags offset `0x1d88000`。

## Rootfs

| 项目 | 当前设备 Debian 11 | 构建的 Debian 13 |
|---|---:|---:|
| 根分区容量 | 3.33GiB | 3.33GiB（目标 p14 不变） |
| 实际已用 | 约 2.2GiB | 预计约 362MiB |
| 可见文件树 | 约 2.2GiB | 362MiB allocated / 348MiB apparent |
| 压缩传输包 | - | 129.5MiB (`trixie-rootfs.tar.gz`) |
| 可用空间（粗略） | 约 945MiB | 约 3.0GiB |

当前系统 `du -xhd1 /`：`/usr` 597MiB、`/var` 721MiB、`/boot` 33MiB，总计约 2.2GiB。这个数字包含当前系统长期运行产生的软件、日志、缓存和用户数据，不是纯基础系统大小。

新 rootfs `/usr` 约 354MiB，包含 Debian 13 用户空间、NetworkManager/ModemManager/libqmi/qrtr/rmtfs、6.18 模块和从现机提取的固件；`/var` 约 6.7MiB，apt 缓存已清理。

## 关键组成

- 新内核模块：约 45MiB（`6.18.48-ufi003-dirty`）
- 现机固件：约 46MiB（完整 `/lib/firmware`，含 modem/wcnss/WCNSS NV）
- 新 rootfs 包：约 201MiB（此前旧模块版）；切换精简模块后为 129.5MiB
- 新 rootfs 目录：约 362MiB

## 结论

1. boot 分区容量完全足够：新 boot.img 仅占 10.45MiB/64MiB，余量约 53.5MiB。
2. p14 容量也足够：新 rootfs 约 362MiB/3.33GiB，理论余量约 3.0GiB。
3. 新系统比当前设备的根文件树小约 6.2 倍，但这是“全新最小 Debian 13 + 必需组件”对比“现有长期运行 Debian 11”的结果，不能视作发行版本身的绝对差异。
4. 新 boot 没有原厂 ramdisk；因此阶段1只刷 boot 时必须确认 6.18 能识别 eMMC、WCNSS 和 modem，再进行阶段2根文件系统替换。

产物：
- `out/boot/boot-original-p12.img`
- `out/boot/boot-ufi003-6.18.img`
- `out/trixie-rootfs.tar.gz`
