# 7.2.9 实机验证 — 2026-10-10

> 后续USB修复已完成，见 [USB-FIX-7.2.9.md](USB-FIX-7.2.9.md)。
> 下文保留修复前的原始验收结果，不能把旧boot哈希和失败状态当作最新产物。

## 结论与范围

**主力 UFI103s 的 `venus-4g-gpu` 变体可以运行，但不能宣布全功能验收通过。**
明确阻塞项是 NM USB 共享出网；持续高负载还受散热限制。MPEG-4 硬解有固件错误，
已用同一素材在旧 7.1.13 复现，不能归因为本次内核升级。

- 测试内核：`7.2.9-ufix0x-venus-4g-gpu-dirty`。
- 原始 boot 文件：`artifacts/boot/ufi103s-ufi003/boot-board-venus-4g-gpu-7.2.9.img`。
- 文件 SHA256：`5626c15b172b3c42ebb9425b6370f69343166b036f57610fc38765a896cfa035`。
- **两次通过 `fastboot boot` 内存启动**，临时覆盖 cmdline，未刷 boot/rootfs。
- 使用设备原有 Debian 13 rootfs，新增配套模块目录；**不是新 max.ext4 的整机验收**。
- 其它四个功能变体、七张新 rootfs 的实机矩阵、其它四块板均未测；此前 QEMU 7/7
  仅证明 userspace 启动，不能覆盖本次发现的硬件/防火墙问题。
- 原始证据与测试程序：`out/validation-20261010/`（不入 git，包含局域网信息）。

## 安全与回退

身份用历史 SSH 公钥及设备树 `handsome,ufi103s` 双重确认。
只读回 p12；全部写入都是 rootfs 内普通文件、模块及测试配置，未写其它原始分区，
未触碰 GPT、aboot、modem/NV，未卸载 venus/msm，未操作任何主机串口。

备份目录 `out/rollback/20261010/`：

- `boot-p12-before.bin`：67,108,864 字节；主机副本及设备 p12 多次散列一致：
  `9159529fe351f82f99d06717cb06480176ec611555bae96f56637af4ad8a7d75`。
- `old-modules-and-config.tar.gz`：旧 7.1.13 模块与相关配置，**含 WiFi 私有配置，不可公开**。
  目录权限 700，文件 600。
- 原有 `recovery/backups/` 的 p14 读回保留；本次不刷 rootfs，因此未做在线 p14 全量副本。

旧系统基线期间发生一次非预期重启，前一 boot 日志出现大量串口 SysRq、
`ttyMSM0: 1 input overrun(s)`、`Nice All RT Tasks`、`Emergency Sync`。
**没有捕获到确切重启指令或 panic，因果尚不能定论**，不能把它算成 WiFi/GPU 压测失败。
之后临时设置 `kernel.sysrq=0`；7.2.9 预演用下列 cmdline 隔离串口：

```text
console=tty0 root=PARTUUID=a7ab80e8-e9d1-e8cd-f157-93f69b1d141e rw rootwait panic=10 sysctl.kernel.sysrq=0 systemd.mask=serial-getty@ttyMSM0.service
```

这个覆盖不改变磁盘上的 boot 文件。每次新内核启动前启用 10 分钟用户态兜底重启，
SSH 恢复后撤销；它不保证救回用户态启动前的硬挂死。

中途已**正常重启回 7.1.13**，确认 SSH、旧模块和原 p12 哈希，再次从 RAM 启动 7.2.9。
因此回退不是仅靠推断。**收尾时设备仍运行第二次 RAM 启动的 7.2.9；下次正常重启
或断电仍会启动磁盘上的 7.1.13。** 没有进行正式升级写入。

## 验收清单

