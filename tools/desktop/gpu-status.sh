#!/bin/sh
exec xterm -T gpu-status -fa "WenQuanYi Micro Hei Mono" -fs 12 -e sh -c "
  echo 桌面 + xrdp + GPU 验证;
  echo;
  echo GPU 节点:; ls -l /dev/dri/;
  echo;
  echo GPU 身份:; cat /sys/class/drm/renderD128/device/uevent | head -4;
  echo;
  echo GPU 渲染器:;
  EGL_PLATFORM=gbm eglinfo 2>/dev/null | grep -m1 \"OpenGL core profile renderer\";
  echo;
  echo 硬件编解码:; v4l2-ctl --list-devices | head -3;
  echo;
  echo 内存:; free -m | head -2;
  sleep 900
"
