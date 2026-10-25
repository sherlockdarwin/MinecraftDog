`timescale 1ns / 1ps
// =============================================================================
// mc_cam_pwrup.v  摄像头上电时序（24 MHz 时钟域）
// IMX415 要求：INCK(24MHz) 稳定之后才能释放复位，复位释放约 1 ms 之后才能访问 I2C。
//   I_rst_n 释放(PLL 锁定，24MHz 开始输出)
//     ├─ 10 ms 后 O_cam_rst_n = 1   释放传感器复位
//     └─ 40 ms 后 O_cfg_rst_n = 1   才允许 I2C 配置模块开始工作
// =============================================================================
module mc_cam_pwrup #(
    parameter CLK_HZ       = 24_000_000,
    parameter RST_HOLD_MS  = 10,
    parameter CFG_DELAY_MS = 40
)(
    input  wire I_clk,          // 24 MHz
    input  wire I_rst_n,        // 异步复位，低有效（接 PLL lock）
    output reg  O_cam_rst_n,
    output reg  O_cfg_rst_n
);

localparam [21:0] T_RST = (CLK_HZ / 1000) * RST_HOLD_MS;
localparam [21:0] T_CFG = (CLK_HZ / 1000) * CFG_DELAY_MS;

reg [21:0] S_cnt;

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        S_cnt       <= 22'd0;
        O_cam_rst_n <= 1'b0;
        O_cfg_rst_n <= 1'b0;
    end else begin
        if (S_cnt != 22'h3FFFFF)
            S_cnt <= S_cnt + 22'd1;
        if (S_cnt == T_RST) O_cam_rst_n <= 1'b1;
        if (S_cnt == T_CFG) O_cfg_rst_n <= 1'b1;
    end
end

endmodule
