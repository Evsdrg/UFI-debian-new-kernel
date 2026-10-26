# 踩坑与解决记录（问题清单）

按「现象 → 根因 → 修法 → 证据」组织，只收**已经定案**的条目。尚未解决的问题
在 `docs/build/TOOLING.md` 的「缺口」一节；实机验收的未通过项在
`docs/validation/`。

平台的**硬约束**（违反会静默出错或变砖的那类）在 `CONTRIBUTING.md` §2 与 §3，
本文件不重复，只记这些约束是**怎么被发现和修掉的**。

---

## 1. 串口速率：不是适配器偏差，是 getty 沿用了旧速率

**现象**：主机按 115200 抓串口解不出可读内容。

**根因**：`serial-getty@ttyMSM0` 用 `agetty --keep-baud 115200,57600,38400,9600`，
`--keep-baud` 会**保持端口上次遗留的速率**，而不是强制列表里第一个。

**修法**：在设备上 `stty -F /dev/ttyMSM0 115200` 复位，再按 115200 抓。两端
本来就是 115200（cmdline 是 `earlycon console=ttyMSM0,115200`）。

**证据**：主机逐档抓包只有 115200 可读，57600/230400 是乱码、9600 无输出。
这个 CH343（USB `1a86:55d3`，CDC-ACM 模式）**确实遵守主机设的波特率**，
不存在"适配器时钟偏差"。

**顺带**：端口名每次重插都会变（同一类适配器先后以 `ch341-uart` 与 `cdc_acm`
绑定，tty 名与 USB 序列号都变）。用前 `tools/ufi-console.sh id` 确认，
不确定时用波特率扫描识别端口。

---

## 2. 不带看门狗的软件重启会把板子挂死

**现象**：`systemctl reboot` 在 `qcom-wcnss-pil: unexpected response to sysmon
event`（remoteproc1/modem teardown）之后卡住，接着 `rcu_preempt detected stalls`
无限重复。日志里还有 `Failed to set watchdog hardware timeout to 10min:
Invalid argument`。

**根因**：PM8916 PON 看门狗只接受 **1..127 秒**
（`pm8916_wdt.c`：`PM8916_WDT_MIN_TIMEOUT=1`、`MAX_TIMEOUT=127`；DTS
`timeout-sec=60`）。systemd 257 的 `RebootWatchdogSec` 默认是 10 分钟 = 600 s，
远超范围，**看门狗武装失败，硬件没有兜底**。

**修法**：`/etc/systemd/system.conf.d/10-watchdog.conf` 设
`RuntimeWatchdogSec=60s` + `RebootWatchdogSec=60s`（已固化进 `build-rootfs.sh`），
然后 `systemctl daemon-reexec`。

**证据**：修后 `RebootWatchdogUSec=1min`，systemd/PID 1 持有 `/dev/watchdog0`。
硬件验证：武装 15 s 后停止喂狗 → 约 12 s 掉网、约 21 s 回来、systemd 时间回到
1970（无 RTC，即冷复位），事后 `wdctl` 报 `CARDRESET boot-status = 1`。
**看门狗复位是一次干净启动**，与卡死的软件重启不同。

---

## 3. rmtfs 开机被静默跳过，modem remoteproc 一直离线

**现象**：4G 不工作，但没有任何报错。

**根因**：`rmtfs.service` 依赖 `qcom_rmtfs_mem1` 的 systemd `.device` 单元，
而该节点由 `rmtfs_mem` 模块创建，开机时那个单元并不可靠地 active。

**修法**：加 udev 规则
`ACTION=="add", SUBSYSTEM=="rmtfs", ENV{SYSTEMD_WANTS}+="rmtfs.service"`，
配合有界的 `ExecStartPre` 重试。

**证据**：跨一次重启验证 rmtfs active、remoteproc0/1 running。

---

## 4. 每次 apt 都刷 debconf frontend 回退警告

**现象**：设备上每次 apt 运行都打印
`debconf: unable to initialize frontend: Dialog ... falling back to frontend:
Readline ... Teletype` 三行。

**根因**：`Debconf::Config->frontend()` 的解析顺序是
`$DEBIAN_FRONTEND` → 数据库里的 `debconf/frontend` → 内建默认 `dialog`。
镜像里既没有 dialog/whiptail 也没有 `Term/ReadLine.pm`，而数据库把
`debconf/frontend` 设成 Dialog，**所以回退链每次都会跑**；就算数据库是干净的，
内建默认 `dialog` 也照样告警。