| 项目 | 状态 | 实测与限制 |
|---|---|---|
| RAM 启动 / 回退 | ✅ | 7.2.9 两次启动；中途回到 7.1.13，p12 哈希始终未变 |
| 服务 / 内核健康 | ✅ | 收尾 0 failed units，taint=0，未发现 Oops、panic、GPU/IOMMU fault；不代表 dmesg 完全无错误 |
| WiFi TCP | ✅ | 同一台架 7.2.9 上行 49.24、下行 62.76 Mbit/s；旧版 46.31 / 55.64 |
| WiFi 重连 | ✅ | 通过 USB 管理通道执行 3 次断开/重连，均恢复 DHCP 和网关连通 |
| USB RNDIS | ✅ | 高速 USB 枚举；电脑→棒子 164.13、棒子→电脑 148.69 Mbit/s，均 0 retransmits |
| USB DHCP / DNS / SSH | ✅ | 在手工启用 gadget、设置 NM managed 后通过；非开箱即用验证 |
| USB 共享出网 | ❌ | NM 的 nft 规则事务失败，规则集为空；仅 DHCP/DNS 成功不能判为 NAT 成功 |
| GPU EGL / GLES | ✅ | Mesa 25.0.7，freedreno `FD307`，实际 headless 合成及三角形渲染 |
| H.264 硬编硬解 | ✅ | 640×480 30 帧 NV12 逐字节一致；1280×736、1920×1088 各 180 帧 HW/SW 帧哈希一致 |
| H.264 周期关键帧 | ✅ | 后两档各 180 帧中 10 个关键帧；使用 FORCE_KEY_FRAME + dump_extra；不是验证 `-g` 有效 |
| VP8 硬解 | ✅ | 640×480、45 帧，HW/SW 帧哈希全部一致 |
| MPEG-2 硬解 | ⚠️ | 解出 45 帧；HW/SW 非字节一致，但平均 PSNR 70.83 dB、最大分量差 3，符合小量舍入差异特征 |
| MPEG-4 硬解 | ❌ | 640×480、45 帧有效素材触发固件 `vbuffer.c:1200` fatal；7.1.13 同样复现 |
| HEVC 转码 | ✅ | 软件解码 HEVC→Venus 硬编码 H.264，45 帧；没有 HEVC 硬解能力 |
| GPU→Venus→UDP | ✅/⚠️ | 短链路正确；标称 30fps，实际约 25–27fps；持续测试受 80°C 保护中止 |
| 推流中途加入 | ✅ | 发送端启动 30 秒后接收；拿到后续关键帧并解出 573 帧、19.1s 画面，不是从流头接收 |
| xrdp / i3 | ✅ | FreeRDP TLS 实际登录，Xorg :10 与 i3 正常，1024×768 截图留档；测试会话已退出 |
| 蓝牙 | ✅/⚠️ | hci0 正常，扫描 15 秒发现 4 个设备；未配对/传输/测音频 |
| 4G | ⚠️ | 两个 remoteproc running，QMI/AT 与 wwan0–7 正常，MM 识别；`sim-missing`，未测注册/拨号/短信 |
| CPU OPP | ✅ | 200/400/800/998.4/1094.4/1152/1209.6 MHz 逐档设定及 sysfs 回读正常 |
| 满频持续 CPU+内存 | ⚠️ | 约 27 秒从 55°C 升到 80°C，测试主动退出；不是 60 秒满载通过，也不是内核过热关机 |
| 降频 CPU+内存 | ✅ | 临时限 800MHz：四进程 SHA256 60s + 96MiB 内存 90.56s，91 轮正反数据校验 0 错，最高 75°C |
| eMMC / ext4 | ✅ | 普通文件写入 64MiB 随机数据并 fsync，3 次 O_DIRECT 读回 SHA256 相同；不写裸分区 |
| 三色 LED | ✅/⚠️ | 仅 red/green/blue 的 sysfs 亮灭回读通过，恢复状态灯服务；无光学确认，不操作 SIM 选择 GPIO |
| zram | ✅ | 350MiB zstd swap 工作，推流时确有换页；未做逼近 OOM 的测试 |
| NTP / RTC | ✅/⚠️ | chrony 恢复正确时间，RTC 可读但为 1970；无掉电保时保证，不设置 RTC/PMIC |
| 随机数 | ✅/🚫 | Linux CRNG 已初始化，urandom 正常；qcom PRNG 不注册 hwrng，因此 `/dev/hwrng` 不可读不是新增回归 |
| 长时间稳定性 | ⚠️ | 第一轮 7.2.9 连续约 25 分钟后主动恢复固件；第二轮继续验证，非 24h/长期负载验收 |

## 失败项的源码核对

### 1. USB 共享不能开箱出网（发布阻塞）

证据：`usb-gadget-first-start.txt`、`usb-nm-diagnostics.txt`、`nat-investigation.txt`、
`usb-nat-e2e.txt`。缺口分为四层，不能只补其中一层就宣布完成：

1. **内核**：本次 GPU 配置中 `CONFIG_NFT_CT`、`CONFIG_NFT_REJECT`、
   `CONFIG_NF_REJECT_IPV4` 等未启用，`nft_ct`/`nft_reject_ipv4` 无模块。
   NM 生成的 `ct state { established, related }` 和 `reject` 表达式报 ENOENT，
   整套规则事务失败，`nft list ruleset` 为空。
2. **依赖**：旧 rootfs 没有 nftables，本次仅为测试安装了该包（无其它包升级）。
   **新 `artifacts/rootfs/ufi103s-7.2.9-max.ext4` 也没有 `/usr/sbin/nft`**，由 debugfs
   只读检查确认。`build-rootfs.sh:154` 只对 native 分支显式加 nftables。
3. **管理权**：设备 `/usr/lib/udev/rules.d/85-nm-unmanaged.rules:36` 对 gadget
   设置 `NM_UNMANAGED=1`；现有 NM 配置未针对 usb0 覆盖。
   本次手工 `nmcli device set usb0 managed yes` 后才可启动共享连接。
   新镜像包含 usb-share keyfile，但没看到对应的 gadget 管理权修正。
4. **gadget 脚本**：`tools/usb-gadget.sh:74` 写
   `functions/rndis.usb0/os_desc/interface.rndis/b_vendor_code`，该属性不存在，
   实测报 `Permission denied`；脚本继续绑定并返回 0。接口 OS descriptor 的
   vendor code 应与 gadget 级 `os_desc/b_vendor_code` 区分。Windows 兼容性未测。

