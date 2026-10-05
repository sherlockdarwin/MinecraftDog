`timescale 1ns / 1ps
// 仿真用替身：代替 mc_cam_if（里面是 MIPI 硬核和厂商加密模块，仿真不了）。
// 只保留和 mctop 有关的行为：I_key_n[0] 下降沿 O_ae +1，I_key_n[1] 下降沿 O_ae -1（模拟 ae_set），其余输出给常数。
module mc_cam_if #(
    parameter [3:0] LANE_INVERT = 4'b0000,
    parameter       CROP_X0_GRP = 141,
    parameter       CROP_W_GRP  = 200,
    parameter       CROP_Y0     = 317,
    parameter       CROP_H      = 448,
    parameter       IMG_W       = 800,
    parameter       IMG_H       = 448
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
    output wire         O_cfg_done,
    output wire [7:0]   O_ae,
    output wire [3:0]   O_lane_error,
    output reg          O_csi_frame_tog,
    output reg          O_isp_frame_tog
);
reg [7:0] ae = 8'd50;
reg [1:0] key_d = 2'b11;
always @(posedge I_clk_24m) begin
    key_d <= I_key_n;
    if (key_d[0] && !I_key_n[0]) ae <= ae + 8'd1;
    if (key_d[1] && !I_key_n[1]) ae <= ae - 8'd1;
end
initial begin O_csi_frame_tog = 0; O_isp_frame_tog = 0; end
always @(posedge I_clk_100m) begin O_csi_frame_tog <= ~O_csi_frame_tog; O_isp_frame_tog <= ~O_isp_frame_tog; end
assign O_ae = ae;
assign O_cam_scl = 1'b1;
assign O_cam_clk = I_clk_24m;
assign O_cam_rst = 1'b1;
assign O_pix_clk = I_clk_100m;
assign O_pix_frame_start = 1'b0;
assign O_pix_valid = 1'b0;
assign O_pix_data = 128'd0;
assign O_cfg_done = 1'b1;
assign O_lane_error = 4'd0;
endmodule
