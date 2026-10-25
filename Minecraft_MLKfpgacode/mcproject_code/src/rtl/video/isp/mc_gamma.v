`timescale 1ns / 1ps
// =============================================================================
// mc_gamma.v  取窗之后、去马赛克之前：每个 RAW10 像素查表（减黑电平 + sRGB 伽马），再统计每帧的平均亮度给自动曝光用
//
//   为什么在这里做：传感器给的是线性亮度，直接显示会"亮的特别亮、暗的一片黑"（屏幕本身按 sRGB 伽马显示）。
//   在 RAW10（10 位）上查表，暗部的细节比去马赛克以后在 8 位上做多 2 位精度。
//   输出仍是 4 像素 × 10 位：每个像素 = {查表结果 8 位, 2'b00}（下游 mipi_to_raw_converter 只取高 8 位）。
//   延迟 1 个时钟（tvalid / tuser / tlast 一起延迟）。
//
//   亮度统计（自动曝光 mc_ae 用）：一帧里所有像素（查表以后的 8 位值，超过 STAT_CLIP 的按 STAT_CLIP 算，
//   免得灯这类小亮点把平均值拉高）求和，帧开始（I_tuser）时把上一帧的和右移 STAT_SHIFT 位作为平均亮度 O_mean，
//   并翻转 O_mean_tog。1920×1080 = 2073600 个像素 ≈ 2^21，所以 STAT_SHIFT = 21 时 O_mean ≈ 平均值 × 0.989。
//   Bayer 像素按 R G G B 各占 1/4、1/2、1/4 平均，正好接近亮度。
// =============================================================================
module mc_gamma #(
    parameter       STAT_SHIFT = 21,    // 求平均：和 >> STAT_SHIFT（= 每帧像素数的 log2）
    parameter [7:0] STAT_CLIP  = 8'd200 // 统计时亮于这个值的像素按它算
)(
    input  wire        I_clk,
    input  wire        I_rst_n,

    input  wire [39:0] I_tdata,         // 4 个 RAW10 像素，先到的在 [9:0]（和 raw10_unpacket_4lane 一样）
    input  wire        I_tvalid,
    input  wire        I_tuser,         // 帧开始（窗口里第一拍）
    input  wire        I_tlast,

    output reg  [39:0] O_tdata,
    output reg         O_tvalid,
    output reg         O_tuser,
    output reg         O_tlast,

    output reg  [7:0]  O_mean,          // 上一帧的平均亮度（帧开始时更新）
    output reg         O_mean_tog       // 每更新一次 O_mean 翻转一次（跨时钟域用）
);

// ---- 查表（4 个像素各一份表）----
wire [7:0] S_y0, S_y1, S_y2, S_y3;
mc_gamma_lut u_lut0 (.I_x(I_tdata[ 9: 0]), .O_y(S_y0));
mc_gamma_lut u_lut1 (.I_x(I_tdata[19:10]), .O_y(S_y1));
mc_gamma_lut u_lut2 (.I_x(I_tdata[29:20]), .O_y(S_y2));
mc_gamma_lut u_lut3 (.I_x(I_tdata[39:30]), .O_y(S_y3));

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        O_tdata  <= 40'd0;
        O_tvalid <= 1'b0;
        O_tuser  <= 1'b0;
        O_tlast  <= 1'b0;
    end else begin
        O_tdata  <= I_tvalid ? {S_y3, 2'b00, S_y2, 2'b00, S_y1, 2'b00, S_y0, 2'b00} : 40'd0;
        O_tvalid <= I_tvalid;
        O_tuser  <= I_tuser;
        O_tlast  <= I_tlast;
    end
end

// ---- 亮度统计 ----
function [7:0] clip;
    input [7:0] y;
    clip = (y > STAT_CLIP) ? STAT_CLIP : y;
endfunction

reg  [9:0]  S_sum4;                     // 这一拍 4 个像素（限幅后）的和，晚一拍
reg         S_sum4_v;
reg  [31:0] S_acc;                      // 本帧累加

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        S_sum4   <= 10'd0;
        S_sum4_v <= 1'b0;
    end else begin
        S_sum4   <= {2'b00, clip(S_y0)} + {2'b00, clip(S_y1)} + {2'b00, clip(S_y2)} + {2'b00, clip(S_y3)};
        S_sum4_v <= I_tvalid;
    end
end

// 帧开始那一拍：交出上一帧的和（含上一拍还没加进去的那 4 个像素）、清零；
// 这一拍自己的 4 个像素晚一拍（S_sum4_v）才加进来，不会丢
wire [31:0] S_acc_now = S_acc + (S_sum4_v ? {22'd0, S_sum4} : 32'd0);
wire [31:0] S_avg     = S_acc_now >> STAT_SHIFT;

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        S_acc      <= 32'd0;
        O_mean     <= 8'd0;
        O_mean_tog <= 1'b0;
    end else if (I_tuser) begin
        S_acc      <= 32'd0;
        O_mean     <= (|S_avg[31:8]) ? 8'd255 : S_avg[7:0];
        O_mean_tog <= ~O_mean_tog;
    end else begin
        S_acc      <= S_acc_now;
    end
end

endmodule
