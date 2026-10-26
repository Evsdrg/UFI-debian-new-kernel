# UFI001b

MSM8916 机型，WiFi 为 **WCN3660b**（与 UFI103s 的 WCN3620 不同），
单 SIM（无 `sim-sel2` / `sim-en2` 控制线）。

- DTS：`dts/msm8916-handsome-openstick-ufi001b.dts`
- DTB：`boot/board.dtb`
- 内核：同家族共用（当前 7.2.9，6 个变体见 `CONTRIBUTING.md` §4.1）
- 设备树标识：`model` = `Handsome OpenStick UFI001b`，`compatible` = `handsome,ufi001b`, `qcom,msm8916`
- boot 镜像：**暂无 7.2.y 产物**；需要为该板型完成构建与实机验证

## 验证状态

**只有 DTS/DTB，从未在硬件上启动过**。本工作区没有该型号硬件。

DTS 里自带一张最高 1.6 GHz 的 CPU OPP 表，那是**上游 DTS 的声明**，本工作区
未在任何 UFI001b 上实测过。没有实机时不要把它当成已验证的结论。

## 排错

DTS 引脚布局与 UFI001c 同源（差异只有两条 SIM 控制线），所以两者行为应当
接近。若本型号启动失败，先用 `diff` 对比两者 DTS 缩小范围，再看
`boards/README.md` 的家族差异表。

## 刷机前

**必须先用 Miko 做整片 eMMC 全量备份**。只动 `boot` 与 `rootfs`，不动 GPT、
aboot、modem、NV。
