# Handsome OpenStick UFI00x 家族适配 (Linux 6.18 主线)

目标 SoC: Qualcomm MSM8916 (Snapdragon 410, 4×Cortex-A53)
目标内核: Linux 6.18.48-ufi003 (自编译, GCC -O2, arch/arm64)

## 板级 DTS 概况

统一放在 `arch/arm64/boot/dts/qcom/`:

| 文件 | 设备 | Wi-Fi 芯片 | SIM 槽 | 状态 |
|---|---|---|---|---|
| `msm8916-handsome-openstick-common.dtsi` | 公共基座 | - | - | ✅ 实机验证 |
| `msm8916-handsome-openstick-ufi003.dts` | UFI103s | WCN3620 | 双SIM(sel2/en2) | ✅ 实机验证 |
| `msm8916-handsome-openstick-ufi001c.dts` | UFI001c | WCN3660b | 双SIM(sel2/en2) | ✅ 编译验证 |
| `msm8916-handsome-openstick-ufi001b.dts` | UFI001b | WCN3660b | 单SIM(无sel2/en2) | ✅ 编译验证 |

`Makefile` 已注册三个 dtb:
```
dtb-$(CONFIG_ARCH_QCOM) += msm8916-handsome-openstick-ufi001b.dtb
dtb-$(CONFIG_ARCH_QCOM) += msm8916-handsome-openstick-ufi001c.dtb
dtb-$(CONFIG_ARCH_QCOM) += msm8916-handsome-openstick-ufi003.dtb
```

## 板级差异对照表

| 特性 | ufi001b | ufi001c | ufi003 (UFI103s) |
|---|---|---|---|
| iris (Wi-Fi/BT芯片) | WCN3660b | WCN3660b | **WCN3620** |
| reset 键 GPIO | 37 | 37 | 37 |
| Wi-Fi LED | gpio20 | gpio20 | gpio20 |
| internet LED | gpio21 | gpio21 | gpio21 |
| os LED | gpio22 | gpio22 | gpio22 |
| sim:sel | gpio2 (default on) | gpio2 (default on) | gpio2 (default on) |
| sim:en | gpio1 (off) | gpio1 (off) | gpio1 (off) |
| sim:sel2 | 无 | gpio0 (off) | gpio0 (off) |
| sim:en2 | 无 | gpio3 (off) | gpio3 (off) |
| eMMC rootfs | mmcblk0p14 | mmcblk0p14 | mmcblk0p14 |

## common.dtsi 公共配置

- `serial0 = &blsp_uart2` (ttyMSM0), `mmc0 = &sdhc_1`
- USB `usb_id` extcon (gpio110), `usb_hs_phy` 供电 (pm8916 l7/l13)
- Modem 数据通道: `mpss` + `mpss_mem`(reg=0x86800000, 0x5500000) + `mba_mem` + `bam_dmux` + `bam_dmux_dma` + `apr`
- **不启用**语音通话 (q6voiced/q6mvm/q6cvp/q6cvs 在主线不提供)

## 与 HandsomeMod 5.10 patch 的差异

主线移植需处理的 label 映射 (5.10 → 6.18):
- `blsp1_uart2` → `blsp_uart2`
- `pronto` → `wcnss`
- `msmgpio` → `tlmm`
- `smd_rpm_regulators` → `pm8916_rpm_regulators` (电压已上游化, 无需覆盖)

关键修复:
- `mpss_mem` 主线 dtsi 的 size 为 0 (device-specific), 必须补 `reg = <0 0x86800000 0 0x5500000>` (85MiB, 与 5.15 BSP 一致)

## 验证状态

- 三个 dtb 编译 exit=0，无板级引入的警告
- 反编译核对 model/compat/LED GPIO/iris 全部符合
- 12 处 dtc 警告来自上游 `msm8916.dtsi`/`msm-8916-pm8916.dtsi` 公共节点 (i2c/spi 地址重复等)，与板级无关

## 已实机验证 (ufi003)

内核 6.18.48-ufi003 在 UFI103s 实机成功启动并工作:
- Wi-Fi (WCN3620 + wcn36xx) ✅
- Bluetooth 栈 ✅
- 4G modem (q6v5-mss + bam_dmux + QRTR 全套服务) ✅
- eMMC rootfs (mmcblk0p14) ✅
- zram (zstd) ✅ / cpufreq / 温度采样 ✅

ufi001b / ufi001c 经 DTS 差异核对与编译验证，硬件上仅在 LED 引脚与 Wi-Fi 芯片型号不同，预期可直接复用同一内核镜像 (仅需替换对应 dtb 与 cmdline 的 PARTUUID)。
