#!/bin/bash
# 用 Edge 无头模式把 figs.html 里的图渲染成 PNG（2 倍分辨率），输出到 out/。
# 用法：bash render.sh fig_system 20.2 11.25 [名字 宽 高 ...]（宽高单位见 dg.js，1 单位 = 70 px）
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E="/c/Program Files (x86)/Microsoft/Edge/Application/msedge.exe"
mkdir -p "$HERE/out"
while [ $# -ge 3 ]; do
  n=$1; w=$(awk "BEGIN{print int($2*70+0.5)}"); h=$(awk "BEGIN{print int($3*70+0.5)}"); shift 3
  "$E" --headless=new --disable-gpu --hide-scrollbars --allow-file-access-from-files --force-device-scale-factor=2 --window-size=$w,$h --virtual-time-budget=3000 --screenshot="$(cygpath -w "$HERE/out/$n.png")" "file:///$(cygpath -m "$HERE/figs.html")#$n" >/dev/null 2>&1
  echo "$n ${w}x${h}"
done
