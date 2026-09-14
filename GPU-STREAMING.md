# GPU 桌面 + venus 推流

**问题**：能否用 GPU 渲染桌面，用 Venus 硬件编码推出去，并在另一台机器上开窗口实时显示？

**答案：能，已端到端跑通。** 设备上 `sway`（GPU 合成）→ `wf-recorder`（抓帧）→ FIFO →
`ffmpeg`（RGB→NV12）→ `h264_v4l2m2m`（Venus 硬编）→ MPEG-TS/UDP → 对端 `mpv` 全屏窗口。
实测 1280x736@30，稳定 26–28 fps，端到端延迟约 1 秒，画面用走动的时钟验证过是实时的。

现成工具**没有一条龙方案**，缺的一环用 FIFO 补上了（下详）。

## 结论表

| 层 | 结论 | 证据 |
|---|---|---|
| 1. GPU 渲染/合成桌面 | ✅ | `sway` headless + gles2 → `GL renderer: FD307` |
| 2. Venus 硬编码 | ✅ | 多分辨率实测，见 32 对齐约束 |
| 3. GPU ↔ Venus 零拷贝 | ✅ 双向 | C 程序实测 dmabuf 互相导入 |
| 4. GPU 色彩转换 → Venus 编码 | ✅ | GStreamer 管线产出可解码 H.264 |
| 5. GPU 合成 + Venus 编码 并发 | ✅ | 两者同时跑，互不影响 |
| 6. 合成器输出 → 编码器 的连接器 | ✅ **用 FIFO 补上** | 见「方案 A」 |
| 7. 端到端到对端桌面 | ✅ | 时钟 19:20:04→19:20:09，uptime 同步增长 |

## 1. GPU 渲染桌面（不需要 KMS）

无显示面板也能用 GPU 合成 —— headless 后端 + GL 渲染器：

```
$ weston --backend=headless-backend.so --renderer=gl --width=1280 --height=736
[16:11:24.489] EGL vendor: Mesa Project
[16:11:24.569] GL version: OpenGL ES 3.0 Mesa 25.0.7
[16:11:24.569] GL vendor: freedreno
[16:11:24.569] GL renderer: FD307        <- Adreno 306 硬件
[16:11:24.762] Using GL renderer
```

sway（wlroots）同样可行，本项目实际用的就是它：

```
$ WLR_BACKENDS=headless WLR_RENDERER=gles2 WLR_HEADLESS_OUTPUTS=1 sway
[wlr] Opening DRM render node '/dev/dri/renderD128'
[wlr] Using EGL device /dev/dri/card0
[wlr] Supported EGL display extensions: ... EGL_EXT_image_dma_buf_import
                                        EGL_MESA_image_dma_buf_export
```

`EGL_EXT_image_dma_buf_import` / `EGL_MESA_image_dma_buf_export` 都在，这是零拷贝的前提。
软件渲染（llvmpipe）也能跑，但那就不算“GPU 渲染”了，用 `sway.log` 里有没有 `FD3`
可以一眼区分。

## 2. Venus 硬编码：32 对齐是硬约束

实测（ffmpeg `h264_v4l2m2m`，2 秒 15fps 测试源）：

| 分辨率 | H%32 | 结果 |
|---|---|---|
| 640x480 | 0 | ✅ 106399 字节 |
| 1280x736 | 0 | ✅ 168142 字节 |
| 1280x768 | 0 | ✅ 198770 字节 |
| **1920x1088** | 0 | ✅ **242738 字节** |
| 1280x720 | 16 | ❌ ffmpeg 段错误 |
| 1920x1080 | 24 | ❌ ffmpeg 段错误 |

**宽高都必须 32 对齐**，否则 Venus 固件报
`Err_Fatal - VenusCoreCtrl_AhbVbifErrorIRQ`（总线接口错误）并让进程崩掉。

所以 720p/1080p 这类“标准”分辨率反而不能用；用 1280x736（720p 加 16 行黑边）
或 1920x1088。**1080p 是能用的**，之前以为不行只是因为高度没对齐。

### 2b. venus 忽略 `-g`，必须用 `-force_key_frames`（关键坑）

这是推流能否被“中途加入”的决定性细节。

venus 驱动只注册了 `V4L2_CID_MPEG_VIDEO_H264_I_PERIOD` 和
`V4L2_CID_MPEG_VIDEO_FORCE_KEY_FRAME`（见 `venc_ctrls.c:632,635`），
而 ffmpeg 的 v4l2m2m 封装只设 `GOP_SIZE` —— 驱动**忽略**它。实测：

```
$ ffmpeg ... -c:v h264_v4l2m2m -g 60 -f h264 out.264
$ ffprobe -show_frames out.264 | grep key_frame
   总帧=180 关键帧=1        <- -g 完全无效，整段只有开头一个 IDR
```

后果：编码器只在**流最开始**发一次 SPS/PPS/IDR。一个**中途加入**的播放器拿不到
参数集，只能一直报：

