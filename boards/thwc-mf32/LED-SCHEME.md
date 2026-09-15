# MF32 LED 方案设计

硬件前提（来自反编译 DTB）：**一颗 RGB 三通道 LED**（R=GPIO27 / G=GPIO29 / B=GPIO30，
共透镜）+ **4 颗独立 LED**（GPIO19/20/21/22，厂配为 per-CPU 活动灯）。
所有灯都是 gpio-leds、只有 0/1 两态，无 PWM；闪烁只能用内核 `timer` trigger。

## 分工

| 灯组 | 职责 |
|---|---|
| RGB（一次只亮一个通道） | 系统状态：异常/低电/关机警示 + 网络状态 |
| 4 颗独立 LED | 电量条：档位 + 充电填充 + 低电快闪 |

弃用原厂 per-CPU 活动灯：headless MiFi 没人看 CPU 灯，4 颗排成一排正是天然
的电量条。RGB 混色（黄/品红/白）不可靠（透镜混色质量未知），设计上禁止使用，
一次只亮一个通道。

## RGB 系统状态（优先级从高到低，同时刻仅一态生效）

| 优先 | 条件 | 显示 | 性质 |
|---|---|---|---|
| 0 | 电量 ≤8% 且未充电，或正在关机 | 红快闪 250/250 | 到关机为止 |
| 1 | 系统异常（关键单元 failed / 过温） | 红慢闪 1000/1000 | 持续 |
| 2 | 低电警告（≤15% 且未充电） | 红常亮 | 持续 |
| 3 | Wi-Fi 已配置但断开 | 蓝慢闪 1000/1000 | 持续到恢复 |
| 4 | 4G 数据会话已建立 | 绿常亮 | 稳态 |
| 5 | 4G 正在拨号连接 | 绿快闪 250/250 | 瞬态 |
| 6 | 系统正常（默认稳态） | 蓝常亮 | 稳态 |

排序理由：红系是"必须处理"，蓝慢闪（用户设备连不上来了）优先于绿系
（外网状态），4G 会话是 MiFi 核心功能所以绿常亮压过空闲蓝。充电信息
**不进 RGB**——全部由电量条表达，避免双重指示互相打架。

省电原则（与 ufi-led-state 相同）：稳态只允许"常亮"或"灭"，闪烁只存在于
瞬态/异常/充电填充。4G"已注册无会话"不闪灯（回蓝常亮），避免每秒 2 次
的 timer 唤醒长期存在。

## 电量条

读 `/sys/class/power_supply/*/capacity`（auto 发现， psy 名实机校准）+
`status`（Charging/Full/Discharging）：

| 电量 | 未充电 | 充电中 |
|---|---|---|
| >75%（含充满） | 4 颗常亮 | 4 颗常亮 |
| 50–75% | 3 常亮 | 3 常亮 + 第 4 颗慢闪 500/500 |
| 25–50% | 2 常亮 | 2 常亮 + 第 3 颗慢闪 |
| 8–25% | 1 常亮 | 1 常亮 + 第 2 颗慢闪 |
| ≤8% | 第 1 颗快闪 250/250（与 RGB 红快闪联动） | 同充电行 |

- 档位滞回 3%：升档需跨过 25/50/75，降档需跌破 22/47/72，防止边界抖动。
- "第 N+1 颗慢闪"即经典充电填充指示；充满即全常亮。
- 电量条稳态全是常亮，无定时器唤醒；只有填充位和危急快闪驱动 timer。

## 开关机与启动阶段

- **内核接管前**：DTS 只给绿通道挂 `heartbeat` 默认 trigger（绿闪=内核活了），
  其余全灭；红/蓝不设默认 trigger。
- **服务接管后**：按上表。`ExecStop`（关机）把 RGB 切红常亮 2 秒再全灭，
  给"正在关机"一个可见反馈。
- **关机后**：全灭（PMIC 断电，灯自然灭）。
- 4G/WiFi 状态来源与 ufi-led-state 一致：nmcli 优先，回退 mmcli/wpa_cli。

## DTS 节点草案（供 mf32 板级 dts 使用）

```dts
leds {
	compatible = "gpio-leds";
	pinctrl-names = "default";
	pinctrl-0 = <&mf32_leds_default>;

	/* 系统状态 RGB：function/color 出 sysfs 名 red:status 等 */
	led-sys-r { color = <LED_COLOR_ID_RED>;   function = LED_FUNCTION_STATUS;
		    gpios = <&tlmm 27 GPIO_ACTIVE_HIGH>; };
	led-sys-g { color = <LED_COLOR_ID_GREEN>; function = LED_FUNCTION_STATUS;
		    gpios = <&tlmm 29 GPIO_ACTIVE_HIGH>;
		    linux,default-trigger = "heartbeat"; };
	led-sys-b { color = <LED_COLOR_ID_BLUE>;  function = LED_FUNCTION_STATUS;
		    gpios = <&tlmm 30 GPIO_ACTIVE_HIGH>; };

	/* 电量条：bat:1..4 的 GPIO 映射按实机物理顺序校准后落定 */
	led-bat-1 { label = "bat:1"; gpios = <&tlmm 19 GPIO_ACTIVE_HIGH>; };
	led-bat-2 { label = "bat:2"; gpios = <&tlmm 22 GPIO_ACTIVE_HIGH>; };
	led-bat-3 { label = "bat:3"; gpios = <&tlmm 21 GPIO_ACTIVE_HIGH>; };
	led-bat-4 { label = "bat:4"; gpios = <&tlmm 20 GPIO_ACTIVE_HIGH>; };

	/* SIM 切换器沿用厂配（sim:sel/en/sel2/en2），不是指示灯，不进本方案 */
};
```

原厂 DTB 的 `led-r(mmc0)/led-g(heartbeat)/led-b(phy0tx)` 与 cpu0-3 trigger
全部弃用。**bat:N 的物理左右顺序必须实机校准**，校准结果落在本 DTS。

## 实现

- `tools/mf32-led-state.sh`：状态机 + 渲染，支持 `monitor`（服务主循环）、
  `once`（单次渲染，供自测）、`off`（systemd ExecStop：红常亮后全灭）。
- `tools/mf32-led-selftest.sh`：假 sysfs + 假 nmcli/systemctl 注水，
  26 项断言覆盖全部 RGB 优先级分支、电量条档位/滞回/充电填充/危急快闪。
  改状态机必须先跑它。
- LED/电源/sysfs 根路径可用环境变量替换（`MF32_LED_SYS`、`MF32_PSY_SYS`、
  `MF32_STATE`），自测不依赖实机。
- 配置覆盖 `/etc/default/mf32-led-state`：阈值、节拍、`QUIET=1`（夜间静音：
  稳态灯全灭，只保留异常/充电/低电指示）。
- 不并入现有 build-rootfs 流程：那是 UFI 棒的 rootfs；MF32 将来有自己的
  flavor 时再挂 `mf32-led-state.service`。
