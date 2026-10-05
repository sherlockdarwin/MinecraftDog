`timescale 1ns / 1ps
// =============================================================================
// mc_osd_dash.v  屏幕中间状态带里的文字（3 行 × 45 列）：把相机增益、霍尔、尾巴、按键、音频状态排成文字
//   ★ 本文件由 tools/gen_osd_dash.pl 生成，不要手改：想改显示什么、显示在哪，改脚本里的 @ITEMS 再重新生成。
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
    parameter ROWS = 3,                     // 文字框行数、列数（只用来清屏；版面按 45 列 × 3 行排）
    parameter COLS = 45
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

localparam N_ITEMS = 21;

// ---------------------------------------------------------------------------
// 刷新节拍：复位后约 1 ms 画第一遍（清屏写总线时本模块自动等），之后每 100 ms 一遍
// ---------------------------------------------------------------------------
reg S_started;
always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)          S_started <= 1'b0;
    else if (I_tick_1ms)   S_started <= 1'b1;
end

wire S_go = I_tick_100ms | (I_tick_1ms & ~S_started);

// 开机秒数
reg [3:0]  S_dec;
reg [31:0] S_sec;
always @(posedge I_clk or negedge I_rst_n) begin
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
always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)              S_evt <= 3'd0;
    else if (I_key_short[0])   S_evt <= 3'd1;
    else if (I_key_long[0])    S_evt <= 3'd2;
    else if (I_key_short[1])   S_evt <= 3'd3;
    else if (I_key_long[1])    S_evt <= 3'd4;
    else if (I_key_short[2])   S_evt <= 3'd5;
    else if (I_key_long[2])    S_evt <= 3'd6;
end

// ---------------------------------------------------------------------------
// 项目表（ROM）：{行[2:0], 列[5:0], 类型, f1[5:0], 选择器[2:0], f3[9:0]}
//   字符串项目：f1 = 长度，选择器 0 = 固定字符串，否则 = 用哪个信号当状态值，f3 = 文字表起始地址
//   数字项目  ：f1 = {有符号, 位数[2:0]}，f3 = 取值来源编号
// ---------------------------------------------------------------------------
function [28:0] desc;
    input [6:0] i;
    begin
        case (i)
            7'd0 : desc = {3'd0, 6'd0 , 1'b0, 6'd5 , 3'd0, 10'd158};   // 第 0 行第  0 列 "GAIN "
            7'd1 : desc = {3'd0, 6'd5 , 1'b1, 6'd3 , 3'd0, 10'd1  };   // 第 0 行第  5 列 数字 ae (3 位)
            7'd2 : desc = {3'd0, 6'd10, 1'b0, 6'd5 , 3'd0, 10'd163};   // 第 0 行第 10 列 "HALL "
            7'd3 : desc = {3'd0, 6'd15, 1'b1, 6'd1 , 3'd0, 10'd2  };   // 第 0 行第 15 列 数字 hall (1 位)
            7'd4 : desc = {3'd0, 6'd18, 1'b0, 6'd5 , 3'd0, 10'd168};   // 第 0 行第 18 列 "TAIL "
            7'd5 : desc = {3'd0, 6'd23, 1'b0, 6'd4 , 3'd7, 10'd142};   // 第 0 行第 23 列 状态名 tail
            7'd6 : desc = {3'd0, 6'd28, 1'b0, 6'd4 , 3'd0, 10'd173};   // 第 0 行第 28 列 "KEY "
            7'd7 : desc = {3'd0, 6'd32, 1'b0, 6'd3 , 3'd6, 10'd72 };   // 第 0 行第 32 列 状态名 keys
            7'd8 : desc = {3'd0, 6'd36, 1'b0, 6'd3 , 3'd0, 10'd177};   // 第 0 行第 36 列 "UP "
            7'd9 : desc = {3'd0, 6'd39, 1'b1, 6'd5 , 3'd0, 10'd0  };   // 第 0 行第 39 列 数字 sec (5 位)
            7'd10: desc = {3'd0, 6'd44, 1'b0, 6'd1 , 3'd0, 10'd180};   // 第 0 行第 44 列 "s"
            7'd11: desc = {3'd1, 6'd0 , 1'b0, 6'd3 , 3'd0, 10'd181};   // 第 1 行第  0 列 "SD "
            7'd12: desc = {3'd1, 6'd3 , 1'b0, 6'd6 , 3'd1, 10'd96 };   // 第 1 行第  3 列 状态名 sd
            7'd13: desc = {3'd1, 6'd10, 1'b0, 6'd6 , 3'd0, 10'd184};   // 第 1 行第 10 列 "CODEC "
            7'd14: desc = {3'd1, 6'd16, 1'b0, 6'd4 , 3'd2, 10'd0  };   // 第 1 行第 16 列 状态名 codec
            7'd15: desc = {3'd1, 6'd22, 1'b0, 6'd4 , 3'd0, 10'd190};   // 第 1 行第 22 列 "BGM "
            7'd16: desc = {3'd1, 6'd26, 1'b0, 6'd4 , 3'd3, 10'd126};   // 第 1 行第 26 列 状态名 bgm
            7'd17: desc = {3'd1, 6'd32, 1'b0, 6'd4 , 3'd0, 10'd194};   // 第 1 行第 32 列 "SFX "
            7'd18: desc = {3'd1, 6'd36, 1'b0, 6'd4 , 3'd4, 10'd126};   // 第 1 行第 36 列 状态名 sfx
            7'd19: desc = {3'd2, 6'd0 , 1'b0, 6'd8 , 3'd5, 10'd16 };   // 第 2 行第  0 列 状态名 evt
            7'd20: desc = {3'd2, 6'd10, 1'b0, 6'd32, 3'd0, 10'd198};   // 第 2 行第 10 列 "SW2 gain+ SW3 gain- SW1 2s reset"
            default: desc = 29'd0;
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
            10'd0  : rom = 8'h49;   // 'I'
            10'd1  : rom = 8'h4E;   // 'N'
            10'd2  : rom = 8'h49;   // 'I'
            10'd3  : rom = 8'h54;   // 'T'
            10'd4  : rom = 8'h4F;   // 'O'
            10'd5  : rom = 8'h4B;   // 'K'
            10'd8  : rom = 8'h45;   // 'E'
            10'd9  : rom = 8'h52;   // 'R'
            10'd10 : rom = 8'h52;   // 'R'
            10'd12 : rom = 8'h3F;   // '?'
            10'd13 : rom = 8'h3F;   // '?'
            10'd14 : rom = 8'h3F;   // '?'
            10'd15 : rom = 8'h3F;   // '?'
            10'd16 : rom = 8'h2D;   // '-'
            10'd17 : rom = 8'h2D;   // '-'
            10'd18 : rom = 8'h2D;   // '-'
            10'd19 : rom = 8'h2D;   // '-'
            10'd20 : rom = 8'h2D;   // '-'
            10'd21 : rom = 8'h2D;   // '-'
            10'd22 : rom = 8'h2D;   // '-'
            10'd23 : rom = 8'h2D;   // '-'
            10'd24 : rom = 8'h4B;   // 'K'
            10'd25 : rom = 8'h31;   // '1'
            10'd27 : rom = 8'h53;   // 'S'
            10'd28 : rom = 8'h48;   // 'H'
            10'd29 : rom = 8'h4F;   // 'O'
            10'd30 : rom = 8'h52;   // 'R'
            10'd31 : rom = 8'h54;   // 'T'
            10'd32 : rom = 8'h4B;   // 'K'
            10'd33 : rom = 8'h31;   // '1'
            10'd35 : rom = 8'h4C;   // 'L'
            10'd36 : rom = 8'h4F;   // 'O'
            10'd37 : rom = 8'h4E;   // 'N'
            10'd38 : rom = 8'h47;   // 'G'
            10'd40 : rom = 8'h4B;   // 'K'
            10'd41 : rom = 8'h32;   // '2'
            10'd43 : rom = 8'h53;   // 'S'
            10'd44 : rom = 8'h48;   // 'H'
            10'd45 : rom = 8'h4F;   // 'O'
            10'd46 : rom = 8'h52;   // 'R'
            10'd47 : rom = 8'h54;   // 'T'
            10'd48 : rom = 8'h4B;   // 'K'
            10'd49 : rom = 8'h32;   // '2'
            10'd51 : rom = 8'h4C;   // 'L'
            10'd52 : rom = 8'h4F;   // 'O'
            10'd53 : rom = 8'h4E;   // 'N'
            10'd54 : rom = 8'h47;   // 'G'
            10'd56 : rom = 8'h4B;   // 'K'
            10'd57 : rom = 8'h33;   // '3'
            10'd59 : rom = 8'h53;   // 'S'
            10'd60 : rom = 8'h48;   // 'H'
            10'd61 : rom = 8'h4F;   // 'O'
            10'd62 : rom = 8'h52;   // 'R'
            10'd63 : rom = 8'h54;   // 'T'
            10'd64 : rom = 8'h4B;   // 'K'
            10'd65 : rom = 8'h33;   // '3'
            10'd67 : rom = 8'h4C;   // 'L'
            10'd68 : rom = 8'h4F;   // 'O'
            10'd69 : rom = 8'h4E;   // 'N'
            10'd70 : rom = 8'h47;   // 'G'
            10'd72 : rom = 8'h30;   // '0'
            10'd73 : rom = 8'h30;   // '0'
            10'd74 : rom = 8'h30;   // '0'
            10'd75 : rom = 8'h30;   // '0'
            10'd76 : rom = 8'h30;   // '0'
            10'd77 : rom = 8'h31;   // '1'
            10'd78 : rom = 8'h30;   // '0'
            10'd79 : rom = 8'h31;   // '1'
            10'd80 : rom = 8'h30;   // '0'
            10'd81 : rom = 8'h30;   // '0'
            10'd82 : rom = 8'h31;   // '1'
            10'd83 : rom = 8'h31;   // '1'
            10'd84 : rom = 8'h31;   // '1'
            10'd85 : rom = 8'h30;   // '0'
            10'd86 : rom = 8'h30;   // '0'
            10'd87 : rom = 8'h31;   // '1'
            10'd88 : rom = 8'h30;   // '0'
            10'd89 : rom = 8'h31;   // '1'
            10'd90 : rom = 8'h31;   // '1'
            10'd91 : rom = 8'h31;   // '1'
            10'd92 : rom = 8'h30;   // '0'
            10'd93 : rom = 8'h31;   // '1'
            10'd94 : rom = 8'h31;   // '1'
            10'd95 : rom = 8'h31;   // '1'
            10'd96 : rom = 8'h49;   // 'I'
            10'd97 : rom = 8'h4E;   // 'N'
            10'd98 : rom = 8'h49;   // 'I'
            10'd99 : rom = 8'h54;   // 'T'
            10'd102: rom = 8'h52;   // 'R'
            10'd103: rom = 8'h45;   // 'E'
            10'd104: rom = 8'h41;   // 'A'
            10'd105: rom = 8'h44;   // 'D'
            10'd106: rom = 8'h59;   // 'Y'
            10'd108: rom = 8'h4E;   // 'N'
            10'd109: rom = 8'h4F;   // 'O'
            10'd111: rom = 8'h53;   // 'S'
            10'd112: rom = 8'h44;   // 'D'
            10'd114: rom = 8'h4E;   // 'N'
            10'd115: rom = 8'h4F;   // 'O'
            10'd117: rom = 8'h46;   // 'F'
            10'd118: rom = 8'h41;   // 'A'
            10'd119: rom = 8'h54;   // 'T'
            10'd120: rom = 8'h3F;   // '?'
            10'd121: rom = 8'h3F;   // '?'
            10'd122: rom = 8'h3F;   // '?'
            10'd123: rom = 8'h3F;   // '?'
            10'd124: rom = 8'h3F;   // '?'
            10'd125: rom = 8'h3F;   // '?'
            10'd126: rom = 8'h49;   // 'I'
            10'd127: rom = 8'h44;   // 'D'
            10'd128: rom = 8'h4C;   // 'L'
            10'd129: rom = 8'h45;   // 'E'
            10'd130: rom = 8'h4F;   // 'O'
            10'd131: rom = 8'h50;   // 'P'
            10'd132: rom = 8'h45;   // 'E'
            10'd133: rom = 8'h4E;   // 'N'
            10'd134: rom = 8'h50;   // 'P'
            10'd135: rom = 8'h4C;   // 'L'
            10'd136: rom = 8'h41;   // 'A'
            10'd137: rom = 8'h59;   // 'Y'
            10'd138: rom = 8'h45;   // 'E'
            10'd139: rom = 8'h52;   // 'R'
            10'd140: rom = 8'h52;   // 'R'
            10'd142: rom = 8'h49;   // 'I'
            10'd143: rom = 8'h44;   // 'D'
            10'd144: rom = 8'h4C;   // 'L'
            10'd145: rom = 8'h45;   // 'E'
            10'd146: rom = 8'h48;   // 'H'
            10'd147: rom = 8'h4F;   // 'O'
            10'd148: rom = 8'h4D;   // 'M'
            10'd149: rom = 8'h45;   // 'E'
            10'd150: rom = 8'h57;   // 'W'
            10'd151: rom = 8'h41;   // 'A'
            10'd152: rom = 8'h47;   // 'G'
            10'd154: rom = 8'h3F;   // '?'
            10'd155: rom = 8'h3F;   // '?'
            10'd156: rom = 8'h3F;   // '?'
            10'd157: rom = 8'h3F;   // '?'
            10'd158: rom = 8'h47;   // 'G'
            10'd159: rom = 8'h41;   // 'A'
            10'd160: rom = 8'h49;   // 'I'
            10'd161: rom = 8'h4E;   // 'N'
            10'd163: rom = 8'h48;   // 'H'
            10'd164: rom = 8'h41;   // 'A'
            10'd165: rom = 8'h4C;   // 'L'
            10'd166: rom = 8'h4C;   // 'L'
            10'd168: rom = 8'h54;   // 'T'
            10'd169: rom = 8'h41;   // 'A'
            10'd170: rom = 8'h49;   // 'I'
            10'd171: rom = 8'h4C;   // 'L'
            10'd173: rom = 8'h4B;   // 'K'
            10'd174: rom = 8'h45;   // 'E'
            10'd175: rom = 8'h59;   // 'Y'
            10'd177: rom = 8'h55;   // 'U'
            10'd178: rom = 8'h50;   // 'P'
            10'd180: rom = 8'h73;   // 's'
            10'd181: rom = 8'h53;   // 'S'
            10'd182: rom = 8'h44;   // 'D'
            10'd184: rom = 8'h43;   // 'C'
            10'd185: rom = 8'h4F;   // 'O'
            10'd186: rom = 8'h44;   // 'D'
            10'd187: rom = 8'h45;   // 'E'
            10'd188: rom = 8'h43;   // 'C'
            10'd190: rom = 8'h42;   // 'B'
            10'd191: rom = 8'h47;   // 'G'
            10'd192: rom = 8'h4D;   // 'M'
            10'd194: rom = 8'h53;   // 'S'
            10'd195: rom = 8'h46;   // 'F'
            10'd196: rom = 8'h58;   // 'X'
            10'd198: rom = 8'h53;   // 'S'
            10'd199: rom = 8'h57;   // 'W'
            10'd200: rom = 8'h32;   // '2'
            10'd202: rom = 8'h67;   // 'g'
            10'd203: rom = 8'h61;   // 'a'
            10'd204: rom = 8'h69;   // 'i'
            10'd205: rom = 8'h6E;   // 'n'
            10'd206: rom = 8'h2B;   // '+'
            10'd208: rom = 8'h53;   // 'S'
            10'd209: rom = 8'h57;   // 'W'
            10'd210: rom = 8'h33;   // '3'
            10'd212: rom = 8'h67;   // 'g'
            10'd213: rom = 8'h61;   // 'a'
            10'd214: rom = 8'h69;   // 'i'
            10'd215: rom = 8'h6E;   // 'n'
            10'd216: rom = 8'h2D;   // '-'
            10'd218: rom = 8'h53;   // 'S'
            10'd219: rom = 8'h57;   // 'W'
            10'd220: rom = 8'h31;   // '1'
            10'd222: rom = 8'h32;   // '2'
            10'd223: rom = 8'h73;   // 's'
            10'd225: rom = 8'h72;   // 'r'
            10'd226: rom = 8'h65;   // 'e'
            10'd227: rom = 8'h73;   // 's'
            10'd228: rom = 8'h65;   // 'e'
            10'd229: rom = 8'h74;   // 't'
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
reg  [28:0] S_d;                             // 当前项目的描述符（取出后锁存）
reg  [9:0]  S_a;                             // 文字表地址（字符串项目）
reg  [31:0] S_bin;                           // 转换：绝对值，被逐位移出
reg  [19:0] S_bcd;                           // 转换：5 位 BCD；写字符时每写一位左移 4 位，最高位的数字就是下一个要写的
// （没有有符号的项目：不生成符号相关的逻辑；加有符号的项目时脚本会自动生成）
reg  [5:0]  S_iter;
wire [19:0] S_ib;                            // 上游（清屏）的写总线
reg         S_bus_we;                        // 输出总线：写使能（有复位）
reg  [18:0] S_bus_d;                         // 输出总线：行 / 列 / 字符（无复位）

assign O_bus = {S_bus_we, S_bus_d};

wire [2:0] D_row  = S_d[28:26];
wire [5:0] D_col  = S_d[25:20];
wire       D_kind = S_d[19];
wire [5:0] D_f1   = S_d[18:13];
wire [2:0] D_sel  = S_d[12:10];
wire [9:0] D_f3   = S_d[9:0];
wire [2:0] D_dig  = D_f1[2:0];


// 状态值（选择器）
reg [2:0] S_selv;
always @* begin
    case (D_sel)
        3'd1:  S_selv = I_aud_sd[2] ? 3'd4 : {1'd0, I_aud_sd[1:0]};
        3'd2:  S_selv = {1'd0, I_aud_codec};
        3'd3:  S_selv = {1'd0, I_bgm_state};
        3'd4:  S_selv = {1'd0, I_sfx_state};
        3'd5:  S_selv = S_evt;
        3'd6:  S_selv = {I_key_pressed[0], I_key_pressed[1], I_key_pressed[2]};
        3'd7:  S_selv = {1'd0, I_tail_seq};
        default: S_selv = 3'd0;
    endcase
end

// 状态值 × 长度（移位相加，不用乘法器）
wire [8:0] S_off = (S_selv[0] ? {3'd0, D_f1}       : 9'd0) +
                   (S_selv[1] ? {2'd0, D_f1, 1'b0} : 9'd0) +
                   (S_selv[2] ? {1'd0, D_f1, 2'b0} : 9'd0);

// 数字的取值：32 位（有符号的来源符号扩展）
reg [31:0] S_v;
always @* begin
    case (D_f3[1:0])
        2'd0 : S_v = S_sec;
        2'd1 : S_v = {24'd0, S_ae};
        2'd2 : S_v = {31'd0, I_hall};
        default: S_v = 32'd0;
    endcase
end

wire [31:0] S_abs = S_v;

// ---- 二进制转 BCD（逐位移位法）：每个数字 >= 5 就加 3，再整体左移一位 ----
reg [19:0] S_adj;
integer k;
always @* begin
    for (k = 0; k < 5; k = k + 1)
        S_adj[k*4 +: 4] = (S_bcd[k*4 +: 4] >= 4'd5) ? (S_bcd[k*4 +: 4] + 4'd3) : S_bcd[k*4 +: 4];
end

// ---- 要写的字符 ----
wire [7:0] S_num_ch = 8'h30 + {4'd0, S_bcd[19:16]};
wire [7:0] S_ch     = (S_st == ST_STR) ? rom(S_a) : S_num_ch;
wire       S_emit   = ((S_st == ST_STR) || (S_st == ST_NUM)) && !S_ib[19];   // 上游空闲才能写

wire [5:0] S_num_last = {3'd0, D_dig} - 6'd1;                  // 数字项目最后一个字符的序号

always @(posedge I_clk or negedge I_rst_n) begin
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

            ST_ALIGN: if ({3'd0, S_iter[2:0]} + {3'd0, D_dig} >= 6'd5) S_st <= ST_NUM;     // 把要显示的最高位数字移到最左边（位数 < 5 时先丢掉多余的高位）

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
always @(posedge I_clk) begin
    case (S_st)
        ST_FETCH: S_d <= desc(S_it);
        ST_CHECK: begin
            S_a  <= D_f3 + {1'b0, S_off};
            S_ci <= 6'd0;
        end
        ST_STR:   if (!S_ib[19]) begin S_a <= S_a + 10'd1; S_ci <= S_ci + 6'd1; end
        ST_LOAD: begin
            S_bin  <= S_abs;
            S_bcd  <= 20'd0;
            S_iter <= 6'd0;
        end
        ST_CONV: begin
            {S_bcd, S_bin} <= {S_adj, S_bin} << 1;
            S_iter <= (S_iter == 6'd31) ? 6'd0 : (S_iter + 6'd1);
        end
        ST_ALIGN: begin
            S_iter <= S_iter + 6'd1;
            if ({3'd0, S_iter[2:0]} + {3'd0, D_dig} < 6'd5) S_bcd <= S_bcd << 4;
        end
        ST_NUM:   if (!S_ib[19]) begin
            S_ci <= S_ci + 6'd1;
            S_bcd <= S_bcd << 4;
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
