`timescale 1ns / 1ps
// 仿真用替身：代替 IP 生成的 mcsys_pll（真的 PLL 是硬核，仿真不了）。
// 行为：reset=0 时输出 100/24/52.17/10 MHz，reset 释放 2 us 后 lock 拉高；reset=1 时 lock 立刻拉低。
module mcsys_pll (
    input  wire refclk,
    output reg  clk0_out,
    output reg  clk1_out,
    output reg  clk2_out,
    output reg  clk3_out,
    output reg  lock,
    input  wire reset
);
initial begin clk0_out = 0; clk1_out = 0; clk2_out = 0; clk3_out = 0; lock = 0; end
always #5      clk0_out = ~clk0_out;       // 100 MHz
always #20.833 clk1_out = ~clk1_out;       // 24 MHz
always #9.583  clk2_out = ~clk2_out;       // 52.17 MHz
always #50     clk3_out = ~clk3_out;       // 10 MHz
always @(posedge reset) lock = 1'b0;
always @(negedge reset) begin #2000 if (!reset) lock = 1'b1; end
initial begin #3000 if (!reset) lock = 1'b1; end
endmodule
