# Debian 13 rootfs 启动问题修复

串口日志证明 6.18 内核、DTS、eMMC 和 Debian 13 systemd 均已启动；失败原因是 rootfs 用户空间配置不完整。

## 已修复

- 加入 `kmod`/`udev`，提供 `/sbin/modprobe` 和模块自动加载
- 加入 `wireless-regdb`，使用 Debian alternatives 的 debian-signed `regulatory.db`
- 创建 `/dev/hugepages`、`/dev/mqueue`、`/run/lock`、`/tmp` 挂载目录
- 删除 `/etc/fstab` 中重复的 `/tmp` tmpfs 项，交给 systemd `tmp.mount`
- 删除错误的 `systemd-resolved` `FirstJournal` override
- 默认 target 设置为 `multi-user.target`
- 明确启用 networkd、resolved、wpa_supplicant@wlan0、ModemManager、qrtr-ns、rmtfs、zram-setup、ssh
- 确保 6.18.48-ufix0x 模块树完整（wcn36xx/q6v5/bam_dmux/zram/zsmalloc）
- root 密码设为 `REDACTED`，SSH 允许 root 密码登录

## 本地验证

所有修复项通过 user namespace 下的文件级检查：
- rootfs: 357MiB
- tar: 125MiB
- tar md5: `bf4b40bc9c1ab82f0df1cbc5ae1723fb`
- Debian version: 13.6
- NetworkManager: absent
