# 103s — IPQ4019 Debian 13 build

目标设备：**Qualcomm IPQ4019** 高通410棒子 (局域网内 192.0.2.14，debian11-Zt)

目标系统：**Debian 13 (trixie)** + **Linux 6.18** 自编译内核 + ath10k Wi-Fi

## 工作区目录

```
103s/
├── README.md          本文件
├── .gitignore         忽略内核编译产物、rootfs 镜像、工具链
└── ...                后续放置内核配置、构建脚本、根文件系统构建等
```

## 关键事实速查

- 设备: 192.0.2.14 (debian11-Zt)
- 架构: aarch64 / arm64
- 当前内核: 5.15.0-jsbsbxjxh66+ (高通厂商定制)
- Wi-Fi: ath10k (QCA4019/hw1.0)
- 目标内核: 6.18.x mainline
- 目标用户空间: Debian 13 trixie arm64

## 参考资料

- Linux kernel tree: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
- OpenWrt ipq40xx target: https://openwrt.org/docs/techref/targets/ipq40xx
- ath10k driver: drivers/net/wireless/ath/ath10k/
- DTS 文件位置: arch/arm64/boot/dts/qcom-ipq40xx/