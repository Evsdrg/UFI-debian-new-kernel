# 硬件子系统文档

按子系统分册。每份都写清**能用什么、有什么硬限制、踩过什么坑**，
实测数据注明年份与内核版本；历史记录不等于当前承诺。

| 文档 | 内容 | 什么时候读 |
|---|---|---|
| [`FASTBOOT.md`](FASTBOOT.md) | fastboot 刷机全流程：进 fastboot、双分区、`-S` 分片、growfs、回退 | **刷机前必读** |
| [`NETWORK.md`](NETWORK.md) | NetworkManager 网络管理、中文化、rootfs 自动撑满 | 配网、改语言、查 NM 抢占问题 |
| [`DESKTOP.md`](DESKTOP.md) | i3 桌面、xrdp 远程桌面、Adreno 306 render-only GPU | 用桌面 / RDP / GPU 渲染 |
| [`GPU-STREAMING.md`](GPU-STREAMING.md) | GPU 合成 → Venus 硬编 → UDP 推流（含 `-force_key_frames` 关键坑） | 做推流、中途加入 |
| [`VIDEO-CODEC.md`](VIDEO-CODEC.md) | Venus 编解码实测：性能、画质、格式边界、坏素材误判 | 用硬编解码、选分辨率 |
| [`CPU-POWER.md`](CPU-POWER.md) | CPU 频率 / 电压 / 散热：1209.6 MHz 上限、降压不可行、热保护 | 调频、评估持续负载 |
| [`LED.md`](LED.md) | 三色状态灯的跨型号适配与灯语 | 灯不亮、改状态指示 |
| [`MF601SL.md`](MF601SL.md) | MF601SL_CT_V07 电池型 4G MiFi 的设备树三方对比与取值依据 | 适配 MF601SL、核对 GPIO |
| [`BLUETOOTH.md`](BLUETOOTH.md) | 蓝牙：为什么"没打开"、固件不用单独提供、实测 | 蓝牙扫描 / 配对 / 排错 |

## 几条最容易踩的硬限制（速查）

- **Venus 宽高必须 32 对齐**：1280×720、1920×1080 会崩；用 1280×736、1920×1088。
- **Venus 忽略 `-g`**：推流要用 `-force_key_frames` + `dump_extra`，否则中途加入失败。
- **Venus 没有 H.265 / VP9 硬解**；MPEG-4 硬解会触发固件 fatal（新旧内核均复现）。
- **GPU 只能分配 RGB 格式**：不能直接渲染 NV12 给 Venus，必须有一次颜色转换。
- **GPU 是 render-only**：`CONFIG_DRM_MSM_KMS=n` + `options msm separate_gpu_kms=1`，
  且 `MODULE_TREE` 必须用 `venus-4g-gpu` 那棵。
- **别 `rmmod venus` / `rmmod msm`**：remove 路径不健壮，只能重启恢复。
- **散热是持续负载的天花板**：满频约 45–160 秒到 80°C，不要宣称长稳满载。

完整的约束清单见根目录 [`CONTRIBUTING.md`](../../CONTRIBUTING.md)。
