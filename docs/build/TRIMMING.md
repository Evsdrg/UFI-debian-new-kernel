# 系统精简：档位（flavor）与体积

`tools/build-matrix.sh` 一键产出 **7 个 rootfs**：四档 × 两种网络栈。档位是
`ROOTFS_FLAVOR`（`max` / `basic` / `slim` / `micro`），网络栈是 `ROOTFS_NET`
（`nm` / `native`）；裁剪用包集合 + dpkg `path-exclude`，**不是复制脚本**。

矩阵的完整定义（各档的功能集、内核/DTB 配对）见 `BUILD-MATRIX.md`。

## 档位 × 网络栈（2026-10-07，内核 7.2.9 实测）

| 镜像 | 档位 | 网络栈 | 文件体积 | 内容体积 | 4G | 蓝牙 | 中文 | 桌面/GPU |
|---|---|---|---|---|---|---|---|---|
| `ufi103s-7.2.9-max.ext4` | max | NM | 2.0G | 1.6G | ✅ | ✅ | ✅ | i3+xrdp+GPU |
| `…-basic.ext4` | basic | NM | 404M | 317M | ✅ | ✅ | ✅ | ✗ |
| `…-basic-native.ext4` | basic | native | 383M | 300M | ✅ | ✅ | ✅ | ✗ |
| `…-slim.ext4` | slim | NM | 326M | 256M | ✗ | ✗ | ✅ | ✗ |
| `…-slim-native.ext4` | slim | native | 296M | 232M | ✗ | ✗ | ✅ | ✗ |
| `…-micro.ext4` | micro | NM | 301M | 234M | ✗ | ✗ | ✗ | ✗ |
| `…-micro-native.ext4` | micro | native | 271M | 211M | ✗ | ✗ | ✗ | ✗ |

**两个体积口径别混用**：

- **文件体积**（`ls -l`）：下载/传输看到的数，也是分发仓里列的数。
- **内容体积**：已用块 × 块大小 —— `dumpe2fs -h <镜像>` 的
  `(Block count - Free blocks) × Block size`，代表实际装了多少东西。
  mmdebstrap 按内部估算给 ext4 留了空闲块与 inode 表，所以文件体积比内容体积
  大一截（micro：301M vs 234M）。刷到设备后 fstab 的 `x-systemd.growfs` 会把
  文件系统撑满 3.3GB 分区，所以这些预留**不占实机空间**，但对**分发文件**
  （下载/传输）是实打实的体积。

用 `ROOTFS_SHRINK=1` 可把文件收掉这部分：先 `resize2fs -M` 压到最小，再加
**固定 32MB 余量**（不是按比例——growfs 才是实际扩容手段，镜像内余量只需够
growfs 之前那几秒的写入）。实测 tiny：**299MB → 267MB**（最小 235MB）。

> 陷阱：不要用 `du -sm` 在 `-M` **之前**去量基准——它对**文件**返回的是文件
> 大小而非内容占用，拿这个数再加 25% 反而会得到比原文件更大的镜像（踩过）。
> 余量也别用 `-M` 后的最小值按百分比放大（25% 就是 58MB，过肥）。

## 四个正交开关

档位只给默认值，四个维度本身是**正交开关**，可以单独覆盖：

| 开关 | 默认（max / basic / slim / micro） | 作用 |
|---|---|---|
| `ROOTFS_ZH` | `1 / 1 / 1 / 0` | 中文 locale + NM 翻译（关掉则用 `C.UTF-8`） |
| `ROOTFS_BT` | `1 / 1 / 0 / 0` | bluez（蓝牙用户态） |
| `ROOTFS_4G` | `1 / 1 / 0 / 0` | ModemManager/qmi/qrtr/rmtfs + modem 固件 |
| `ROOTFS_NET` | `nm`（全部档位） | `nm`=NetworkManager；`native`=networkd+wpa_supplicant+nftables |

所以「无 4G 但保留中文与蓝牙」= `ROOTFS_FLAVOR=micro ROOTFS_ZH=1 ROOTFS_BT=1`。

内容体积一律用上面那个"已用块"口径；**不要用 ext4 文件大小比较**
（mmdebstrap 会按内部估算 padding，同一内容可能有 ±40MB 差异）。

