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

---

# 第三轮：整机刷入验收（同日）

上一轮全部跑在「RAM 内核 + 设备原 rootfs」上，**新构建的 rootfs 从未整机刷入**。
本轮的目标是把验收标准提到「刷入后开箱即用」：设备插到电脑上就能自动开出 RNDIS
并让两边正常通信。

## 刷入前的核查（发现一个会直接导致失联的缺陷）

逐项核对镜像内容时发现：**7 张 rootfs 的预置 Wi-Fi `psk=` 都是错的**
（`            <真实口令>`，11 个前导空格 + 真口令），而设备在用的是 `<真实口令>`。
根因是凭据文件里用了裸反斜杠转义（详见 `ISSUES.md` 第 15 条）。
若直接刷入，开机连不上 AP —— 棒子无屏、USB 共享的 NAT 上游又正是 WiFi，
**刷完即失联**。

修复：`.local-creds` 改用单引号包真实口令；`build-rootfs.sh` 加 `_ws_guard`
（凭据含前后空白就拒绝构建）；重编全部档位。

## 刷入步骤

分两步走，把「内核能否从闪存启动」与「新 rootfs 能否用」两个风险分开：

1. **先只刷 boot**（p12），保留现有 rootfs —— 现有 rootfs 配的正是这份内核，
   等于把内存预演变成从闪存启动，风险最低。
2. 确认无误后**再刷 rootfs**（p14）。

回退依据（刷前做齐，且逐项校验过）：

| 备份 | 内容 | 校验 |
|---|---|---|
| `out/flash-20261016/p12-before-7.2.9.img` | 原 boot 分区 | SHA256 与设备一致 |
| `out/flash-20261016/p14-before-7.2.9.img.gz` | 原 rootfs | gzip 完整；解压 3571432960 字节 = p14 精确大小 |

刷前另外实测确认：镜像 fstab 的 PARTUUID = boot cmdline 的 `root=` = 设备 p14
实际 PARTUUID（`a7ab80e8…`）；镜像 `root` 口令 hash 用 `crypt` 验证 MATCH；
内核 release 与 rootfs 模块树目录名完全一致。

## 结果：开箱即用验收通过

设备**只插在电脑上、不做任何手工配置**，重启后实测：

| 项目 | 结果 |
|---|---|
| 内核从闪存启动 | ✅ `7.2.9-ufix0x-venus-4g-gpu-dirty`（uptime 真实归零） |
| **USB RNDIS 自动开放** | ✅ 主机侧自动出现网卡并拿到 `10.42.0.x` |
| gadget | ✅ `active`，UDC `configured` |
| usb0 | ✅ `10.42.0.1/24` |
| **WiFi 自动连接** | ✅ 开机即连上 AP（**验证 PSK 修复生效**） |
| tx bitrate | ✅ `90.0 Mbit/s MCS 4`（正常档） |
| 电脑→设备 L3 | ✅ ping 3/3，RTT 0.5ms |
| 电脑→设备 SSH | ✅ 用镜像里的口令登录成功 |
| DNS（经设备） | ✅ `@10.42.0.1` 正常解析 |
| **真实 NAT** | ✅ 隔离客户端（`10.42.0.170`）访问 LAN 服务，上游看到的来源是**设备 WiFi 地址 `192.0.2.109`** |
| nft 规则 | ✅ `nm-shared-usb0` 含 `ct state` + `masquerade` + `reject` |
| ip_forward | ✅ `1` |
| 根分区自动撑满 | ✅ `1.6G/3.3G (50%)`（`x-systemd.growfs` 生效） |
| 失败服务 | ✅ **0** |
| GPU | ✅ `renderD128`、`1c00000.gpu` |
| venus | ✅ `video0`/`video1`，三个模块 vermagic 全匹配 |
| 模块 vermagic | ✅ `msm`/`nft_ct`/`wcn36xx` 均为当前 release |
| CMA / 内存 | ✅ `CmaFree` 11MB；可用 270MB / 375MB |
| 温度 | ✅ 47°C（空闲） |

## 一个需要说明的测试假象

公网 `https://1.1.1.1` 经设备不通，一度被当成 NAT 故障。实测查明：
**主机自己直连 `1.1.1.1:443` 也失败**（该网络环境必须走 `127.0.0.1:7897` 代理才出网），
所以公网 TCP 在这个环境下本就不能作为 NAT 判据。改用局域网内服务做判据后
（隔离客户端出网、上游看到设备 WiFi 源地址），NAT 被证实工作。

原始日志见 `out/flash-20261016/`。

## 刷入后状态

- **boot 分区已写入 7.2.9**（哈希 `244b840e…`），不再是 RAM 启动
- **rootfs 已换为新建的 max 档镜像**，预置 WiFi 为正确值
- 设备可经 WiFi 与 USB 两条路管理；USB 直连为 `10.42.0.1`

---

