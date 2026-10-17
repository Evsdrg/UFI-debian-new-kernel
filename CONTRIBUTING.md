# 贡献须知

本文件写给要在这个仓库里干活的人。这里的绝大多数条目，共同特征是
**违反时不会立刻报错**——而是静默出错、挂死，或者把一个能用的设备变成砖。
动手前请先读完「硬性约束」和「平台硬限制」两节。

工程概述见 [`README.md`](README.md)；相对上游改了什么见
[`docs/CHANGES.md`](docs/CHANGES.md)；已定案的踩坑见 [`docs/ISSUES.md`](docs/ISSUES.md)。

---

## 一、硬性约束（违反的后果不可恢复）

### 1.1 只能操作 boot 与 rootfs 两个分区

| 分区 | 用途 | 可以动吗 |
|---|---|---|
| `mmcblk0p12` (64M, `boot`) | 内核 + appended DTB | ✅ 动它 |
| `mmcblk0p14` (3.3G, `rootfs`) | 根文件系统 | ✅ 动它 |
| GPT / `aboot` / `modem` / `NV` / 其它 | 引导链、射频校准 | ❌ **绝对不要动** |

GPT 或 aboot 写坏 = 设备进不了任何模式，只能 EDL 全片恢复；NV/modem 写坏 =
射频永久失准，且**不可从别处复制回来**（每台机器的校准值唯一）。

### 1.2 刷机前必须能整片恢复

动手刷任何分区前，先确认目标分区有**分区级读回**副本（`dd if=/dev/mmcblk0p12 ...`）；
没有就先读一份。全片 eMMC 备份目前只有 Windows GUI 工具（Miko）能做，无法脚本化，
这是已知缺口（见 [`docs/build/TOOLING.md`](docs/build/TOOLING.md)）。

> 公开的 Firehose loader 不被这些棒子接受，只有 Miko 自带的 MSM8916 loader 能用。

### 1.3 这两个驱动的 remove 路径不健壮，别 rmmod

| 操作 | 后果 |
|---|---|
| venus 固件报错后 `rmmod venus` | **挂死内核** |
| render-only 模式下 `rmmod msm` | 空指针崩溃，GPU 设备消失、GL 退回 llvmpipe |

两者的恢复方式都只有**重启**。要重载驱动就重启，不要试 remove。

### 1.4 不做寄存器级试探

不使用 `devmem`、不做 Firehose poke、不写入猜测的寄存器值。这个平台已有能工作的
主线驱动，绕过驱动直接改寄存器只会得到难以复现的挂死。

### 1.5 串口

两端波特率都是 **115200**。若解不出内容，多半是 `serial-getty@ttyMSM0` 沿用了
上次的速率（`--keep-baud`），先在设备上 `stty -F /dev/ttyMSM0 115200` 复位。
参数名会随适配器类型变化（`ttyUSB0` ↔ `ttyACM0`），用前先确认。
**无可靠串口时不要默认 RX 安静**：串口杂散输入可能注入 SysRq，历史上曾与一次
非预期重启同时出现。测试内核 cmdline 建议禁用串口 console 并设 `kernel.sysrq=0`。

### 1.6 凭据

**仓库里不含任何真实凭据。** 设备口令、Wi-Fi PSK、内网地址一律从环境变量读取，
脚本不要写内置默认值。**不要把任何真实口令、PSK、内网地址提交进来。**
镜像本身也**不预置任何 Wi-Fi 凭据**（见 §2.9）。

---

## 二、平台硬限制（会让命令静默出错）

这一节是踩坑最多的地方。出错现象与真实原因距离很远。

### 2.1 Venus 编码器要求宽高都 32 对齐

不满足时固件报 `Err_Fatal - VenusCoreCtrl_AhbVbifErrorIRQ`，ffmpeg **段错误**。

- ✅ 640x480、1280x736、1280x768、**1920x1088**
- ❌ 1280x720（H%32=16）、1920x1080（H%32=24）

所以**「标准」分辨率反而不能用**。720p 要 pad 到 736，1080p 要用 1920x1088。
`tools/venus-transcode.sh` 有显式校验，`tools/verify-layout.sh` 有守护断言。

### 2.2 Venus 忽略 ffmpeg 的 `-g`

驱动只注册 `V4L2_CID_MPEG_VIDEO_H264_I_PERIOD` 与 `..._FORCE_KEY_FRAME`
（`venc_ctrls.c`），**没有 GOP_SIZE**，而 ffmpeg 的 v4l2m2m 封装只设 GOP_SIZE。
实测 180 帧只有 1 个 IDR，SPS/PPS 只在流开头发一次，**中途加入的播放器永远报
`non-existing PPS 0 referenced`**。修法：

