# 产物分发与对外协议

## 这一目录是什么

主仓库的 `artifacts/` **不跟踪**可刷镜像（`*.img` / `*.ext4` / 模块树，
见根 `.gitignore` 与 `artifacts/README.md`），但根目录
[`builds/`](../../builds/README.md) **跟踪**一份可直接分发的 7.2.9 boot 镜像集
与配套 `wcn36xx.ko`——那是全仓唯一入库的二进制产物，因为它们本身就是交付内容。

本目录（`docs/dist/`）放**面向其他机主**的说明：怎么测、怎么备份、怎么回报数据、
怎么自己重编，以及产物的可信度边界。工具在 [`tools/dist/`](../../tools/dist/)：

| 工具 | 用途 |
|---|---|
| `dump-nv.sh` | 导出本机的 WiFi 校准（NV）数据，刷机前务必备份 |
| `install-module.sh` | 在设备上安全替换 / 回滚 `wcn36xx.ko`（校验 vermagic） |
| `wifi-tx-test.sh` | 上行 / 下行速率测量，非破坏性 |
| `gen-manifest.sh` | 从目录里的文件重写 `builds/boot/*/build.json` |
| `gpt-backup.sh` | 按 OpenStick GPT 表把整片镜像拆成单分区文件，并可安全写回（默认只写 boot/rootfs/基带校准） |
| `check-repo.sh [内核树]` | 自检：脚本语法、补丁可应用性、产物哈希、文档链接 |

## 你能帮什么

本工程真机验证过的只有 **UFI103s（WCN3620）**。家族里其它板
（`ufi001b` / `ufi001c` / `sp970` / `uz801`）用的是 **WCN3660B**，共享同一张
配置表，但我们**没有这些硬件**——所以它们的结果正是我们需要的。

如果你手上有这类棒子，最有用的做法是跑一遍
[`TESTING.md`](TESTING.md) 里的非破坏性测试（替换一个模块，不写任何分区），
再按 [`report-template.md`](report-template.md) 把数据贴进 issue。

## 产物可信度

每个 `builds/boot/<variant>/build.json` 记录了该目录里每个文件的 sha256、
vermagic 与 cmdline，`check-repo.sh` 会比对。`status` 字段说明该产物到底被验证到
什么程度——**不要替它多声称**，这是这部分内容存在的全部理由。

各变体的实际刷入 / 测试状态见 [`builds/README.md`](../../builds/README.md) 的
「刷入状态」一节。

## 上游来源

设备树**不是**从零写的，派生自已确立的上游工作：

- **[HandsomeMod](https://github.com/HandsomeMod/HandsomeMod)** — OpenWrt BSP。
  它的 `target/linux/msm89xx/patches-5.10/0083-arm64-dts-add-support-for-Handsome-Openstick-Family.patch`
  加入了 `msm8916-handsome-openstick-common.dtsi` 与 `sp970` / `ufi001b` /
  `ufi001c` / `uz801` 的板级树，是本工程板级布局（LED GPIO、reset 键、SIM
  选择 / 使能线、eMMC）的来源。参考修订 `fa7f0be`（2022-10-01）。本仓不再单独
  分发设备树源码——它们已在主仓 `boards/` 与 `source/dts/`。
- **[OpenStick](https://github.com/OpenStick/OpenStick)** — MSM8916 棒子的逆向与
  mainline 移植工程。参考修订 `4be50db`（2022-05-27）。它的刷机包会重写分区表
  与 bootloader，所以经过它的棒子有已知分区布局。实际启动参数仍以
  各镜像 `build.json` 的 `cmdline` 为准，不能假定所有机器的 GPT 都相同。
- 产物内核：**Linux 7.2.9**。WiFi 修复是针对 mainline `wcn36xx` 的补丁。

## 自己重编一个产物

补丁是事实来源，`builds/` 里的产物只是它的一个输出。重编：

```sh
git clone --depth 1 -b v7.2.9 https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git
cd linux
git am /path/to/source/patches/0001-*.patch /path/to/source/patches/0002-*.patch
# 0003 是诊断用覆盖；0005 改的是 Venus，不属于 WiFi 修复
# 用 CONFIG_WCN36XX=m 编译；修复在模块里，不在内核镜像里
make modules
```

两个踩过的构建坑：

- 用整棵树的 `make modules`。目录目标（如
  `make drivers/net/wireless/ath/wcn36xx/`）只跑 `checksyscalls`，不会重新链接模块。
- 不要同时用 `make M=<dir>` 和 `O=<outdir>`：它会把对象写进**源码树**。事后清掉
  源码树里的游离 `.o` / `.ko`；手工删对象会截断 `Module.symvers` 并导致 `modpost`
  报 "undefined!"，跑一次完整 `make modules` 可恢复。

改完跑 `tools/dist/check-repo.sh <内核树>`，它会验证补丁仍能干净套用到 pristine
源码、且每个记录的哈希都对得上。

## 应用补丁

对着 pristine `linux-7.2.9` 树：

```sh
cd linux-7.2.9
git am /path/to/source/patches/0001-*.patch /path/to/source/patches/0002-*.patch
# 0003 仅诊断用，修复不需要它
# 0005 改 Venus，不属于 WiFi 测试
```

`0001` 与 `0002` 相互独立，各自能单独套用；两者都通过 `checkpatch.pl --strict`，
无 error 无 warning。

## 许可证与固件

内核补丁是 GPL-2.0-only，与其改动的文件一致。Qualcomm 固件与校准 blob **不**在
本仓再分发，它们来自你自己的设备。见根 `NOTICE` 与 OpenStick 关于固件许可的说明。

## 本目录的文档

| 文档 | 内容 |
|---|---|
| [`wifi-tx-throughput.md`](wifi-tx-throughput.md) | 上行速率 bug 的完整诊断、原始数据与参数扫描 |
| [`TESTING.md`](TESTING.md) | 给机主的非破坏性测试步骤（两种方案） |
| [`backup-and-restore.md`](backup-and-restore.md) | 刷机前必做的整片 eMMC 备份与恢复 |
| [`report-template.md`](report-template.md) | 回报数据用的填空模板 |
