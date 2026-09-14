# GPU 桌面 + venus 推流：可行性与结论

**问题**：能否用 GPU 渲染桌面，再用 Venus 硬件编码把画面推出去？

**答案：能。** 这条链路的每一层都在实机上验证通过了，但**现成软件没有一条龙的方案**——
三个候选工具各缺一环。下面分层给证据，最后给可行方案。

## 分层验证结果

| 层 | 结论 | 证据 |
|---|---|---|
| 1. GPU 渲染桌面 | ✅ 可行 | weston/sway headless + GL → `GL renderer: FD307` |
| 2. Venus 硬编码 | ✅ 可行 | 有多分辨率实测（见下方 32 对齐硬约束） |
| 3. GPU ↔ Venus 零拷贝 | ✅ 双向可行 | C 程序实测 dmabuf 互相导入成功 |
| 4. GPU 色彩转换 → Venus 编码 | ✅ 可行 | GStreamer 管线产出可解码 H.264 |
| 5. GPU 合成 + Venus 编码 并发 | ✅ 可行 | 两者同时跑，互不影响 |
| 6. 合成器输出 → 编码器 的现成连接器 | ❌ 无 | 三个候选都缺一环，见下 |

## 1. GPU 渲染桌面（不需要 KMS）

无显示面板也能用 GPU 合成——headless 后端 + GL 渲染器：

```
$ weston --backend=headless-backend.so --renderer=gl --width=1280 --height=736
[16:11:24.489] EGL vendor: Mesa Project
[16:11:24.569] GL version: OpenGL ES 3.0 Mesa 25.0.7
[16:11:24.569] GL vendor: freedreno
[16:11:24.569] GL renderer: FD307        <- Adreno 306 硬件
[16:11:24.762] Using GL renderer
```

sway（wlroots）同样可行：

```
$ WLR_BACKENDS=headless WLR_RENDERER=gles2 sway
[wlr] Opening DRM render node '/dev/dri/renderD128'
[wlr] Using EGL device /dev/dri/card0
[wlr] Supported EGL display extensions: ... EGL_EXT_image_dma_buf_import
                                        EGL_MESA_image_dma_buf_export
```

`EGL_EXT_image_dma_buf_import` / `EGL_MESA_image_dma_buf_export` 都在，
这是零拷贝的前提。软件渲染（llvmpipe）也能跑，但那就不算"GPU 渲染"了。

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

这就是为什么我们的 `tools/venus-transcode.sh` 里写着
"Venus encoder needs 32-aligned height, so scale to 1280x720 and pad to
1280x736"。**1080p 是能用的**（用 1920x1088），之前以为不行只是因为高度没对齐。

## 3. GPU ↔ Venus 零拷贝：双向都通

这条是关键——它决定能不能省掉内存拷贝。写了 C 程序实测：

**Venus 分配 → GPU 导入**（推荐姿态，venus 的缓冲天然物理连续）：

```
venus 分配了 5 个 NV12 缓冲 (size=462848)
venus 缓冲已导出为 dmabuf fd=4
GPU 导入 venus dmabuf: 成功
  -> 零拷贝架构可行：venus 内存，GPU 直接写，无中间拷贝
```

**GPU 分配 → Venus 导入**（第一次测试，也通过了）：

```
GPU dmabuf: fd=6 stride=5120 format=0x34325258 size=1280x800
OUTPUT 已设: 1280x800 fourcc=NV12
REQBUFS(DMABUF) 成功，count=5
>>> QBUF(GPU dmabuf) 成功 —— 零拷贝导入可行！
```

**为什么能通**：venus 的 `vb2_dma_contig` 会检查 dmabuf 的 DMA 地址是否连续
（`vb2_dc_map_dmabuf` 里 `contiguous chunk is too small` 那个检查）。msm8916
的两个 IOMMU（`apps_iommu` 给 venus、`gpu_iommu` 给 GPU）会把分散的物理页映射成
连续的 DMA 地址，所以检查通过。

### 但 GPU 不能分配 YUV 格式

实测 GPU 支持的缓冲格式：

```
NV12   不支持      NV21   不支持      YUYV   不支持      UYVY   不支持
XRGB8888 支持      ARGB8888 支持     RGB565 支持
ABGR8888 支持      XBGR8888 支持     R8 支持           GR88 支持
```

**全是 RGB 类**（Adreno 3xx 的硬件特性）。所以「GPU 直接渲染出 NV12 给 venus」
做不到，中间必须有一次 RGB→NV12 的色彩转换。

有趣的是 `R8` 和 `GR88` 都支持——理论上可以让 GPU 分别渲染 Y 平面（R8）和
UV 平面（GR88）来凑 NV12，但 venus 的 NV12 是**单平面**
（`venc.c` 注释："the MPLANE formats allow only one plane to be used"），
所以还是得转成一块连续内存。

## 4. GPU 色彩转换 → Venus 编码：管线跑通

用 GStreamer 把「GPU 转换 + venus 编码」接起来（1280x736，32 对齐）：

```sh
gst-launch-1.0 videotestsrc num-buffers=60 ! \
  video/x-raw,width=1280,height=736,framerate=30/1 ! \
  glupload ! glcolorconvert ! "video/x-raw(memory:GLMemory),format=NV12" ! \
  gldownload ! \
  v4l2h264enc ! h264parse ! filesink location=out.h264
```

结果：**73476 字节可解码 H.264**（`ffprobe` 确认 codec=h264, 1280x736）。
注意这条管线里 `gldownload` 把数据从 GPU 拷回主存——**不是零拷贝**，
但证明了「GPU 做转换、venus 做编码」这条分工是通的。

