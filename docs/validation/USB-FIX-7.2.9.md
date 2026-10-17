# USB 共享修复与回归（7.2.9，2026-10-10）

接续 2026-10-10 的首轮实机验收（记录本地保留）；根因核对已并入 `../ISSUES.md`。
**USB 的已确认缺陷已修复；MPEG-4、散热、Windows/macOS兼容性不在本次通过范围。**

## 修改范围

| 层次 | 修复 |
|---|---|
| 公共内核配置 | NFT_CT/NFT_REJECT=m，Kconfig 派生 inet/IPv4/IPv6 reject 依赖；五个功能变体均重建 |
| NM rootfs | 全部四档显式安装 nftables，固定 nft 后端；仅 usb0 managed=1 覆盖 udev；网关显式设10.42.0.1/24 |
| gadget | 实际读取 UDC 内容，不看 stat 大小；串行化装配；检查属性写入、失败回滚、幂等启停；保留绑定冲突现场 |
| OS descriptor | 删除不存在的 interface/b_vendor_code；不再宣称全部平台免驱 |
| systemd | 修正 systemd-networkd 名称与顺序，增加有界超时 |
| native | 等待USB地址；独立、幂等的 inet openstick_usb 表；USB来源限制与返回流量过滤；前台dnsmasq受监督，停止/失败只清理自己的表 |
| dnsmasq | 删除原配置中非法的 log-dhcp=no；不启用日志选项，启动前做语法检查；全局dnsmasq服务被mask |
| 交付守护 | 新增故障注入测试和五内核/七镜像的USB能力、资产、权限、模块哈希校验；verify-layout接入USB断言 |

文件：`source/configs/common-7.2.9-os.config`、`build-rootfs.sh`、
`tools/usb-gadget.sh` / `.service`、`tools/nm-connections/`、`tools/net-native/`、
`tools/test-usb-sharing.py`、`tools/verify-usb-sharing.py`、`tools/verify-layout.sh`。

## 实机方法与结果

设备仍使用原有 Debian rootfs，安装本次完整匹配模块树、gadget服务与NM配置。
只使用 `fastboot boot` 从RAM启动新内核，**没有正式刷入任何分区**。

- 内核：`7.2.9-ufix0x-venus-4g-gpu-dirty`，构建序号 `#2`。
- boot文件：`artifacts/boot/ufi103s-ufi003/boot-board-venus-4g-gpu-7.2.9.img`。
- 新文件SHA256：`11f975b280b357f96d06f72c490284a66c6ca0ebeeb0368778044e61e654bb51`。
- 两次RAM启动，第二次确认 **usb-share 正式keyfile自动激活**，无手工managed补救。
- 原p12始终为SHA256 `9159529fe351f82f99d06717cb06480176ec611555bae96f56637af4ad8a7d75`。
- 新旧模块、配置和前一批主机产物已备份；`out/usb-fix/device-backups.tar` **含私有WiFi
  配置，不可公开**，权限600。其它不可再生回退副本未删除。

| 项目 | 结果 |
|---|---|
| NM 自动共享 | ✅ 新配置随RAM启动自动激活，nft共享表完整，无原来的ct/reject ENOENT |
| 真正NAT | ✅ 隔离网络命名空间内只有USB网卡；上游HTTP服务观察到来源为棒子WiFi地址，不是USB客户端地址 |
| NM DHCP/DNS/外网HTTPS | ✅ 获取10.42.0.x；经棒子DNS查询；不使用代理，HTTPS返回200 |
| native DHCP/DNS/NAT/外网HTTPS | ✅ 临时切换USB的管理者，不影响WiFi；客户端获取10.42.0.20，HTTP来源同为棒子WiFi，HTTPS返回200 |
| native 进程监督 | ✅ 精确KILL其dnsmasq主进程，自动重启并恢复规则；不按命令行批量杀进程 |
| native 规则生命周期 | ✅ restart后不累积；stop删除自己的表，保留另建的sentinel表 |
| native 错误配置 | ✅ 故意添加不存在的选项，ExecStartPre拒绝启动，未残留共享表 |
| gadget重复启停 | ✅ 三次systemd restart，均自动恢复NM共享；重复start不解绑已有有效gadget |
| gadget半装配恢复 | ✅ 在停止后创建空的gadget目录；UDC stat仍为4096但status返回inactive/3；重新start完整恢复 |
| boot分区保护 | ✅ 两次RAM启动前后哈希未变 |

