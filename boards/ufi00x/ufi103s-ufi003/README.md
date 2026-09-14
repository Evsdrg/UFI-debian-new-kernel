# UFI103s / UFI003

本工作区的**主力机型**，也是唯一插过真机的板子。WiFi 为 WCN3620，
与同家族其它成员（WCN3660b）不同。

## 产物

`dts/` — 6 个设备树变体；`boot/` — 6 个对应 boot 镜像 + `board.dtb`。

| boot 镜像 | DTS | 用途 | 内核版本 |
|---|---|---|---|
| `boot-baseline.img` | `ufi103s.dts` | 基线频率（200/400/800/998.4 MHz） | `6.18.49-ufi003-dirty` |
| `boot-oc12.img` | `ufi103s-oc12.dts` | 频率档 1094.4/1152/1209.6 MHz | `6.18.49-ufi003-dirty` |
| `boot-venus.img` | `ufi103s-venus.dts` | 基线 + Venus 硬编解码 | `6.18.49-ufi003-venus-dirty` |
| `boot-venus-oc12.img` | `ufi103s-venus-oc12.dts` | Venus + 频率档 | `6.18.49-ufi003-venus-dirty` |
| `boot-venus-oc-100.img` | `ufi103s-venus-oc-100.dts` | Venus + 约 100 MHz 粒度频率表 | `6.18.49-ufi003-venus-dirty` |
| `boot-venus-oc-burst.img` | `ufi103s-venus-oc-burst.dts` | Venus + burst 策略（**已交付配置**） | `6.18.49-ufi003-venus-dirty` |

`boot-venus*.img` 需要配套的 venus rootfs 和模块树：

- rootfs：`shared/rootfs/debian13-arm64-ufi103s-6.18.49-venus.ext4`
  
- 模块：`shared/modules/6.18.49-ufi003-venus/`
- 固件：`shared/firmware/ufi103s-venus/`（比 common 多 `qcom/venus-1.8/venus.mbn`）

基线镜像配 `shared/rootfs/debian13-arm64-ufi103s-6.18.49.ext4` +
`shared/modules/6.18.49-ufi003-dirty/` + `shared/firmware/common/`。

## 一个需要注意的不一致

同目录下各 `build.json` 记录的 cmdline 有两种：

- `boot-baseline.img` / `boot-oc12.img` 的 `build.json`：
  `root=PARTLABEL=rootfs`
- `boot-venus*.img` 的 `*-build.json`：
  `root=PARTUUID=a7ab80e8-e9d1-e8cd-f157-93f69b1d141e`

两种都能启动（实机早期用 PARTUUID，后改用 PARTLABEL），但同一目录下混用
容易误判。**刷机前务必以实际要刷的那个镜像的 json 为准**，不要凭印象。

## 实机状态

- 已验证：启动、SSH、WiFi（含上行速率修复）、4G、SMS、zram、QRTR/rmtfs、
  ModemManager、systemd-networkd + wpa_supplicant、看门狗、监管域 CN。
- CPU 频率：实测约 1209.6 MHz 后无收益（1401.6 MHz 零增益）；降压不可行
  （电压由 PSCI 固件掌控）。
- Venus 硬编解码：已跑通（H.264 编解码；无 HW H.265/VP9 解码）。

## 刷机前

**必须先用 Miko 做整片 eMMC 全量备份**，再刷任何分区。只动 `boot` 与
`rootfs`，不动 GPT、aboot、modem、NV。

原始 boot 分区读回单份保存在 `recovery/original/boot-original-p12.img`。
