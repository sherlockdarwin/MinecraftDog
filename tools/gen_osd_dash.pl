#!/usr/bin/perl
# =============================================================================
# 生成屏幕状态面板 mcproject_code/src/rtl/video/osd/mc_osd_dash.v
#   用法：perl tools/gen_osd_dash.pl > mcproject_code/src/rtl/video/osd/mc_osd_dash.v
#   想改显示什么、显示在哪：改下面 @ITEMS（每个项目 = 一个固定字符串 / 一个状态名 / 一个数字），再重新生成。
#   生成的 mc_osd_dash.v 是"查表 + 一个序列器 + 共用的一个数字转换器"：
#     · 项目表（第几行第几列、什么类型）和文字表（所有固定字符串和状态名）都是 ROM（case 语句）；
#     · 序列器每 100 ms 把所有项目逐个写进字符 RAM（字符串：查文字表；数字：先取值，用共用的转换器转成十进制，再逐位写）。
#   只有一页（没有翻页）。数字转换器按需生成：没有有符号的项目就不生成符号逻辑（取绝对值 / '+' '-'），BCD 位数 = 项目里最大的位数。
#   有符号的项目（num 的来源在 @SRC 里写 signed = 1）出现时脚本自动生成完整版本；那条路径目前没有项目用、没有测试台覆盖，
#   加有符号的项目时要先在 tb_dash 里补测（'+' / '-'、0、最大 / 最小值）。旧版（带有符号、7 位 BCD、有测试）在 git 提交 a8d9f01 里。
# =============================================================================
use strict;
use warnings;

my $NROWS = 3;                                  # 文字框行数（和 mctop.v 的 OSD_ROWS 一致）
my $NCOLS = 45;                                 # 每行字符数（和 mctop.v 的 OSD_COLS 一致）

# ---- 状态名表（按状态值从小到大排；同一个表里每个名字一样长）----
my %NAMES = (
    sd    => [6, "INIT  ", "READY ", "NO SD ", "NO FAT", "??????"],
    codec => [4, "INIT", "OK  ", "ERR ", "????"],
    state => [4, "IDLE", "OPEN", "PLAY", "ERR "],
    tail  => [4, "IDLE", "HOME", "WAG ", "????"],
    evt   => [8, "--------", "K1 SHORT", "K1 LONG ", "K2 SHORT", "K2 LONG ", "K3 SHORT", "K3 LONG "],
    keys  => [3, map { sprintf("%d%d%d", ($_ >> 2) & 1, ($_ >> 1) & 1, $_ & 1) } 0 .. 7],
);
# 选择器编号（"用哪个信号当状态值"），对应生成的 Verilog 里的 S_selv；0 = 固定字符串
my %SELID = (sd => 1, codec => 2, bgm => 3, sfx => 4, evt => 5, keys => 6, tail => 7);
my %SELTAB = (sd => 'sd', codec => 'codec', bgm => 'state', sfx => 'state', evt => 'evt', keys => 'keys', tail => 'tail');
my $SELMAX = 0; for my $v (values %SELID) { $SELMAX = $v if $v > $SELMAX; }
my $SELW = 1; $SELW++ while ((1 << $SELW) <= $SELMAX);      # 选择器的位数

