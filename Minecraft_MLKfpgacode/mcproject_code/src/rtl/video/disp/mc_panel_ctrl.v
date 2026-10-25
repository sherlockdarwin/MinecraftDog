`timescale 1ns / 1ps
// =============================================================================
// mc_panel_ctrl.v  屏幕上电时序（10 MHz 时钟域）：复位脉冲 → 等待 → 允许 ROM 开始发初始化命令 → 开背光
//
//   I_rst_n 释放（MIPI TX 的 DPLL 锁定，数据线已处于 LP-11 空闲态）
//     0 ~ RST_LOW_MS      O_panel_rst_n = 0   面板复位（DSI_RES，经 TXS0108E 转 1.8V）
//     RST_LOW_MS ~        O_panel_rst_n = 1   释放复位
//     + WAIT_MS           O_config_start = 1  让 display_config_wrapper 发初始化脚本（ROM）
//     I_config_done = 1   O_backlight = 1     初始化完成后才点亮背光，避免上电白屏闪烁
// ILI9881C 数据手册要求复位释放后至少等 ~120 ms 才能发 DCS 命令，这里留 150 ms。
// =============================================================================
module mc_panel_ctrl #(
    parameter CLK_HZ      = 10_000_000,
    parameter RST_LOW_MS  = 20,
    parameter WAIT_MS     = 150
)(
    input  wire I_clk,              // 10 MHz
    input  wire I_rst_n,            // 异步复位，低有效
    input  wire I_config_done,      // display_config_wrapper 初始化脚本跑完

    output reg  O_panel_rst_n,
    output reg  O_config_start,
    output reg  O_backlight
);

localparam [21:0] T_RST   = (CLK_HZ / 1000) * RST_LOW_MS;
localparam [21:0] T_START = (CLK_HZ / 1000) * (RST_LOW_MS + WAIT_MS);

reg [21:0] S_cnt;

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        S_cnt          <= 22'd0;
        O_panel_rst_n  <= 1'b0;
        O_config_start <= 1'b0;
        O_backlight    <= 1'b0;
    end else begin
        if (S_cnt != 22'h3FFFFF)
            S_cnt <= S_cnt + 22'd1;
        if (S_cnt == T_RST)   O_panel_rst_n  <= 1'b1;
        if (S_cnt == T_START) O_config_start <= 1'b1;
        O_backlight <= I_config_done;
    end
end

endmodule
