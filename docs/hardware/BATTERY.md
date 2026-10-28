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

## 六、"必须上电池，否则半小时内重启"的分析

群友反馈：电池机刷完 Debian 必须装电池，纯 USB 供电半小时内必重启；装电池后
可稳定运行一个月。以下按源码证据逐条拆解，区分**已证实的机制**与**待实测的推测**。

### 6.1 已确认的硬件/驱动事实

| 事实 | 依据 |
|---|---|
| LBC 驱动**完全不检测电池是否存在** | `pm8916_lbc.c` 只 `platform_get_irq_byname(pdev, "usb_vbus")`（第 325 行）并注册这一个中断；DTS 里定义的 `bat_pres`、`vbat_det`、`chg_fail`、`temp_ok`、`overtemp` 等 9 个中断**驱动一个都没请求** |
| BMS 驱动**不暴露 `POWER_SUPPLY_PROP_PRESENT`，也不暴露 `CAPACITY`** | `pm8916_bms_vm.c:106-111` 的属性表只有 `STATUS`/`VOLTAGE_NOW`/`VOLTAGE_OCV`/`HEALTH`；`grep -n 'present'` 零命中 |
| 驱动初始化时**无条件**写 `CHG_EN \| PSTG_EN`（`0xA0`，强制打开功率级） | `pm8916_lbc.c:110-111` |
| 驱动**从不写 `LBC_MISC_BOOT_DONE`**（FSM 充电启动的前提） | 全文件 `grep -c BOOT_DONE` = 0；手册 `0x1049` bit7 明确要求 |
| 驱动**从不写 `LBC_USB_ENUM_TIMER_STOP`**（否则 120 秒后 IBAT_MAX 降到 90mA） | 全文件 0 处；手册 `0x134F` 原文 |
| 驱动**从不读 `LBC_BAT_IF_BAT_PRES_STATUS`**（硬件有 BAT_PRES 位） | 全文件 0 处 |
| PM8916 有**显式电源路径**：`POWERED_FROM_USB_CHARGER` / `POWERED_FROM_BATTERY` | `LBC_USB_PWR_PTH_STS` `0x1308` bit1:0 |
| 无电池时 LBC **稳压到 `VDD_MAX`** | `LBC_CHGR_VDD_MAX` `0x1040` 原文 "It's also the voltage that the lbc regulates to when the battery is gone" |
| 驱动**从不设置 USB 输入电流限制（ICL）** | `pm8916_lbc.c` 全文只有 `USBIN_VALID` 状态位（第 31 行）与两处读取（188、346 行），无任何 `USBIN_IMAX` / `ICL` 寄存器操作。同族 `qcom_smbb.c` 有 `ATTR_USBIN_IMAX`（`usb-charge-current-limit`），LBC 没有 |
| 用户态**没有任何低电量处理** | 镜像里没有 battery 相关 systemd unit；`build-rootfs.sh` 无低电关机逻辑；`upower` 只在 max 档且读不到 `capacity`（见第三节） |
| 内核 watchdog **已启用**：`RuntimeWatchdogSec=60s`、`RebootWatchdogSec=60s` | `build-rootfs.sh:426-431`；`CONFIG_PM8916_WATCHDOG=m`，上限 127 秒 |
| PM8916 会记录上次掉电原因，但**只有 watchdog 驱动读它** | `pm8916_wdt.c:12-16,188-201` 定义并读取 `POFF_REASON1_PMIC_WD` / `POFF_REASON2_UVLO` / `POFF_REASON2_OTST3`；全树无任何写操作 |

### 6.2 主因：驱动没写完 PMIC 的启动握手，直供能力被限制

这一节在查到 PM8916 手册后重写过。原来的"电流预算不足"说法方向对，但漏了
真正的因果链。完整证据在 6.4a，这里给结论：

**PM8916 有 `POWERED_FROM_USB_CHARGER` 电源路径，且无电池时 LBC 会稳压到
`VDD_MAX`**——所以"没有直供模式"不成立。真正的问题是驱动的三处缺失让这条
路径几乎不可用：