**修法**（已进 `build-rootfs.sh`）：`/etc/environment` 里固化
`DEBIAN_FRONTEND=noninteractive`、mmdebstrap 本身也带这个变量、再加一个
`debconf-set-selections` 的 hook 把 `debconf/frontend` 设为 Noninteractive。

**证据**：设备上 `DEBIAN_FRONTEND=noninteractive /usr/share/debconf/frontend <script>`
完全无警告；不设时会精确复现那三行。

---

## 5. 监管域被 Signing 变体顶掉，`iw reg set CN` 静默失效

**现象**：cfg80211 报 `loaded regulatory.db is malformed or signature is
missing/invalid`，`iw reg get` 停在 country 00（world），`iw reg set CN` 被忽略。

**根因**：cfg80211 用内核内建证书校验 `regulatory.db`。本内核带的是 upstream
证书（`net/wireless/certs/wens.hex`、`sforshee.hex`），而 `wireless-regdb` 的
postinst 把 Debian 签名变体（`-debian`）以优先级 100 注册、upstream 变体
（`-upstream`）以 50 —— **默认选中那个过不了校验**。cfg80211 于是退回 world
域，且因为 `regdb_query_database()` 返回 `-ENODATA`，连用户提示也一起忽略。

**修法**：选中 upstream 变体
`update-alternatives --set regulatory.db /lib/firmware/regulatory.db-upstream`
（两个 hook：设置 + 断言软链指向 `-upstream`，回归会让构建失败）。

**证据**：两个 db 的正文**逐字节相同**（sha256 `2fb33ca0…`），只有 detached
签名不同；把 `wens.hex` 解出来与 `-upstream` 签名证书 `cmp` 完全一致
（sha256 `eeb04959…`）。设备上应用并重启后 dmesg 干净，`iw reg get` 显示
country CN: DFS-FCC，ch12/13 变为可用（world 域下是 "no IR"），ch14 正确禁用。
这是**持久化的 alternatives 改动**，重启后仍生效。

---

## 6. 内核模块增量构建的三个坑

- 必须用 **`make modules`（整棵树）**，不能用 `make <dir>/` —— 目录目标只跑
  `checksyscalls`，**不会重新链接**。
- **不要用 `make M=<dir>`**：它会往**源码树**写对象文件，与 `O=` 混用时很危险。
- **不要手工删 `.o`**：会截断 `Module.symvers`，导致 modpost 报一堆 `undefined!`。
  补救办法同样是 `make modules` 重建。

---

## 7. Venus 客户端侧的三个非驱动问题

驱动没毛病，是客户端用法：

1. **ffmpeg 的 v4l2m2m 编码器不回读驱动调整后的尺寸**，所以传非对齐尺寸会让
   它自己段错误（用户态崩溃，内核干净）。命令行先 pad：
   `-vf "scale=1280:736,format=nv12"`。
2. **解码必须加 `-fps_mode passthrough`**：m2m 驱动每帧上报 timestamp 0，
   默认 vsync 会把几乎每帧都丢掉。
3. **`/dev/videoN` 每次启动会换号**，要用稳定名 `/dev/video-encoder`、
   `/dev/video-decoder`（`70-venus-video.rules`）。

解码不需要 pad：`vdec_try_fmt_common()` 只对齐 capture（画面）几何，coded
几何保持码流本身，这是 V4L2 的正确规则。

---

## 8. Venus：一个 0 帧的坏素材曾被我误判成"驱动死锁"

**现象**：1080p60 硬编"挂死"，8 个线程全停在 `futex_do_wait`，
`timeout`/SIGTERM/SIGKILL 全部无效，进程一直持有 `/dev/video0` 与 CMA 缓冲。

**根因**：测试素材本身是坏的 —— 从 36 秒的源里 `-ss 60` 剪，得到的文件
`duration 2.65s`、`nb_read_frames=N/A`（0 帧）。喂 0 帧给 v4l2m2m 会卡在
不可杀死的 futex 等待。**不是内核问题**：同一时刻 venus 设备响应正常
（`v4l2-ctl --list-formats` 成功），进程状态是 `S` 而非 `D`。

