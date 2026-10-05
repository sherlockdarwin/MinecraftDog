`timescale 1ns / 1ps
// =============================================================================
// mc_rst_sync.v  复位同步器：异步复位、同步释放
// 每个时钟域例化一份，防止复位释放沿落在时钟沿附近导致各触发器退出复位的时刻不一致。
// =============================================================================
module mc_rst_sync #(
    parameter STAGES = 4                // 同步级数，>= 2
)(
    input  wire I_clk,
    input  wire I_arst_n,               // 异步复位源（如 PLL lock），低有效
    output wire O_rst_n                 // 同步到 I_clk 的复位，低有效
);

reg [STAGES-1:0] S_sync;

always @(posedge I_clk or negedge I_arst_n) begin
    if (!I_arst_n)
        S_sync <= {STAGES{1'b0}};
    else
        S_sync <= {S_sync[STAGES-2:0], 1'b1};
end

assign O_rst_n = S_sync[STAGES-1];

endmodule
