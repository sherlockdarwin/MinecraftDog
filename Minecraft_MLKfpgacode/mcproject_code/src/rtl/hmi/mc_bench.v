`timescale 1ns / 1ps
// =============================================================================
// mc_bench.v  台架按键：SW2 / SW3 短按 → 相机亮度档 +1 / -1（自动曝光的目标亮度；只有这一个功能，没有翻页）
//
// 按键（SW1/SW2/SW3 = KEY1/KEY2/KEY3）：
//   SW2 短按  亮一档（EV +1）         SW3 短按  暗一档（EV -1）
//   SW1 按住 2 秒  整机复位（在顶层 mc_hold_reset，不经过这里）。SW1 短按 / 各键长按没有功能。
//
// 亮度档在相机模块的自动曝光 mc_ae 里（24 MHz 时钟域）。这里把短按变成一个 40 ms 的低电平脉冲
// （O_cam_key_n，低有效），宽脉冲跨时钟域不会丢。
// =============================================================================
module mc_bench (
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_tick_10ms,         // 10 ms 节拍（用来拉宽亮度键脉冲）

    input  wire [2:0]  I_key_short,         // 来自 mc_key 的短按脉冲，bit0 = SW1

    output wire [1:0]  O_cam_key_n          // 亮度键（低有效脉冲）：[0] 亮一档，[1] 暗一档
);

// ---- SW2/SW3 短按 → 40 ms 低电平脉冲（4 个 10 ms 节拍）----
reg [2:0] S_gain_cnt0, S_gain_cnt1;
assign O_cam_key_n = {(S_gain_cnt1 == 3'd0), (S_gain_cnt0 == 3'd0)};

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        S_gain_cnt0 <= 3'd0;
        S_gain_cnt1 <= 3'd0;
    end else begin
        if (I_key_short[1])                            S_gain_cnt0 <= 3'd4;
        else if (I_tick_10ms && S_gain_cnt0 != 3'd0)   S_gain_cnt0 <= S_gain_cnt0 - 3'd1;

        if (I_key_short[2])                            S_gain_cnt1 <= 3'd4;
        else if (I_tick_10ms && S_gain_cnt1 != 3'd0)   S_gain_cnt1 <= S_gain_cnt1 - 3'd1;
    end
end

endmodule
