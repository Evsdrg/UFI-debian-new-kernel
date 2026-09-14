#!/bin/sh
exec xterm -T zh-check -fa "WenQuanYi Micro Hei Mono" -fs 14 -e sh -c "
  echo 中文渲染测试：你好，世界;
  echo;
  echo i3 + xrdp + 文泉驿微米黑;
  echo;
  echo 当前系统:;
  . /etc/os-release; echo \$PRETTY_NAME;
  echo;
  free -m | head -2;
  sleep 600
"