四档都保留：SSH、**nmtui**（NM 档）/ `wpa_cli`（native 档）、
NetworkManager 或 networkd、zram swap、LED 状态服务、fstab 的
`x-systemd.growfs`、串口 getty。

## 用法

```sh
# 全矩阵 7 个镜像（档位 × 网络栈）。镜像不预置 Wi-Fi（见上）。
bash tools/build-matrix.sh

# 只建其中几个
bash tools/build-matrix.sh max basic-native

# 单个档位，且不用 build-matrix 的配对表时，直接调 build-rootfs.sh：
MMDEBSTRAP_FORMAT=ext4 TMPDIR="$PWD/out/tmp" \
KERNEL_RELEASE=7.2.9-ufix0x-venus-4g-gpu-dirty \
MODULE_TREE=$PWD/artifacts/modules/7.2.9-ufix0x-venus-4g-gpu-dirty \
EXTRA_MODULE_TREES=$PWD/artifacts/modules/7.2.9-ufix0x-dirty \
EXTRA_FIRMWARE_DIR=$PWD/artifacts/firmware/ufi103s-venus \
ROOTFS_PATH=$PWD/artifacts/rootfs/ufi103s-7.2.9-max.ext4 \
EXTRA_PKGS="ffmpeg,v4l-utils" ROOTFS_DESKTOP=1 \
ROOTFS_FLAVOR=max ROOTFS_NET=nm \
bash build-rootfs.sh

# 想进一步收掉文件的 padding（分发用），加 ROOTFS_SHRINK=1
# 另可显式控制正交开关：
#   ROOTFS_ZH=1 ROOTFS_BT=1 ROOTFS_4G=0 ROOTFS_NET=native
```

## 精简从哪儿省出来的

原始镜像（max）里 `/usr` 占绝大部分，主要几块：

| 项 | 体积 | 处理 |
|---|---|---|
| `libLLVM.so.*` + `mesa-libgallium` | **151 MB** | 精简档位不装 mesa（GPU 是 render-only，无显示面板，本来也用不上） |
| `usr/share/doc` + `man` + `usr/share/locale` | 114 MB | `path-exclude`（保留各包 `copyright`，Debian 政策要求） |
| `modem.*` 固件（4G） | **39 MB** | 关掉 4G 时删除（不装 ModemManager、不加载 modem 模块，固件永不被读取） |
| `usr/share/i18n` + `locales`（中文） | **~23 MB** | 关掉中文时删除（`i18n` 17MB 是大头），改用 libc-bin 内建的 `C.UTF-8` |
| `bluez`（蓝牙） | **~5.2 MB** | 关掉蓝牙时删除。注意 `network-manager` 依赖 `libbluetooth3`(336KB)，那个小库去不掉 |

体积大头来自 **mesa → libLLVM**：连一个只做 3D 渲染的 render 节点都要拖进
一百多 MB 的 LLVM。若将来要做 GPU 分区镜像，这是首先要解决的依赖。


内核侧本已精简：单棵模块树 26MB，最大子系统（`drivers/net`）仅 2.4MB，
可压缩空间远小于固件与 mesa。

## 两个构建陷阱（都实测踩过）

1. **`/etc/default/locale` 是符号链接**，指向 `../locale.conf`。往它里面 `cp`
   会两难：链接悬空时 `cp` 直接拒绝（`not writing through dangling symlink`），
   而它是否有效取决于 `locales` 包是否安装 —— 所以"关掉中文"会连带把这条路径
   搞坏。**解法：写规范目标 `/etc/locale.conf`**（systemd 与 PAM 都直接读它），
   并且用 `grep LANG= /etc/locale.conf` 断言，不用 `update-locale`。
2. **语言 hook 必须放在 STAGE 拷贝之后**。它们要断言镜像里的
   `/etc/locale.conf`，放在拷贝之前会因文件还不存在而失败
   （`command failed: grep -q ... /etc/default/locale`）。数组里 hook 的顺序
   就是执行顺序，别只看逻辑顺序。

## 模块树必须与内核配对（不是精简缺陷，是使用前提）

