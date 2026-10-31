`timescale 1ns / 1ps
// =============================================================================
// mc_behavior.v  狗的"行为层"：传感器信号 → 尾巴 / 音效命令（以后避障、跟随的状态机也放在这一层）
//
//   现在做的事：
//     · 喂食（I_hall = 1，霍尔传感器检测到磁铁 = 食物靠近）：
//         尾巴摇摆：每摇完一个来回（mc_tail 空闲）就检查一次，还是 1 就再摇一个来回；变成 0 以后把当前这个来回摇完就停；
//         进食音效：播放 EAT_CLIP.wav 一遍。音效正在播放的时候不会被重复触发；音效播完磁铁还在也不重播
//                   （磁铁拿开再靠近才重播）。
//     · 狗叫：播放 BARK_CLIP.wav，该叫的条件一直在就循环叫。音效只有一路：喂食音效在播的时候狗叫排队等它播完。
//       该叫 = 困住了（I_stuck，mc_follow 转了一圈没找到出口，马上叫）
//            或者 连续 BARK_MS 毫秒：STM32 线是通的（I_uwb_link）并且 收不到 UWB（主人丢了）或者 距离 ≥ BARK_CM（STM32 超过 999 cm 都发 999）。
//            线不通（STM32 没接 / 没开）不叫；UWB 偶尔跳一帧不叫。
//     · 主人在身边也摇尾巴，和喂食一样按"摇一遍"为周期（和 STM32 task.c 的 Task_Tail_OwnerNear 一样）：
//       收得到 UWB、距离 < TAIL_NEAR_CM 一直保持 TAIL_NEAR_MS → 在身边；距离 ≥ TAIL_FAR_CM 或收不到 UWB → 马上不在；中间保持原状（等确认的重新数）。
//
//   触发规则（防止重复触发）：每种音效有一个"这次已经触发过"的标志，触发时置 1，信号变回 0 时清零；
//   狗叫音效正常播完时标志清掉（信号还在就接着叫）；音效播放出错（没有这个文件等）时标志不会因为播完而清掉，
//   不会反复尝试；TF 卡没准备好时先等着（I_audio_ready）。
//   命令都是单周期脉冲，接 mc_tail 的 I_cmd_wag、mc_audio 的 I_sfx_play / I_sfx_clip。
// =============================================================================
module mc_behavior #(
    parameter [6:0] EAT_CLIP    = 7'd2,         // 进食音效：2.wav
    parameter [6:0] BARK_CLIP   = 7'd3,         // 狗叫音效：3.wav
    parameter       BARK_CM     = 999,          // 主人这么远（厘米）就叫
    parameter       BARK_MS     = 1000,         // 太远 / 丢了要连续这么久才叫
    parameter       TAIL_NEAR_CM = 300,         // 主人比这近（厘米）……
    parameter       TAIL_FAR_CM = 320,          // 比这远就不算在身边
    parameter       TAIL_NEAR_MS = 300          // ……保持这么久才算在身边
)(
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_tick_1ms,

    input  wire        I_hall,                  // 1 = 正在喂食（mc_hall 的 O_fed）

    input  wire        I_uwb_link,              // mc_m0_link：STM32 的线是通的
    input  wire        I_uwb_ok,                //   收到了主人位置
    input  wire [9:0]  I_uwb_cm,                //   主人多远
    input  wire        I_stuck,                 // mc_follow：困住了

    input  wire        I_audio_ready,           // mc_audio 的 O_ready
    input  wire        I_sfx_busy,              // mc_audio 的 O_sfx_busy
    input  wire [1:0]  I_sfx_state,             // mc_audio 的 O_sfx_state：3 = 出错
    input  wire        I_tail_busy,             // mc_tail 的 O_busy

    output reg         O_tail_wag,              // → mc_tail 的 I_cmd_wag（单周期脉冲）
    output reg         O_sfx_play,              // → mc_audio 的 I_sfx_play（单周期脉冲）
    output reg  [6:0]  O_sfx_clip               // → mc_audio 的 I_sfx_clip
);

// ---- 主人在不在身边 ----
reg         S_near;
reg  [15:0] S_near_ms;              // 已经比 TAIL_NEAR_CM 近多少毫秒
wire        S_gone   = ~I_uwb_ok | (I_uwb_cm >= TAIL_FAR_CM);
wire        S_closer = ~S_gone & (I_uwb_cm < TAIL_NEAR_CM);
always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)        begin S_near <= 1'b0; S_near_ms <= 16'd0; end
    else if (S_gone)     begin S_near <= 1'b0; S_near_ms <= 16'd0; end
    else if (!S_closer)  S_near_ms <= 16'd0;
    else if (I_tick_1ms && !S_near) begin
        if (S_near_ms == TAIL_NEAR_MS - 1) S_near <= 1'b1;
        else S_near_ms <= S_near_ms + 16'd1;
    end
end

// ---- 尾巴：要摇 且 尾巴空闲 → 给一个脉冲（尾巴收到后下一拍就忙，不会连发）----
wire S_want_wag = I_hall | S_near;

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) O_tail_wag <= 1'b0;
    else          O_tail_wag <= S_want_wag & ~I_tail_busy & ~O_tail_wag;
end

// ---- 该不该叫：困住了马上叫；主人太远 / 丢了要连续 BARK_MS ----
wire        S_far = I_uwb_link & (~I_uwb_ok | (I_uwb_cm >= BARK_CM));
reg  [15:0] S_far_ms;               // 太远 / 丢了已经多少毫秒（到 BARK_MS 不再加）
always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)                                 S_far_ms <= 16'd0;
    else if (!S_far)                              S_far_ms <= 16'd0;
    else if (I_tick_1ms && S_far_ms != BARK_MS)   S_far_ms <= S_far_ms + 16'd1;
end
wire S_bark = I_stuck | (S_far & (S_far_ms == BARK_MS));

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
        if (!S_bark) S_bark_done <= 1'b0;

        // 狗叫正常播完（不是出错）而信号还在 → 清掉标志，让它再叫一遍
        if (S_busy_d && !I_sfx_busy && I_sfx_state != 2'd3 && !S_last_eat) S_bark_done <= 1'b0;

        if (S_can) begin
            if (I_hall && !S_eat_done) begin
                O_sfx_play <= 1'b1;
                O_sfx_clip <= EAT_CLIP;
                S_eat_done <= 1'b1;
                S_last_eat <= 1'b1;
            end else if (S_bark && !S_bark_done) begin
                O_sfx_play  <= 1'b1;
                O_sfx_clip  <= BARK_CLIP;
                S_bark_done <= 1'b1;
                S_last_eat  <= 1'b0;
            end
        end
    end
end

endmodule
