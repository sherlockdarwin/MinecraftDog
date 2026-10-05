#!/bin/bash
# =============================================================================
# 用 Icarus Verilog 跑仿真测试台（src/sim/tb_*.v）。每个测试台最后会打印 PASS 或 FAIL。
# 用法：bash tools/sim.sh            跑 src/sim 下的 tb_*.v，但跳过最慢的三个（tb_top、tb_fb、tb_audio），17 个约 25 分钟（本机实测，同时还有别的仿真在跑：tb_sdfat 约 15 分钟、tb_dash 约 3 分钟，其余大多在 2 分钟以内）
#       bash tools/sim.sh tb_key     只跑一个（可以写多个名字）
#       慢的三个：tb_top 顶层集成测试（真的 mctop.v + 视频替身 + TF 卡模型 + 霍尔 / 行为层 / LED，约 15 分钟）、
#                 tb_fb 帧缓存（真的 video_in/video_out + 行为级 DDR；慢相机逐像素核对 + 相机高速写的压力用例，约 2 分钟）、
#                 tb_audio 音频子系统（ES8388 + I2S + TF 卡 + FAT32 + 双路 WAV + 混音，2 个实例（一张正常卡、一张初始化很慢的卡），约 30 分钟）
#       ALL=1 bash tools/sim.sh      全部都跑（顺序跑约 2.5 小时；想快就分别开几个终端，各设一个 SIM_OUT 目录并行跑；tb_top 约 60 MB、tb_audio 约 120 MB、tb_sdfat 要 1~2 GB 内存，别一次开太多，会换页）
#       SIM_OUT=<目录> bash tools/sim.sh ...   仿真输出（.vvp、日志、测试用的 TF 卡镜像）放到指定目录，并行跑多个互不干扰
# （波形：给测试台加 $dumpfile/$dumpvars 即可，输出放在 src/sim/.out/，用 GTKWave 打开）
# 找仿真器的顺序：环境变量 IVERILOG_HOME → PATH → 默认安装位置。
# 装 Icarus：winget install Icarus.Verilog（装完把安装目录的 bin 加进 PATH，或设置 IVERILOG_HOME）
# 注意：testbench 只用 iverilog 能编译的纯 Verilog-2005，和上板代码共用同一份 src/rtl 源文件。
# =============================================================================
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/../mcproject_code/src"
OUT="${SIM_OUT:-$HERE/../mcproject_code/src/sim/.out}"
mkdir -p "$OUT"

IV=iverilog; VVP=vvp
if [ -n "$IVERILOG_HOME" ] && [ -x "$IVERILOG_HOME/bin/iverilog.exe" ]; then
  IV="$IVERILOG_HOME/bin/iverilog.exe"; VVP="$IVERILOG_HOME/bin/vvp.exe"
elif ! command -v iverilog >/dev/null 2>&1; then
  for d in "/c/iverilog/bin" "/c/Program Files/iverilog/bin" "$HOME/AppData/Local/Programs/iverilog/bin"; do
    [ -x "$d/iverilog.exe" ] && IV="$d/iverilog.exe" && VVP="$d/vvp.exe" && break
  done
fi
"$IV" -V >/dev/null 2>&1 || { echo "找不到 iverilog：请安装或设置 IVERILOG_HOME"; exit 2; }

