# 7.2.9 第二轮实机验证（2026-10-16）

设备：UFI103s（Handsome OpenStick），**无串口管理窗口**。
方法：`fastboot boot` 内存启动 `artifacts/boot/ufi103s-ufi003/boot-board-venus-4g-gpu-7.2.9.img`，
**未写 boot 分区**。用户态资产（gadget 脚本、NM 配置）沿用设备 rootfs 上已部署的修复后版本，
与主仓逐个哈希一致。

## 结果矩阵

| 项目 | 状态 | 数据 |
|---|---|---|
| boot 分区未变 | ✅ | `9159529f…` 与验证前一致 |
| 7.2.9 RAM 启动 | ✅ | `7.2.9-ufix0x-venus-4g-gpu-dirty #2` |
| USB gadget | ✅ | `active UDC=ci_hdrc.0`，主机侧 `0525:a4a2` |
| usb0 地址 | ✅ | `10.42.0.1/24` |
| DHCP / DNS | ✅ | 主机拿到 `10.42.0.33/24`；`@10.42.0.1` 解析正常 |
| **真实 NAT** | ✅ | 隔离客户端（`10.42.0.33`）访问上游服务，来源为 **`192.0.2.109`** |
| 外网 HTTPS | ✅ | `HTTP 200`，remote_ip 为 Cloudflare |
| nft 规则 | ✅ | `nm-shared-usb0` 含 `ct state` + `reject` |
| USB 直连吞吐 | ✅ | **180 / 151 Mbit/s**（历史 164/149） |
| WiFi 吞吐 | ✅ | **49.1 / 53.1 / 50.8 Mbit/s**（历史 46.3） |
| WiFi 断连重连 | ✅ | 3 轮，每轮 **1 秒**恢复，网关可达 |
| GPU | ✅ | `DRIVER=adreno`，**FD307 / freedreno** |
| H.264 硬编→硬解 | ✅ | 640×480，**30 帧逐字节一致** |
| H.264 矩阵 | ✅ | 1280×736、1920×1088 各 **180 帧**哈希匹配 |
| VP8 硬解 | ✅ | 45 帧 **逐帧一致** |
| MPEG-2 硬解 | ⚠️ | 45 帧解出，**舍入差异**（历史已知） |
| HEVC 软解→H264 硬编 | ✅ | 45 帧，转码 rc=0 |
| MPEG-4 硬解 | ❌ | 固件 `Err_Fatal … vbuffer.c:1200`（历史已知，非新增） |
| Venus 自动恢复 | ✅ | fatal 后驱动报 `recovered`，H.264 硬解**继续可用** |
| 蓝牙 | ✅ | 控制器 `Powered: yes`，扫描发现 25 设备 |
| LED | ✅ | sysfs 全枚举，可读写 |
| 存储 | ✅ | 64MiB 写入 9.3 MB/s，哈希回读一致 |
| xrdp + i3 | ✅ | TLS 登录，i3bar + xterm 实际渲染并截图 |
| 推流（GPU→Venus→UDP） | ✅ | **27 fps @1280×736**，收端 1188 帧/39.6s |
| 推流周期 IDR | ✅ | 40 个关键帧 / 39.6s ≈ 每秒 1 个 |
| **中途加入** | ✅ | 推流已跑 8s 后才开始收，**第 1 帧即 IDR**，600 帧解出 |
| 散热（CPU 满载） | ⚠️ | 45s 满载峰值 **86°C**，降频 1209→1094MHz |
| 散热（推流持续） | ⚠️ | **160s** 持续，45°C→**84°C** 峰值（约 110s 到 80°C） |
| 4G 模组 | ⚠️ | 驱动与控制通道正常，`sim-missing`（现场无 SIM） |

通过 22 / 已知限制 6 / 失败 1（历史已知）。

## 本轮新发现

**1. CMA 被 movable 分配借用（新）**
MPEG-4 fatal 后 `CmaFree` 跌至 **108 KB**，而 `dma_buf` 无占用、无 venus 进程。
`sync; echo 3 > /proc/sys/vm/drop_caches` 后回升到 **10 MB**（`MemFree` 同时 26MB→127MB）。
说明是**内存压力下 movable pageblock 借用了 CMA 区域**，不是 venus 泄漏。推流等吃 CMA 的
负载前建议先 drop_caches。

**2. MPEG-4 fatal 后 WiFi 暂时劣化（新观察）**
fatal 后 `tx bitrate` 一度掉到 **13.5 Mbit/s MCS 0**（≈2.4 Mbit/s 实测），
约数分钟后自愈回到 **90 Mbit/s MCS 4**。补丁 0002 已生效（`wcn36xx.ko` 哈希与
`artifacts` 一致），MCS0 是暂时现象而非速率自适应卡死。同期 `rx bitrate` 始终正常。

**3. Venus 自动恢复优于历史记录**
此前记录 MPEG-4 fatal "需重启恢复"，本轮驱动自行完成 `recovered`，
H.264 硬解在 fatal 后**直接可用**（输出 13824000 字节）。

**4. xrdp 会话残留**
SSH 断开后 xrdp 会话与 xterm 不会自动回收，`loginctl list-sessions` 可见残留。
清理需 `pgrep -x xterm` 精确杀，不能用 `terminate-session`（会连带杀掉 console 会话）。

## 设备最终状态

- 运行 `7.2.9-ufix0x-venus-4g-gpu-dirty`（RAM，up 14:57）
- 温度 41–52°C，`CmaFree` 17.7 MB，无失败服务
- `usb-gadget` / `NetworkManager` / `xrdp` 均 active
- `wlan0=192.0.2.109`，`usb0=10.42.0.1`
- **boot 分区仍为 7.1.13**，重启即回退

原始日志与截图见 `out/validation-20261015/`。
