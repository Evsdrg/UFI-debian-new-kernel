# UFI001b

MSM8916 机型，WiFi 为 **WCN3660b**（与 UFI103s 的 WCN3620 不同），
单 SIM（无 `sim-sel2` / `sim-en2` 控制线）。

- DTS：`dts/msm8916-handsome-openstick-ufi001b.dts`
- boot 镜像：`boot/boot-baseline.img`
- DTB：`boot/board.dtb`
- 内核：`7.1.13-ufi003-venus-dirty`（7.1.13 与所有机型共用同一份内核；
  6.18.49 产物保留作回退）
- 设备树标识：`model` = `Handsome OpenStick UFI001b`，`compatible` = `handsome,ufi001b`, `qcom,msm8916`
- cmdline：见 `boot/build.json`

## 验证状态

**仅离线校验**（构建成功、哈希自洽、DTB 布局正确），**从未刷入实机**。
本工作区没有该型号硬件。

DTS 里自带一张最高 1.6 GHz 的 CPU OPP 表，那是**上游 DTS 的声明**，本工作区
未在任何 UFI001b 上实测过。没有实机时不要把它当成已验证的结论。

## 排错

DTS 引脚布局与 UFI001c 同源（差异只有两条 SIM 控制线），所以两者行为应当
接近。若本型号启动失败，先用 `diff` 对比两者 DTS 缩小范围，再看
`boards/README.md` 的家族差异表。

## 刷机前

**必须先用 Miko 做整片 eMMC 全量备份**。只动 `boot` 与 `rootfs`，不动 GPT、
aboot、modem、NV。
