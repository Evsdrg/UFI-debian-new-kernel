# 电量百分比（OCV 查表）与 RNDIS 稳定性

本文回答两个问题：在只有电压读数的 BMS 上做电量百分比的可行性，以及 USB RNDIS
链路存在哪些可能影响稳定性的因素。

## 一、OCV 查表方案可行性

### 1.1 硬件能给什么

`pm8916_bms_vm` 的属性表（`pm8916_bms_vm.c:106-111`）只有：

| 属性 | 说明 |
|---|---|
| `STATUS` | `Charging` / `Discharging`（由 `power_supply_am_i_supplied()` 推导） |
| `VOLTAGE_NOW` | 最近一次 FIFO 采样值 × 300 µV |
| `VOLTAGE_OCV` | **仅开机后 180 秒内有效**，之后返回 `-ENODATA` |
| `HEALTH` | 与 `voltage_min/max_design` 比较 |

采样：S1/S2 间隔各 10（寄存器单位），FIFO 长度 2，驱动只取**最后一个样本**
（`pm8916_bms_vm.c:132`）。硬件注释明确写着"VM-BMS 只采集电压，SoC 需软件计算"。

### 1.2 分辨率够不够

`VOLTAGE_NOW` 的 LSB 是 **300 µV**。按 DTS 的 OCV 表换算：

| 电压区间 | 每 1% 需要的电压 | 300 µV 对应的容量误差 |
|---|---|---|
| 4.10–4.25 V（高 SOC） | 12–25 mV | 0.012–0.024% |
| 3.15–4.10 V（主体） | **10 mV** | **0.030%** |
| 3.00–3.15 V（末端） | 25–100 mV | 0.003–0.012% |

**分辨率完全够用**——量化误差远小于电池本身的 OCV 分散性（同型号电芯 ±2–3%）。

### 1.3 真正的问题不是分辨率，是 OCV 拿不到

这是本节最重要的结论：

- `VOLTAGE_NOW` 是**带负载的端电压**（`vbat_now`），不是 OCV
- `VOLTAGE_OCV` 只在开机后 180 秒内有效，之后驱动主动返回 `-ENODATA`
  （`pm8916_bms_vm.c:88-98`，注释写明"硬件只在关机或挂起时可靠测量 OCV"）

所以运行期只能拿 `VOLTAGE_NOW`。用带负载的端电压直接查 OCV 表，误差取决于
负载电流与电池内阻：

```
V_terminal = V_ocv - I_load × R_internal
```

典型 18650/软包电芯 `R_internal` 约 80–150 mΩ。按 500 mA 负载、100 mΩ 估算，
压降约 **50 mV**——在 3.15–4.10 V 区间相当于 **5% 的容量误差**。这是单靠
`VOLTAGE_NOW` 查表的**固有误差下限**。

### 1.4 可行的实现方式

**方案 A：纯 `VOLTAGE_NOW` + OCV 表（简单，误差约 ±5–10%）**

- 读 `/sys/class/power_supply/pm8916-bms-vm/voltage_now`（µV）
- 在脚本里内嵌与 DTS 一致的 OCV 表，线性插值
- 用 `STATUS` 判断充放电，充电时加一个偏移补偿（充电时端电压偏高）
- 优点：零内核改动、零额外依赖
- 缺点：负载突变时百分比会跳变；充电/放电曲线不同

**方案 B：开机 180 秒内抓 `VOLTAGE_OCV` 做基准 + 运行期用 `VOLTAGE_NOW` 增量修正**

- 开机时读一次 `VOLTAGE_OCV`（此时有效）作为初始 SOC
- 之后只用 `VOLTAGE_NOW` 做相对变化（相当于把 OCV 当锚点）
- 优点：初始值准确
- 缺点：只修正了起点，长时间运行仍会漂移；且本项目没有电流积分（`CURRENT_NOW` 不存在）

**方案 C：改内核驱动，加 `CURRENT_NOW` 与 `CAPACITY`**

- 需要硬件支持电流测量——**BMS VM 硬件只采电压，没有电流通道**
  （`pm8916_bms_vm.c:123-132` 注释明确写 "The VM-BMS hardware only collects
  voltage data"）