# ---- 数字的取值来源（编号 = 在下面的 case 里的号码；signed = 有符号）----
my @SRC = (
    ['sec',   32,  0, 'S_sec'],
    ['ae',     8,  0, 'S_ae'],
    ['hall',   1,  0, 'I_hall'],
);
my %SRCID; for my $i (0 .. $#SRC) { $SRCID{$SRC[$i][0]} = $i; }
my $SRCW = 1; $SRCW++ while ((1 << $SRCW) < @SRC);             # 取值来源编号的位数

# ---- 项目：{row=>行, col=>列, str=>固定字符串 | sel=>状态名表 | num=>数字来源, dig=>位数} ----
my @ITEMS = (
    # 第 0 行：相机增益 / 霍尔 / 尾巴动作 / 三个键的电平 / 开机秒数
    { row => 0, col => 0,  str => "GAIN " },
    { row => 0, col => 5,  num => 'ae', dig => 3 },
    { row => 0, col => 10, str => "HALL " },
    { row => 0, col => 15, num => 'hall', dig => 1 },
    { row => 0, col => 18, str => "TAIL " },
    { row => 0, col => 23, sel => 'tail' },
    { row => 0, col => 28, str => "KEY " },
    { row => 0, col => 32, sel => 'keys' },
    { row => 0, col => 36, str => "UP " },
    { row => 0, col => 39, num => 'sec', dig => 5 },
    { row => 0, col => 44, str => "s" },
    # 第 1 行：音频（TF 卡 / ES8388 / 背景音乐 / 音效 的状态）
    { row => 1, col => 0,  str => "SD " },
    { row => 1, col => 3,  sel => 'sd' },
    { row => 1, col => 10, str => "CODEC " },
    { row => 1, col => 16, sel => 'codec' },
    { row => 1, col => 22, str => "BGM " },
    { row => 1, col => 26, sel => 'bgm' },
    { row => 1, col => 32, str => "SFX " },
    { row => 1, col => 36, sel => 'sfx' },
    # 第 2 行：最近一次按键事件 / 按键提示
    { row => 2, col => 0,  sel => 'evt' },
    { row => 2, col => 10, str => "SW2 gain+ SW3 gain- SW1 2s reset" },
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
// mc_osd_dash.v  屏幕中间状态带里的文字（3 行 × 45 列）：把相机增益、霍尔、尾巴、按键、音频状态排成文字
//   ★ 本文件由 tools/gen_osd_dash.pl 生成，不要手改：想改显示什么、显示在哪，改脚本里的 \@ITEMS 再重新生成。
//
//   实现：一张"项目表"（第几行第几列、是固定字符串 / 状态名 / 数字）+ 一张"文字表"（所有固定字符串和状态名，ROM）
//         + 一个序列器 + 一个共用的二进制→十进制转换器。每 100 ms，序列器把所有项目逐个写进字符 RAM：
//           · 字符串 / 状态名：按"文字表起始地址 + 状态值 × 长度 + 第几个字符"查表，一个时钟写一个字符；
//           · 数字：按来源编号取值，用共用的转换器（逐位移位加 3）转成十进制，再逐位写（保留前导零；位数不够显示高位时只显示低位）。
//         写总线格式见 mc_osd_text.v：{we, row[3:0], col[6:0], char[7:0]}，链的第一级是 mc_osd_clear（复位后先清屏，再轮到本模块写）。
//         复位后约 1 ms 画第一遍，之后每 100 ms 刷新一遍。只有一页。
//
//   版面（45 列 × 3 行）：
//     GAIN 050  HALL 0  TAIL IDLE KEY 000 UP 00123s     ← 相机增益 / 霍尔（1 = 磁铁靠近）/ 尾巴动作 / 三个键 / 开机秒数
//     SD READY  CODEC OK    BGM PLAY  SFX IDLE          ← TF 卡 / ES8388 / 背景音乐 / 音效
//     K1 SHORT  SW2 gain+ SW3 gain- SW1 2s reset        ← 最近一次按键事件 / 按键提示
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

    input  wire [7:0]   I_cam_ae,               // 相机曝光/增益值（24 MHz 域，内部同步）
    input  wire         I_hall,                 // 霍尔传感器：1 = 磁铁靠近（正在喂食）
    input  wire [1:0]   I_tail_seq,             // 尾巴动作：0 空闲 1 回零 2 摇摆

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

wire [7:0] S_ae;
mc_sync_bits #(.W(8)) u_sync_ae (.I_clk(I_clk), .I_d(I_cam_ae), .O_q(S_ae));

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
