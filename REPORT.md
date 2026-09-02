# 103s 调研报告: Linux 6.18 对 MSM8916 (Handsome OpenStick UFI103s) 的支持现状

**目标设备**：192.0.2.14 (debian11-Zt)
**SoC**：Qualcomm MSM8916 (Snapdragon 410, 四核 Cortex-A53)
**板子**：Handsome OpenStick UFI103s (4G/5G 棒子, 开源固件)
**当前内核**：5.15.0-jsbsbxjxh66+ (handsome-mod 定制 BSP)
**目标内核**：Linux 6.18 mainline / stable (v6.18.48)
**目标用户空间**：Debian 13 trixie (arm64)

## 1. Linux 6.18 主线对 MSM8916 的支持：✅ 完善

### DTS 资源 (arch/arm64/boot/dts/qcom/)

**SoC 级 dtsi**:
- `msm8916.dtsi` — MSM8916 SoC 定义（GCC、TLMM、SMP2P、SMEM、PRNG、SCM、GLINK、RPM等）
- `msm8916-pm8916.dtsi` — PM8916 PMIC 子节点

**板级 dts** (可作为模板):
- `msm8916-mtp.dtb` — Qualcomm 官方 MTP (Mobile Test Platform) 参考板
- `apq8016-sbc.dtb` — 96boards APQ8016 SBC (业界开源参考板)
- 还有大量商业设备 DTS: Samsung A3/A5/E5/E7/J3/J5, LG C50/M216, Motorola Harpia/Osprey/Surnia, Huawei G7, Asus Z00L 等

**drivers/soc/qcom/** 中可用的子系统驱动:
- QCOM_SMD_RPM, QCOM_SMEM, QCOM_SMEM_STATE, QCOM_SMP2P, QCOM_SMSM
- QCOM_RPMH, QCOM_APR, QCOM_GENI_SE, QCOM_ICC_BWMON
- QCOM_WCNSS_CTRL (Wi-Fi/BT 控制通道)
- QCOM_QMI_HELPERS, QCOM_PDR_HELPERS, QCOM_MDT_LOADER

### Kconfig 入口

```
CONFIG_ARCH_QCOM=y                     # 顶层 menuconfig
                                        # 路径: arch/arm64/Kconfig.platforms
select GPIOLIB, PINCTRL, HAVE_PWRCTRL (if PCI)
```

## 2. Wi-Fi/BT 子系统: WCN3680 驱动已合并

`/proc/device-tree/compatible` 在目标机上读到 `handsome,openstick`, `qcom,msm8916`，
`lsmod` 显示当前正在用：
- `wcn36xx` — WCN3660/WCN3680 主驱动 (`drivers/net/wireless/ath/wcn36xx/`)
- `btqcomsmd` — Qualcomm SMD Bluetooth (`drivers/bluetooth/btqcomsmd.c`)
- `qcom_wcnss_pil` — Peripheral Image Loader (`drivers/remoteproc/qcom_wcnss_pil.c`)
- `wcnss_ctrl` — WCNSS 控制通道 (`drivers/soc/qcom/wcnss_ctrl.c`)

**主线状态**:
- wcn36xx driver: ✅ 在主线
- btqcomsmd driver: ✅ 在主线
- qcom_wcnss_pil: ✅ 在主线
- wcnss_ctrl: ✅ 在主线 (CONFIG_QCOM_WCNSS_CTRL)

**Kconfig 选项** (drivers/net/wireless/ath/wcn36xx/Kconfig):
```
config WCN36XX
    tristate "Qualcomm Atheros WCN3660/3680 support"
    depends on QCOM_WCNSS_CTRL || QCOM_WCNSS_CTRL=n
```

## 3. 关键问题: handsome,openstick 板级 dts 不存在

主线**没有**名为 `handsome,openstick` 的 board dts。需要从模板（apq8016-sbc.dts 或 msm8916-mtp.dts）
重写一份，纳入以下板级差异:

- USB 4G/5G modem 子节点（棒子的核心外设）
- LED/Button GPIO 配置（板子没有这些，但 dts 模板里有，必须删）
- Wi-Fi/BT 节点（wcn36xx + wcnss-wlan/bt，通常直接 include msm8916-pm8916.dtsi 就能继承）
- msm8916 SoC 节点要保留 camss（camera）、lpass（audio）等默认节点（不要 status="disabled" 删干净，
  否则 ABI 不一致升级工具可能报错）

**建议的 board dts 起点**: `apq8016-sbc.dts`（无 modem 子节点，简洁），加入 usb 节点和 wcnss 节点。

## 4. 当前 BSP (5.15.0-jsbsbxjxh66+) 已知信息

| 项目 | 当前 BSP | 6.18 mainline |
|---|---|---|
| SoC 支持 | ✅ 完整 | ✅ 完整 |
| WCN3680 Wi-Fi | ✅ wcn36xx | ✅ wcn36xx |
| Bluetooth | ✅ btqcomsmd + btqca | ✅ 同上 |
| PM8916 PMIC | ✅ | ✅ |
| USB Gadget | ✅ (棒子靠这个连电脑) | ✅ dwc3 |
| QMI/RPM | ✅ | ✅ |
| **handsome,openstick board dts** | ✅ 有 | ❌ **没有，需自写** |
| **4G/5G modem 子节点** | ✅ 有 | ❌ 需自写 |
| **ztecFW (ztcfw2ocfm) 接口** | ✅ proprietary | ❌ 是 Handsome OpenStick 项目自带，6.18 不一定有 |

## 5. 调研结论

**主线6.18完全够用** — MSM8916 + WCN3680 + wcn36xx 是非常成熟的组合，OpenWrt / 各类
Android downstream 都基于同款驱动栈。自编译内核走以下路径:

1. **复用** `arch/arm64/configs/defconfig` 或自定义 `defconfig` for IPQ-410-board
2. **复制** `arch/arm64/boot/dts/qcom/apq8016-sbc.dts` 作为 board dts 模板
3. **重命名** compat 为 `handsome,openstick` + `qcom,msm8916`
4. **删除** 96boards SBC 特有的：HDMI/LCD panel/codec 部分；保留 USB/UART/eMMC/SD/WCNSS
5. **添加** USB 4G/5G modem 节点（具体型号看设备 tree 信息）
6. **debootstrap** 出 Debian 13 trixie arm64 rootfs
7. **打包** bootimg/zImage + dtb + rootfs，烧写到原厂 mtd 分区

## 6. 风险点

1. **板子 DTB 必须精确兼容 `handsome,openstick`**, 否则 U-Boot/QCM 引导器会拒绝
2. **`ztcfw2ocfm` 接口是 Handsome OpenStick 私有协议**, Debian 上需自行移植用户空间 daimon
3. **原厂 fastboot/aboot 签名验证**: 一般开源棒子都禁用签名（developer build），但刷前要确认
4. **eMMC 分区表 / UBI**: 不同棒子不一, 查 `/proc/mtd` 或 `/proc/partitions` 摸清布局