**后果**：卡死进程占住 CMA（`CmaFree` 从 28 MB 掉到 48 kB），此后所有 venus
操作都失败，形成连锁症状。只能重启清除。

**教训**：
- 剪素材后务必核对 `nb_read_frames`，`-ss` 越界会产生 0 帧垃圾输入。
- `CmaFree` 掉到几 kB 且 `venus_enc` 引用计数不归零 → 有会话 wedged，重启，
  别继续试。

---

## 9. USB 共享：NetworkManager "激活成功"不等于 NAT 成功

完整记录见 `docs/validation/2026-10-10-usb-fix.md`（含修复范围、实机回归与交付断言）。
这里只留最反直觉、以后最难重新推导出来的几点。

**NM 的防火墙执行是 fire-and-forget。** 在 NetworkManager 1.52.1 源码里：

- `src/core/nm-firewall-utils.c:702–770`：共享 IPv4 生成 **`table ip`**（不是
  `table inet`），内容含 `masquerade`、`ct state { established, related }` 与两条
  `reject`。
- `src/core/nm-firewall-utils.c:1225–1246`：`nm_firewall_config_apply_sync()`
  返回 **`void`**，nft 提交失败不向设备激活流程传播；
  `src/core/devices/nm-device.c:13581–13586` 随后继续处理连接。
- `nm-firewall-utils.c:1251–1260`：先找 nft，再找 iptables；**两者都不存在时仍选
  nft 后端** —— 不是"缺 nft 就自动免防火墙工作"。
- `nm-firewall-utils.c:1262–1300`：后端是**进程内静态缓存**并读原始配置，所以
  `nmcli general reload` 不能当作切换后端/清缓存的保证。

结论：**看到 connected、DHCP 也拿到地址，仍然可能完全没有 NAT**。必须实测从
客户端访问上游，并确认来源地址是棒子而不是客户端自己的网卡。

**内核缺项比看上去多。** 五个变体原本都缺 `NFT_CT` 和 `NFT_REJECT`，但
`NFT_REJECT` 是**隐藏选项**，只设它两行不够：内核 Kconfig
（`net/netfilter/Kconfig:578–590`、`net/ipv4/netfilter/Kconfig:42–45` 与 IPv6
对应项）会派生出一整组家族模块 —— `NFT_REJECT_INET/_IPV4/_IPV6` 与
`NF_REJECT_IPV4/_IPV6`。**验收要看最终 `.config` 与模块树闭包，不是看补了哪几行。**

**gadget 的 `test -s UDC` 是错的判据。** configfs 属性 inode 的 `stat` 大小固定为
PAGE_SIZE（现场实测 4096），与内容无关；半装配后未绑定的 gadget 会被误判为已装好。
要读实际 UDC 名。

**原生路径也不是天然替代。** 修之前，native 栈有启动竞态
（`Wants=network-online.target` 不等于 `After=`）、没限定来源的 masquerade、
停止不删自己的表、后台 dnsmasq 无监督等问题。

**QEMU 冒烟不能证明 USB 可用**：`tools/qemu-smoke.sh` 有意过滤了 usb-gadget 与
native-net 的失败（QEMU 无真实 UDC），所以七镜像 PASS 与这两套栈无关。

---

## 10. `pkill -f` 会杀掉自己的 shell

`pkill -f "<pattern>"` 匹配完整命令行，而正在执行的那条命令本身（含 pattern
文字）就在命令行里 —— 结果是工具会话自杀。本工程被这条坑到多次。

**做法**：用 PID 列表精确 kill，或扫 `/proc/*/cmdline` 按内容挑。同理
`pgrep -x` 对超过 15 字符的进程名**永远匹配不到**（内核 `comm` 字段截断到
15 字符），要按完整命令行匹配就扫 `/proc`。

---

## 11. 宿主缺 arm64 探针，mmdebstrap 拒绝构建 rootfs

**现象**：`E: arm64 can neither be executed natively nor via qemu user emulation
with binfmt_misc`。

**根因**：宿主 AOSC OS 的 `arch-test` 包只带 x86 家族探针
（`/usr/libexec/arch-test/` 里只有 amd64/i386/x32/kfreebsd-*/illumos-amd64），
**不认识 arm64**，于是 mmdebstrap 的模拟能力检测失败。这个报错**具误导性** ——
binfmt_misc 与 `qemu-aarch64-static` 其实都是好的。