# 每个测试台需要哪些 RTL 文件（相对 src/rtl）；新增测试台时在这里登记
rtl_for() {
  case "$1" in
    tb_key)        echo "hmi/mc_key.v";;
    tb_hold_reset) echo "system/mc_hold_reset.v";;
    tb_uart)       echo "comm/mc_uart_tx.v";;
    tb_tail)       echo "comm/mc_uart_tx.v tail/mc_stepper_emm.v tail/mc_tail.v";;
    tb_osd)        echo "video/osd/mc_font8x16.v video/osd/mc_osd_text.v video/osd/mc_osd_clear.v";;
    tb_bench)      echo "hmi/mc_bench.v";;
    tb_top)        echo "mctop.v system/mc_rst_sync.v system/mc_tick.v system/mc_sync_bits.v system/mc_activity_mon.v system/mc_hold_reset.v hmi/mc_key.v hmi/mc_bench.v comm/mc_uart_tx.v tail/mc_stepper_emm.v tail/mc_tail.v video/osd/mc_font8x16.v video/osd/mc_osd_text.v video/osd/mc_osd_clear.v video/osd/mc_osd_dash.v audio/mc_audio.v audio/mc_es8388_cfg.v audio/mc_i2c_wr.v audio/mc_i2s_tx.v audio/mc_sd_spi.v audio/mc_sd_arb.v audio/mc_audio_mix.v audio/mc_fat32.v audio/mc_fat_dir.v audio/mc_fat_rd.v audio/mc_wav_player.v sensor/mc_hall.v app/mc_behavior.v ../sim/models/sd_card_model.v ../sim/models/i2c_ack_slave.v ../sim/stubs/stub_mcsys_pll.v ../sim/stubs/stub_mc_cam_if.v ../sim/stubs/stub_mc_framebuf.v ../sim/stubs/stub_mc_disp_if.v";;
    tb_fb)         echo "video/fb/mc_framebuf.v video/fb/video_in.v video/fb/video_out.v video/fb/mc_to_user_interface.v ../ip/w128_d512_fifo/w128_d512_fifo.v ../ip/w128_d512_fifo/soft_fifo_al_4057d6b76aa6.v ../ip/w155_d512_fifo/w155_d512_fifo.v ../ip/w155_d512_fifo/soft_fifo_al_f58e8b3e1f3d.v ../sim/stubs/stub_ddr_wrapper.v";;
    tb_i2s)        echo "audio/mc_i2s_tx.v";;
    tb_es8388)     echo "audio/mc_i2c_wr.v audio/mc_es8388_cfg.v";;
    tb_sdfat)      echo "audio/mc_sd_spi.v audio/mc_fat32.v audio/mc_fat_dir.v audio/mc_fat_rd.v ../sim/models/sd_card_model.v";;
    tb_audio)      echo "audio/mc_audio.v audio/mc_es8388_cfg.v audio/mc_i2c_wr.v audio/mc_i2s_tx.v audio/mc_sd_spi.v audio/mc_sd_arb.v audio/mc_audio_mix.v audio/mc_fat32.v audio/mc_fat_dir.v audio/mc_fat_rd.v audio/mc_wav_player.v ../sim/models/sd_card_model.v ../sim/models/i2c_ack_slave.v";;
    tb_audio_mix)  echo "audio/mc_audio_mix.v";;
    tb_sdarb)      echo "audio/mc_sd_spi.v audio/mc_sd_arb.v audio/mc_fat32.v audio/mc_fat_dir.v audio/mc_fat_rd.v ../sim/models/sd_card_model.v";;
    tb_sdarb_proto) echo "audio/mc_sd_arb.v";;
    tb_hall)       echo "sensor/mc_hall.v";;
    tb_behavior)   echo "app/mc_behavior.v";;
    tb_awb)        echo "video/isp/awb.v video/isp/signal_delay.v ../sim/stubs/stub_awb_delay_ram.v";;
    tb_mixer)      echo "video/disp/mc_mixer.v system/mc_sync_bits.v video/osd/mc_font8x16.v video/osd/mc_osd_text.v";;
    tb_dash)       echo "system/mc_sync_bits.v video/osd/mc_font8x16.v video/osd/mc_osd_text.v video/osd/mc_osd_clear.v video/osd/mc_osd_dash.v";;
    *) echo "";;
  esac
}

