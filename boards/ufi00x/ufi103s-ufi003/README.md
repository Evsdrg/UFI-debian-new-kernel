# UFI103s / UFI003

本工作区的**主力机型**，也是唯一插过真机的板子。WiFi 为 WCN3620，
与同家族其它成员（WCN3660b）不同。

设备树标识（每型专属，用于区分型号）：

- `model` = `Handsome OpenStick UFI103s (UFI003)`（UFI103s 与 UFI003 是同一块板的两种叫法）
- `compatible` = `handsome,ufi103s`, `qcom,msm8916`

> 历史上五块板共用 `compatible = "handsome,openstick"`，只能靠 `model` 区分。
> 2026-09-14 起每型用自己的 compatible（上游同族如 `thwc,ufi001c` 也是这个约定），
> 这样 udev/脚本可以直接按 compatible 认板而不必解析 model 字符串。

## 内核版本

当前 **7.1.13**（`KERNEL_RELEASE=7.1.13-ufi003-venus-dirty`）。
版本号由 `source/kernel-version.env` 统一管理，脚本从它派生路径；
6.18.49 的树与产物原样保留作回退（把 `KERNEL_VERSION` 改回 6.18.49 即可）。

## 产物

`dts/` — 7 个设备树变体；`boot/` — 对应 boot 镜像 + `board.dtb`。

带 `-7.1.13` 的是当前内核；不带版本号的是 6.18.49 时期的产物（保留作回退）。

| boot 镜像 | DTS | 用途 | 内核 |
|---|---|---|---|
| `boot-venus-oc-100-gpu-7.1.13.img` | `ufi103s-venus-oc-100-gpu.dts` | **已交付配置**：Venus + ~100MHz 频率表 + Adreno GPU | 7.1.13 |
| `boot-venus-oc-100-7.1.13.img` | `ufi103s-venus-oc-100.dts` | Venus + 约 100 MHz 粒度频率表 | 7.1.13 |
| `boot-venus-oc-burst-7.1.13.img` | `ufi103s-venus-oc-burst.dts` | Venus + burst 策略 | 7.1.13 |
| `boot-venus-oc12-7.1.13.img` | `ufi103s-venus-oc12.dts` | Venus + 频率档 1094.4/1152/1209.6 | 7.1.13 |
| `boot-venus-7.1.13.img` | `ufi103s-venus.dts` | Venus 基线频率（200/400/800/998.4） | 7.1.13 |
| `out/boot-7.1.13/boot-ufi103s-7.1.13-baseline.img` | `ufi103s.dts` | 无 Venus 的纯基线 | 7.1.13 |
| `out/boot-7.1.13/boot-ufi103s-7.1.13-oc12.img` | `ufi103s-oc12.dts` | 基线 + 频率档 | 7.1.13 |
| `boot-venus-oc-100-gpu-6.18.49.img` | 同上 | 6.18.49 的 GPU 变体（回退用） | 6.18.49 |
| `boot-venus*.img`（无版本号） | 同上 | 6.18.49 时期产物 | 6.18.49 |

配套产物：

- rootfs：`shared/rootfs/debian13-arm64-ufi103s-<版本>-venus.ext4`（Venus/GPU 变体）
  或 `...-<版本>.ext4`（基线）
- 模块：`shared/modules/<版本>-ufi003-venus/`（Venus）、`...-ufi003-gpu/`（GPU）、
  `...-ufi003-dirty/`（基线）
- 固件：`shared/firmware/ufi103s-venus/`（比 common 多 `qcom/venus-1.8/venus.mbn`）

**GPU 变体的模块树必须用 `-gpu` 那份**：render-only 模式需要 `separate_gpu_kms=1`
以及 `msm.ko`/`drm.ko`，而 `-venus` 树里没有它们。详见 `DESKTOP.md`。

## 实机状态（7.1.13，2026-09-14 实测）

- 启动 ✅：`uname -r` = `7.1.13-ufi003-venus-dirty`，型号与 compatible 正确；
  开机日志 0 error（仅一条 PSCI `failed to set PC mode` 固件报告，6.18 时期就有）。
- GPU ✅：`/dev/dri/renderD128`，`DRIVER=adreno`，`GL renderer: FD307`。
- Venus ✅：硬编 90 帧产 502824 字节；硬解正常（H.264；无 HW H.265/VP9）。
- WiFi ✅：`wlan0` 连接正常（WCN3620，含上行速率修复）。
- 4G ✅：remoteproc1 加载 mpss，`wwan0-7` 建出，ModemManager 识别 `modem0`
  （状态 `sim-missing` —— 未插 SIM，与 6.18 行为一致）。`qrtr-ns`/`rmtfs` 均 active。
- 推流 ✅：GPU 合成 → Venus 硬编 → MPEG-TS/UDP，27 fps，见 `GPU-STREAMING.md`。
- 并发 ✅：GPU 合成 + Venus 硬编同时跑 0 内核错误；CPU 压测 30s 无 thermal 异常
  （47→69°C）。
- CPU 频率：档位 200/400/800/998.4/1094.4/1209.6/1401.6 MHz 齐全；
  实测约 1209.6 MHz 后无收益，降压不可行（电压由 PSCI 固件掌控）。

## 升级到 7.1.13 的过程（可复现）

改动只在 boot 分区，rootfs 无需重刷（模块以新增目录方式装入，旧的 6.18 模块保留）：

```sh
# 1) 主机：模块推到设备（纯新增，不动现有模块）
tar -C shared/modules/7.1.13-ufi003-gpu/lib/modules -czf /tmp/m.tar.gz 7.1.13-ufi003-venus-dirty
scp /tmp/m.tar.gz root@<设备>:/tmp/ && ssh root@<设备> 'cd /lib/modules && tar xzf /tmp/m.tar.gz && depmod -a'

# 2) 零风险预演：从内存启动，完全不写 flash
ssh root@<设备> 'systemctl reboot --reboot-argument=bootloader'
fastboot boot boards/ufi00x/ufi103s-ufi003/boot/boot-venus-oc-100-gpu-7.1.13.img
#    启动后 uname -r 即为 7.1.13；验完直接重进 fastboot 即可，flash 未被改动

# 3) 正式刷入
bash flash.sh fastboot-flash boot boards/ufi00x/ufi103s-ufi003/boot/boot-venus-oc-100-gpu-7.1.13.img
fastboot continue
```

**回退**：把任意 6.18.49 的 boot 镜像刷回 p12 即可（例如
`boot-venus-oc-100-gpu-6.18.49.img`）。6.18 的模块树仍在设备上，所以回退后
WiFi/Venus 等功能立即恢复。设备 boot 分区的完整读回副本在
`out/rollback/boot-backup-6.18-gpu.img`。

## 刷机前

**必须先用 Miko 做整片 eMMC 全量备份**，再刷任何分区。只动 `boot` 与
`rootfs`，不动 GPT、aboot、modem、NV。

原始 boot 分区读回单份保存在 `recovery/original/boot-original-p12.img`。
