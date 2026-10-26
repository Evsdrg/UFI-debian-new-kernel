# UFI103s / UFI003

本工作区的**主力机型**，也是唯一插过真机的板子。WiFi 为 WCN3620，
与同家族其它成员（WCN3660b）不同。

设备树标识（每型专属，用于区分型号）：

- `model` = `Handsome OpenStick UFI103s (UFI003)`（UFI103s 与 UFI003 是同一块板的两种叫法）
- `compatible` = `handsome,ufi103s`, `qcom,msm8916`


## 内核版本

当前 **7.2.9**，release 令牌 `KERNEL_LOCALVERSION=-ufix0x`（均来自
`source/kernel-version.env`）。

> **刷入状态（2026-10-17）**：p12 与 p14 均已刷为 7.2.9：
> boot 为 `boot-board-venus-4g-gpu-7.2.9.img`，rootfs 为 max 档，
> 从闪存启动后自动开放 USB RNDIS。`minimal` 变体也已通过内存启动验证。
> 验收范围见 [`2026-10-16-validation.md`](../../../docs/validation/2026-10-16-validation.md)。
> 刷前分区备份保存在本机 `out/flash-20261016/`，不随仓库发布。

## 产物

`dts/` 放设备树源码，boot 镜像与元数据由构建脚本写入 `artifacts/boot/`。
板型命名规则见 `CONTRIBUTING.md` §4.1：release =
`<版本>-ufix0x<板型后缀>-dirty`，后缀只写"有的功能"。

| boot 镜像 | DTS | 功能 | 配对模块树 |
|---|---|---|---|
| `boot-board-baseline-7.2.9.img` | `msm8916-handsome-openstick-ufi103s.dts` | WiFi/BT（4G 链与 venus 全关） | `7.2.9-ufix0x-dirty` |
| `boot-board-4g-7.2.9.img` | `…-ufi103s-4g.dts` | +4G | `7.2.9-ufix0x-4g-dirty` |
| `boot-board-venus-7.2.9.img` | `…-ufi103s-venus.dts` | +Venus | `7.2.9-ufix0x-venus-dirty` |
| `boot-board-venus-4g-7.2.9.img` | `…-ufi103s-venus-4g.dts` | +Venus +4G | `7.2.9-ufix0x-venus-4g-dirty` |
| `boot-board-venus-4g-gpu-7.2.9.img` | `…-ufi103s-venus-4g-gpu.dts` | +Venus +4G +GPU | `7.2.9-ufix0x-venus-4g-gpu-dirty` |
| `boot-board-minimal-7.2.9.img` | 同 baseline DTS | WiFi + USB 共享 + zram，裁内核配置 | `7.2.9-ufix0x-minimal-dirty` |


配套产物：

- rootfs：`artifacts/rootfs/ufi103s-7.2.9-<档>{,-native}.ext4`，共 7 张
  （max / basic / slim / micro × nm|native，见下）
- 模块：`artifacts/modules/7.2.9-ufix0x-*.dirty`
- 固件：`artifacts/firmware/ufi103s-venus/`（比 common 多 `qcom/venus-1.8/venus.mbn`）

**GPU 板型的模块树必须用 `-venus-4g-gpu` 那份**：render-only 模式需要
`separate_gpu_kms=1` 以及 `msm.ko`/`drm.ko`，而 `-venus`（无 gpu）树里没有它们，
拿错树构建 rootfs 会表现为 `/dev/dri` 静默缺失、渲染退回 llvmpipe。详见 `../../../docs/hardware/DESKTOP.md`。

## 实机状态

### 7.2.9 实测范围

- `venus-4g-gpu` 已整机刷入并验证 USB 共享、WiFi、GPU、H.264/VP8、xrdp、
  蓝牙和存储；4G 仅验证驱动与控制通道，未插 SIM。
- `minimal` 已通过内存启动验证：WiFi、USB NAT、zram、LED 和 Reset 键。
- 持续满载与推流受散热限制；MPEG-4 硬解会触发 Venus 固件 fatal。
- 当前 DTS 的 CPU OPP 为 200/400/800/998.4/1094.4/1152/1209.6 MHz。
- 完整结果见 `../../../docs/validation/2026-10-16-validation.md`。

## 升级 / 刷入与回退

改动内核时，rootfs 可以只增加新 release 的模块目录，不必重刷整个分区。
但**内核与模块树必须属于同一 release**，否则预演启动时模块会因 vermagic
不匹配而拒绝加载：

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
#    预演失败也不改 boot 分区（但若早期硬挂死，仍需物理断电恢复）

# 3) 正式刷入（2026-10-16 已执行并验收，见上「内核版本」）
bash flash.sh fastboot-flash boot \
  artifacts/boot/ufi103s-ufi003/boot-board-venus-4g-gpu-7.2.9.img
fastboot continue
```

### 回退

回退使用刷前保存的分区读回副本（**不可再生**，不要删除）：

| 用途 | 位置 |
|---|---|
| 升级前 p12 | `out/rollback/20261010/boot-p12-before.bin` |
| 原厂 boot | `recovery/original/boot-original-p12.img` |
| 其它分区备份 | `recovery/backups/`、`out/flash-20261016/` |

这些是本机备份路径，不随公开仓库分发。刷回：
`fastboot flash boot <img>` 后 `fastboot continue`。

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
