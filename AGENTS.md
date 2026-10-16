# AGENTS.md — OpenStick 工程作业须知

本文件给在这个仓库里干活的 agent 看，写的是**硬性约束、平台限制、以及我们自己做过的改动**。
这三类东西有个共同点：**违反它们时，失败往往没有明确报错**，而是静默出错、挂死、
或者把一个能用的设备变成砖。所以先读第 1、2 节再动手。

范围：`/opt/helloworld/openstick`（含 `source/`、`boards/`、`tools/`、`artifacts/`）。
分发仓 `ufi00x-mainline/`（本目录下，自带 git）有它自己的 `AGENTS.md`。

工程一句话：为 **MSM8916（高通 410）USB 4G 棒** 构建 Debian 13 arm64 + 自编译
Linux **7.2.9**，机型为 Handsome OpenStick 家族五块板（UFI103s/UFI003、UFI001b、
UFI001c、SP970、UZ801）。

---

## 1. 硬性约束（违反的后果不可恢复）

### 1.1 只能操作 boot 与 rootfs 两个分区

| 分区 | 用途 | 可以动吗 |
|---|---|---|
| `mmcblk0p12` (64M, `boot`) | 内核 + appended DTB | ✅ 动它 |
| `mmcblk0p14` (3.3G, `rootfs`) | 根文件系统 | ✅ 动它 |
| GPT / `aboot` / `modem` / `NV` / 其它 | 引导链、射频校准 | ❌ **绝对不要动** |

GPT 或 aboot 写坏 = 设备进不了任何模式，只能 EDL 全片恢复；NV/modem 写坏 =
射频永久失准，且**不可从别处复制回来**（每台机器的校准值唯一）。

### 1.2 刷机前必须能整片恢复；但目前只有分区级备份

仓库文档要求「先用 Miko 做整片 eMMC 全量备份」，**但这条是个已知缺口**：
Miko 是 Windows GUI 工具（`edl-tools/Miko/miko_service_tool_pro.7z`），
没有脚本化的命令行路径，无法校验、无法复现（详见 `docs/build/TOOLING.md` 的「缺口」一节）。

实际可依赖的是**分区级读回**：`recovery/backups/` 与 `recovery/original/` 里有
p12/p14 的逐字节副本，`out/rollback/` 有升级前的 boot 整分区读回。动手刷之前，
先确认目标分区有对应的读回副本；没有就**先读一份**（`dd if=/dev/mmcblk0p12 ...`）。

> 另：公开的 Firehose loader **不被这些棒子接受**，只有 Miko 自带的 MSM8916
> loader 能用。

### 1.3 这两个驱动的 remove 路径不健壮，别 rmmod

| 操作 | 后果 |
|---|---|
| venus 固件报错后 `rmmod venus` | **挂死内核** |
| render-only 模式下 `rmmod msm` | 空指针崩溃（`msm_drm_uninit` 里 `priv->kms` 为 NULL 时保护不全）；GPU 设备消失、GL 退回 llvmpipe |

两者的恢复方式都只有**重启**。要重载驱动就重启，不要试 remove。

### 1.4 不做寄存器级试探

不使用 `devmem`、不做 Firehose poke、不写入猜测的寄存器值。这个平台已经有
能工作的主线驱动，绕过驱动直接改寄存器只会得到难以复现的挂死。

### 1.5 串口：两端都是 115200，但端口名会变

- **波特率 115200**，两端一致：内核 cmdline 是 `console=ttyMSM0,115200`，设备侧
  `stty -F /dev/ttyMSM0` 也报 115200。实测（主机侧逐档抓包）只有 115200 能解出
  可读内容，57600 / 230400 是乱码、9600 无输出 —— 这个 CH343（USB `1a86:55d3`，
  CDC-ACM 模式）**确实遵守主机设的波特率，没有"适配器时钟偏差"这回事**。
- **若解不出内容**，多半是串口速率被 getty 沿用了：`serial-getty@ttyMSM0` 用
  `--keep-baud`（`115200,57600,38400,9600`），会把端口保持在上次遗留的速率上。
  先在设备上 `stty -F /dev/ttyMSM0 115200` 复位，再按 115200 抓。
- **端口名每次重插都会变**：同一类适配器曾先后以 `ch341-uart`（`/dev/ttyUSB0`）
  与 `cdc_acm`（`/dev/ttyACM0`）绑定，重插后 tty 名与 USB 序列号都会变。
  用之前先跑 `tools/ufi-console.sh id`；不确定时用波特率扫描识别端口。
