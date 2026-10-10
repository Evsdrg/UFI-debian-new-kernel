# AOSC OS 与 Afterglow：适配调研

对 https://github.com/AOSC-Dev/aosc-os-abbs 的调研结论。**只做研究，未改动设备。**

> 结论速览：**能跑，但不划算。** AOSC OS 的 arm64 是官方一级架构，我用自编译内核
> 在 QEMU 里成功启动到登录提示；但它的"最小系统"就有 **1590 MB**（Debian 精简版
> 239 MB），装齐网络+4G+蓝牙后逼近设备 3.3 GB 分区的上限。**Afterglow 则不适合本
> 设备** —— 它是给 32 位老机器（i486/armv4/PowerPC）的，arm64 支持列表里根本没有它。

## 1. 名词先厘清

| 名称 | 是什么 |
|---|---|
| **AOSC OS** | 发行版本体。分支代号 `stable`，当前 codename **Jinkela**（13.3.1） |
| **abbs** | `aosc-os-abbs` 仓库，即**包构建树**（不是系统本身）。默认分支 `stable` |
| **Afterglow** | **AOSC OS/Retro 的别名**。见下 |
| **aoscbootstrap** | 用它从零拉一个 rootfs 的工具（已实测可用） |
| **aosc-mklive** | 把 tarball 做成 LiveCD 的生成器 |

`Afterglow` 这个名字的直接证据在 abbs 里：

```
runtime-kernel/linux+kernel/autobuild/defines:
  PKGDES="Generic Linux Kernel for AOSC OS"
  PKGDES__RETRO="Generic Linux Kernel for Afterglow"
```

即 `__RETRO` 变体的描述文字就叫 Afterglow。而仓库里正好有两条同名分支线索
（`afterglow-survey-*`、`icewm-afterglow`、`sdl-afterglow` 等）。

**它是独立仓库而非 component**：

| 仓库 | InRelease 的 Label | Codename | arm64 包数 |
|---|---|---|---|
| `repo.aosc.io/debs` | AOSC OS | Jinkela | **10149** |
| `repo.aosc.io/debs-retro` | AOSC OS/Retro | Icenowy | **2** |

## 2. 关键事实：Afterglow 不支持 arm64

AOSC 官方 Retro 文档列出的目标硬件：

| 架构 | 典型设备 |
|---|---|
| ARMv4 (soft float) | HP Jornada 710/720/728/820 |
| ARMv6 (hard float) | Raspberry Pi 1 |
| ARMv7 (hard float + NEON) | Raspberry Pi 2 |
| i486 | IBM Palm Top PC110、Toshiba Satellite 430CDT |
| Loongson 2F | Lemote YeeLoong 8089B/D |
| PowerPC G3 / G5 | Apple iBook G3、PowerMac G5 |

**没有 arm64。** 我在仓库索引里实测印证了这一点：

| retro 架构 | 包数 |
|---|---|
| **arm64** | **2**（仅 `wpa-supplicant`、`x11-lib`） |
| armv7hf | 884 |
| armv6hf / armv4 | 少量 |
| i486 | 3700 |
| powerpc | 1957 |
| loongson2f | 2264 |
| m68k | 412 |

i486 有 3700 个包、arm64 只有 2 个 —— **afterglow 的 arm64 实质是空的支持格子**，
不是"能用但没优化"。所以"我们的设备更适合 afterglow"这个判断与事实不符：
afterglow 是为**更老、更小的 32 位机器**准备的。

Retro 的定位（官方原文要点）：与主线共享包树与维护工具、**按存储/内存削减功能**、
更新更慢、`systemd` 仍是默认 init（官方特意说明它们在 33MHz 486SL / 20MiB RAM
的机器上测过 systemd）。

### 唯一沾边的路径：armv7hf

Cortex-A53 **原生支持 AArch32**，我们的内核也开了 32 位兼容（实测
`CONFIG_COMPAT=y`、`CONFIG_COMPAT_32BIT_TIME=y`），所以理论上能跑 retro 的
**armv7hf** 仓库（884 个包）。但：

- armv7hf 里 `systemd`/`bash`/`openssh`/`networkmanager`/`modemmanager` **有**，
  而 **`bluez`/`rmtfs`/`qrtr` 没有** —— 即蓝牙与 4G 的关键组件缺失。
