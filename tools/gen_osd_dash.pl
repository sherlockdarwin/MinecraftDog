#!/usr/bin/perl
# =============================================================================
# 生成屏幕状态面板 mcproject_code/src/rtl/video/osd/mc_osd_dash.v
#   用法：perl tools/gen_osd_dash.pl > mcproject_code/src/rtl/video/osd/mc_osd_dash.v
#   想改显示什么、显示在哪：改下面 @ITEMS（每个项目 = 一个固定字符串 / 一个状态名 / 一个数字），再重新生成。
#   生成的 mc_osd_dash.v 是"查表 + 一个序列器 + 共用的一个数字转换器"：
#     · 项目表（第几行第几列、什么类型）和文字表（所有固定字符串和状态名）都是 ROM（case 语句）；
#     · 序列器每 100 ms 把所有项目逐个写进字符 RAM（字符串：查文字表；数字：先取值，用共用的转换器转成十进制，再逐位写）。
#   只有一页（没有翻页）。数字转换器按需生成：没有有符号的项目就不生成符号逻辑（取绝对值 / '+' '-'），BCD 位数 = 项目里最大的位数。
#   有符号的项目（num 的来源在 @SRC 里写 signed = 1）出现时脚本自动生成完整版本：现在亮度档 ev（−4~+4）用到它，
#   tb_dash 测了 '+' / '-'、0、最大 / 最小值。
# =============================================================================
use strict;
use warnings;

my $NROWS = 5;                                  # 文字框行数（和 mctop.v 的 OSD_ROWS 一致）
my $NCOLS = 45;                                 # 每行字符数（和 mctop.v 的 OSD_COLS 一致）

# ---- 状态名表（按状态值从小到大排；同一个表里每个名字一样长）----
my %NAMES = (
    sd    => [6, "INIT  ", "READY ", "NO SD ", "NO FAT", "??????"],
    codec => [4, "INIT", "OK  ", "ERR ", "????"],
    state => [4, "IDLE", "OPEN", "PLAY", "ERR "],
    tail  => [4, "IDLE", "HOME", "WAG ", "????"],
    evt   => [8, "--------", "K1 SHORT", "K1 LONG ", "K2 SHORT", "K2 LONG ", "K3 SHORT", "K3 LONG "],
    keys  => [3, map { sprintf("%d%d%d", ($_ >> 2) & 1, ($_ >> 1) & 1, $_ & 1) } 0 .. 7],
    plan  => [4, "GO  ", "STOP"],
    uwb   => [4, "LOST", "OK  "],
    cmd   => [4, "LOST", "NCAM", "HERE", "BLK ", "TURN", "GO  "],
);
# 选择器编号（"用哪个信号当状态值"），对应生成的 Verilog 里的 S_selv；0 = 固定字符串
my %SELID = (sd => 1, codec => 2, bgm => 3, sfx => 4, evt => 5, keys => 6, tail => 7, plan => 8, uwb => 9, cmd => 10);
my %SELTAB = (sd => 'sd', codec => 'codec', bgm => 'state', sfx => 'state', evt => 'evt', keys => 'keys', tail => 'tail', plan => 'plan', uwb => 'uwb', cmd => 'cmd');
my $SELMAX = 0; for my $v (values %SELID) { $SELMAX = $v if $v > $SELMAX; }
my $SELW = 1; $SELW++ while ((1 << $SELW) <= $SELMAX);      # 选择器的位数

