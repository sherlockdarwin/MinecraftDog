`timescale 1ns / 1ps
// =============================================================================
// mc_follow.v  跟随 + 避障决策（100 MHz 域）：主人在哪（UWB，经 mc_m0_link）+ 前面能往哪走（mc_obs）→ 两个轮子的 PWM
//
//   每 PERIOD_MS（20 ms）算一次（和 MSPM0 原来的跟随程序一样的参数和斜坡），给 mc_m0_link 发一帧命令：
//     1. 状态（O_state）：
//        0 LOST  收不到 UWB                          → 停（#S*）
//        1 NCAM  OBS_TIMEOUT_MS 内没有新的避障结果      → 停（相机没图，看不见路）
//        2 HERE  主人在 STOP_CM 以内                 → 停（到了）
//        4 TURN  主人在 ±VIEW_DEG 以外（相机看不到那边）→ 原地转：左 = +转向量，右 = −转向量
//        5 GO    在避障的 9 个方向（4~12，±19°）里，能走 ≥ CLEAR_CM 的方向中挑离主人最近的（一样近挑靠正前方的）→ 往那个方向走
//        3 BLK   哪个方向都不到 CLEAR_CM                → 停
//     2. 转向量 = 角度 × KP_A（TURN 用主人的角度，GO 用选中方向的角度）；
//        前进量（GO）= (距离 − STOP_CM) × KP_D，限在 MIN_FWD ~ MAX_FWD，再不超过 (那个方向能走多远 − D_STOP) × KP_OBS（离障碍近就慢）；
//        左轮 = 前进 + 转向、右轮 = 前进 − 转向，各限在 ±MAX_WHEEL。
//     3. 斜坡：每次最多变 ACC（加速）/ DEC（减速：目标的绝对值比现在小）；停的时候直接归 0。
//   避障结果在相机像素时钟域：mc_obs 每帧翻转 I_obs_tog，翻转以后 I_obs_free 保持一帧不变，这里同步翻转信号后再取。
// =============================================================================
module mc_follow #(
    parameter PERIOD_MS      = 20,
    parameter OBS_TIMEOUT_MS = 100,
    parameter STOP_CM        = 300,
    parameter VIEW_DEG       = 35,
    parameter CLEAR_CM       = 60,
    parameter D_STOP         = 35,
    parameter KP_D           = 4,       // PWM / 厘米
    parameter KP_A           = 35,      // PWM / 度
    parameter KP_OBS         = 50,      // PWM / 厘米
    parameter MIN_FWD        = 600,
    parameter MAX_FWD        = 6000,
    parameter MAX_WHEEL      = 6500,
    parameter ACC            = 200,
    parameter DEC            = 400
)(
    input  wire               I_clk,
    input  wire               I_rst_n,
    input  wire               I_tick_1ms,

    input  wire               I_tgt_ok,         // 主人（mc_m0_link）
    input  wire signed [7:0]  I_tgt_deg,
    input  wire [9:0]         I_tgt_cm,

    input  wire               I_obs_tog,        // 避障结果（相机像素时钟域）
    input  wire [71:0]        I_obs_free,       // 方向 4~12 各能走多远（厘米，255 = 没挡），方向 4 在 [7:0]

    output reg                O_cmd_valid,      // 每 PERIOD_MS 打一拍
    output reg                O_cmd_stop,
    output reg  signed [13:0] O_cmd_l,
    output reg  signed [13:0] O_cmd_r,
    output reg  [2:0]         O_state
);

localparam [2:0] M_LOST = 3'd0, M_NCAM = 3'd1, M_HERE = 3'd2, M_BLK = 3'd3, M_TURN = 3'd4, M_GO = 3'd5;

// ---- 避障结果：同步翻转信号，翻转后取一份 ----
wire S_tog;
mc_sync_bits #(.W(1)) u_sync (.I_clk (I_clk), .I_d (I_obs_tog), .O_q (S_tog));
reg        S_tog_d;
reg [71:0] S_free;
reg  [9:0] S_oage;                      // 上次结果以后多少毫秒（到 OBS_TIMEOUT_MS 不再加）
always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        S_tog_d <= 1'b0; S_free <= {9{8'd0}}; S_oage <= OBS_TIMEOUT_MS;
    end else begin
        S_tog_d <= S_tog;
        if (S_tog != S_tog_d) begin S_free <= I_obs_free; S_oage <= 10'd0; end
        else if (I_tick_1ms && S_oage != OBS_TIMEOUT_MS) S_oage <= S_oage + 10'd1;
    end
end

// ---- 方向角度表 ----
reg  [3:0]        S_hb;
wire signed [6:0] S_psi;
mc_obs_lut u_lut (.I_row (7'd0), .O_dist (), .I_sec (4'd0), .O_sec_deg (), .I_head (S_hb), .O_head_deg (S_psi),
                  .I_tb (4'd0), .I_tj (4'd0), .O_thr (), .O_row_min ());

function [3:0] pref;                    // 第 k 个看的方向：8,7,9,6,10,5,11,4,12
    input [3:0] k;
    pref = k[0] ? 4'd8 - ((k + 4'd1) >> 1) : 4'd8 + (k >> 1);
endfunction

// ---- 斜坡（和 MSPM0 的 Follow_RampCommand 一样）----
function signed [15:0] ramp;
    input signed [15:0] cur, tgt;
    reg signed [16:0] d;
    reg        [15:0] ac, at, st;
    begin
        d  = tgt - cur;
        ac = cur[15] ? -cur : cur;
        at = tgt[15] ? -tgt : tgt;
        st = (at < ac) ? DEC : ACC;
        ramp = (d > $signed({1'b0, st})) ? cur + st : (d < -$signed({1'b0, st})) ? cur - st : tgt;
    end
endfunction
function signed [15:0] clampw;          // 限在 ±MAX_WHEEL
    input signed [19:0] v;
    clampw = (v > MAX_WHEEL) ? MAX_WHEEL : (v < -MAX_WHEEL) ? -MAX_WHEEL : v[15:0];
endfunction

// ---- 决策 ----
localparam [2:0] F_WAIT = 3'd0, F_SEARCH = 3'd1, F_MUL = 3'd2, F_SUM = 3'd3, F_OUT = 3'd4;
reg  [2:0]  S_f;
reg  [4:0]  S_ms;
reg  [3:0]  S_k;
reg  [2:0]  S_m;                        // 这一次的状态
reg  signed [7:0] S_deg;
reg  [9:0]  S_cm;
reg  [7:0]  S_bdiff;                    // 选方向：到目前为止离主人最近的角度差
reg  [3:0]  S_bb;
reg  signed [6:0] S_bpsi;
reg  [7:0]  S_bfree;
reg  signed [19:0] S_fwd, S_turn, S_fo;
reg  signed [15:0] S_tl, S_tr;          // 目标
reg  signed [15:0] S_cl, S_cr;          // 现在（斜坡后）

wire [7:0]  S_adeg = I_tgt_deg[7] ? -I_tgt_deg : I_tgt_deg;
wire [7:0]  S_fb   = S_free[8 * (S_hb - 4'd4) +: 8];
wire signed [8:0] S_dd = $signed({S_psi[6], S_psi}) - $signed({S_deg[7], S_deg});
wire [7:0]  S_diff = S_dd[8] ? -S_dd[7:0] : S_dd[7:0];
wire signed [19:0] S_fw1 = (S_fwd < MIN_FWD) ? MIN_FWD : (S_fwd > MAX_FWD) ? MAX_FWD : S_fwd;    // 前进量：限幅
wire signed [19:0] S_fw  = (S_fo < S_fw1) ? S_fo : S_fw1;                                          //       再不超过避障的限制

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        S_f <= F_WAIT; S_ms <= 5'd0; S_k <= 4'd0; S_m <= M_LOST; S_deg <= 8'sd0; S_cm <= 10'd0;
        S_hb <= 4'd8; S_bdiff <= 8'd255; S_bb <= 4'd0; S_bpsi <= 7'sd0; S_bfree <= 8'd0;
        S_fwd <= 20'sd0; S_turn <= 20'sd0; S_fo <= 20'sd0; S_tl <= 16'sd0; S_tr <= 16'sd0; S_cl <= 16'sd0; S_cr <= 16'sd0;
        O_cmd_valid <= 1'b0; O_cmd_stop <= 1'b1; O_cmd_l <= 14'sd0; O_cmd_r <= 14'sd0; O_state <= M_LOST;
    end else begin
        O_cmd_valid <= 1'b0;
        case (S_f)
            F_WAIT: if (I_tick_1ms) begin
                        if (S_ms == PERIOD_MS - 1) begin
                            S_ms <= 5'd0;
                            S_deg <= I_tgt_deg; S_cm <= I_tgt_cm;
                            S_k <= 4'd0; S_hb <= pref(4'd0); S_bdiff <= 8'd255; S_bb <= 4'd0;
                            if (!I_tgt_ok)                              begin S_m <= M_LOST; S_f <= F_SUM; end
                            else if (S_oage == OBS_TIMEOUT_MS)          begin S_m <= M_NCAM; S_f <= F_SUM; end
                            else if (I_tgt_cm <= STOP_CM)               begin S_m <= M_HERE; S_f <= F_SUM; end
                            else if (S_adeg > VIEW_DEG)                 begin S_m <= M_TURN; S_f <= F_MUL; end
                            else                                        begin S_m <= M_GO;   S_f <= F_SEARCH; end
                        end else S_ms <= S_ms + 5'd1;
                    end
            F_SEARCH: begin                                           // 9 拍：方向 S_hb 能走 ≥ CLEAR_CM、离主人更近 → 记下
                        if (S_fb >= CLEAR_CM && S_diff < S_bdiff) begin S_bdiff <= S_diff; S_bb <= S_hb; S_bpsi <= S_psi; S_bfree <= S_fb; end
                        if (S_k == 4'd8) begin S_f <= F_MUL; end
                        else begin S_k <= S_k + 4'd1; S_hb <= pref(S_k + 4'd1); end
                    end
            F_MUL: begin                                              // 乘系数
                        if (S_m == M_GO && S_bb == 4'd0) S_m <= M_BLK;
                        S_turn <= ((S_m == M_TURN) ? S_deg : S_bpsi) * KP_A;
                        S_fwd  <= ($signed({1'b0, S_cm}) - STOP_CM) * KP_D;
                        S_fo   <= ($signed({1'b0, S_bfree}) - D_STOP) * KP_OBS;
                        S_f <= F_SUM;
                    end
            F_SUM: begin                                              // 前进量限幅，左右轮目标
                        if (S_m == M_TURN) begin
                            S_tl <= clampw(S_turn); S_tr <= clampw(-S_turn);
                        end else begin
                            S_tl <= clampw(S_fw + S_turn); S_tr <= clampw(S_fw - S_turn);
                        end
                        S_f <= F_OUT;
                    end
            F_OUT: begin                                              // 斜坡、发出去
                        O_cmd_valid <= 1'b1;
                        O_state <= S_m;
                        if (S_m == M_TURN || S_m == M_GO) begin
                            S_cl <= ramp(S_cl, S_tl); S_cr <= ramp(S_cr, S_tr);
                            O_cmd_stop <= 1'b0;
                            O_cmd_l <= ramp(S_cl, S_tl); O_cmd_r <= ramp(S_cr, S_tr);
                        end else begin
                            S_cl <= 16'sd0; S_cr <= 16'sd0;
                            O_cmd_stop <= 1'b1; O_cmd_l <= 14'sd0; O_cmd_r <= 14'sd0;
                        end
                        S_f <= F_WAIT;
                    end
            default: S_f <= F_WAIT;
        endcase
    end
end

endmodule