- `/dev/ttyACM1` 属于**另一台设备（LubanCat）**，任何时候都不要用它。
- **无可靠串口时不要默认 RX 安静**：2026-10-10 旧系统出现串口 overrun 与大量
  SysRq，随后非预期重启（重启原因未最终确认）。本次 RAM 预演临时去掉串口
  console、屏蔽 serial-getty，并设 `kernel.sysrq=0`；具体隔离/恢复状态见
  `docs/validation/VALIDATION-7.2.9.md`。在物理问题排除前不要恢复危险的串口 SysRq。

### 1.6 凭据现状

**仓库里不含任何真实凭据。** 口令、Wi-Fi PSK、设备 IP 一律从本地文件或环境变量取：

| 来源 | 说明 |
|---|---|
| `.local-creds` | 仓库根，**已 gitignore**；本机台架值都写在这里 |
| 环境变量 | 同名校验，优先级最高（`DEV` / `PW` / `SUDO_PW` / `ROOTFS_WIFI_SSID` / `ROOTFS_WIFI_PSK` / `ROOTFS_ROOT_PASSWORD`） |

取值统一走 `tools/lib-creds.sh` 的 `cred` / `cred_opt`；格式模板见
`.local-creds.example`。使用方：`flash.sh`（`DEV`/`PW`）、`tools/ufi-console.sh`
与 `tools/qemu-smoke.sh`（`SUDO_PW`）、`tools/build-matrix.sh`（Wi-Fi 与 root 口令，
转给 `build-rootfs.sh`）。

- **未提交**：Wi-Fi PSK 与设备 root 口令只在构建 rootfs 时经文件传入镜像
  （`$STAGE/root/.root-password`，用完立即删除，不进命令行/日志）。
- 规则：**不要把任何真实口令、PSK、内网地址提交进来**；新增需要凭据的地方，
  用 `tools/lib-creds.sh` 取，不要写默认值。

---

## 2. 平台硬限制（会让命令静默出错）

这一节是踩坑最多的地方。共同特征：出错现象与真实原因距离很远。

### 2.1 Venus 编码器要求宽高都 32 对齐

不满足时固件报 `Err_Fatal - VenusCoreCtrl_AhbVbifErrorIRQ`，ffmpeg **段错误**。

- ✅ 640x480、1280x736、1280x768、**1920x1088**
- ❌ 1280x720（H%32=16）、1920x1080（H%32=24）

所以**「标准」分辨率反而不能用**。720p 要 pad 到 736，1080p 要用 1920x1088。
`tools/venus-transcode.sh` 有显式校验，`tools/verify-layout.sh` 有守护断言。

### 2.2 Venus 忽略 ffmpeg 的 `-g`

驱动只注册 `V4L2_CID_MPEG_VIDEO_H264_I_PERIOD` 与 `..._FORCE_KEY_FRAME`
（`venc_ctrls.c`），**没有 GOP_SIZE**，而 ffmpeg 的 v4l2m2m 封装只设 GOP_SIZE。
实测 180 帧只有 1 个 IDR。

后果：SPS/PPS 只在流开头发一次，**中途加入的播放器永远报
`non-existing PPS 0 referenced`**。修法：

```sh
-force_key_frames "expr:gte(t,n_forced*1)"   # 触发 FORCE_KEY_FRAME
-bsf:v dump_extra=freq=keyframe              # 每个关键帧前重挂 SPS/PPS
```

### 2.3 Venus 没有 H.265 / VP9 硬解

Venus 1.8 早于这些格式。V4L2 枚举 H.264/MPEG4/VC1/VP8/H263/XVID 等，
但**枚举不等于可用**：2026-10-10 实测 H.264/VP8 通过，MPEG-2 有微小舍入差异；
MPEG-4 在 7.2.9 与 7.1.13 均触发 `Err_Fatal ... vbuffer.c:1200`，只能重启恢复。
**H.265 只能软解**，1080p H.265 在本机达不到实时。同一 ffmpeg 进程里用
v4l2m2m 同时编+解只出 1 帧，所以**必须软解 + 硬编**。

### 2.4 单个 Venus 编码器 + 32MB CMA 是独占资源

跑两条链会互相抢，帧率掉到个位数（实测 7fps）且现象隐蔽（`CmaFree` 剩几百 KB）。
编排脚本必须在启动前做兜底清扫。

### 2.5 mbs_per_sec 上限是软的

