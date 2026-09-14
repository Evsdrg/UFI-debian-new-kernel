# AGENTS.md — OpenStick 工程作业须知

本文件给在这个仓库里干活的 agent 看，写的是**硬性约束、平台限制、以及我们自己做过的改动**。
这三类东西有个共同点：**违反它们时，失败往往没有明确报错**，而是静默出错、挂死、
或者把一个能用的设备变成砖。所以先读第 1、2 节再动手。

范围：`/opt/helloworld/openstick`（含 `source/`、`boards/`、`tools/`、`shared/`）。
分发仓 `/opt/helloworld/ufi00x-mainline/` 有它自己的 `AGENTS.md`。

工程一句话：为 **MSM8916（高通 410）USB 4G 棒** 构建 Debian 13 arm64 + 自编译
Linux **7.1.13**，机型为 Handsome OpenStick 家族五块板（UFI103s/UFI003、UFI001b、
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
没有脚本化的命令行路径，无法校验、无法复现（详见 `TOOLING.md` 的「缺口」一节）。

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

### 1.5 串口：一个特定的适配器，且端口名会变

- 台架上的 **CH343 USB 适配器**枚举为 cdc_acm，**需要 57600 波特率** ——
  按内核 cmdline 里的 115200 设会出乱码（适配器时钟问题，不是内核问题）。
  内核侧确实是 `console=ttyMSM0,115200`，两者不矛盾。
- **端口名每次重插都会变**（`/dev/ttyACM0` ↔ `/dev/ttyUSB0` 都出现过）。
  用之前先跑 `tools/ufi-console.sh id` 重新确认，不要写死。
- `/dev/ttyACM1` 属于**另一台设备（LubanCat）**，任何时候都不要用它。

### 1.6 凭据

本仓库已提交台架凭据（root 密码 `REDACTED`、主 sudo 密码 `REDACTED`、
台架 WiFi SSID/PSK）。这些是本地测试设备的，不是需要保守的机密；
但**不要把新的私有凭据提交进来**。

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

Venus 1.8 早于这些格式。硬解只有 H.264/MPEG4/VC1/VP8/H263/XVID 等；
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
"1080p60 挂死"，后来查明真凶是一个 0 帧的坏测试素材（详见 `VIDEO-CODEC.md`）。

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

`msm.ko`/`drm.ko` 只在 `-ufi003-gpu` 模块树里，`-ufi003-venus` 树里没有。
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

- 刷的是 `shared/rootfs/*.ext4`（约 1 GB），**不是** 3.4 GB 的整分区 dump
  （LK 会拒绝：`size too large`）
- 大镜像要 `-S 200M` 分片：LK 的 `max-download-size` 只有 256 MB
- 进 fastboot 的正确写法是 `systemctl reboot --reboot-argument=bootloader`；
  写成位置参数会报 `Too many arguments`

### 3.10 升级内核时用 `fastboot boot` 做零风险预演

`fastboot boot <img>` 从内存启动，**完全不写 flash**。升级/换内核时先这样验证，
通过再正式刷。这是本工程验证过的最安全的升级路径（见
`boards/ufi00x/ufi103s-ufi003/README.md` 的升级流程）。

---

## 4. 我们做过的改动（不是上游行为）

**重要**：这些是本地改动。看代码时不要把 `source/linux-*/` 里的现状当作上游原样，
也不要在别处照抄。判断"某行为是不是上游的"，先看 `source/patches/`。

### 4.1 内核补丁（`source/patches/`，共 5 个）

内核树是**就地打补丁**的：`HEAD` 保持 pristine，改动留在工作区。
（这样 `ufi00x-mainline/tools/check-repo.sh` 才能对着干净树验证补丁可应用性。）

