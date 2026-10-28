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
| 驱动初始化时**无条件**写 `CHG_EN \| PSTG_EN` 使能充电 | `pm8916_lbc.c:110-111` |
| 驱动**从不设置 USB 输入电流限制（ICL）** | `pm8916_lbc.c` 全文只有 `USBIN_VALID` 状态位（第 31 行）与两处读取（188、346 行），无任何 `USBIN_IMAX` / `ICL` 寄存器操作。同族 `qcom_smbb.c` 有 `ATTR_USBIN_IMAX`（`usb-charge-current-limit`），LBC 没有 |
| 用户态**没有任何低电量处理** | 镜像里没有 battery 相关 systemd unit；`build-rootfs.sh` 无低电关机逻辑；`upower` 只在 max 档且读不到 `capacity`（见第三节） |
| 内核 watchdog **已启用**：`RuntimeWatchdogSec=60s`、`RebootWatchdogSec=60s` | `build-rootfs.sh:426-431`；`CONFIG_PM8916_WATCHDOG=m`，上限 127 秒 |
| PM8916 会记录上次掉电原因，但**只有 watchdog 驱动读它** | `pm8916_wdt.c:12-16,188-201` 定义并读取 `POFF_REASON1_PMIC_WD` / `POFF_REASON2_UVLO` / `POFF_REASON2_OTST3`；全树无任何写操作 |

### 6.2 最可能的主因：纯 USB 供电时的电流预算不足

这是"半小时"这个时间尺度最吻合的解释：

1. **PM8916 LBC 是线性充电器**（`qcom,pm8916-lbc` 的 binding 原文：
   "Implements a simple, autonomous CC/CV charger"）。线性充电的输入电流
   ≈ 输出电流 + 自身压差损耗，它**不会**把 USB 的 5V 高效变换成电池电压。
2. **驱动不设 USB 输入限流**，所以输入限流取 PMIC 上电默认值。USB 2.0 端口
   通常只保证 **500 mA**（未枚举时 100 mA）。
3. 设备满载功耗实测：WiFi 吞吐测试时 CPU 有负载，历史记录里 4 核满载 45 秒
   升到 86℃、功耗显著高于 2.5W。**500 mA × 5V = 2.5W** 是 USB 2.0 的上限。
4. 因此纯 USB 供电时，系统净功耗 > 输入功率 → 缺口由电池补。**没有电池**
   就只有一个很小的输入电容，母线电压会缓慢下跌。
5. **半小时**这个量级与"小电容 + 2.5W 输入"的放电曲线一致，而不是分钟级
   （分钟级更像 UVLO 立即触发）。

**但这一条我不能确认为唯一原因**：缺少 PM8916 的 USB 输入限流默认值实测数据，
也没有纯 USB 供电下 `voltage_now` 的实测曲线。要证实需要：
`cat /sys/class/power_supply/pm8916-bms-vm/voltage_now` 每 10 秒采样一次，
记录从插上到重启的完整曲线。

### 6.3 第二可能：UVLO 触发的硬复位，而不是软件崩溃

- PM8916 的 `POFF_REASON2_UVLO`（bit5）就是"欠压锁定"标记。若母线电压跌破
  UVLO 阈值，PMIC 直接断电，**内核来不及打任何日志**——这与群友描述的
  "必重启"（而不是"死机"）吻合。
- `pm8916_wdt` 会把该位映射成 `WDIOF_POWERUNDER`，通过
  `/dev/watchdog0` 的 `WDIOC_GETBOOTSTATUS` 可读。
- **但本项目镜像里 `CONFIG_WATCHDOG_SYSFS` 未开**（`common-7.2.9-os.config:3637`
  `# CONFIG_WATCHDOG_SYSFS is not set`），所以没有
  `/sys/class/watchdog/watchdog0/bootstatus`；只能靠 `wdctl`（镜像里有
  `/usr/bin/wdctl`，走 ioctl）读 `BOOTSTATUS` 位。
- **这一点是可直接验证的**：下次重启后执行 `wdctl`，若 `Boot status` 里出现
  `POWERUNDER`，就基本确认是 UVLO。

### 6.4 第三可能：PM8916 的补充模式（PSTG）

`CHG_CTRL` 的 bit5 叫 `PSTG_EN`（Power Stage Enable）。驱动无条件置位它。
在 PM8916 LBC 上，PSTG 的作用是当输入功率不足以同时供系统 + 充电时，
**由电池补充供电**（supplement mode）。这正是"装了电池就稳"的机制：