`max_load = 352800` macroblocks/s 定义在 `venus/core.c`（msm8916 res），
判定在 `pm_helpers.c` 的 `load_scale_v1()`、超限时只 `dev_warn`
（`HW is overloaded`），**不拒绝**。实测 1080p60（489600）仍然能编，
只是刷警告且没有实时余量。不要把它当硬墙 —— 曾经把它当硬限制并归咎于一次
"1080p60 挂死"，后来查明真凶是一个 0 帧的坏测试素材（详见 `docs/hardware/VIDEO-CODEC.md`）。

### 2.6 GPU 只能分配 RGB 格式

Adreno 306 支持 XRGB8888/ARGB8888/RGB565/R8/GR88；**NV12/NV21/YUYV/UYVY 全不支持**。
所以「GPU 直接渲染出 NV12 给 venus」做不到，链路里必须有一次 RGB→NV12 转换。

### 2.7 GPU 是 render-only，需要特定的内核配置

本设备**没有显示面板**，GPU 只提供 render 节点。要求：

- 模块参数 `options msm separate_gpu_kms=1`（走 `msm_gpu_probe()`，绕开组件框架）
- **`CONFIG_DRM_MSM_KMS` 必须是 n**。注意 `DRM_MSM_MDP4/MDP5/DPU` 在 Kconfig 里是
  `default y` 且会 `select DRM_MSM_KMS`，所以必须在片段里**显式 =n**
- 用 `source/configs/ufi103s-gpu.config`，构建脚本会断言这两条

验证：`/dev/dri/renderD128` 存在、`uevent` 里 `DRIVER=adreno`、
GL 报 `FD307`（freedreno）。若退回 llvmpipe 说明 GPU 没起来。

### 2.8 rootfs 的 MODULE_TREE 必须用 GPU 树

`msm.ko`/`drm.ko` 只在 `venus-4g-gpu` 板型的模块树里
（`<ver>-ufix0x-venus-4g-gpu-dirty`），纯 venus 板型（`<ver>-ufix0x-venus-dirty`）
里没有。
拿错树构建 rootfs，开机 `modprobe msm` 只报一句
`Module drm not found`，表现为 `/dev/dri` 静默缺失、渲染退回 llvmpipe。
`build-rootfs.sh` 内置了这个错配的告警。

### 2.9 内存与 CPU 规模

- **376 MB 总内存**（4× Cortex-A53），可用约 270 MB；**CMA 只有 32 MB**
  （venus 的缓冲从这里出）
- 开机用 zram 提供 350 MB zstd 压缩 swap（`zram-setup.service`）
- 因此桌面选 i3 而非 LXQt/GNOME；不要引入内存重的组件

### 2.10 xrdp 的两个必需项

- `Xwrapper.config` 必须 `allowed_users=anybody`（xrdp 以非 console 用户起 Xorg）
- 客户端连接**必须用 `/sec:tls`**：FreeRDP 3.x + xrdp 0.10 下 `/sec:rdp` 会报
  `MAC checksum error for non-FIPS PDU`

---

## 3. 工具与环境的坑

### 3.1 `pgrep -x` 对超过 15 字符的进程名零匹配

内核 `comm` 字段截断到 15 字符，所以 `pgrep -x weston-simple-egl` **永远匹配不到**
（`weston-simple-e` 也不一定对）。要按完整命令行匹配就扫 `/proc/*/cmdline`。
这个坑害过一次「进程杀不掉」的排查。

### 3.2 `pkill -f "<pattern>"` 会杀掉**你自己的 shell**

因为 `pkill -f` 匹配完整命令行，而正在执行的那条命令本身（含 pattern 文字）
就在命令行里。本工程里已被这条坑到多次（工具会话被自杀）。
用 PID 列表精确 kill，或扫 `/proc` 按 cmdline 挑，别用 `pkill -f`。

### 3.3 venus / CMA 的释放是异步的

刚 `stop` 完就重启编码链，可能拿不到设备。停链后要等驱动真正回收
（脚本里的做法是轮询确认进程消失后再多等一拍）。

### 3.4 宿主机 `/tmp` 是 11 GB tmpfs

在本机 build rootfs 时，mmdebstrap 的临时目录若落在 `/tmp`，装桌面包阶段会
`No space left on device` 而失败（报错在 dpkg 解包，看不出是 tmpfs 小）。
把 `TMPDIR` 指到大盘上的目录。

### 3.5 `MMDEBSTRAP_FORMAT` 默认是 `directory`

不显式设 `ext4` 就只产出目录树，**没有可刷的 `.ext4` 镜像**。

### 3.6 构建 rootfs 必须传 WiFi 凭据

