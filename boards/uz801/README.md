# UZ801

MSM8916 机型，WiFi 为 **WCN3660b**。独立设计：reset 键与三颗 LED 的引脚
编号都与 ufi00x 家族和 SP970 不同，因此**不能复用其它机型的 boot 镜像**。

- DTS：`dts/msm8916-handsome-openstick-uz801.dts`
- boot 镜像：`boot/boot-baseline.img`
- DTB：`boot/board.dtb`
- 内核：`7.1.13-ufi003-venus-dirty`（7.1.13 与所有机型共用同一份内核；
  6.18.49 产物保留作回退）
- 设备树标识：`model` = `Handsome OpenStick UZ801`，`compatible` = `handsome,uz801`, `qcom,msm8916`
- cmdline：见 `boot/build.json`

## 验证状态

**仅离线校验**（构建成功、哈希自洽、DTB 布局正确），**从未刷入实机**。
本工作区没有该型号硬件。

DTS 里的 CPU OPP 表**封顶 1.4 GHz**，DTS 注释给出的理由是「UZ801 在高频下
不稳」。这是**上游 DTS 的声明**，本工作区未实测。

## 与 SP970 的关系

两者都是独立引脚设计，但 reset 与 LED 引脚**不同**，不可互换 boot 镜像。
另外 SP970 的 OPP 表最高到 1.8 GHz，UZ801 只到 1.4 GHz——**频率上限也不同**，
不要照搬对方的频率设置。

## 刷机前

**必须先用 Miko 做整片 eMMC 全量备份**。只动 `boot` 与 `rootfs`，不动 GPT、
aboot、modem、NV。