# 第四轮：发布镜像**不预置 WiFi**（同日，最终定案）

上一轮把“预置 WiFi 的值写对”当作修复方向。但这类缺陷的本质不是“值写错了”，
而是**凭据会被静默写进镜像**——只要还存在预置路径，就总有下一个写法/取值失误
会再现同样的“刷完即失联”。所以本轮**从结构上移除这个问题类别**：

- 镜像**完全不预置任何 WiFi 凭据**；
- 无屏设备的首次进系统路径统一为 **USB RNDIS**（插电脑即得 `10.42.0.1`）；
- 配无线用 `nmtui` / `nmcli`（`docs/hardware/NETWORK.md`）。

## 代码改动

| 文件 | 改动 |
|---|---|
| `build-rootfs.sh` | 删除 nm 档的 `openstick-wifi.nmconnection` heredoc 与 native 档的 `network{}` 段；`_ws_guard` 守护对象改为 `ROOTFS_ROOT_PASSWORD`;文件头补说明 |
| `tools/build-matrix.sh` | 不再读/传 `ROOTFS_WIFI_SSID` / `ROOTFS_WIFI_PSK` |
| `.local-creds.example` | 删除 SSID/PSK 两项，改为说明“镜像不预置 WiFi” |
| `tools/verify-usb-sharing.py` | 交付断言**反转为拒绝带预置 WiFi 的镜像**（nm 档的 `openstick-wifi.nmconnection`、native 档的 `wpa_supplicant-wlan0.conf` 不得含 `network=`/`ssid=`/`psk=`）|
| `tools/build-rootfs-common.sh` | 删除（无人引用的死代码） |

## 验证

**1. 静态：7 张镜像全部合格**（独立脚本 `out/no-wifi-20261016/verify-images.sh`，不采信交付脚本）：

| 镜像 | WiFi profile | wpa 网络段 | USB 共享资产 |
|---|---|---|---|
| max / basic / slim / micro | ✅ 无 | ✅ 无 | ✅ NM 档齐 |
| basic-native / slim-native / micro-native | ✅ 无 | ✅ 无 | ✅ native 档齐 |

`python3 tools/verify-usb-sharing.py` 对 7 张全部 `USB_DELIVERY_OK`（rc=0）。
**负向测试**：拿带预置 WiFi 的旧镜像跑同一脚本，被判 `ships a preset Wi-Fi profile`（rc=1）——断言确实能拦住。

**2. 整机刷入**（max 档 + venus-4g-gpu boot，均先比 `build.json` 的 sha256）：

- boot 前 8003584 字节哈希 = 镜像 sha256（`11f975b2…`）✅
- rootfs 刷入 440s，开机后 `system-connections/` **只有 `usb-share.nmconnection`**（无 WiFi）

**3. 开箱即用（重启后验证，boot_id `9146ce22` → `ce4d7a12`、uptime 归零）**：

| 项目 | 结果 |
|---|---|
| **USB RNDIS 自动开放** | ✅ 重启后 21s 主机自动拿到 `10.42.0.26/24` |
| gadget | ✅ `active UDC=ci_hdrc.0` |
| usb0 | ✅ `10.42.0.1/24` |
| WiFi 配置 | ✅ **空**（`wlan0: disconnected`，符合发布意图） |
| 电脑→设备 ping | ✅ 2/2，RTT 0.6ms |
| 电脑→设备 SSH | ✅ `ufi103s 7.2.9-ufix0x-venus-4g-gpu-dirty` |
| DHCP | ✅ 主机得 `10.42.0.26`（设备 dnsmasq 租约） |
| 失败服务 | ✅ 0 |
| 无 WiFi 时默认路由 | ✅ 0 条（无上游，符合预期） |

**4. 首次配网闭环**（模拟用户拿到设备后的操作）：经 USB 执行 `nmcli dev wifi connect`
→ `wlan0` 激活、默认路由经 `wlan0` 恢复；隔离客户端再验真实 NAT，
上游看到的来源是设备 WiFi 地址 `192.0.2.109`；DNS 经设备解析 + 真实域名 HTTPS 200。
测试后已删除配网 profile，还原到“刚刷完”状态。

## 一个必须记下的误判

验证“真实 NAT”时一度认为存在 **PMTU/MSS 问题**（ping 通、小 TCP 通、
HTTPS 卡死；探测到路径 MTU 1492 为 PPPoE 典型值），并临时加过 MSS clamp 规则。
后查明：**是我选的目标 IP（`93.184.215.14`）本身不可达**，不是 MTU 问题。
换用可达目标（`223.5.5.5:443` 返 404、`www.baidu.com` 返 200）后一切正常。
临时规则已全部删除。教训：**换一个可达目标再下结论**，别把“目标不可达”
误读成链路缺陷。

## 最终设备状态

