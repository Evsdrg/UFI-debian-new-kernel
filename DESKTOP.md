# 桌面 + 远程桌面 + GPU（UFI103s）

三件事都已在实机跑通并截图验证：**i3 桌面**、**xrdp 远程连接**、**Adreno 306
GPU 硬件渲染**，外加**硬件编解码**（Venus，本来就有）。

## 结论速览

| 能力 | 状态 | 证据 |
|---|---|---|
| i3 桌面（X11） | ✅ 可用 | xfreerdp 连上后截图见中文/i3 状态栏 |
| xrdp 远程桌面 | ✅ 可用 | `xrdp devices` 列出、会话存活、截图有真实内容 |
| GPU 硬件渲染 | ✅ 可用 | `OpenGL core profile renderer: FD307`（freedreno） |
| 硬件编解码 | ✅ 可用 | Venus 软/硬解结果**逐字节一致** |

## 一、桌面（i3）

选 **i3** 而不是 LXQt/KDE：这台机器只有 **376MB 内存**（可用约 250MB），
i3 加一个 xterm 和 i3status 总共只占几十兆，而完整桌面环境光会话管理器就吃紧。

装的组件（都在 `build-rootfs.sh` 的 `DESKTOP_PKGS`）：

| 包 | 作用 |
|---|---|
| `xserver-xorg-core` | X 服务器 |
| `xserver-xorg-video-dummy` | 无头虚拟显示 |
| `xserver-xorg-legacy` | 提供 `Xwrapper.config`（放行非 console 用户启动 Xorg） |
| `xrdp` / `xorgxrdp` | RDP 服务端 + Xorg 的 RDP 后端驱动 |
| `i3-wm` / `i3status` / `dmenu` | 窗口管理器、状态栏、启动器 |
| `xterm` / `x11-utils` | 终端与调试工具 |
| `fonts-wqy-microhei` | 中文（5MB；`fonts-noto-cjk` 要 91MB，内存和磁盘都不划算） |
| `libgl1-mesa-dri` 等 | Mesa 用户态（GPU 用，见第三节） |

配置资产在 `tools/desktop/`，构建时装进镜像：

- `xsession` → `/root/.xsession`：会话入口，设 `LANG=zh_CN.UTF-8` 后 `exec i3`
- `i3-config` → `/root/.config/i3/config`：预置配置（避免首次登录弹向导）
- `gpu-status.sh` / `zh-check.sh` → `/usr/local/bin/`：排错用的小窗口

> **`allowed_users=anybody` 是必需的。** xrdp 以服务身份启动 Xorg，Debian 的
> `xserver-xorg-legacy` 默认 `allowed_users=console`，会直接拒绝，表现为
> 能认证但会话起不来。构建脚本会写入正确的 `Xwrapper.config`。

## 二、xrdp

服务端：`xrdp.service` + `xrdp-sesman.service`（监听 3389）。

```sh
# 主机（Linux/Windows 都行）连接
xfreerdp /v:<设备IP> /u:root /p:<密码> /size:1280x800 /cert:ignore /sec:tls
# 或图形客户端
remmina            # 新建 RDP 连接
```

### 踩过的坑：`/sec:rdp` 会失败

第一次用默认的 `/sec:rdp`（标准 RDP 安全层）连接，认证过了但会话在 LICENSING
阶段挂掉，服务端日志：

```
[ERROR] MAC checksum error for non-FIPS PDU
[ERROR] xrdp_rdp_recv: xrdp_sec_recv failed
```

FreeRDP 3.x 与 xrdp 0.10 在这条路径上的 MAC 计算不兼容。**改用 `/sec:tls`
即可**（服务端配置里 `Security protocol: configured [SSL|RDP]`，两边都支持 TLS）。

### 验证方式（端到端、有截图）

主机上不需要真实显示器：

```sh
Xvfb :99 -screen 0 1280x800x24 &
DISPLAY=:99 xfreerdp /v:<IP> /u:root /p:<pw> /size:1280x800 /cert:ignore /sec:tls &
sleep 20
DISPLAY=:99 import -window root /tmp/shot.png     # 截取会话画面
```

截出来的图能看到 i3 的窗口边框、状态栏（网络/磁盘/内存/时间都在刷新）、
以及中文渲染。

## 三、GPU：Adreno 306（render-only）

**这台设备没有显示面板**，但 GPU 可以用——主线内核支持把 GPU 单独暴露成
render 节点，不需要任何显示硬件。

### 硬件与主线支持

- MSM8916 的 GPU 是 **Adreno 306**，`compatible = "qcom,adreno-306.0"`，
  chip_id `0x03000600`，属于主线 **a3xx** 家族（`drivers/gpu/drm/msm/adreno/a3xx_catalog.c`）
- 需要的固件 `a300_pfp.fw` / `a300_pm4.fw` 镜像里本来就有
- DTS 里 `&gpu` 是 `status = "disabled"`，板级打开即可（三星机型也是这么做的）
- 内核原先 `# CONFIG_DRM is not set`，完全没有显示/GPU 栈

### render-only 是怎么实现的（关键机制）

`msm.ko` 默认把 GPU 当作**显示管线的组件**，通过 component framework 绑定；
没有 MDP/MDSS/DSI 时必然失败。主线为此留了独立路径：

```
adreno_probe()
  → msm_gpu_no_components() 为真
      → msm_gpu_probe()      // 不绑组件，独立注册 DRM render 设备
```

