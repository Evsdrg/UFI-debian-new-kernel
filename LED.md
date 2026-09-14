# LED 状态灯：跨型号适配

一句话：**脚本已经机型通用，正常不需要按型号改任何东西。**

## 为什么能通用

五个支持机型（UFI103s/UFI003、UFI001b、UFI001c、SP970、UZ801）的三颗状态灯，
在设备树里用的是同一套语义，只是 GPIO 编号不同：

| 灯 | 设备树 function | 设备树 color | sysfs 名字 | 五机型是否一致 |
|---|---|---|---|---|
| 蓝 | `LED_FUNCTION_WLAN` | `LED_COLOR_ID_BLUE` | `blue:wlan` | 一致 |
| 绿 | `LED_FUNCTION_WAN` | `LED_COLOR_ID_GREEN` | `green:wan` | 一致 |
| 红 | `LED_FUNCTION_HEARTBEAT` | `LED_COLOR_ID_RED` | `red:heartbeat` | 一致 |

GPIO 差异（ufi00x 是 20/21/22，SP970 是 28/10/9，UZ801 是 6/8/7）**全部由各自的
DTB 承担**，内核据此生成同样的 sysfs 名字。所以脚本只认名字，天然通吃。

## 脚本怎么发现的

`/usr/local/sbin/ufi-led-state.sh` 启动时：

1. 先按已知名字找灯（`blue:wlan` / `green:wan` / `red:heartbeat`）；
2. 找不到就**按名字里的颜色词兜底**（`*/blue*`、`*/green*`、`*/red*`）；
3. 无线网口自动取第一个 `wlan*`（不写死 `wlan0`）；
4. 状态来源自动选：有 `nmcli` 用 NetworkManager，否则退回 `wpa_cli`，
   再退回只看路由表；4G 同理，有 NM 用 NM，否则用 `mmcli`。

设备上可以直接检查它发现了什么：

```sh
ufi-led-state.sh paths
# red   = /sys/class/leds/red:heartbeat
# blue  = /sys/class/leds/blue:wlan
# green = /sys/class/leds/green:wan
# wifi  = wlan0
# modem = auto
```

## 万一某机型不一样

改 `/etc/default/ufi-led-state`（镜像里已带这个文件，全部选项默认注释掉）：

```sh
# 灯名不同时指定
LED_BLUE_HINT=my:blue:led
LED_GREEN_HINT=my:green:led
LED_RED_HINT=my:red:led

# 网口不叫 wlan0
WIFI_IFACE=wlp1s0

# 4G 状态只信 ModemManager（不看 NM）
MODEM_MGMT=mm

# 红灯档位：CPU 超过 80% 亮，降到 75% 以下灭
RED_ON_PCT=80
RED_OFF_PCT=75
```

改完 `systemctl restart ufi-led-state` 即可，不需要重新构建镜像。
这份文件在构建时从 `tools/ufi-led-state.default` 安装。

## 灯语（五机型统一）

| 灯 | 常亮 | 快闪 | 慢闪 | 灭 |
|---|---|---|---|---|
| 蓝 | Wi-Fi 已连接 | 正在关联 | 无链路 | — |
| 绿 | 4G 数据会话已建立 | 正在连接 | 已注册/搜索中 | 无 SIM / 已锁 / 无模块 |
| 红 | CPU 负载 ≥ 70% | 从不闪 | 从不闪 | CPU 负载 < 65% |

红灯**故意不闪**：三颗灯都是 `max_brightness=1` 的 gpio-leds，软件 PWM 每次翻转
都把 CPU 从深空闲拉出（实测 4ms/16ms 翻转 → 深空闲退出 +101 次/秒）。红灯改用
"系统在忙"的负载档位，用 65%/70% 两点做滞回防抖动。绿灯闪是硬件 blink timer
的低频使用，代价可忽略。

空闲稳定态（无负载、Wi-Fi 连上、无 SIM）：**红灭 + 蓝常亮 + 绿灭**。

## 已实测

2026-09-14 在 UFI103s 上验证：
- 灯发现：三颗都正确定位；把提示名改成不存在的名字后，颜色兜底仍能找到；
- 状态：Wi-Fi `solid`（NM 报 `已连接`），无 SIM 时 4G 正确判 `off`；
- 容错：路径为空、路径不存在时 `led_off`/`led_solid`/`led_blink` 都不报错；
- 服务：`systemctl restart ufi-led-state` 后模式 `off,solid,off`，与三颗灯实际
  亮度值完全一致。

其余四个机型**没有实机**，它们的灯名一致性是从各自 DTS 逐条核对得出的，不是
实测；但即使某机型与预期不同，颜色兜底也会兜住。