```sh
-force_key_frames "expr:gte(t,n_forced*1)"   # 触发 FORCE_KEY_FRAME
-bsf:v dump_extra=freq=keyframe              # 每个关键帧前重挂 SPS/PPS
```

### 2.3 Venus 没有 H.265 / VP9 硬解

Venus 1.8 早于这些格式。V4L2 枚举 H.264/MPEG4/VC1/VP8/H263/XVID 等，但**枚举不等于
可用**：实测 H.264/VP8 通过，MPEG-2 有微小舍入差异；MPEG-4 触发
`Err_Fatal ... vbuffer.c:1200`（固件 bug，与内核基线无关，只能重启恢复）。
**H.265 只能软解**。同一 ffmpeg 进程里用 v4l2m2m 同时编+解只出 1 帧，所以**必须软解 + 硬编**。

### 2.4 单个 Venus 编码器 + 32MB CMA 是独占资源

跑两条链会互相抢，帧率掉到个位数且现象隐蔽（`CmaFree` 剩几百 KB）。编排脚本必须
在启动前做兜底清扫。注意 `CmaFree` 低**未必**是 venus 泄漏——内存压力下 movable
pageblock 会借用 CMA 区域，`sync; echo 3 > /proc/sys/vm/drop_caches` 后回升即是此因。

### 2.5 mbs_per_sec 上限是软的

`max_load = 352800` macroblocks/s（`venus/core.c`）超限时只 `dev_warn`，**不拒绝**。
1080p60（489600）仍能编，只是刷警告且没有实时余量。不要把它当硬墙。

### 2.6 GPU 只能分配 RGB 格式

Adreno 306 支持 XRGB8888/ARGB8888/RGB565/R8/GR88；**NV12/NV21/YUYV/YUYV 全不支持**。
所以「GPU 直接渲染出 NV12 给 venus」做不到，链路里必须有一次 RGB→NV12 转换。

### 2.7 GPU 是 render-only，需要特定的内核配置

本设备**没有显示面板**，GPU 只提供 render 节点。要求：

- 模块参数 `options msm separate_gpu_kms=1`（走 `msm_gpu_probe()`，绕开组件框架）
- **`CONFIG_DRM_MSM_KMS` 必须是 n**。`DRM_MSM_MDP4/MDP5/DPU` 在 Kconfig 里是
  `default y` 且会 `select DRM_MSM_KMS`，必须在片段里**显式 =n**
- 用 `source/configs/ufi103s-gpu.config`，构建脚本会断言这两条

验证：`/dev/dri/renderD128` 存在、`uevent` 里 `DRIVER=adreno`、GL 报 `FD307`（freedreno）。
若退回 llvmpipe 说明 GPU 没起来。

### 2.8 rootfs 的 MODULE_TREE 必须用 GPU 树

`msm.ko`/`drm.ko` 只在 `venus-4g-gpu` 板型的模块树里（`<ver>-ufix0x-venus-4g-gpu-dirty`），
纯 venus 板型里没有。拿错树构建 rootfs，开机 `modprobe msm` 只报一句
`Module drm not found`，表现为 `/dev/dri` 静默缺失、渲染退回 llvmpipe。

### 2.9 镜像不预置 Wi-Fi，首次进系统靠 USB RNDIS

刷出去的镜像里**没有任何 Wi-Fi 凭据**（刻意的）。无屏棒子插到电脑上后，靠 USB RNDIS
共享拿到 `10.42.0.1` 进系统，然后用 `nmtui` / `nmcli` 配无线。

刻意不预置的原因：预置一旦写法出错（例如凭据值里混入空白），会**静默写进镜像**、
开机连不上 AP，而设备无屏、刷完即失联。与其依赖"记得把值写对"，不如不预置。

### 2.10 内存与 CPU / xrdp

- **376 MB 总内存**（4× Cortex-A53），可用约 270 MB；**CMA 只有 32 MB**；zram 提供
  350 MB zstd swap。桌面选 i3 而非 LXQt/GNOME，不要引入内存重的组件。
- xrdp 的 `Xwrapper.config` 必须 `allowed_users=anybody`；客户端连接**必须用
  `/sec:tls`**（FreeRDP 3.x + xrdp 0.10 下 `/sec:rdp` 会报 `MAC checksum error`）。

---

## 三、工具与环境的坑

- **`pgrep -x` 对超过 15 字符的进程名零匹配**：内核 `comm` 截断到 15 字符。
  要按完整命令行匹配就扫 `/proc/*/cmdline`。