`msm_gpu_no_components()` 返回模块参数 **`separate_gpu_kms`**，所以：

```
# /etc/modprobe.d/msm-gpu-render-only.conf
options msm separate_gpu_kms=1
```

同时必须让 `CONFIG_DRM_MSM_KMS` 保持 **n**。**这里是本次最大的坑**：
`DRM_MSM_MDP4` / `MDP5` / `DPU` 在 Kconfig 里都是 **`default y`**，`olddefconfig`
会自动打开它们，而它们各自 `select DRM_MSM_KMS` —— KMS 被强制启用，驱动转去
找显示组件就失败了。所以 `source/configs/ufi103s-gpu.config` 里必须**显式**：

```
# CONFIG_DRM_MSM_MDP4 is not set
# CONFIG_DRM_MSM_MDP5 is not set
# CONFIG_DRM_MSM_DPU is not set
# CONFIG_DRM_MSM_MDSS is not set
# CONFIG_DRM_MSM_DSI is not set
# CONFIG_DRM_MSM_DP is not set
# CONFIG_DRM_MSM_HDMI is not set
```

`tools/build-gpu-variant.sh` 会校验这一点（KMS 若被启用就直接报错退出）。

### 另一个坑：不能只换模块，必须换内核

我一开始想省事，只把 `msm.ko` 等模块传到设备 `insmod`，结果 `drm.ko` 加载失败：

```
drm: Unknown symbol hdmi_vendor_infoframe_init (err -2)
drm: Unknown symbol video_get_options (err -2)
```

这两个符号来自 `CONFIG_HDMI=y` 和 `CONFIG_VIDEOMODE_HELPERS`，它们是**编进
vmlinux 的**（内核配置原先没开）。所以 DRM 有 builtin 依赖，**必须重新编内核
并刷 boot**，不能只换模块。好在 GPU 变体沿用了 venus 的 `LOCALVERSION`，模块
release 与设备现有树一致，所以**不用重刷 rootfs**。

### 结果

```
$ ls /dev/dri/
card0  renderD128  by-path

$ cat /sys/class/drm/renderD128/device/uevent
DRIVER=adreno
OF_NAME=gpu
OF_FULLNAME=/soc@0/gpu@1c00000
OF_COMPATIBLE_0=qcom,adreno-306.0

$ EGL_PLATFORM=gbm eglinfo | grep renderer
OpenGL core profile renderer: FD307                     # Adreno 306 的 freedreno 标识
OpenGL ES profile renderer: FD307
OpenGL ES profile version: OpenGL ES 3.0 Mesa 25.0.7
```

`FD307` 是 freedreno 对 revn 307（a306）的命名，走**硬件**而不是 llvmpipe。

构建方式：

```sh
tools/build-gpu-variant.sh          # 编内核 + 打包 boot-venus-oc-100-gpu.img
# 然后 fastboot flash boot <该镜像>
```

注意 GPU 与 xrdp **不冲突**：xrdp 走的是 xorgxrdp 的软件虚拟显示
（`xrdpdev_drv.so`），不碰 DRM；GPU 只提供 render 节点给应用做加速渲染。

## 四、硬件编解码（Venus）

这部分本来就有（`CONFIG_VIDEO_QCOM_VENUS=m` + `venus.mbn`），本次确认在桌面
环境下依然可用：

```sh
# 硬编码（注意必须是 nv12 + 裸流；用 mp4 封装或 yuv420p 会报 -22）
ffmpeg -f lavfi -i "testsrc=duration=2:size=640x480:rate=15" \
       -vf format=nv12 -pix_fmt nv12 -c:v h264_v4l2m2m -b:v 1M out.h264

# 硬解码
ffmpeg -c:v h264_v4l2m2m -i out.h264 -fps_mode passthrough \
       -f rawvideo -pix_fmt nv12 hw.yuv
```

实测硬解与软解输出**逐字节相同**（13824000 字节）。`ffmpeg` 暴露的 venus 编码器
有 h263/h264/hevc/mpeg4/vp8，解码器另有 mpeg1/mpeg2/vc1/vp9。

> 注意：别在 venus 报错后 `rmmod venus` ——只会挂死内核，只能重启。

## 内存实况（重要）

装完桌面 + GPU 后：

```
              total   used   free  available
内存:          376    125     42      250
交换(zram):    349     10    339
```

**只有 376MB**，所以这个桌面适合「轻量远程操作/跑命令行工具」，不适合开浏览器
或多标签终端。要跑重负载，优先考虑把活儿丢给 Venus（编解码）而不是 CPU。

## 复现步骤（从零）

```sh
# 1) 编 GPU 内核（含 venus），产出 boot 镜像
tools/build-gpu-variant.sh

# 2) 构建带桌面的 rootfs（DESKTOP 默认 1）
MMDEBSTRAP_FORMAT=ext4 ROOTFS_PATH=/path/to/rootfs.ext4 \
  ROOTFS_WIFI_SSID=... ROOTFS_WIFI_PSK=... \
  bash build-rootfs.sh

# 3) 刷 boot + rootfs
fastboot flash boot boards/ufi00x/ufi103s-ufi003/boot/boot-venus-oc-100-gpu.img
fastboot -S 200M flash rootfs /path/to/rootfs.ext4
fastboot reboot
# 4) 首次开机后（镜像已带 x-systemd.growfs，无需手工 resize）

# 5) 主机连 RDP
xfreerdp /v:<IP> /u:root /p:<pw> /size:1280x800 /cert:ignore /sec:tls
```
