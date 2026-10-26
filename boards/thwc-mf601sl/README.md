# THWC MF601SL_CT_V07（mf601sl_v07）

MSM8916 电池型 4G MiFi。与 UFI103s 同 SoC 但硬件差异大：**有电池、有 microSD、
有完整 4G、USB 角色靠 GPIO 而非充电器 VBUS**。

## 状态

| 项 | 状态 |
|---|---|
| 设备树 | ✅ 已写（`dts/msm8916-thwc-mf601sl-v07.dts`），cpp+dtc 编译通过 |
| 内核 | ✅ 已构建（`7.2.9-ufix0x-mf601sl-dirty`，678 个模块） |
| 测试包 | ✅ 已生成（`out/mf601sl-build/package/`，14MB） |
| **实机验证** | ❌ **未做**（本工作区无此设备） |

## 硬件（依据见 `docs/hardware/MF601SL.md`）

| 子系统 | 配置 |
|---|---|
| SoC | MSM8916 4×Cortex-A53 |
| WiFi/BT | WCN3620（同 UFI，`wcn36xx` 修复适用） |
| 4G | mpss 85MiB@0x86800000 + mba + rmtfs + bam-dmux |
| 电池 | 2100mAh / 3.0–4.2V，`pm8916_lbc` 充电 + `pm8916_bms` 电量计 |
| USB-ID | **GPIO121**（`extcon-usb-gpio`） |
| 复位键 | GPIO34（`KEY_RESTART`） |
| LED | 6 颗三色 + 4 个 SIM 控制（110/112/115/116/119/120 + 24/49/50/51） |
| 存储 | eMMC（sdhc_1）+ microSD（sdhc_2） |
| 串口 | `blsp_uart2` = `ttyMSM0` @115200 |

## 内核配置差异

只需在 `common-7.2.9-os.config` 上叠加 `source/configs/mf601sl.config`：
- `CHARGER_PM8916_LBC=m`（充电 + **USB extcon**，缺了 RNDIS 不工作）
- `BATTERY_PM8916_BMS_VM=m`（电量计）
- `INPUT_PM8XXX_VIBRATOR=y`

**4G 链已全在 common 里**，不需要额外配置。**不要套用 baseline/minimal 的内存裁剪**
（那会关掉 modem 链，MF601 就没 4G 了）。

## 构建

```sh
bash tools/build-board-set.sh mf601sl
```

产出：
- `artifacts/boot/thwc-mf601sl/boot-board-mf601sl-7.2.9.img`
- `artifacts/modules/7.2.9-ufix0x-mf601sl-dirty/`

## 测试包

`out/mf601sl-build/package/`（不入库）内含 boot 镜像、DTB、模块树、`build.json`、
`来源与不确定项.md`、`SHA256SUMS.txt`。

**刷机前必读 `来源与不确定项.md`**：里面列了 5 个必须实机确认的不确定项
（按键、LED 数量、电池电压、SIM sel/en、已知死机问题）。

## 不确定项速览

| 项 | 本包采用 | 冲突来源 |
|---|---|---|
| 按键 | GPIO34 / KEY_RESTART | 原厂 BSP：GPIO107(WPS) + GPIO34(code 216) |
| LED 数量 | 10（6 灯 + 4 SIM） | 原厂 BSP 列 18 脚，多出的多为占位标签 |
| 电池满充 | 4.2V（保守） | 原厂 BSP 4.35V；有历史 Over voltage 记录 |
| SIM sel/en | sel=49 / en=24 | Debian11 修复版是 sel=24 / en=49（对调） |