- **别用 `pkill -f "<pattern>"`**：它匹配完整命令行，正在执行的那条命令自己也含 pattern，
  会把自己杀掉。用 PID 列表精确 kill，或扫 `/proc` 按 cmdline 挑。
- **venus / CMA 的释放是异步的**：停链后要等驱动真正回收（轮询确认进程消失后再多等一拍）。
- **`MMDEBSTRAP_FORMAT` 默认是 `directory`**：不显式设 `ext4` 就只产出目录树，
  没有可刷的 `.ext4` 镜像。
- **构建主机的 `/tmp` 若是 tmpfs 且偏小**：mmdebstrap 临时目录落在 `/tmp` 会在装桌面
  包阶段 `No space left on device`（报错在 dpkg 解包，看不出是 tmpfs 小）。把 `TMPDIR`
  指到大盘目录。
- **构建主机缺 arm64 的 `arch-test` 探针**：mmdebstrap 会用 `arch-test` 做模拟能力
  预检，若它不认识 arm64 就会报 `arm64 can neither be executed natively nor via qemu
  user emulation`——这个报错具误导性，binfmt/qemu 其实是好的，缺的只是探针文件。
  从 Debian 的 `arch-test` 包（`Architecture: all`）取出 `usr/libexec/arch-test/arm64`
  放到宿主对应位置即可（`arch-test arm64` 应打印 `arm64: ok`）。
- **刷机时不要刷错对象**：刷的是 `artifacts/rootfs/*.ext4`（约 1 GB），**不是** 3.4 GB
  的整分区 dump（LK 会拒绝 `size too large`）；大镜像要 `-S 200M` 分片（LK 的
  `max-download-size` 只有 256 MB）；进 fastboot 用
  `systemctl reboot --reboot-argument=bootloader`，写成位置参数会报 `Too many arguments`。
- **升级内核先用 `fastboot boot` 做内存预演**：从内存启动、不写 boot 分区，通过再正式刷。
  启动/驱动硬挂死仍可能需要物理断电，不能称为"零风险"。
- **中文 locale 会打乱某些 grep**：`apt-cache`/`systemctl` 输出中英混排，需要稳定解析时
  加 `LC_ALL=C`。
- **wf-recorder 作采集端**：必须 `-c rawvideo`、必须 `-D`（no-damage）、必须经 FIFO 而非管道。

---

## 四、构建与验证

### 4.1 版本是单一事实来源

`source/kernel-version.env` 是**唯一**写内核版本的地方，配套 `tools/kver.sh`（shell）与
`tools/kver.py`（Python）。所有脚本从它派生路径与 release 字符串。**升级内核只改这个文件**，
脚本不要硬编码版本号。

**内核命名 = 设备令牌 + 板型（DTS 后缀）**。设备令牌写在 `KERNEL_LOCALVERSION`（当前
`-ufix0x`）。每个板型独立 release 与模块树，如 `7.2.9-ufix0x-dirty`、
`7.2.9-ufix0x-venus-4g-gpu-dirty`。板型级构建用 `tools/build-board-set.sh`（表驱动）。
**重刷时内核与模块树必须成对**，只刷 boot.img 会让模块全部静默失配（vermagic 含 release）。

> 内核镜像**不是逐位可复现的**（构建序号/时间戳/build-id 会变，解压后仅几十字节不同）；
> 模块 `.ko` 是逐字节可复现的。所以别用内核镜像哈希判断"是否重建成功"，比对解压内容或
> 看 `dmesg | grep 'Linux version'`。

### 4.2 产物位置

所有构建产物只放 `artifacts/`（`boot` / `rootfs` / `modules` / `dtb` / `firmware` 五类），
`boards/` 只放源码（DTS）。脚本**不要拼 `artifacts/...` 字面路径**，一律用 `tools/kver.sh`
/ `kver.py` 派生的 `ARTIFACTS_*` 变量。

### 4.3 验收标准

- 脚本：`bash -n` 全过
- 补丁：在 pristine 内核树上按序干净套用（无 fuzz、无 reject），反向套用也干净
- DTS：所有变体零错误编译
- 内核 / rootfs：`tools/verify-layout.sh` exit 0
- 设备相关改动：**实机验证**，不要只靠编译通过就宣称可用

常用命令见 [`README.md`](README.md)「开始使用」与 [`docs/build/TOOLING.md`](docs/build/TOOLING.md)。

---

## 五、许可

提交即表示同意以 **GPL-2.0-only** 授权。详见 [`LICENSE`](LICENSE) 与 [`NOTICE`](NOTICE)。
