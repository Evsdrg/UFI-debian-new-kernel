# 工具与脚本：现状与缺口

本文件回答「工作区还需要哪些工具或脚本」。**下面「缺口」一节列的都是尚未
存在的东西**，不是已完成的工作。

## 已有（可用）

### 构建

| 脚本 | 用途 |
|---|---|
| `source/kernel-version.env` | **内核版本单一事实来源**：升级内核只改这里 |
| `tools/kver.sh` / `tools/kver.py` | 版本派生的 shell / Python 实现（其余脚本 source/import 它们） |
| `build-rootfs.sh` / `tools/build-rootfs-common.sh` | 用 mmdebstrap 构建 Debian 13 arm64 rootfs（unshare 模式 + qemu-user） |
| `tools/build-kernel-variant.sh` | 从权威源码树构建内核变体（支持多片段叠加，如 venus+gpu） |
| `tools/build-board-set.sh` | 板型级构建：5 个功能组合的内核 + 模块树 + boot 镜像（表驱动，缺省只建未完成的） |
| `tools/build-boot-images.sh` | 编译板级 DTS 并组装 boot 镜像（非 ufi103s 板出镜像用；语法与静态路径有效，7.2.9 未实机验证） |
| `tools/package-boards.py` | 按 `boards/<家族>/<机型>/` 打包各板 boot 镜像 |
| `tools/package-boot-variant.py` | 打包 ufi103s 的 boot 变体 |

版本相关的一切都从 `source/kernel-version.env` 派生，脚本里不再硬编码版本号；
换版本用环境变量覆盖即可（如 `KERNEL_VERSION=... bash tools/build-board-set.sh`）。
构建目录与产物名都带版本号，所以不同版本的内核镜像不会互相覆盖。
注意 6.18.49 / 7.1.13 的内核树已于 2026-10-07 清理，现在只剩 7.2.9 一棵，
**旧版本不再能重建**。

### 刷机与设备访问

| 脚本 | 用途 |
|---|---|
| `flash.sh` | `boot` 经 SSH 刷 boot；`enter-fastboot` 重启进 LK fastboot；`fastboot-flash <boot\|rootfs> <img>` 带 sha256 校验刷写；`fastboot-reboot` 回正常启动 |
| `tools/ufi-console.sh` | 有界串口控制台（`id` / `read` / `send`） |
| `edl-tools/` | EDL / Firehose / Miko 工具链（`qdl`、`edl.py` 等） |

见 `FASTBOOT.md`：本设备可以在 Linux 里
`systemctl reboot --reboot-argument=bootloader` 直接进 fastboot（内核 qcom-pon
驱动 + OpenStick LK 全链路，已实机验证）。注意必须用 `--reboot-argument=`。

### 桌面 / 远程桌面

| 资产 | 用途 |
|---|---|
| `tools/desktop/xsession` | xrdp 会话入口（设中文 locale 后 exec i3） |
| `tools/desktop/i3-config` | i3 预置配置（窗口/工作区/状态栏） |
| `tools/desktop/gpu-status.sh` / `zh-check.sh` | 桌面里排错用的小窗口 |
| `tools/desktop/ufi-stream-push.sh` | 设备端：GPU 合成 → Venus 硬编 → MPEG-TS/UDP（`stop` 停链） |
| `tools/desktop/ufi-stream-clock.sh` | 推流时放在桌面的实时时钟（用于验证实时性） |
| `tools/desktop/ufi-stream-play.sh` | 接收端：自动探测 Wayland/X11 会话并全屏播放 |
| `tools/msm-gpu-render-only.conf` | `options msm separate_gpu_kms=1` |
| `source/configs/ufi103s-gpu.config` | GPU 内核片段（显式关掉显示后端） |

见 `DESKTOP.md`。构建 rootfs 时 `ROOTFS_DESKTOP=0` 可做纯服务端镜像。
`GPU-STREAMING.md` 是「GPU 渲染桌面 + Venus 推流」的完整方案与实测（已端到端跑通）。

### 测试与验证

