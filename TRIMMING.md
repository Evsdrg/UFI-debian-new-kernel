# 系统精简：档位（flavor）与体积

`build-rootfs.sh` 支持 `ROOTFS_FLAVOR=full|minimal|tiny`，用包集合 + dpkg
`path-exclude` 裁剪，**不是复制脚本**。

## 三档对比（7.1.13，实测内容体积）

| 档位 | 内容体积 | 含什么 | 不含什么 |
|---|---|---|---|
| `full`（默认） | **760 MB** | 桌面(xrdp+i3)、GPU/mesa、4G、man、中文、蓝牙 | — |
| `minimal` | **294 MB** | **nmtui** + 完整 4G、SSH、蓝牙、中文、zram、LED | 桌面、mesa、man |
| `tiny` | **239 MB** | **nmtui**、SSH、蓝牙、中文、zram、LED | 桌面、mesa、man、**4G** |

内容体积 = 把镜像 loop 挂载后 `du -sm`；**不要用 ext4 文件大小比较**
（mmdebstrap 会按内部估算 padding，同一内容可能有 ±40MB 差异）。

三档都保留：SSH、NetworkManager + **nmtui**、中文 locale（`zh_CN.UTF-8`）、
zram swap、LED 状态服务、fstab 的 `x-systemd.growfs`、串口 getty。

## 用法

```sh
ROOTFS_FLAVOR=minimal MMDEBSTRAP_FORMAT=ext4 TMPDIR="$PWD/out/tmp" \
KERNEL_RELEASE=7.1.13-ufi003-venus-dirty \
MODULE_TREE=$PWD/shared/modules/7.1.13-ufi003-gpu \
EXTRA_MODULE_TREES=$PWD/shared/modules/7.1.13-ufi003-dirty \
ROOTFS_PATH=$PWD/out/debian13-arm64-ufi103s-7.1.13-minimal.ext4 \
ROOTFS_WIFI_SSID='<ssid>' ROOTFS_WIFI_PSK='<psk>' \
bash build-rootfs.sh
```

## 精简从哪儿省出来的

原始镜像 760MB 里 `/usr` 占 736MB，主要三块：

| 项 | 体积 | 处理 |
|---|---|---|
| `libLLVM.so.19.1` + `mesa-libgallium` | **151 MB** | 精简档位不装 mesa（GPU 是 render-only，无显示面板，本来也用不上） |
| `usr/share/doc` + `man` + `usr/share/locale` | 114 MB | `path-exclude`（保留各包 `copyright`，Debian 政策要求） |
| `modem.*` 固件（4G） | **39 MB** | tiny 档位删除（不装 ModemManager、不加载 modem 模块，固件永不被读取） |

体积大头来自 **mesa → libLLVM**：连一个只做 3D 渲染的 render 节点都要拖进
117MB 的 LLVM。若将来要做 GPU 分区镜像，这是首先要解决的依赖。

内核侧本已精简：模块树 26MB（678 个），最大子系统（`drivers/net`）仅 2.4MB，
可压缩空间远小于固件与 mesa。

## 两个必须显式声明的东西（否则镜像不可启动）

### `systemd-sysv` —— 提供 `/usr/sbin/init`

它**只是 `systemd` 的 Recommends**。`tiny` 档位移除 4G 包后依赖链断裂，
镜像里没有 `/sbin/init`，内核依次尝试 `/sbin/init`→`/etc/init`→`/bin/init`
全部失败，**落到 `/bin/sh`，系统起不来**（无 SSH、无网络，刷到真机只能
按复位键走 EDL 恢复）。

已把 `systemd-sysv` 显式列入 `PKGS_BASE`。这个缺陷是**用 QEMU 冒烟测试发现的**
（见下节），从文件清单上完全看不出来。

### `bluez` / `rfkill` —— 蓝牙用户态

详见 `BLUETOOTH.md`。内核有 `hci0` 但没有 `bluetoothctl` 的话，蓝牙等于不可用。

## QEMU 冒烟测试（精简档位必须做的一步）

设备只能从**运行中的系统**进 fastboot；若新 rootfs 起不来就只能物理复位，
所以刷 rootfs 前应先在不碰真机的前提下验证可启动性。

我们的内核配置恰好齐备 QEMU `virt` 所需项（`ARM_GIC`/`GIC_V3`/`ARCH_TIMER`/
`PSCI_FW`/`SERIAL_AMBA_PL011`/`VIRTIO_MMIO`/`VIRTIO_BLK`，全部 `=y` 内建，
无需 `ARCH_VIRT`，arm64 也没有这个符号）。所以：

```sh
# 1) 从 boot 镜像提取裸 Image（跳过 2048 字节 Android header，
#    截止到 appended DTB 的 d00dfeed 魔数）
python3 - <<'PY'
import struct, gzip, pathlib
d = pathlib.Path("boards/ufi00x/ufi103s-ufi003/boot/boot-venus-oc-100-gpu-7.1.13.img").read_bytes()
page = struct.unpack_from("<I", d, 36)[0]
off  = d.find(bytes.fromhex("d00dfeed"), page)
pathlib.Path("out/qemu-test/Image").write_bytes(gzip.decompress(d[page:off]))
PY

# 2) 准备可写 rootfs：改 fstab 为 /dev/vda，加 ttyAMA0 getty
cp out/<镜像>.ext4 out/qemu-test/test.ext4
#   /etc/fstab 写 "/dev/vda / ext4 defaults 0 1"
#   ln -sf /lib/systemd/system/serial-getty@.service \
#          /etc/systemd/system/getty.target.wants/serial-getty@ttyAMA0.service

# 3) 按设备规格启动（4×Cortex-A53、376MB，与真机一致）
qemu-system-aarch64 -M virt -cpu cortex-a53 -smp 4 -m 376 \
  -kernel out/qemu-test/Image \
  -append "console=ttyAMA0 root=/dev/vda rw rootwait" \
  -drive file=out/qemu-test/test.ext4,if=none,id=d0,format=raw \
  -device virtio-blk-device,drive=d0 -nographic -no-reboot
```

**通过标准**：出现 `ufi103s login:`（或 `Welcome to Debian GNU/Linux 13`）。

### 预期内的假故障

QEMU 里没有高通硬件，所以下列失败是**正常的**，不要当成缺陷：

- `rmtfs.service` 超时（等 `/dev/qrtr*` 与 ttyMSM0）
- `dev-ttyMSM0.device` 超时
- 无 `wlan0`/`wwan0`（`wcn36xx` 没有对应硬件）

真机上这些服务是 `active (running)`。

## 精简档位的实机状态

`minimal` / `tiny` 的镜像均已构建并通过 QEMU 启动验证，但**尚未刷入真机**：
设备只能从运行中的系统进 fastboot，刷 rootfs 失败需物理复位，这一步应在
操作者在场时进行。刷机命令与回退方式见
`boards/ufi00x/ufi103s-ufi003/README.md`。