本轮只定位与留证，**没有手写 NAT 规则绕过失败，也没有修改内核/构建脚本来掩盖验收状态**。
`tools/verify-layout.sh` 仍返回 0，说明现有离线守护不足以覆盖这些要求。

### 2. MPEG-4 枚举支持不等于可用

45 帧素材先由宿主软件解码计数，确认非空；SHA256：
`38e2a79f4c57970e01452b2d54cd6822d85b2dbbf05bf6ac60f9222272065eab`。
7.2.9 与 7.1.13 同样报 capture buffer 初始化 EIO、分配失败及：

```text
QC_IMAGE_VERSION_STRING=VIDEO.VE.1.8-00109
Err_Fatal - Z:\b\venus\utils\src\vbuffer.c:1200:
```

两次都在退出 ffmpeg 后以**重启**恢复，没有 rmmod。
证据：`other-codecs.txt`、`dmesg-7.2.9-before-recovery.txt`、
`old-kernel-mpeg4-control.txt`。VC1/H.263/Xvid 尚未据有效素材验证，不能从格式枚举外推。

MPEG-2 的定量对照：20,736,000 字节中 108,709 字节不同，最大绝对差 3，
平均绝对差 0.005284，平均 PSNR 70.833219 dB。非规范性逐字节相等测试不应直接作为
MPEG-2 IDCT 硬解失败的判据；这里保留差异记录，不声称完全相同。

### 3. 散热与推流内存

- 满频测试在 80°C 主动中止，低于 DTS 85°C 被动冷却点，没有验证内核热节流极限。
- 800MHz 限频只是测试条件，退出后已恢复 `schedutil` / 最大 1209600 kHz。
- 1280×736@30 GPU 推流持续测试，启动约 **82 秒**即达到 80°C，未跑满计划时长。
- 临近保护退出时的瞬时 smaps（不是严格同时采样）：

| 进程 | RSS (KiB) | PSS (KiB) | SwapPss (KiB) |
|---|---:|---:|---:|
| ffmpeg | 96,836 | 93,807 | 15,416 |
| wf-recorder | 74,700 | 42,169 | 10,012 |
| sway | 68,088 | 34,753 | 21,744 |
| weston-simple-egl | 6,136 | 2,780 | 19,768 |

完整证据 `stream-memory.txt`、`stream-soak.txt`。CmaFree 的低值本身不能证明泄漏，
它也受可迁移页使用影响；不能把此次低值和所有历史会话问题统一归因于 CMA。

## 其它观察

- 7.2.9 当前 DTS 的最高 OPP 是 **1209.6MHz**，不是旧运行镜像的 1401.6MHz；
  `source/dts/common/msm8916-handsome-openstick-common.dtsi:107–118` 与实测一致。
  本轮修正文档，不把旧实机与新构建 DTB 当作同一份。
- H.264 的 `number of reference frames (0+2) exceeds max (1)` 警告在旧版与新版均出现；
  本组素材仍通过计数及逐帧一致性校验，警告保留，不写成“0 解码警告”。
- 7.2.9 dmesg 有 USB supplier device-link 错误及 `l13: voltage operation not allowed`；
  实际 USB 双向传输通过，根因未深入，不能写成“0 内核错误”。
- `qcom-rng.c:99–106,132–153` 明确对 `qcom,prng` 不注册 TRNG，只保留绑定；
  两版均有 `TRNG support not detected`，不要通过改 compatible 或寄存器强启 hwrng。
- RDP 第一次凭据管道使用错误导致客户端取消，修正测试调用后实际登录成功；
  这不是 xrdp 服务端功能失败。

## 收尾现场与后续门槛

- 当前可用管理入口：设备 WiFi 地址（DHCP）、USB `10.42.0.1`。
- 7.2.9 保持 RAM 运行，p12 仍是 7.1.13；正式 flash 状态仍为 **not flashed**。
- 新增模块目录保留，旧模块未删除；设备上的 nftables 测试依赖保留（服务未启用）。
- `/etc/sysctl.d/99-ufi-validation.conf` 暂留 `kernel.sysrq=0`，因为串口异常尚未排除。
  串口修复后再删除该临时文件并恢复原值 438，不要现在恢复。
- 兜底重启 unit 已删除；CPU 限频、压力负载、RDP 会话均已清理，状态灯服务恢复。
- USB gadget / managed override 是运行时测试状态，未安装开机 gadget 服务。
  宿主仅留隔离的 `ufi-validation-usb` 连接（不自动连接、不接管默认路由/DNS）；
  全局临时 no-auto-default 配置和 NAT 测试策略路由均已清理。
- 最新健康快照：0 failed units、taint=0、MemAvailable 约 267MiB、温度约 52–56°C。

后续应先修 USB 的内核依赖、NM 包/管理权及 gadget 脚本，再重新构建相关变体与
rootfs、补充离线断言并重测真正 NAT。持续推流/满频场景要先改善散热或明确运行限制。
有 SIM 和可靠串口后，再补蜂窝业务、其它板型/rootfs 矩阵、掉电/长稳等高风险项目。