| 缺失 | 手册要求 | 驱动现状 | 后果 |
|---|---|---|---|
| `LBC_MISC_BOOT_DONE` bit7 | "BOOT_DONE must also be set to 1 in order that FSM controlled charging starts" | **从不写**（全文件 0 处） | FSM 充电状态机不启动 |
| `LBC_USB_ENUM_TIMER_STOP` bit0 | 枚举成功后 SW 必须写 1，否则计时器到期把 `IBAT_MAX` 压到 **90mA** | **从不写**（0 处） | 插 USB 120 秒后充电能力降到 90mA |
| `LBC_BAT_IF_BAT_PRES_STATUS` | 硬件提供 `BAT_PRES` 位 | **从不读**（0 处） | 驱动不知道电池在不在，无法做相应策略 |

对照同族 PM8941 的 `qcom_smbb.c:718`，它有：

```c
/* The bootloader is supposed to set this... make sure anyway. */
{ SMBB_MISC_BOOT_DONE, BOOT_DONE, BOOT_DONE },
```

PM8916 驱动漏了这行。

**时间尺度对得上**：`ENUM_TIMER` 默认 `0x03` = **120 秒**。插 USB 两分钟后
充电上限被压到 90mA，之后系统靠这点功率硬撑，直到母线跌到 UVLO
（默认下降阈值 2.550V）→ PMIC 直接断电。半小时量级取决于负载与电容，
不是固定值。

**手册自己点名了这两个原因**：`PON_POFF_REASON2` bit3 `CHARGER` 的描述是
`Triggered by Charger (ENUM_TIMER, BOOT_DONE)`——把 ENUM_TIMER 和 BOOT_DONE
直接列为充电器触发的掉电原因。

### 6.3 UVLO 触发的硬复位，不是软件崩溃

- PM8916 的 `PON_POFF_REASON2` bit5 是 `UVLO`。若母线电压跌破阈值，PMIC 直接
  断电，**内核来不及打任何日志**——这与群友描述的"必重启"（而不是"死机"）吻合。
- `pm8916_wdt` 会把该位映射成 `WDIOF_POWERUNDER`，通过 `/dev/watchdog0` 的
  `WDIOC_GETBOOTSTATUS` 可读。
- **但本项目镜像里 `CONFIG_WATCHDOG_SYSFS` 未开**（`common-7.2.9-os.config:3637`），
  所以没有 `/sys/class/watchdog/watchdog0/bootstatus`；只能靠 `wdctl`
  （镜像里有 `/usr/bin/wdctl`，走 ioctl）读 `BOOTSTATUS` 位。
- **可直接验证**：下次重启后执行 `wdctl`，若 `Boot status` 出现 `POWERUNDER`，
  就确认是 UVLO。

### 6.4 PSTG 的真实语义（更正）

`CHG_CTRL` bit5 `PSTG_EN` 的完整描述是：

```
5  PSTG_EN  Power Stage Enable
   0x0: CHG_PSTG_NOT_FORCED_ON
   0x1: CHG_PSTG_FORCED_ON
4  FOLLOW_PSTG_EN_FSM  Follow Power Stage Enable from FSM
   0x0: IGNORE_PSTG_EN_FROM_FSM
   0x1: FOLLOW_PSTG_EN_FROM_FSM
```

**这不是"补充模式"（supplement mode）**。它是"**强制打开功率级**"的开关：
`PSTG_EN=1` 表示不管状态机怎么判，都把功率级强制打开。bit4 则是"跟随 FSM"。

`pm8916_lbc.c` 写的是 `CHG_EN | PSTG_EN` = `0x80 | 0x20` = **`0xA0`**。
对比复位值 `0x90` = `CHG_EN | FOLLOW_PSTG_EN_FSM`——驱动把"跟随 FSM"换成了
"强制打开"。

**这意味着**：驱动强制打开了功率级，但因为没有写 `BOOT_DONE`，FSM 的充电
状态机并没有真正启动。功率级开着、状态机没跑，这是 6.2 那条因果链的一部分。

**我之前的说法要撤回**：上一版把 PSTG 解释成"输入不足时由电池补充供电"，
并据此推出"无电池无处可补所以跌落"。手册没有支持这个解释。PSTG 是功率级
强制使能位，与"电池补充"无关。

### 6.4a 关于"没有直接供电模式"的界定

上一版这里写的是"只有一条由线性充电器兼作的通路"，**这个说法要更正**。
查到 PM8916 手册后，证据不支持它。

#### 手册里的三条硬证据

**（1）硬件确实有独立的电源路径状态**