- 32 位用户态在 376MB 上确实更省内存，但要放弃 AArch64 的寄存器与寻址优势，
  且要自己补 4G/蓝牙的组件。**投入产出比不成立。**

## 3. main（AOSC OS arm64）实测：能跑

### 3.1 arm64 是官方一级架构

`repo.aosc.io/debs/dists/stable/main/` 下的架构目录：

```
binary-all  binary-amd64  binary-arm64  binary-armv4  binary-i486
binary-loongarch64  binary-loongson3  binary-ppc64el  binary-riscv64
```

而且 `stable` 下有个专门的 **`bsp-qcom`** component：

```
Package: linux-kernel-msm8916-5.18.0
  Description: Linux Kernel version 5.18.0 optimized for Qualcomm MSM8x16/APQ8016 devices
Package: linux-kernel-msm8916-6.3.0
Package: qmic-dbg / qrtr-dbg / rmtfs-dbg
```

**APQ8016 就是我们的 SoC** —— AOSC 明确为它做过内核与 qmic/qrtr/rmtfs。

### 3.2 实际 bootstrap 成功（非推测）

本机就是 AOSC OS 13.3.1 x86_64，`aoscbootstrap` 可装：

```sh
aoscbootstrap --target <dir> --arch arm64 --branch stable \
  --config /usr/share/aoscbootstrap/config/aosc-mainline.toml \
  --mirror https://repo.aosc.io/debs
```

**注意 mirror 必须带 `/debs` 后缀** —— 官方 README 的示例写
`--mirror http://localhost/debs`，而参数默认值是 `https://repo.aosc.io`（不带
`/debs`），照默认跑会 404 panic。

实测结果：**成功**产出 1.6 GB 的 arm64 rootfs，`usr/bin/bash` 确认为
`ELF 64-bit LSB, ARM aarch64`，`/sbin/init → ../lib/systemd/systemd`，
`/etc/os-release` 是 `AOSC OS (13.3.1)`。

### 3.3 用我们自编译的内核启动成功

在 QEMU 里（与真机同规格 4×A53 / 376MB）用**我们自己的 7.1.13 内核**（从 boot 镜像提取的裸 Image）：

```
Linux version 7.1.13-ufi003-venus-dirty  ← 我们编译的
systemd[1]: Detected architecture arm64.
Welcome to AOSC OS (13.3.1)!
aosc login:
```

**0 错误、53 个 systemd 单元成功**，无 OOM。这证明：

- AOSC OS arm64 **不依赖它自己的内核**（能换成第三方内核）
- 我们的主线内核（含 msm8916 支持）足以驱动 AOSC 用户态
- `systemd` 所需的内核特性我们都满足

## 4. 问题在体积

### 4.1 最小系统就 1590 MB

bootstrap 出来的 stub（**只有 32 个包**，无内核/无桌面/无 NM）已经 1590 MB：

| 组成 | 体积 |
|---|---|
| `/usr/lib/python3.14` | 223 MB |
| `/usr/lib/locale`（全部语言） | 223 MB |
| `/usr/lib/gcc` | 94 MB |
| `libicudata.so` | 30 MB |
| `/usr/share/doc` + `man` | 89 MB |

这是"**不拆包**"的直接后果：AOSC 的包把运行时、文档、locale 都塞在一起，
没有 Debian 那种 `-dev`/`-doc`/`-data` 细分，所以**无法只装需要的那部分**。

### 4.2 装齐设备功能后逼近分区上限

在 AOSC 里 `apt-get install --dry-run networkmanager modemmanager bluez`：
**121 个依赖包、约 920 MB**（很多依赖是它不拆包带来的，如 `perl`/`tk`/`texinfo`
被 networkmanager 间接拉进来）。

体积推算：

| 方案 | 体积 |
|---|---|
| AOSC stub | 1590 MB |
| + 网络/4G/蓝牙 | ~2500 MB（含重叠，保守估 2.0–2.5 GB） |
| Debian `minimal` 对照 | **294 MB** |
| Debian `tiny` 对照 | **239 MB** |

设备 `p14` 分区 **3.3 GB**：AOSC 装得下但余量很少，且这还没算桌面、4G 固件、
以及 AOSC 自己那个"功能开满"的通用内核（`linux-kernel-7.1.13` 安装后 **565 MB**，
对比我们整个模块树 26 MB）。

