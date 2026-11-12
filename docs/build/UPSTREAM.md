# 上游内核版本跟踪

## 2026-11-10 升级：7.2.9 → 7.2.15

当前基线已升到 **Linux 7.2.15**（上游提交 `497791a0a`）。
本次升级理由与风险评估：

| 版本线 | 最新 tag | 距离当前 | 与本平台的关系 |
|---|---|---|---|
| 7.2.y | `v7.2.15` | 7.2.9 之后 1058 个提交 | **零驱动变化**，全是通用/安全修复 |
| 7.3.y | `v7.3.3` | 跨大版本 | 有几个直接相关的上游修复（见下） |

### 7.2.9 → 7.2.15 对本平台的实际改动

按 Qualcomm/MSM8916 相关路径筛选，923 个被修改的文件里只有 15 个与
Qualcomm 相关，且**全是其它 SoC**：`gcc-eliza`、`gcc-kaanapali`、
`gpucc-glymur`、`pinctrl-ipq5018/hawi/nord`、`i2c-qcom-*`、`qcom_geni_serial` 等。

逐文件核验，以下文件**0 行差异**：

```
qcom_q6v5_mss.c  qcom_q6v5.c  qcom_wcnss.c
wcn36xx 的 5 个文件  pm8916_lbc.c  pm8916_bms_vm.c
gcc-msm8916.c  msm8916.dtsi  全部 48 个 msm8916 dts
```

只有两处微小差异，对本项目无实际影响：

- `sdhci-msm.c` 差 6 行：`cqhci_irq` 参数变更，只影响支持 CQE 的 SoC，MSM8916 不用 CQE。
- `pinctrl-spmi-gpio.c` 差 38 行：7.2.13 的「make direction changes exclusive」。
  两块板的 DTS 都不使用 PMIC GPIO（MF32 的 `pm8916-gpio` 节点是原厂反编译
  留下的空壳、没有 consumer）。

因此 7.2.15 的收益主要是 CVE 与通用稳定性修复。

### 7.3 里值得关注的四项（本次未采用）

| 上游改动 | 与本项目的关系 |
|---|---|
| `remoteproc: qcom: q6v5: Make handover IRQ one-shot` | **最重要**。7.2.9/7.2.15 的 `q6v5_handover_interrupt()` 在 `handover_issued` 为真时只打日志并 `return IRQ_HANDLED`，IRQ 保持使能；7.3 改为 `IRQF_NO_AUTOEN` + 触发后立即关闭。这是 MF601SL 开机 `MPSS authentication failed: -19` 竞态的上游根治方案，也是目前 `modem-start.service` 只能靠重试 12 次兜住的那个问题的根源 |
| `wifi: wcn36xx: Fix potential use-after-free in TX ack timer teardown` | `wcn36xx_dxe_deinit()` 补 `timer_shutdown_sync()`，只影响 rmmod/驱动复位路径 |
| `gcc-msm8916: Fix enable_reg for gcc_blsp1_sleep_clk` | BLSP1 sleep clock 的 `0x45004` bit9 vote |
| `remoteproc: qcom_q6v5_pas: Create platform device for BAM-DMUX` | MSM8916 走 `q6v5_mss` 而非 PAS，不适用 |

MSM8916 在 7.3 中**没有任何 DTS 改动**，48 个 msm8916 dts 逐字节相同。

### 补丁兼容性

五个补丁在 7.2.15 上按序干净套用（无 fuzz、无 reject），改动 9 个文件、
+292/−24 行。特别地，7.3.3 的 `pm8916_lbc.c` 里仍没有 `BOOT_DONE` /
`ENUM_TIMER_STOP`，说明 `0006` 仍未被上游吸收，升级后必须保留。

## 历史核查（2026-10-27，基线当时为 7.2.9）

当前项目基线是 **Linux 7.2.9**（上游提交 `5fce16164`）。
kernel.org stable 仓库已有 **Linux 7.2.13**（2026-10-26，提交 `3c172eede`）。

| 版本 | 日期 | 相对上一版的提交数 |
|---|---|---:|
| 7.2.10 | 2026-10-11 | 426 |
| 7.2.11 | 2026-10-15 | 285 |
| 7.2.12 | 2026-10-21 | 13 |
| 7.2.13 | 2026-10-26 | 232 |

`v7.2.9..v7.2.13` 共 **956 个提交**。

## 与本项目的关系

按当前平台相关路径筛选，有 17 个提交，主要涉及：

- IPv4/IPv6、TCP 与 netfilter 的稳定性修复
- USB gadget 的若干修复
- power supply 核心的回调生命周期修复

其中没有看到 `wcn36xx`、`msm8916` DTS、Qualcomm remoteproc/QRTR 或 Venus
的变更。USB gadget 的 `f_fs` 修复也不等于当前使用的 RNDIS 路径发生了变化。

