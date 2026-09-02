# 103s 综合调研报告: Linux 6.18 + Debian 13 on UFI103s

**目标设备**：192.0.2.14 (debian11-Zt)
**项目代号**：UFI103s（OpenStick 内部命名为 **ufi003**）
**SoC**：Qualcomm MSM8916 (Snapdragon 410, 四核 Cortex-A53, aarch64)
**板子**：Handsome OpenStick UFI103s（USB 4G 棒子形态）
**当前内核**：5.15.0-jsbsbxjxh66+（handsome-mod BSP）
**当前 OS**：Debian 11.11
**目标内核**：Linux 6.18 mainline（v6.18.48 stable）
**目标 OS**：Debian 13 trixie arm64

---

## 1. 设备硬件识别结论

| 项目 | 值 |
|---|---|
| DT model | `Handsome OpenStick  jsbsbxjxh66-bianyi UFI103s` |
| DT compat | `handsome,openstick` `qcom,msm8916` |
| CPU | Cortex-A53 ×4（CPU part 0xd03） |
| Wi-Fi 芯片 | QCA WCN3620（WCN36xx 驱动） |
| 当前内核模块 | `wcn36xx` `btqcomsmd` `qcom_wcnss_pil` `qcom_q6v5_mss` `mdt_loader` |
| 内置 4G modem | Qualcomm MSM8916 集成基带 |
| rootfs | `/dev/mmcblk0p14`（eMMC 分区14） |
| Bootloader | mkbootimg 格式（非 U-Boot）|

**关键节点**：`compatible = "handsome,openstick", "qcom,msm8916"`，与 HandsomeMod 项目所有 OpenStick 板子共用一套 compat 字符串。

---

## 2. Linux 6.18 mainline 支持现状

### ✅ SoC 层 (msm8916.dtsi)
- GCC、TLMM、SMP2P、SMEM、PRNG、SCM、GLINK、RPM、RPMH、BAM、SMD、SMSM、APR、QMI、PDR — 全部主线
- Kconfig 入口：`CONFIG_ARCH_QCOM=y`（arm64/Kconfig.platforms）

### ✅ Wi-Fi/BT (WCN3620/WCN3660)
- `wcn36xx`: `drivers/net/wireless/ath/wcn36xx/` 完整支持，6.18 持续维护
- `btqcomsmd`: `drivers/bluetooth/btqcomsmd.c` 主线
- `qcom_wcnss_pil`: `drivers/remoteproc/qcom_wcnss_pil.c` 主线
- `qcom_q6v5_mss`: `drivers/remoteproc/qcom_q6v5_mss.c` 主线（Modem 启动）
- `qcom_wcnss_ctrl`: `drivers/soc/qcom/wcnss_ctrl.c` 主线

### ✅ 4G modem userspace 守护进程依赖
- `kmod-qcom-modem` 内核模块（**OpenStick 项目自家写**） — 通过 HandsomeMod 镜像构建可获得

---

## 3. DTS: 你要做的核心工作

主线**没有** `handsome,openstick` 板子 dts。HandsomeMod 在 5.10 上通过 patch（已存 `103s/openstick-patches/0083-handsome-openstick-dts.patch`）支持：

| 板子 | patch 中状态 | 在 dump 中确认 |
|---|---|---|
| `handsome-openstick-ufi001b` | ✅ 已支持 | – |
| `handsome-openstick-ufi001c` | ✅ 已支持 | – |
| `handsome-openstick-sp970` | ✅ 已支持 | – |
| `handsome-openstick-uz801` | ✅ 已支持 | – |
| **`handsome-openstick-ufi003`** | ❌ **缺失** | ✅ 你的设备 |

### UFI103s 跟 ufi001c 的差异（从 dump 的 dts 反推）

| 项目 | ufi001c | **UFI103s（ufi003）** |
|---|---|---|
| Wi-Fi 芯片 | WCN3660b | **WCN3620** |
| reset 键 | gpio37 | gpio37 ✓ 一致 |
| Wi-Fi LED | gpio20 | gpio20 ✓ |
| internet LED | gpio21 | gpio21 ✓ |
| os LED | gpio22 | gpio22 ✓ |
| sim_sel | gpio2 (on) | gpio2 (on) ✓ |
| sim_en | gpio1 (off) | gpio1 (off) ✓ |
| sim_sel2 | gpio0 (off) | gpio0 (off) ✓ |
| sim_en2 | gpio3 (off) | gpio3 (off) ✓ |

