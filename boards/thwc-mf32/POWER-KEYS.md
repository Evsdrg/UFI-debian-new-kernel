# MF32 电源键、按键与外围能力研究

查证于反编译 DTB + 本仓 7.1.13 源码树。结论分"驱动已证实的"与"待实机验证的"。

## 实物按键清单

| 按键 | 硬件 | DTB 状态 | 内核事件 |
|---|---|---|---|
| 电源键 | PMIC PON 块（KPDPWR_N 专用引脚，非 GPIO） | `pwrkey` okay | KEY_POWER(116)，防抖 15.6ms |
| Restart 通孔键 | TLMM GPIO34，低有效，上拉 | `gpio-keys/button-restart` okay | KEY_RESTART(408) |
| 第二 PMIC 键 (resin) | KPDPWR_N 旁边的 RESIN_N | **disabled** | 无（板上大概率没这颗键） |

## 电源键的完整生命周期（全部有驱动证据）

| 场景 | 机制 | 状态 |
|---|---|---|
| 关机状态按下 → 开机 | PON 硬件自主上电，不经 SoC | 硬件保证，待实机 |
| 运行中短按 | KEY_POWER → logind `HandlePowerKey` 默认 **poweroff** | 现成，可改语义 |
| 运行中长按 ~6-10s | PON 块的"长按强制复位"是**硬件行为**，主线驱动不配置不复位它 | 行为/时长待实机（兜底救援路径） |
| 挂起(suspend)中按下 | pwrkey **恒为唤醒源**（binding 明文：pwrkey 默认即 wake） | 驱动保证 |
| `poweroff` 落盘路径 | pm8941-pwrkey 的 reboot notifier 写 PON_PS_HOLD_TYPE_SHUTDOWN；`qcom,pshold` 驱动同路径 | 驱动保证 |
| `reboot bootloader` | `pon@800` 的 mode-bootloader/mode-recovery 由 `drivers/power/reset/qcom-pon.c` 注册成 reboot_mode，把意图写进 PON 寄存器，**stock aboot 读取后进 fastboot** | 与 UFI103s 同一套机制，现成 |

## 按键语义设计建议（防误触优先，待实机落地）

MiFi 是口袋设备，两颗键都有误触风险：logind 默认会把意外短按变成关机；
PON 长按会把意外长按变成硬复位（丢数据）。建议把短/中按语义接管到用户态，
只把超长按留给硬件兜底：

| 操作 | 建议语义 |
|---|---|
| 电源键短按（<1s） | **电量 peek**：LED 电量条亮 3 秒显示当前档位（MiFi 惯例），需要 `mf32-led-state.sh` 加 override 机制 |
| 电源键长按 3-5s | 干净 `poweroff`（LED 红快闪过渡，走 ExecStop 现有路径） |
| 电源键超长按 | 不处理 → PON 硬复位兜底（实测确认秒数后写进文档） |
| Restart 短按 | 未定义（预留：重启 4G 模组） |
| Restart 长按 5s | `reboot bootloader`（进 fastboot，救援键） |

落地件：logind drop-in（`HandlePowerKey=ignore`）+ 一个 evdev 监听小
daemon（读 /dev/input/eventN，区分短/长按）+ `mf32-led-state.sh` 的
peek override。配置里 `INPUT_PM8941_PWRKEY=y` 已开，无需动。

## 其他外围能力速览

| 能力 | DTB | 内核/配置现状 |
|---|---|---|
| 震动马达 | pm8916-vib **okay** | `INPUT_PM8XXX_VIBRATOR=m` ✓（ff-memless，可直接用） |
| RTC + 闹钟 | pm8941-rtc（带 alarm） | `RTC_DRV_PM8XXX=m` ✓；**闹钟能否从关机开机取决于 PON 配置，未知** |
| 过温保护 | spmi-temp-alarm + tsens 5 区 | `QCOM_SPMI_TEMP_ALARM=m` ✓ |
| 电池计量 ADC | vadc 7 通道（含 vbat_sns） | `QCOM_SPMI_VADC=m` ✓ |
| SD 卡槽 | sdhci @7864000，cd=GPIO38 | 驱动同 eMMC ✓ |
| USB OTG | ci-hdrc dr_mode=otg，ID=GPIO110 | extcon-usb-gpio 切 host/peripheral ✓ |
| 音频 | q6 全栈 + WCD 模拟/数字 codec，LPASS okay | **sound card disabled**——有无喇叭待实机；要出声需自建 sound 节点 |
| GPS | memshare + gps@0x8bd00000 预留 1MB | memshare disabled → **预留纯浪费**（照回收方案砍） |
| 看门狗 | pm8916-wdt timeout=60s | 已知约束：只接受 1..127s，systemd 修复方案沿用 |

## 待实机验证清单（电源相关）

1. 关机（pshold→PMIC）后是否彻底断电、静态电流多少
2. 插充电器是否自动开机；关机状态是否硬件自主充电（插着即充）
3. PON 长按硬复位的实际秒数
4. 电源键开机的最短按压时长
5. RTC 闹钟开机是否被 PON 支持
