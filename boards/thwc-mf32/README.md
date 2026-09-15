# THWC MF32（MF32_MB_V02）—— 4G MiFi，自带电池

来源：反编译的 DTB（`dts/msm8916-thwc-mf32.decompiled.dts`，phandle 形态）。
model = `"MF32_MB_V02 (4G) ak201314"`，compatible = `"ak201314,MF32_MB_V02", "qcom,msm8916"`。
dtsi 代次与我们的 7.1.13 同期（pm8916-lbc / bms-vm / pwm / psci domain-idle 都在），
即这是别人基于近主线内核做过的板子，不是 Stock DT 的翻译。

## 硬件清单（全部来自 DTS 实证）

| 项目 | 内容 | 与 UFI103s 对比 |
|---|---|---|
| WiFi/BT | pronto-v2-pil + iris **WCN3620**（wcnss 6MB 静态 @0x8df00000） | **同芯片** → 我们的 MAX_MEDIUM_TIME 上行修复应当直接适用 |
| 调制解调 | mpss 85MB @0x86800000 + mba @0x8ea00000 + rmtfs，bam-dmux | 同布局 |
| 存储 | eMMC 8-bit @7824000；**SD 卡槽** @7864000（cd=GPIO38） | 多了 SD 槽 |
| USB | ci-hdrc OTG，USB-ID=**GPIO110**（与我们相同） | 同 |
| 串口控制台 | blsp1_uart2 @78b0000（GPIO4/5），stdout-path | 同 |
| **电池** | **pm8916-lbc 充电 + pm8916-bms-vm 电量计**，2100mAh / 7.98Wh，3.0–4.2V，安全参数 4.2V/700mA，OCV 表仅 25°C | **我们没有的维度** |
| 按键 | 电源键（pm8941-pwrkey, KEY_POWER）；Restart=GPIO34 | 我们是 Reset=GPIO37 |
| LED | RGB 三色（R=GPIO27 电源 / G=GPIO29 wlan / B=GPIO30 wan）+ 4 个 CPU 活动 LED（19/22/21/20）+ 双 SIM 切换 4 脚（49/24/50/51） | 我们单 WLAN LED + 通用 LED 方案不同 |
| 音频 | q6/APR 全栈 + WCD 模拟/数字 codec + LPASS，sound card **disabled** | 同为禁用 |
| 摄像头/显示 | camss/cci/mdss 全 disabled | 同 |
| 马达 | pm8916-vib okay | 我们没有 |
| CPU OPP | 200/400/800/1000MHz 原厂档 | 我们已验证到 1209.6 的超频经验可迁移 |
| ACC/SAW | `status = "reserved"` | **与我们实测结论一致**：电压由 PSCI 掌管，降压无门 |

## 电池与开关机（此设备的 bring-up 核心）

内核 7.1.13 **驱动已齐**，只差配置：
- `CONFIG_CHARGER_PM8916_LBC`（充电控制，依赖 MFD_SPMI_PMIC ✓）
- `CONFIG_BATTERY_PM8916_BMS_VM`（电压法电量计，读数经 `QCOM_SPMI_VADC`（=m 已有））
- `CONFIG_INPUT_PM8941_PWRKEY=y` 已开（电源键→logind 默认触发 poweroff）
- `CONFIG_POWER_RESET_MSM=y` 已开（pshold 关机路径，接电池后 `poweroff` 才是真正断电）

待上机验证的开关机行为（DTS 看不出来）：
1. `poweroff` 是否彻底断电（电池设备预期如此，USB 棒无从验证）。
2. 开机是否只认电源键；**插充电器是否自动开机**取决于 PON/aboot 配置。
3. **关机充电**：PMIC 硬件自主充电还是依赖 bootloader 兜底，需实测
   （我们的链路里没有"关机充电屏"这种东西，最坏情况=关机后不充电）。
4. 低电自动关机需要用户态配合：读 `/sys/class/power_supply/*/capacity`，
   低于阈值触发 `poweroff`（tiny 档用一个小 systemd timer 即可，不必上 upower）。

## 内存优化经验直接迁移

- `status="disabled"` 回收 reserved-memory 的机制同样适用：
  mpss+mba+rmtfs ≈ 87MB（MF32 是 4G 设备，保留 modem）；venus_mem 只有 **1MB**
  （不够转码用：要么提到 5MB+，要么照我们的 no4g-novenus 方案整个砍掉）。
- CMA 照旧中性；TZ/SMEM/HYP 块照旧不可动。

## 板级 DTS 相对原厂 DTB 的定制清单（已定案）

写板级 DTS 时按此清单偏离反编译版，逐项都是本工作区已确认的决定：

| # | 偏离 | 理由/收益 |
|---|---|---|
| 1 | **删除 GPS 能力**：`/delete-node/` 掉 `reserved-memory/gps@8bd00000`（1MB no-map）与 `memshare` 节点（本就 disabled，且引用 gps） | 回收 +1MB MemTotal；两个节点一起删避免悬空 phandle |
| 2 | LED 节点重写为 LED-SCHEME 方案（RGB `color+function`=status 三通道、`bat:1..4` 电量条；bat 物理顺序实机校准） | 系统状态+电量指示，见 LED-SCHEME.md |
| 3 | venus_mem 二选一：提到 ≥5MB（要转码）或照 no4g-novenus 禁用（省内存） | 原厂 1MB 不够任何实际转码 |
| 4 | `pon@800` / pwrkey / 看门狗(60s) 沿用原厂 | 见 POWER-KEYS.md |
| 5 | 充电/电量计（lbc + bms-vm）节点沿用原厂，配 `mf32.config.fragment` 开驱动 | 电池管理前提 |
| 6 | SD 卡 CD 引脚：原厂定义了 `pmx-sdc2-cd-pin-state` 但 pinctrl-0 **未引用**，板级 DTS 补上引用（GPIO38 上拉） | 插卡检测可靠性；驱动侧其余零缺口 |

其中 #1 的 DTS 写法（板级 dts 顶层）：

```dts
/ {
	reserved-memory {
		/delete-node/ gps@8bd00000;
	};
	/delete-node/ memshare;
};
```

## Bring-up 前置硬约束（沿用本工程规则）

- 先 Miko 全片 eMMC 备份；只动确认过的 boot/rootfs 分区。
- fastboot 可达性、aboot 是否健在、串口引出的物理位置——全部未知，需实机。
- 新建 `boards/thwc-mf32/` 家族目录，内核走
  `mf32.config.fragment`（在 common-os 上加：LBC、BMS_VM、EXTCON_QCOM_SPMI_MISC、
  SD/电池相关；LED/SIM 用板级 DTS 描述）+ 可叠加 `kernel-size.config`。