- 运行 `7.2.9-ufix0x-venus-4g-gpu-dirty`（**已从闪存启动**，boot 分区 `244b840e…`）
- rootfs = 本轮新建 max 档，**不含任何 WiFi 凭据**
- `usb0=10.42.0.1`，插电脑即得 `10.42.0.x`；无 WiFi 时只有 USB 一条管理通道
- 失败服务 0

原始日志见 `out/no-wifi-20261016/`、`out/flash-20261016/`。

---

# 第四轮（2026-10-17）：minimal 变体（最简功能内核）

目标：在 WiFi + USB 网络共享 + zram 三条链之外全部裁掉，把内核足迹压到最小。
构建方式与板型表见 [`../build/BUILD-MATRIX.md`](../build/BUILD-MATRIX.md)。

## 两次实机失败与根因（均由用户手动断电恢复）

**首次：硬挂死，无任何输出**。`fastboot boot` 后主机再无 USB 事件、无重启、
WiFi 不通。根因：片段里写了 `CONFIG_QCOM_APCS_IPC=n`，而
`QCOM_CLK_APCS_MSM8916`（msm8916 CPU 时钟控制器）`depends on` 它，导致 CPU 时钟
驱动整个符号消失，内核在早期 CPU 频率初始化时挂死。**QEMU 冒烟完全正常**——
QEMU 没有 msm8916 APCS 硬件，掩盖了该缺陷。这是“QEMU 通过 ≠ 实机通过”的典型。

**第二次：能启动，但丢了 Reset 按键**。`CONFIG_INPUT_KEYBOARD=n` 把
`if INPUT_KEYBOARD` 内的 `CONFIG_KEYBOARD_GPIO`（DTS `gpio-keys` 的 Reset 键）
一起切掉了，只剩 `pm8941_pwrkey`，无任何报错。

两者均已修复（`QCOM_APCS_IPC=y`、`INPUT_KEYBOARD=y` + `KEYBOARD_GPIO=y`，
其余键盘驱动仍关）。

## 实机验收（fastboot boot，未写 boot 分区）

| 项目 | 结果 |
|---|---|
| 启动 | ✅ 12–15 秒到 SSH（`7.2.9-ufix0x-minimal-dirty`） |
| GPU / venus / 4G | 已裁，符合预期 |
| **WiFi** | ✅ wcn36xx+mac80211+cfg80211 加载；`nmcli dev wifi connect` 成功，`192.0.2.102`，默认路由就位 |
| **USB 共享** | ✅ gadget `active UDC=ci_hdrc.0`；`usb0=10.42.0.1/24`；隔堆客户端访问 LAN 服务，来源 = 设备 WiFi 地址（NAT 真实工作）；外网 HTTPS 200；DNS 正常 |
| **zram** | ✅ `/dev/zram0` 350M，算法 **zstd** |
| **状态灯** | ✅ 8 个 LED 全在（blue:wlan/green:wan/red:heartbeat/sim:*），亮度实测可写 |
| **Reset 键** | ✅ `gpio-keys` event0（修复后） |
| `pm8941_pwrkey` | ✅ event1 |
| 失败服务 | ✅ 0 |
| USB 大文件传输 | ✅ 32MB / 3.24s（≈10MB/s），两端 sha256 一致 |
| 无 WiFi 时 | ✅ `usb0` 自动就位、`wlan0` DOWN——“到货即插即用”状态 |

## 内存与体积（与 GPU 版实机对比）

| 项 | minimal | venus-4g-gpu | 差 |
|---|---:|---:|---:|
| `MemTotal` | 484176 kB | 384632 kB | **+97 MB** |
| `MemAvailable`（空载） | 382348 kB | 282536 kB | **+98 MB** |
| boot 镜像 | 5,935,104 B | 8,003,584 B | −26% |
| 解压内核 | 15,849,480 B | 21,723,144 B | −27% |
| 模块树 `.ko` 数 | 460 | 696 | −34% |
| `lsmod` 运行时模块 | 46 | — | |

⚠️ **归因**：~97MB 的 `MemTotal` 增量来自 **DTS**（空板型 disabled
mpss/mba/rmtfs/venus_mem 预留），在 baseline 变体上就已存在；内核配置裁剪的
收益是镜像体积/rodata/模块数，**不是** MemTotal。两个维度要分开讲。

## 已知残留限制

- `CONFIG_RFKILL=n`：`rfkill list` 报 `/dev/rfkill` 不存在，但 WiFi 扫描/连接/
  数据面实测均正常，不愿为一个小工具增加内建代码。若要 `rfkill` 命令行工具，
  需把 `CONFIG_RFKILL` 改为 `=y`。
- `kernel.sysrq=0` 的 sysctl 在 minimal 下报“parameter not found”（
  `CONFIG_MAGIC_SYSRQ=n` 已裁），无害。
- MPEG-4/GPU/4G/散热：minimal 不含这些链，不适用。

原始日志见 `out/minimal-v2/`、`out/minimal-v3/`。
