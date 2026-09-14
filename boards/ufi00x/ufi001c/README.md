# UFI001c

MSM8916 机型，WiFi 为 **WCN3660b**，双 SIM（比 UFI001b 多 `sim-sel2` /
`sim-en2` 两条控制线）。

- DTS：`dts/msm8916-handsome-openstick-ufi001c.dts`
- boot 镜像：`boot/boot-baseline.img`
- DTB：`boot/board.dtb`
- 内核：`7.1.13-ufi003-venus-dirty`（7.1.13 与所有机型共用同一份内核；
  6.18.49 产物保留作回退）
- 设备树标识：`model` = `Handsome OpenStick UFI001c`，`compatible` = `handsome,ufi001c`, `qcom,msm8916`
- cmdline：见 `boot/build.json`

## 验证状态

**仅离线校验**（构建成功、哈希自洽、DTB 布局正确），**从未刷入实机**。
本工作区没有该型号硬件。

DTS 里自带一张最高 1.6 GHz 的 CPU OPP 表，那是**上游 DTS 的声明**，本工作区
未在任何 UFI001c 上实测过。

## 与 UFI001b 的关系

两者引脚布局同源，差异只有两条 SIM 控制线（以及由此影响的 `sim:` LED 节点
与相关 pinmux）。**双 SIM 是本型号与 UFI001b 唯一的功能性区别**，若双卡
切换异常，优先查这两条线。

## 刷机前

**必须先用 Miko 做整片 eMMC 全量备份**。只动 `boot` 与 `rootfs`，不动 GPT、
aboot、modem、NV。