- 所以这条路**走不通**，除非换用别的 PMIC 电量计（如 `pm8916_bms` 而非 `bms_vm`）

**结论：只能走方案 A（或 A+B 组合）。** 精度上限约 ±5%，够做"电量条"这种
4 档显示，不够做精确百分比。若要更好，必须加电流测量硬件。

### 1.5 与 DTS OCV 表的一致性维护

OCV 表当前只在 DTB 里（`simple-battery` 的 `ocv-capacity-table-0`），用户态
**取不到**（`power_supply_battery_info` 不导出到 sysfs）。所以脚本必须内嵌一份。

维护约定：

- 脚本里的表与 DTS 的 `ocv-capacity-table-0` 必须逐点一致
- 改 DTS 时同步改脚本，并在两边互相引用（DTS 注释指向脚本，脚本注释指向 DTS）
- 建议加一条校验：`tools/verify-layout.sh` 比对两处的点数与首尾值

### 1.6 建议的落点

`tools/mf32-led-state.sh` 的 `find_batt_psy()` 现在找"第一个有 `capacity` 的
power_supply"，在这个平台上永远找不到，所以电量条从来不亮。

应改为：

1. 优先找 `capacity`（兼容将来有真实电量计的板）
2. 回退到 `pm8916-bms-vm` 的 `voltage_now` + 内嵌 OCV 表
3. 充电时（`STATUS=Charging`）用充电 OCV 曲线或加 +50mV 补偿

这样 UFI（无电池）不受影响，MF32/MF601SL 能显示电量。

## 二、RNDIS 稳定性因素

### 2.1 链路结构

```
[PC] --USB--> [ci_hdrc UDC] --configfs gadget--> rndis.usb0 --> usb0 (10.42.0.1/24)
                                                                    |
                                          NM shared 或 native-net（dnsmasq + nft NAT）
                                                                    |
                                                              wlan0 / wwan0（上游）
```

### 2.2 已确认的风险点

#### 风险 1：`usb-gadget.service` 无 `Restart=`，启动失败即永久失败 ✅ 已修复

`tools/usb-gadget.service` 是 `Type=oneshot` + `RemainAfterExit=yes`，**没有
`Restart=`**。若开机时 UDC 尚未就绪（脚本等 20×0.5s = 10 秒），或 configfs
操作失败，服务进入 `failed` 状态且**不会重试**。此时：

- `usb0` 不存在 → NM 的 `usb-share` 连接一直 pending
- PC 侧完全看不到网卡
- 用户唯一补救是 `systemctl restart usb-gadget`

**修复**：加 `Restart=on-failure` + `RestartSec=3` + `StartLimitIntervalSec=0`
（oneshot 配 `Restart=on-failure` 合法，`Restart=always` 才被禁止），
`TimeoutStartSec` 提到 60。另外新增 `usb-gadget-watchdog.timer`：每 30 秒
检查一次 gadget 是否仍完整绑定，失效就重建（见下面风险 9）。

#### 风险 2：NM shared 模式不做 MSS clamp，上游 MTU < 1500 时大包被丢 ✅ 已修复

`usb-share.nmconnection` 没有设 `mtu`，NM shared 模式生成的 nft 规则里
（实测 `nm-shared-usb0` 表）只有 `masquerade`、`ct state`、`reject`，**没有
`tcp option maxseg size` 规则**。

如果 WiFi 上游是 PPPoE（MTU 1492）或更小：

- PC 按 USB 网卡的 MTU 1500 发包
- 转发到 wlan0 时被分片或丢弃（取决于上游是否接受分片）
- 典型症状：ping 通、小请求通、HTTPS 大包卡死

**这个项目历史上踩过一次**：2026-10-16 验证时曾误判为 PMTU 问题，后来发现
是测试目标 IP 不可达。但**机制本身是真实存在的**，只是当时没触发。

**修复**（三条一起，缺一不可）：

1. `usb-share.nmconnection` 的 `[ethernet] mtu=1400`
2. `/etc/NetworkManager/dnsmasq-shared.d/90-usb-shared-mtu.conf` 下发
   `dhcp-option=option:mtu,1400`，让 PC 侧也按 1400 发包