`LBC_USB_PWR_PTH_STS`（`0x1308`，只读）bit1:0 的 `POWER_PATH` 字段：

| 值 | 含义 |
|---|---|
| `0x0` | NOT_USED |
| `0x1` | **POWERED_FROM_BATTERY** |
| `0x2` | **POWERED_FROM_USB_CHARGER** |
| `0x3` | NOT_USED_3 |

这是一个**显式的二选一电源路径状态**，不是"只有电池一路"。

**（2）无电池时 LBC 会主动稳压到 VDD_MAX**

`LBC_CHGR_VDD_MAX`（`0x1040`）的寄存器描述原文：

> The end voltage Battery charging voltage
> **It's also the voltage that the lbc regulates to when the battery is gone**

也就是说：电池不在时，LBC 不是"无处可补就放任母线跌落"，而是**把输出稳压到
`VDD_MAX` 设定的电压**。这是一个明确的"无电池供电"工作模式。

**（3）手册的充电流程图里有无电池分支**

设备规格书 Figure 3-1（p31）明确画了两个入口：

- `For case with Battery present **or NOT present**`
- `For Factory Test Mode: No battery and USB cable inserted`

#### 但"直供"仍然是有条件的，不是无限制的

这才是群友现象的真正解释。三个限制条件都在手册里：

**限制一：`BOOT_DONE` 必须被写 1，否则 FSM 充电不启动**

`LBC_CHGR_CHG_CTRL` bit7 `CHG_EN` 的描述原文：

> 1 = Enables FSM controlled charging
> **BOOT_DONE in the LBC_MISC peripheral must also be set to 1 in order that FSM controlled charging starts**

而 `pm8916_lbc.c` **从来不写 `LBC_MISC_BOOT_DONE`**（`grep -c BOOT_DONE` = 0，
全树也无第二处）。对比同族 PM8941 的 `qcom_smbb.c:718` 明确有：

```c
/* The bootloader is supposed to set this... make sure anyway. */
{ SMBB_MISC_BOOT_DONE, BOOT_DONE, BOOT_DONE },
```

PM8916 驱动缺了这一步。**后果**：驱动写了 `CHG_EN=1`，但 FSM 不会真正开始
充电状态机。

**限制二：ENUM_TIMER 到期会把 IBAT_MAX 压到 90mA**

`LBC_USB_ENUM_TIMER`（`0x134F`）的说明原文：

> If USB wall charger (DCP) is detected or USB enumeration (SDP) is successful,
> SW (PBL or SBL) has to write to the ENUM_TIMER_STOP bit and set IBAT_MAX.
> **When this timer expires, FSM assumes that USB enumeration has failed or
> >100mA current has not been granted. It sets the ENUM_TIMER_EXP flag and
> **sets IBAT_MAX = 90mA**.

`pm8916_lbc.c` 同样**从不写 `ENUM_TIMER_STOP`**（0 处）。默认 `ENUM_TIMER=0x03`
即 **120 秒**。所以插上 USB 后 120 秒，PMIC 自己把充电电流上限压到 90mA。

**限制三：`VIN_MIN` 决定输入电压跌落时的调节下限**

`LBC_CHGR_VIN_MIN`（`0x1047`）默认 `0x04`：

```
V = 4.229 V + X × 26.2 mV
X=4 → 4.334 V
```

这是**输入电压调节下限**：当 USB_IN 电压跌到这个值附近，LBC 会减少充电电流
以维持输入电压。它不是输入限流，但意味着**输入源被拉垮时 LBC 会优先保电压**。

#### 综合解释"半小时必重启"

三条限制叠加的实际效果：

1. 插 USB（不装电池）：`POWER_PATH` 应为 `POWERED_FROM_USB_CHARGER`，
   LBC 稳压到 `VDD_MAX`（驱动设的是 `voltage-max-design`，MF601SL 4.25V /
   MF32 4.2V）
2. 但 `BOOT_DONE` 没写 → FSM 不进入充电状态机
3. `ENUM_TIMER` 120 秒后到期 → `IBAT_MAX` 被压到 90mA
4. 于是**输入能力被限制在很小**，系统负载超过它时母线电压下跌
5. 跌到 `UVLO` 阈值（默认 2.725V 上升 / 2.550V 下降）→ **PMIC 直接断电，
   无中断、无日志**（`PON_POFF_REASON2` bit5 `UVLO`）

