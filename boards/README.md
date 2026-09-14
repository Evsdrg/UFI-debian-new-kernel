# boards/ — 为什么这样分组

本目录按**硬件家族**分组，而不是每个机型一个平级目录。分组的依据是 DTS
里引脚定义的实际差异，不是机型名字或销售渠道。

## 家族划分

| 家族 | 成员 | 判据 |
|---|---|---|
| `ufi00x/` | ufi103s-ufi003、ufi001b、ufi001c | 三个机型的 LED / 按键 / SIM 引脚定义同源，差异只在型号字符串、WiFi 芯片和 CPU 频率上限 |
| `sp970/` | sp970 | 独立设计，引脚布局与其它机型不同 |
| `uz801/` | uz801 | 独立设计，引脚布局与其它机型不同 |

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

1. **内核是共享的**。`Image.gz` 所有机型共用；机型差异只体现在追加的 DTB 上。
   所以 `boards/<家族>/<机型>/boot/` 里的 boot 镜像 = 同一内核 + 各自 DTB。
2. **所有机型共用同一个 dtsi**：`source/dts/common/msm8916-handsome-openstick-common.dtsi`。
   每个机型的 `.dts` 都 `#include` 它，只在其上覆盖引脚差异。
3. **rootfs 是板无关的**，统一放在 `shared/rootfs/`。刷机包 = 本板 boot 镜像 +
   共享 rootfs，见顶层 `README.md`。
4. **LED 脚本也是板无关的**。五机型的三颗状态灯在设备树里语义一致
   （`WLAN`/蓝、`WAN`/绿、`HEARTBEAT`/红），sysfs 名字都是 `blue:wlan`、
   `green:wan`、`red:heartbeat`，只有 GPIO 编号不同——而那由各自的 DTB 承担。
   所以脚本按名字发现灯即可，不需要按型号分支。详见 `../LED.md`。
5. **网络配置也板无关**：统一由 NetworkManager 管理，见 `../NETWORK.md`。

## 引脚布局的来源

`ufi00x` 家族的布局来自 HandsomeMod BSP（`target/linux/msm89xx/patches-5.10/
0083-arm64-dts-add-support-for-Handsome-Openstick-Family.patch`），并经实机
设备树 dump 核对。本工作区不重新发明引脚定义。

## 新增机型时

1. 先在 `boards/<家族>/<机型>/dts/` 放 DTS，在 `source/dts/common/` 里复用 dtsi。
2. 用 `tools/package-boards.py` 生成 boot 镜像（它会读 `build.json` 里的 cmdline）。
3. 在 `tools/verify-layout.sh` 的机型列表里登记，否则布局校验不会覆盖到它。
4. 不要假设 DTB 一致就直接复用别的机型的 boot 镜像——先跑 diff 确认。
