# MF601SL_CT_V07 设备树研究

MSM8916 电池型 4G MiFi（主板代号 `mf601sl_v07`）。本文记录**设备树的三方来源
对比**与最终取值依据。板级文件在 `boards/thwc-mf601sl/`，内核片段在
`source/configs/mf601sl.config`。

## 一、三个来源与可信度

| 来源 | 内容 | 可信度 |
|---|---|---|
| **`debian12_sl_v07.dtb`** | 社区 6.x Debian boot 镜像内嵌 DTB，**部分设备实测可启动**。sha256 `1a03db51…` | ⭐ 最高，本工程以此为准 |
| **原厂固件 boot.img** | 16MB Android bootimg，33 份 FDT 中 `board-id=0x08/0x100` 那份（model `MSM 8916 512MB MTP`） | ⭐ 高（引脚核对），但**高通 BSP 语言，不能直接用** |
| `cm9vdA/build-linux` mainline | 社区 mainline 版 DTS | ❌ USB-ID 用 charger VBUS，与实测可用树不一致，未采用 |
| 交接包 `mf601sl_v07原固件提取/修改后` | model `Handsome Openstick` | ❌ **实为 UFI103s 配置**，文件名有误导性 |

交叉验证：`debian12_sl_v07.dtb` 的 sha256 与另一份独立交接包里的同名文件
**逐字节相同**，说明该哈希对应的确实是那台可用设备的真实树。

## 二、原厂 BSP 与参考 mainline 的差异（本质：两种驱动语言）

| | 原厂 BSP | 参考 mainline |
|---|---|---|
| model | `MSM 8916 512MB MTP` | `MF601SL_CT_V07 (4G) jsbsbxjxh66+compile` |
| CPU 启动 | `qcom,arm-cortex-acc` | `psci` |
| 串口 | `qcom,msm-lsuart-v14` | `qcom,msm-uartdm-v1.4` |
| USB | `qcom,hsusb-otg` | `qcom,ci-hdrc` |
| 电池 | 高通 `qcom,8905-batterydata` | `simple-battery` + OCV 表 |

所以"两者差距大"是**必然的**——不是谁写错了，是驱动模型不同。

## 三、引脚对照（原厂 BSP vs 参考 mainline）

### LED

| 功能 | 原厂 BSP | 参考 mainline |
|---|---|---|
| 电池红 | GPIO110 | GPIO110 |
| 电池绿 | GPIO112 | GPIO112 |
| 网络红 | GPIO115 | GPIO115 |
| 网络绿 | GPIO116 | GPIO116 |
| WiFi 绿 | GPIO120 | GPIO120 |
| WiFi 红 | GPIO119 | GPIO119 |
| 占位 `LED_3/4/7/8/11/12/13/14` | GPIO113/114/117/118/121/22/21/20 | **未启用** |

原厂 `gpio-leds` 的 pinctrl 列 18 脚，参考树只启用 10 脚（6 灯 + 4 SIM）。
多出的 8 个都是**无功能名的占位标签**，很可能是模板残留。

⚠️ **GPIO121 冲突**：原厂当 `LED_11`，参考树当 **USB-ID**。本工程采用参考树
（USB-ID = 121）。这也解释了原厂 `usb-id-pin`（GPIO110）为何是死代码——
它没有任何节点引用。

### 按键

| 来源 | 说法 |
|---|---|
| 参考 mainline（本工程采用） | GPIO34 = `KEY_RESTART`(408) |
| 原厂 BSP | `key_wps`=GPIO107(code 64) + `key_freset`=GPIO34(code 216) |
| 交接包 Debian11 修复版 | GPIO37（= UFI 的，不适用） |

**三种说法，需实机确认。** 可能是不同硬件批次。

### SIM

