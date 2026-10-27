# 电池、充电与电量显示

本文记录 MSM8916 + PM8916 电池机型（MF601SL、MF32）的充电与电量计实现、
内核能提供什么、以及用户态在哪里消费电量百分比。

## 一、硬件与驱动

| 组件 | 驱动 | 提供的属性 |
|---|---|---|
| 充电 | `pm8916_lbc`（`CHARGER_PM8916_LBC`） | `ONLINE`、`CONSTANT_CHARGE_VOLTAGE_MAX`、`CONSTANT_CHARGE_CURRENT` |
| 电量计 | `pm8916_bms_vm`（`BATTERY_PM8916_BMS_VM`） | **`STATUS`、`VOLTAGE_NOW`、`VOLTAGE_OCV`、`HEALTH`** |

两者都由 PM8916 的 SPMI 节点提供，`pm8916.dtsi` 里已有完整的 10 个（LBC）和
6 个（BMS）中断定义，板级 DTS 只要 `status = "okay"` 并指向 `monitored-battery`
即可继承。

### 关键点：LBC 同时是 USB device 模式的前提

`pm8916_lbc` 注册 `EXTCON_USB`（`pm8916_lbc.c:189`），把 VBUS 状态同步给
USB 控制器。**只开 BMS 不开 LBC，会出现"电量能读但插电脑不认 RNDIS"**。
MF601SL / MF32 这类靠充电器检测 VBUS 的板子必须两个都开。

### DT 属性名（易错）

7.2.9 的驱动读的是：

```dts
qcom,fast-charge-safe-voltage = <4250000>;   /* uV，范围 4.0–4.775V */
qcom,fast-charge-safe-current = <500000>;    /* uA，范围 90mA–1.44A */
```

从原厂 BSP 反编译继承的旧名 `qcom,vdd-safe` / `qcom,ibat-safe` **不被识别**。
`probe_dt()` 直接返回 `-EINVAL`，而 `probe()` 只打日志不中止，结果就是
`charge_voltage_safe = 0`，后续 `configure()` 里的减法溢出——充电器静默异常。

### 中断必须齐全

驱动用 `platform_get_irq_byname()` 取中断：

- LBC 要 `usb_vbus`
- BMS 要 `fifo`

从原厂反编译整份展开的 DTS（如 MF32）**不会继承 `pm8916.dtsi`**，必须手工补齐
10 个 / 6 个中断与对应 `interrupt-names`，否则 probe 直接失败。

## 二、内核能提供电量百分比吗

**不能。** `pm8916_bms_vm` 的属性表只有 `STATUS` / `VOLTAGE_NOW` /
`VOLTAGE_OCV` / `HEALTH`，**没有 `POWER_SUPPLY_PROP_CAPACITY`**（逐行核对
`pm8916_bms_vm.c:106-111`）。

`simple-battery` 的 `ocv-capacity-table` 会被 `power_supply_get_battery_info()`
读进 `power_supply_battery_info`，但**7.2.9 全内核没有驱动消费它**：

```sh
grep -rn 'ocv_capacity_table' source/linux-7.2.9/   # 零命中
```

只有自带私有 OCV 表的驱动（`ab8500`、`samsung-sdi`、`sc27xx`）会用
`power_supply_ocv2cap_simple()` 自己换算。BMS VM 不在其中。

所以**这个平台上拿不到内核给出的百分比**，只能拿到电压。

## 三、用户态在哪里消费电量百分比

| 组件 | 是否在本项目镜像 | 读什么 | 结果 |
|---|---|---|---|
| **upower / upowerd** | ✅ 仅 max 档（cinnamon 依赖链带入） | 扫 `/sys/class/power_supply/*`；百分比优先级 `capacity` → `energy_now/energy_full` → `charge_now/charge_full` | 我们只有 `voltage_now` → **给不出百分比** |
| **i3status battery 模块** | ✅ max 档装了 i3status，但配置里没启用 battery 块 | 只找 `/sys/class/power_supply/BAT0..BATn`，读 `POWER_SUPPLY_CAPACITY=` 等 | 设备名是 `pm8916-bms-vm`，**不是 BAT\***，且无 capacity → 用不了 |
| **cbatticon** | ✅ max 档 | 直接扫 `/sys/class/power_supply`，读 `capacity` / `energy_*` / `charge_*` | 无 capacity → **用不了** |
| **systemd-battery-check** | ✅ 所有档（systemd 自带） | 仅 initrd 阶段（`AssertPathExists=/etc/initrd-release`），读 capacity/energy | 本项目无 initramfs，**不会运行** |
| **内核 charger-manager** | ❌ 未启用（`CONFIG_CHARGER_MANAGER` 未设） | 读 fuel_gauge 的 `CAPACITY` | 不适用 |
| **内核 power_supply_leds** | ✅ `CONFIG_LEDS_TRIGGERS=y` 时编入 | 只用 `STATUS`，**不用 capacity** | 提供 `pm8916-bms-vm-charging` / `-full` 等 LED trigger，可做充电指示 |

