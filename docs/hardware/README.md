# 硬件文档

按子系统记录功能、限制和实测结果。修改硬件相关代码或刷机前，先读对应文档；
通用约束见[贡献须知](../../CONTRIBUTING.md)。

| 文档 | 内容 |
|---|---|
| [`FASTBOOT.md`](FASTBOOT.md) | fastboot 刷机、回退、分区注意事项与实测记录 |
| [`NETWORK.md`](NETWORK.md) | NetworkManager、中文 locale、rootfs 自动扩容 |
| [`4G.md`](4G.md) | 4G 流量、短信、基带/EFS 备份与恢复、rmtfs 只读陷阱 |
| [`DESKTOP.md`](DESKTOP.md) | i3、xrdp、Adreno 306 render-only GPU |
| [`GPU-STREAMING.md`](GPU-STREAMING.md) | GPU 合成、Venus 编码与 UDP 推流 |
| [`VIDEO-CODEC.md`](VIDEO-CODEC.md) | Venus 编解码能力、性能、格式与分辨率限制 |
| [`CPU-POWER.md`](CPU-POWER.md) | CPU 频率、电压和散热 |
| [`LED.md`](LED.md) | 状态灯的设备树命名、灯语与适配 |
| [`MF601SL.md`](MF601SL.md) | MF601SL 设备树来源、GPIO 对比与未确认项 |
| [`BATTERY.md`](BATTERY.md) | 电池、充电与电量显示：驱动属性、内核能力边界、用户态消费点 |
| [`POWER-AND-RNDIS.md`](POWER-AND-RNDIS.md) | OCV 查表做电量百分比的可行性与精度，RNDIS 稳定性风险清单 |
| [`WIFI-HOTSPOT.md`](WIFI-HOTSPOT.md) | WCN36xx AP 能力、NM 热点方案与验收清单 |
| [`BLUETOOTH.md`](BLUETOOTH.md) | 蓝牙驱动、固件与实测结果 |

几个最容易影响可用性的限制：

- Venus 编码宽高须按 32 对齐，且不能只用 ffmpeg `-g` 控制关键帧。
- GPU 只支持 render-only 和 RGB 格式，不能直接输出 NV12 给 Venus。
- 不要 `rmmod venus` 或 `rmmod msm`；需要重载时重启设备。
- 持续满载会受到散热限制，不能把短时测试当作长稳结论。

完整说明和原因见各专题文档。
