#!/usr/bin/perl
# =============================================================================
# 生成 src/rtl/video/obs/mc_obs_lut.v：避障用的几何表（只和摄像头装法有关）。
#   相机：离地 H_MM、向下倾 TILT_DEG（负数 = 往上仰）、焦距 F（1920 宽的画面里的像素数；车上的值按实测反推，见下面）；
#   避障网格 160×90，每格 = 1920×1080 里的 12×12 像素；网格第 r 行中心在 1080 窗口的第 12r + 5.5 行，光轴在第 539.5 行。
#   1. 行 → 距离：第 r 行看到的地面离镜头（水平）多远：H / tan(TILT + atan((12r + 5.5 − 539.5) / F))，厘米，最多 255；
#      在地平线以上（角度 ≤ 0.5°）的行给 255。
#   （从第几行起判断障碍不在这里：mctop 的 OBS_ROW_MIN，按下面行 → 距离的表挑。）
#   2. 方向角：地面上的水平角度（度，左负右正）。相机下倾时，画面的一列在地面上是一条从镜头正下方稍后一点（h·tan(TILT)）
#      出发的射线，角度 = atan(列偏移 × cos(TILT) / F)。扇区角度 = 扇区中心列；"方向 b"= 扇区 b−1 和 b 的分界线（b = 1~15，b = 8 是正前方）。
#   3. 车宽门限 O_thr（方向 b、扇区 j）：车沿方向 b 直走，扫过一条宽 CAR_W + 2 × MARGIN 的带子；扇区 j 里的障碍离镜头 d 厘米、
#      它离这条路线的横向距离 ≥ d × sin(扇区 j 靠近 b 的那条边和 b 的夹角)。这个距离 < 半宽就挡路 ⇔ d ≤ 半宽 / sin(夹角)。
#      O_thr = floor(半宽 / sin(夹角))，最多 255；挨着方向 b 的两个扇区（b−1、b）= 255（多远都挡）。
# 用法：perl tools/gen_obs_lut.pl > mcproject_code/src/rtl/video/obs/mc_obs_lut.v
#       perl tools/gen_obs_lut.pl --tilt 15 > mcproject_code/src/sim/models/mc_obs_lut_t15.v   （测试台专用的固定几何，见那个文件的开头）
# 摄像头高度 / 角度变了：改下面的数，重新生成（tb_obs_core_cur 用同样的公式独立核对）。
# =============================================================================
use strict;
use warnings;
use POSIX qw(floor);

my $PI = 4 * atan2(1, 1);

my $H_MM     = 174;     # 镜头离地高度（毫米）
# 镜头竖直装（光轴水平）。焦距和倾角按 10-30 上车量的两个数反推（盒子放在地上量）：
#   画面下 1/3（小图第 CAL_ROW 行，处理画面里的灰色交界线）看到的地面离镜头 CAL_CM；那条线上画面左右一共宽 CAL_W_CM。
#   结果：倾角约 +0.4°（就是竖直）、焦距约 1526 像素（水平视场约 64°，和 4.2 mm 镜头一致；以前按手册的 72° 算偏大）。重新量了就改这三个数。
my $CAL_ROW  = 60;
my $CAL_CM   = 135;
my $CAL_W_CM = 170;
my ($F, $TILT_DEG);
my $TB = 0;
if (@ARGV == 2 && $ARGV[0] eq '--tilt') {                                          # 测试台用：直接给倾角，焦距按视场 72°
    $TB = 1; $TILT_DEG = $ARGV[1]; $F = 960 / (sin(36 * $PI / 180) / cos(36 * $PI / 180));
} else {                                                                            # 车上：倾角、焦距一起反推（互相有关，迭代几次就收敛）
    my $t = 0; $F = 1500;
    for (1 .. 20) {
        $t = atan2($H_MM / 10, $CAL_CM) - atan2(12 * $CAL_ROW + 5.5 - 539.5, $F);
        $F = 960 * ($CAL_CM * cos($t) + $H_MM / 10 * sin($t)) / ($CAL_W_CM / 2);   # 那条线离镜头的深度 × 半个画面宽（像素）/ 实际半宽
    }
    $TILT_DEG = $t * 180 / $PI;
}
my $CAR_W_CM = 20;      # 车宽（厘米）
my $MARGIN_CM = 5;      # 两边各留多少（厘米）
my $HALF_CM  = $CAR_W_CM / 2 + $MARGIN_CM;
my $TILT_TXT = $TB ? "向下倾 ${TILT_DEG}°、水平视场 72°（测试台专用的固定几何，不是车上的）"
                   : sprintf("倾角 %.2f°、焦距 %.0f 像素（按第 %d 行实测 %d cm、左右宽 %d cm 反推）", $TILT_DEG, $F, $CAL_ROW, $CAL_CM, $CAL_W_CM);