### 结论

**没有任何现成组件能在这个平台上显示电量百分比**，因为它们全都依赖
`capacity` 或 `energy_now/energy_full`，而 BMS VM 只给电压。

要做电量显示，必须在用户态用 `voltage_now` + DTS 里的 OCV 表插值算 SOC。

## 四、推荐做法

### 4.1 充电指示（不需要百分比）

用内核自带的 power_supply LED trigger，无需写代码：

```dts
led-charge {
    function = LED_FUNCTION_CHARGING;
    color = <LED_COLOR_ID_RED>;
    gpios = <...>;
    linux,default-trigger = "pm8916-bms-vm-charging";
};
```

可用的 trigger 名（`power_supply_leds.c:151-159`）：

- `pm8916-bms-vm-charging`
- `pm8916-bms-vm-full`
- `pm8916-bms-vm-charging-or-full`
- `pm8916-bms-vm-charging-blink-full-solid`
- `pm8916-bms-vm-charging-orange-full-green`

### 4.2 电量条 LED（需要自己算 SOC）

`tools/mf32-led-state.sh` 当前读 `capacity`，在这个平台上永远读不到。
应改为：

1. 读 `/sys/class/power_supply/pm8916-bms-vm/voltage_now`（µV）
2. 用 DTS 里的 `ocv-capacity-table-0` 做线性插值得到百分比
3. 按百分比点亮 `bat:1`..`bat:4`

OCV 表最好放进一个用户态可读的位置（当前只在 DTB 里，用户态取不到）。
两个办法：

- 在脚本里写死一份与 DTS 一致的 OCV 表（简单，但两处维护）
- 由 `simple-battery` 的 sysfs 暴露？——**不行**，`power_supply_battery_info`
  不导出到 sysfs

建议采用第一种，并在注释里注明与 DTS 的对应关系；改 DTS 时同步改脚本。

### 4.3 桌面电量显示

max 档的 `i3status.conf` 里 battery 块默认注释掉了（并注明"路径实机校准"）。
在这个平台上启用它也没用（见上表）。正确做法是用 4.2 的脚本输出，
再通过 `i3status` 的 `custom` 模块或 `i3bar` 的 JSON 协议喂进去。

## 五、充电电压设置

| 机型 | 电池标称 | 本项目设置 | 说明 |
|---|---|---|---|
| MF601SL | 4.35V / 2100mAh | **4.25V** | 用户要求按更保守值充电，考虑电芯质量 |
| MF32 | 4.2V（原厂 DTS） | 4.2V | 沿用原厂值 |

`voltage-max-design-microvolt` 必须 **≥** `qcom,fast-charge-safe-voltage`，
否则 `pm8916_bms_vm` 的 `HEALTH` 判定会在充满时报 `OVERVOLTAGE`
（`pm8916_bms_vm.c:79-84`）。

MF601SL 的 OCV 表已按 4.25V 重新标定：100% 对应 4250000 µV，其余点按比例
压缩到 3.0–4.25V 区间。

## 六、待实机验证

- [ ] LBC / BMS 能否 probe 成功（`dmesg | grep -E 'pm8916-lbc|pm8916-bms'`）
- [ ] `/sys/class/power_supply/` 下是否出现 `pm8916-bms-vm` 与 `pm8916-lbc-chgr`
- [ ] `voltage_now` 读数是否合理（3.0–4.35V）
- [ ] 插拔充电器时 `STATUS` 是否切换、`EXTCON_USB` 是否联动 RNDIS
- [ ] 充电截止电压实测是否接近设定值
- [ ] 电量条 LED 与实测电压的对应关系

以上全部**未在硬件上验证**——本工作区没有这两块板子。
