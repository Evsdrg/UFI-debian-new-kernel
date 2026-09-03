# UFI00x boot.img 预生成产物

## cmdline 差异(关键)
| 版型 | root 定位 | cmdline |
|---|---|---|
| ufi003 (UFI103s) | PARTUUID (实机) | earlycon console=ttyMSM0,115200 root=PARTUUID=a7ab80e8-e9d1-e8cd-f157-93f69b1d141e rw rootwait |
| ufi001b / ufi001c | /dev/mmcblk0p14 (HandsomeMod默认) | earlycon console=ttyMSM0,115200 root=/dev/mmcblk0p14 rw rootwait |

## 产物 (out/boot/, 均含 6.18.48-ufi003 内核)
- boot-ufi003-6.18.img   (10956800 bytes, WCN3620 dtb, PARTUUID)
- boot-ufi001c-6.18.img  (10956800 bytes, WCN3660b dtb, /dev/mmcblk0p14)
- boot-ufi001b-6.18.img  (10956800 bytes, WCN3660b dtb, /dev/mmcblk0p14)

## 说明
ufi001b/c 无实机 PARTUUID 数据, 采用 HandsomeMod 构建系统默认的设备节点路径
root=/dev/mmcblk0p14(经 OpenStick 验证)。若后续拿到实机 /proc/cmdline,
可改为对应 PARTUUID 更稳。
