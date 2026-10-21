`timescale 1ns / 1ps
// 仿真用替身：代替 mc_cam_if（里面是 MIPI 硬核和厂商加密模块，仿真不了）。
// 只保留和 mctop 有关的行为：I_key_n[0] 下降沿亮度档 +1、I_key_n[1] 下降沿 −1（0~8，模拟 mc_ae），
// 增益 / 曝光给和真实默认值不同的"诱饵"常数（61 / 1717，接错了在屏幕文字上看得出来），其余输出给常数。
// 参数的默认值也故意和 mctop 配置区的值不同（顶层没把参数传下来时 tb_top 能发现）。
// 像素时钟是独立的 111 MHz（和 100 MHz 不同：避障 / 帧缓存的时钟接成 100 MHz 在 tb_top 里看得出来）。
module mc_cam_if #(
    parameter [3:0] LANE_INVERT = 4'b0000,
    parameter       CROP_X0_GRP = 9,
    parameter       CROP_Y0     = 99,
    parameter       OUT_H       = 99
)(
    input  wire         I_rst_n,
    input  wire         I_clk_100m,
    input  wire         I_clk_24m,
    input  wire [1:0]   I_key_n,
    output wire         O_cam_scl,
    inout  wire         IO_cam_sda,
    output wire         O_cam_clk,
    output wire         O_cam_rst,
    inout  wire         IO_rx_clk_pad_n,
    inout  wire         IO_rx_clk_pad_p,
    inout  wire [3:0]   IO_rx_data_pad_n,
    inout  wire [3:0]   IO_rx_data_pad_p,
    output wire         O_pix_clk,
    output wire         O_pix_frame_start,
    output wire         O_pix_valid,
    output wire [127:0] O_pix_data,
    output wire         O_isp_fs,
    output wire         O_isp_valid,
    output wire [95:0]  O_isp_data,
    output wire         O_cfg_done,
    output wire [7:0]   O_ae_gain,
    output wire [11:0]  O_ae_exp,
    output wire [3:0]   O_ae_ev,
    output wire [3:0]   O_lane_error,
    output reg          O_csi_frame_tog,
    output reg          O_isp_frame_tog
);
reg [3:0] ev = 4'd4;
reg [1:0] key_d = 2'b11;
always @(posedge I_clk_24m) begin
    key_d <= I_key_n;
    if (key_d[0] && !I_key_n[0] && ev != 4'd8) ev <= ev + 4'd1;
    if (key_d[1] && !I_key_n[1] && ev != 4'd0) ev <= ev - 4'd1;
end
initial begin O_csi_frame_tog = 0; O_isp_frame_tog = 0; end
always @(posedge I_clk_100m) begin O_csi_frame_tog <= ~O_csi_frame_tog; O_isp_frame_tog <= ~O_isp_frame_tog; end
assign O_ae_gain = 8'd61;
assign O_ae_exp  = 12'd1717;
assign O_ae_ev   = ev;
assign O_cam_scl = 1'b1;
assign O_cam_clk = I_clk_24m;
assign O_cam_rst = 1'b1;
reg pclk = 1'b0;
always #4.49 pclk = ~pclk;
assign O_pix_clk = pclk;
assign O_pix_frame_start = 1'b0;
assign O_pix_valid = 1'b0;
assign O_pix_data = 128'd0;
assign O_isp_fs = 1'b0;
assign O_isp_valid = 1'b0;
assign O_isp_data = 96'd0;
assign O_cfg_done = 1'b1;
assign O_lane_error = 4'd0;
endmodule
