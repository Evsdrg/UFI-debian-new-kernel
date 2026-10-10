# 7.2.9 验收问题的源码研究（2026-10-10）

本轮接续 [实机验收](VALIDATION-7.2.9.md)，**只研究，不修改生产配置、补丁或脚本**。
研究结论与已实测的修复必须区分；以下候选方案尚未完成实施验收。

## 一、结论分级

| 问题 | 根因核对 | 本轮结论 |
|---|---|---|
| NM USB NAT | ✅ | 缺依赖、nft 表达式、gadget 管理权；影响全部五个内核变体及四个 NM 档 |
| gadget 异常却报成功 | ✅ | 不存在的 OS descriptor 属性 + 不检查失败 + 用属性文件大小误判绑定 |
| native USB 共享 | ⚠️ | 未实机验证；另有启动竞态、规则作用域和生命周期问题，不能视作天然可靠替代 |
| MPEG-4 fatal | ⚠️ | 已定位错误传播链；固件断言条件仍未知，不能认定只需扩大 CMA |
| 推流高 CPU | ✅/⚠️ | 隔离实验确认 RGB→NV12 路径成本很高；未完成全链性能分解或优化验收 |
| 80°C 中止 | ✅ | 测试保护早于本地 CPU 的 85°C 被动冷却阈值；上游原本是 75°C，已被本地 DTS 改高 |

## 二、研究基础与现场边界

源码版本与设备包版本对齐：

- 项目内核：`source/linux-7.2.9/`，检查本地 patch 与 pristine 差异。
- NetworkManager：设备 `1.52.1-1`；研究上游 tag `1.52.1`。
- FFmpeg：设备 `7:7.1.5-0+deb13u1`；研究上游 tag `n7.1.5`。
- wf-recorder：设备 `0.5.0-2`；研究上游 tag `v0.5.0`。
- 当前文档经 Context7 核对，同时以对应 tag 的真实源码为主。

本轮下载的源码、原始实验日志与候选配置都在 `out/research-20261010/`，不入 git。
上述第三方源码是对应上游 tag，**不是逐项核对过全部 Debian 包补丁的源包副本**。

开始时设备仍为第二次 RAM 启动的 7.2.9，uptime **11小时16分钟**，0 failed units，
温度约 36–41°C。只读观察表明它在低负载下没有重启；**不是 11 小时持续压测通过**。
唯一新增设备实验是有限帧数、75°C 保护的纯软件转换测试，退出后恢复 CPU 最大频率，
没有调用 MPEG-4 硬解、没有重启或刷写，没有改防火墙/USB/串口状态。

## 三、USB：应修复完整交付链，而不是换一条临时 NAT 规则

### 3.1 NetworkManager 为何“激活成功但不能出网”

对应源码：`NetworkManager-1.52.1/src/core/nm-firewall-utils.c`。

- `702–770`：共享 IPv4 生成 **`table ip`**，不是 `table inet`；包含 `masquerade`、
  `ct state { established, related }` 和两条 `reject`。
- `1225–1246`：`nm_firewall_config_apply_sync()` 返回 `void`，调用 nft 后不把失败
  向设备激活流程传播；`src/core/devices/nm-device.c:13581–13586` 随后继续处理连接。
- `1251–1260`：先找 nft，再找 iptables；两者都不存在时仍选择 nft 后端，
  **不是“缺 nft 就自动免防火墙工作”**。
- `1262–1300`：后端是进程内静态缓存，并读取原始配置。因此单纯 `nmcli general reload`
  不能当作切换后端或清缓存的保证；实施时应设计维护窗口/备用入口，不能直接重启
  唯一网络入口上的 NM。

验收日志 `out/validation-20261010/nat-investigation.txt` 正好报以上 `ct`/`reject`
表达式 ENOENT，然后显示成功激活。现象与源码吻合。

### 3.2 内核最小缺项与影响范围

逐一核对五份 `build/variant-7.2.9-board-*/.config`：全部已有 NF_TABLES、
NF_CONNTRACK、NF_NAT、NFT_MASQ、NFT_NAT，但**全部缺 NFT_CT 和 NFT_REJECT**。
所以不能只重建 GPU 内核。