`ROOTFS_WIFI_SSID` / `ROOTFS_WIFI_PSK` 不传，镜像里就没有任何网络配置，
刷到这种**无屏幕的棒子**上会直接失联、只能拆下来重刷。
构建完应核对镜像里的
`/etc/NetworkManager/system-connections/*.nmconnection` 与设备现用配置一致。

### 3.7 中文 locale 会打乱某些 grep

系统默认 `zh_CN.UTF-8`，`apt-cache`/`systemctl` 等输出是中英混排，
按英文关键字 grep 会漏。需要稳定解析时加 `LC_ALL=C`。

### 3.8 wf-recorder 用作采集端时的三个要求

- 必须 `-c rawvideo`：它会把 `rgb0` 直接喂 venus，而 venus 要 `nv12`
- 必须 `-D`（no-damage）持续出帧，否则帧率由合成器更新驱动、不可控
- 必须经 **FIFO** 而不是管道：两个进程互相依赖，一方退出另一方会挂住等写入端

### 3.9 刷机时不要刷错对象

- 刷的是 `artifacts/rootfs/*.ext4`（约 1 GB），**不是** 3.4 GB 的整分区 dump
  （LK 会拒绝：`size too large`）
- 大镜像要 `-S 200M` 分片：LK 的 `max-download-size` 只有 256 MB
- 进 fastboot 的正确写法是 `systemctl reboot --reboot-argument=bootloader`；
  写成位置参数会报 `Too many arguments`

### 3.10 升级内核时用 `fastboot boot` 做内存预演

`fastboot boot <img>` 从内存启动，**不写 boot 分区**。升级/换内核时先这样验证，
通过再正式刷；启动/驱动硬挂死仍可能需要物理断电，不能称为“零风险”。
2026-10-10 无串口预演的 cmdline、兜底重启与回退验证见 `docs/validation/VALIDATION-7.2.9.md`。

### 3.11 宿主 `arch-test` 缺 arm64 探针 → mmdebstrap 直接拒构 rootfs

本机是 AOSC OS，它的 `arch-test`（作为 mmdebstrap 的依赖自动装上）只带 x86 家族
的探针（`/usr/libexec/arch-test/` 里只有 amd64/i386/x32/kfreebsd-*/illumos-amd64），
**不认识 arm64**。后果是 mmdebstrap 的模拟能力检测失败，构建根本不会开始：

```
E: arm64 can neither be executed natively nor via qemu user emulation with binfmt_misc
```

这个报错**具误导性**：binfmt_misc、`qemu-aarch64-static` 其实都是好的（`arch-test`
一旦能识别 arm64，它自己就会打印 `arm64: ok`）。真正的缺失只是探针文件。

修法（2026-10-07 已在本机做过）：从 Debian 的 `arch-test` 包（`Architecture: all`，
带全架构探针）里取出 arm64 那一个，放到宿主对应位置：

```sh
curl -fsSL -o /tmp/arch-test.deb \
  https://mirrors.cernet.edu.cn/debian/pool/main/a/arch-test/arch-test_0.22-1.1_all.deb
dpkg-deb -x /tmp/arch-test.deb /tmp/arch-test-ext
echo "$SUDO_PW" | sudo -S cp /tmp/arch-test-ext/usr/libexec/arch-test/arm64 /usr/libexec/arch-test/arm64
arch-test arm64      # 期望：arm64: ok
```

只补 arm64 一个即可；AOSC 原有的 x86 探针不要覆盖（它们归属那个包，改了两边
都不一致）。

---

## 4. 我们做过的改动（不是上游行为）

**重要**：这些是本地改动。看代码时不要把 `source/linux-*/` 里的现状当作上游原样，
也不要在别处照抄。判断"某行为是不是上游的"，先看 `source/patches/`。

### 4.1 内核补丁（`source/patches/`，共 4 个）

内核树是**就地打补丁**的：`HEAD` 保持 pristine，改动留在工作区。
（这样 `ufi00x-mainline/tools/check-repo.sh` 才能对着干净树验证补丁可应用性。）

| 补丁 | 作用 |
|---|---|
| `0001` wcn36xx feat-caps 可读 | 通过 debugfs 暴露固件的 feature caps，用于诊断 |
| `0002` wcn36xx MAX_MEDIUM_TIME 6000→20000 | **真正的上行速率修复**：6000 太小导致固件速率自适应卡在 MCS0（约 6 Mbit/s），改后 45–50 Mbit/s |
| `0003` wcn36xx cfg override 诊断 | 允许运行时把 `WCN36XX_HAL_CFG_*` 值推给固件（debugfs），用于在不重编内核的情况下探测参数 |
| `0005` venus HFI 1xx 编码修复 | 8x8 transform 只发给 HFI 4xx/6xx；1xx 强制 in-band headers；对外广告真实的 128x32 对齐；vdec 等 reconf 事件 |