sub dist_cm {
    my ($r) = @_;
    my $a = $TILT_DEG * $PI / 180 + atan2(12 * $r + 5.5 - 539.5, $F);
    return 255 if $a <= 0.5 * $PI / 180;
    my $d = $H_MM / 10 / (sin($a) / cos($a));
    my $v = floor($d + 0.5);
    return $v > 255 ? 255 : $v;
}
my $COS_T = cos($TILT_DEG * $PI / 180);
sub ang { my ($x) = @_; return atan2($x * $COS_T, $F); }                            # 列偏移（像素）→ 地面角度（弧度）
sub deg { my ($x) = @_; my $v = ang($x) * 180 / $PI; return $v < 0 ? -floor(-$v + 0.5) : floor($v + 0.5); }
sub head_ang { my ($b) = @_; return ang(120 * $b - 960); }                        # 方向 b = 扇区 b−1 和 b 的分界线
sub thr { my ($b, $j) = @_;
    return 255 if $j == $b - 1 || $j == $b;
    my $e = ($j >= $b) ? $j : $j + 1;                                                # 扇区 j 靠近方向 b 的那条边
    my $t = floor($HALF_CM / sin(abs(head_ang($e) - head_ang($b))));
    return $t > 255 ? 255 : $t;
}

print <<"EOF";
`timescale 1ns / 1ps
// =============================================================================
// mc_obs_lut.v  避障几何表：网格行 → 地面距离（厘米）、扇区 / 方向 → 地面上的水平角度（度）、车宽门限
// ★ 本文件由 tools/gen_obs_lut.pl 生成（镜头离地 ${H_MM} mm、${TILT_TXT}、车宽 ${CAR_W_CM} cm + 两边各 ${MARGIN_CM} cm），不要手改。
//   方向 b（1~15）= 扇区 b−1 和 b 的分界线，b = 8 是正前方。O_thr：扇区 j 里的障碍距离 ≤ 这个数（厘米）就挡住方向 b（255 = 多远都挡）。
//   从第几行起判断障碍由 mctop 的 OBS_ROW_MIN 定（按 O_dist 这张表挑：第 50 行 @{[dist_cm(50)]} cm、第 60 行 @{[dist_cm(60)]} cm、第 70 行 @{[dist_cm(70)]} cm、第 75 行 @{[dist_cm(75)]} cm、第 82 行 @{[dist_cm(82)]} cm、第 89 行 @{[dist_cm(89)]} cm；255 = 太远 / 地平线以上）。
// =============================================================================
module mc_obs_lut (
    input  wire [6:0] I_row,            // 网格行 0~89
    output reg  [7:0] O_dist,           // 这一行看到的地面离镜头多远（厘米，255 = 很远 / 地平线以上）
    input  wire [3:0] I_sec,            // 扇区 0~15
    output reg  signed [6:0] O_sec_deg, // 扇区中心的水平角度（度，左负右正）
    input  wire [3:0] I_head,           // 方向 1~15
    output reg  signed [6:0] O_head_deg,// 它的水平角度
    input  wire [3:0] I_tb,             // 车宽门限：方向 b
    input  wire [3:0] I_tj,             //           扇区 j
    output reg  [7:0] O_thr
);

always \@(*) begin
    case (I_row)
EOF
for my $r (0 .. 89) { printf "        7'd%-2d: O_dist = 8'd%d;\n", $r, dist_cm($r); }
print "        default: O_dist = 8'd255;\n    endcase\nend\n\nalways \@(*) begin\n    case (I_sec)\n";
for my $k (0 .. 15) {
    my $d = deg((10 * $k + 4.5) * 12 + 5.5 - 959.5);
    printf "        4'd%-2d: O_sec_deg = %s7'sd%d;\n", $k, ($d < 0 ? "-" : " "), abs($d);
}
print "        default: O_sec_deg = 7'sd0;\n    endcase\nend\n\nalways \@(*) begin\n    case (I_head)\n";
for my $b (1 .. 15) {
    my $d = deg(120 * $b - 960);
    printf "        4'd%-2d: O_head_deg = %s7'sd%d;\n", $b, ($d < 0 ? "-" : " "), abs($d);
}
print "        default: O_head_deg = 7'sd0;\n    endcase\nend\n\nalways \@(*) begin\n    case ({I_tb, I_tj})\n";
for my $b (1 .. 15) { for my $j (0 .. 15) {
    my $t = thr($b, $j);
    printf "        8'h%X%X: O_thr = 8'd%d;\n", $b, $j, $t if $t != 255;
} }
print "        default: O_thr = 8'd255;\n    endcase\nend\n\nendmodule\n";
