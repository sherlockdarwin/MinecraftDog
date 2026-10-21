`timescale 1ns / 1ps
// =============================================================================
// mc_obs_down.v  避障用的小图：白平衡后的 1920×1080 → 每 12×12 求平均 → 160×90（和 mc_scale 并联，接同一路像素流）
//
//   输入：每拍 4 个像素 {R,G,B}×4（96 位，第一个像素在最高位），每行 IN_W/4 拍；I_fs = 帧开始（比第一拍早）。
//   横向：每 3 拍（12 个像素）把 R、G、B 各加起来；纵向：每列一个累加器（RAM，160 × 3 × 16 位），12 行加完输出一行。
//   输出：平均值 = round(和 / 144) = ((和 + 72) × 116509) >> 24（对 0 ~ 144×255 的和精确等于四舍五入的整数除法）。
//         一个像素一拍有效（O_valid），附带网格行号 O_row（0~89）、列号 O_col（0~159）；输出行在第 12 行的数据到来时逐个出来，
//         两个像素之间至少隔 3 拍（下游 mc_obs_core 依赖这一点）。
// =============================================================================
module mc_obs_down #(
    parameter IN_W = 1920,
    parameter IN_H = 1080
)(
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_fs,
    input  wire        I_valid,
    input  wire [95:0] I_data,

    output reg         O_fs,            // 帧开始（晚 1 拍）
    output reg         O_valid,
    output reg  [6:0]  O_row,
    output reg  [7:0]  O_col,
    output reg  [23:0] O_rgb
);

localparam BPL = IN_W / 4;              // 每行拍数
localparam NG  = IN_W / 12;             // 每行格数

reg [10:0] S_bx;                        // 行内第几拍
reg [1:0]  S_hb;                        // 格内第几拍
reg [7:0]  S_gx;                        // 第几格
reg [3:0]  S_pr;                        // 格内第几行 0~11
reg [6:0]  S_gy;                        // 第几行格
reg [9:0]  S_p0r, S_p0g, S_p0b;        // 格里第 1 拍 4 个像素的和
reg [9:0]  S_p1r, S_p1g, S_p1b;        // 第 2 拍

// ---- 横向：每拍先把 4 个像素加起来（R / G / B 各 10 位），凑够 3 拍再合成 12 个像素的和 ----
function [9:0] b4;                      // 这一拍 4 个像素第 c 个通道（0 = R，1 = G，2 = B）的和
    input [95:0] d;
    input integer c;
    b4 = ({2'd0, d[95-8*c -: 8]} + {2'd0, d[71-8*c -: 8]}) + ({2'd0, d[47-8*c -: 8]} + {2'd0, d[23-8*c -: 8]});
endfunction
wire [9:0] S_b4r = b4(I_data, 0);
wire [9:0] S_b4g = b4(I_data, 1);
wire [9:0] S_b4b = b4(I_data, 2);

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        S_bx <= 11'd0; S_hb <= 2'd0; S_gx <= 8'd0; S_pr <= 4'd0; S_gy <= 7'd0;
        S_p0r <= 10'd0; S_p0g <= 10'd0; S_p0b <= 10'd0; S_p1r <= 10'd0; S_p1g <= 10'd0; S_p1b <= 10'd0;
    end else if (I_fs) begin
        S_bx <= 11'd0; S_hb <= 2'd0; S_gx <= 8'd0; S_pr <= 4'd0; S_gy <= 7'd0;
    end else if (I_valid) begin
        if (S_hb == 2'd0) begin S_p0r <= S_b4r; S_p0g <= S_b4g; S_p0b <= S_b4b; end
        if (S_hb == 2'd1) begin S_p1r <= S_b4r; S_p1g <= S_b4g; S_p1b <= S_b4b; end
        S_hb <= (S_hb == 2'd2) ? 2'd0 : S_hb + 2'd1;
        if (S_hb == 2'd2) S_gx <= (S_gx == NG - 1) ? 8'd0 : S_gx + 8'd1;
        if (S_bx == BPL - 1) begin
            S_bx <= 11'd0;
            S_pr <= (S_pr == 4'd11) ? 4'd0 : S_pr + 4'd1;
            if (S_pr == 4'd11) S_gy <= S_gy + 7'd1;
        end else begin
            S_bx <= S_bx + 11'd1;
        end
    end
end

wire       S_grp = I_valid && !I_fs && (S_hb == 2'd2);

reg [11:0] S_hr, S_hg, S_hbl;
reg        S_h_v;
reg [7:0]  S_h_gx;
reg [3:0]  S_h_pr;
reg [6:0]  S_h_gy;

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        S_h_v <= 1'b0; S_h_gx <= 8'd0; S_h_pr <= 4'd0; S_h_gy <= 7'd0;
        S_hr <= 12'd0; S_hg <= 12'd0; S_hbl <= 12'd0;
    end else begin
        S_h_v <= S_grp;
        if (S_grp) begin
            S_h_gx <= S_gx; S_h_pr <= S_pr; S_h_gy <= S_gy;
            S_hr  <= {2'd0, S_p0r} + {2'd0, S_p1r} + {2'd0, S_b4r};
            S_hg  <= {2'd0, S_p0g} + {2'd0, S_p1g} + {2'd0, S_b4g};
            S_hbl <= {2'd0, S_p0b} + {2'd0, S_p1b} + {2'd0, S_b4b};
        end
    end
end

// ---- 纵向：每格一个累加器。组凑齐那拍给读地址，下一拍出数据（和横向和对齐），再下一拍写回 ----
reg  [47:0] S_mem [0:NG-1];
reg  [47:0] S_rd;
reg         S_w_v;
reg  [7:0]  S_w_addr;
reg  [47:0] S_w_data;

always @(posedge I_clk) begin
    S_rd <= S_mem[S_gx];
    if (S_w_v) S_mem[S_w_addr] <= S_w_data;
end

wire [15:0] S_ar = (S_h_pr == 4'd0) ? 16'd0 : S_rd[47:32];
wire [15:0] S_ag = (S_h_pr == 4'd0) ? 16'd0 : S_rd[31:16];
wire [15:0] S_ab = (S_h_pr == 4'd0) ? 16'd0 : S_rd[15:0];
wire [15:0] S_sr = S_ar + {4'd0, S_hr};
wire [15:0] S_sg = S_ag + {4'd0, S_hg};
wire [15:0] S_sb = S_ab + {4'd0, S_hbl};

// 第 12 行：和 → 平均（乘一个常数，用 DSP）
reg         S_d_v;
reg  [16:0] S_dr, S_dg, S_db;
reg  [6:0]  S_d_row;
reg  [7:0]  S_d_col;

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        S_w_v <= 1'b0; S_w_addr <= 8'd0; S_w_data <= 48'd0;
        S_d_v <= 1'b0; S_dr <= 17'd0; S_dg <= 17'd0; S_db <= 17'd0; S_d_row <= 7'd0; S_d_col <= 8'd0;
    end else begin
        S_w_v <= S_h_v;
        S_d_v <= S_h_v && (S_h_pr == 4'd11);
        if (S_h_v) begin
            S_w_addr <= S_h_gx;
            S_w_data <= {S_sr, S_sg, S_sb};
            S_dr <= {1'b0, S_sr} + 17'd72;
            S_dg <= {1'b0, S_sg} + 17'd72;
            S_db <= {1'b0, S_sb} + 17'd72;
            S_d_row <= S_h_gy;
            S_d_col <= S_h_gx;
        end
    end
end

wire [33:0] S_mr = S_dr * 17'd116509;
wire [33:0] S_mg = S_dg * 17'd116509;
wire [33:0] S_mb = S_db * 17'd116509;

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        O_fs <= 1'b0; O_valid <= 1'b0; O_row <= 7'd0; O_col <= 8'd0; O_rgb <= 24'd0;
    end else begin
        O_fs    <= I_fs;
        O_valid <= S_d_v;
        if (S_d_v) begin
            O_row <= S_d_row;
            O_col <= S_d_col;
            O_rgb <= {S_mr[31:24], S_mg[31:24], S_mb[31:24]};
        end
    end
end

endmodule
