# MF32 电源键、按键与外围能力研究

查证于反编译 DTB + 本仓 7.2.9 源码树（与 7.1.13 核对时一致）。结论分"驱动已证实的"与"待实机验证的"。

## 实物按键清单

| 按键 | 硬件 | DTB 状态 | 内核事件 |
|---|---|---|---|
| 电源键 | PMIC PON 块（KPDPWR_N 专用引脚，非 GPIO） | `pwrkey` okay | KEY_POWER(116)，防抖 15.6ms |
| Restart 通孔键 | TLMM GPIO34，低有效，上拉 | `gpio-keys/button-restart` okay | KEY_RESTART(408) |
| 第二 PMIC 键 (resin) | KPDPWR_N 旁边的 RESIN_N | **disabled** | 无——**拆解确认（2026-09-15）：第三键只有焊盘未上件**，全机仅 pwrkey 与 reset 两键可用，resin 永久保持 disabled |

## 电源键的完整生命周期（全部有驱动证据）

| 场景 | 机制 | 状态 |
|---|---|---|
| 关机状态按下 → 开机 | PON 硬件自主上电，不经 SoC | 硬件保证，待实机 |
| 运行中短按 | KEY_POWER → logind `HandlePowerKey` 默认 **poweroff** | 现成，可改语义 |
| 运行中长按 ~6-10s | PON 块的"长按强制复位"是**硬件行为**，主线驱动不配置不复位它 | 行为/时长待实机（兜底救援路径） |
| 挂起(suspend)中按下 | pwrkey **恒为唤醒源**（binding 明文：pwrkey 默认即 wake） | 驱动保证 |
| `poweroff` 落盘路径 | pm8941-pwrkey 的 reboot notifier 写 PON_PS_HOLD_TYPE_SHUTDOWN；`qcom,pshold` 驱动同路径 | 驱动保证 |
| `reboot bootloader` | `pon@800` 的 mode-bootloader/mode-recovery 由 `drivers/power/reset/qcom-pon.c` 注册成 reboot_mode，把意图写进 PON 寄存器，**stock aboot 读取后进 fastboot** | 与 UFI103s 同一套机制，现成 |

## 按键语义设计（已实现：tools/mf32-powerkey.sh + 自测）

MiFi 是口袋设备，两颗键都有误触风险：logind 默认会把意外短按变成关机；
PON 长按会把意外长按变成硬复位（丢数据）。**关机走双击**——双击比长按
更快，又比单击多一道防误触门槛；单/双击的歧义用 500ms 窗口消解，单击的
peek 立即触发，若 500ms 内来了第二次按下就由关机路径覆盖（LED 条闪一下
即灭，视觉可接受）：

| 操作 | 语义 | 实现 |
|---|---|---|
| 电源键单击（<800ms） | **电量 peek**：电量条亮 3 秒（QUIET 夜间模式也亮） | `do_peek` 写 `/run/mf32-powerkey/peek_until`，`mf32-led-state.sh` 读取 |
| **电源键双击**（两次按下间隔 ≤500ms） | **干净关机**（`systemctl poweroff`） | `do_poweroff`，先清 peek |
| 电源键长按（>1.5s） | 软件不动作 → PON 硬复位兜底 | 实测确认 PON 秒数后更新文档 |
| Restart 短按 | 未定义（预留：重启 4G 模组） | — |
| Restart 长按 5s | `reboot bootloader`（进 fastboot，救援键） | 未实现，保留设计 |

落地件（全部在 tools/，实机时装入 rootfs）：
- `mf32-powerkey.sh`：evdev 监听（按 `/sys/class/input/input*/name` 匹配
  `pm8941_pwrkey`），状态机无定时器（pending 靠第二次按下推进，永不空转）；
  `simulate` 模式可脱离硬件喂数据。
- `mf32-powerkey-selftest.sh`：11 项断言（双击关机/单击 peek/双击间隔超限/
  长按吞状态/三连击/慢按压边界）。
- `mf32-powerkey.service` + `mf32-logind-powerkey.conf`（**必须装到
  `/etc/systemd/logind.conf.d/`**，否则短按被 logind 抢先关机）。
- `mf32-led-state.sh` 的 peek/QUIET 支持（自测 30 项含两个新场景）。

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