- 有电池：PSTG 使能 → 输入不足时电池补，系统电压稳定 → 可稳定一个月
- 无电池：PSTG 无处可补 → 母线直接跌落 → UVLO 硬复位

这条与 6.2 是同一个物理过程的两面，且能解释"必须装电池"这个强相关性。

**未证实部分**：我没有 PM8916 寄存器手册确认 PSTG 在这颗 PMIC 上的确切行为，
只能从驱动无条件置位 + 同族 PMIC（PM8941 `qcom_smbb`）的 supplement 语义推断。

### 6.4a 关于"没有直接供电模式"的界定

一个常见的推论是"这板子没有 VBUS 直接供电模式"。这个说法**半对半错**，
需要分清两个层次：

**硬件层：存在 VBUS → VSYS 的通路，但不是独立的"直供模式"**

- 无电池时设备能开机、能跑半小时——如果完全没有 VBUS 到系统的通路，
  根本开不了机。所以通路**存在**。
- 但这条通路是**线性充电器的一部分**，不是独立的"adapter/USB 直供"模式。
  `pm8916_lbc.c` 的全部 6 处寄存器写**都在 `LBC_CHGR` 模块**，改的是
  电池侧参数（`VDD_MAX`/`VDD_SAFE` = 电池最高电压，`IBAT_MAX`/`IBAT_SAFE` =
  电池最大电流，`CHG_CTRL` = 充电使能，`TCHG_MAX_EN` = 充电超时）。
  **没有任何一处涉及 VSYS / 系统侧电压或电流**，也没有 `power path` /
  `POWER_PATH` 相关属性或寄存器。
- 对比同族：PM8941 的 `qcom_smbb.c` 文件头明确列出 `Buck`、`DC charge-path`、
  `USB charge-path`、`Boost` 等子模块，且有 `SMBB_USB_OTG_CTL`/`OTG_CTL_EN`
  与 OTG regulator。**PM8916 LBC 驱动里 OTG / boost / power path 一个都没有**。

**软件层：内核不提供、也控制不了"直供"这个模式**

- 驱动没有 ICL 接口（6.1 已列），所以无法调大输入限流去支撑系统峰值。
- 驱动不读 `bat_pres`，所以**不知道电池在不在**——它不会因为检测到无电池而
  切换到某种"直供"配置。
- 换句话说：硬件的通路能力由 PMIC 硅片和板级电路决定，Linux 这边既没有
  可写的开关，也没有可选的模式。

**所以更准确的说法是**：这不是"有/没有直供模式"的二值开关，而是
**"只有一条由线性充电器兼作的通路，能力受 PMIC 默认输入限流约束，
无法通过软件调整；有电池时靠 PSTG 补充，无电池时只能靠它硬扛"**。

群友的"必须上电池"经验，实质是：**这条通路的功率预算小于系统峰值功耗，
电池充当了必要的能量缓冲**。这不是一个可以靠改配置打开的"直供模式"。

### 6.5 可以排除的方向

| 方向 | 排除依据 |
|---|---|
| 软件崩溃 / oops | 30 分钟量级不像崩溃；且 `RuntimeWatchdogSec=60s` 会让真死机在 60 秒内硬复位，不会拖到半小时 |
| 热节流 | 电池板 DTS 未定义 `thermal-zones` 的 cooling-maps（MF601SL 完全不包含 thermal 段，MF32 是反编译展开的独立表）；且重启而非降频 |
| RTC / 时钟问题 | 与本现象无关 |
| 电池驱动 probe 失败 | 若 LBC/BMS 没起来，`EXTCON_USB` 不会注册，插电脑连 RNDIS 都没有——但群友能刷机、能跑，说明驱动是起来的 |

### 6.6 建议

**短期（使用者侧）**：按群友经验，电池机型**必须装电池使用**。这不是配置问题，
是供电架构问题。

**要确认根因**，需要做三件事（都要实机）：

1. 纯 USB 供电（不装电池）下每 10 秒采样 `voltage_now`，记录到重启的曲线
2. 重启后跑 `wdctl` 读 `BOOTSTATUS`，看是否有 `POWERUNDER`
3. 装电池重复 1、2 作为对照

**若要改善纯 USB 供电**，可行方向（均需实机验证）：

- 降低系统峰值功耗：CPU 限频到 800MHz、关 WiFi、关 4G
- 缩短 watchdog 超时到 30 秒，让真死机能更快自恢复（但这不解决 UVLO）
- **不要**试图用软件"提高输入限流"——驱动根本没有这个接口，且提高限流会让
  输入电压跌得更快

**本节的结论都是源码分析与推理，未在实机验证。**