if [ $# -gt 0 ]; then
  TBS="$*"
else
  TBS=$(cd "$SRC/sim" && ls tb_*.v 2>/dev/null | sed 's/\.v$//')
  # tb_top / tb_fb / tb_audio 比较慢，默认不跑；ALL=1 bash tools/sim.sh 或点名才跑
  [ -n "$ALL" ] || TBS=$(echo "$TBS" | grep -v -E "^(tb_top|tb_fb|tb_audio)$")
fi

FAILED=0
for tb in $TBS; do
  case "$tb" in tb_sdfat|tb_audio|tb_top|tb_sdarb)        # 这几个测试台要读 FAT32 镜像：先用 perl 生成到输出目录
    perl "$HERE/mk_sd_test_image.pl" "$OUT/sd_mbr.hex" 2 1 > /dev/null
    perl "$HERE/mk_sd_test_image.pl" "$OUT/sd_flat.hex" 1 0 > /dev/null
    if [ "$tb" = tb_sdfat ]; then           # tb_sdfat 另外要的卡：目录填满 / 1 份 FAT / 各种挂载失败
      perl "$HERE/mk_sd_test_image.pl" "$OUT/sd_full.hex"      2 1 2 2 0 1 1 > /dev/null  # 根目录刚好填满它占的簇（没有结尾项）+ 多一个 64.WAV 和 65.WAV 诱饵
      perl "$HERE/mk_sd_test_image.pl" "$OUT/sd_nfats1.hex"    1 0 1 > /dev/null          # 只有 1 份 FAT
      perl "$HERE/mk_sd_test_image.pl" "$OUT/sd_bsig_flat.hex" 1 0 2 2 1 > /dev/null      # 卷引导扇区签名坏（无分区表）
      perl "$HERE/mk_sd_test_image.pl" "$OUT/sd_bsig_vbr.hex"  2 1 2 2 1 > /dev/null      # 分区的卷引导扇区签名坏
      perl "$HERE/mk_sd_test_image.pl" "$OUT/sd_bsig_mbr.hex"  2 1 2 2 2 > /dev/null      # MBR 签名坏
      perl "$HERE/mk_sd_test_image.pl" "$OUT/sd_nfats3.hex"    2 1 3 > /dev/null          # 3 份 FAT（不支持）
      perl "$HERE/mk_sd_test_image.pl" "$OUT/sd_spc3.hex"      3 0 > /dev/null            # 每簇 3 个扇区（不是 2 的幂）
      perl "$HERE/mk_sd_test_image.pl" "$OUT/sd_root1.hex"     2 1 2 1 > /dev/null        # 根目录起始簇 = 1（非法）
      perl "$HERE/mk_sd_test_image.pl" "$OUT/sd_mbr0b.hex"    2 1 2 2 0 0 0 11 > /dev/null   # 分区类型 0x0B
      perl "$HERE/mk_sd_test_image.pl" "$OUT/sd_free.hex"     2 1 2 2 0 2 > /dev/null        # 目录和 4.WAV 的簇链以 FAT 项 1（保留簇号）结尾（损坏的卡）
      for v in "f_sig0 1 0 2 2 3" "v_sig0 2 1 2 2 3" "m_sig0 2 1 2 2 4" "f_bps 1 0 2 2 5" "v_bps 2 1 2 2 5" "f_fsz 1 0 2 2 6" "v_fsz 2 1 2 2 6"; do     # 签名第 1 字节坏 / 每扇区字节数不对 / FAT 大小为 0（无分区表 f、分区的卷引导扇区 v、MBR m）
        set -- $v; perl "$HERE/mk_sd_test_image.pl" "$OUT/sd_$1.hex" $2 $3 $4 $5 $6 > /dev/null
      done
    fi
    printf '00\n' > "$OUT/blank_none.hex";;
  esac
  files=""
  for f in $(rtl_for "$tb"); do files="$files $SRC/rtl/$f"; done
  if ! "$IV" -g2005 -Wall -Wno-timescale -o "$OUT/$tb.vvp" "$SRC/sim/$tb.v" $files 2> "$OUT/$tb.warn"; then
    echo "[$tb] 编译失败："; cat "$OUT/$tb.warn"; FAILED=1; continue
  fi
  [ -s "$OUT/$tb.warn" ] && grep -v "^$" "$OUT/$tb.warn" | head -20
  ( cd "$OUT" && "$VVP" "$tb.vvp" ) | tee "$OUT/$tb.log" | grep -E "PASS|FAIL|ERROR|error"
  grep -q "^PASS" "$OUT/$tb.log" || FAILED=1
done
exit $FAILED