# ---- 数字的取值来源（编号 = 在下面的 case 里的号码；signed = 有符号）----
my @SRC = (
    ['sec',   32,  0, 'S_sec'],
    ['gain',   8,  0, 'S_gain'],
    ['exp',   12,  0, 'S_exp'],
    ['ev',     4,  1, 'S_ev'],
    ['hall',   1,  0, 'I_hall'],
    ['near',   8,  0, 'S_near'],
    ['ndeg',   7,  1, 'S_ndeg'],
    ['gdeg',   7,  1, 'S_gdeg'],
    ['gfree',  8,  0, 'S_gfree'],
    ['udeg',   8,  1, 'I_uwb_deg'],
    ['ucm',   10,  0, 'I_uwb_cm'],
    ['cmdl',  14,  1, 'I_cmd_l'],
    ['cmdr',  14,  1, 'I_cmd_r'],
);
my %SRCID; for my $i (0 .. $#SRC) { $SRCID{$SRC[$i][0]} = $i; }
my $SRCW = 1; $SRCW++ while ((1 << $SRCW) < @SRC);             # 取值来源编号的位数

# ---- 项目：{row=>行, col=>列, str=>固定字符串 | sel=>状态名表 | num=>数字来源, dig=>位数} ----
my @ITEMS = (
    # 第 0 行：相机增益（自动曝光给的）/ 霍尔 / 尾巴动作 / 三个键的电平（SW1 SW2 SW3）/ 开机秒数
    { row => 0, col => 0,  str => "GAIN " },
    { row => 0, col => 5,  num => 'gain', dig => 3 },
    { row => 0, col => 10, str => "HALL " },
    { row => 0, col => 15, num => 'hall', dig => 1 },
    { row => 0, col => 18, str => "TAIL " },
    { row => 0, col => 23, sel => 'tail' },
    { row => 0, col => 28, str => "KEY " },
    { row => 0, col => 32, sel => 'keys' },
    { row => 0, col => 36, str => "UP " },
    { row => 0, col => 39, num => 'sec', dig => 5 },
    { row => 0, col => 44, str => "s" },
    # 第 1 行：音频（TF 卡 / ES8388 / 背景音乐 / 音效 的状态）/ 亮度档
    { row => 1, col => 0,  str => "SD " },
    { row => 1, col => 3,  sel => 'sd' },
    { row => 1, col => 10, str => "CODEC " },
    { row => 1, col => 16, sel => 'codec' },
    { row => 1, col => 22, str => "BGM " },
    { row => 1, col => 26, sel => 'bgm' },
    { row => 1, col => 32, str => "SFX " },
    { row => 1, col => 36, sel => 'sfx' },
    { row => 1, col => 41, str => "EV" },
    { row => 1, col => 43, num => 'ev', dig => 1 },
    # 第 2 行：最近一次按键事件 / 按键提示 / 曝光行数
    { row => 2, col => 0,  sel => 'evt' },
    { row => 2, col => 10, str => "SW2/3 EV+/- SW1 2s reset" },
    { row => 2, col => 35, str => "EXP " },
    { row => 2, col => 39, num => 'exp', dig => 4 },
    # 第 3 行：避障（最近的障碍多远、在哪个方向；建议往哪走、那边能走多远）
    { row => 3, col => 0,  str => "NEAR " },
    { row => 3, col => 5,  num => 'near', dig => 3 },
    { row => 3, col => 8,  str => "cm " },
    { row => 3, col => 11, num => 'ndeg', dig => 2 },
    { row => 3, col => 14, str => "deg" },
    { row => 3, col => 19, sel => 'plan' },
    { row => 3, col => 24, num => 'gdeg', dig => 2 },
    { row => 3, col => 27, str => "deg " },
    { row => 3, col => 31, num => 'gfree', dig => 3 },
    { row => 3, col => 34, str => "cm" },
    # 第 4 行：跟随（主人在哪：UWB 角度 / 距离；决策：状态 / 左右轮 PWM）
    { row => 4, col => 0,  str => "UWB " },
    { row => 4, col => 4,  sel => 'uwb' },
    { row => 4, col => 9,  num => 'udeg', dig => 2 },
    { row => 4, col => 12, str => "deg " },
    { row => 4, col => 16, num => 'ucm', dig => 3 },
    { row => 4, col => 19, str => "cm  CMD " },
    { row => 4, col => 27, sel => 'cmd' },
    { row => 4, col => 32, str => "L" },
    { row => 4, col => 33, num => 'cmdl', dig => 4 },
    { row => 4, col => 39, str => "R" },
    { row => 4, col => 40, num => 'cmdr', dig => 4 },
);

# ---- 文字 ROM：先放状态名表，再放固定字符串（相同的字符串只放一份）----
my @ROM;                                   # 每个元素 = 一个字符（ASCII 码）
my %TABBASE;                               # 状态名表 → 起始地址
for my $t (sort keys %NAMES) {
    my ($len, @vals) = @{ $NAMES{$t} };
    $TABBASE{$t} = scalar(@ROM);
    for my $v (@vals) { die "name length: $t $v" if length($v) != $len; push @ROM, map { ord($_) } split //, $v; }
}
my %STRBASE;
for my $it (@ITEMS) {
    next unless defined $it->{str};
    my $s = $it->{str};
    next if exists $STRBASE{$s};
    $STRBASE{$s} = scalar(@ROM);
    push @ROM, map { ord($_) } split //, $s;
}
die "text ROM too big" if @ROM > 1023;

# ---- 项目描述符：{row[2:0], col[5:0], kind, f1[5:0], sel[SELW-1:0], f3[9:0]} ----
#   字符串项目：f1 = 长度，sel = 状态名选择器（0 = 固定字符串），f3 = 文字 ROM 起始地址
#   数字项目  ：f1 = {sgn, dig[2:0]}（低 4 位），sel = 0，f3 = 取值来源编号
my @DESC;
for my $it (@ITEMS) {
    my ($kind, $f1, $sel, $f3);
    if (defined $it->{str}) {
        $kind = 0; $f1 = length($it->{str}); $sel = 0; $f3 = $STRBASE{ $it->{str} };
    } elsif (defined $it->{sel}) {
        my $tab = $SELTAB{ $it->{sel} };
        $kind = 0; $f1 = $NAMES{$tab}[0]; $sel = $SELID{ $it->{sel} }; $f3 = $TABBASE{$tab};
    } else {
        my $src = $SRCID{ $it->{num} }; die "bad source $it->{num}" unless defined $src;
        my $sgn = $SRC[$src][2];
        die "dig" if $it->{dig} < 1 || $it->{dig} > 7;
        $kind = 1; $f1 = ($sgn << 3) | $it->{dig}; $sel = 0; $f3 = $src;
    }
    die "col+len > $NCOLS: " . ($it->{str} // $it->{sel} // $it->{num}) if $it->{col} + ($kind ? $it->{dig} + (($f1 >> 3) & 1) : $f1) > $NCOLS;
    die "row >= $NROWS" if $it->{row} >= $NROWS;
    push @DESC, [$it->{row}, $it->{col}, $kind, $f1, $sel, $f3, $it];
}
my $N = scalar(@DESC);

# ---- 数字转换器的规格：有没有有符号的项目、最多几位（决定要不要生成符号逻辑、BCD 有几位）----
my ($ANYSGN, $NDIG) = (0, 1);
for my $d (@DESC) { if ($d->[2]) { $ANYSGN = 1 if (($d->[3] >> 3) & 1); my $dg = $d->[3] & 7; $NDIG = $dg if $dg > $NDIG; } }
my $BW = 4 * $NDIG;                                         # BCD 的位数 × 4
my $BMSB = $BW - 1; my $BTOP = $BW - 4;
my $SGN_DECL = $ANYSGN ? "reg         S_neg;" : "// （没有有符号的项目：不生成符号相关的逻辑；加有符号的项目时脚本会自动生成）";
my $SGN_WIRE = $ANYSGN ? "wire       D_sgn  = D_f1[3];" : "";
my $ABS_BLK  = $ANYSGN ? "wire       S_vneg = D_sgn & S_v[31];\nwire [31:0] S_abs = S_vneg ? (~S_v + 32'd1) : S_v;" : "wire [31:0] S_abs = S_v;";
my $NUM_CH   = $ANYSGN ? "wire [7:0] S_num_ch = (D_sgn && S_ci == 6'd0) ? (S_neg ? 8'h2D : 8'h2B) : (8'h30 + {4'd0, S_bcd[${BMSB}:${BTOP}]});" : "wire [7:0] S_num_ch = 8'h30 + {4'd0, S_bcd[${BMSB}:${BTOP}]};";
my $NUM_LAST = $ANYSGN ? "{3'd0, D_dig} + {5'd0, D_sgn} - 6'd1" : "{3'd0, D_dig} - 6'd1";
my $LOAD_NEG = $ANYSGN ? "            S_neg  <= S_vneg;\n" : "";
my $NUM_SHIFT = $ANYSGN ? "if (!(D_sgn && S_ci == 6'd0)) S_bcd <= S_bcd << 4;" : "S_bcd <= S_bcd << 4;";

# 描述符的位置（从低位到高位）
my $DW = 10 + $SELW + 6 + 1 + 6 + 3;                           # 描述符总位数
my ($F3_LO, $SEL_LO, $F1_LO, $KIND_LO, $COL_LO, $ROW_LO);
$F3_LO = 0; $SEL_LO = 10; $F1_LO = $SEL_LO + $SELW; $KIND_LO = $F1_LO + 6; $COL_LO = $KIND_LO + 1; $ROW_LO = $COL_LO + 6;
sub fld { my ($lo, $w) = @_; return $w == 1 ? sprintf("S_d[%d]", $lo) : sprintf("S_d[%d:%d]", $lo + $w - 1, $lo); }

# ---------------------------------------------------------------------------------------------------------------
my $DESCMSB = $DW - 1;

print <<"EOT";
`timescale 1ns / 1ps
// =============================================================================
// mc_osd_dash.v  屏幕中间状态带里的文字（5 行 × 45 列）：把相机自动曝光、霍尔、尾巴、按键、音频、避障、跟随状态排成文字
//   ★ 本文件由 tools/gen_osd_dash.pl 生成，不要手改：想改显示什么、显示在哪，改脚本里的 \@ITEMS 再重新生成。
//
//   实现：一张"项目表"（第几行第几列、是固定字符串 / 状态名 / 数字）+ 一张"文字表"（所有固定字符串和状态名，ROM）
//         + 一个序列器 + 一个共用的二进制→十进制转换器。每 100 ms，序列器把所有项目逐个写进字符 RAM：
//           · 字符串 / 状态名：按"文字表起始地址 + 状态值 × 长度 + 第几个字符"查表，一个时钟写一个字符；
//           · 数字：按来源编号取值，用共用的转换器（逐位移位加 3）转成十进制，再逐位写（保留前导零；位数不够显示高位时只显示低位）。
//         写总线格式见 mc_osd_text.v：{we, row[3:0], col[6:0], char[7:0]}，链的第一级是 mc_osd_clear（复位后先清屏，再轮到本模块写）。
//         复位后约 1 ms 画第一遍，之后每 100 ms 刷新一遍。只有一页。
//
//   版面（45 列 × 5 行）：
//     GAIN 050  HALL 0  TAIL IDLE KEY 000 UP 00123s     ← 相机增益 / 霍尔（1 = 磁铁靠近）/ 尾巴动作 / 三个键（SW1 SW2 SW3）/ 开机秒数
//     SD READY  CODEC OK    BGM PLAY  SFX IDLE EV+0     ← TF 卡 / ES8388 / 背景音乐 / 音效 / 亮度档
//     K1 SHORT  SW2/3 EV+/- SW1 2s reset EXP 2275       ← 最近一次按键事件 / 按键提示 / 曝光行数
//     NEAR 045cm -12deg  GO   +06deg 150cm          ← 最近的障碍（255 = 1.5 m 内没有）/ 建议方向（STOP = 走不了）/ 那边能走多远
//     UWB OK   -12deg 350cm  CMD GO   L+3000 R+2100 ← 主人在哪（LOST = 收不到 UWB）/ 跟随决策（LOST NCAM HERE BLK TURN GO）/ 左右轮 PWM
// =============================================================================
module mc_osd_dash #(
    parameter ROWS = $NROWS,                     // 文字框行数、列数（只用来清屏；版面按 $NCOLS 列 × $NROWS 行排）
    parameter COLS = $NCOLS
)(
    input  wire         I_clk,                  // 100 MHz
    input  wire         I_rst_n,
    input  wire         I_tick_1ms,
    input  wire         I_tick_100ms,

    input  wire [2:0]   I_key_pressed,
    input  wire [2:0]   I_key_short,
    input  wire [2:0]   I_key_long,

    input  wire [7:0]   I_cam_gain,             // 相机自动曝光：增益（0.3 dB 一级）（24 MHz 域，内部同步）
    input  wire [11:0]  I_cam_exp,              //               曝光行数（同上）
    input  wire [3:0]   I_cam_ev,               //               亮度档 0~8，显示成 −4~+4（同上）
    input  wire [7:0]   I_obs_near,             // 避障：最近的障碍（厘米，255 = 1.5 m 内没有）（相机像素时钟域，内部同步）
    input  wire [6:0]   I_obs_near_deg,         //       它的方向（度，有符号）
    input  wire [6:0]   I_obs_go_deg,           //       建议方向（度，有符号）
    input  wire [7:0]   I_obs_free,             //       那边能走多远（厘米）
    input  wire         I_obs_stop,             //       哪边都走不了
    input  wire         I_hall,                 // 霍尔传感器：1 = 磁铁靠近（正在喂食）
    input  wire [1:0]   I_tail_seq,             // 尾巴动作：0 空闲 1 回零 2 摇摆
    input  wire         I_uwb_ok,               // 跟随：收到主人位置（mc_m0_link，100 MHz 域）
    input  wire [7:0]   I_uwb_deg,              //       主人的角度（度，有符号，左负右正）
    input  wire [9:0]   I_uwb_cm,               //       主人的距离（厘米）
    input  wire [2:0]   I_cmd_state,            //       决策状态（mc_follow：0 LOST 1 NCAM 2 HERE 3 BLK 4 TURN 5 GO）
    input  wire [13:0]  I_cmd_l,                //       左 / 右轮 PWM（有符号）
    input  wire [13:0]  I_cmd_r,

    input  wire [2:0]   I_aud_sd,               // 音频：TF 卡状态 0 INIT 1 READY 2 NO SD 3 NO FAT
    input  wire [1:0]   I_aud_codec,            //       ES8388 配置状态 0 INIT 1 OK 2 ERR
    input  wire [1:0]   I_bgm_state,            //       背景音乐状态 0 IDLE 1 OPEN 2 PLAY 3 ERR
    input  wire [1:0]   I_sfx_state,            //       音效状态（同上）

    output wire [19:0]  O_bus                   // 接 mc_osd_text 的 I_wbus
);

localparam N_ITEMS = $N;

// ---------------------------------------------------------------------------
// 刷新节拍：复位后约 1 ms 画第一遍（清屏写总线时本模块自动等），之后每 100 ms 一遍
// ---------------------------------------------------------------------------
reg S_started;
always \@(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)          S_started <= 1'b0;
    else if (I_tick_1ms)   S_started <= 1'b1;
end

wire S_go = I_tick_100ms | (I_tick_1ms & ~S_started);

// 开机秒数
reg [3:0]  S_dec;
reg [31:0] S_sec;
always \@(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        S_dec <= 4'd0;
        S_sec <= 32'd0;
    end else if (I_tick_100ms) begin
        if (S_dec == 4'd9) begin S_dec <= 4'd0; S_sec <= S_sec + 32'd1; end
        else               S_dec <= S_dec + 4'd1;
    end
end

wire [7:0]  S_gain;
wire [11:0] S_exp;
wire [3:0]  S_evr;
mc_sync_bits #(.W(24)) u_sync_cam (.I_clk(I_clk), .I_d({I_cam_gain, I_cam_exp, I_cam_ev}), .O_q({S_gain, S_exp, S_evr}));
wire [3:0]  S_ev = S_evr - 4'd4;              // 有符号：−4 ~ +4
wire [7:0]  S_near, S_gfree;
wire [6:0]  S_ndeg, S_gdeg;
wire        S_stop;
mc_sync_bits #(.W(31)) u_sync_obs (.I_clk(I_clk), .I_d({I_obs_near, I_obs_near_deg, I_obs_go_deg, I_obs_free, I_obs_stop}),
                                   .O_q({S_near, S_ndeg, S_gdeg, S_gfree, S_stop}));

// 最近一次按键事件（0 没有；1 K1 短 2 K1 长 3 K2 短 4 K2 长 5 K3 短 6 K3 长）
reg [2:0] S_evt;
always \@(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)              S_evt <= 3'd0;
    else if (I_key_short[0])   S_evt <= 3'd1;
    else if (I_key_long[0])    S_evt <= 3'd2;
    else if (I_key_short[1])   S_evt <= 3'd3;
    else if (I_key_long[1])    S_evt <= 3'd4;
    else if (I_key_short[2])   S_evt <= 3'd5;
    else if (I_key_long[2])    S_evt <= 3'd6;
end

// ---------------------------------------------------------------------------
// 项目表（ROM）：{行[2:0], 列[5:0], 类型, f1[5:0], 选择器[${\($SELW-1)}:0], f3[9:0]}
//   字符串项目：f1 = 长度，选择器 0 = 固定字符串，否则 = 用哪个信号当状态值，f3 = 文字表起始地址
//   数字项目  ：f1 = {有符号, 位数[2:0]}，f3 = 取值来源编号
// ---------------------------------------------------------------------------
function [$DESCMSB:0] desc;
    input [6:0] i;
    begin
        case (i)
EOT

for my $i (0 .. $#DESC) {
    my ($row, $col, $kind, $f1, $sel, $f3, $it) = @{ $DESC[$i] };
    my $what = defined $it->{str} ? "\"$it->{str}\"" : defined $it->{sel} ? "状态名 $it->{sel}" : "数字 $it->{num} ($it->{dig} 位)";
    printf "            7'd%-2d: desc = {3'd%d, 6'd%-2d, 1'b%d, 6'd%-2d, %d'd%d, 10'd%-3d};   // 第 %d 行第 %2d 列 %s\n",
        $i, $row, $col, $kind, $f1, $SELW, $sel, $f3, $row, $col, $what;
}

print <<"EOT";
            default: desc = ${DW}'d0;
        endcase
    end
endfunction

// ---------------------------------------------------------------------------
// 文字表（ROM）：状态名表在前、固定字符串在后；没列出的地址 = 空格
// ---------------------------------------------------------------------------
function [7:0] rom;
    input [9:0] a;
    begin
        case (a)
EOT

for my $a (0 .. $#ROM) {
    next if $ROM[$a] == 0x20;
    my $c = chr($ROM[$a]);
    my $cm = ($c eq "\\" ) ? "\\\\" : $c;
    printf "            10'd%-3d: rom = 8'h%02X;   // '%s'\n", $a, $ROM[$a], $cm;
}

print <<"EOT";
            default: rom = 8'h20;
        endcase
    end
endfunction

// ---------------------------------------------------------------------------
// 序列器
// ---------------------------------------------------------------------------
localparam [2:0] ST_IDLE = 3'd0, ST_FETCH = 3'd1, ST_CHECK = 3'd2, ST_STR = 3'd3,
                 ST_LOAD = 3'd4, ST_CONV  = 3'd5, ST_ALIGN = 3'd6, ST_NUM = 3'd7;

reg  [2:0]  S_st;
reg  [6:0]  S_it;                            // 当前项目号
reg  [5:0]  S_ci;                            // 项目里的第几个字符
reg  [$DESCMSB:0] S_d;                             // 当前项目的描述符（取出后锁存）
reg  [9:0]  S_a;                             // 文字表地址（字符串项目）
reg  [31:0] S_bin;                           // 转换：绝对值，被逐位移出
reg  [${BMSB}:0] S_bcd;                           // 转换：${NDIG} 位 BCD；写字符时每写一位左移 4 位，最高位的数字就是下一个要写的
${SGN_DECL}
reg  [5:0]  S_iter;
wire [19:0] S_ib;                            // 上游（清屏）的写总线
reg         S_bus_we;                        // 输出总线：写使能（有复位）
reg  [18:0] S_bus_d;                         // 输出总线：行 / 列 / 字符（无复位）

assign O_bus = {S_bus_we, S_bus_d};

wire [2:0] D_row  = @{[ fld($ROW_LO, 3) ]};
wire [5:0] D_col  = @{[ fld($COL_LO, 6) ]};
wire       D_kind = @{[ fld($KIND_LO, 1) ]};
wire [5:0] D_f1   = @{[ fld($F1_LO, 6) ]};
wire [@{[$SELW-1]}:0] D_sel  = @{[ fld($SEL_LO, $SELW) ]};
wire [9:0] D_f3   = @{[ fld($F3_LO, 10) ]};
wire [2:0] D_dig  = D_f1[2:0];
${SGN_WIRE}

// 状态值（选择器）
reg [2:0] S_selv;
always \@* begin
    case (D_sel)
        ${SELW}'d$SELID{sd}:  S_selv = I_aud_sd[2] ? 3'd4 : {1'd0, I_aud_sd[1:0]};
        ${SELW}'d$SELID{codec}:  S_selv = {1'd0, I_aud_codec};
        ${SELW}'d$SELID{bgm}:  S_selv = {1'd0, I_bgm_state};
        ${SELW}'d$SELID{sfx}:  S_selv = {1'd0, I_sfx_state};
        ${SELW}'d$SELID{evt}:  S_selv = S_evt;
        ${SELW}'d$SELID{keys}:  S_selv = {I_key_pressed[0], I_key_pressed[1], I_key_pressed[2]};
        ${SELW}'d$SELID{tail}:  S_selv = {1'd0, I_tail_seq};
        ${SELW}'d$SELID{plan}:  S_selv = {2'd0, S_stop};
        ${SELW}'d$SELID{uwb}:  S_selv = {2'd0, I_uwb_ok};
        ${SELW}'d$SELID{cmd}:  S_selv = I_cmd_state;
        default: S_selv = 3'd0;
    endcase
end

// 状态值 × 长度（移位相加，不用乘法器）
wire [8:0] S_off = (S_selv[0] ? {3'd0, D_f1}       : 9'd0) +
                   (S_selv[1] ? {2'd0, D_f1, 1'b0} : 9'd0) +
                   (S_selv[2] ? {1'd0, D_f1, 2'b0} : 9'd0);

// 数字的取值：32 位（有符号的来源符号扩展）
reg [31:0] S_v;
always \@* begin
    case (D_f3[@{[$SRCW-1]}:0])
EOT

for my $i (0 .. $#SRC) {
    my ($name, $w, $sgn, $sig) = @{ $SRC[$i] };
    my $expr;
    if ($w == 32) { $expr = $sig; }
    elsif ($sgn)  { $expr = sprintf("{{%d{%s[%d]}}, %s}", 32 - $w, $sig, $w - 1, $sig); }
    else          { $expr = sprintf("{%d'd0, %s}", 32 - $w, $sig); }
    printf "        %d'd%-2d: S_v = %s;\n", $SRCW, $i, $expr;
}

print <<"EOT";
        default: S_v = 32'd0;
    endcase
end

${ABS_BLK}

// ---- 二进制转 BCD（逐位移位法）：每个数字 >= 5 就加 3，再整体左移一位 ----
reg [${BMSB}:0] S_adj;
integer k;
always \@* begin
    for (k = 0; k < ${NDIG}; k = k + 1)
        S_adj[k*4 +: 4] = (S_bcd[k*4 +: 4] >= 4'd5) ? (S_bcd[k*4 +: 4] + 4'd3) : S_bcd[k*4 +: 4];
end

// ---- 要写的字符 ----
${NUM_CH}
wire [7:0] S_ch     = (S_st == ST_STR) ? rom(S_a) : S_num_ch;
wire       S_emit   = ((S_st == ST_STR) || (S_st == ST_NUM)) && !S_ib[19];   // 上游空闲才能写

wire [5:0] S_num_last = ${NUM_LAST};                  // 数字项目最后一个字符的序号

always \@(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        S_st     <= ST_IDLE;
        S_it     <= 7'd0;
        S_bus_we <= 1'b0;
    end else begin
        S_bus_we <= S_ib[19] | S_emit;                  // 上游在写就透传；自己写字符时也是 1

        case (S_st)
            ST_IDLE: if (S_go) begin
                S_it <= 7'd0;
                S_st <= ST_FETCH;
            end

            ST_FETCH: begin
                if (S_it == N_ITEMS) S_st <= ST_IDLE;     // 一遍写完
                else                 S_st <= ST_CHECK;
            end

            ST_CHECK: S_st <= D_kind ? ST_LOAD : ST_STR;

            ST_STR: if (!S_ib[19]) begin
                if (S_ci == D_f1 - 6'd1) begin
                    S_it <= S_it + 7'd1;
                    S_st <= ST_FETCH;
                end
            end

            ST_LOAD: S_st <= ST_CONV;

            ST_CONV: if (S_iter == 6'd31) S_st <= ST_ALIGN;

            ST_ALIGN: if ({3'd0, S_iter[2:0]} + {3'd0, D_dig} >= 6'd${NDIG}) S_st <= ST_NUM;     // 把要显示的最高位数字移到最左边（位数 < ${NDIG} 时先丢掉多余的高位）

            ST_NUM: if (!S_ib[19]) begin
                if (S_ci == S_num_last) begin
                    S_it <= S_it + 7'd1;
                    S_st <= ST_FETCH;
                end
            end

            default: S_st <= ST_IDLE;
        endcase
    end
end

// ---- 数据（无复位：使用前总是先被写过）----
always \@(posedge I_clk) begin
    case (S_st)
        ST_FETCH: S_d <= desc(S_it);
        ST_CHECK: begin
            S_a  <= D_f3 + {1'b0, S_off};
            S_ci <= 6'd0;
        end
        ST_STR:   if (!S_ib[19]) begin S_a <= S_a + 10'd1; S_ci <= S_ci + 6'd1; end
        ST_LOAD: begin
${LOAD_NEG}            S_bin  <= S_abs;
            S_bcd  <= ${BW}'d0;
            S_iter <= 6'd0;
        end
        ST_CONV: begin
            {S_bcd, S_bin} <= {S_adj, S_bin} << 1;
            S_iter <= (S_iter == 6'd31) ? 6'd0 : (S_iter + 6'd1);
        end
        ST_ALIGN: begin
            S_iter <= S_iter + 6'd1;
            if ({3'd0, S_iter[2:0]} + {3'd0, D_dig} < 6'd${NDIG}) S_bcd <= S_bcd << 4;
        end
        ST_NUM:   if (!S_ib[19]) begin
            S_ci <= S_ci + 6'd1;
            ${NUM_SHIFT}
        end
        default: ;
    endcase

    if (S_ib[19])     S_bus_d <= S_ib[18:0];
    else if (S_emit)  S_bus_d <= {1'b0, D_row, 1'b0, D_col + S_ci, S_ch};
end

// ---------------------------------------------------------------------------
// 清屏（链的第一级）：复位后清整个文字框
// ---------------------------------------------------------------------------
mc_osd_clear #(.ROWS(ROWS), .COLS(COLS)) u_clr (.I_clk(I_clk), .I_rst_n(I_rst_n), .I_bus(20'd0), .O_bus(S_ib));

endmodule
EOT