做了一次隔离 `olddefconfig` 实验：仅在研究目录复制配置，设置
`NFT_CT=m`、`NFT_REJECT=m`，内核 Kconfig 推导出：

```text
CONFIG_NFT_CT=m
CONFIG_NFT_REJECT=m
CONFIG_NFT_REJECT_INET=m
CONFIG_NFT_REJECT_IPV4=m
CONFIG_NF_REJECT_IPV4=m
CONFIG_NFT_REJECT_IPV6=m
CONFIG_NF_REJECT_IPV6=m
```

依据 `net/netfilter/Kconfig:491,578–590`、`net/ipv4/netfilter/Kconfig:42–45` 与
IPv6 对应项：隐藏的 REJECT 家族选项由默认值和 select 派生。**不能以只看两行配置
为验收**，要检查最终 `.config`、模块树及依赖闭包。NM 当前 IPv4 共享主要需要
IPv4 reject；inet/IPv6 项是当前配置推导及共用网络能力，不能混称都是本次 IPv4
事务的直接必需项。

### 3.3 rootfs 的正确管理权与依赖

- `build-rootfs.sh:147–155` 只在 native 分支显式加入 nftables。
  NM 四档也需要；已只读确认新 max 镜像里 nft/iptables 都不存在。
- 当前 `[keyfile] unmanaged-devices=none` 不能清除 udev 的 unmanaged 原因。
- `NetworkManager-1.52.1/man/NetworkManager.conf.xml:1235–1246` 明确：
  **`[device-…] managed=1` 的优先级高于 udev**，仍可运行时由 D-Bus 覆盖。
  推荐仅匹配 `interface-name:usb0`，不要全局取消所有 udev 管理策略。
- rootfs 的 nftables **包需要安装，但 NM 档不应另启全局 nftables.service 去接管
  同一份规则**。防火墙规则所有权应由 NM shared 管理；全局 dnsmasq 也应维持禁用，
  由 NM 拉起共享口自己的实例。
- `tools/nm-connections/usb-share.nmconnection` 没有显式 `address1`。NM 源码
  `src/core/nm-netns.c:579–583` 是分配空闲的 `10.42.x.1`，不是无条件固定
  `10.42.0.1`。若网关地址是产品合同，应显式配置并测冲突处理，不靠默认猜测。

候选配置方向（未安装到设备）：

```ini
[main]
firewall-backend=nftables

[device-openstick-usb]
match-device=interface-name:usb0
managed=1
```

### 3.4 gadget 还有比错误属性更深的状态机缺陷

源码：`tools/usb-gadget.sh`、内核 `drivers/usb/gadget/configfs.c` 与
`fs/configfs/dir.c:488–493`。

| 缺陷 | 源码/实测依据 | 修复要求 |
|---|---|---|
| interface 的 `b_vendor_code` 不存在 | configfs.c:1516–1524 只列 compatible_id/sub_compatible_id；现场目录一致 | vendor code 只写 gadget 的 os_desc 属性 |
| 错误装配后继续绑定并报成功 | 脚本只有 `set -u`，多数写入/链接失败不处理 | 每步检查、失败清理、非零退出；不能仅加一行后遗留半成品 |
| 用 `test -s UDC` 判定绑定 | 现场 `UDC` 的 stat size=4096；configfs inode 设为 PAGE_SIZE，与内容无关 | 读取实际 UDC 名，再核对期望函数/配置；status 同样修正 |
| restart/stop 不可靠 | teardown 忽略全部错误；部分装配后的下次 start 可能误认为 active | start/stop/status 都应幂等；禁止在半装配状态静默返回 0 |
| 供电注释错误 | MaxPower=200 在 configfs 中是 200mA；composite.c:529–547 再编码 USB 单位 | 5V 下声明约1W，不是注释的2W；实际耗电未测，不能据此诊断掉电 |
| systemd 顺序名称错误 | usb-gadget.service 写 `Before=... networkd.service` | 正确单元为 systemd-networkd.service；还需区分“服务启动”与地址就绪 |
| 全平台免驱未验 | 单一 RNDIS；现场只测 Linux | Windows/macOS 兼容性独立验收，不能靠注释保证；是否引入 ECM/NCM 是另一个设计决策 |

