#!/usr/bin/perl
# =============================================================================
# 生成 src/rtl/video/isp/mc_gamma_lut.v：RAW10 原始值 → 8 位"显示亮度"的查找表（1024 项）。
#   1. 减黑电平：IMX415 的 BLKLEVEL = 50（10 位），传感器把"全黑"输出成 50 左右；
#   2. 归一化到 0~1：v = (x − 50) / (1023 − 50)，小于 0 当 0；
#   3. sRGB 伽马：v ≤ 0.0031308 时 12.92·v，否则 1.055·v^(1/2.4) − 0.055（暗部提亮，亮部压缩，和屏幕的显示曲线配套）；
#   4. ×255 四舍五入。
# 用法：perl tools/gen_gamma.pl > mcproject_code/src/rtl/video/isp/mc_gamma_lut.v
# 改黑电平或曲线只改这里，重新生成；tb_gamma 用同样的公式独立核对全部 1024 项。
# =============================================================================
use strict;
use warnings;

my $BL = 50;

sub g {
    my ($x) = @_;
    my $v = ($x - $BL) / (1023 - $BL);
    $v = 0 if $v < 0;
    my $s = ($v <= 0.0031308) ? 12.92 * $v : 1.055 * ($v ** (1 / 2.4)) - 0.055;
    my $y = int($s * 255 + 0.5);
    $y = 255 if $y > 255;
    return $y;
}

print <<'EOF';
`timescale 1ns / 1ps
// =============================================================================
// mc_gamma_lut.v  RAW10 原始值 → 8 位显示亮度（减黑电平 50 + sRGB 伽马）。组合逻辑查找表，1024 项。
// ★ 本文件由 tools/gen_gamma.pl 生成，不要手改；改曲线请改脚本后重新生成。
// =============================================================================
module mc_gamma_lut (
    input  wire [9:0] I_x,
    output reg  [7:0] O_y
);

always @(*) begin
    case (I_x)
EOF
for my $x (0 .. 1023) {
    printf "        10'd%-4d: O_y = 8'd%d;\n", $x, g($x);
}
print <<'EOF';
        default:  O_y = 8'd0;
    endcase
end

endmodule
EOF
