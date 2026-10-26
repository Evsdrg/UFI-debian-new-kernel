# 测试指南

有两种测试方式，取决于你愿意对设备做多大改动。

**方案 A** 在一个已经能启动的系统上替换一个内核模块。不写任何分区、不碰
bootloader，回滚也只是一条命令。**从这里开始。**

**方案 B** 刷入 `builds/` 里的 boot 镜像。只有在方案 A 不可行时才考虑，
而且先读[`刷机警告`](../../builds/README.md)——特别是：rootfs 里的 WiFi 校准
blob 是从**另一台实体设备**导出的。

两种方式回答的是同一个问题：**把 `MAX_MEDIUM_TIME` 调大，能否让这块网卡的
发射速率恢复正常？**

## 我们需要你提供什么

最有价值的结果是**同一台设备、同一个 AP、同一个位置的前后对照**。
如果你只能给"之后"的数据，请注明——它仍然有用，只是说服力弱一些。

请回报：

1. 板型（`ufi001b`、`sp970`……）以及测试输出里的 `wifi_chip=` 那一行。
2. 每种状态下 `tools/dist/wifi-tx-test.sh` 的完整输出块。
3. 方案 A 需要**换模块前**与**换模块后**的两组数字。
4. 如果你拿得到驱动源码，请给出你默认的 `MAX_MEDIUM_TIME` 值（见下）；
   否则给出驱动版本即可。

贴到 issue 里即可。输出本身就是 key=value 行，不需要再排版。

## 快速自查：你的驱动用的是哪个值？

如果你有内核源码或编出来的模块，可以这样判断你的树是否已修复：

```sh
grep -n MAX_MEDIUM_TIME drivers/net/wireless/ath/wcn36xx/smd.c
```

里面有两张表：WCN3620/WCN3660B 一张，WCN3680 一张。

| 你看到的 | 含义 |
|---|---|
| 第一张表里 `MAX_MEDIUM_TIME, 6000` | 未修复——这就是那个 bug |
| 第一张表里 `MAX_MEDIUM_TIME, 20000` | 修复已应用 |
| 第二张表里 `MAX_MEDIUM_TIME, 4096` | WCN3680 的表，与本问题无关 |

## 方案 A —— 换模块，不刷机

你需要：棒子上一个能正常工作的系统、与之匹配的内核源码（或能单独编出一个
模块的环境），以及另一台装了 `iperf3` 的机器做测量对端。

### 1. 先测"之前"的状态

对端机器上：

```sh
iperf3 -s
```

棒子上，把 `tools/dist/wifi-tx-test.sh` 拷过去运行：

```sh
./wifi-tx-test.sh <对端IP> 10
```

保留这份输出。

### 2. 编译并安装修复后的模块

把修复打到你的内核树上，重新编译驱动。两件事必须注意，都是踩过的坑：

- 用整棵树的 `make modules`。目录目标（例如
  `make drivers/net/wireless/ath/wcn36xx/`）只跑 `checksyscalls`，**不会重新链接**模块。
- 用 `O=` 构建时不要加 `make M=<dir>`；它会把对象文件写进**源码树**。

```sh
cd linux-<你的版本>
git am /source/patches/0001-*.patch /source/patches/0002-*.patch
make <你现有的 defconfig 目标>       # 保持当前配置
make modules
```

或者，如果你只是想先试这个值、还不想正式打补丁，可以只打 `0003`，
在加载时传参——它提供了 `cfg_override` 参数：

```sh
# 只打了 0003 的情况下
modprobe wcn36xx cfg_override="9=20000"
```

注意 `cfg_override` 只在模块加载时生效：固件在 MAC 启动时锁存配置，
所以改值后需要重新 `modprobe`（或让链路 down/up 一次）。
打了补丁的默认值同理。

### 3. 安装

模块在构建树的 `drivers/net/wireless/ath/wcn36xx/wcn36xx.ko`。
替换系统里那份并重建模块索引：

