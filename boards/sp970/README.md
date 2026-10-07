# SP970

MSM8916 机型，WiFi 为 **WCN3660b**。独立设计：reset 键与三颗 LED 的引脚
编号都与 ufi00x 家族和其它机型不同，因此**不能复用 ufi00x 的 boot 镜像**。

- DTS：`dts/msm8916-handsome-openstick-sp970.dts`
- DTB：`boot/board.dtb`
- 内核：同家族共用（当前 7.2.9，5 个板型组合见 `AGENTS.md` §5.1）
- 设备树标识：`model` = `Handsome OpenStick SP970`，`compatible` = `handsome,sp970`, `qcom,msm8916`
- boot 镜像：**暂无 7.2.y 产物** —— 6.18.49 时代那张（离线校验级）已随
  2026-10-07 的旧内核清理移除；要重出得跑对应板型的构建

## 验证状态

**只有 DTS/DTB，从未在硬件上启动过**。本工作区没有该型号硬件。

DTS 里自带一张最高 **1.8 GHz** 的 CPU OPP 表（DTS 注释说该芯片可到 2.1 GHz，
但因跨批次不保证、故封顶 1.8 GHz）。那是**上游 DTS 的声明**，本工作区未在
任何 SP970 上实测过。

## 与 UZ801 的关系

两者常被归为同一档（都是独立引脚设计），但 reset 与 LED 引脚**不同**，不可
互换 boot 镜像。差异见 `boards/README.md` 的家族表。

## 刷机前

**必须先用 Miko 做整片 eMMC 全量备份**。只动 `boot` 与 `rootfs`，不动 GPT、
aboot、modem、NV。