**修法**：从 Debian 的 `arch-test` 包（`Architecture: all`，带全架构探针）取出
arm64 那一个，放到宿主 `/usr/libexec/arch-test/arm64`。**只补这一个**，不要覆盖
AOSC 原有的 x86 探针。

```sh
curl -fsSL -o /tmp/arch-test.deb \
  https://mirrors.cernet.edu.cn/debian/pool/main/a/arch-test/arch-test_0.22-1.1_all.deb
dpkg-deb -x /tmp/arch-test.deb /tmp/arch-test-ext
sudo cp /tmp/arch-test-ext/usr/libexec/arch-test/arm64 /usr/libexec/arch-test/arm64
arch-test arm64      # 期望：arm64: ok
```

---

## 12. ⚠️ CMA 被 movable 分配借用，`CmaFree` 会假性见底

**现象**：MPEG-4 固件 fatal 之后，`CmaFree` 跌到 **108 KB**（`CmaTotal` 32 MB），
但 `/sys/kernel/debug/dma_buf/bufinfo` **为空**、`pgrep ffmpeg` **无进程**，
看着像 venus 缓冲泄漏。

**根因**：不是 venus 泄漏。`MemFree` 当时只有 26 MB，**内存压力下 movable
pageblock 借用了 CMA 区域**，CMA 空闲页因此不可见。

**证据**：`sync; echo 3 > /proc/sys/vm/drop_caches` 后，`CmaFree`
108 KB → **10 MB**，`MemFree` 同时 26 MB → 127 MB（2026-10-16 实测）。

**修法**：吃 CMA 的负载（venus 编解码、GPU 推流）启动**前**先 `drop_caches`，
并把 `MemFree`/`MemAvailable` 一起记录 —— 只看 `CmaFree` 会误判成泄漏。

## 13. ⚠️ MPEG-4 固件 fatal 后 WiFi 会暂时掉到 MCS 0

**现象**：MPEG-4 硬解触发固件 fatal 后，`tx bitrate` 一度掉到
**13.5 Mbit/s MCS 0**（iperf3 实测约 2.4 Mbit/s），数分钟后自愈回
**90 Mbit/s MCS 4**（约 49–53 Mbit/s）。同期 `rx bitrate` 始终正常。

**排查**：补丁 0002 确认**已生效** —— 设备上 `wcn36xx.ko` 与
`artifacts/modules/` 中对应文件**哈希一致**，源码树 `smd.c:56` 为
`WCN36XX_CFG_VAL(MAX_MEDIUM_TIME, 20000)`。

注意 `smd.c:104` 另有一个 `MAX_MEDIUM_TIME, 4096`，它属于
`wcn3680_cfg_vals[]`（WCN3680），**不适用于本板的 WCN3620**，勿据此判断补丁未生效。

**结论**：是 fatal 之后的**暂时劣化**，不是速率自适应卡死（MCS0 会恢复）。
若在 fatal 后立刻测吞吐，数字不可信；**应等速率回到 MCS 4 再测**。

## 14. ⚠️ xrdp 会话不会随 SSH 断开而回收

**现象**：RDP 客户端断开后，设备侧 `loginctl list-sessions` 仍显示残留会话，
`pgrep xterm` 可见残留终端（内含历史内容，**有明文口令风险**）。

**修法**：用 `pgrep -x xterm` **按进程名精确杀**（`pgrep -x` 对超 15 字符
进程名零匹配，这里 `xterm` 长度安全）。

**禁止**：用 `loginctl terminate-session` 清理 —— 它会连带杀掉 console 会话，
把正在用的 SSH 一起断掉（2026-10-16 踩过，SSH 中断后需重连）。

---

## 15. ⚠️ 凭据文件里的裸反斜杠转义会让镜像静默失联

**现象**：7 张 rootfs 镜像的预置 Wi-Fi `psk=` 变成了
`            <真实口令>`（**11 个前导空格 + 真口令**），而设备在用的是 `<真实口令>`。
若直接刷入，开机连不上 AP；棒子无屏、USB 共享的 NAT 上游又正是 WiFi，
**刷完即失联**。构建与开机全程无报错。

**根因**：`.local-creds` 里写成 `ROOTFS_WIFI_PSK='\ \ \ \ \ \ \ \ \ \ \ <真实口令>'`
（想转义空格）。单引号内反斜杠**不被展开**，source 后得到字面反斜杠；
而 `.wifi-creds` 写成不带引号的 `\ \ …`，source 时被 shell 展开成空格。
两种写法都不对：正确写法是 `ROOTFS_WIFI_PSK='真实口令'`（单引号，无裸反斜杠）。