本轮没有为验证错误判定而解绑设备 USB；PAGE_SIZE 行为已由现场和源码双重确认。

### 3.5 native 不应被当成“绕开 NM 即解决”

`tools/net-native/` 另有静态问题，尚未做实机故障复现：

- `native-net.service` 只有 `After=systemd-networkd.service wpa_supplicant.service`，
  不保证 gadget 已创建，更不保证 usb0 地址就绪；`Wants=network-online.target`
  **不等于 `After=network-online.target`**。dnsmasq `bind-interfaces` 存在启动竞态。
- `nat.nft` 对所有从 wlan0/wwan0 离开的流量做 masquerade，没限定 USB 来源；
  没有明确的转发隔离策略，不能把它视作与 NM 的共享规则等价。
- stop 只杀 dnsmasq，不删除本服务拥有的 nft 表；文件也没有明确重载去重策略。
- oneshot 启动后台 dnsmasq，RemainAfterExit 掩盖后续 dnsmasq 退出，无独立守护。
- native README 说用全局 supplicant，而实际构建启用的是 `wpa_supplicant@wlan0`。
  本轮不擅自更换栈，但需要消除文档与实现分叉。
- `tools/qemu-smoke.sh:53–54` **过滤了 usb-gadget 与 native-net 的失败**。
  所以七镜像 PASS 从来不证明两套 USB 栈可用。

建议两栈保留各自唯一的网络/规则所有者，共用 gadget 生命周期与内核能力验收；
native 的 DHCP/DNS 单独托管、只管理自己的 nft 表，禁止 `flush ruleset` 伤及其它服务。

### 3.6 修改影响与验收门槛

真正修复需覆盖：公共内核配置 → 五个 release/module 树 → 七个 rootfs →
gadget 脚本/unit → NM/native 管理策略 → 离线断言 → 实机网络验收 → 分发仓清单。
模块与 boot 必须成对重新交付，不把旧产物当作新配置生效的证据。

最低验收应包括：所有新镜像 nft 可执行、对应模块存在、共享配置权限正确；
故意删依赖的负向测试会失败；start/stop/restart/半装配恢复；冷启动/拔插；
USB 客户端实际经棒子访问上游 TCP/DNS并核对 NAT 计数；上游 WiFi 断开/重连后恢复。
主机测试流量必须用独立路由/命名空间约束，防止其实从主机自己的 WiFi 出网。

## 四、MPEG-4：排除了几种误判，但断言根因还没闭环

### 4.1 素材并不是空文件或明显超出能力

宿主离线 `ffprobe`：640×480、Simple Profile、level=1、YUV420P、无 B 帧，
extradata 47 字节；此前已数出45帧。尺寸也是32对齐。

因此不能把失败解释成“不对齐的720p”或复杂 Advanced Simple/B帧。
这**不证明该码流绝对规范**，也不证明所有 MPEG-4 输入都会失败。

### 4.2 实际错误传播

FFmpeg n7.1.5：

1. `libavcodec/v4l2_m2m_dec.c:39–96` 先 OUTPUT STREAMON，再 G_FMT，初始化 CAPTURE。
2. `v4l2_context.c:724–750` 做 REQBUFS，再逐个初始化缓冲。
3. `v4l2_buffers.c:494–557` 包含 QUERYBUF、mmap、QBUF。
   mmap 失败在这里改报 ENOMEM；当前日志 buffer[0] 的 **EIO** 更应关注 ioctl 路径。
4. `v4l2_m2m_dec.c:88–92` 把 CAPTURE 初始化的任意错误统一变成 ENOMEM，
   于是后面出现 `Cannot allocate memory`，不能当作真实分配失败证明。

