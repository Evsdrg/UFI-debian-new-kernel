# MF601SL LED 与电源键方案（C 实现，事件驱动）

**2026-11-01 用户实机确认物理方位**（以充电口朝下为基准）。

## 一、硬件（唯一事实来源）

6 颗灯，两两一组，共三组。GPIO 来自原厂 `boot.img` 内 DTB 的 `gpio-leds` 节点，
与仓库 `boards/thwc-mf601sl/dts/msm8916-thwc-mf601sl-v07.dts` 完全一致。

| 方位 | 功能 | 红 | 绿 | sysfs 名 |
|---|---|---|---|---|
| **左上** | LTE | GPIO 115 | GPIO 116 | `red:wan` / `green:wan` |
| **右上** | 电量 | GPIO 110 | GPIO 112 | `red:power` / `green:power` |
| **右下** | WiFi | GPIO 119 | GPIO 120 | `red:wlan` / `green:wlan` |

另有 4 个 SIM 切换控制（GPIO 24/49/50/51，`sim:sel`/`sim:en`/`sim:sel2`/`sim:en2`），
它们是 GPIO 而非灯，不参与灯语。

所有灯都是 `gpio-leds`、只有 0/1 两态、无 PWM；闪烁只能用内核 `timer` trigger。

## 二、灯语

### 电量组（右上）

**稳态一律不亮**（省电，无常驻显示需求）。短按电源键后显示 3 秒。

| 条件 | 红灯 | 绿灯 |
|---|---|---|
| ≤8% 且未充电（危急） | 快闪 250/250（任何模式都显示，安全警示） | 灭 |
| ≤15% | 常亮 | 灭 |
| >15% | 灭 | 常亮 |
| 充电中且 <100% | 灭 | 慢闪 1000/1000 |
| 充满 | 灭 | 常亮 |

### LTE 组（左上）

| 条件 | 红灯 | 绿灯 |
|---|---|---|
| 模组故障 / 无 SIM（`remoteproc` 非 running 或 `mmcli` 报 failed/locked） | 慢闪 1000/1000 | 灭 |
| **有卡但注册被拒**（`qmicli` 报 `registration-denied` / `registration-limited`） | **常亮** | 灭 |
| 数据会话已建立（`wwan0` operstate=up） | 灭 | 常亮 |
| 搜索中 / 未注册 | 灭 | 灭 |

> 为什么必须区分「搜索中」与「注册被拒」：`mmcli` 会把被网络拒绝的卡报成
> `state: searching`，只看它就得到「全灭＝正在搜索」，而用户实际已经上不了网。
> 真实注册结果只能从 `qmicli --nas-get-serving-system` 的 `Registration state` 取。

### WiFi 组（右下）

**任何状态都有灯，不允许全灭。**

| 条件 | 红灯 | 绿灯 |
|---|---|---|
| 已连接 | 灭 | 常亮 |
| 已配置但断开 | 慢闪 1000/1000 | 灭 |
| 无配置 | 灭 | **慢闪 1000/1000** |

## 三、电源键（唯一物理按键 `pm8941_pwrkey`）

| 操作 | 语义 |
|---|---|
| 短按 <800ms | 电量组 peek 3 秒 |
| 双击（间隔 ≤500ms） | 关机（`systemctl poweroff`） |
| 长按 2s ~ 10s | 切换显示模式（六灯同时快闪两下作反馈） |
| 长按 >10.3s | PON bark（内核仅收中断，本进程不处理） |
| 长按 >12.3s | PMIC 硬件复位（不可阻止，救援通道） |

`/etc/systemd/logind.conf.d/mf601-powerkey.conf` 把 `HandlePowerKey` 设为
`ignore`，否则短按会先被 logind 直接关机。

## 四、显示模式（持久化于 `/var/lib/mf601sl-ledctl/mode`）

| 模式 | 状态灯 | 电量组 |
|---|---|---|
| 0 默认 | 正常工作 | 默认灭，短按显示 3 秒 |
| 1 常亮 | 正常工作 | 常亮 |
| 2 全灭 | 灭，短按后 3 秒恢复 | 灭，短按后 3 秒 |

## 五、实现

`tools/mf601sl-ledctl.c` —— 单进程 C 守护进程，systemd 单元
`mf601sl-ledctl.service`。

- **事件驱动**：`poll(2)` 同时等待 evdev（电源键）、`NETLINK_ROUTE`（网络接口
  变化）与 `NETLINK_KOBJECT_UEVENT`（power_supply 变化），稳态无轮询、
  无周期性唤醒。闪烁交给内核 `timer` trigger，用户态不设心跳。
- **uevent 必须按 SUBSYSTEM 过滤**：写 LED sysfs 本身也会发 kobject uevent
  （实测 `change /devices/platform/leds/leds/<name>`，每 20ms 一条）。不过滤会
  形成「收到自己写的事件 → 采样电池 + render → 再写 LED」的自反馈死循环：
  实测 CPU 占用约 8%（18–20 jiffies / 2s），`timer` trigger 被反复重置导致
  6 颗灯一起快速抽搐。修复后 CPU 实测 **0 jiffies / 2s**（完全阻塞在 poll）。
  双保险：只处理 `SUBSYSTEM=power_supply` 的事件 + LED 目标状态缓存（目标
  不变就不写 sysfs）。
- **`delay_on`/`delay_off` 必须在 `trigger=timer` 之后写**：这是 ledtrig-timer
  注册的 sysfs 属性，切 trigger 之前写会静默失败（属性不存在），内核就退到
  默认 500/500ms——比设计的 1000/1000 快一倍，看起来就是「快速闪烁」。
- **编译**：`build-rootfs.sh` 内的 `build_ledctl()` 用
  `aarch64-linux-gnu-gcc -std=gnu23 -O2 -Wall -Wextra -Werror -Wshadow
  -Wformat=2 -Wstrict-prototypes -Wmissing-prototypes -static` 交叉编译，
  **零告警**，静态链接，不依赖镜像内 glibc 版本。
- **自测**：`tools/mf601sl-ledctl-selftest.sh`（假 sysfs + 假 evdev 注水，
  18 个场景 37 项断言）。该脚本只在开发机跑，不装进镜像。

## 六、与 MF32 的关系

MF32 的 `tools/mf32-ledctl.c` 是同一套事件驱动框架，但硬件完全不同
（3 颗单色状态灯 + 4 颗电池条，无红绿配对），因此各自独立实现、不共用
灯名表。两者都由 `build-rootfs.sh` 按 `ROOTFS_BOARD` 选择编译安装。

**2026-11-01 起 MF32 也切到 C 版**（此前 `mf32-ledctl.c` 虽已写好但构建里
装的仍是 `mf32-led-state.sh`）。批量时注意：MF32 的 C 版自测 21/21 通过，
但尚未在 MF32 实机上跑过；实机此前验证的是 shell 版行为。
