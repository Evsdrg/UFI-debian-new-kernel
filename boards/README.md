# boards/ — 为什么这样分组

本目录按**硬件家族**分组，而不是每个机型一个平级目录。分组的依据是 DTS
里引脚定义的实际差异，不是机型名字或销售渠道。

## 家族划分

| 家族 | 成员 | 判据 |
|---|---|---|
| `ufi00x/` | ufi103s-ufi003、ufi001b、ufi001c | 三个机型的 LED / 按键 / SIM 引脚定义同源，差异只在型号字符串、WiFi 芯片和 CPU 频率上限 |
| `sp970/` | sp970 | 独立设计，引脚布局与其它机型不同 |
| `uz801/` | uz801 | 独立设计，引脚布局与其它机型不同 |
| `thwc-mf601sl/` | mf601sl_v07 | THWC 电池型 4G MiFi；与 UFI 家族差异大（电池/SD/完整4G/USB-ID GPIO121） |
| `thwc-mf32/` | MF32_MB_V02 | THWC 电池型 4G MiFi；RGB+电量条 LED、双击关机，已构建但未实机验证 |

## 实测差异（逐字节 diff，注释行已剔除）

下表是本目录分组的直接证据。数字越小表示两个机型越接近：

| 对比 | 实质差异行数 | 关系 |
|---|---|---|
| ufi001b ↔ ufi001c | 20 | 同布局；差异为 ufi001c 多出 `sim-sel2`/`sim-en2` 两条 SIM 控制线 |
| ufi001c ↔ ufi103s-ufi003 | 40 | 同布局；差异为 WiFi 芯片（WCN3660b / WCN3620）、型号串，以及 ufi001c 自带的 CPU OPP 表 |
| ufi001b ↔ ufi103s-ufi003 | 54 | 同上两个差异的叠加 |
| sp970 ↔ uz801 | 35 | reset 键与三颗 LED 的引脚编号全部不同 |
| ufi001b ↔ uz801 | 42 | 跨家族 |
| sp970 ↔ ufi001b | 43 | 跨家族 |
| ufi001c ↔ uz801 | 52 | 跨家族 |
| sp970 ↔ ufi001c | 53 | 跨家族 |
| ufi103s-ufi003 ↔ uz801 | 74 | 跨家族，差异最大 |
| sp970 ↔ ufi103s-ufi003 | 87 | 跨家族，差异最大 |

跨家族的差异集中在 reset 键与 LED 的 GPIO 编号上：

| 机型 | reset 键 | LED (wifi / internet / os) |
|---|---|---|
| sp970 | 独立编号 | 独立编号，且与 uz801 完全不同 |
| uz801 | 独立编号 | 独立编号 |

这三种引脚定义直接决定设备树能否启动、LED 能否点亮，因此**不能跨家族复用
boot 镜像**。

## 关键共性

1. **同一板型的各变体共享内核构建基础，机型差异主要由追加的 DTB 表达。**
   不同板型可以有独立配置和模块树；不要跨板型复用 boot 镜像或模块。
2. **UFI 家族共用 `source/dts/common/msm8916-handsome-openstick-common.dtsi`**，
   各机型在其上覆盖引脚差异。MF601SL 使用独立的板级 DTS，不套用这个 dtsi。
3. **rootfs 的用户态软件基本通用，但模块树必须与内核 release 配对。**
   UFI 的 rootfs 不能直接替代 MF601SL 的配套 rootfs；vermagic 不同会导致
   模块无法加载。详见 `artifacts/README.md` 与各板级 README。
4. **UFI 五机型的 LED 脚本可共用**：它们的三颗灯语义一致
   （`WLAN`/蓝、`WAN`/绿、`HEARTBEAT`/红），GPIO 差异由 DTB 承担。
   MF601SL 是每功能红绿双灯，使用独立的灯名映射。详见 `../docs/hardware/LED.md`。
5. **网络配置框架基本通用**，UFI 默认由 NetworkManager 管理，
   见 `../docs/hardware/NETWORK.md`；具体板型仍需验证 modem、SIM 与 USB 角色。

## 引脚布局的来源

`ufi00x` 家族的布局来自 HandsomeMod BSP（`target/linux/msm89xx/patches-5.10/
0083-arm64-dts-add-support-for-Handsome-Openstick-Family.patch`），并经实机
设备树 dump 核对。本工作区不重新发明引脚定义。

## 新增机型时

1. 先在 `boards/<家族>/<机型>/dts/` 放 DTS，在 `source/dts/common/` 里复用 dtsi。
2. 按板型在 `tools/build-board-set.sh` 的板型表中登记内核片段、DTS、板目录和
   `root=` 写法，再生成 boot 镜像与配套模块树。
3. 在 `tools/verify-layout.sh` 的机型列表里登记，否则布局校验不会覆盖到它。
4. 不要假设 DTB 接近就直接复用别的机型的 boot 镜像——先核对配置、compatible
   和关键引脚，再做实机验证。