（原 `0004` venus hfi_parser payload size 已随 7.2.9 退场，见下。）

`source/patches/venus-backport-provenance.txt` 记录了 `0004` 的完整沿革：当初
为什么要回移，以及 2026-10-07 为什么退场。退场依据是实测——升到 pristine
7.2.9 后再套会报 `Reversed (or previously applied) patch detected`，且逐函数
对比 pristine 7.2.9 与「7.1.13 + 0004」的结果**逐字节相同**，即上游已含该修复。

**已知缺陷（已修，2026-09-14）**：`0005` 原本还含一份与 `0004` **逐字节重复**的
`hfi_parser.c` 改动，导致按序号套用必然冲突（`patch` 报
`Reversed (or previously applied) patch detected`）。已把该段从 0005 删除、
`hfi_parser.c` 全部归 0004（该补丁随后于 2026-10-07 随 7.2.9 升级一并删除）。
修改补丁序列时仍要遵守这条：**每个文件只有一个归属**。

补丁必须与分发仓 `ufi00x-mainline/patches/` **逐字节一致**
（两边都有校验脚本会比对）。

### 4.2 自写设备树（`boards/*/*/dts/`，共 10 个 + 1 个共享 dtsi）

这些 DTS/dtsi 是我们自己写的，**不在内核树的上游部分**。权威副本在 `boards/`
（**源码侧，只放 DTS**）与 `source/dts/common/` 下；构建时用独立的 `cpp` + `dtc`
就地编译，只把内核树当 include 来源（不往内核树里拷文件，也不改内核 `Makefile`）。
产物 DTB 与 boot 镜像在 `artifacts/`。

- 共享基础：`source/dts/common/msm8916-handsome-openstick-common.dtsi`
- 每板一个基础 DTS；UFI103s 另有 4 个功能变体（`-4g`、`-venus`、`-venus-4g`、
  `-venus-4g-gpu`），合计 5 个功能组合。早期那批频率变体（`oc12`、
  `venus-oc-100`、`venus-oc-burst` 等）已于 2026-09-16 收敛删除——CPU 超频
  全员化进公共 dtsi，不再占名字。
- **每型有专属 `compatible`**：`handsome,ufi103s` / `ufi001b` / `ufi001c` /
  `sp970` / `uz801`（早期五板共用 `handsome,openstick`，只能靠 `model` 区分）。
  新增板子时照这个约定给专属 compatible，不要复用别人的。
- 好消息：**DTS 跨内核版本零漂移**。同一份 DTS 在 6.18 / 7.1 / 7.2 上编译出的
  DTB 逐字节相同（7.2.9 上与 7.1.13 对比验证过），所以升级内核时 DTS 不用改。

### 4.3 rootfs 定制（`build-rootfs.sh`）

镜像不是纯 Debian，做了以下改造（改 rootfs 行为前先确认没和这些冲突）：

- **默认简体中文**：`zh_CN.UTF-8` 生成并设为默认 locale（`locale-gen` 必须真跑，
  只改 `locale.gen` 不够）；装了 `network-manager-l10n`（NM 汉化）、
  `man-db` + `manpages-zh`
- **网络用 NetworkManager**，并且**移除** `systemd-networkd` 与
  `wpa_supplicant@wlan0`（含 networkd 的 socket 启用项）—— 留着会抢 wlan0，
  开机后 NM 反复报 `couldn't grab this interface` 最终放弃。
  注意**不要删全局 `wpa_supplicant.service`**，那是 NM 的 D-Bus 后端。
- NM 连接文件（keyfile）必须 `600`，否则 NM 静默忽略
- fstab 带 `x-systemd.growfs`：镜像约 1 GB 而 p14 有 3.3 GB，开机自动撑满
  （没有它会只剩一百多 MB 可用）
- 看门狗：PM8916 PON 看门狗**只接受 1..127 秒**，systemd 默认 10 分钟会武装失败
  导致关机卡死，已通过 `system.conf.d/10-watchdog.conf` 修正
- zram 350 MB zstd swap；`DEBIAN_FRONTEND=noninteractive` 与环境变量固化
- 监管域固定为 upstream 变体 `regulatory.db`（Debian 签名变体过不了内核内建
  cert 校验，会静默退回 world domain 并忽略 `iw reg set CN`）
