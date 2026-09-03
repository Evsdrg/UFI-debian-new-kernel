# UFI00x / SP970 / UZ801 boot.img 预生成产物

## 通用内核
- 版本: 6.18.48-ufix0x-dirty (GCC -O2, 精简配置, zram zstd, 无音频codec)
- 统一内核, 每个板子只换 dtb + cmdline

## cmdline 差异
| 板型 | root 定位 | cmdline |
|---|---|---|
| ufi103s (UFI103s) | PARTUUID (实机) | earlycon console=ttyMSM0,115200 root=PARTUUID=a7ab80e8-e9d1-e8cd-f157-93f69b1d141e rw rootwait |
| ufi001b / ufi001c | /dev/mmcblk0p14 | earlycon console=ttyMSM0,115200 root=/dev/mmcblk0p14 rw rootwait |
| sp970 / uz801 | /dev/mmcblk0p14 | 同上 |

## 产物 (out/boot/, 均含 6.18.48-ufix0x 内核)
- boot-ufi103s-6.18.img  (WCN3620 dtb, PARTUUID)
- boot-ufi001c-6.18.img  (WCN3660b dtb, /dev/mmcblk0p14)
- boot-ufi001b-6.18.img  (WCN3660b, 单SIM, /dev/mmcblk0p14)
- boot-sp970-6.18.img    (WCN3660b, /dev/mmcblk0p14)
- boot-uz801-6.18.img    (WCN3660b, /dev/mmcblk0p14)

## 原厂备份
- boot-original-p12.img 从设备 mmcblk0p12 (5.15 原厂内核) 恢复
- 原始备份在设备 /root/boot-backup-5.15.img 仍保留
- CPU超频研究: 见 CPU-OVERCLOCKING.md