**修法**（2026-10-16，**两阶段**）：

先是就地修值：
1. `.local-creds` 的 `ROOTFS_WIFI_PSK` 改为单引号包真实口令；
   删除无任何脚本引用的重复文件 `.wifi-creds`。
2. `build-rootfs.sh` 在“网络”一节开头加 `_ws_guard`：凭据值含前导/尾随空白
   就**直接拒绝构建**（错误信息指向裸反斜杠这个常见原因）。两档共用。
3. `.local-creds.example` 补上这条写法警告。
4. 重编 max 档并整机刷入验证（详见 `2026-10-16-validation.md`）。

随后**从结构上移除这个问题类别**（同日）：镜像改为**完全不预置 Wi-Fi**。
理由是这类缺陷的本质不是“值写错了”，而是**凭据会被静默写进镜像**：
只要还存在预置路径，就总有下一个写法/取值失误会再现同样的“刷完即失联”。
现在：
- `build-rootfs.sh` / `tools/build-matrix.sh` 不再读 `ROOTFS_WIFI_SSID` / `ROOTFS_WIFI_PSK`，
  相关的 heredoc、native 档的 `network{}` 段、`.local-creds.example` 里那两项全部删除；
- **首次进系统统一走 USB RNDIS**（无屏设备插电脑即得 `10.42.0.1`），
  配无线用 `nmtui` / `nmcli`；
- `_ws_guard` 保留，但守护对象改成 `ROOTFS_ROOT_PASSWORD`（口令带空白同样是
  “构建不报错、登录才发现”的隐式失效）；
- 交付断言反转为**拒绝带预置 Wi-Fi 的镜像**（`tools/verify-usb-sharing.py`）。

**教训**：凭据会被静默写进镜像，所以（1）不该带的凭据就不要带进去，
（2）必须带的（root 口令）在构建期校验并在产物上再验一道——
不能等到刷机后靠联网失败去发现。

---

## 16. 🚫 裁剪内核配置时 `QCOM_APCS_IPC=n` 会让设备硬挂死

**现象**：minimal（最简功能）内核用 `fastboot boot` 内存启动后，主机再无任何
USB 事件（无 RNDIS、无重启枚举），WiFi 不通，`panic=10` 也没有生效——
**完全静默，只能物理断电**。而同一个内核在 **QEMU 里能正常启动到 login**。

**根因**：`QCOM_CLK_APCS_MSM8916`（msm8916 的 CPU 时钟控制器，管 CPU 频率）
`depends on QCOM_APCS_IPC`。片段里写了 `CONFIG_QCOM_APCS_IPC=n`，于是
`QCOM_CLK_APCS_MSM8916` 的符号**整个消失**，内核在早期 CPU 频率初始化时挂死。
挂死点在 panic handler 尚未就绪之前，所以连 `panic=` 都不起作用。

**为何 QEMU 抓不到**：QEMU 的 `virt` 机器没有 msm8916 APCS 硬件，
`QCOM_CLK_APCS_MSM8916` 本就不会 probe，所以缺了也无感。
**“QEMU 冒烟 PASS”不能代替实机对平台驱动的覆盖。**

**修法**：片段里改回 `CONFIG_QCOM_APCS_IPC=y`，并在片段中写明原因。

**检出方法**（比逐个实机试快得多）：不要只看 `=n`，要看**符号是否还存在**。
对比 baseline 与裁剪后的 `.config`：

```sh
# baseline=y 但 minimal 里 CONFIG_X 与 "# CONFIG_X is not set" 都不存在的项
comm -23 <(grep -E '^CONFIG_[A-Z0-9_]+=y' baseline/.config | sort) \
         <(grep -E '^CONFIG_[A-Z0-9_]+=y' minimal/.config | sort)
```

“符号消失”比“被设成 n”危险得多：它意味着某个 `depends on` 被破坏，
上游（依赖者）也没了。先用这个方法筛一遍 msm8916 相关项，再上真机。

---

## 17. ⚠️ 裁剪 `INPUT_KEYBOARD` 会静默丢掉 DTS 的 Reset 按键