- 时区 `Asia/Shanghai`；串口 getty 在 `ttyMSM0`
- 桌面（`ROOTFS_DESKTOP=1`）：xrdp + xorgxrdp + i3 + 中文字体
- LED 脚本与 unit、SSH 允许 root 密码登录

### 4.4 userspace 脚本（`tools/`）

- `ufi-led-state.sh`：五机型通用的状态灯控制（**不需要按型号改**，按 sysfs 名字
  发现，失败按颜色兜底；`fix` 里的 trap 必须 `exit 0` 否则 stop 会挂到超时）
- `desktop/ufi-stream-push.sh` / `-clock.sh` / `-play.sh`：GPU 推流链路
  （见 `docs/hardware/GPU-STREAMING.md`）
- `ufi-console.sh`：有界串口访问
- **USB 共享修复（2026-10-10）**：公共配置补齐 nft CT/reject；两栈均携带
  nftables，NM明确接管usb0；gadget按UDC内容判断状态、检查失败并回滚。
  NM/native的DHCP/DNS/真实NAT及gadget半装配恢复已实机通过，见
  `docs/validation/USB-FIX-7.2.9.md`。`verify-usb-sharing.py`检查五内核/七镜像，
  `verify-layout.sh`已接入；新rootfs仍未整机刷入验收，不可外推蜂窝/Windows支持。
- `flash.sh`（仓库根）：刷机，`fastboot-flash` 会比对 build.json 的 sha256 再写。
  （`tools/flash.sh` 是重组时复制进来的旧子集、引用已失效的路径，2026-09-14 已从
  仓库删除，其历史归档随后于 2026-10-07 一并清理。）

---

## 5. 构建与验证

### 5.1 版本是单一事实来源

`source/kernel-version.env` 是**唯一**写内核版本的地方，配套
`tools/kver.sh`（shell）与 `tools/kver.py`（Python）。所有脚本从它派生路径与
release 字符串。**升级内核只改这个文件**，脚本不要硬编码版本号。

**内核命名 = 设备令牌 + 板型（DTS 后缀）**。设备令牌写在
`KERNEL_LOCALVERSION`（当前 `-ufix0x`）。每个板型独立 release 与模块树，如
`7.2.9-ufix0x-dirty`、`7.2.9-ufix0x-4g-dirty`、`7.2.9-ufix0x-venus-4g-gpu-dirty`。
板型级构建用 `tools/build-board-set.sh`（5 个功能组合，表驱动）。旧名沿革：
`-ufi003`（PCB 号）→ `-ufi103s`（单板名，2026-09-30 弃用）→ `-ufix0x`。
**重刷时内核与模块树必须成对**，只刷 boot.img 会让模块全部静默失配。MF32 用 `-mf32`。
7.1.13 / 6.18.49 时代的模块树（`-ufi103s-*`、`-ufi003-*`）已于 2026-10-07 清理；
vermagic 本就不通用，回退只能靠 `recovery/` 与 `out/rollback/` 的分区读回。

做验证性构建而不必编辑版本文件时，用环境变量临时覆盖（例如换 release 名
重编一棵树做对比）：

```sh
KERNEL_LOCALVERSION=-test bash tools/build-board-set.sh baseline
```

但注意：**旧内核树本身已经在 2026-10-07 清退**（只剩 7.2.9 一棵），所以现在
这条路只在同一棵树上换其它变量才有效（比如 `KERNEL_LOCALVERSION` 建一次
验证性构建）。要回到旧内核跑，只能用 `recovery/` 或 `out/rollback/` 里的分区读回。

产物名与构建目录都带版本号 —— **这是必须保持的**：早先不带版本号时，换版本重编
会覆盖掉旧版本的 `Image.gz`，而 boot 镜像不在 git 里（`.gitignore` 排除 `*.img`），
覆盖后旧镜像再也拼不回来（真的发生过一次）。

### 5.1b 内核镜像**不是**逐位可复现的（模块是）

重编同一个变体会得到**不同的 sha256**，这不是出错。实测（2026-09-14，同源同配置
重编）解压后 21374984 字节里只有 **47 字节**不同：

| 差异 | 字节数 | 性质 |
|---|---|---|
| 内嵌版本串（`#N SMP PREEMPT <日期时间>`） | 12 | 构建序号与时间戳 |
| `GNU` build-id 注记 | 20 | 每次链接都变 |
| 地址表条目 | 15 | 随 build-id 变化微移 |

代码段与数据段**完全一致**；**模块（.ko）是逐字节可复现的**（697 个逐个哈希相同）。

