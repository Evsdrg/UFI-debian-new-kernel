# THWC MF32（MF32_MB_V02）

MSM8916 电池型 4G MiFi。与 UFI103s 同 SoC，但具有电池、microSD、
独立 LED/按键布局和不同的产品形态，不能直接复用 UFI 的 boot 或模块树。

## 当前状态

| 项 | 状态 |
|---|---|
| 板级 DTS | 已生成并编译，基于同目录反编译 DTS 做定点调整 |
| 内核与模块 | `7.2.9-ufix0x-mf32-dirty`，678 个模块 |
| rootfs | Debian 13 basic 档，含 MF32 LED/电源键服务 |
| 静态检查 | USB 交付断言、e2fsck、LED 37/37、电源键 11/11 通过 |
| QEMU | 能到 login，无非预期 FAILED |
| **实机** | **尚未验证**；本工作区没有 MF32 硬件 |

## 硬件依据

型号来自 DTS：`MF32_MB_V02 (4G) ak201314`，compatible 为
`ak201314,MF32_MB_V02` 与 `qcom,msm8916`。

| 子系统 | 配置 |
|---|---|
| WiFi/BT | WCN3620，使用 mainline wcn36xx 与本项目补丁 |
| 4G | mpss 85MiB@0x86800000、mba、rmtfs、bam-dmux，完整保留 |
| 电池 | PM8916 LBC 充电 + BMS-VM 电量计，2100mAh，保守 4.2V 参数 |
| USB | ci-hdrc OTG，extcon USB-ID |
| 存储 | eMMC + microSD，SD CD 使用 GPIO38 |
| 按键 | PMIC 电源键 + GPIO34 Restart |
| LED | RGB 系统状态 + 四颗独立 LED 电量条 |
| 串口 | `ttyMSM0` @115200 |

详细依据见 [`LED-SCHEME.md`](LED-SCHEME.md) 与
[`POWER-KEYS.md`](POWER-KEYS.md)。原始反编译 DTS 保留在
`dts/msm8916-thwc-mf32.decompiled.dts`，构建使用
`dts/msm8916-thwc-mf32.dts`。

## 本版设备树调整

- 删除未使用的 GPS 与 memshare 预留，回收 1MB。
- 关闭 Venus 和原厂仅 1MB 的 Venus 预留；本版不做硬件转码。
- 按 LED 方案重写 RGB 与四颗电量条节点，SIM 控制保持不变。
- 将原厂已定义但未引用的 SD CD pinctrl 接到 SD 控制器。
- 保留完整 modem、充电、电量计、PMIC 按键和震动马达。

**不要套用 UFI baseline/minimal 的内存裁剪**，那会关闭 MF32 必需的 4G 链。

## 构建

```sh
bash tools/build-board-set.sh mf32
```

产物：

- `artifacts/boot/thwc-mf32/boot-board-mf32-7.2.9.img`
- `artifacts/modules/7.2.9-ufix0x-mf32-dirty/`

rootfs 构建：

```sh
KERNEL_RELEASE=7.2.9-ufix0x-mf32-dirty \
MODULE_TREE=artifacts/modules/7.2.9-ufix0x-mf32-dirty \
ROOTFS_FLAVOR=basic ROOTFS_BOARD=mf32 \
ROOTFS_ROOT_DEVICE=PARTLABEL=rootfs \
MMDEBSTRAP_FORMAT=ext4 bash build-rootfs.sh
```

`ROOTFS_BOARD=mf32` 会安装并启用：

- `mf32-led-state.service`：RGB 系统状态与电量条
- `mf32-powerkey.service`：单击显示电量、双击干净关机
- logind 配置：不再把单击电源键直接关机

不会安装 UFI 的灯语服务。

## 启动与分区限制

当前 boot cmdline 和 rootfs fstab 都使用 `PARTLABEL=rootfs`。
**MF32 的实际 GPT 尚未在本项目核实**，刷入前必须确认目标分区标签确实为
`rootfs`；如果不同，需要同时调整 cmdline 与 `/etc/fstab`。

不要根据其它机型的分区编号直接刷入，不要在未备份的情况下测试。
本板仍未验证 fastboot 可达性、关机充电、插充电器自动开机、长按硬复位、
电池/SIM/SD 与 LED 实际对应关系。

## 测试包

本地测试包在 `out/mf32-build/`，包含 boot、DTB、模块树、rootfs、
`测试说明.md` 和 `SHA256SUMS.txt`。测试包与验收记录不随公开仓库分发。
