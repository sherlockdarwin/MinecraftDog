`timescale 1ns / 1ps
// 仿真用替身：代替 mc_disp_if（MIPI DSI 硬核 + 加密打包模块，仿真不了）。
// 只保留文字层（真的 mc_osd_text），这样可以在顶层仿真里直接读字符 RAM，核对屏幕上会显示什么。
// 版面参数的默认值故意写成和配置区不一样的"诱饵"：顶层漏接哪个参数，tb_top 的参数核对就能看出来。
module mc_disp_if #(
    parameter H_ACTIVE = 800, parameter HSA = 24, parameter HBP = 136, parameter HFP = 160,
    parameter V_ACTIVE = 1280, parameter VSA = 6, parameter VBP = 15, parameter VFP = 16,
    parameter IMG_W = 1, parameter IMG_H = 1, parameter SQ_V0 = 1, parameter SQ_H = 1,
    parameter [3:0] TPG_MODE = 4'd9, parameter BG_PATTERN = 0, parameter RB_SWAP = 0,
    parameter TXT_U0 = 1, parameter TXT_V0 = 1, parameter TXT_COLS = 45, parameter TXT_ROWS = 1, parameter TXT_SH = 1,
    parameter DPLL_MULTI_RATIO = 20
)(
    input  wire         I_rst_n,
    input  wire         I_clk_dpll_ref,
    input  wire         I_clk_lp,
    output wire         O_dsi_clk,
    output wire         O_vsync,
    output wire         O_rd_en,
    input  wire [23:0]  I_rd_data,
    input  wire         I_win_en,
    input  wire [7:0]   I_status,
    output wire         O_panel_ready,
    input  wire         I_txt_clk,
    input  wire [19:0]  I_txt_bus,
    output wire         O_dsi_pwm,
    output wire         O_dsi_rst_n,
    inout  wire         IO_tx_clk_pad_n,
    inout  wire         IO_tx_clk_pad_p,
    inout  wire [3:0]   IO_tx_data_pad_n,
    inout  wire [3:0]   IO_tx_data_pad_p
);
assign O_dsi_clk = I_clk_dpll_ref;
assign O_vsync = 1'b0;
assign O_rd_en = 1'b0;
assign O_panel_ready = 1'b1;
assign O_dsi_pwm = 1'b1;
assign O_dsi_rst_n = 1'b1;

mc_osd_text #(.X0(TXT_U0), .Y0(TXT_V0), .COLS(TXT_COLS), .ROWS(TXT_ROWS), .SCALE_SH(TXT_SH)) u_osd (
    .I_pclk(I_clk_dpll_ref), .I_x(11'd0), .I_y(11'd0), .O_hit(), .O_on(),
    .I_wclk(I_txt_clk), .I_wbus(I_txt_bus)
);
endmodule