## 5. GPU 合成与 Venus 编码可以并发

```
weston 渲染器: GL renderer: FD307
GPU 客户端: 运行中
并发下 venus 产物: 74924 字节  OK
GPU 客户端仍在: 是
```

两者用不同的 IOMMU 和不同的硬件单元，互不抢占。

## 6. 缺的那一环：合成器到编码器的连接器

三个候选工具各缺一环：

### wf-recorder（wlroots 标准录制工具）—— 失败

它有 `--no-dmabuf`、`-c h264_v4l2m2m` 等选项，看起来正合适，但：

```
selected region 0,0 1280x736
[h264_v4l2m2m] requesting formats: output=NV12/rgb0 capture=H264/none
[h264_v4l2m2m] Encoder requires nv12 pixel format.
avcodec_open2 failed: Invalid argument
```

**它把 RGB 直接喂给 venus，中间不做 RGB→NV12 转换**。四个编码器组合
（`h264_v4l2m2m` / `--no-dmabuf` / `libx264` / `-p pix_fmt=nv12`）全部失败。
这是 wf-recorder 对 v4l2m2m 编码器支持的缺陷，不是内核问题。

### weston 的 remoting 插件 —— 不适用

它用 `gst_parse_launch` 接收合成输出、`gst_dmabuf_allocator_alloc` 走 dmabuf
（设计上正是我们要的零拷贝），但它注册的是
`weston_drm_virtual_output_api_v2` —— **需要 DRM 后端**。我们没有 KMS，加载不了。

### weston pipewire 后端 + GStreamer pipewiresrc —— 半通

weston 以 GPU 合成并成功发布到 pipewire：

```
[16:44:14.852] Initializing PipeWire backend
[16:44:16.042] Registered plugin API 'weston_pipewire_output_api_v2'
node.name = "weston.pipewire"
media.class = "Stream/Output/Video"
```

但 `pipewiresrc` 拉流失败（`no format given`，加显式 caps 也不出帧）。
pipewire 自身还有 session bus 报错（无 D-Bus 会话）。这条路上还需要调。

## 可行方案（按实用性排序）

### 方案 A：抓帧循环 → venus（最简单，已验证）

sway/weston（GPU 合成）持续运行，用 `grim` 式抓帧，帧送 venus 编码：

```sh
# 已验证：grim 能从 GPU 合成的 sway 抓到 PNG（2819 字节）
grim -o HEADLESS-1 shot.png
# 已验证：PNG -> venus 硬编码成功（3740 字节）
ffmpeg -i shot.png -vf "format=nv12,scale=1280:736" -pix_fmt nv12 \
       -c:v h264_v4l2m2m out.h264
```

**优点**：所有环节都已验证可用。
**缺点**：CPU 参与拷贝与色彩转换，帧率受限于抓帧循环（适合 1-5 fps 的
"看屏幕状态"场景，不适合流畅视频）。

### 方案 B：GStreamer 全管线（GPU 转换 + venus 编码已验证）

第 4 节那条管线本身通了，只差一个**能用的合成器源**。可选：
- 把 sway/weston 的输出通过支持 dmabuf 的源喂进 GStreamer
- 或修 pipewiresrc 的协商问题（方案 C 的前提）

**优点**：GPU 做色彩转换，CPU 负担小。
**缺点**：需要打通 pipewire 或写一个 wlr-screencopy 的 GStreamer 源。

### 方案 C：自写连接器（零拷贝，工作量最大）

用第 3 节已验证的内核能力：

1. venus 侧 `REQBUFS(MMAP)` 分配 NV12 缓冲（天然连续）
2. `VIDIOC_EXPBUF` 导出 dmabuf
3. GPU 用 `gbm_bo_import` 导入（已验证成功），渲染桌面内容到该缓冲，
   顺便用 GPU shader 做 RGB→NV12
4. `QBUF` 把同一缓冲交回 venus 编码

全程零拷贝，但要写约 200-400 行 C（或用 GStreamer 的 `appsrc`＋自写源）。

### 现阶段推荐

如果目标是**远程看桌面**：用已跑通的 **xrdp**（`DESKTOP.md`）——它走软件虚拟显示，
在这个 376MB 内存的设备上是最省事、最稳的方案。

如果目标是**把桌面推成视频流**（比如给手机/网页看）：先做**方案 A** 落地，
它每一环都已验证；再按需向方案 B/C 演进。

## 顺带发现的 bug：render-only 模式下 rmmod msm 会崩

调试过程中发现，`modprobe -r msm` 在 render-only 模式（`separate_gpu_kms=1`）
下会解引用空指针崩溃：

```
pc : msm_drm_uninit.isra.0+0x24/0x94 [msm]
lr : msm_gpu_remove+0x14/0x20 [msm]
Call trace:
 msm_drm_uninit.isra.0+0x24/0x94 [msm] (P)
 msm_gpu_remove+0x14/0x20 [msm]
 adreno_remove+0x3c/0x40 [msm]
 ...
 __arm64_sys_delete_module
```

原因：`msm_drm_uninit()` 里 `priv->kms` 为 NULL（render-only 模式没有 KMS），
但代码在 `ddev->registered` 分支里只对 `priv->kms` 做了部分保护，
后面 `msm_drm_kms_cleanup` 之类的路径仍会解引用。崩溃后 GPU 设备消失，
GL 退回 llvmpipe，**只能重启恢复**。

**操作建议：render-only 模式下不要 `rmmod msm`**（和「venus 报错后别 rmmod」
是同一类问题——这两个驱动的 remove 路径都不够健壮）。要重载就重启。
