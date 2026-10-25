#!/bin/bash
# =============================================================================
# 从 TI2026H 的 OLED 字库（HARDWARE/OLED/oledfont.h 里的 asc2_1608，8×16 ASCII 点阵）
# 生成 FPGA 用的字库 ROM：mcproject_code/src/rtl/video/osd/mc_font8x16.v
#
# OLED 字库的格式：每个字符 16 字节，前 8 字节是上半(第 0~7 行)的 8 列，后 8 字节是下半(第 8~15 行)的 8 列，
#                  每个字节的 bit0 = 最上面一行。显示屏要的是"一行 8 个像素"（bit7 = 最左），所以这里转置一下。
# 什么时候用：想换字体（换另一份 oledfont.h）时重新生成。字库本身不用每次都生成，已经提交在仓库里。
# 用法：bash tools/gen_font.sh [oledfont.h 路径]
# =============================================================================
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${1:-$HERE/../../reference/TI2026H题code/HARDWARE/OLED/oledfont.h}"
OUT="$HERE/../mcproject_code/src/rtl/video/osd/mc_font8x16.v"
[ -f "$SRC" ] || { echo "找不到字库文件：$SRC"; exit 1; }

awk '/asc2_1608/ {f=1; next} f && /^};/ {exit} f' "$SRC" | grep -o '0x[0-9A-Fa-f][0-9A-Fa-f]' | awk '
function hex(s,   i, c, v, d) { v = 0; s = tolower(substr(s, 3)); for (i = 1; i <= length(s); i++) { c = substr(s, i, 1); d = index("0123456789abcdef", c) - 1; v = v * 16 + d } return v }
function band(x, n) { return int(x / n) % 2 }          # 取 x 的某一位：n = 2^k
{ b[NR - 1] = hex($1) }
END {
    if (NR != 95 * 16) { print "字库字节数不对：" NR "（应为 1520）" > "/dev/stderr"; exit 1 }
    print "`timescale 1ns / 1ps"
    print "// ============================================================================="
    print "// mc_font8x16.v  ASCII 8x16 字库 ROM（自动生成，请不要手改；生成脚本 tools/gen_font.sh）"
    print "// 来源：TI2026H 的 OLED 字库 asc2_1608（可显示 ASCII 32~126：空格、数字、大小写字母、标点）。"
    print "// 地址 = {ASCII[6:0], 行号[3:0]}，一次给一行 8 个像素，bit7 = 最左边的像素；输出比地址晚一个时钟。"
    print "// ASCII 码 < 32 或 = 127 的字符返回全 0（空白）。"
    print "// ============================================================================="
    print "module mc_font8x16 ("
    print "    input  wire        I_clk,"
    print "    input  wire [10:0] I_addr,"
    print "    output reg  [7:0]  O_data"
    print ");"
    print ""
    print "always @(posedge I_clk) begin"
    print "    case (I_addr)"
    for (ch = 0; ch < 95; ch++) {
        code = ch + 32
        label = (code == 32) ? "space" : sprintf("%c", code)
        printf "        // 0x%02X '%s'\n", code, label
        for (r = 0; r < 16; r++) {
            v = 0
            half = (r >= 8) ? 8 : 0
            for (c = 0; c < 8; c++) {
                byte = b[ch * 16 + half + c]
                bit = band(byte, 2 ^ (r % 8))
                v = v * 2 + bit                        # c = 0 是最左列 → 放到最高位
            }
            printf "        11'"'"'h%03X: O_data <= 8'"'"'h%02X;\n", code * 16 + r, v
        }
    }
    print "        default: O_data <= 8'"'"'h00;"
    print "    endcase"
    print "end"
    print ""
    print "endmodule"
}' > "$OUT.new" && mv "$OUT.new" "$OUT" && echo "已生成 $OUT（$(wc -l < "$OUT") 行）"
