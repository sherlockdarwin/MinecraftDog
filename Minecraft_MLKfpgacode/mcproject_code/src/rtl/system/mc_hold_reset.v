`timescale 1ns / 1ps
// =============================================================================
// mc_hold_reset.v  长按复位：按键持续按下 HOLD_MS 毫秒 → 输出一个 PULSE_MS 毫秒宽的复位脉冲
//
// 为什么要它：SW1 原来直接当整机复位键。现在 SW1 要和 SW2/SW3 一起当普通按键（短按/长按），
//             所以改成"按住 2 秒 = 复位整机"，复位功能还在，按键也能用。
// 为什么跑在晶振时钟上：它的输出接 PLL 的 reset。PLL 被复位时 PLL 输出时钟会停，
//             如果这个模块也用 PLL 时钟，复位脉冲就永远结束不了。晶振时钟一直在，没这个问题。
// 没有复位端口：上电后寄存器用声明时的初值（FPGA 配置完成时就是这个值）。
// =============================================================================
module mc_hold_reset #(
    parameter CLK_HZ   = 25_000_000,    // I_clk 频率
    parameter HOLD_MS  = 2000,          // 按住多久触发复位；0 = 关闭这个功能（O_rst 恒为 0）
    parameter PULSE_MS = 2              // 复位脉冲宽度（毫秒）
)(
    input  wire I_clk,
    input  wire I_key_n,                // 按键原始电平，低有效（异步输入，内部同步）
    output reg  O_rst                   // 高有效复位脉冲 → 接 PLL 的 reset
);

localparam MS_DIV = CLK_HZ / 1000;      // 每毫秒多少个时钟

reg  [1:0]  S_key_sync = 2'b11;
reg  [15:0] S_div      = 16'd0;         // 毫秒分频
reg  [15:0] S_hold     = 16'd0;         // 已按住的毫秒数
reg  [7:0]  S_pulse    = 8'd0;          // 复位脉冲剩余毫秒数
reg         S_fired    = 1'b0;          // 已触发过，等松手后才能再次触发

initial O_rst = 1'b0;

wire S_ms_tick = (S_div == MS_DIV - 1);
wire S_pressed = ~S_key_sync[1];

always @(posedge I_clk) begin
    S_key_sync <= {S_key_sync[0], I_key_n};

    if (S_ms_tick) S_div <= 16'd0;
    else           S_div <= S_div + 16'd1;

    if (HOLD_MS != 0) begin
        if (!S_pressed) begin
            S_hold  <= 16'd0;
            S_fired <= 1'b0;
        end else if (S_ms_tick && !S_fired) begin
            if (S_hold == HOLD_MS - 1) begin
                S_fired <= 1'b1;
                S_pulse <= PULSE_MS;
                O_rst   <= 1'b1;
            end else begin
                S_hold <= S_hold + 16'd1;
            end
        end

        if (O_rst && S_ms_tick) begin
            if (S_pulse == 8'd1) begin
                O_rst   <= 1'b0;
                S_pulse <= 8'd0;
            end else begin
                S_pulse <= S_pulse - 8'd1;
            end
        end
    end
end

endmodule