3. native 档：`10-usb0.network` 的 `MTUBytes=1400`，`dnsmasq.conf` 同样的
   DHCP 选项，`nat.nft` 里加 `tcp option maxseg size set 1360`

只做第 1 条只能限制设备→PC 方向；PC→设备方向仍会发 1500。

#### 风险 3：`usb-gadget.service` 与 NM 的顺序只是 `Before=`，不是 `Requires=` ✅ 已修复

`usb-gadget.service` 有 `Before=NetworkManager.service`，但如果 gadget 启动
**失败**，NM 仍会正常启动（`Before` 只影响顺序）。此时 NM 会一直尝试激活
`usb-share` 但接口不存在，日志里会出现反复重试。

**修复**：`usb-share.nmconnection` 加 `autoconnect-retries=0`（0 = 无限重试）。
NM 默认只重试 4 次就永久放弃，USB 重新枚举或 gadget 重启后拉不起来。

#### 风险 4：UDC 等待窗口只有 10 秒，可能不够 ✅ 已修复

`usb-gadget.sh:76-83` 最多等 20×0.5s = 10 秒。`TimeoutStartSec=30` 给了 30 秒，
但脚本自己在 10 秒后就放弃了。慢速 eMMC 或内核模块加载慢时可能不够。

**修复**：循环改成 `seq 1 60`（30 秒），与 `TimeoutStartSec=60` 留出一半余量。

#### 风险 5：`MaxPower 200`（200 mA）声明值可能偏低 ✅ 已修复

configfs 的 `MaxPower` 单位是 mA。200 mA 是向主机声明的取电上限，**不影响数据
传输**，但如果设备实际功耗超过声明值，某些严格的主机（尤其是 USB hub）可能
在枚举后限流甚至断开。

MF601SL/MF32 带电池，充电时功耗可能超过 200 mA。已调到 **500 mA**
（USB 2.0 单个配置允许的上限）。

#### 风险 6：`extcon` 只接了 ID，没有 VBUS 检测 ℹ️ 信息

`usb_extcon_detect_cable()`（`extcon-usb-gpio.c:59-85`）的逻辑：

```c
id   = id_gpiod   ? 读值 : 1;
vbus = vbus_gpiod ? 读值 : id;   // 只有 ID 时，VBUS 跟随 ID
```

MF601SL/MF32 都只定义了 `id-gpios`（`bias-pull-up`）：

- 插电脑（micro-B ID 悬空）→ id=1 → `EXTCON_USB=true` → device 模式 ✅
- 插 OTG 外设（ID 接地）→ id=0 → `EXTCON_USB_HOST=true` → host 模式 ✅

**逻辑正确**，但注意：只有 ID 时**无法区分"插了充电器"和"插了电脑"**——两者都
让 ID 悬空。所以插充电器时设备也会进入 device 模式（gadget 绑定，但主机不存在），
这本身无害，只是多一次无意义的枚举尝试。

#### 风险 7：RNDIS 在 Windows/macOS 上的兼容性未验证 ⚠️ 中

`f_rndis` 是 Linux 的 RNDIS 实现，Windows 原生支持（靠 `os_desc` 的
`compatible_id=RNDIS` + `sub_compatible_id=5162001` 触发自动装驱动）。
macOS **不原生支持 RNDIS**，需要第三方驱动（HoRNDIS，且在新版 macOS 上已失效）。

**本项目只在 Linux 主机上验证过**。Windows/macOS 兼容性属于未验证项。

#### 风险 8：USB autosuspend —— 已排除 ℹ️

`CONFIG_USB_AUTOSUSPEND_DELAY=2` 看起来像风险，但它只作用于 **USB 主机控制器
对下游设备**的自动挂起。设备侧（做 device）的 `ci_hdrc_msm` 驱动**没有设置
`CI_HDRC_SUPPORTS_RUNTIME_PM` 标志**（`ci_hdrc_msm.c:190-192` 的 flags 里没有它），
所以 gadget 侧不参与 runtime PM 自动挂起。

**结论：本项目不需要额外处理 autosuspend。** 历史实机日志里也没有相关记录。

#### 风险 9：内核侧解绑后 gadget 不自动重绑（"RNDIS 自己断开"的根因）✅ 已修复

这是"群友观测到 RNDIS 会断开"最主要的内核侧机制：