因此，**7.2.13 不能被视为 WiFi 热点或现有平台问题的直接修复**；
升级价值主要是常规稳定与安全修复。

## 补丁兼容性预检

已在干净的 v7.2.13 工作树上按序实测，当前五个补丁全部可以套用：

1. `0001-wifi-wcn36xx-make-firmware-feat-caps-readable.patch`
2. `0002-wifi-wcn36xx-raise-max-medium-time-for-ht-tx.patch`
3. `0003-wifi-wcn36xx-add-cfg-override-diagnostics.patch`
4. `0005-venus-hfi1xx-encoder-fixes.patch`
5. `0006-power-supply-pm8916-lbc-complete-charger-handshake.patch`

这里只证明补丁能按序套用，**不代表 7.2.13 已完成构建或实机验证**。

## 启动镜像不使用 initramfs（2026-11-10 定案）

**全家族 11 个 boot 镜像一律空 ramdisk（`ramdisk_size = 0`）**，不生成 initramfs。

### 依据：启动驱动全部内置

内核在 `prepare_namespace()` 里自行解析 `root=` 并挂根，前提是块设备与文件系统
驱动已经在内核里，不需要用户态帮忙：

| 配置项 | 值 | 作用 |
|---|---|---|
| `CONFIG_MMC` | `=y` | MMC 核心 |
| `CONFIG_MMC_SDHCI` | `=y` | SDHCI 主机控制器 |
| `CONFIG_MMC_SDHCI_MSM` | `=y` | msm8916 具体驱动 |
| `CONFIG_MMC_BLOCK` | `=y` | `/dev/mmcblk0` 节点 |
| `CONFIG_EXT4_FS` | `=y` | 根文件系统 |
| `CONFIG_DEVTMPFS_MOUNT` | `=y` | 内核自动挂 `/dev` |

六项在 7.2.9 与 7.2.15、MF32 与 MF601SL 的配置里**逐字相同**。
`CONFIG_BLK_DEV_INITRD=y` 只是「支持」initramfs，不等于「需要」。

### 依据：LK 侧对 `ramdisk_size = 0` 有显式保护

```c
if (ramdisk_size) {                    /* platform/msm_shared/dev_tree.c:2317 */
    fdt_setprop_u32(fdt, offset, "linux,initrd-start", ...);
}
```
```c
if (ramdisk_size) {                    /* app/aboot/aboot.c:1112 */
    *ptr++ = 0x54420005;  /* ATAG_INITRD2 */
}
```

为 0 时既不设 `linux,initrd-start/end`，也不打 `ATAG_INITRD2`，属规范分支。

### 依据：MF601SL 已实机验证空 ramdisk

| | MF32 basic（7.2.9 旧版） | MF601SL |
|---|---|---|
| `ramdisk_size` | 12,821,980 | **0** |
| 启动相关内核配置 | — | **与 MF32 逐字相同** |
| 实机结果 | ✅ | ✅ 连续运行 39 小时 |

### 历史：MF32 的 12.8MB initramfs 为什么被移除

它是 2026-10-30 一次性手工生成、**从未进入构建链**的游离产物
（`out/mf32-build/initrd-mf32-7.2.9.img`），因此升级内核时立刻丢失——
这不是偶发遗漏，是结构性隐患。

当时加它的理由是「对齐 OpenStick 官方 `boot-ufi001c.img` 的 6.6MB ramdisk」。
但实测该 initramfs 内 **262 个模块里只有 4 个与 MSM8916 相关**：

```
btrfs.ko 1.6MB、bridge.ko 346KB、zstd 308KB、stmmac 291KB
还有 camcc-sm8650.ko、dispcc-x1e80100.ko 这类完全无关 SoC 的时钟驱动
```

那是 Debian `MODULES=most` 给「不知道装到哪台机器」的通用发行版准备的默认值。
官方那个 ramdisk 同样是通用安装介质，不是为 msm8916 定制——照抄属于形式对齐。

移除带来的实际收益：boot 从 20.7MB 降到 7.9MB（`fastboot flash boot` 快约 60%）、
省约 13MB 常驻内存（512MB 设备的 2.5%）、省掉解压与 udev 初始化时间，
且 11 个 boot 用同一套打包逻辑，不再有「MF32 特殊处理」。

`tools/package-boot-variant.py` 把 `ramdisk_size: 0` 写进每个 `build.json`，
让「发布物里没有 initramfs」成为可断言的事实，而不是靠读脚本缺省行为推断。

## 升级建议

将 7.2.13 作为一次独立基线升级处理，不与热点、MF32 等功能改动混在同一轮：
先迁移配置并确认补丁，再重建全部板型，跑 QEMU、USB 交付断言和实机回归。
升级前保留当前 7.2.9 的已验证 boot、模块树和 rootfs，便于逐项对照。
