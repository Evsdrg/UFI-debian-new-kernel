# 蓝牙（Bluetooth）

一句话：**内核侧一直就绪，缺的只是用户态 bluez；装上即用，重启后自动恢复。**

## 现状：为什么"没打开"

开机时 `hci0` 其实已经存在：

```
$ ls /sys/class/bluetooth/
hci0
$ hciconfig hci0
hci0:  Type: Primary  Bus: SMD
       BD Address: 02:00:07:24:04:B0  ACL MTU: 1024:6  SCO MTU: 50:8
       UP RUNNING
```

链路是这样的：设备树的 `bluetooth` 节点（挂在 wcnss 的 smd-edge 下）→ `btqcomsmd`
驱动注册 HCI 设备 → 但**用户态完全没有 bluez**（镜像里只有个 `libbluetooth3`
是被别的包依赖带进来的），所以没有 `bluetoothctl`/`bluetoothd`，看起来像"没蓝牙"。

## 一个容易查错的地方：BT 固件不需要单独提供

`btqcomsmd_setup()` 只做两件事：

```c
skb = __hci_cmd_sync(hdev, HCI_OP_RESET, 0, NULL, HCI_INIT_TIMEOUT);
hci_set_quirk(hdev, HCI_QUIRK_USE_BDADDR_PROPERTY);   /* 从 DTS 取地址 */
```

它**不加载任何 QCA 蓝牙固件**（不像 USB 蓝牙那样需要 `qca/crbtfw*.tlv` +
`qca/crnv*.bin`）。WCNSS 的固件是一起跑的，蓝牙只是它的一个通道。

所以镜像里没有 `qca/` 目录、`btqca.ko` 也没被用到，**都属正常**，不要去
`/lib/firmware/qca/` 找固件然后判定"驱动缺固件"。

BD 地址来自设备树：

```
$ cat /proc/device-tree/soc@0/remoteproc@a204000/smd-edge/wcnss/bluetooth/local-bd-address
b0 04 24 07 00 02
```

它与 `wlan0` 的 MAC（`02:00:07:24:04:b1`）是连号的，符合预期。

## 修复：装 bluez

镜像构建已把 `bluez` 与 `rfkill` 加进**所有档位**的 `PKGS_BASE`
（`build-rootfs.sh`）。手工安装等价于：

```sh
apt-get install -y --no-install-recommends bluez rfkill
systemctl enable --now bluetooth
```

体积代价约 **5.5 MB**（bluez）+ 0.3 MB（rfkill）。`build-rootfs.sh` 里
`bluetooth.service` 已按存在性判断加入开机启用列表。

## 实测结果（2026-09-15，7.1.13）

| 项 | 结果 |
|---|---|
| `hci0` 状态 | `UP RUNNING`，`RX/TX errors: 0` |
| `rfkill` | Bluetooth 未被软/硬阻塞 |
| 控制器 | `Powered: yes`、`Discoverable: no`（默认） |
| 扫描 | 10 秒扫到 6 个真实设备，含名称与 BLE 广播数据 |

扫描输出（节选）：

```
[NEW] Device 0C:CD:B4:BD:9B:B5 0C-CD-B4-BD-9B-B5
[CHG] Device 0C:CD:B4:BD:9B:B5 Name: 红米G Pro 32U 2026
[CHG] Device 0C:CD:B4:BD:9B:B5 ManufacturerData.Key: 0x038f (911)
[NEW] Device A4:C1:38:B3:9B:B4 MJWSD05MMC
```

能解出中文设备名和 BLE 广播字段，说明控制器与协议栈都工作正常。

**重启后自动恢复**已验证：`bluetooth.service` active、`hci0` UP RUNNING、
`Powered: yes`，无需任何手动操作。

## 常用命令

```sh
bluetoothctl show              # 控制器状态
bluetoothctl --timeout 10 scan on   # 扫描
bluetoothctl devices           # 已发现设备
bluetoothctl pair <MAC>        # 配对（需先 agent on）
bluetoothctl connect <MAC>
rfkill list                    # 是否被阻塞
```

## 已知限制

- **BD 地址用的是 DTS 里的值**（`b0:04:24:07:00:02`），而
  `hciconfig` 显示的是 `02:00:07:24:04:B0` —— 两者是同一地址的字节序/
  显示差异，不是两个不同地址。这个地址对所有 UFI103s 都是一样的，
  所以多台设备同时工作时会冲突；需要的话可在 DTS 里改，或用
  `bluetoothctl` 运行时覆盖。
- 本设备**没有音频通路**（无音箱/耳机接口），所以 A2DP/HFP 这类用途意义有限；
  蓝牙主要用于 BLE 外设与数据透传。