- configfs gadget 的驱动标志 **`match_existing_only = 1`**（`configfs.c:1985`），
  所以 UDC 后出现时内核**不会**自动把 gadget 绑上去
- `usb-gadget.service` 是 `oneshot + RemainAfterExit`，绑定成功后即使内核侧解绑了
  （UDC 注销、控制器掉电恢复、USB 重新枚举），**systemd 仍认为服务 active**，
  不会触发 `Restart=`
- `configfs_composite_unbind()` **不清 `udc_name`**，所以 `$G/UDC` 里仍显示旧名字；
  而 `complete()` 要求 `[ -d "$UDCS/<名字>" ]`，一旦 UDC 目录消失就返回失败
- 旧版 `start()` 遇到"UDC 有值但 complete 失败"时直接 `fail '请先明确停止'`，
  **自愈被自己挡住**

**修复**：

1. `usb-gadget.sh start()` 改为区分两种情况：UDC 目录**还在**（真的有别的 gadget
   占着）→ 拒绝；UDC 目录**已不存在**（内核侧已解绑的残留）→ 清理重建
2. `remove_tree()` 在 UDC 已消失、写空失败时，只要确认 `$UDCS/<名字>` 不存在就继续清
3. 新增 `usb-gadget-watchdog.timer`（每 30 秒）+ `usb-gadget-watchdog.service`：
   调 `usb-gadget.sh status`，非 active 就重跑 `start`（start 幂等，且有 flock 串行）

#### 风险 10：没有 IPv6（`ipv6.method=ignore`）ℹ️ 信息

`usb-share.nmconnection` 里 `[ipv6] method=ignore`。这不影响 IPv4 稳定性，
但如果 PC 侧有 IPv6 优先的应用，可能出现"解析到 AAAA 后超时"的假性卡顿。
**建议保持现状**（避免引入 SLAAC/DHCPv6 复杂度），但在文档里注明。

### 2.3 已验证的稳定性数据

| 项目 | 数据 | 来源 |
|---|---|---|
| USB 直连吞吐 | 180 / 151 Mbit/s，0 重传 | 2026-10-16 验证 |
| gadget 重启恢复 | 3 次重启 + 半装配恢复通过 | 2026-10-10 USB 修复 |
| 开机自动开放 | 重启后 21 秒主机自动拿到地址 | 2026-10-16 验证 |
| NM shared 真实 NAT | 隔离客户端出网，来源为设备 WiFi 地址 | 2026-10-16 验证 |

**未验证**：长时间（>1 小时）大流量传输、反复插拔（>100 次）、Windows/macOS、
USB hub 级联、USB 3.0 主机口（RNDIS 是 USB 2.0 设备）。

## 三、优先级建议

| 状态 | 项目 | 位置 |
|---|---|---|
| ✅ | gadget 失败自动重启 | `tools/usb-gadget.service` |
| ✅ | gadget 定时健康检查与重建 | `tools/usb-gadget-watchdog.{sh,service,timer}` |
| ✅ | UDC 后出现/内核解绑后重建 | `tools/usb-gadget.sh` 的 `start()` / `remove_tree()` |
| ✅ | UDC 等待窗口 10s → 30s | `tools/usb-gadget.sh` |
| ✅ | `MaxPower` 200 → 500 mA | `tools/usb-gadget.sh` |
| ✅ | NM 档 MTU 1400（设备侧 + DHCP 下发） | `usb-share.nmconnection` + `90-usb-shared-mtu.conf` |
| ✅ | native 档 MTU 1400 + MSS clamp | `10-usb0.network` / `dnsmasq.conf` / `nat.nft` |
| ✅ | `autoconnect-retries=0`（无限重试） | `usb-share.nmconnection` |
| — | OCV 电量百分比（方案 A） | 未实现；精度 ±5%，够做电量条 |
| — | 内核侧加 CAPACITY | 走不通，硬件无电流通道 |

**以上修复均通过离线测试（10 项）与 QEMU 冒烟，但未在实机验证。**
实机验收需要：插拔 USB 主机线、USB 主机休眠唤醒、反复重启 gadget 服务，
确认 `usb0` 的 carrier 恢复后 PC 侧不用重新插拔就能继续通信。
