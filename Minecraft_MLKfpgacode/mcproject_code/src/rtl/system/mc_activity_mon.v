`timescale 1ns / 1ps
// =============================================================================
// mc_activity_mon.v  "有没有在动"监测器
// 输入是一个每发生一次事件就翻转一次的电平（已同步到本时钟域）；
// 只要在 TIMEOUT_MS 毫秒内看到过翻转，O_alive 就保持为 1。
// 用途：判断摄像头帧是否持续到来（帧起始事件 → 翻转 → 本模块）。
// =============================================================================
module mc_activity_mon #(
    parameter TIMEOUT_MS = 100
)(
    input  wire I_clk,
    input  wire I_rst_n,
    input  wire I_tick_1ms,     // 来自 mc_tick 的 1 ms 脉冲
    input  wire I_toggle,       // 事件翻转信号（须已同步到 I_clk）
    output reg  O_alive
);

reg        S_t_d;
reg [15:0] S_cnt;

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        S_t_d   <= 1'b0;
        S_cnt   <= 16'd0;
        O_alive <= 1'b0;
    end else begin
        S_t_d <= I_toggle;
        if (I_toggle ^ S_t_d)
            S_cnt <= TIMEOUT_MS;                    // 有事件：重新装填
        else if (I_tick_1ms && S_cnt != 16'd0)
            S_cnt <= S_cnt - 16'd1;                 // 无事件：每毫秒减一
        O_alive <= (S_cnt != 16'd0);
    end
end

endmodule
