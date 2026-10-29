`timescale 1ns / 1ps
// =============================================================================
// mc_mixer.v  屏幕画面合成（像素时钟域）——取代厂商 mixer.v
//
// 一、版面（竖屏，800×1280；坐标单位像素，u 向右、v 向下；实际数值由 mctop 配置区传入）：上面相机、紧接着状态带、下面留给避障
//     相机窗口     u 0~799，  v 0~447          800×448：传感器完整视场等比缩小（mc_scale），不拉伸
//       状态方块   v 452~491，u = 40 + 90k     8 个 80×40 的方块（绿 = 对应状态位为 1，红 = 0），k = 0~7
//       文字区     u 40~759， v 496~687        TXT_COLS × TXT_ROWS（45 列 × 6 行），每字符 16×32 像素，黑底白字
//       安路 Logo  u LOGO_U0~+479，v LOGO_V0~+127   480×128 白底横幅（mc_osd_logo，位图 mc_logo_rom）
//     避障画面     u 0~799，  v OBS_V0~OBS_V0+449  160×90 的处理结果放大 5 倍 + 红框（mc_obs_view），上方 10 行是建议方向的绿条
//   相机画面取数：厂商 video_out（顺序读，O_rd_en），读使能之后第 2 个时钟像素有效。
//
// 二、没有相机帧（I_win_en = 0）时窗口里是黑色（背景色），状态方块和文字照常显示；I_win_en 在帧起始处锁存，
//     保证整帧要么全读相机要么全不读。
//
// 三、其他
//   · 背景默认黑色（BG_PATTERN = 0）；想用厂商的测试图案排查屏幕链路时改成 1，图案由 video_tpg 产生。
//   · 叠放顺序（从上到下）：文字层 > Logo > 相机窗口 > 避障画面 > 状态方块 > 背景；写字走 I_txt_bus（见 mc_osd_text.v / mc_osd_dash.v）。
//
// 流水线（总延迟 6 拍，所有信号等量延迟，对屏幕没有影响）：
//   第 0 拍：S_x/S_y（面板坐标）和读使能 → 第 1 拍：画布坐标 S_u/S_v（竖屏下就是 S_x/S_y，同时是文字层的输入）
//   → 第 2 拍：相机像素到达、方块判断结果 → … → 第 5 拍：文字层 O_hit/O_on 出来，各路汇合 → 第 6 拍：输出寄存
// =============================================================================
module mc_mixer #(
    parameter PANEL_W   = 800,      // 面板宽
    parameter PANEL_H   = 1280,     // 面板高
    parameter IMG_W     = 800,      // 相机窗口宽（像素）
    parameter IMG_H     = 448,      // 相机窗口高
    parameter SQ_V0     = 456,      // 状态方块起始行
    parameter SQ_U0     = 40,       // 第 0 个方块的起始列
    parameter SQ_W      = 80,
    parameter SQ_H      = 40,
    parameter SQ_PITCH  = 90,       // 相邻方块间距
    parameter TXT_U0    = 40,       // 文字框左上角 u
    parameter TXT_V0    = 504,      // 文字框左上角 v
    parameter TXT_COLS  = 45,       // 文字框每行字符数
    parameter TXT_ROWS  = 4,        // 文字框行数
    parameter TXT_SH    = 1,        // 字符放大倍数 = 2^TXT_SH（1 → 每个字符 16×32 像素）
    parameter [23:0] TXT_FG = 24'hFFFFFF,   // 文字颜色
    parameter [23:0] TXT_BG = 24'h000000,   // 文字框底色
    parameter TXT_BG_EN = 1,        // 1：文字框有底色（盖住背景）；0：只画笔画，背景透出来
    parameter BG_PATTERN = 0,       // 0：背景黑色；1：背景用 video_tpg 的测试图案
    parameter [10:0] OBS_V0 = 11'd830,  // 避障画面起始行
    parameter [7:0]  REF_X0 = 8'd56,    // 地面参考区（网格坐标，画黄框；要和 mc_obs 的一致）
    parameter [7:0]  REF_X1 = 8'd103,
    parameter [6:0]  REF_Y0 = 7'd82,
    parameter [6:0]  REF_Y1 = 7'd89,
    parameter [6:0]  ROW_MIN = 7'd29,    // 避障画面：这一行以上（不判断障碍的远处）画暗灰（要和 mc_obs 的一致）
    parameter LOGO_U0   = 160,      // 安路 Logo（480×128）左上角；放到面板外就不显示
    parameter LOGO_V0   = 678
)(
    input  wire        I_clk,       // 像素时钟 = DSI 字节时钟

    input  wire        I_vsync,     // 高有效同步脉冲（帧起始处，持续 VSA 行）
    input  wire        I_hsync,
    input  wire        I_de,
    input  wire [23:0] I_bg_data,   // 背景图案 {R,G,B}，与 I_de 对齐

    input  wire        I_win_en,    // 相机帧是否在持续到来（任意时钟域，内部同步）
    input  wire [7:0]  I_status,    // 状态位（任意时钟域，内部同步）

    input  wire        I_txt_clk,   // 文字写入时钟（系统 100 MHz）
    input  wire [19:0] I_txt_bus,   // 文字写入总线 {we,row,col,char}（见 mc_osd_text.v）

    input  wire        I_obs_wclk,  // 避障画面写入（相机像素时钟域，见 mc_obs_core）
    input  wire [24:0] I_obs_wbus,
    input  wire        I_obs_pub_bank,
    input  wire        I_obs_pub_valid,
    input  wire [5:0]  I_obs_go,
    output wire        O_obs_disp_bank,

    output wire        O_rd_en,     // → 厂商 video_out：读一个相机像素
    input  wire [23:0] I_rd_data,   // ← 厂商 video_out：相机像素 {R,G,B}，O_rd_en 之后第 2 个时钟有效

    output reg         O_vsync,
    output reg         O_hsync,
    output reg         O_de,
    output reg  [23:0] O_data
);

localparam [23:0] C_ON  = 24'h00C800;   // 绿
localparam [23:0] C_OFF = 24'hC80000;   // 红

// ---------------------------------------------------------------------------
// 异步输入同步
// ---------------------------------------------------------------------------
wire        S_win_en;
wire [7:0]  S_status;

mc_sync_bits #(.W(9)) u_sync (
    .I_clk (I_clk),
    .I_d   ({I_win_en, I_status}),
    .O_q   ({S_win_en, S_status})
);

// ---------------------------------------------------------------------------
// 第 0 拍：行/列计数（面板坐标）：x = 本行已输出的有效像素数；y = 本帧已完成的有效行数
// ---------------------------------------------------------------------------
reg        S_de_d;
reg        S_vs_d;
reg [10:0] S_x;
reg [10:0] S_y;
reg        S_win_lat  = 1'b0;          // 帧起始处锁存，保证整帧要么全读要么全不读

wire S_vs_rise = I_vsync & ~S_vs_d;
wire S_de_fall = S_de_d  & ~I_de;

always @(posedge I_clk) begin
    S_de_d <= I_de;
    S_vs_d <= I_vsync;

    if (!I_de) S_x <= 11'd0;
    else       S_x <= S_x + 11'd1;

    if (S_vs_rise)      S_y <= 11'd0;
    else if (S_de_fall) S_y <= S_y + 11'd1;

    if (S_vs_rise) S_win_lat <= S_win_en;
end

// 相机窗口：上方 IMG_H 行，整行宽
wire S_img = (S_y < IMG_H);

assign O_rd_en = I_de & S_win_lat & S_img;

// ---------------------------------------------------------------------------
// 第 1 拍：画布坐标（竖屏：画布 = 面板）
// ---------------------------------------------------------------------------
reg [10:0] S_u;
reg [10:0] S_v;

always @(posedge I_clk) begin
    S_u <= S_x;
    S_v <= S_y;
end

// ---------------------------------------------------------------------------
// 状态方块（画布坐标，第 1 拍输入）
// ---------------------------------------------------------------------------
wire       S_sq_row = (S_v >= SQ_V0) && (S_v < (SQ_V0 + SQ_H));
wire [7:0] S_sq_hit;

genvar k;
generate
    for (k = 0; k < 8; k = k + 1) begin : G_SQ
        assign S_sq_hit[k] = S_sq_row && (S_u >= (SQ_U0 + k * SQ_PITCH))
                                      && (S_u <  (SQ_U0 + k * SQ_PITCH + SQ_W));
    end
endgenerate

wire S_sq_any = |S_sq_hit;
wire S_sq_on  = |(S_sq_hit & S_status);

// ---------------------------------------------------------------------------
// 文字层（输入是第 1 拍的画布坐标；O_hit/O_on 晚 4 拍 = 第 5 拍）
// ---------------------------------------------------------------------------
wire S_txt_hit;
wire S_txt_on;

mc_osd_text #(
    .X0       (TXT_U0),
    .Y0       (TXT_V0),
    .COLS     (TXT_COLS),
    .ROWS     (TXT_ROWS),
    .SCALE_SH (TXT_SH)
) u_osd_text (
    .I_pclk (I_clk),
    .I_x    (S_u),
    .I_y    (S_v),
    .O_hit  (S_txt_hit),
    .O_on   (S_txt_on),
    .I_wclk (I_txt_clk),
    .I_wbus (I_txt_bus)
);

// ---------------------------------------------------------------------------
// 避障画面（输入是第 1 拍的画布坐标；O_hit/O_rgb 晚 4 拍 = 第 5 拍）
// ---------------------------------------------------------------------------
wire        S_obs_hit;
wire [23:0] S_obs_rgb;

mc_obs_view #(
    .V0     (OBS_V0),
    .REF_X0 (REF_X0), .REF_X1 (REF_X1), .REF_Y0 (REF_Y0), .REF_Y1 (REF_Y1), .ROW_MIN (ROW_MIN)
) u_obs_view (
    .I_clk       (I_clk),
    .I_vsync     (I_vsync),
    .I_u         (S_u),
    .I_v         (S_v),
    .O_hit       (S_obs_hit),
    .O_rgb       (S_obs_rgb),
    .I_wclk      (I_obs_wclk),
    .I_wbus      (I_obs_wbus),
    .I_pub_bank  (I_obs_pub_bank),
    .I_pub_valid (I_obs_pub_valid),
    .I_go        (I_obs_go),
    .O_disp_bank (O_obs_disp_bank)
);

// ---------------------------------------------------------------------------
// 安路 Logo（输入是第 1 拍的画布坐标；O_hit/O_rgb 晚 4 拍 = 第 5 拍）
// ---------------------------------------------------------------------------
wire        S_logo_hit;
wire [23:0] S_logo_rgb;

mc_osd_logo #(
    .U0 (LOGO_U0),
    .V0 (LOGO_V0)
) u_osd_logo (
    .I_clk (I_clk),
    .I_u   (S_u),
    .I_v   (S_v),
    .O_hit (S_logo_hit),
    .O_rgb (S_logo_rgb)
);

// ---------------------------------------------------------------------------
// 对齐流水线 + 合成：各路都延迟到第 5 拍再合成
// ---------------------------------------------------------------------------
reg        S_vs_1, S_vs_2, S_vs_3, S_vs_4, S_vs_5;
reg        S_hs_1, S_hs_2, S_hs_3, S_hs_4, S_hs_5;
reg        S_de_1, S_de_2, S_de_3, S_de_4, S_de_5;
reg [23:0] S_bg_1, S_bg_2, S_bg_3, S_bg_4, S_bg_5;
reg        S_win_1, S_win_2, S_win_3, S_win_4, S_win_5;
reg        S_sqa_2, S_sqa_3, S_sqa_4, S_sqa_5;
reg        S_sqo_2, S_sqo_3, S_sqo_4, S_sqo_5;
reg [23:0] S_rd_3, S_rd_4, S_rd_5;

wire        S_txt_ovr = (TXT_BG_EN != 0) ? S_txt_hit : S_txt_on;     // 文字层是否盖住这个像素
wire [23:0] S_bg      = (BG_PATTERN != 0) ? S_bg_5 : 24'h000000;
wire [23:0] S_pix = S_txt_ovr  ? (S_txt_on ? TXT_FG : TXT_BG) :
                    S_logo_hit ? S_logo_rgb :
                    S_win_5   ? S_rd_5 :
                    S_obs_hit ? S_obs_rgb :
                    S_sqa_5   ? (S_sqo_5 ? C_ON : C_OFF) :
                                S_bg;

always @(posedge I_clk) begin
    S_vs_1  <= I_vsync;    S_vs_2  <= S_vs_1;   S_vs_3  <= S_vs_2;   S_vs_4  <= S_vs_3;   S_vs_5  <= S_vs_4;
    S_hs_1  <= I_hsync;    S_hs_2  <= S_hs_1;   S_hs_3  <= S_hs_2;   S_hs_4  <= S_hs_3;   S_hs_5  <= S_hs_4;
    S_de_1  <= I_de;       S_de_2  <= S_de_1;   S_de_3  <= S_de_2;   S_de_4  <= S_de_3;   S_de_5  <= S_de_4;
    S_bg_1  <= I_bg_data;  S_bg_2  <= S_bg_1;   S_bg_3  <= S_bg_2;   S_bg_4  <= S_bg_3;   S_bg_5  <= S_bg_4;
    S_win_1 <= O_rd_en;
    S_win_2 <= S_win_1;    S_win_3 <= S_win_2;  S_win_4 <= S_win_3;  S_win_5 <= S_win_4;
    S_sqa_2 <= S_sq_any;   S_sqa_3 <= S_sqa_2;  S_sqa_4 <= S_sqa_3;  S_sqa_5 <= S_sqa_4;
    S_sqo_2 <= S_sq_on;    S_sqo_3 <= S_sqo_2;  S_sqo_4 <= S_sqo_3;  S_sqo_5 <= S_sqo_4;
    S_rd_3  <= I_rd_data;  S_rd_4  <= S_rd_3;   S_rd_5  <= S_rd_4;                       // 读出端像素在第 2 拍有效

    O_vsync <= S_vs_5;
    O_hsync <= S_hs_5;
    O_de    <= S_de_5;
    O_data  <= S_pix;
end

endmodule