**native实机范围**：在现有NM rootfs上，暂时只让networkd接管usb0，运行本次完整native
共享服务、配置和helper；测试结束恢复NM并删除临时native配置。这验证了硬件网络路径
与服务生命周期，**不等于三张native镜像已做整机冷启动/蜂窝拨号验收**。
其它四个内核变体未在硬件启动；七张新rootfs均未刷入设备。

DHCP测试客户端在namespace里使用dhcpcd，禁用ARP探测/IPv4LL并阻止resolv.conf hook，
避免宿主的ARP探测问题及修改全局DNS；最终成功日志记录了DHCP ACK和实际地址。
`timeout`终止前台测试客户端的124退出码不是DHCP失败，判断依据为租约、地址和路由。
早期保留日志包含一次旧租约/ARP探测失败，未将那次记为通过。

## 实机发现并补齐的缺陷

1. **未绑定UDC不能重复写空值**：最初半装配实机测试报 `No such device`。
   清理现在只有读到非空UDC时才解绑；离线测试用只读空属性捕获这类回归。
2. **原 native dnsmasq 配置不合法**：实际前台daemon拒绝 `log-dhcp=no`。
   删除这类伪关闭配置，启动前增加 `dnsmasq --test`；坏配置负向测试已执行。

不能仅靠mock测试模拟完整configfs/守护进程行为，所以本轮同时做了真实设备测试。

## 回归命令与边界

| 最终回归 | 结果 |
|---|---|
| 五变体内核/boot重建 | ✅ 5/5，完整配套模块已安装，DTB未改变 |
| 七张rootfs完整重建 | ✅ 两批最终构建均rc=0 |
| USB交付断言 | ✅ 五内核/七镜像全部通过，资产与嵌入模块哈希一致 |
| configfs/native故障注入 | ✅ 6/6 |
| 负向镜像 | ✅ 修复前镜像缺nft、故意删nft_ct的镜像均被拒绝 |
| 布局自检 | ✅ verify-layout rc=0 |
| QEMU | ✅ 7/7到login、无非预期FAILED；每镜像90秒，不含真实USB验收 |
| 分发仓自检 | ✅ ALL CHECKS PASSED，补丁逐字节一致，五镜像哈希与主仓一致 |

```sh
python3 tools/test-usb-sharing.py
python3 tools/verify-usb-sharing.py
bash tools/verify-layout.sh
bash tools/smoke-all.sh
```

- 故障注入6项覆盖失败回滚、绑定冲突、幂等停止、属性大小假阳性、native规则所有权及错误。
- `verify-usb-sharing.py` 检查所有五份最终配置、模块闭包；逐镜像核对nft可执行、
  gadget/NM/native资产与源码逐字节一致、keyfile权限、嵌入模块与主机模块哈希一致。
- 保留修复前max镜像做负向检查，守护明确报缺nft并非零退出；另在临时镜像副本
  中故意删除nft_ct.ko，守护准确报缺模块。正式镜像未被负向测试修改。
- QEMU并行测试使用独立 `QEMU_TEST_DIR`，避免共用test.ext4/Image与挂载点互相踩。
- QEMU仍不具备真实UDC，USB/native失败的预期过滤仍保留；QEMU通过只代表userspace
  启动，不替代上面的真实NAT测试。

最终构建、镜像检查及QEMU完成日志在 `out/usb-fix/`。最初并行构建期间
编辑运行中的脚本导致两张构建收尾rc127，因此冻结实现后已完成**完整七镜像重建**，
最终两批构建和总回归均rc=0；保留最初失败日志，不把它们当最终成功证据。

## 现场与未解决项

- 设备运行修复后的7.2.9 RAM内核，磁盘boot仍是7.1.13。
- 当前网络由NM接管；gadget服务已安装启用，共享配置固定为10.42.0.1/24。
- 试验用native服务、networkd运行时USB配置、sentinel表、兜底重启unit、主机namespace
  和临时no-auto-default配置均已清理；host USB连接不接管默认路由/DNS。
- 私有备份及设备旧模块保留；`kernel.sysrq=0`串口隔离仍保留。
- **MPEG-4固件fatal、持续负载散热、其它板型和SIM业务仍未修复/验收**。
- Windows/macOS RNDIS兼容性未测，本次不引入ECM/NCM协议重构。
