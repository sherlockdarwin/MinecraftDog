`timescale 1ns / 1ps
// 仿真用替身：代替 mc_framebuf（DDR2 控制器是厂商加密模块，仿真不了；真实的帧缓存由 tb_fb 单独测）。
module mc_framebuf (
    input  wire         I_rst_n,
    input  wire         I_clk_sys,
    input  wire         I_cam_clk,
    input  wire         I_cam_frame_start,
    input  wire         I_cam_valid,
    input  wire [127:0] I_cam_data,
    input  wire         I_dsi_clk,
    input  wire         I_dsi_vsync,
    input  wire         I_dsi_rd_en,
    output wire [23:0]  O_dsi_data,
    output wire         O_ddr_ready,
    output wire [12:0]  ddr_addr,
    output wire [1:0]   ddr_ba,
    output wire [0:0]   ddr_cke,
    output wire [0:0]   ddr_odt,
    output wire [0:0]   ddr_cs_n,
    output wire         ddr_ras_n,
    output wire         ddr_cas_n,
    output wire         ddr_we_n,
    output wire [0:0]   ddr_ck_p,
    output wire [0:0]   ddr_ck_n,
    inout  wire [1:0]   ddr_dm,
    inout  wire [15:0]  ddr_dq,
    inout  wire [1:0]   ddr_dqs_p,
    inout  wire [1:0]   ddr_dqs_n
);
assign O_dsi_data  = 24'd0;
assign O_ddr_ready = 1'b1;
assign ddr_addr = 13'd0; assign ddr_ba = 2'd0; assign ddr_cke = 1'b0; assign ddr_odt = 1'b0;
assign ddr_cs_n = 1'b1; assign ddr_ras_n = 1'b1; assign ddr_cas_n = 1'b1; assign ddr_we_n = 1'b1;
assign ddr_ck_p = 1'b0; assign ddr_ck_n = 1'b1;
endmodule
