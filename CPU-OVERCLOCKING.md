# UFI103s CPU 超频可行性研究 (MSM8916 / Cortex-A53)

日期: 2026-09-03
内核: Linux 6.18.48-ufix0x (主线)
SoC: Qualcomm MSM8916 (Snapdragon 410, 4×Cortex-A53)

## 1. 关键机制: SAW2 是频率-电压绑定器

主线 `msm8916.dtsi` 每个 CPU 核都有:
```
cpu@0 {
    clocks = <&apcs>;                       // A53 时钟源
    qcom,saw = <&cpu0_saw>;                 // SAW2 v3.0 AVS 控制器
    operating-points-v2 = <&cpu_opp_table>;
};
cpu0_saw: power-manager@b089000 {
    compatible = "qcom,msm8916-saw2-v3.0-cpu", "qcom,saw2";
};
```

`qcom,saw2` 是 **AVS(自适应电压调节)** 控制器 —— 它通过内嵌的
Fuse 校正 + 反馈环，在频率切换时**自动**拉高/降低 CPU 供电电压。
因此 OPP 表里**只需写频率**，电压由 SAW2 动态决定，无需 `opp-microvolt`。

这解释了为何:
- 设备 5.15 BSP 的高频 OPP 表(无电压字段)能原样跑 1.6GHz
- 主线 OPP 表同样只有频率(200/400/800/998.4)，无电压
- 主线可直接照搬设备的高频档，SAW2 会自动配压

## 2. 频率档位对比

| 档位 | 主线 OPP | 设备 BSP OPP | 用途 |
|---|---|---|---|
| 200 MHz | ✓ | - (idle 更低?) | 深睡眠/早期 |
| 400 MHz | ✓ | ✓ | idle |
| 800 MHz | ✓ | ✓ | 常规 |
| 998.4 MHz | ✓ | - | 主线默认最高 |
| 1000 MHz | - | ✓ | boost |
| 1100 MHz | - | ✓ | 超频 |
| 1200 MHz | - | ✓ | 超频 |
| 1300 MHz | - | ✓ | 超频 |
| 1400 MHz | - | ✓ | 超频 |
| 1500 MHz | - | ✓ | 超频 |
| 1600 MHz | - | ✓ | 极限 |

设备 BSP 定义了 1.6GHz 上限，远高于主线的 998.4MHz。

## 3. 核心风险: 电压箱位在 RPM 的 s3 上限

CPU 核心供电 rail 是 **pm8916_s3**:
```
pm8916_s3: s3 {
    regulator-min-microvolt = <1250000>;
    regulator-max-microvolt = <1350000>;
    regulator-always-on;
};
```

**这是最大风险点**:
- SAW2 要驱动 1.6GHz 需要更高的电压(通常 A53 高频 > 1.3V)
- 但 s3 的 regulator 上限被限死在 **1350mV**
- 若 SAW2 请求超过 1350mV，RPM regulator 会**拒绝/箱位**到 1350mV
- 结果: 高频点电压不足 → 要么死机/重启，要么系统不稳定

所以真正决定能否安全超到 1.6GHz 的，不是 DTS 能不能写，而是
**这颗 UFI103s 的 eFuse PVS bin + SAW2 的自动调压上限**。

## 4. 决定超频安全性的实际因素

1. **eFuse PVS bin (体质)**: 每颗 MSM8916 出厂时熔断 PVS(process-voltage-speed)。
   高体质 bin 天生能耐更高电压/频率,低体质 bin 高频点易不稳。
   可用 `qcom-cpufreq-nvmem` 读 eFuse 得到 bin 值(需厂商 fuse 映射)。

2. **SAW2 是否能越过 s3 电压上限**:
   若 SAW2 的 AVS 环在 1350mV 内能覆盖 1.0~1.3GHz,则这部分安全;
   1.4GHz+ 大概率触及电压天花板。

3. **温度**: 高频 + 高电压 → 发热。棒子散热差(无风扇,紧贴外壳),
   长期 1.4GHz+ 可能温度攀升,触发热降频或损坏。

