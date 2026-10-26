# ufi00x 家族

成员：**UFI103s / UFI003**、**UFI001b**、**UFI001c**。

这三个机型共用同一套 LED / 按键 / SIM 引脚布局，来自 HandsomeMod BSP 的
OpenStick 系列 DTS，并经 UFI103s 实机设备树 dump 核对。它们都 `#include`
`source/dts/common/msm8916-handsome-openstick-common.dtsi`。

## 成员差异

| 机型 | WiFi 芯片 | SIM 控制线 | CPU OPP |
|---|---|---|---|
| UFI103s / UFI003 | WCN3620 | 单 SIM | 本工作区按实测标定（见 ufi103s-ufi003/README.md） |
| UFI001b | WCN3660b | 单 SIM，无 sel2/en2 | DTS 内自带 1.0–1.6 GHz 表 |
| UFI001c | WCN3660b | 双 SIM（多 sel2/en2） | DTS 内自带 1.0–1.6 GHz 表 |

**注意**：ufi001b / ufi001c 的 DTS 里各带一张最高 1.6 GHz 的 OPP 表，那是
**来自上游 DTS 的声明，不是本工作区实测的结论**。本工作区只在 UFI103s 上
做过频率标定：约 1209.6 MHz 之后无收益，且电压由 PSCI 固件掌控，不能靠
`opp-microvolt` 降压。没有实机就不要照搬那两张表。

## 产物

- `dts/`：该机型的设备树源文件。
- boot 镜像、DTB 和模块树由构建脚本写入 `artifacts/`，不在本目录保存产物。

UFI103s 有 6 个 boot 变体：5 个 DTS 功能组合，以及使用 baseline DTS、
进一步裁剪内核配置的 `minimal`。ufi001b / ufi001c 目前只有 DTS 与 DTB，
没有对应的 7.2.9 boot 镜像。变体说明见 `ufi103s-ufi003/README.md`。

## 只有 UFI103s 插过真机

ufi001b / ufi001c 到目前为止只做到 DTS/DTB 级别，从未在硬件上启动过。
这两个型号的进一步验证需要对应硬件与实机反馈，测试说明见 `../../docs/dist/`。