```
[h264] non-existing PPS 0 referenced
[h264] no frame!
```

解法是改用 `-force_key_frames`，它按帧的 `pict_type` 触发
`V4L2_CID_MPEG_VIDEO_FORCE_KEY_FRAME`：

```
$ ffmpeg ... -force_key_frames "expr:gte(t,n_forced*1)" ...
   总帧=180 关键帧=6        <- 每秒一个 IDR，OK
```

配合 `-bsf:v dump_extra=freq=keyframe`（把 SPS/PPS 挂到每个关键帧前），
播放器就能在 1 秒内锁定。这是整条链路里最容易漏、也最难从现象反推的一环。

## 3. GPU ↔ Venus 零拷贝：双向都通

写了 C 程序实测。

**Venus 分配 → GPU 导入**（推荐姿态，venus 的缓冲天然物理连续）：

```
venus 分配了 5 个 NV12 缓冲 (size=462848)
venus 缓冲已导出为 dmabuf fd=4
GPU 导入 venus dmabuf: 成功
```

**GPU 分配 → Venus 导入**：

```
GPU dmabuf: fd=6 stride=5120 format=0x34325258 size=1280x800
OUTPUT 已设: 1280x800 fourcc=NV12
REQBUFS(DMABUF) 成功，count=5
>>> QBUF(GPU dmabuf) 成功 —— 零拷贝导入可行！
```

**为什么能通**：venus 的 `vb2_dma_contig` 会检查 dmabuf 的 DMA 地址是否连续
（`vb2_dc_map_dmabuf` 里的 `contiguous chunk is too small` 检查）。msm8916 的两个
IOMMU（`apps_iommu` 给 venus、`gpu_iommu` 给 GPU）把分散的物理页映射成连续的 DMA
地址，所以检查通过。

### 但 GPU 不能分配 YUV 格式

```
NV12   不支持      NV21   不支持      YUYV   不支持      UYVY   不支持
XRGB8888 支持      ARGB8888 支持     RGB565 支持
ABGR8888 支持      XBGR8888 支持     R8 支持           GR88 支持
```

**全是 RGB 类**（Adreno 3xx 的硬件特性）。所以「GPU 直接渲染出 NV12 给 venus」做不到，
中间必须有一次 RGB→NV12 的颜色转换。

## 4. GPU 色彩转换 → Venus 编码：管线跑通

```
$ gst-launch-1.0 videotestsrc num-buffers=60 ! \
    video/x-raw,width=1280,height=736,framerate=30/1 ! \
    glupload ! glcolorconvert ! "video/x-raw(memory:GLMemory),format=NV12" ! \
    gldownload ! v4l2h264enc ! h264parse ! filesink location=out.h264
```

产出 73476 字节可解码 H.264。这条管线里 `gldownload` 把数据从 GPU 拷回主存，
**不是零拷贝**，但证明了「GPU 转换 + venus 编码」这条分工可行。

## 5. GPU 合成与 Venus 编码可以并发

两者用不同的 IOMMU 和不同的硬件单元，互不抢占：

```
weston 渲染器: GL renderer: FD307
GPU 客户端: 运行中
并发下 venus 产物: 74924 字节  OK
```

**但要小心**：单一 venus 编码器 + 32MB CMA 是全局独占资源。跑两条链会互相抢，
帧率掉到个位数（实测 7fps）而且现象很隐蔽。所以脚本里做了兜底清扫，
启动前先确保没有残链（见 `tools/desktop/ufi-stream-push.sh` 的 `sweep_stragglers`）。

## 6. 缺的那一环，以及怎么补上

三个候选连接器各有缺点：

- **wf-recorder 直接编码** —— 失败。它把 RGB（`rgb0`）直接喂给 venus，
  中间不转换：`[h264_v4l2m2m] Encoder requires nv12 pixel format.` /
  `avcodec_open2 failed: Invalid argument`。四种编码器组合全部失败。
- **weston remoting 插件** —— 不适用。它注册的是
  `weston_drm_virtual_output_api_v2`，**需要 DRM 后端**，我们没有 KMS。
- **weston pipewire 后端 + pipewiresrc** —— 半通。weston 能把 GPU 合成发布到
  pipewire（`node.name = "weston.pipewire"`, `media.class = "Stream/Output/Video"`,
  格式 **BGRx**），但 `pipewiresrc` 拉流协商不出来（`no format given`），
  pipewire 自身还缺 D-Bus 会话。

### 方案 A（已落地）：wf-recorder 出 rawvideo，FIFO 桥到 ffmpeg 转换再硬编

思路：让 wf-recorder 只做它擅长的事（从合成器抓帧），把 RGB→NV12 交给 ffmpeg，
venus 只管编码。

