#!/usr/bin/env bash
# 【已废弃，禁止使用】MF32 转 OpenStick 分区 + lk2nd 引导的历史脚本。
#
# 保留此文件只为留下"曾经尝试过什么、为什么不行"的线索；它描述的整套路径
# 已被实机实测证伪，且每一步都是对设备的破坏性写入。任何情况下都不要执行。
#
# 为什么废弃（每一条都有实测依据，见 docs/hardware/FASTBOOT.md）：
#
#   1) 自创 GPT。本脚本用 out/mf32-gpt/gpt-main.bin 这套自己算出来的表；
#      正确做法是照 OpenStick 官方 base.zip 的 gpt_both0.bin 作模板，并由
#      原厂 LK 的 `fastboot flash partition` 按实际 eMMC 容量把 rootfs 撑到盘尾。
#      自创等价布局是被明确否决的方向。
#
#   2) lk2nd 作最终引导。实测设备启动日志报 `product: LK1ST_MSM8916`——
#      OpenStick 的 aboot.bin 实际是 CAF lk1st primary bootloader，不是 lk2nd，
#      也不会去找 extlinux。lk2nd 在官方流程里只在阶段 1 临时刷入、用于
#      `oem dump` 备份校准分区，随后被 `fastboot erase lk2nd` 清掉。
#
#   3) ext2/extlinux 启动链。lk1st 走标准 CAF `boot_linux_from_mmc`（按
#      Android boot.img + appended DTB 启动），`fastboot boot` 会对裸 ext2 报
#      `dtb not found`。真正可用的配方是 UFI 系已验证的 inline 布局：
#      kernel 段 = Image.gz + 紧跟其后的 mainline DTB，header 里 kernel_size
#      包含 DTB、dt_size=0，lk1st 靠 appended DTB magic 定位设备树。
#
#   4) 硬编码 7.2.9 的 rootfs 路径，升级内核后必然指错文件。
#
# 替代品：tools/dist/openstick-official-flash.sh —— 逐行复刻 OpenStick 官方
# base/flash.sh 的三阶段流程（临时 lk2nd 备份校准分区 → 原厂 LK 刷官方 GPT 与
# bootloader → 写本项目的 rootfs 与 boot），带每步前置校验与失败即停。

echo "mf32-openstick-flash.sh 已废弃：它写自创 GPT + lk2nd/extlinux 引导链，" >&2
echo "实测证伪（设备实际是 lk1st + inline Android boot.img）。" >&2
echo "请改用：tools/dist/openstick-official-flash.sh" >&2
exit 1
