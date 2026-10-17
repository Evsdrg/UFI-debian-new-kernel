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

当前 **7.2.9**，release 令牌 `KERNEL_LOCALVERSION=-ufix0x`（均来自
`source/kernel-version.env`）。

> **boot 分区仍是 7.1.13，7.2.9 已做 RAM 实机预演**：2026-10-10 对
> `venus-4g-gpu` 两次 `fastboot boot`，并实测正常重启回退；未刷 boot/rootfs。
> 后续USB修复已完成，NM/native的真实NAT已通过；持续负载散热与MPEG-4仍有
> 限制，暂不正式刷入。见 [`USB-FIX-7.2.9.md`](../../../docs/validation/USB-FIX-7.2.9.md)。
> 最新整机刷入验收见 [`VALIDATION-2026-10-16.md`](../../../docs/validation/VALIDATION-2026-10-16.md)；早期首轮验收记录（本地保留，不随仓库发布）。
> 6.18.49 与 7.1.13 的主机内核树/模块产物已清理，回退副本保留；设备旧模块未删。

## 产物

`dts/` — 5 个功能组合；`boot/` — 对应 boot 镜像 + 每个镜像的 `build.json` +
`board.dtb`。板型命名规则见 `CONTRIBUTING.md` §4.1：release =
`<版本>-ufix0x<板型后缀>-dirty`，后缀只写"有的功能"。

| boot 镜像 | DTS | 功能 | 配对模块树 |
|---|---|---|---|
| `boot-board-baseline-7.2.9.img` | `msm8916-handsome-openstick-ufi103s.dts` | WiFi/BT（4G 链与 venus 全关） | `7.2.9-ufix0x-dirty` |
| `boot-board-4g-7.2.9.img` | `…-ufi103s-4g.dts` | +4G | `7.2.9-ufix0x-4g-dirty` |
| `boot-board-venus-7.2.9.img` | `…-ufi103s-venus.dts` | +Venus | `7.2.9-ufix0x-venus-dirty` |
| `boot-board-venus-4g-7.2.9.img` | `…-ufi103s-venus-4g.dts` | +Venus +4G | `7.2.9-ufix0x-venus-4g-dirty` |
| `boot-board-venus-4g-gpu-7.2.9.img` | `…-ufi103s-venus-4g-gpu.dts` | +Venus +4G +GPU | `7.2.9-ufix0x-venus-4g-gpu-dirty` |

CPU 超频（三档 OPP + 85°C 被动冷却）已全员化进公共 dtsi，不再占板型名字；
早期那批频率变体（`oc12`、`venus-oc-100`、`venus-oc-burst` 等）已于 2026-09-16 收敛删除。

配套产物：

- rootfs：`artifacts/rootfs/ufi103s-7.2.9-<档>{,-native}.ext4`，共 7 张
  （max / basic / slim / micro × nm|native，见下）
- 模块：`artifacts/modules/7.2.9-ufix0x-*.dirty`
- 固件：`artifacts/firmware/ufi103s-venus/`（比 common 多 `qcom/venus-1.8/venus.mbn`）

**GPU 板型的模块树必须用 `-venus-4g-gpu` 那份**：render-only 模式需要
`separate_gpu_kms=1` 以及 `msm.ko`/`drm.ko`，而 `-venus`（无 gpu）树里没有它们，
拿错树构建 rootfs 会表现为 `/dev/dri` 静默缺失、渲染退回 llvmpipe。详见 `../../../docs/hardware/DESKTOP.md`。

## 实机状态

### 7.1.13（2026-09-14 实测，仍在 boot 分区的默认启动版）

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

### 7.2.9（2026-10-07 构建；2026-10-10 RAM 实测）

- 5 个板型内核 + boot 镜像 ✅（`tools/build-board-set.sh`）
- 7 个 rootfs 的 QEMU 冒烟 ✅；不是实机全功能验收。
- 仅 `venus-4g-gpu` 做了 RAM 实机测试：WiFi、USB 直连、GPU、H.264/VP8、xrdp、
  蓝牙扫描、存储与内存校验通过；4G 仅到 `sim-missing`。
- USB NAT ✅：公共nft依赖、NM管理权/包及gadget/native生命周期已修复，
  两栈实测客户端经棒子出网；新镜像整机与Windows/macOS兼容性未测。