```sh
mkfifo /tmp/stream/p.yuv
wf-recorder -g "0,0 1280x736" -c rawvideo -r 30 -D -f /tmp/stream/p.yuv &
ffmpeg -f rawvideo -pix_fmt bgra -s 1280x736 -r 30 -i /tmp/stream/p.yuv \
  -vf format=nv12 -pix_fmt nv12 \
  -c:v h264_v4l2m2m -b:v 4M \
  -force_key_frames "expr:gte(t,n_forced*1)" -fps_mode passthrough \
  -bsf:v dump_extra=freq=keyframe \
  -f mpegts "udp://192.0.2.13:5000?pkt_size=1316"
```

要点：

- `-c rawvideo` 绕开 wf-recorder 对 v4l2m2m 的残缺支持（它自己也不做转换）。
- `-D`（no-damage）强制持续出帧，否则合成器只在有更新时才给帧，
  帧率不可控、`-fps_mode passthrough` 也没意义。
- **必须用 FIFO**，不能直接管道：两个进程都依赖对方活着，
  一方退出另一方会空转（实测 ffmpeg 会挂住等 FIFO 写入端）。
- `-fps_mode passthrough`：venus 每帧上报的 timestamp 是 0，
  默认 vsync 会把几乎每帧都丢掉。

**代价**：RGB→NV12 转换由 CPU 做。1280x736@30 下 CPU 有余量（能跑到 26–28fps，
说明瓶颈不在转换）。零拷贝版本见方案 C。

### 方案 B：GStreamer 全管线（GPU 转换 + venus 编码已验证）

第 4 节那条管线本身通了，只差一个**能用的合成器源**。需要打通 pipewiresrc
或写一个 wlr-screencopy 的 GStreamer 源。

### 方案 C：自写连接器（零拷贝，工作量最大）

用第 3 节已验证的内核能力：

1. venus 侧 `REQBUFS(MMAP)` 分配 NV12 缓冲（天然连续）
2. `VIDIOC_EXPBUF` 导出 dmabuf
3. GPU 用 `gbm_bo_import` 导入（已验证成功），渲染桌面内容到该缓冲，
   顺便用 GPU shader 做 RGB→NV12
4. `QBUF` 把同一缓冲交回 venus 编码

全程零拷贝，约 200–400 行 C。

## 7. 实测性能（1280x736，1280x736@30 源）

| 指标 | 实测 |
|---|---|
| 采集+编码帧率 | 26–28 fps（目标 30） |
| 输出码率 | 约 1.0–1.1 Mbit/s（`-b:v 4M` 上限下，实际内容简单） |
| 端到端延迟 | 约 1 秒（含 1 秒内等 IDR 的锁定时间） |
| 单条链 CMA 占用 | 约 30MB / 32MB（`CmaFree` 剩 2–7MB） |
| 中途加入锁定 | ≤ 1 秒（`-force_key_frames` 每秒一个 IDR） |

## 8. 网络：UDP 通路本身没问题

调试时出现过“对端收到 0 字节”，最后查明**不是网络**。排查顺序（值得复用）：

1. 裸 UDP 往返：设备 `python3 socket.sendto` → 对端 `recvfrom`，收到 17 字节 →
   链路、路由、防火墙都正常。
2. 合成源 → venus → `udp://` 发送，对端用字节计数接收器：收到 6000+ 包 / 6.4MB。
3. 剩下的问题就只可能在编解码参数上了 —— 也就是第 2b 节那个 `-force_key_frames`。

顺带确认：对端 firewalld 的 `default` zone 已放行 `1025-65535/udp`，
所以 UDP 5000 本来就通。

## 9. 脚本

| 脚本 | 位置 | 用途 |
|---|---|---|
| `ufi-stream-push.sh` | 设备 `/usr/local/bin/` | 起 sway+抓帧+硬编+推流；`stop` 停止整链 |
| `ufi-stream-clock.sh` | 设备 `/usr/local/bin/` | 桌面放一个实时时钟窗口（便于肉眼验实时性） |
| `ufi-stream-play.sh` | 接收端 | 自动探测 Wayland/X11 会话并全屏播放 |

源文件在 `tools/desktop/`。用法：

```sh
# 设备
TARGET=192.0.2.13 ufi-stream-push.sh     # 默认就是 .113:5000
ufi-stream-push.sh stop

# 接收端
ufi-stream-play.sh                          # 全屏
WINDOWED=1 ufi-stream-play.sh               # 窗口模式
OUT=/tmp/s.ts ufi-stream-play.sh            # 只录制
```

## 顺带发现的 bug：render-only 模式下 rmmod msm 会崩

`modprobe -r msm` 在 render-only 模式（`separate_gpu_kms=1`）下解引用空指针崩溃：

```
pc : msm_drm_uninit.isra.0+0x24/0x94 [msm]
lr : msm_gpu_remove+0x14/0x20 [msm]
```

`msm_drm_uninit()` 里 `priv->kms` 为 NULL（render-only 没有 KMS），
但 `ddev->registered` 分支只做了部分保护。崩溃后 GPU 设备消失，GL 退回 llvmpipe，
**只能重启恢复**。

**操作建议：render-only 模式下不要 `rmmod msm`**（和「venus 报错后别 rmmod」
是同一类问题——这两个驱动的 remove 路径都不够健壮）。