| 脚本 | 用途 |
|---|---|
| `tools/verify-layout.sh` | 工作区布局与产物自检 |
| `tools/venus-test.sh` / `venus-transcode.sh` | Venus 硬编解码验证与转码 |
| `tools/wcn36xx-cfg-sweep.sh` 等 3 个 | WiFi 固件参数 / 速率扫描 |
| `tools/cpu-freq-verify.sh` / `cpu-power-tradeoff.sh` | CPU 频率与功耗验证 |
| `tools/ufi-led-state.sh`（+ `.service`、`.default`） | 三色 LED 状态指示，**机型通用**（见 `LED.md`） |

### 在分发仓（不在本工作区，属正常分工）

`ufi00x-mainline/tools/`：`check-repo.sh`（自检）、
`gen-manifest.sh`（哈希清单）、`install-module.sh`（模块安装/回滚）、
`wifi-tx-test.sh`（吞吐测试）、`dump-nv.sh`（NV 导出）。

## 缺口（尚未存在）

按重要性排列。前两项直接关系到「给别人刷机」这件事能不能安全落地。

**1. 全片 eMMC 备份的脚本化辅助**
要求刷机者「先用 Miko 做全量备份」，但 Miko 是 Windows GUI 工具
（`edl-tools/Miko/miko_service_tool_pro.7z`），没有任何脚本或文档化的命令行
路径。结果是：备份这一步完全依赖对方正确操作 GUI，我们无法校验、无法复现、
也无法在文档里给出可照抄的命令。**这是当前最大的缺口。**

**2. 刷机包组装脚本**
`package-boards.py` 只产出 boot 镜像。要发布「某机型的刷机包」，还需要把
该板 boot 镜像 + 共享 rootfs + 说明文档 + 校验清单打成一个可下载的包。
目前是手工拼的，没有脚本。这是面向「给别人刷机」最缺的一块。

**3. 刷机前的镜像校验**
`flash.sh fastboot-flash` 现在会比对同目录 `build.json` 里记录的 sha256，不一致
就拒绝刷入——这正好防住一个真实隐患：核对 `build.json` 才发现 UFI103s 目录里
cmdline 有 PARTUUID/PARTLABEL 两种混用（见
`boards/ufi00x/ufi103s-ufi003/README.md`）。刷错变体以前不会报错，现在会。
注意 `fastboot-rootfs` 那个旧接口仍不校验。

**4. 串口自动探测**
`tools/ufi-console.sh` 默认写死 `/dev/ttyACM0`（可用环境变量覆盖）。本项目里
该设备重新插拔后串口名变过（`ttyUSB0` ↔ `ttyACM0`），每次都要人工确认。
一个按 USB VID:PID 自动定位的辅助会省事，但不是必须。

**5. 板间 DTS 差异快速比对**
`boards/README.md` 里那张家族差异表是临时手写 diff 得出的。要加新机型时
（判断能否复用 DTB），值得有个一行命令的比对脚本。

**6. ~~LED 镜像新旧不一致~~（已解决）**
`shared/rootfs/` 里原先是三张不同时期构建的镜像，内容不一致（旧的没装 LED、
没 NetworkManager、没中文）。现由 `tools/build-matrix.sh` 一次产出全部 7 张
同源镜像（`ufi103s-7.2.9-{max,basic,slim,micro}{,-native}.ext4`），都带通用
LED 脚本 + fstab 的 `x-systemd.growfs`（网络栈按档位是 NM 或 networkd）。
旧的 `debian13-arm64-ufi103s-*` 命名与它们的归档副本已随 2026-10-07 的
旧内核清理移除。

## 不建议做的

- **不要给 LED 加软件 PWM**：实测软件 PWM 会带来约 +101 次/秒的深空闲退出
  （13118 vs 3007 per 100 s，用 cpuidle state1 计数测出），已改用 CPU 负载档位。
  完整研究记录见 `WORKSPACE-INDEX.txt` 的 “LED status research” 一节。
- 不要把内核树、产物、备份塞进 git：已在 `.gitignore` 里排除。
