# OpenStick 上行速率低：诊断与修复

## 现象

在一台 Handsome OpenStick UFI103s（MSM8916，WCN3620 网卡）上，链路良好时：

- **下行：约 45–50 Mbit/s**，PHY 速率 `MCS 6`–`MCS 7`（135–150 Mbit/s）。
- **上行：约 5–8 Mbit/s**，PHY 速率卡在 `MCS 0`（13.5 Mbit/s）。

**不对称是重要线索**。信号弱或干扰会让双向都变差；
而这里只有发射方向受影响，并且被钉在最低的一档 HT 速率上。

进一步确认的细节：

- 传输期间设备 CPU 只有 7–8%，不是主机性能瓶颈。
- 打开/关闭省电模式没有区别。
- 信号 -27 dBm、40 MHz 信道，`tx retries`/`tx failed` 都是 0。
- 四条并行上行流的总吞吐与单流相同——排除了单条 TCP 流的行为问题，
  指向 PHY/MAC 层的天花板。
- 上行期间平均 TX 帧长 1529 字节（满 MSS），说明没有分片或在发小帧。

## 排查过程

### 速率由固件决定

驱动设置了 `IEEE80211_HW_HAS_RATE_CONTROL`，所以速率选择完全是固件的工作。
运行时确认：

```
$ cat /sys/kernel/debug/ieee80211/phy0/rate_ctrl_alg
hw/driver
```

没有"主机设置速率"的消息；TX 描述符里的 `bd_rate` 只是 2 bit 的帧类别字段
（数据/管理/控制），不是速率。驱动也从不把逐包速率反馈给 mac80211——
固件的 TX 完成消息只带状态字——所以主机侧速率控制**在原理上就不存在**。

### 速率自适应先高后塌

配置表本来就要求固件从 MCS5 开始速率自适应
（`ENABLE_DYNAMIC_RA_START_RATE = 133`，即 `0x80|5`），
管理帧也确实是 `MCS 4`。**只有数据帧**掉到并停在 `MCS 0`。

### 那些最后证明不是原因的方向

- **TX 聚合**。传输期间 `agg_status` 显示 TID 0/1 的 BA 会话一直建立着，
  帧也是满长的。聚合是正常的。
- **固件能力表**。它报告 `RATECTRL`（没有 `BLOCKACK`，但驱动只拿这张表做
  debug 名字和扫描卸载的判断，并不用来门控聚合）。
- **`FIXED_RATE`**。这是最容易误导的旋钮。它**确实有效，但只对 legacy 速率**：
  设 1 / 2 / 4 得到 1 / 2 / 11 Mbit/s，证明值能到固件。
  而所有 HT 编码（128、130、133、135）试下来，数据帧都停在 MCS0——
  固件不接受主机指定的 HT 速率。
- **其它速率/重传旋钮**。`ENABLE_DYNAMIC_RA_START_RATE`（0、64、133、134、135）、
  `RA_FILTER_ENABLE`、`RA_RATE_LIMIT_INTERVAL`、`MCS_RATES`、`RETRYRATE_POLICY`、
  `FORCE_POLICY_PROTECTION`——都没有效果。

### 原因：MAX_MEDIUM_TIME

`MAX_MEDIUM_TIME`（HAL 配置 id 9）是固件每条信道的占用预算，单位微秒。
WCN3620/WCN3660B 的表里把它设成了 **6000**。

把它调大，发射速率就恢复。同一条链路、同一个 AP、单流、设备到主机实测
（模块加载时设值、重启链路后测量）：

| MAX_MEDIUM_TIME | PHY 速率 | TCP 吞吐 |
|---|---|---|
| 6000（原默认） | MCS0 13.5 Mbit/s | ~6 Mbit/s |
| 8000 | MCS0 | ~6 Mbit/s |
| **10000** | MCS4 90 Mbit/s | 43–45 Mbit/s |
| **12000** | MCS4 | 44–46 Mbit/s |
| 16000 | MCS0 | ~6 Mbit/s |
| **20000（现默认）** | MCS4–MCS5 | 44–50 Mbit/s |
| 30000 | MCS4 | 44–47 Mbit/s |

这张表有两点必须明说，因为它们不那么"舒服"：

1. **响应不是单调的**。8000 和 16000 会掉回 MCS0，而 10000、12000、20000、
   30000 都正常。所以这个值是**量出来的，不是推出来的**。
   我们没有固件源码，无法解释。

2. **另一张表里还有更小的值**。WCN3680 的表把 `MAX_MEDIUM_TIME` 设为 4096——
   比这里被称作"太小"的 6000 还小——却没有看到 WCN3680 用户有类似抱怨。
   所以诚实的读法是：这个阈值是**这一版固件**
   （`CNSS-PR-1-4-2-c4-00084`，`WCN v2.0`）的性质，不是普遍规律。
   这也正是为什么需要其它网卡（WCN3660B，最好还有 WCN3680）的数据：
   它们要么把修复推广开，要么把它限定在观察到它的那一版固件上。

## 验证

把 20000 写进驱动配置表、**不设任何模块参数**，干净启动后：

```
sustained1: 47 Mbit/s  tx=[MCS 4 40MHz short GI]
sustained2: 45 Mbit/s  tx=[MCS 4 40MHz short GI]
sustained3: 44 Mbit/s  tx=[MCS 4 40MHz short GI]
tx retries: 0    tx failed: 0    temperature 52 C
```

下行不变：设备 RX 仍是 `MCS 6`–`MCS 7`，45–50 Mbit/s。
把值改回 6000，约 6 Mbit/s 的故障立刻复现——正是这一来一回
确立了因果关系，而不是巧合。

## 补丁

`source/patches/0002-wifi-wcn36xx-raise-max-medium-time-for-ht-tx.patch`
只改这一个值，并在注释里记录了测量依据。它可以单独套用到 pristine 的
`linux-7.2.9` 树。补丁文本不随旧内核产物分发；当前版本应重新构建并复测。
它通过 `checkpatch.pl --strict`，无 error 无 warning。

另有两个配套补丁：

- `0001` 让驱动的 `firmware_feat_caps` debugfs 文件可读。上游把它注册成
  `0200`（只写）却挂了**读**回调，导致固件能力表谁都读不到。改成 `0444` 修复。
  这是一个独立、显然的 bug 修复。
- `0003` 增加 `cfg_override` 模块参数和 debugfs 旋钮，可以在加载时覆盖任意
  HAL 配置值。上面的参数扫描就是靠它做的，不必每个值都重编一次；
  它是诊断工具，不是修复的一部分。

## 相关说明

- 读固件能力表需要 `CONFIG_WCN36XX_DEBUGFS`（看聚合情况还需要
  `CONFIG_MAC80211_DEBUGFS` 与 `CONFIG_CFG80211_DEBUGFS`）。这些在默认配置里都没开。
- 高通的下游厂商驱动里同样有 `MAX_MEDIUM_TIME = 6000`，所以它是从厂商 BSP
  继承来的，不是主线引入的。
- WCN3620 与 WCN3660B 共用配置表；WCN3680 有自己的表。
