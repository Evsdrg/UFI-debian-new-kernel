# 网络与语言（NetworkManager + 中文）

## 为什么用 NetworkManager

早期镜像是 `systemd-networkd` + `wpa_supplicant` 的固定化配置（SSID 写死、要改
网络得进串口编辑配置文件）。换成 NetworkManager 是为了**方便用户上手**：

```sh
nmtui                     # 全屏中文界面，选 Wi-Fi、输密码
nmcli device wifi list    # 命令行扫描
nmcli device wifi connect <SSID> password <PSK>
```

不用碰配置文件，改网络不用重启。

## 已实测（2026-09-14，UFI103s）

| 项目 | 结果 |
|---|---|
| NM 接管 wlan0 | `nmcli device status` → `wlan0 wifi 已连接 openstick-wifi` |
| 开机自动联网 | 重启后 uptime 41s 时已拿到 IPv4 并 SSH 可用 |
| DNS | `resolvectl` → `223.6.6.6 1.0.0.3 fe80::1` |
| 4G | NM 报 `wwan0qmi0 gsm 不可用`（无 SIM，符合预期）；ModemManager 正常 |
| LED | 新脚本走 nmcli 分支，Wi-Fi 判为 `solid` |

## 踩过的坑（已修进构建脚本）

**`wpa_supplicant@wlan0.service` 会抢网卡。** 从 networkd 方案切换过来时，如果
这个每接口的 wpa_supplicant 仍被启用，它会先占住 wlan0，NM 随后反复失败：

```
device (wlan0): Couldn't initialize supplicant interface:
  GDBus.Error:fi.w1.wpa_supplicant1.UnknownError:
  wpa_supplicant couldn't grab this interface.
device (wlan0): supplicant interface keeps failing, giving up
```

现象是 `wlan0` 开机后一直 `unavailable`，NM 死活连不上。**注意别误删全局的
`wpa_supplicant.service`**——NM 是通过 D-Bus 让这个全局实例干活的
（`wpa_supplicant -u -s -O DIR=/run/wpa_supplicant`），删了 Wi-Fi 反而不能用。
要禁用的只是**每接口**的 `wpa_supplicant@<iface>.service`。

另外 `systemd-networkd.socket` 也要一并禁用：它是 socket 激活的，只删 service
的软链没用，socket 被访问时会自己把 networkd 拉起来。

构建脚本现在会清掉这几项并做断言（见 `build-rootfs.sh` 的 customize hooks）：
`systemd-networkd.service`、`systemd-networkd.socket`、`wpa_supplicant@wlan0.service`
的启用软链，以及早期方案遗留的 `/etc/wpa_supplicant/wpa_supplicant-wlan0.conf`。

## 中文

系统默认简体中文（`zh_CN.UTF-8`）。已实测的输出：

```
$ nmcli general status
STATE   CONNECTIVITY  WIFI-HW  WIFI    WWAN-HW  WWAN    METERED
已连接  完全          已启用   已启用  已启用   已启用  否（猜测）

$ man 1 access
NAME(名称)
       access - 确定文件是否可以存取访问
```

### 三个必须一起装的包

| 包 | 作用 | 不装的后果 |
|---|---|---|
| `locales` | locale 数据与 `locale-gen` | 没有 zh_CN，中文全变问号或回退英文 |
| `network-manager-l10n` | NetworkManager 的翻译 | `nmcli`/`nmtui` 全是英文 |
| `man-db` + `manpages-zh` | man 命令 + 中文手册 | 有手册文件但没有 `man` 命令可用 |

`network-manager-l10n` 容易被漏掉：NM 主包只 **Recommends** 它，不是硬依赖，
所以必须显式安装。`manpages-zh` 同理——它只是页面文件，`man` 命令在 `man-db` 里。

### 只有写 locale.gen 是不够的

早期镜像的一个 bug：脚本往 `/etc/locale.gen` 追加了 `zh_CN.UTF-8 UTF-8`，但
mmdebstrap 的 apt variant **不会自动跑 `locale-gen`**。结果 `locale -a` 里只有
C/POSIX，`LANG=zh_CN.UTF-8` 无效，中文实际是坏的。

现在构建脚本会：
1. 取消 `locale.gen` 里 `zh_CN.UTF-8` 那行的注释；
2. `chroot ... locale-gen` 真正生成；
3. **断言** `locale -a` 里确实有 `zh_CN.utf8`；
4. `update-locale LANG=zh_CN.UTF-8 LANGUAGE=zh_CN:zh` 写入 `/etc/default/locale`。

## 换回英文（或别的语言）

```sh
dpkg-reconfigure locales        # 生成需要的 locale
update-locale LANG=en_US.UTF-8  # 或 zh_TW.UTF-8 等
# 重新登录生效
```

## 相关文件

| 路径 | 内容 |
|---|---|
| `/etc/NetworkManager/NetworkManager.conf` | keyfile 后端 |
| `/etc/NetworkManager/conf.d/10-openstick.conf` | 设备/连接策略（DHCP 超时 30s） |
| `/etc/NetworkManager/system-connections/` | Wi-Fi 连接（keyfile，权限 600） |
| `/etc/default/locale` | 默认语言 |
| `/etc/locale.gen` | 要生成的 locale 列表 |

构建脚本里的相关变量：`ROOTFS_WIFI_SSID` / `ROOTFS_WIFI_PSK`（预置 Wi-Fi，
不设则镜像不带预置网络，用户用 nmtui 自己配）。