| 补丁 | 作用 |
|---|---|
| `0001` wcn36xx feat-caps 可读 | 通过 debugfs 暴露固件的 feature caps，用于诊断 |
| `0002` wcn36xx MAX_MEDIUM_TIME 6000→20000 | **真正的上行速率修复**：6000 太小导致固件速率自适应卡在 MCS0（约 6 Mbit/s），改后 45–50 Mbit/s |
| `0003` wcn36xx cfg override 诊断 | 允许运行时把 `WCN36XX_HAL_CFG_*` 值推给固件（debugfs），用于在不重编内核的情况下探测参数 |
| `0004` venus hfi_parser payload size | 从上游 v7.3 回移（本树 7.1.13 仍有此 bug）；修 `parse_caps`/`parse_alloc_mode`/`parse_raw_formats` 的返回长度 |
| `0005` venus HFI 1xx 编码修复 | 8x8 transform 只发给 HFI 4xx/6xx；1xx 强制 in-band headers；对外广告真实的 128x32 对齐；vdec 等 reconf 事件 |

`source/patches/venus-backport-provenance.txt` 记录了 0004 的上游 commit 与
适用版本的推导。

**已知缺陷（已修，2026-09-14）**：`0005` 原本还含一份与 `0004` **逐字节重复**的
`hfi_parser.c` 改动，导致按序号套用必然冲突（`patch` 报
`Reversed (or previously applied) patch detected`）。已把该段从 0005 删除、
`hfi_parser.c` 全部归 0004。修改补丁序列时注意保持"每个文件只有一个归属"。

补丁必须与分发仓 `/opt/helloworld/ufi00x-mainline/patches/` **逐字节一致**
（两边都有校验脚本会比对）。

### 4.2 自写设备树（`boards/*/*/dts/`，共 12 个文件）

这些 DTS/dtsi 是我们自己写的，**不在内核树的上游部分**（在 `source/linux-*/
` 里是未跟踪文件）。权威副本在 `boards/` 下，构建时复制/包含进内核树。

- 共享基础：`msm8916-handsome-openstick-common.dtsi`
- 每板一个基础 DTS + UFI103s 的多个频率/功能变体（oc12、venus、venus-oc12、
  venus-oc-100、venus-oc-burst、venus-oc-100-gpu）
- **每型有专属 `compatible`**：`handsome,ufi103s` / `ufi001b` / `ufi001c` /
  `sp970` / `uz801`（早期五板共用 `handsome,openstick`，只能靠 `model` 区分）。
  新增板子时照这个约定给专属 compatible，不要复用别人的。
- 好消息：**DTS 跨内核版本零漂移**。同一份 DTS 在 6.18 与 7.1 上编译出的 DTB
  逐字节相同，所以升级内核时 DTS 不用改。

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
  （见 `GPU-STREAMING.md`）
- `ufi-console.sh`：有界串口访问
- `flash.sh` / `tools/flash.sh`：刷机（`fastboot-flash` 会比对 build.json 的 sha256）

---

## 5. 构建与验证

### 5.1 版本是单一事实来源

`source/kernel-version.env` 是**唯一**写内核版本的地方，配套
`tools/kver.sh`（shell）与 `tools/kver.py`（Python）。所有脚本从它派生路径与
release 字符串。**升级内核只改这个文件**，脚本不要硬编码版本号。

重建旧版本（回退验证）用环境变量覆盖：

```sh
KERNEL_VERSION=6.18.49 bash tools/build-gpu-variant.sh
```

产物名与构建目录都带版本号 —— **这是必须保持的**：早先不带版本号时，换版本重编
会覆盖掉旧版本的 `Image.gz`，而 boot 镜像不在 git 里（`.gitignore` 排除 `*.img`），
覆盖后旧镜像再也拼不回来（真的发生过一次）。

### 5.2 常用命令