实践含义：
- 别用内核镜像哈希判断"是否重建成功"——比对解压后的内容，或看
  `dmesg | grep 'Linux version'` 里的版本串（`#N` 与时间戳会变）。
- `build.json` 里的 `boot_sha256` 是"这一份文件"的指纹，重编就会变
  （打包脚本会同步更新，所以它始终自洽，可放心用于刷前校验）。
- 要逐位复现需固定 `KBUILD_BUILD_TIMESTAMP`/`KBUILD_BUILD_VERSION` 与确定的
  `--build-id` 选项；目前没做，也没必要。
- 需要确认"设备上跑的是哪一份"时，比 `out/rollback/` 下的 p12 读回副本。

### 5.1c 产物位置（硬约定）

**所有构建产物只放 `artifacts/`**，不要再散落到 `boards/`、`shared/` 或别处。
2026-10-11 之前产物分在 `shared/{rootfs,modules,firmware}` 与
`boards/<家族>/<机型>/boot/` 两处，已全部收进 `artifacts/`。

脚本**不要自己拼 `artifacts/...` 字面路径**，一律用 `tools/kver.sh`（shell）
或 `tools/kver.py`（Python）派生的 `ARTIFACTS_*` / `MODULES_DIR*` / `ROOTFS_BASE`
/ `FIRMWARE_DIR` —— 它们都从 `source/kernel-version.env` 算出。
新增产物类别时，先在 `tools/kver.sh` 与 `tools/kver.py` 两处同步加变量，
再改脚本。

结构、入库规则（哪些产物入库、哪些被 .gitignore 排除）与用途见
`artifacts/README.md`。

## 5.2 常用命令

```sh
# 当前版本（先看一眼，命令里的 <ver> 就是它）
. source/kernel-version.env && echo "$KERNEL_VERSION"

# 五个板型的内核 + 模块树 + boot 镜像（表驱动，缺省只建未完成的）
bash tools/build-board-set.sh
bash tools/build-board-set.sh venus-4g-gpu      # 单个板型

# 单独重编某个变体（少用；build-board-set.sh 已含这一步）
# ⚠️ 重编会覆盖 artifacts/boot/ 下对应的 boot 镜像与 build.json。内核镜像
# 不是逐位可复现的（§5.1b），所以覆盖后哈希会变，已实机验证过的那一份
# 就再也拼不回来——动手前先备份，或从分发仓取回已验证的副本。
# 追加 source/configs/kernel-size.config 可得体积极限版（-8.4% Image.gz，
# 2026-09-15 实测；代价：oops 无符号名 + 必须用同配置重编的模块树，
# KALLSYMS=n 会改 struct module 布局，旧模块全部拒载）。
bash tools/build-kernel-variant.sh venus source/configs/ufi103s-venus.config \
     "$PWD/artifacts/modules/<ver>-ufix0x-venus-dirty"

# 全矩阵 rootfs（7 个：max/basic/slim/micro × nm|native；注意 §3.4/3.5/3.6 三个坑）
# 凭据从 .local-creds 或环境变量取，脚本无内置默认值（见 §1.6）。
bash tools/build-matrix.sh
bash tools/build-matrix.sh max                  # 单个档位

# QEMU 冒烟（不碰真机，改档位/砍包后必做）
bash tools/smoke-all.sh

# 布局与产物自检（应 exit 0；默认校验 max 档镜像，可用 ROOTFS_IMAGE 换档）
bash tools/verify-layout.sh
ROOTFS_IMAGE=artifacts/rootfs/ufi103s-<ver>-slim.ext4 bash tools/verify-layout.sh

# 分发仓自检（传当前内核树）
cd ufi00x-mainline
K=$(cd .. && . source/kernel-version.env && echo "$PWD/source/linux-$KERNEL_VERSION")
sh tools/check-repo.sh "$K"
```

### 5.3 改动的验收标准

- 脚本：`bash -n` 全过
- 补丁：在 pristine 树上能按序干净套用（无 fuzz、无 reject）
- DTS：所有变体零错误编译
- 内核/rootfs：`tools/verify-layout.sh` exit 0
- 设备相关改动：**实机验证**，不要只靠编译通过就宣称可用

### 5.4 改动完成后的提交

两个仓库都要提交且保持一致（补丁、版本相关）。仅本地提交，不推远端。

---

## 6. 关键事实速查