- 满频压力、持续推流 ⚠️：80°C 测试保护中止；800MHz 限频校验通过，之后已恢复。
- MPEG-4 硬解 ❌：两版内核同样触发 Venus 固件 fatal；只能重启恢复，不卸载模块。
- 当前 DTS 的 CPU OPP 为 200/400/800/998.4/1094.4/**1152/1209.6 MHz**。
- 其它 4 个变体及 7 个新 rootfs 的实机矩阵未测；正式 flash 未执行。

## 升级到 7.2.9（RAM 预演已执行，正式刷入暂缓）

改动只在 boot 分区，rootfs 不必重刷（模块以新增目录方式装入，旧目录保留）。
但 **7.2.9 与 7.1.13 的 vermagic 不同**，所以第 1 步必须先把新模块推上设备，
否则预演启动时模块会全部静默失配：

```sh
# 1) 主机：模块推到设备（纯新增，不动现有模块）
tar -C artifacts/modules/7.2.9-ufix0x-venus-4g-gpu-dirty/lib/modules \
    -czf /tmp/m.tar.gz 7.2.9-ufix0x-venus-4g-gpu-dirty
scp /tmp/m.tar.gz root@<设备>:/tmp/ && \
  ssh root@<设备> 'cd /lib/modules && tar xzf /tmp/m.tar.gz && depmod -a 7.2.9-ufix0x-venus-4g-gpu-dirty'

# 2) 内存预演：不写 boot flash，但启动失败仍可能需要物理复位
#    无可靠串口时，参考 CONTRIBUTING.md 的串口与 SysRq 注意事项。
ssh root@<设备> 'systemctl reboot --reboot-argument=bootloader'
fastboot boot artifacts/boot/ufi103s-ufi003/boot-board-venus-4g-gpu-7.2.9.img
#    启动后 uname -r 即为 7.2.9；验完直接重进 fastboot 即可，flash 未被改动
#    预演失败也不会影响设备——boot 分区上仍是 7.1.13

# 3) 正式刷入（当前暂停；先解决验收报告中的阻塞项）
bash flash.sh fastboot-flash boot \
  artifacts/boot/ufi103s-ufi003/boot-board-venus-4g-gpu-7.2.9.img
fastboot continue
```

### 回退

主机上已经没有旧内核树了，回退靠分区读回（**不可再生**，别删）：

| 目标 | 镜像 | 说明 |
|---|---|---|
| 本次升级前整分区 | `out/rollback/20261010/boot-p12-before.bin` | 64MiB p12 读回；本次各阶段散列一致，回退启动已验证 |
| 回到 7.1.13 | `out/rollback/boot-7.1.13-as-flashed-28e0902f.img` | 历史 boot 镜像读回；设备上保留 7.1.13 模块目录 |
| 回到 6.18.49 | `out/rollback/boot-backup-6.18-gpu.img` | 6.18 的 boot；其模块树已从主机清理，设备上是否留有需实机确认 |
| 原厂 boot | `recovery/original/boot-original-p12.img` | 出厂读回 |
| 分区级全量 | `recovery/backups/{boot,rootfs}-*.bin` | 6.18.49 时代 p12/p14 的读写前后读回 |

刷回：`fastboot flash boot <img>` 后 `fastboot continue`。

## rootfs 镜像（7 个矩阵档）

`tools/build-matrix.sh` 一次产出全部 7 张，配对关系写在脚本里：

| 镜像 | 档位 | 网络栈 | 配对内核/模块树 |
|---|---|---|---|
| `ufi103s-7.2.9-max.ext4` | max | NM | `7.2.9-ufix0x-venus-4g-gpu-dirty`（+ 基线树随镜像附带） |
| `ufi103s-7.2.9-basic.ext4` | basic | NM | `7.2.9-ufix0x-4g-dirty` |
| `ufi103s-7.2.9-basic-native.ext4` | basic | native | 同上 |
| `ufi103s-7.2.9-slim.ext4` | slim | NM | `7.2.9-ufix0x-dirty` |
| `ufi103s-7.2.9-slim-native.ext4` | slim | native | 同上 |
| `ufi103s-7.2.9-micro.ext4` | micro | NM | 同上 |
| `ufi103s-7.2.9-micro-native.ext4` | micro | native | 同上 |

体积、四个正交开关、精简档位的取舍见 `../../../docs/build/TRIMMING.md`；矩阵定义见 `../../../docs/build/BUILD-MATRIX.md`。

**镜像不预置 Wi-Fi**（刻意的）。刷入后首次进系统走 USB RNDIS（插电脑即得
`10.42.0.1` 并 DHCP），再用 `nmtui` / `nmcli` 配无线。原因见
`../../../docs/ISSUES.md` 第 15 条。

构建只需指定 root 口令（不传则镜像里 root 无口令）：

```sh
# 口令从 .local-creds 的 ROOTFS_ROOT_PASSWORD 自动取，无需显式传
bash tools/build-matrix.sh
```

两个易踩点：`MMDEBSTRAP_FORMAT=ext4` 不写的话只产出目录树（脚本默认
`directory`；`build-matrix.sh` 已代设）；`TMPDIR` 若落在小容量的 tmpfs 上会在装
桌面包时 "No space left on device"（本机 `/tmp` 就是 11G tmpfs，需指到大盘上）。

## 刷机前

**必须先用 Miko 做整片 eMMC 全量备份**，再刷任何分区。只动 `boot` 与
`rootfs`，不动 GPT、aboot、modem、NV。注意这条备份目前**无法脚本化**
（Miko 是 Windows GUI 工具），仓库里能依赖的是上面那张分区级读回表。

原始 boot 分区读回单份保存在 `recovery/original/boot-original-p12.img`。

刷机命令与坑见 `../../../docs/hardware/FASTBOOT.md`；rootfs 刷机用 `-S 200M` 分片（LK 的
`max-download-size` 只有 256 MB）。