内核 `vdec.c:1590–1625` 收到 session error 后设置 vb2 queue error；
`videobuf2-core.c` 的后续准备/入队因此可返回 EIO。这与捕获端错误相符，
但**没有本次 ioctl/固件日志时间线，不能认定是哪个调用首先触发断言**。
`hfi_venus.c:1049–1075` 只是打印固件 SFR，`vbuffer.c:1200` 是固件内部路径，
不是主线树里可以直接修第1200行的 C 文件。

### 4.3 尚未排除的三类原因

| 假设 | 现有证据 | 下一步所需证据 |
|---|---|---|
| 码流特征触发老固件问题 | 同一有效素材在两内核复现 | 另一份独立 Simple Profile 素材、其它客户端对照 |
| HFI1xx 缓冲/状态协商错误 | fatal 在初始化阶段；vdec 使用固件 bufreq/count | 记录 G_FMT/REQBUFS/QBUF 的尺寸、实际数量及 HFI seq-change/bufreq |
| FFmpeg 客户端时序与本地兼容补丁交互 | 0005 改 vdec 的 G_FMT 等待；两版可能共享客户端与本地行为 | 事件驱动 V4L2 客户端 vs FFmpeg，以及 pristine/local vdec 行为对照 |

“7.1也失败”只能说明**不是7.2独有**，不能替相同 FFmpeg/固件/本地补丁排除责任。
解码默认 OUTPUT=16、CAPTURE=20；驱动还会根据 firmware minimum 增加数量。
缩小数量的试验必须看 ioctl 实际返回值和全部缓冲大小；CmaFree 低既不能证明根因，
也不能单独证明无资源问题。

建议先做一次带恢复计划的、详细追踪的最小复现；本轮不再反复触发 fatal，
不扩大 CMA，不换猜测的固件，更不 rmmod。已有素材的 MPEG-4 硬解暂记不可用，
业务应选择软件解码；若规范完整客户端也失败，再讨论有界拒绝/降级而非虚假广告支持。

## 五、温控与推流：CPU 搬运路径才是首要优化对象之一

### 5.1 热保护不是失效，而是本地策略比测试门槛更晚

- 上游 `arch/arm64/boot/dts/qcom/msm8916.dtsi:2644–2676` CPU passive 为 **75°C**。
- 本地 `source/dts/common/msm8916-handsome-openstick-common.dtsi:120–126`
  把两组 CPU trip 都改成 **85°C**；所有五变体共享。
- 设备 sysfs：CPU cooling `cpufreq-cpu0` 有7状态；GPU passive仍为75°C，
  critical95°C；CPU critical110°C。本轮未测试这些临界温度，**不把 critical
  当可接受的日常运行温度**。
- 之前的80°C测试保护当然会先于CPU85°C被动冷却触发；因此不能声称“自动热节流没用”，
  也不能凭DTS注释声称持续负载已经受控。

候选方案是恢复较保守的被动阈值、验证 cooling state 实际变化，并定义持续功耗/帧率
合同。仅永久限800MHz可能减少发热，却不保证桌面推流帧率；改善散热也不能替代软件降本。
没有功率计数据，本轮不做“耗电几瓦”或芯片电压归因。

### 5.2 纯软件隔离实验

避免测试源生成的额外开销：先在设备 `/tmp` 放一帧3,768,320字节BGRA，
rawvideo循环读同一帧，输出null。每组90帧，CPU临时限800MHz，75°C保护；
**无GPU合成、无Venus、无网络发送**。日志 `out/research-20261010/conversion-bench.txt`。

| 路径 | 实际耗时 | 帧/秒 | 用户+系统CPU秒 | 峰值RSS KiB |
|---|---:|---:|---:|---:|
| BGRA passthrough对照 | 1.035s | 86.96 | 1.091 | 58,064 |
| BGRA→NV12，1过滤线程，默认SIMD | 7.597s | 11.85 | 8.871 | 102,220 |
| BGRA→NV12，4过滤线程，默认SIMD | 3.026s | 29.74 | 9.645 | 103,636 |
| BGRA→NV12，1线程，`-cpuflags 0` | 12.127s | 7.42 | 13.331 | 105,904 |