```sh
# 当前版本（先看一眼，命令里的 <ver> 就是它）
. source/kernel-version.env && echo "$KERNEL_VERSION"

# 构建内核变体（venus / gpu / 基线）
bash tools/build-kernel-variant.sh venus source/configs/ufi103s-venus.config \
     "$PWD/shared/modules/<ver>-ufi003-venus"
bash tools/build-gpu-variant.sh          # 含 boot 打包
bash tools/build-boot-images.sh          # 基线 boot 镜像

# rootfs（注意 §3.4/3.5/3.6 的三个坑）
MMDEBSTRAP_FORMAT=ext4 TMPDIR="$PWD/out/tmp" \
KERNEL_RELEASE="<ver>-ufi003-venus-dirty" \
MODULE_TREE="$PWD/shared/modules/<ver>-ufi003-gpu" \
EXTRA_MODULE_TREES="$PWD/shared/modules/<ver>-ufi003-dirty" \
EXTRA_FIRMWARE_DIR="$PWD/shared/firmware/ufi103s-venus" \
ROOTFS_PATH="$PWD/shared/rootfs/debian13-arm64-ufi103s-<ver>-venus.ext4" \
EXTRA_PKGS="ffmpeg,v4l-utils" ROOTFS_DESKTOP=1 \
ROOTFS_WIFI_SSID='<ssid>' ROOTFS_WIFI_PSK='<psk>' \
bash build-rootfs.sh

# 布局与产物自检（应 exit 0）
bash tools/verify-layout.sh
ROOTFS_IMAGE=shared/rootfs/<venus 镜像> bash tools/verify-layout.sh

# 分发仓自检（传当前内核树）
cd /opt/helloworld/ufi00x-mainline
K=$(cd /opt/helloworld/openstick && . source/kernel-version.env && echo "$PWD/source/linux-$KERNEL_VERSION")
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
| 内核 | `7.1.13-ufi003-venus-dirty`（venus/GPU 变体）／`7.1.13-ufi003-dirty`（基线） |
| rootfs PARTUUID | `a7ab80e8-e9d1-e8cd-f157-93f69b1d141e`（cmdline 必须匹配） |
| 串口 | `/dev/ttyACM0` @ **57600**（CH343 适配器），端口名会变 |
| 设备 root 密码 | `REDACTED` |
| 宿主机 sudo 密码 | `REDACTED` |
| 设备地址 | DHCP，历史上出现过 `.102`/`.108`，用前先 `ping` |
| CPU | 4× Cortex-A53；档位 200/400/800/998.4/1094.4/1209.6/1401.6 MHz |
| 内存 / CMA | 376 MB / 32 MB |
| boot 镜像布局 | Android legacy header v0、page 2048、base 0x80000000、appended DTB |
| 网卡 | wlan0（WCN3620 或 WCN3660B）、wwan0-7（4G）、蓝牙 |
| 设备树 | model 写明具体型号；`compatible` 每型专属 |

**CPU 频率的实测结论**：约 1209.6 MHz 后无收益（1401.6 MHz 零增益）；
**降压不可行**（电压由 PSCI 固件掌控，无 `opp-microvolt` 可改）。

---

## 7. 文档地图

| 文档 | 内容 |
|---|---|
| `README.md` | 工作区结构与整体状态 |
| `AGENTS.md`（本文件） | 约束、平台限制、我们做过的改动 |
| `TOOLING.md` | 工具清单与**已知缺口** |
| `FASTBOOT.md` | fastboot 刷机全流程（含实测数据与两个坑） |
| `NETWORK.md` | NetworkManager 迁移与中文化 |
| `DESKTOP.md` | i3 桌面 / xrdp / Adreno GPU 渲染 |
| `GPU-STREAMING.md` | GPU 合成 → Venus 硬编 → 推流（含关键坑） |
| `VIDEO-CODEC.md` | 编解码实测数据 |
| `LED.md` | LED 跨型号适配 |
| `boards/<家族>/<机型>/README.md` | 该板产物清单、实机状态、升级/回退流程 |
| `archive/reports/` | 历史专题研究（CPU 频率/电压、EDL、刷机证据等） |