## 5. 结论与建议

### 直接回答"能否跑得动 AOSC"

| 维度 | 结论 |
|---|---|
| **技术可行性** | ✅ 能。arm64 官方支持，实测 bootstrap + 用我们内核启动到登录 |
| **Afterglow** | ❌ 不适用。它是给 32 位老机器的，**arm64 只有 2 个包**；"更适合我们"是与事实相反的印象 |
| **体积** | ⚠️ 紧。最小可用 ~2.0–2.5 GB / 3.3 GB 分区，且无法像 Debian 那样裁剪 |
| **内存** | ✅ 376MB 能启动（53 个单元、无 OOM），但 AOSC 自己承认"heavy"、不建议对轻量有需求的场景 |
| **维护成本** | ⚠️ 高。它自带内核（565MB）与我们自编译内核/mainline GPU/Venus 支持的关系要重新理顺 |

### 建议

**维持 Debian 为主线，AOSC 作为研究结论存档。** 理由：

1. Debian 的**可裁剪性**是这台设备的关键优势。我们靠 `path-exclude` 和包集合把
   系统压到 239–294 MB；AOSC 的不拆包设计让最小系统就是 1590 MB，**没法做这件事**。
2. 设备只有 376MB 内存、3.3GB 存储、无显示面板，属于 AOSC 明确"不推荐"的
   "轻量 / 高度可定制"场景。
3. AOSC 对我们的价值主要是**它也是我们自编译内核的验证对手** ——
   实测它能在我们的内核上跑起来，这反过来印证了我们的内核（含 msm8916 支持）
   没有偏离通用 arm64 行为。

### 如果要继续这条线，下一步

1. 用 `aoscbootstrap` 的 `--include` 直接产出带 NetworkManager/modemmanager 的
   rootfs，测**实际**体积（本文的 2.0–2.5GB 是按包索引估算的上界）。
2. 决定内核路线：沿用我们自编译内核（已验证可启动），而不是 AOSC 的 565MB 通用内核。
3. 补齐 AOSC 侧 msm8916 的 4G/蓝牙（`qrtr-tools` 在 main arm64 里**没有**，
   `rmtfs` 有；`bluez` 有）。这部分要自己做包。
4. 把 `bsp-qcom` component 加进 sources.list（`--comps main,bsp-qcom`），
   看它的 msm8916 支持是否能直接用。

## 附：复现命令

```sh
# 主机需为 AOSC OS（本机即是），装 aoscbootstrap
apt-get install -y aoscbootstrap        # 本机 AOSC 13.3.1 实测可用

# bootstrap arm64 rootfs
aoscbootstrap --target /tmp/aosc-arm64 --arch arm64 --branch stable \
  --config /usr/share/aoscbootstrap/config/aosc-mainline.toml \
  --mirror https://repo.aosc.io/debs

# 用我们的内核在 QEMU 里启动（376MB，同真机规格）
# Image 提取方式见 TRIMMING.md「QEMU 冒烟测试」
qemu-system-aarch64 -M virt -cpu cortex-a53 -smp 4 -m 376 \
  -kernel out/qemu-test/Image \
  -append "console=ttyAMA0 root=/dev/vda rw rootwait" \
  -drive file=/tmp/aosc-arm64.ext4,if=none,id=d0,format=raw \
  -device virtio-blk-device,drive=d0 -nographic -no-reboot
```

参考来源：

- 架构支持：`https://wiki.aosc.io/aosc-os/information/arch-support/`
- Retro/Afterglow 定位与目标硬件：`https://wiki.aosc.io/aosc-os/retro/intro`
- 体积自述（"Heavy, takes up more storage than other distributions"）：
  `https://wiki.aosc.io/aosc-os/is-aosc-os-right-for-me`
- 包树：`https://github.com/AOSC-Dev/aosc-os-abbs`（分支 `stable`）
- `Afterglow` 命名证据：abbs 内
  `runtime-kernel/linux+kernel/autobuild/defines` 的 `PKGDES__RETRO`
- 仓库实测：`https://repo.aosc.io/debs/dists/stable/InRelease`（Jinkela）、
  `https://repo.aosc.io/debs-retro/dists/stable/InRelease`（Icenowy）
- bootstrap 工具：`https://github.com/AOSC-Dev/aoscbootstrap`
