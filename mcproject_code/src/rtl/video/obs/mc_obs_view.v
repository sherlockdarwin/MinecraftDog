`timescale 1ns / 1ps
// =============================================================================
// mc_obs_view.v  屏幕下面的"避障处理画面"（显示时钟域，挂在 mc_mixer 里）
//
//   画面：160×90 网格，每格放大成 5×5 像素 → 800×450，放在 v = V0 ~ V0+449。
//     颜色（亮度 y 取自小图）：地面（能走）= 偏绿 (y, y+96, y)；障碍 = 偏紫 (y+64, y+32, y+128)；
//     1.5 m 线（mc_obs_lut 的 O_row_min）以上（不判断）= 暗灰 (y, y, y)。y = 亮度 / 2。
//   叠加：红框（障碍，2 像素宽）> 黄框（地面参考区，1 像素宽）> 画面。
//     框表按扇区（每 10 格一个）存：这一格所在扇区如果有框，就看这一格是不是在框的边上。
//   建议方向：画面上方 v = V0−10 ~ V0−3 一条绿条，盖住选中方向 b 两边的扇区（b−1 和 b，方向在绿条正中）；要停的时候不画。
//
//   写入（像素时钟域）：I_wbus = {写使能, 缓冲块, 选择, 地址[13:0], 数据[7:0]}（见 mc_obs_core）。
//     两块缓冲：画面 RAM 2 × 16384 × 8、框表 4 张 2 × 16 × 8。
//   缓冲块切换：每帧开头（I_vsync 上升沿）锁存写端发布的块（I_pub_bank，同步过来）；O_disp_bank 告诉写端。
//   建议方向是 6 位：两级同步后连续两拍相同才锁存（正好赶上它变的那一拍就沿用上一帧的）。
//   还没发布过（I_pub_valid = 0）：整块区域黑色。
//   流水：输入是 mc_mixer 第 1 拍的画布坐标，O_hit / O_rgb 在第 5 拍（和文字层一样晚 4 拍）。
// =============================================================================
module mc_obs_view #(
    parameter [10:0] V0      = 11'd830, // 画面左上角 v（u = 0）
    parameter [7:0]  REF_X0  = 8'd56,
    parameter [7:0]  REF_X1  = 8'd103,
    parameter [6:0]  REF_Y0  = 7'd82,
    parameter [6:0]  REF_Y1  = 7'd89
)(
    input  wire        I_clk,
    input  wire        I_vsync,
    input  wire [10:0] I_u,             // 第 1 拍的画布坐标
    input  wire [10:0] I_v,

    output reg         O_hit,           // 第 5 拍：这个像素归本层管
    output reg  [23:0] O_rgb,

    input  wire        I_wclk,
    input  wire [24:0] I_wbus,
    input  wire        I_pub_bank,      // 写端时钟域（内部同步）
    input  wire        I_pub_valid,
    input  wire [5:0]  I_go,            // {有效, 停, 方向[3:0]}，跟着发布变
    output reg         O_disp_bank
);

// ---------------------------------------------------------------------------
// 写端（像素时钟域）
// ---------------------------------------------------------------------------
reg [7:0] S_img [0:32767];              // {块, 地址[13:0]}
reg [7:0] S_bx0 [0:31];                 // 框表 4 个字节分开存：{块, 扇区}
reg [7:0] S_bx1 [0:31];
reg [7:0] S_bx2 [0:31];
reg [7:0] S_bx3 [0:31];

wire        W_we   = I_wbus[24];
wire        W_bank = I_wbus[23];
wire        W_sel  = I_wbus[22];
wire [13:0] W_addr = I_wbus[21:8];
wire [7:0]  W_data = I_wbus[7:0];

always @(posedge I_wclk) begin
    if (W_we && !W_sel) S_img[{W_bank, W_addr}] <= W_data;
    if (W_we && W_sel && W_addr[1:0] == 2'd0) S_bx0[{W_bank, W_addr[5:2]}] <= W_data;
    if (W_we && W_sel && W_addr[1:0] == 2'd1) S_bx1[{W_bank, W_addr[5:2]}] <= W_data;
    if (W_we && W_sel && W_addr[1:0] == 2'd2) S_bx2[{W_bank, W_addr[5:2]}] <= W_data;
    if (W_we && W_sel && W_addr[1:0] == 2'd3) S_bx3[{W_bank, W_addr[5:2]}] <= W_data;
end

// ---------------------------------------------------------------------------
// 读端（显示时钟域）：每帧开头锁存块号、建议方向
// ---------------------------------------------------------------------------
wire       S_pub, S_pvalid;
wire [5:0] S_go_s;
mc_sync_bits #(.W(8)) u_sync (.I_clk (I_clk), .I_d ({I_pub_bank, I_pub_valid, I_go}), .O_q ({S_pub, S_pvalid, S_go_s}));

reg       S_vs_d;
reg       S_valid;
reg [5:0] S_go, S_go_d;
initial begin O_disp_bank = 1'b0; S_valid = 1'b0; S_go = 6'd0; S_go_d = 6'd0; S_vs_d = 1'b0; end
always @(posedge I_clk) begin
    S_vs_d <= I_vsync;
    S_go_d <= S_go_s;
    if (I_vsync && !S_vs_d) begin
        O_disp_bank <= S_pub;
        S_valid     <= S_pvalid;
        if (S_go_s == S_go_d) S_go <= S_go_s;
    end
end

// 第 2 拍：格坐标（÷5 用 ×205 >> 10，0~1023 范围内精确）、格内偏移、区域判断
function [20:0] m205;                   // x × 205（移位相加，不用 DSP）
    input [10:0] x;
    m205 = {3'd0, x, 7'd0} + {4'd0, x, 6'd0} + {7'd0, x, 3'd0} + {8'd0, x, 2'd0} + {10'd0, x};
endfunction
wire [10:0] S_dv  = I_v - V0;
wire [20:0] S_cx_m = m205(I_u);
wire [20:0] S_cy_m = m205(S_dv);
wire [7:0]  S_cx0  = S_cx_m[17:10];
wire [6:0]  S_cy0  = S_cy_m[16:10];
wire [10:0] S_sx0  = I_u  - ({1'b0, S_cx0, 2'b00} + {3'd0, S_cx0});      // u − 5·cx = 0~4
wire [10:0] S_sy0  = S_dv - ({2'b0, S_cy0, 2'b00} + {4'd0, S_cy0});

reg        S2_area, S2_bar;
reg [7:0]  S2_cx;
reg [6:0]  S2_cy;
reg [2:0]  S2_sx, S2_sy;
always @(posedge I_clk) begin
    S2_area <= (I_v >= V0) && (I_v < V0 + 11'd450) && (I_u < 11'd800);
    S2_bar  <= (I_v >= V0 - 11'd10) && (I_v < V0 - 11'd2) && (I_u < 11'd800);
    S2_cx   <= S_cx0;
    S2_cy   <= S_cy0;
    S2_sx   <= S_sx0[2:0];
    S2_sy   <= S_sy0[2:0];
end

// 第 3 拍：读画面和框表
wire [13:0] S_iaddr = {S2_cy, 7'd0} + {2'd0, S2_cy, 5'd0} + {6'd0, S2_cx};
wire [20:0] S_sec_m = m205({3'd0, S2_cx});                                 // 扇区 = 格 / 10 = 格 × 205 >> 11（0~159 精确）
wire [3:0]  S2_sec  = S_sec_m[14:11];

reg [7:0] S3_pix, S3_b0, S3_b1, S3_b2, S3_b3;
reg       S3_area, S3_bar;
reg [7:0] S3_cx;
reg [6:0] S3_cy;
reg [2:0] S3_sx, S3_sy;
reg [3:0] S3_sec;
always @(posedge I_clk) begin
    S3_pix <= S_img[{O_disp_bank, S_iaddr}];
    S3_b0  <= S_bx0[{O_disp_bank, S2_sec}];
    S3_b1  <= S_bx1[{O_disp_bank, S2_sec}];
    S3_b2  <= S_bx2[{O_disp_bank, S2_sec}];
    S3_b3  <= S_bx3[{O_disp_bank, S2_sec}];
    S3_area <= S2_area; S3_bar <= S2_bar;
    S3_cx <= S2_cx; S3_cy <= S2_cy; S3_sx <= S2_sx; S3_sy <= S2_sy; S3_sec <= S2_sec;
end

// 1.5 m 线（mc_obs_lut 生成，和扫描用的同一个数）：这一行以上画暗灰
wire [6:0] S_row_min;
mc_obs_lut u_lut (.I_row (7'd0), .O_dist (), .I_sec (4'd0), .O_sec_deg (), .I_head (4'd0), .O_head_deg (), .I_tb (4'd0), .I_tj (4'd0), .O_thr (),
                  .O_row_min (S_row_min));

// 第 4 拍：上色、叠加
wire [6:0] S_y   = S3_pix[7:1];
wire       S_obs = S3_pix[0];
wire       S_bv  = S3_b0[7];
wire [6:0] S_bt  = S3_b0[6:0];
wire [6:0] S_bb  = S3_b1[6:0];
wire       S_inbox = S_bv && (S3_cx >= S3_b2) && (S3_cx <= S3_b3) && (S3_cy >= S_bt) && (S3_cy <= S_bb);
wire       S_boxedge = S_inbox && (((S3_cx == S3_b2) && (S3_sx < 3'd2)) || ((S3_cx == S3_b3) && (S3_sx >= 3'd3)) ||
                                   ((S3_cy == S_bt) && (S3_sy < 3'd2)) || ((S3_cy == S_bb) && (S3_sy >= 3'd3)));
wire       S_inref = (S3_cx >= REF_X0) && (S3_cx <= REF_X1) && (S3_cy >= REF_Y0) && (S3_cy <= REF_Y1);
wire       S_refedge = S_inref && (((S3_cx == REF_X0) && (S3_sx == 3'd0)) || ((S3_cx == REF_X1) && (S3_sx == 3'd4)) ||
                                   ((S3_cy == REF_Y0) && (S3_sy == 3'd0)) || ((S3_cy == REF_Y1) && (S3_sy == 3'd4)));
wire       S_gobar = S3_bar && S_go[5] && !S_go[4] && ((S3_sec == S_go[3:0] - 4'd1) || (S3_sec == S_go[3:0]));

reg [23:0] S4_rgb;
reg        S4_hit;
always @(posedge I_clk) begin
    S4_hit <= S3_area | S3_bar;
    if (!S_valid)                    S4_rgb <= 24'h000000;
    else if (S3_bar)                 S4_rgb <= S_gobar ? 24'h00FF00 : 24'h000000;
    else if (S_boxedge)              S4_rgb <= 24'hFF0000;
    else if (S_refedge)              S4_rgb <= 24'hFFDC00;
    else if (S3_cy < S_row_min)      S4_rgb <= {1'b0, S_y, 1'b0, S_y, 1'b0, S_y};
    else if (S_obs)                  S4_rgb <= {{1'b0, S_y} + 8'd64, {1'b0, S_y} + 8'd32, {1'b0, S_y} + 8'd128};
    else                             S4_rgb <= {1'b0, S_y, {1'b0, S_y} + 8'd96, 1'b0, S_y};
    O_hit <= S4_hit;
    O_rgb <= S4_rgb;
end

endmodule
