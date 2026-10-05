`timescale 1ns / 1ps
// =============================================================================
// mc_bench.v  台架按键：SW2 / SW3 短按 → 相机增益 +1 / -1（只有这一个功能，没有翻页）
//   ★ 调试用的"遥控器"，以后状态机直接产生相机增益键脉冲时把它拿掉即可。
//
// 按键（SW1/SW2/SW3 = KEY1/KEY2/KEY3）：
//   SW2 短按  相机增益 +1 级          SW3 短按  相机增益 -1 级
//   SW1 按住 2 秒  整机复位（在顶层 mc_hold_reset，不经过这里）。SW1 短按 / 各键长按没有功能。
//
// 相机增益：增益值在相机模块 ae_set 里，它要的是"按键"。这里把短按变成一个 40 ms 的低电平脉冲
// （O_cam_key_n，低有效，和真按键一样）送给它。
// =============================================================================
module mc_bench (
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_tick_10ms,         // 10 ms 节拍（用来拉宽相机增益脉冲）

    input  wire [2:0]  I_key_short,         // 来自 mc_key 的短按脉冲，bit0 = SW1

    output wire [1:0]  O_cam_key_n          // 相机增益键（低有效脉冲）：[0] 增益 +，[1] 增益 -
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
