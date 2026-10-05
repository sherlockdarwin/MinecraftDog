`timescale 1ns / 1ps
// =============================================================================
// mc_behavior.v  狗的"行为层"：传感器信号 → 尾巴 / 音效命令（以后避障、跟随的状态机也放在这一层）
//
//   现在做的事：
//     · 喂食（I_hall = 1，霍尔传感器检测到磁铁 = 食物靠近）：
//         尾巴摇摆：每摇完一个来回（mc_tail 空闲）就检查一次，还是 1 就再摇一个来回；变成 0 以后把当前这个来回摇完就停；
//         进食音效：播放 EAT_CLIP.wav 一遍。音效正在播放的时候不会被重复触发；音效播完磁铁还在也不重播
//                   （磁铁拿开再靠近才重播）。
//     · 狗叫（I_bark = 1，以后接 UWB：信号丢了 / 离得太远）：播放 BARK_CLIP.wav，I_bark 一直为 1 就循环叫。
//       音效只有一路：喂食音效在播的时候狗叫排队等它播完。
//     · 尾巴还会在 I_near = 1（以后接 UWB：距离 < 5 m）时摇，和喂食一样按"一个来回"为周期。
//     I_bark、I_near 现在在顶层接 0（UWB 还没做）。
//
//   触发规则（防止重复触发）：每种音效有一个"这次已经触发过"的标志，触发时置 1，信号变回 0 时清零；
//   狗叫音效正常播完时标志清掉（信号还在就接着叫）；音效播放出错（没有这个文件等）时标志不会因为播完而清掉，
//   不会反复尝试；TF 卡没准备好时先等着（I_audio_ready）。
//   命令都是单周期脉冲，接 mc_tail 的 I_cmd_wag、mc_audio 的 I_sfx_play / I_sfx_clip。
// =============================================================================
module mc_behavior #(
    parameter [6:0] EAT_CLIP    = 7'd2,         // 进食音效：2.wav
    parameter [6:0] BARK_CLIP   = 7'd3          // 狗叫音效：3.wav
)(
    input  wire        I_clk,
    input  wire        I_rst_n,

    input  wire        I_hall,                  // 1 = 正在喂食（mc_hall 的 O_fed）
    input  wire        I_near,                  // 1 = 主人在 5 m 以内（以后接 UWB）
    input  wire        I_bark,                  // 1 = 该叫了（以后接 UWB）

    input  wire        I_audio_ready,           // mc_audio 的 O_ready
    input  wire        I_sfx_busy,              // mc_audio 的 O_sfx_busy
    input  wire [1:0]  I_sfx_state,             // mc_audio 的 O_sfx_state：3 = 出错
    input  wire        I_tail_busy,             // mc_tail 的 O_busy

    output reg         O_tail_wag,              // → mc_tail 的 I_cmd_wag（单周期脉冲）
    output reg         O_sfx_play,              // → mc_audio 的 I_sfx_play（单周期脉冲）
    output reg  [6:0]  O_sfx_clip               // → mc_audio 的 I_sfx_clip
);

// ---- 尾巴：要摇 且 尾巴空闲 → 给一个脉冲（尾巴收到后下一拍就忙，不会连发）----
wire S_want_wag = I_hall | I_near;

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) O_tail_wag <= 1'b0;
    else          O_tail_wag <= S_want_wag & ~I_tail_busy & ~O_tail_wag;
end

// ---- 音效 ----
reg S_eat_done, S_bark_done;        // 这一次靠近 / 这一次该叫 已经触发过
reg S_last_eat;                     // 上一次触发的是进食音效
reg S_busy_d;

wire S_can = I_audio_ready & ~I_sfx_busy & ~O_sfx_play;

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        O_sfx_play  <= 1'b0;
        O_sfx_clip  <= 7'd0;
        S_eat_done  <= 1'b0;
        S_bark_done <= 1'b0;
        S_last_eat  <= 1'b0;
        S_busy_d    <= 1'b0;
    end else begin
        O_sfx_play <= 1'b0;
        S_busy_d   <= I_sfx_busy;

        // 信号变回 0：下次再来才算新的一次
        if (!I_hall) S_eat_done  <= 1'b0;
        if (!I_bark) S_bark_done <= 1'b0;

        // 狗叫正常播完（不是出错）而信号还在 → 清掉标志，让它再叫一遍
        if (S_busy_d && !I_sfx_busy && I_sfx_state != 2'd3 && !S_last_eat) S_bark_done <= 1'b0;

        if (S_can) begin
            if (I_hall && !S_eat_done) begin
                O_sfx_play <= 1'b1;
                O_sfx_clip <= EAT_CLIP;
                S_eat_done <= 1'b1;
                S_last_eat <= 1'b1;
            end else if (I_bark && !S_bark_done) begin
                O_sfx_play  <= 1'b1;
                O_sfx_clip  <= BARK_CLIP;
                S_bark_done <= 1'b1;
                S_last_eat  <= 1'b0;
            end
        end
    end
end

endmodule