**现象**：minimal 能正常启动、WiFi/USB/zram 均正常，但 `/proc/bus/input/devices`
里只有 `pm8941_pwrkey`，DTS 里的 `gpio-keys`（Reset 键，`KEY_RESTART`）不枚举。
没有任何报错——**只有主动去查输入设备才能发现**。

**根因**：`CONFIG_KEYBOARD_GPIO` 位于 `drivers/input/keyboard/Kconfig` 的
`if INPUT_KEYBOARD` 块内。为了“只留电源键”而把 `CONFIG_INPUT_KEYBOARD=n`，
把 `gpio-keys` 的驱动一起切掉了；而 DTS 的两个按键节点分属两个子系统：
`gpio-keys` 用 `KEYBOARD_GPIO`，`pm8941-pwrkey` 用 `INPUT_MISC`。只保后者不够。

**修法**：`CONFIG_INPUT_KEYBOARD=y` + `CONFIG_KEYBOARD_GPIO=y`，
其余键盘驱动（`KEYBOARD_ATKBD` / `KEYBOARD_GPIO_POLLED` 等）仍 `=n`。

**教训**：裁剪时要按 **DTS 里 `status="okay"` 的每个节点**反查其驱动，
而不是按驱动菜单目录枚举。按键节点分属不同 menuconfig 是常见陷阱。

---

# 尚未闭环的问题
这些是**已定位但未定案**的。记录的是当前证据边界，不是结论。

## A. Venus MPEG-4 硬解触发固件 fatal

**现象**：640×480、45 帧的 MPEG-4 Simple Profile 素材，硬解触发
`Err_Fatal - Z:\b\venus\utils\src\vbuffer.c:1200`，只能重启恢复。
**旧内核 7.1.13 同样复现**，所以不是 7.2 独有的回归。

**已排除的误判**：

1. **素材不是空文件或超出能力**：离线 `ffprobe` 确认 640×480、Simple Profile、
   level=1、YUV420P、无 B 帧、extradata 47 字节，尺寸也是 32 对齐。
   （但这**不证明码流绝对规范**，也不证明所有 MPEG-4 输入都会失败。）
2. **"Cannot allocate memory" 不是 CMA 不足的证明**：FFmpeg n7.1.5 在
   `libavcodec/v4l2_m2m_dec.c:88–92` 把 CAPTURE 初始化的**任意错误统一改成
   ENOMEM**。日志里 buffer[0] 的原始错误是 **EIO**，更应关注 ioctl 路径。
   错误传播链：`v4l2_context.c:724–750`（REQBUFS）→ `v4l2_buffers.c:494–557`
   （QUERYBUF/mmap/QBUF）→ 内核 `vdec.c:1590–1625` 收到 session error 后置
   vb2 queue error → 后续准备/入队返回 EIO。
3. **`vbuffer.c:1200` 是固件内部路径**，不是主线树里可以直接改的 C 文件。
   `hfi_venus.c:1049–1075` 只是打印固件 SFR。

**尚未排除的三类原因**（需先补时间线，再选方向）：

| 假设 | 下一步所需证据 |
|---|---|
| 码流特征触发老固件问题 | 另一份独立 Simple Profile 素材、其它客户端对照 |
| HFI1xx 缓冲/状态协商错误 | 记录 G_FMT/REQBUFS/QBUF 的尺寸、实际数量及 HFI seq-change/bufreq |
| FFmpeg 时序与本地 vdec 兼容补丁交互 | 事件驱动 V4L2 客户端 vs FFmpeg，pristine/local vdec 对照 |

**约束**："旧内核也失败"只能排除"7.2 独有"，**不能替相同 FFmpeg/固件/本地补丁
排除责任**。解码默认 OUTPUT=16、CAPTURE=20，驱动还会按固件 minimum 提高数量；
缩小数量的试验必须看 ioctl 实际返回值，CmaFree 低既不能证明根因也不能证明无资源
问题。**当前处理：不扩大 CMA、不换猜测的固件、不 rmmod**；已有素材的 MPEG-4
硬解记作不可用，业务选软件解码。

## B. 持续负载的散热与推流 CPU 成本

**散热**：本地公共 dtsi 把 CPU 被动冷却阈值从**上游的 75 °C 改成 85 °C**。
所以 2026-10-10 测试在 80 °C 中止时**还没到 CPU 热节流点** —— 不能声称
"自动热节流没用"，也不能凭 DTS 注释声称持续负载已受控。详见
`docs/hardware/CPU-POWER.md`。