4. **CPU 体质 vs 标称**: 骁龙410(MSM8916) 官方标称最高 1.2GHz(部分 SKU 1.4GHz)。
   1.4GHz+ 属于"非官方超频",需实机试。

## 5. 结论与建议

**结论**: MSM8916 的 SAW2 机制使得主线 DTS **技术上可以**加入高频 OPP 表,
但安全上限受 pm8916_s3 的 1350mV 箱位约束,且取决于这颗料的 PVS 体质。

**分档建议(由保守到激进)**:

| 级别 | 频率 | 风险评估 | 建议 |
|---|---|---|---|
| 稳定 | 998.4 MHz (主线) | 零风险,官方标称 | 保持 |
| 保守超频 | 1.0~1.2 GHz | 低风险,多数 A53 体质可耐 | 可试 |
| 中度超频 | 1.2~1.4 GHz | 中风险,需实机压测 | 谨慎 |
| 激进超频 | 1.4~1.6 GHz | 高风险,电压/温度双压力 | 需实测+散热 |

**推荐路径**:
1. 先在板级 DTS 里加 1.0/1.1/1.2GHz 三档(保守),
   即 OPP 表补 `opp-1000000000/1100000000/1200000000`
2. 实机用 `stress -c 4` + `cpufreq-set` 压测,观察:
   - 是否死机/重启
   - 温度是否过高
   - 电压是否被箱位(dmesg 有无 regulator 报错)
3. 若稳定,再逐级加 1.3/1.4/1.5GHz,每级测试
4. 1.6GHz 仅限敢死队,作娱乐性尝试

**不建议直接照搬设备 BSP 的 1.6GHz** —— 那是厂商特定体质 + 特定散热
环境下调好的,我们的板子未必同体质。稳妥从 1.2GHz 起步。

## 6. 超频修改点(挂到板级 DTS)

在 `msm8916-handsome-openstick-common.dtsi` (或专给它) 的 CPU OPP 表
追加高频档(仅频率,SAW2 自动配压):
```dts
&cpu_opp_table {
    opp-1000000000 { opp-hz = /bits/ 64 <1000000000>; };
    opp-1100000000 { opp-hz = /bits/ 64 <1100000000>; };
    opp-1200000000 { opp-hz = /bits/ 64 <1200000000>; };
    /* 实测稳定后再放开 */
    /* opp-1300000000 { opp-hz = /bits/ 64 <1300000000>; }; */
};
```
但注意: 主线 OPP 表是 SoC 共享的(`cpu_opp_table`), 板级可覆盖
但会不会被 cpufreq-dt 接受取决于 `opp-supported-hw`/eFuse 掩码。
实际需在实机上验证 cpufreq-dt 是否听从这些新增档位。

## 7. 待办: 实机验证步骤(等设备恢复在线)

```bash
# 1. 看当前可用频率
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_freqs
# 2. 设到 1.2GHz
echo 1200000 > /sys/devices/system/cpu/cpu0/cpufreq/scaling_setspeed
# 3. 压测
stress -c 4 &
sleep 60
# 4. 看温度(热降频触发点)
cat /sys/class/thermal/thermal_zone0/temp   # 需毫度
# 5. 观察dmesg有无regulator/voltage警告
dmesg | grep -iE 'regulator|voltage|cpufreq'
```

## 8. 实测体质补充 (2026-09-03, 用户实测数据)

不再依赖保守分档, 按实际体质直接配置:
| 板子 | 最高频率 | 依据 |
|---|---|---|
| UFI001b / UFI001c / UFI103s | 1.6GHz | 大部分 UFI00x 能跑 1.8GHz, 取稳 1.6 |
| SP970 | 1.8GHz | 实测可达2.1GHz, 为稳定起见降到1.8 |
| UZ801 | 1.4GHz | 不易稳定高频, 单独限制 |

实现: 各板 dts 里 override &cpu_opp_table, 追加高频档(纯频率, SAW2自动配压)。
已验证最终 dtb 的 OPP 表正确合并 (基档 200/400/800/998.4 + 各板高频档)。
