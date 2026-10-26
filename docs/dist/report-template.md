# 测试回报模板

把下面这段复制到 issue 里。有的就填，**没有的删掉那一行，不要猜着填**。
同一台设备、同一位置的前后对照是最重要的部分——只有"之后"的结果也有用，
注明即可。

```markdown
## 板型

- board:                  （ufi103s-ufi003 / ufi001b / ufi001c / sp970 / uz801 / 其它）
- wifi_chip:              （照抄测试输出里的 wifi_chip= 那一行）
- kernel:                （uname -r）
- running this rootfs/os: （例如本工程的 venus-led 镜像、pmOS……）

## 我做了什么

- [ ] 方案 A：在现有系统上替换 wcn36xx.ko（不刷机）
- [ ] 方案 B：刷入 builds/ 里的 boot 镜像
- [ ]（仅方案 B）我先用 Miko 做了整片 eMMC 备份，并在刷机前核对了镜像大小
- 模块来源：              （自己用补丁编的 / 用了 builds/boot/<variant>/wcn36xx.ko）
- 测试前我驱动里的 MAX_MEDIUM_TIME：
                          （6000 / 20000 / 其它 / 未知）

## 之前（仅方案 A，或你原来的状态）

```
<粘贴 tools/dist/wifi-tx-test.sh 的完整输出>
```

## 之后

```
<粘贴 tools/dist/wifi-tx-test.sh 的完整输出>
```

## 其它

- AP 与频段：            （例如你的 AP、2.4 GHz ch1 / 5 GHz）
- 距离 / 遮挡：           （例如同房间、约 2 米）
- 有没有别的异常？        （服务、蓝牙、modem……）
- 备注：
```

## 什么样的数据算好数据

一次完整的"之后"测量长这样。**这里只展示输出格式**，不表示你的设备应得到
同样的数字。当前产物是 7.2.9，网卡、固件和链路环境都会影响结果：

```
# ==== wifi-tx-test ====
kernel=<uname -r>
hostname=ufi103s
iface=wlan0
ap_ssid=<your-ap-ssid>
ap_freq_mhz=2412.0
signal_dbm=-25
wifi_chip=qcom,wcn3620
firmware=WCN v2.0 RadioPhy vUnknown with 19.2MHz XO
driver_vermagic=<from modinfo wcn36xx>
--- rates before traffic ---
  tx bitrate:	90.0 MBit/s MCS 4 40MHz short GI
  rx bitrate:	150.0 MBit/s MCS 7 40MHz short GI
upload_mbps=42.7
upload_retrans=5
rate_during_upload=tx bitrate:	90.0 MBit/s MCS 4 40MHz short GI rx bitrate:	150.0 MBit/s MCS 7 40MHz short GI
download_mbps=72.2
tx_retries=0
tx_failed=0
# ==== end ====
```

有两行容易读错：

- `rate_during_upload` 是**在跑流量时**采样的。这点很重要：空闲链路经常报的是
  管理帧速率，不是数据速率。这个 bug 在这里表现为 `MCS 0`，
  正常链路则是 `MCS 4` 或更高。
- `signal_dbm` 决定你的预期。低于约 -60 dBm 时，无论是否打这个补丁都稳不住
  MCS4，所以信号弱本身就能解释一个低数字。
