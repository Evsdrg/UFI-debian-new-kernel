#!/bin/sh
# usb-gadget 健康检查：由 usb-gadget-watchdog.timer 周期性调用。
#
# 为什么需要它：
#   - configfs gadget 的驱动标志 match_existing_only=1（configfs.c:1985），
#     意味着 UDC 后出现时内核不会自动把 gadget 绑上去；
#   - usb-gadget.service 是 oneshot + RemainAfterExit，绑定后即使内核侧
#     解绑了（UDC 注销/重新枚举、控制器掉电恢复），systemd 仍认为服务 active；
#   - 结果是 PC 侧看到设备"自己断开"，而且不会再回来。
#
# 本脚本检测到 gadget 不再完整绑定时，重新执行 start。start 自身是幂等的：
# 已完整绑定则直接返回 0。
set -eu

GADGET=${USB_GADGET_BIN:-/usr/local/sbin/usb-gadget.sh}

# status 退出码：0=active，3=inactive。其它码视为异常，同样尝试修复。
if "$GADGET" status >/dev/null 2>&1; then
    exit 0
fi

logger -t usb-gadget-watchdog 'gadget 未处于 active 状态，尝试重新装配' 2>/dev/null || true
# start 有 flock 串行化，和 systemd 的 Restart 不会互相踩。
exec "$GADGET" start
