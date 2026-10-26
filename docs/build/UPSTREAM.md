# 上游内核版本跟踪

## 2026-10-27 核查结果

当前项目基线是 **Linux 7.2.9**（上游提交 `5fce16164`）。
kernel.org stable 仓库已有 **Linux 7.2.13**（2026-10-26，提交 `3c172eede`）。

| 版本 | 日期 | 相对上一版的提交数 |
|---|---|---:|
| 7.2.10 | 2026-10-11 | 426 |
| 7.2.11 | 2026-10-15 | 285 |
| 7.2.12 | 2026-10-21 | 13 |
| 7.2.13 | 2026-10-26 | 232 |

`v7.2.9..v7.2.13` 共 **956 个提交**。

## 与本项目的关系

按当前平台相关路径筛选，有 17 个提交，主要涉及：

- IPv4/IPv6、TCP 与 netfilter 的稳定性修复
- USB gadget 的若干修复
- power supply 核心的回调生命周期修复

其中没有看到 `wcn36xx`、`msm8916` DTS、Qualcomm remoteproc/QRTR 或 Venus
的变更。USB gadget 的 `f_fs` 修复也不等于当前使用的 RNDIS 路径发生了变化。

因此，**7.2.13 不能被视为 WiFi 热点或现有平台问题的直接修复**；
升级价值主要是常规稳定与安全修复。

## 补丁兼容性预检

已在干净的 v7.2.13 工作树上按序实测，当前四个补丁全部可以套用：

1. `0001-wifi-wcn36xx-make-firmware-feat-caps-readable.patch`
2. `0002-wifi-wcn36xx-raise-max-medium-time-for-ht-tx.patch`
3. `0003-wifi-wcn36xx-add-cfg-override-diagnostics.patch`
4. `0005-venus-hfi1xx-encoder-fixes.patch`

这里只证明补丁能按序套用，**不代表 7.2.13 已完成构建或实机验证**。

## 升级建议

将 7.2.13 作为一次独立基线升级处理，不与热点、MF32 等功能改动混在同一轮：
先迁移配置并确认补丁，再重建全部板型，跑 QEMU、USB 交付断言和实机回归。
升级前保留当前 7.2.9 的已验证 boot、模块树和 rootfs，便于逐项对照。
