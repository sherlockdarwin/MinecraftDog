#!/bin/bash
# =============================================================================
# 命令行复现 TD 图形界面的完整流程：综合 → 布局布线 → 生成 bit。
# 在临时目录里跑（先把 mcproject_code/src 和 .al 复制过去），不会碰你的工程，TD 开着也能跑。
#
# 用法（Windows 上用 Git Bash）：
#     bash tools/td_build.sh            # 综合 + 布局布线 + bit（约 4~5 分钟）
#     bash tools/td_build.sh syn        # 只综合（约 1 分钟，查语法/例化/约束语法够用）
#     bash tools/td_build.sh phy        # 只做布局布线 + bit（需要先跑过 syn，用上一次的综合结果）
# 环境变量：
#     TD_HOME        TD 安装目录，默认 /d/TD_6.2.1_Release_6.2.175.876
#     TD_BUILD_DIR   临时构建目录，默认 $TEMP/mc_td_build
# 结果：
#     $TD_BUILD_DIR/MinecraftDog_FPGA_Runs/syn_1/run.log   综合日志
#     $TD_BUILD_DIR/MinecraftDog_FPGA_Runs/phy_1/run.log   布局布线日志
#     $TD_BUILD_DIR/MinecraftDog_FPGA_Runs/phy_1/MinecraftDog_FPGA.bit
#     脚本末尾会打印时序摘要：SWNS（建立）/ HWNS（保持）为正数才算时序满足。
# 注意：这不是 TD 官方入口，只是照着 GUI 生成的 run.bat / settings.cfg 复刻的；以 TD 界面里的结果为准。
# =============================================================================
STAGE=${1:-all}
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="$HERE/../mcproject_code"
W="${TD_BUILD_DIR:-${TEMP:-/tmp}/mc_td_build}"
TD="${TD_HOME:-/d/TD_6.2.1_Release_6.2.175.876}"
TDW="$(cygpath -m "$TD" 2>/dev/null || echo "$TD")"
NAME=MinecraftDog_FPGA

[ -x "$TD/bin/td_commands_prompt.exe" ] || { echo "找不到 $TD/bin/td_commands_prompt.exe，请设置 TD_HOME"; exit 1; }

if [ "$STAGE" != "phy" ]; then
  rm -rf "$W"; mkdir -p "$W/${NAME}_Runs/syn_1" "$W/${NAME}_Runs/phy_1"
  cp -r "$PROJ/src" "$W/src"
  cp "$PROJ/$NAME.al" "$W/$NAME.al"
  # .al -> .prj：文件路径加 ../../ 前缀（run 目录在 <工程>/<名>_Runs/syn_1），去掉 <Runs> 和 <Project_Settings>
  sed -E 's#File Path="src/#File Path="../../src/#' "$W/$NAME.al" \
    | awk '/<Runs>/{skip=1} !skip{print} /<\/Runs>/{skip=0}' \
    | awk '/<Project_Settings>/{skip=1} !skip{print} /<\/Project_Settings>/{skip=0}' > "$W/${NAME}_Runs/syn_1/$NAME.prj"
  grep -q "</Project>" "$W/${NAME}_Runs/syn_1/$NAME.prj" || echo "</Project>" >> "$W/${NAME}_Runs/syn_1/$NAME.prj"
  cp "$W/${NAME}_Runs/syn_1/$NAME.prj" "$W/${NAME}_Runs/phy_1/$NAME.prj"

  # settings.cfg：约束文件列表（IP 自带的约束 TD 界面会自动登记，这里手工列出）
  ADC=""; for f in $(cd "$W" && find src/pin -name '*.adc' | sort); do ADC="$ADC \"../../$f\""; done
  SDC=""; for f in $(cd "$W" && find src/pin -name '*.sdc' | sort); do SDC="$SDC \"../../$f\""; done
  IPADC=""; IPSDC=""
  if [ -f "$W/src/ip/ddr2/src/adc/ddr2.adc" ]; then
    IPADC="set IpADCList { ddr2 ../../src/ip/ddr2/src/adc/ddr2.adc }"
    IPSDC="set IpSDCList { ddr2 ../../src/ip/ddr2/src/sdc/ddr2.sdc w128_d512_fifo ../../src/ip/w128_d512_fifo/w128_d512_fifo.tcl }"
  fi
  TOP=$(grep -o '<MODULE>[^<]*' "$W/$NAME.al" | head -1 | sed 's/<MODULE>//')
  cat > "$W/${NAME}_Runs/syn_1/settings.cfg" <<EOF
# This File is Created by Tang Dynasty.
set ADCList {$ADC}
$IPADC
$IPSDC
set SDCList {$SDC}
set area_option -packarea
set device_name ph1_35p.db
set end_step opt_gate
set package_name PH1P35MDG324
set prj_name {$NAME}
set run_type syn
set speed 3
set start_step read_design
set top_model_name {$TOP}
EOF
  cat > "$W/${NAME}_Runs/phy_1/settings.cfg" <<EOF
# This File is Created by Tang Dynasty.
set ADCList {$ADC}
$IPADC
$IPSDC
set SDCList {$SDC}
set area_option -packarea
set arr_filter false
set device_name ph1_35p.db
set drHoldFix on
set end_step bitgen
set package_name PH1P35MDG324
set parent ../syn_1
set prj_name {$NAME}
set run_type phy
set speed 3
set start_step opt_place
set top_model_name {$TOP}
EOF

  cd "$W/${NAME}_Runs/syn_1" || exit 1
  echo "[td_build] 综合 ..."; T0=$(date +%s)
  timeout 1500 "$TD/bin/td_commands_prompt.exe" "$TDW/scripts/DefaultFlow.tcl" > run.log 2>&1
  echo "[td_build] 综合用时 $(( $(date +%s) - T0 )) 秒"
  grep -E "ERROR|CRITICAL" run.log | grep -v "derive_pll_clocks" | sort | uniq -c | sort -rn | head -30
  echo "[td_build] 警告数: $(grep -c ' WARNING' run.log)（大部分来自厂商模块内部，可忽略）"
fi

if [ "$STAGE" != "syn" ]; then
  cd "$W/${NAME}_Runs/phy_1" || exit 1
  echo "[td_build] 布局布线 + 生成 bit ..."; T0=$(date +%s)
  timeout 3000 "$TD/bin/td_commands_prompt.exe" "$TDW/scripts/DefaultFlow.tcl" > run.log 2>&1
  echo "[td_build] 布局布线用时 $(( $(date +%s) - T0 )) 秒"
  grep -E "ERROR|CRITICAL" run.log | grep -v "derive_pll_clocks" | sort | uniq -c | sort -rn | head -30
  echo "[td_build] 时序摘要："
  sed -n '/Timing Status/,/Period Check/p' ${NAME}_pr.timing 2>/dev/null | grep -E "SWNS|HWNS"
  ls -la ${NAME}.bit 2>/dev/null && echo "[td_build] bit: $W/${NAME}_Runs/phy_1/${NAME}.bit"
fi