`PON_POFF_REASON2` bit3 `CHARGER` 的描述是 `Triggered by Charger (ENUM_TIMER, BOOT_DONE)`
——**手册自己把 ENUM_TIMER 和 BOOT_DONE 列为充电器触发的掉电原因**，正好对上。

#### 装电池为什么就稳

有电池时：

- `POWER_PATH` = `POWERED_FROM_BATTERY`，电池直接给系统供电
- 充电器只需补电池，不需要直接扛系统峰值
- `ENUM_TIMER` 的 90mA 限制只影响充电速度，不影响系统供电

所以"必须上电池"不是"没有直供模式"，而是**直供模式因为驱动缺陷被限制得
几乎不可用**。

#### 这是可以修的

如果确认属实，修法是在 `pm8916_lbc.c` 的 `probe()` 里补两处寄存器写：

```c
/* BOOT_DONE：告诉 PMIC 引导已完成，允许 FSM 充电 */
regmap_update_bits(chg->regmap, chg->reg[LBC_MISC] + 0x42, BIT(7), BIT(7));

/* 停止枚举计时器，避免 120 秒后 IBAT_MAX 被压到 90mA */
regmap_update_bits(chg->regmap, chg->reg[LBC_USB] + 0x4E, BIT(0), BIT(0));
```

但这两处**都是基于手册与驱动源码的推断，没有实机验证**。在实机确认前不要改：
错误的寄存器写可能损坏 PMIC 或电池。

**更稳妥的验证顺序**：

1. 装电池、插 USB，读 `POWER_PATH`（`0x1308` bit1:0）确认实际走哪一路
2. 读 `LBC_MISC_BOOT_DONE`（`0x1642`）确认 bootloader 是否已写过
3. 读 `LBC_USB_ENUM_TIMER_STOP`（`0x134E`）与 `ENUM_TIMER_EXP`（`0x1309` bit5）
4. 纯 USB 无电池下采样 `voltage_now`，看是否在 120 秒附近开始下跌

### 6.5 可以排除的方向

| 方向 | 排除依据 |
|---|---|
| 软件崩溃 / oops | 30 分钟量级不像崩溃；且 `RuntimeWatchdogSec=60s` 会让真死机在 60 秒内硬复位，不会拖到半小时 |
| 热节流 | 电池板 DTS 未定义 `thermal-zones` 的 cooling-maps（MF601SL 完全不包含 thermal 段，MF32 是反编译展开的独立表）；且重启而非降频 |
| RTC / 时钟问题 | 与本现象无关 |
| 电池驱动 probe 失败 | 若 LBC/BMS 没起来，`EXTCON_USB` 不会注册，插电脑连 RNDIS 都没有——但群友能刷机、能跑，说明驱动是起来的 |

### 6.6 建议

**短期（使用者侧）**：按群友经验，电池机型**装电池使用**。在驱动补齐之前，
纯 USB 供电确实不可靠。

**要确认根因**，需要按顺序做（都要实机）：

1. 装电池、插 USB，读 `LBC_USB_PWR_PTH_STS`（`0x1308` bit1:0）确认实际走
   `POWERED_FROM_USB_CHARGER` 还是 `POWERED_FROM_BATTERY`
2. 读 `LBC_MISC_BOOT_DONE`（`0x1642`）看 bootloader 是否已经写过 bit7
3. 读 `LBC_USB_ENUM_TIMER_STOP`（`0x134E`）与 `ENUM_TIMER_EXP`（`0x1309` bit5）
4. 纯 USB 无电池下每 10 秒采样 `voltage_now`，看是否在 120 秒附近开始下跌
5. 重启后跑 `wdctl` 读 `BOOTSTATUS`，看是否有 `POWERUNDER`

**若要真正修复**，方向是在 `pm8916_lbc.c` 的 `probe()` 里补两处寄存器写
（`BOOT_DONE` 与 `ENUM_TIMER_STOP`），见 6.4a 末尾。**在实机验证前不要改**：
错误的寄存器写可能损坏 PMIC 或电池。

**降低峰值功耗**（CPU 限频、关 WiFi/4G）只能延长时间，不解决根因。

**本节结论基于 PM8916 设备规格书（LM80-P0436-35 Rev.A）与硬件寄存器描述
（LM80-P0436-36 Rev.A）原文 + 7.2.9 驱动源码，未在实机验证。**