**结论**：UFI103s 的板级定义几乎 1:1 复用 ufi001c，只需把 dts 复制一份改成 `msm8916-handsome-openstick-ufi003.dts`，并把 `&pronto` 节点的 `iris` 子节点 compat 从 `"qcom,wcn3660b"` 改成 `"qcom,wcn3620"`。

---

## 4. OpenStick 项目资源地图

```
OpenStick/OpenStick           项目 README (https://github.com/OpenStick/OpenStick)
HandsomeMod/HandsomeMod       OpenWrt 构建系统，target/linux/msm89xx/
  ├─ config-5.10              MSM8916 内核 config 模板
  ├─ patches-5.10/0083-*      OpenStick 板子 DTS patch (4 个板子)
  ├─ patches-5.10/0048-*      msm8916 modem dtsi (Q6V5 MSS 节点)
  ├─ image/msm8916.mk         image 生成器(mkbootimg) + 设备定义
  └─ package/firmware/qcom-firmware/  各板子固件(nv、wcnss、modem)

HandsomeMod/packages          LuCI + ModemManager + 用户空间包
HandsomeMod/qcom-firmware     modem/WCNSS/nv 二进制(ufi003 已有！)
HandsomeMod/handsomefeed      OpenStick 私有 feed
```

**关键发现**：
1. `qcom-msm8916-modem-openstick-ufi003-firmware` 已在 `qcom-firmware/Makefile` 中**定义完整**，但 `image/msm8916.mk` 没启用 — 只需加一个 Device entry
2. `openstick-ufi003-modem.bin` (64MB) + `openstick-ufi003-nv.bin` (30KB) **已就绪**
3. WCN3620 firmware 文件名按 OpenStick 惯例命名为 `openstick-ufi003-wcnss.*`

---

## 5. 构建路径建议

### 路径 A（推荐）：复用 HandsomeMod 构建系统

```
1. 基于 HandsomeMod 的 KERNEL_PATCHVER=6.18 升级
   - target/linux/msm89xx/Makefile: KERNEL_PATCHVER:=6.18
   - target/linux/msm89xx/config-5.10 → config-6.18 (用 make oldconfig 重新生成)
2. 把 patch 适配到 6.18 (核心 patch 0083 几乎不用改, 但 Makefile 行号会变)
3. 添加 ufi003 board dts (复制 ufi001c, 改 wcn3660b→wcn3620, 加进 Makefile)
4. image/msm8916.mk 增加 Device/Handsome_handsome-openstick-ufi003 (复制 ufi001c)
5. 构建产物:
   - 6.18 内核 Image.gz + dtbs
   - OpenWrt rootfs(可选)
6. 用 HandsomeMod 工具链或 Debian 13 rootfs 替换 OpenWrt 镜像
```

### 路径 B（直接 6.18 + Debian 13）

```
1. /opt/helloworld/103s/kernel 是已 clone 的 v6.18.48 stable
2. 移植 0083 patch 到 6.18 (Makefile hunk 改一下 + 适配新 dtsi 父节点)
3. 从 ufi001c.dts 派生 ufi003.dts (WCN3620 适配)
4. 配置 Kconfig:
     CONFIG_ARCH_QCOM=y
     CONFIG_WCN36XX=m
     CONFIG_QCOM_WCNSS_CTRL=y
     CONFIG_QCOM_Q6V5_MSS=m
     CONFIG_QCOM_WCNSS_PIL=m
     CONFIG_REMOTEPROC=y
     CONFIG_USB_DWC3=y
     CONFIG_USB_DWC3_DWC=y
     CONFIG_USB_GADGET=y
5. debootstrap Debian 13 arm64 rootfs
6. mkbootimg 打包: kernel+dtb+ramdisk
7. fastboot 烧写到 mmcblk0p14
```

