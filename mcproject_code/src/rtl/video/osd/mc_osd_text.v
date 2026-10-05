`timescale 1ns / 1ps
// =============================================================================
// mc_osd_text.v  文字层：一块 COLS × ROWS 的字符 RAM + 逐像素渲染（像素时钟域）
//
//   能显示什么：ASCII 32~126（空格、数字、大小写英文字母、标点），每个字符 8×16 像素，可整数倍放大。
//   在屏幕上占多大：文字框左上角 (X0, Y0)，宽 COLS×8×2^SCALE_SH、高 ROWS×16×2^SCALE_SH 像素。
//        默认 45 列 × 8 行、放大 2 倍（每个字符 16×32 像素）→ 720 × 256 像素，放在 800×1280 竖屏的下半部分。
//
//   怎么写字（相当于 OLED_ShowChar）：往写入总线 I_wbus 送一个"写请求"，格式（20 位）：
//        {we[19], row[18:15], col[14:8], char[7:0]}    we=1 的那个 I_wclk 时钟沿，把 ASCII 码 char 写到第 row 行第 col 列。
//   平时不用直接写：写请求由 mc_osd_dash（项目表 + 序列器，每 100 ms 重画一遍）生成，清屏用 mc_osd_clear。
//
//   时序：I_x/I_y 是当前像素在屏幕上的坐标（与 mc_mixer 里决定 O_rd_en 的计数器同一拍）；
//         O_hit / O_on 比 I_x/I_y 晚 4 个像素时钟（RAM 读 + 字库读 + 取位 各 1 拍，再加坐标换算 1 拍）。
//         O_hit = 当前像素在文字框内；O_on = 当前像素是字符的笔画（前景）。
//   跨时钟域：字符 RAM 写口在 I_wclk（100 MHz 系统时钟），读口在 I_pclk（像素时钟）。同一个字符恰好在被写的
//         那一瞬间被读到，最坏情况是那个字符这一帧显示成旧值或乱码，下一帧恢复，对状态文字无影响。
// =============================================================================
module mc_osd_text #(
    parameter X0       = 40,            // 文字框左上角 X（像素）
    parameter Y0       = 640,           // 文字框左上角 Y（行）
    parameter COLS     = 45,            // 每行字符数（最大 128）
    parameter ROWS     = 8,             // 行数（最大 16）
    parameter SCALE_SH = 1              // 放大倍数 = 2^SCALE_SH（0：8×16，1：16×32，2：32×64）
)(
    input  wire        I_pclk,
    input  wire [10:0] I_x,
    input  wire [10:0] I_y,
    output reg         O_hit,
    output reg         O_on,

    input  wire        I_wclk,
    input  wire [19:0] I_wbus
);

localparam BOX_W = (COLS * 8)  << SCALE_SH;
localparam BOX_H = (ROWS * 16) << SCALE_SH;
localparam DEPTH = COLS * ROWS;

function integer clog2;
    input integer v;
    integer n;
    begin
        n = 0;
        while ((1 << n) < v) n = n + 1;
        clog2 = n;
    end
endfunction
localparam AW = clog2(DEPTH);

// ---------------------------------------------------------------------------
// 字符 RAM：写口 I_wclk，读口 I_pclk（读比地址晚一拍）
// ---------------------------------------------------------------------------
reg [7:0] S_mem [0:DEPTH-1];

reg          S_we;
reg [AW-1:0] S_waddr;
reg [7:0]    S_wdata;

always @(posedge I_wclk) begin
    S_we    <= I_wbus[19] && (I_wbus[18:15] < ROWS) && (I_wbus[14:8] < COLS);
    S_waddr <= I_wbus[18:15] * COLS + I_wbus[14:8];
    S_wdata <= I_wbus[7:0];
end

always @(posedge I_wclk) begin
    if (S_we) S_mem[S_waddr] <= S_wdata;
end

// ---------------------------------------------------------------------------
// 第 0 级（组合）：坐标 → 框内判断、字符行列、字内像素
// ---------------------------------------------------------------------------
wire        S_in  = (I_x >= X0) && (I_x < X0 + BOX_W) && (I_y >= Y0) && (I_y < Y0 + BOX_H);
wire [10:0] S_dx  = I_x - X0;
wire [10:0] S_dy  = I_y - Y0;
wire [6:0]  S_col = S_dx >> (3 + SCALE_SH);
wire [3:0]  S_row = S_dy >> (4 + SCALE_SH);
wire [2:0]  S_px  = S_dx >> SCALE_SH;                   // 取低 3 位
wire [3:0]  S_ln  = S_dy >> SCALE_SH;                   // 取低 4 位

// 第 1 级：寄存
reg          S_in_1;
reg [AW-1:0] S_ra_1;
reg [2:0]    S_px_1;
reg [3:0]    S_ln_1;

always @(posedge I_pclk) begin
    S_in_1 <= S_in;
    S_ra_1 <= S_row * COLS + S_col;
    S_px_1 <= S_px;
    S_ln_1 <= S_ln;
end

// 第 2 级：字符 RAM 读出
reg [7:0] S_ch_2;
reg       S_in_2;
reg [2:0] S_px_2;
reg [3:0] S_ln_2;

always @(posedge I_pclk) begin
    S_ch_2 <= S_mem[S_ra_1];
    S_in_2 <= S_in_1;
    S_px_2 <= S_px_1;
    S_ln_2 <= S_ln_1;
end

// 第 3 级：字库 ROM 读出（mc_font8x16 内部寄存一拍）
wire [7:0] S_bits_3;
reg        S_in_3;
reg [2:0]  S_px_3;

mc_font8x16 u_font (
    .I_clk  (I_pclk),
    .I_addr ({S_ch_2[6:0], S_ln_2}),
    .O_data (S_bits_3)
);

always @(posedge I_pclk) begin
    S_in_3 <= S_in_2;
    S_px_3 <= S_px_2;
end

// 第 4 级：按列取出这个像素是不是笔画（bit7 = 最左列）
always @(posedge I_pclk) begin
    O_hit <= S_in_3;
    O_on  <= S_in_3 & S_bits_3[3'd7 - S_px_3];
end

endmodule
