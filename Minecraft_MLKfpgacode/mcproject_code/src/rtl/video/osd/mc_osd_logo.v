`timescale 1ns / 1ps
// =============================================================================
// mc_osd_logo.v  屏幕上的安路 Logo 层（像素时钟域）
//   480×128 的白底横幅（安路标志 + "安路科技" + "ANLOGIC"，位图在 mc_logo_rom.v，由 tools/gen_logo.ps1 生成），
//   左上角放在画布的 (U0, V0)，不缩放。每个像素 2 位颜色号，查调色板 C0~C3 得到 RGB。
//   输入是画布坐标（和文字层一样），输出晚 4 拍：
//     第 1 拍：在不在框里、ROM 地址（行 × 60 + 列 / 8，乘 60 写成 ×64 − ×4，不用乘法器）
//     第 2 拍：ROM 给出这一组 8 个像素 → 第 3 拍：取这个像素的 2 位、查调色板 → 第 4 拍：输出寄存
// =============================================================================
module mc_osd_logo #(
    parameter U0 = 160,                     // 左上角（画布坐标）
    parameter V0 = 678,
    parameter [23:0] C0 = 24'hFFFFFF,       // 调色板：0 白（底）
    parameter [23:0] C1 = 24'h1E2D5A,       //         1 深蓝（标志的 "A"、文字）
    parameter [23:0] C2 = 24'hDC232D,       //         2 红（标志的横条）
    parameter [23:0] C3 = 24'h969EB6        //         3 深蓝和白之间的过渡色（边缘）
)(
    input  wire        I_clk,
    input  wire [10:0] I_u,
    input  wire [10:0] I_v,
    output reg         O_hit,               // 这个像素在 Logo 框里（晚 4 拍）
    output reg  [23:0] O_rgb
);

localparam W = 480;
localparam H = 128;

// ---- 第 1 拍：框内判断、ROM 地址 ----
wire [10:0] S_du = I_u - U0;
wire [10:0] S_dv = I_v - V0;
wire        S_in = (I_u >= U0) && (I_u < U0 + W) && (I_v >= V0) && (I_v < V0 + H);

reg         S_in1;
reg  [2:0]  S_px1;                          // 这个像素在 8 个一组里的第几个
reg  [12:0] S_addr1;

always @(posedge I_clk) begin
    S_in1   <= S_in;
    S_px1   <= S_du[2:0];
    S_addr1 <= {S_dv[6:0], 6'd0} - {4'd0, S_dv[6:0], 2'd0} + {7'd0, S_du[8:3]};
end

// ---- 第 2 拍：ROM 输出 ----
wire [15:0] S_word;
mc_logo_rom u_rom (.I_clk (I_clk), .I_addr (S_addr1), .O_data (S_word));

reg        S_in2;
reg  [2:0] S_px2;
always @(posedge I_clk) begin
    S_in2 <= S_in1;
    S_px2 <= S_px1;
end

// ---- 第 3 拍：取颜色号、查调色板 ----
wire [1:0] S_ci = S_word[{S_px2, 1'b0} +: 2];

reg        S_in3;
reg [23:0] S_rgb3;
always @(posedge I_clk) begin
    S_in3  <= S_in2;
    S_rgb3 <= (S_ci == 2'd0) ? C0 : (S_ci == 2'd1) ? C1 : (S_ci == 2'd2) ? C2 : C3;
end

// ---- 第 4 拍：输出 ----
always @(posedge I_clk) begin
    O_hit <= S_in3;
    O_rgb <= S_rgb3;
end

endmodule