**推流 CPU 成本（纯软件隔离实验）**：设备 `/tmp` 放一帧 BGRA，rawvideo 循环读
同一帧输出 null，每组 90 帧，CPU 临时限 800 MHz，无 GPU、无 Venus、无网络：

| 路径 | 耗时 | 帧/秒 | 用户+系统 CPU 秒 | 峰值 RSS |
|---|---:|---:|---:|---:|
| BGRA passthrough 对照 | 1.035 s | 86.96 | 1.091 | 58,064 KiB |
| BGRA→NV12，1 过滤线程 | 7.597 s | 11.85 | 8.871 | 102,220 KiB |
| BGRA→NV12，4 过滤线程 | 3.026 s | 29.74 | 9.645 | 103,636 KiB |
| BGRA→NV12，1 线程，`-cpuflags 0` | 12.127 s | 7.42 | 13.331 | 105,904 KiB |

四线程组换算到 30 fps 约需 **3.2 CPU 秒/秒**（整个隔离进程的成本，含 tmpfs 读入
与 FFmpeg 调度，**不是 swscale 函数级 profile**）。
`libswscale/aarch64/swscale.c:241–300` 已有 BGRA 输入的 NEON 选择，
**不能笼统诊断成"没开 NEON"**（`-cpuflags 0` 关掉的不止一个转换函数）。

**链路数据量**（1280×736@30，是数据量不是 DRAM 带宽）：

- BGRA：每帧 3,768,320 字节 → FIFO **113.05 MB/s**
- NV12：每帧 1,413,120 字节 → **42.39 MB/s**
- FFmpeg 编码默认 16 个原始 INPUT 缓冲，按 `helpers.c` 的 NV12 帧大小约
  **21.56 MiB**（4 个为 5.39 MiB）。但 `venc.c:1181–1183` 仍按固件需求提高
  最低数量，**实际数量未测，节省尚未兑现**；不能把映射、RSS、PSS、CMA 相加。

**候选方案与各自局限**（按推荐顺序）：

1. **先量化分段、减搬运，不先加线程。** 让 wf-recorder 输出 NV12 rawvideo 到
   FIFO（它 0.5 支持 `-x` 格式选择与格式过滤图），FIFO 载荷可减 62.5%。
   但颜色转换仍存在，只是移到采集端；性能、色彩范围与缓冲要重测，
   **不能称"零拷贝"**。
2. **有限降低缓冲并限制队列。** 实测驱动返回数量、PSS 与 SwapPss，再评估
   4–8 个 INPUT 是否可用；必须验证抖动、重连与长稳，不能只看 RSS 下降。
3. **谨慎评估单进程采集→硬编。** wf-recorder `frame-writer.cpp:737` 把帧
   `pict_type` 设为 NONE，**看不到本工程所需的周期 FORCE_KEY_FRAME 与
   dump_extra 链路**；直接 `-c h264_v4l2m2m` 不能承诺中途加入，必须保留或重建。
4. **再评估专用转换或 GPU 多平面转换。** GPU 不能直接分配 NV12 **不等于**
   所有 GPU 辅助转换在原理上都不可能，但多 pass/读回/同步成本要新实现与实测；
   不把"shader"当现成零成本方案。
5. **同步完善生命周期。** 推流脚本的守护与资源所有权薄弱：自定义 `R` 时仍有
   硬编码 `/tmp/stream/p.yuv` 清扫、部分启动失败没有统一清理、按 UDP 端口扫进程
   过宽。降本前后都需有界资源回收。

## C. 尚未实机验收的范围

验收报告里逐项写了范围界，这里按当前事实汇总：

- **已在真机验证**：UFI103s 的 `venus-4g-gpu` 变体在 7.2.9 上**整机刷入**
  （boot + max rootfs，2026-10-16，含无 WiFi 开箱即用）；
  `minimal` 变体 **RAM 启动**验证（2026-10-17，WiFi/USB 共享/zram/LED/Reset 键）。
- **仍未验收**：其余四个功能变体的硬件启动、除 max 外六张 rootfs 的整机矩阵、
  四块 WCN3660B 板、SIM 业务、Windows/macOS RNDIS、长稳与掉电。
  `minimal` 尚未从闪存做首启验收。

---