```sh
cp wcn36xx.ko /usr/lib/modules/$(uname -r)/kernel/drivers/net/wireless/ath/wcn36xx/
depmod -a
reboot
```

保留被替换的原模块——回滚就是把它拷回去再重启。

模块只有在 `vermagic` 与运行中的内核完全一致时才会加载。
替换前后都用 `modinfo -F vermagic wcn36xx` 核对。

### 4. 测"之后"的状态

与第 1 步相同的命令。上行应从约 5–8 Mbit/s 升到约 40–50 Mbit/s，
`rate_during_upload` 应从 `MCS 0` 变为 `MCS 4` 或更高。下行应基本不变。

如果没有改善，这也是一个有效且有意思的结果——请连测试输出一起回报。
那意味着 WCN3660B 的行为与我们发现此修复的 WCN3620 不同，
而这正是我们想确认的情况。

### 回滚

```sh
cp <你的备份>/wcn36xx.ko /usr/lib/modules/$(uname -r)/kernel/drivers/net/wireless/ath/wcn36xx/
depmod -a
reboot
```

## 方案 B —— 刷 boot 镜像

只在方案 A 不可行时使用。刷机会写引导链，而 eMMC 上有一部分数据是
**每台设备独有、任何镜像都无法重建**的，所以：

### 0. 先做整片备份——这是硬性要求，不是建议

读 [backup-and-restore.md](backup-and-restore.md) 并照做。简单说：在写任何东西
之前，用 Miko 把整个 eMMC 读成一个镜像（约 3.9 GB）。
`modemst1` / `modemst2` / `fsg` / `fsc` 这几个分区存的是**这台设备**的 modem
校准数据；覆盖掉，4G 就永久失效，任何我们能提供的镜像都救不回来。
**不要跳过这一步，也不要跳过刷前对备份文件大小的核对。**

刷之前还要：

1. 看 `builds/boot/<variant>/` 里镜像旁边的 `build.json`。
   `status` 字段写明了这份产物到底验证到哪一步，`cmdline` 里是某个 rootfs
   的 PARTUUID。**不要超出它所说的范围去假设。**
2. 同时导出你自己的 WiFi 校准：
   `tools/dist/dump-nv.sh` 会保存你这台的 `WCNSS_qcom_wlan_nv.bin`。
   随镜像的 rootfs 里那份来自别的设备，可能让你根本没有 WiFi。
   （这与 eMMC 备份是两件事，文件小得多，但属于同一类"每台不同"的问题。）
3. 注意 WiFi 修复**不在**任何 boot 镜像里——它是内核模块，
   只刷 boot 不会改变你的上行速率。见[分发产物说明](../../builds/README.md)。

## 怎么看这些数字

判断结果时的参考：

| 观察到的现象 | 解读 |
|---|---|
| 上行 ~5–8 Mbit/s，tx `MCS 0` | 未修复的表现 |
| 上行 ~40–50 Mbit/s，tx `MCS 4`–`MCS 5` | 修复生效 |
| 上行正常但下行异常 | 回归，请立即回报 |
| 双向都慢 | 与本 bug 无关（AP、干扰、距离） |
| `upload_retrans` 很高（数百） | 链路问题，这个速率不可信 |

信号强度很重要：-25 到 -40 dBm 时可以期待上面那些数字。
低于约 -65 dBm 时，无论是否打这个补丁都稳不住 MCS4，
所以请记下你的 `signal_dbm`。

## 这里说的"修复"到底是什么意思

这个改动调大的是一个固件配置值。我们实测到：在 WCN3620 上，这个值能让
速率自适应稳定在高 MCS，而且**响应不是单调的**——8000 和 16000 会掉回 MCS0，
10000、12000、20000 则正常。我们没有固件源码，具体机制未知；
已知的是可复现的实测行为。来自其它网卡的结果，才能把它从"这台机器上有效"
变成"通用修复"。