四线程组换算30fps约需3.215 CPU秒/秒，**这是整个隔离进程的成本，不是精确的
swscale函数profile**，其中包括tmpfs读入及FFmpeg调度。对照组也有显著系统时间。

对应 `FFmpeg-n7.1.5/libswscale/aarch64/swscale.c:241–300` 已有BGRA输入的NEON
转换函数选择，不能笼统诊断成“没开NEON”。`cpuflags 0`对照关闭的不止某一个转换函数。
峰值RSS含全部映射、库与队列，不能将其全部归为转换私有堆。
本轮最高观察温度约43°C，结束后恢复最大1209600kHz。

### 5.3 链路的数据量和缓冲

当前链路：sway→wf-recorder原始BGRA→FIFO→FFmpeg软件转NV12→Venus→UDP。
1280×736@30：

- BGRA：每帧3,768,320字节，FIFO有效载荷 **113.05 MB/s**。
- NV12：每帧1,413,120字节，**42.39 MB/s**。
- 这些是数据量，不是测得的DRAM总带宽；GPU readback、pipe copy、输入缓冲与
  Venus再拷贝会增加流量，不能把113MB/s当整个链路唯一一次搬运。
- FFmpeg编码默认16个原始INPUT缓冲；按内核 `helpers.c:get_framesize_raw_nv12()`
  的大小，这部分请求体积约 **21.56MiB**，4个为5.39MiB，差16.17MiB。
  `venc.c:1181–1183` 仍按固件需求提高最低数量；**实际数量未测，节省尚未兑现**。
  这不是“16缓冲都必然占CMA”的证明，不能把映射、RSS、PSS、CMA混加。

### 5.4 优化方案的先后与局限

1. **先量化分段与减搬运，不先增加线程。** 对比wf-recorder输出NV12 rawvideo到FIFO，
   仍由FFmpeg硬编/插周期IDR/SPS-PPS；wf-recorder0.5支持 `-x` 格式选择并有格式过滤图。
   这可把FIFO载荷减62.5%，但颜色转换仍存在，只是移到采集端；性能、色彩范围与缓冲
   要重测，不能称“零拷贝”。
2. **有限降低缓冲并限制队列。** 实测驱动返回数量、PSS和SwapPss，再评估4–8个INPUT
   是否可用；验证抖动、重连和长稳，不能只看RSS下降。
3. **谨慎评估单进程采集→硬编。** wf-recorder源码 `frame-writer.cpp:737` 把帧
   `pict_type`设为NONE，未见本工程所需的周期FORCE_KEY_FRAME与dump_extra链路。
   直接 `-c h264_v4l2m2m`不能承诺中途加入，必须保留或重建这部分能力。
4. **再评估专用转换或GPU多平面转换。** GPU不能直接分配NV12不等于所有GPU辅助
   转换在原理上都不可能，但多次pass/读回/同步成本需要新实现与实测；不把“shader”
   当现成零成本方案。当前已有NEON，不应未经benchmark就换库或手写SIMD。
5. **并行完善生命周期。** 推流脚本的守护/资源所有权薄弱：自定义R时仍有硬编码
   `/tmp/stream/p.yuv`清扫，部分启动失败没有统一清理，按UDP端口扫进程也过宽。
   降本前后都需有界资源回收，不能靠杀所有同端口进程维持稳定。

## 六、建议推进顺序（待进入实施阶段）

1. **USB完整修复为第一阶段**：确定规则所有权与固定网关合同，公共配置+gadget状态机+
   NM/native配套+断言一起落地；重建五内核与七镜像，实机验收真正NAT。
2. **温控与推流为第二阶段**：先确定允许持续温度/帧率，恢复保守热策略并做分段对照，
   选择可量化的减搬运方案；实现后再做持续测试，不复用此前短链路PASS。
3. **MPEG-4单独诊断**：先补时间线和客户端对照，再决定补丁或软件回退。
   没有固件断言证据前，不把加CMA/延时/去掉格式当根因修复。

本轮的确定性集中在USB和温控策略，MPEG-4保留未闭环项。没有为了让清单变绿而
更改实现，也没有将候选方案记成实测成功。