| | 参考 mainline（本工程采用） | Debian11 修复版 |
|---|---|---|
| sim:sel | **GPIO49** | **GPIO24** |
| sim:en | **GPIO24** | **GPIO49** |
| sim:sel2 / en2 | GPIO50 / 51 | esim:sel1/2 = 50/51 |

**sel/en 对调**。交接文档警告："必须同时核对 SIM 切换脚本的 LED sysfs 名称
及控制电平，不能只按相同 GPIO 集合判断兼容。"

## 四、电池

| 参数 | 参考 mainline（本工程采用） | 原厂 BSP |
|---|---|---|
| 满充电压 | **4.2V** | 4.35V（`qrd_skub_4v35_2100mAh`） |
| 截止电压 | 3.0V | 3.3V |
| 容量 | 2100mAh / 7.98Wh | 2100mAh |

交接文档记录：历史诊断中**电池遥测 4.3443V、设计最大 4.2V、报 Over voltage**。
本工程保守采用 **4.2V**，确认实物规格前不调高。

## 五、USB 与 RNDIS

MF601 的 USB device 模式由 `extcon-usb-gpio` 的 **GPIO121** 决定（参考树）。
注意：`pm8916_lbc` 也注册 `EXTCON_USB`（VBUS 检测），但参考树选择 GPIO 方案。

因此 **`CHARGER_PM8916_LBC` 必须启用**——虽然它主要管充电，但 `pm8916_bms`
的 `power-supplies` 依赖它，且电池机需要充电控制。缺了会出现"电池有读数但
充电不工作"。

## 六、4G / 短信

内核侧 `common-7.2.9-os.config` 已具备全部所需：

| 配置 | 作用 |
|---|---|
| `QCOM_Q6V5_MSS=m` | modem remoteproc |
| `QCOM_BAM_DMUX=m` | 蜂窝数据（wwan） |
| `WWAN=m` / `RPMSG_WWAN_CTRL=m` | wwan 框架与控制通道 |
| `QRTR=m` / `QRTR_SMD=m` | QMI over SMD（**短信 WMS 也走这里**） |
| `QCOM_QMI_HELPERS=m` | QMI 助手 |
| `QCOM_RMTFS_MEM=m` | NV 存取 |

**没有"短信专用内核开关"**：短信由 ModemManager 经 QMI/WMS 实现，rootfs 的
basic 档已含 `modemmanager` + `libqmi-utils`（`qmicli` 可收发短信）。

不需要 `USB_NET_QMI_WWAN`（内置 modem 走 bam-dmux/wwan，不是 USB QMI 网卡）。

基带固件与 NV 校准必须用**本机原厂**的，不能跨机复制。

## 七、已知问题（与本设备树无因果证据）

交接文档记录 2026-10-17 一台设备（序列号 16263401）在 Debian12 / 6.4.0-rc4：

- MPSS `coex_interface.c:530` fatal
- 自动恢复认证失败（-19）
- 既有恢复服务随后重绑基带
- **整机死机，根因未查明**

同记录提到曾有"USB 与 WiFi 同时消失、非法指令、CPU 卡顿"。
**不能认定由设备树导致**，但测试时需留意。

## 八、本工程未采用的选择

| 项 | 未采用 | 理由 |
|---|---|---|
| venus 硬编解码 | SL 参考树启用了 | 电池 MiFi 不做推流；省 5MB 预留。需要时叠加 `ufi103s-venus.config` |
| 原厂 4.35V 充电 | 原厂 BSP | 有 Over voltage 历史记录，保守用 4.2V |
| 原厂 8 个占位 LED | 原厂 BSP | 无功能名，疑为模板残留；需实测确认 |

## 九、参考资料

- `out/mf601sl-research/handover/device_tree_handover_20261026/`（交接包，
  含 6 份 DTB、差异 JSON、说明文档）
- `out/mf601sl-research/mf601sl-real.dts`（原厂 BSP dtb-04 反编译）
- `out/mf601sl-research/mf601sl-ref/real.dts`（参考 mainline 反编译）