`MODULE_TREE` 的 release 必须与要刷的那个 boot 镜像的内核 release **一致**，
否则开机 `modprobe` 找不到模块。曾出现过模块树与测试内核不配套、
QEMU 中 `zram-setup.service` 失败的情况；换成配对模块树后恢复正常。
**QEMU 冒烟的通过标准应包含"无 FAILED 单元"**，不要只看有没有到 login。

7.2.9 起配对关系是：max ↔ `…-venus-4g-gpu-dirty`，basic ↔ `…-4g-dirty`，
slim / micro ↔ `…-dirty`（基线）或 `…-minimal-dirty`（最简功能内核，内存最大化）。
`tools/build-matrix.sh` 内置这张表。

**何时选 minimal**：slim / micro 档位不跑 GPU、不跑硬件编解码、不跑 4G，
而 `minimal` 内核正是把这三大链从**内核配置**里裁掉（不只是设备树里 disabled），
换来更小的内核镜像与模块树。两者配对但不相依赖：slim/micro 也可以配基线内核，
只是占用更多 flash。实测数据见
[`../build/BUILD-MATRIX.md`](../build/BUILD-MATRIX.md) 第二节。

## 必须显式声明的包（否则镜像不可启动）

### `systemd-sysv` —— 提供 `/usr/sbin/init`

它**只是 `systemd` 的 Recommends**。`micro` 档位移除 4G 包后依赖链断裂，
镜像里没有 `/sbin/init`，内核依次尝试 `/sbin/init`→`/etc/init`→`/bin/init`
全部失败，**落到 `/bin/sh`，系统起不来**（无 SSH、无网络，刷到真机只能
按复位键走 EDL 恢复）。

已把 `systemd-sysv` 显式列入 `PKGS_BASE`。这个缺陷是**用 QEMU 冒烟测试发现的**
（见下节），从文件清单上完全看不出来。

### `bluez` / `rfkill` —— 蓝牙用户态

详见 `BLUETOOTH.md`。内核有 `hci0` 但没有 `bluetoothctl` 的话，蓝牙等于不可用。

## QEMU 冒烟测试（改档位 / 砍包后必做）

设备只能从**运行中的系统**进 fastboot；若新 rootfs 起不来就只能物理复位，
所以刷 rootfs 前应先在不碰真机的前提下验证可启动性。

```sh
# 全部 7 个镜像（自动按档位配上对应的内核 Image.gz）
bash tools/smoke-all.sh

# 单个镜像
tools/qemu-smoke.sh artifacts/rootfs/ufi103s-7.2.9-micro-native.ext4 \
                   build/variant-7.2.9-board-baseline/arch/arm64/boot/Image.gz
```

`tools/qemu-smoke.sh` 自己做三件事：从 boot 构建树里取裸 `Image`、把镜像
复制一份改成可写（`/etc/fstab` 改成 `/dev/vda`、加 `serial-getty@ttyAMA0`）、
按设备规格（`-M virt -cpu cortex-a53 -smp 4 -m 376`，与真机 376MB 一致）启动
并抓串口。

**通过标准**：出现 `ufi103s login:`（或 `Welcome to Debian GNU/Linux 13`），
且没有**非预期**的 FAILED 单元。日志落在 `out/qemu-test/`。

### 预期内的假故障

QEMU 里没有高通硬件，所以下列失败是**正常的**，不要当成缺陷：

- `rmtfs.service` 超时（等 `/dev/qrtr*` 与 ttyMSM0）
- `dev-ttyMSM0.device` 超时
- 无 `wlan0`/`wwan0`（`wcn36xx` 没有对应硬件）

真机上这些服务是 `active (running)`。

## 实机状态

**当前验证状态**：七张 rootfs 均通过 QEMU 冒烟；max 档已随
`venus-4g-gpu` 内核在 UFI103s 上整机刷入验收，minimal 内核已通过内存启动验证。
其余档位与变体的整机组合尚未完整覆盖，详见
[`../validation/README.md`](../validation/README.md)。

刷机命令与回退方式见 `boards/ufi00x/ufi103s-ufi003/README.md`。
**刷机时 boot.img 与 rootfs 必须按档位成对**（见上"模块树必须与内核配对"）。
