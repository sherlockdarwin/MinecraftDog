`timescale 1ns / 1ps
// =============================================================================
// mc_sync_bits.v  两级触发器同步器（跨时钟域的"慢信号/电平信号"）
// 只用于电平型状态位（如 ready、alive、翻转标志），不能用于多比特数据总线。
// =============================================================================
module mc_sync_bits #(
    parameter W = 1
)(
    input  wire         I_clk,      // 目标时钟域
    input  wire [W-1:0] I_d,        // 来自其他时钟域的信号
    output wire [W-1:0] O_q
);

reg [W-1:0] S_s1;
reg [W-1:0] S_s2;

always @(posedge I_clk) begin
    S_s1 <= I_d;
    S_s2 <= S_s1;
end

assign O_q = S_s2;

endmodule