| 项 | 值 |
|---|---|
| 内核 | `7.2.9-ufix0x-venus-4g-gpu-dirty`（GPU / max 档）／`7.2.9-ufix0x-dirty`（基线） |
| rootfs PARTUUID | `a7ab80e8-e9d1-e8cd-f157-93f69b1d141e`（cmdline 必须匹配） |
| 串口 | `/dev/ttyACM0` @ **115200**（CH343，CDC-ACM）；端口名会变，用前 `tools/ufi-console.sh id` 确认 |
| 设备 root 口令 | 见 `.local-creds`（`ROOTFS_ROOT_PASSWORD`）；脚本无内置默认值 |
| 宿主机 sudo 口令 | 见 `.local-creds`（`SUDO_PW`） |
| 设备地址 | DHCP，会变；用前 `ping` 确认，地址写在 `.local-creds` 的 `DEV` |
| CPU | 4× Cortex-A53；当前 7.2.9 DTS 档位 200/400/800/998.4/1094.4/1152/1209.6 MHz |
| 内存 / CMA | 376 MB / 32 MB |
| boot 镜像布局 | Android legacy header v0、page 2048、base 0x80000000、appended DTB |
| 网卡 | wlan0（WCN3620 或 WCN3660B）、wwan0-7（4G）、蓝牙 |
| 设备树 | model 写明具体型号；`compatible` 每型专属 |

**CPU 频率的实测结论**：旧运行镜像曾有 1401.6 MHz 档且无增益；当前源码/7.2.9
最高 1209.6 MHz，别把旧镜像 OPP 表套过来。**降压不可行**（电压由 PSCI 固件掌控）。
2026-10-10 当前散热条件下，四核满频 + 96MiB 校验约 27 秒到 80°C，被测试保护
中止；限 800MHz 后完成 60s CPU / 90s 内存测试，峰值 75°C。持续 GPU 推流也触发
80°C 保护，未完成长稳；不要宣称默认频率可无限持续满载。

2026-10-16 复测（无串口、RAM 启动 7.2.9）：四核纯忙循环 45 秒峰值 **86°C**，
schedutil 降频 1209→1094MHz，设备未中止；GPU 推流持续 **160 秒**峰值 **84°C**
（约 110 秒到 80°C，起始温度 45°C 故比 10-10 的 82 秒更久）。
**散热仍是限制项，长稳与满载不可宣称通过。**

---

## 7. 文档地图

| 文档 | 内容 |
|---|---|
| `README.md` | 工作区结构与整体状态 |
| `AGENTS.md`（本文件） | 约束、平台限制、我们做过的改动 |
| `docs/CHANGES.md` | **改动清单**：相对上游 Linux/Debian 改了什么（交付层 diff） |
| `docs/ISSUES.md` | **问题清单**：已定案的踩坑（现象/根因/修法/证据）+ 尚未闭环的问题 |
| `docs/build/BUILD-MATRIX.md` | 设备 × 档位 × 网络栈矩阵与实施顺序 |
| `docs/build/TRIMMING.md` | 精简档位与体积；**QEMU 冒烟测试流程**（改档位/砍包后必做） |
| `docs/build/TOOLING.md` | 工具清单与**已知缺口** |
| `docs/hardware/FASTBOOT.md` | fastboot 刷机全流程（含实测数据与两个坑） |
| `docs/hardware/NETWORK.md` | NetworkManager 迁移与中文化 |
| `docs/hardware/DESKTOP.md` | i3 桌面 / xrdp / Adreno GPU 渲染 |
| `docs/hardware/GPU-STREAMING.md` | GPU 合成 → Venus 硬编 → 推流（含关键坑） |
| `docs/hardware/VIDEO-CODEC.md` | 编解码实测数据（含 7.2.9 注记） |
| `docs/hardware/CPU-POWER.md` | CPU 频率/电压/散热；降压为何不可行 |
| `docs/hardware/LED.md` | LED 跨型号适配 |
| `docs/hardware/BLUETOOTH.md` | 蓝牙（含“BT 固件不用单独提供”这个易误判点） |
| `docs/validation/VALIDATION-7.2.9.md` | 2026-10-10 无串口实机验收：修复前通过/失败项、回退与现场状态 |
| `docs/validation/VALIDATION-2026-10-16.md` | **最新一轮** 7.2.9 实机验收：USB 全链、编解码、推流与散热数据 |
| `docs/validation/USB-FIX-7.2.9.md` | USB 全链修复：NM/native 真实 NAT、gadget 生命周期、交付断言与保留风险 |
| `boards/<家族>/<机型>/README.md` | 该板产物清单、实机状态、升级/回退流程 |
| `artifacts/README.md` | **产物唯一存放位置**的结构、入库规则与路径派生约定 |
