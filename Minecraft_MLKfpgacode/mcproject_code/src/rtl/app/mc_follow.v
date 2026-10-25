`timescale 1ns / 1ps
// =============================================================================
// mc_follow.v  跟随 + 避障决策（100 MHz 域）：主人在哪（UWB，经 mc_m0_link）+ 前面能往哪走（mc_obs）→ 两个轮子的 PWM
//
//   每 PERIOD_MS（20 ms）算一次，给 mc_m0_link 发一帧命令（停 = #S*，否则两轮 PWM）。完整的运行逻辑见 obstacle.md §6。
//   跟随部分逐条照搬 STM32 上车调好的 follow.c（同样的参数、同样的整数运算：C 的除法向 0 取整，这里用一个
//   逐位除法器做 /3 和 /10000，不近似）：没有障碍时，算出来的两轮命令和 STM32 的跟随测试模式一模一样。
//
//   1. 角度平滑：x16 += (新角度 × 16 − x16) / ANGLE_FILTER（刚收到 / 刚找回目标时直接用新角度）；a = x16 / 16。
//   2. 按顺序判断：
//        LOST  收不到 UWB                                   → 停（平滑重来）
//        NCAM  OBS_TIMEOUT_MS 内没有新的避障结果（相机没图） → 停
//        HERE  主人在 STOP_CM 以内                           → 停
//        TURN  |a| > PIVOT_ENTER 并保持 PIVOT_CONFIRM_MS（回到 PIVOT_EXIT 以内才退出）→ 原地转 ±PIVOT_PWM
//   3. 往前走：前进 = START_PWM + (距离 − STOP_CM) × KP_D，最多 MAX_FWD。再看避障（9 个方向 4~12，8 = 正前方）：
//        挡路 = 正前方能走的距离 < AVOID_CM，或者离主人方向最近的那个方向能走的距离 < AVOID_CM
//        不挡路：GO   转向对着主人（a）；刚绕完障碍 AVOID_HOLD_MS 以内先直走（AVD，转向目标 0）
//        挡路：  在能走 ≥ AVOID_CM 的方向里挑代价最小的（一个都没有，就在 ≥ CLEAR_CM 的里挑）：
//                W_TGT × |方向 − a| + W_PREV × |方向 − 上次绕行的方向|
//                （VFH+ 的代价函数：目标权重大于其余；上次方向那一项让绕行不来回换边）
//                没有 → BLK 停；正前方 < SPIN_CM → SPIN 原地转向它（±SPIN_PWM）；否则 AVD 转向它（用绕行的转向系数）
//        前进不超过 START_PWM + (前面能走的距离 − CLEAR_CM) × KP_OBS（"前面" = 正前方和要去的方向里近的那个）
//   4. 转向（GO / AVD）= 前进 × min((|偏角| − 死区) × 每度系数, 上限) / 10000，带符号；每次最多变 STEP。
//      GO 用 DEADBAND / TURN_PER10K / TURN_MAX_10K / TURN_STEP，AVD 用 0 / AVOID_PER10K / AVOID_MAX_10K / AVOID_STEP。
//   5. 左 = 前进 + 转向、右 = 前进 − 转向，各限 ±MAX_WHEEL；斜坡每次最多变 ACC / DEC（目标绝对值变小）；停的时候直接归 0。
//   避障结果在相机像素时钟域：mc_obs 每帧翻转 I_obs_tog，翻转以后 I_obs_free 保持一帧不变，这里同步翻转信号后再取。
// =============================================================================
module mc_follow #(
    parameter PERIOD_MS        = 20,
    parameter OBS_TIMEOUT_MS   = 100,
    // ---- 跟随（STM32 follow.h，上车调好的）----
    parameter STOP_CM          = 300,
    parameter START_PWM        = 3000,
    parameter KP_D             = 10,      // PWM / 厘米
    parameter MAX_FWD          = 5000,
    parameter ANGLE_FILTER     = 3,
    parameter DEADBAND         = 5,       // 度
    parameter TURN_PER10K      = 30,      // 每度 0.01%（前进的万分比）
    parameter TURN_MAX_10K     = 900,
    parameter TURN_STEP        = 12,
    parameter PIVOT_ENTER      = 90,
    parameter PIVOT_CONFIRM_MS = 300,
    parameter PIVOT_EXIT       = 40,
    parameter PIVOT_PWM        = 2200,
    parameter MAX_WHEEL        = 6500,
    parameter ACC              = 200,
    parameter DEC              = 400,
    // ---- 避障（FPGA 加的，要上车调）----
    parameter AVOID_CM         = 100,
    parameter CLEAR_CM         = 60,
    parameter SPIN_CM          = 45,
    parameter KP_OBS           = 20,      // PWM / 厘米
    parameter SPIN_PWM         = 2200,
    parameter AVOID_PER10K     = 120,
    parameter AVOID_MAX_10K    = 3000,
    parameter AVOID_STEP       = 40,
    parameter AVOID_HOLD_MS    = 500,
    parameter W_TGT            = 2,
    parameter W_PREV           = 1
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

localparam [2:0] M_LOST = 3'd0, M_NCAM = 3'd1, M_HERE = 3'd2, M_BLK = 3'd3, M_TURN = 3'd4, M_GO = 3'd5, M_AVD = 3'd6, M_SPIN = 3'd7;
localparam CONF_N = (PIVOT_CONFIRM_MS + PERIOD_MS - 1) / PERIOD_MS;   // 原地转要确认几次（STM32：经过 ≥ 300 ms）
localparam HOLD_N = AVOID_HOLD_MS / PERIOD_MS;                       // 绕完以后直走几次

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

// ---- 逐位除法器（无符号，27 位 / 14 位，27 拍）----
reg  [26:0] S_dq;                       // 被除数 → 逐位变成商
reg  [14:0] S_drem;
reg  [13:0] S_dden;
reg  [4:0]  S_dcnt;
wire        S_dbusy = (S_dcnt != 5'd0);
wire [14:0] S_dtry  = {S_drem[13:0], S_dq[26]};
wire        S_dge   = (S_dtry >= {1'b0, S_dden});

// ---- 斜坡（和 STM32 的 Follow_RampCommand 一样）/ 限幅 ----
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
localparam [3:0] F_WAIT = 4'd0, F_FILT = 4'd1, F_FDIV = 4'd2, F_DEC1 = 4'd3, F_SRCH = 4'd4, F_DEC2 = 4'd5, F_LIM = 4'd6,
                 F_TURN = 4'd7, F_TMUL = 4'd8, F_TDIV = 4'd9, F_RATE = 4'd10, F_SPIN = 4'd11, F_RAMP = 4'd12, F_OUT = 4'd13, F_STOP = 4'd14;
reg  [3:0]  S_f;
reg  [4:0]  S_ms;
reg         S_ok, S_fresh;
reg  signed [7:0] S_raw;
reg  [9:0]  S_cm;
reg  [71:0] S_fl;                       // 这一次用的避障结果
reg         S_avalid;                   // 平滑角度有效
reg  signed [12:0] S_x16;               // 平滑角度 × 16
reg         S_dneg;                     // 除法结果要取负
reg         S_piv, S_pend;              // 正在原地转 / 超过 PIVOT_ENTER 在等确认
reg  [4:0]  S_pcnt;
reg  [2:0]  S_m;
reg  [3:0]  S_k;
reg  [7:0]  S_btd, S_btf;               // 离主人方向最近的方向：角度差、能走多远
reg         S_aok, S_bok;               // 有能走 ≥ AVOID_CM / ≥ CLEAR_CM 的方向
reg  [11:0] S_ac, S_bc;                 // 各自最小的代价
reg  signed [6:0] S_apsi, S_bpsi;      // 它的角度
reg  [7:0]  S_af, S_bf;                 // 它能走多远
reg         S_pv;                       // 上次绕行的方向有效
reg  signed [6:0] S_ppsi;
reg  [7:0]  S_hold;                     // 绕完以后还要直走几次
reg         S_av;                       // 这一次用绕行的转向系数
reg  signed [7:0] S_err;                // 转向的偏角
reg  signed [15:0] S_fwd, S_tgt, S_turn;
reg  [7:0]  S_flim;                     // 前进上限按这个距离算
reg  [13:0] S_pr;                       // 转向的万分比
reg  signed [15:0] S_tl, S_tr;          // 两轮目标（斜坡前）
reg  signed [15:0] S_cl, S_cr;          // 现在的两轮命令（斜坡后）

// 平滑角度 → 整数度（C：向 0 取整）
wire [12:0] S_x16n = -S_x16;
wire signed [7:0] S_a  = S_x16[12] ? -$signed({4'd0, S_x16n[11:4]}) : $signed({4'd0, S_x16[11:4]});
wire [7:0]  S_aa = S_a[7] ? -S_a : S_a;
wire signed [12:0] S_raw16 = {S_raw[7], S_raw, 4'd0};                 // × 16（拼接是无符号的：要自己补符号位）
wire signed [13:0] S_fd    = S_raw16 - S_x16;                      // 新角度 × 16 − 平滑值
wire [13:0] S_fda  = S_fd[13] ? -S_fd : S_fd;
// 原地转的状态（这一次之后的值）
reg         S_piv_n, S_pend_n;
reg  [4:0]  S_pcnt_n;
always @* begin
    S_piv_n = S_piv; S_pend_n = S_pend; S_pcnt_n = S_pcnt;
    if (!S_piv) begin
        if (S_aa <= PIVOT_ENTER)  S_pend_n = 1'b0;
        else if (!S_pend)         begin S_pend_n = 1'b1; S_pcnt_n = 5'd0; end
        else begin
            S_pcnt_n = (S_pcnt == 5'd31) ? 5'd31 : S_pcnt + 5'd1;
            if (S_pcnt_n >= CONF_N) S_piv_n = 1'b1;
        end
    end else if (S_aa < PIVOT_EXIT) begin
        S_piv_n = 1'b0; S_pend_n = 1'b0;
    end
end
// 搜索：方向 S_hb 的角度、能走多远、角度差、代价
wire [7:0]  S_fb   = S_fl[8 * (S_hb - 4'd4) +: 8];
wire signed [8:0] S_d1 = $signed({S_psi[6], S_psi}) - $signed({S_a[7], S_a});
wire [7:0]  S_dt   = S_d1[8] ? -S_d1[7:0] : S_d1[7:0];
wire signed [7:0] S_d2 = $signed({S_psi[6], S_psi}) - $signed({S_ppsi[6], S_ppsi});
wire [7:0]  S_dp   = S_d2[7] ? -S_d2 : S_d2;
wire [11:0] S_cost = S_dt * W_TGT + (S_pv ? S_dp * W_PREV : 12'd0);
// 前面能走多远 → 前进上限
wire [7:0]  S_f0   = S_fl[39:32];                                  // 方向 8（正前方）
wire [7:0]  S_fmin = (S_f0 < S_btf) ? S_f0 : S_btf;               // 不挡路时：正前方和主人方向里近的
wire signed [6:0] S_cpsi = S_aok ? S_apsi : S_bpsi;              // 绕行方向：先挑 ≥ AVOID_CM 的
wire [7:0]  S_cf   = S_aok ? S_af : S_bf;
wire [7:0]  S_fmav = (S_f0 < S_cf)  ? S_f0 : S_cf;                // 绕行时：正前方和绕行方向里近的
wire        S_blk  = (S_f0 < AVOID_CM) || (S_btf < AVOID_CM);
// 转向：|偏角| 超出死区的部分 × 每度系数，限上限
wire [7:0]  S_ea   = S_err[7] ? -S_err : S_err;
wire [7:0]  S_db   = S_av ? 8'd0 : DEADBAND;
wire [19:0] S_per0 = (S_ea - S_db) * (S_av ? AVOID_PER10K : TURN_PER10K);
wire [19:0] S_per  = (S_per0 > (S_av ? AVOID_MAX_10K : TURN_MAX_10K)) ? (S_av ? AVOID_MAX_10K : TURN_MAX_10K) : S_per0;
wire [15:0] S_stp  = S_av ? AVOID_STEP : TURN_STEP;
wire signed [15:0] S_tup  = S_turn + $signed(S_stp);
wire signed [15:0] S_tdn  = S_turn - $signed(S_stp);
wire signed [15:0] S_tnew = (S_tgt > S_tup) ? S_tup : (S_tgt < S_tdn) ? S_tdn : S_tgt;   // 方向盘每次最多变 STEP

function [15:0] obs_lim;                // 前进上限：START_PWM + (f − CLEAR_CM) × KP_OBS（f < CLEAR_CM 按 CLEAR_CM 算）
    input [7:0] f;
    obs_lim = START_PWM + ((f > CLEAR_CM) ? (f - CLEAR_CM) * KP_OBS : 0);
endfunction

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        S_f <= F_WAIT; S_ms <= 5'd0; S_ok <= 1'b0; S_fresh <= 1'b0; S_raw <= 8'sd0; S_cm <= 10'd0; S_fl <= {9{8'd0}};
        S_avalid <= 1'b0; S_x16 <= 13'sd0; S_dneg <= 1'b0; S_piv <= 1'b0; S_pend <= 1'b0; S_pcnt <= 5'd0;
        S_m <= M_LOST; S_k <= 4'd0; S_hb <= 4'd8; S_btd <= 8'd255; S_btf <= 8'd0; S_bok <= 1'b0; S_bc <= 12'd4095;
        S_aok <= 1'b0; S_ac <= 12'd4095; S_apsi <= 7'sd0; S_af <= 8'd0; S_bpsi <= 7'sd0; S_bf <= 8'd0; S_pv <= 1'b0; S_ppsi <= 7'sd0; S_hold <= 8'd0; S_av <= 1'b0; S_err <= 8'sd0;
        S_fwd <= 16'sd0; S_tgt <= 16'sd0; S_turn <= 16'sd0; S_cl <= 16'sd0; S_cr <= 16'sd0;
        S_flim <= 8'd0; S_pr <= 14'd0; S_tl <= 16'sd0; S_tr <= 16'sd0;
        S_dq <= 27'd0; S_drem <= 15'd0; S_dden <= 14'd1; S_dcnt <= 5'd0;
        O_cmd_valid <= 1'b0; O_cmd_stop <= 1'b1; O_cmd_l <= 14'sd0; O_cmd_r <= 14'sd0; O_state <= M_LOST;
    end else begin
        O_cmd_valid <= 1'b0;
        if (S_dbusy) begin                                            // 除法器每拍出一位商
            S_drem <= S_dge ? S_dtry - {1'b0, S_dden} : S_dtry;
            S_dq   <= {S_dq[25:0], S_dge};
            S_dcnt <= S_dcnt - 5'd1;
        end
        case (S_f)
            F_WAIT: if (I_tick_1ms) begin
                        if (S_ms == PERIOD_MS - 1) begin
                            S_ms <= 5'd0;
                            S_ok <= I_tgt_ok; S_raw <= I_tgt_deg; S_cm <= I_tgt_cm;
                            S_fresh <= (S_oage != OBS_TIMEOUT_MS); S_fl <= S_free;
                            S_f <= F_FILT;
                        end else S_ms <= S_ms + 5'd1;
                    end
            F_FILT: begin                                             // 1. 角度平滑
                        if (!S_ok) begin S_avalid <= 1'b0; S_m <= M_LOST; S_f <= F_STOP; end
                        else if (!S_avalid) begin S_x16 <= S_raw16; S_avalid <= 1'b1; S_f <= F_DEC1; end
                        else begin
                            S_dq <= {13'd0, S_fda}; S_drem <= 15'd0; S_dden <= ANGLE_FILTER; S_dcnt <= 5'd27;
                            S_dneg <= S_fd[13]; S_f <= F_FDIV;
                        end
                    end
            F_FDIV: if (!S_dbusy) begin
                        S_x16 <= S_dneg ? S_x16 - $signed({1'b0, S_dq[11:0]}) : S_x16 + $signed({1'b0, S_dq[11:0]});
                        S_f <= F_DEC1;
                    end
            F_DEC1: begin                                             // 2. 停的条件、原地转
                        if (!S_fresh)            begin S_m <= M_NCAM; S_f <= F_STOP; end
                        else if (S_cm <= STOP_CM) begin S_m <= M_HERE; S_f <= F_STOP; end
                        else begin
                            S_piv <= S_piv_n; S_pend <= S_pend_n; S_pcnt <= S_pcnt_n;
                            if (S_piv_n) begin S_m <= M_TURN; S_f <= F_SPIN; end
                            else begin                                // 3. 往前走：先搜 9 个方向
                                S_fwd <= ((START_PWM + (S_cm - STOP_CM) * KP_D) > MAX_FWD) ? MAX_FWD : START_PWM + (S_cm - STOP_CM) * KP_D;
                                S_k <= 4'd0; S_hb <= pref(4'd0); S_btd <= 8'd255; S_btf <= 8'd0;
                                S_aok <= 1'b0; S_ac <= 12'd4095; S_bok <= 1'b0; S_bc <= 12'd4095;
                                S_f <= F_SRCH;
                            end
                        end
                    end
            F_SRCH: begin                                             // 9 拍：离主人最近的方向；能走的方向里代价最小的
                        if (S_dt < S_btd) begin S_btd <= S_dt; S_btf <= S_fb; end
                        if (S_fb >= AVOID_CM && S_cost < S_ac) begin S_ac <= S_cost; S_aok <= 1'b1; S_apsi <= S_psi; S_af <= S_fb; end
                        if (S_fb >= CLEAR_CM && S_cost < S_bc) begin S_bc <= S_cost; S_bok <= 1'b1; S_bpsi <= S_psi; S_bf <= S_fb; end
                        if (S_k == 4'd8) S_f <= F_DEC2;
                        else begin S_k <= S_k + 4'd1; S_hb <= pref(S_k + 4'd1); end
                    end
            F_DEC2: begin                                             // 挡不挡路、往哪走
                        if (!S_blk) begin
                            if (S_hold != 8'd0) begin S_m <= M_AVD; S_av <= 1'b1; S_err <= 8'sd0; S_hold <= S_hold - 8'd1; end
                            else                begin S_m <= M_GO;  S_av <= 1'b0; S_err <= S_a;   S_pv <= 1'b0; end
                            S_flim <= S_fmin; S_f <= F_LIM;
                        end else if (!S_bok) begin
                            S_m <= M_BLK; S_f <= F_STOP;
                        end else begin
                            S_ppsi <= S_cpsi; S_pv <= 1'b1; S_hold <= HOLD_N;
                            if (S_f0 < SPIN_CM) begin S_m <= M_SPIN; S_f <= F_SPIN; end
                            else begin
                                S_m <= M_AVD; S_av <= 1'b1; S_err <= {S_cpsi[6], S_cpsi};
                                S_flim <= S_fmav; S_f <= F_LIM;
                            end
                        end
                    end
            F_LIM:  begin                                             // 前进不超过避障的上限
                        if (obs_lim(S_flim) < S_fwd) S_fwd <= obs_lim(S_flim);
                        S_f <= F_TURN;
                    end
            F_TURN: begin                                             // 4. 转向 = 前进 × 万分比 / 10000
                        if (S_ea > S_db) begin S_pr <= S_per[13:0]; S_f <= F_TMUL; end
                        else begin S_tgt <= 16'sd0; S_f <= F_RATE; end
                    end
            F_TMUL: begin
                        S_dq <= S_fwd[12:0] * S_pr; S_drem <= 15'd0; S_dden <= 14'd10000; S_dcnt <= 5'd27;
                        S_dneg <= S_err[7]; S_f <= F_TDIV;
                    end
            F_TDIV: if (!S_dbusy) begin
                        S_tgt <= S_dneg ? -$signed({2'b0, S_dq[13:0]}) : $signed({2'b0, S_dq[13:0]});
                        S_f <= F_RATE;
                    end
            F_RATE: begin                                             // 方向盘慢慢打；两轮目标
                        S_turn <= S_tnew;
                        S_tl <= clampw(S_fwd + S_tnew); S_tr <= clampw(S_fwd - S_tnew);
                        S_f <= F_RAMP;
                    end
            F_SPIN: begin                                             // 原地转（TURN：朝主人；SPIN：朝能走的方向）
                        S_turn <= 16'sd0; S_pv <= (S_m == M_SPIN) ? S_pv : 1'b0; S_hold <= (S_m == M_SPIN) ? S_hold : 8'd0;
                        if ((S_m == M_TURN) ? (S_a > 8'sd0) : (S_cpsi > 7'sd0)) begin
                            S_tl <= clampw((S_m == M_TURN) ? PIVOT_PWM : SPIN_PWM);  S_tr <= clampw((S_m == M_TURN) ? -PIVOT_PWM : -SPIN_PWM);
                        end else begin
                            S_tl <= clampw((S_m == M_TURN) ? -PIVOT_PWM : -SPIN_PWM); S_tr <= clampw((S_m == M_TURN) ? PIVOT_PWM : SPIN_PWM);
                        end
                        S_f <= F_RAMP;
                    end
            F_RAMP: begin                                             // 5. 斜坡
                        S_cl <= ramp(S_cl, S_tl); S_cr <= ramp(S_cr, S_tr);
                        S_f <= F_OUT;
                    end
            F_OUT: begin                                              // 发出去
                        O_cmd_valid <= 1'b1; O_cmd_stop <= 1'b0; O_state <= S_m;
                        O_cmd_l <= S_cl[13:0]; O_cmd_r <= S_cr[13:0];
                        S_f <= F_WAIT;
                    end
            F_STOP: begin                                             // 停：命令直接归 0，绕行的记忆清掉
                        S_cl <= 16'sd0; S_cr <= 16'sd0; S_turn <= 16'sd0; S_pv <= 1'b0; S_hold <= 8'd0;
                        O_cmd_valid <= 1'b1; O_cmd_stop <= 1'b1; O_cmd_l <= 14'sd0; O_cmd_r <= 14'sd0; O_state <= S_m;
                        S_f <= F_WAIT;
                    end
            default: S_f <= F_WAIT;
        endcase
    end
end

endmodule