### 关键参数（来自 msm8916.mk）

```
QCOM_CMDLINE = "earlycon console=tty0 console=ttyMSM0,115200 root=/dev/mmcblk0p14 rw rootwait"
QCOM_BOOTIMG_FLASH_OFFSET_BASE=0x80000000
QCOM_BOOTIMG_FLASH_OFFSET_KERNEL=0x00080000
QCOM_BOOTIMG_FLASH_OFFSET_RAMDISK=0x02000000
QCOM_BOOTIMG_FLASH_OFFSET_SECOND=0x00f00000
QCOM_BOOTIMG_FLASH_OFFSET_TAGS=0x01e00000
QCOM_BOOTIMG_FLASH_OFFSET_PAGESIZE=2048
KERNELNAME = Image.gz dtbs
```

---

## 6. 风险点 & 注意事项

1. **patch 适配工作量**: HandsomeMod 的 0083 patch 是基于 5.10 内核的，移植到 6.18 需要解决：
   - Makefile 行号变化
   - `msm8916.dtsi` 自身在 6.18 已添加/删除的节点差异
   - `msm8916-pm8916.dtsi` 节点编号差异

2. **mkbootimg vs aboot**: OpenStick 的烧写用 fastboot + aboot，Linux 6.18 内核格式是 Image.gz dtbs，**用 mkbootimg 拼装**而不是打包成 zImage

3. **UFI103s 暂未在 HandsomeMod 中作为 device 启用**：你将是这个板子的"上游贡献者"，补丁可以推回 OpenStick/HandsomeMod

4. **kernel config 调整**: 5.10 → 6.18 主要差异：
   - 部分宏改名（如 `QCOM_SCM` 增 `QCOM_SCM_DOWNLOAD_REF`）
   - `WCN36XX` 增加了 firmware 加载机制（6.x 默认走 SMD 通道）
   - `BT_QCOMSMD` 在 6.18 已默认开启
   - **不需要打任何补丁来支持 wcn3620**，主线 wcn36xx 通用支持

5. **ztecFW (ztcfw2ocfm) 接口**: 这是 OpenStick 项目 modemnw 守护进程的产物，Debian 上跑的话需要单独装它的 userspace 包

---

## 7. 调研产出物（在 103s 工作区）

```
/opt/helloworld/103s/
├── README.md                        项目说明
├── REPORT.md                        v1 调研报告 (主线6.18 对 MSM8916)
├── REPORT-v2.md                     本报告
├── .gitignore                       忽略规则
├── kernel/                          v6.18.48 stable Linux 内核 shallow clone
├── openstick/                       OpenStick/OpenStick 仓库(仅 README)
├── handsomemod/                    HandsomeMod/HandsomeMod 仓库
├── handsomemod-packages/            HandsomeMod/packages 仓库
├── qcom-firmware/                   HandsomeMod/qcom-firmware 仓库(含 ufi003 固件)
├── openstick-patches/               关键 patch 备份
│   ├── 0048-msm8916-modem-dtsi.patch
│   └── 0083-handsome-openstick-dts.patch
└── openstick.dts                    192.0.2.14 实时 dump 的设备树(63KB, 3101 行)
```

---

## 8. 下一步建议

| 优先级 | 动作 | 预期产出 |
|---|---|---|
| P0 | 在 6.18 内核树上把 0083 patch 改写并 apply（Makefile 偏移 + dtsi 节点修正） | 工作 dts 树 |
| P0 | 派生 `msm8916-handsome-openstick-ufi003.dts`（基于 ufi001c） | board dts 文件 |
| P1 | 从 `arch/arm64/configs/defconfig` 派生 `msm89xx_defconfig` | 编译配置 |
| P1 | arm64 交叉编译工具链安装 | 编译环境 |
| P2 | 构建 Image.gz + dtb | 内核产物 |
| P2 | 用 mkbootimg 拼装 bootimg（offset 按 HandsomeMod 的常量） | 可烧写 boot image |
| P3 | debootstrap Debian 13 arm64 rootfs，注入 qcom-firmware | 可烧写 rootfs |
| P3 | fastboot 烧写、test boot | 完整系统 |