`timescale 1ns / 1ps
// =============================================================================
// mc_follow.v  跟随 + 避障决策 + 角度环（100 MHz 域）：主人在哪（UWB）+ 前面能往哪走（避障）+ 车头朝哪（陀螺仪）→ 两个轮子的 PWM
//
//   每 PERIOD_MS（20 ms）算一次，给 mc_m0_link 发一帧命令（停 = #S*，否则两轮 PWM）。运行逻辑见 obstacle.md §6。
//   角度全部用"世界方向"（陀螺仪航向角，65536 = 360°，右转为正，16 位自然回绕）：
//     主人方向 H_own = 车头 + UWB 角度，在世界方向上平滑（车自己转的时候主人的方向不跟着变，不会被平滑拖慢）；
//     决策只决定"目标航向" H_tgt，由角度环把车头转到 H_tgt 并保持（电机左右不一样快也能走直）。
//
//   1. 主人方向：m = 车头 + UWB 角度；H_own += (m − H_own) / ANGLE_FILTER（刚收到 / 刚找回时 H_own = m）。
//      主人相对车头的角度 a = H_own − 车头（度，按绝对值四舍五入：× 182 换过去再换回来不差 1°）。
//   2. 按顺序判断：
//        LOST  收不到 UWB                                   → 停（平滑重来）
//        NIMU  陀螺仪没准备好（没归零 / 收不到）            → 停（平滑重来）
//        NCAM  OBS_TIMEOUT_MS 内没有新的避障结果（相机没图） → 停
//        HERE  主人在 STOP_CM 以内                           → 停
//   3. 往前走：前进 = START_PWM + (距离 − STOP_CM) × KP_D，最多 MAX_FWD。再看避障（9 个方向 4~12，8 = 正前方）：
//        挡路 = 正前方能走的距离 < AVOID_CM，或者离主人方向最近的那个方向能走的距离 < AVOID_CM
//        TURN  |a| > PIVOT_ENTER 并保持 PIVOT_CONFIRM_MS（回到 PIVOT_EXIT 以内才退出）→ 原地转 ±PIVOT_PWM，转向主人。
//              不进 TURN：刚绕完障碍、还在直走那段（不挡路、绕完直走还没走够）——车头扫过的地方相机看不到，障碍还在车旁边；
//              正在找出口 / 困住了（找出口自己会转）。确认时间照算，能进的时候马上进。
//        不挡路：刚绕完障碍还没走够 AVOID_HOLD_CM → AVD 保持绕行的航向直走
//                  （走了多远按发出去的前进量估：满量程 8000 ≈ CMS_FULL cm/s，每次减掉上一次的前进量）；
//                远处挡路 → AVD 提前绕：主人在看得到的方向里（离它最近的方向差 ≤ FAR_ANG 度）、主人那个方向能走的距离
//                  < T = min(AVOID_FAR_CM, 主人距离 − OWNER_GAP_CM)（再远的可能就是主人自己的腿），
//                  在能走 ≥ T 的方向里挑代价最小的（同下），目标航向 = 车头 + 它（回差同下）；一个都没有就照常 GO，近了再绕；
//                否则 GO   目标航向 = 主人方向（和现在的目标差不到 DEADBAND 度就不改：一段一段走直线）
//        挡路：  在能走 ≥ AVOID_CM 的方向里挑代价最小的（一个都没有，就在 ≥ CLEAR_CM 的里挑）：
//                W_TGT × |方向 − a| + W_PREV × |方向 − 上次绕行的方向|（上次的方向存成世界方向，车转了也对得上）
//                正前方 < SPIN_CM → SPIN 原地转向它（±SPIN_PWM）；否则 AVD 目标航向 = 车头 + 它（同样有 DEADBAND 回差）
//                一个都没有 → 找出口：先停 SCAN_PAUSE_MS 看（BLK），再往主人那边（a ≥ 0 往右）原地转 ±SPIN_PWM（SPIN），
//                  转过 SCAN_DEG（或转了 SCAN_STEP_MS 还没转够）就停下再看……哪一次看到能走的方向就照常绕过去；
//                  每次停着看完，把这一步实际转过的角度（从这一步开始转到现在，含停下时滑过的；往反方向的不算）加起来：
//                  满 360°（360 × 182）、或者已经转了 2 × ⌈360 / SCAN_DEG⌉ 步（电机转不动）还没有 → 困住：BLK 停、O_stuck = 1（狗叫），
//                  直到看到能走的方向（障碍挪开）或者停车条件（LOST / NIMU / NCAM / HERE）
//        前进不超过 START_PWM + (前面能走的距离 − CLEAR_CM) × KP_OBS（"前面" = 正前方和要去的方向里近的那个）
//   4. 角度环（GO / AVD）：e = H_tgt − 车头（度）；转向 = HEAD_KP × e + HEAD_KI × ∫e dt − HEAD_KD × 角速度（°/s），
//      积分分离：|e| ≤ HEAD_I_ZONE 才积分（大转弯时不积，转过去不会冲过头）；积分项限在 ±HEAD_I_MAX；
//      转向限在 ±TURN_MAX（GO）/ ±AVOID_TURN_MAX（AVD）；停车 / 原地转时积分清零。
//      定点：e 以 1/16 度计（e16 = 航向差 × 45 / 512，向下取整），P = HEAD_KP × e16 / 16；
//      积分累加器以 1/256 PWM 计，每次加 KIC × e16 / 16（KIC = HEAD_KI × PERIOD_MS × 256 / 1000，四舍五入）；
//      D = HEAD_KD × 4000 × 角速度原始值 / 65536（= HEAD_KD × °/s）。除以 2 的幂都是向下取整。
//   5. 前进走斜坡（每次最多加 ACC / 减 DEC，起步、停下平顺），转向每次最多变 TURN_SLEW（原地转 TURN / SPIN = 前进 0、转向 ±PIVOT_PWM / ±SPIN_PWM）；
//      左 = 前进 + 转向、右 = 前进 − 转向，各限 ±MAX_WHEEL；停的时候直接归 0。
//      （斜坡只管前进：要是两个轮子各自走斜坡，原地转完一个轮子要从 −2200 慢慢爬回正转，车会多转几十度，角度环管不住）
//   避障结果在相机像素时钟域：mc_obs 每帧翻转 I_obs_tog，翻转以后 I_obs_free 保持一帧不变，这里同步翻转信号后再取。
// =============================================================================
module mc_follow #(
    parameter PERIOD_MS        = 20,
    parameter OBS_TIMEOUT_MS   = 100,
    // ---- 跟随 ----
    parameter STOP_CM          = 200,
    parameter START_PWM        = 3300,
    parameter KP_D             = 10,      // PWM / 厘米
    parameter MAX_FWD          = 5000,
    parameter ANGLE_FILTER     = 3,
    parameter DEADBAND         = 4,       // 度：目标航向的回差
    parameter PIVOT_ENTER      = 90,
    parameter PIVOT_CONFIRM_MS = 300,
    parameter PIVOT_EXIT       = 40,
    parameter PIVOT_PWM        = 2200,
    parameter MAX_WHEEL        = 6500,
    parameter ACC              = 200,
    parameter DEC              = 400,
    parameter TURN_SLEW        = 600,     // 转向每次最多变多少
    // ---- 角度环 ----
    parameter HEAD_KP          = 55,      // PWM / 度
    parameter HEAD_KI          = 20,      // PWM / (度 · 秒)
    parameter HEAD_KD          = 8,       // PWM / (度/秒)
    parameter HEAD_I_MAX       = 400,     // PWM
    parameter HEAD_I_ZONE      = 10,      // 度：误差在这以内才积分
    parameter TURN_MAX         = 800,     // PWM：GO 时转向最多多少
    // ---- 避障 ----
    parameter AVOID_CM         = 100,
    parameter CLEAR_CM         = 60,
    parameter SPIN_CM          = 60,
    parameter KP_OBS           = 20,      // PWM / 厘米
    parameter SPIN_PWM         = 2200,
    parameter AVOID_TURN_MAX   = 1200,    // PWM：AVD 时转向最多多少
    parameter AVOID_HOLD_CM    = 50,      // 绕完以后直走多远
    parameter CMS_FULL         = 92,      // 满量程 8000 时每秒走多少厘米（估的，只用来换算 AVOID_HOLD_CM）
    parameter W_TGT            = 2,
    parameter W_PREV           = 1,
    parameter AVOID_FAR_CM     = 200,     // 远处挡路：主人方向这么远以内有东西就提前绕（≤ AVOID_CM = 不提前绕）
    parameter OWNER_GAP_CM     = 60,      //   只算比主人近这么多的（再远的可能是主人自己）
    parameter SCAN_DEG         = 20,      // 找出口：每步转多少度（12 ~ 120）
    parameter SCAN_PAUSE_MS    = 200,     //   每步停下来看多久（PERIOD_MS ~ 127 × PERIOD_MS）
    parameter SCAN_STEP_MS     = 1000     //   一步转这么久还没转够也算一步（电机转不动 / 陀螺仪不动）（同上）
)(
    input  wire               I_clk,
    input  wire               I_rst_n,
    input  wire               I_tick_1ms,

    input  wire               I_tgt_ok,         // 主人（mc_m0_link）
    input  wire signed [7:0]  I_tgt_deg,
    input  wire [9:0]         I_tgt_cm,

    input  wire               I_obs_tog,        // 避障结果（相机像素时钟域）
    input  wire [71:0]        I_obs_free,       // 方向 4~12 各能走多远（厘米，255 = 没挡），方向 4 在 [7:0]

    input  wire               I_imu_ok,         // 陀螺仪（mc_imu_jy61p）
    input  wire signed [15:0] I_yaw,            //   航向角（65536 = 360°，右转为正）
    input  wire signed [15:0] I_gz,             //   Z 角速度原始值（32768 = 2000°/s，右转为正）

    output reg                O_cmd_valid,      // 每 PERIOD_MS 打一拍
    output reg                O_cmd_stop,
    output reg  signed [13:0] O_cmd_l,
    output reg  signed [13:0] O_cmd_r,
    output reg  [3:0]         O_state,
    output wire signed [8:0]  O_tgt_deg,        // 目标航向（度，四舍五入；停的时候 = 当时的车头），给屏幕
    output wire               O_stuck           // 困住了（转了一圈没有出口）→ 狗叫
);

localparam [3:0] M_LOST = 4'd0, M_NCAM = 4'd1, M_HERE = 4'd2, M_BLK = 4'd3, M_TURN = 4'd4, M_GO = 4'd5, M_AVD = 4'd6, M_SPIN = 4'd7, M_NIMU = 4'd8;
localparam CONF_N  = (PIVOT_CONFIRM_MS + PERIOD_MS - 1) / PERIOD_MS;   // 原地转要确认几次（经过 ≥ PIVOT_CONFIRM_MS）
localparam HOLD_Q  = AVOID_HOLD_CM * (8000000 / PERIOD_MS) / CMS_FULL; // 绕完以后直走：前进量（PWM）每次累加，加到这么多 = 走了 AVOID_HOLD_CM
localparam FAR_ANG = 3;                                                 // 远处挡路只在主人在看得到的方向里时算（离它最近的方向差 ≤ 3°）
localparam SCAN_MAX = 2 * ((360 + SCAN_DEG - 1) / SCAN_DEG);            // 找出口：转了这么多步还不够一圈（电机转不动）也算困住
localparam ROUND_BAM = 360 * 182;
localparam SCAN_BAM = SCAN_DEG * 182;
localparam PAUSE_N = SCAN_PAUSE_MS / PERIOD_MS;
localparam STEP_N  = SCAN_STEP_MS / PERIOD_MS;
localparam KIC     = (HEAD_KI * PERIOD_MS * 256 + 500) / 1000;          // 积分：每次 KIC × e16 / 16（1/256 PWM）
localparam KDC     = HEAD_KD * 4000;                                    // 微分：KDC × 角速度原始值 / 65536
localparam IMAXQ   = HEAD_I_MAX * 256;
localparam IZQ     = HEAD_I_ZONE * 16;                                  // 积分分离（1/16 度）
localparam DB_BAM  = DEADBAND * 182;                                    // 回差（航向角单位）

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
                  .I_tb (4'd0), .I_tj (4'd0), .O_thr ());

function [3:0] pref;                    // 第 k 个看的方向：8,7,9,6,10,5,11,4,12
    input [3:0] k;
    pref = k[0] ? 4'd8 - ((k + 4'd1) >> 1) : 4'd8 + (k >> 1);
endfunction

// ---- 角度换算（移位相加，不用乘法器）----
function signed [15:0] bam;             // 度（有符号）→ 航向角单位：× 182（65536 / 360 = 182.04）
    input signed [7:0] d;
    reg signed [15:0] x;
    begin
        x   = {{8{d[7]}}, d};
        bam = (x <<< 7) + (x <<< 5) + (x <<< 4) + (x <<< 2) + (x <<< 1);
    end
endfunction
function [21:0] mul45;                  // 无符号 × 45
    input [15:0] x;
    mul45 = ({6'd0, x} << 5) + ({6'd0, x} << 3) + ({6'd0, x} << 2) + {6'd0, x};
endfunction

// ---- 逐位除法器（无符号，16 位 / 8 位，16 拍）：只用来做 / ANGLE_FILTER ----
reg  [15:0] S_dq;                       // 被除数 → 逐位变成商
reg  [8:0]  S_drem;
reg  [4:0]  S_dcnt;
wire        S_dbusy = (S_dcnt != 5'd0);
wire [8:0]  S_dtry  = {S_drem[7:0], S_dq[15]};
wire        S_dge   = (S_dtry >= ANGLE_FILTER);

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
localparam [4:0] F_WAIT = 5'd0, F_FILT = 5'd1, F_FDIV = 5'd2, F_ANG0 = 5'd3, F_ANG = 5'd4, F_DEC1 = 5'd5, F_SRCH = 5'd6, F_PREP = 5'd7,
                 F_DEC2 = 5'd8, F_LIM = 5'd9, F_E = 5'd10, F_MUL = 5'd11, F_ACC = 5'd12, F_SUM = 5'd13,
                 F_SPIN = 5'd14, F_RAMP = 5'd15, F_OUT = 5'd16, F_STOP = 5'd17;
reg  [4:0]  S_f;
reg  [4:0]  S_ms;
reg         S_ok, S_fresh, S_iok;
reg  [9:0]  S_cm;
reg  [71:0] S_fl;                       // 这一次用的避障结果
reg  signed [15:0] S_yaw, S_gz;         // 这一次用的车头、角速度
reg  signed [15:0] S_mm;                // 这一次 UWB 量到的主人方向（世界）= 车头 + UWB 角度
reg         S_avalid;                   // 主人方向有效
reg  signed [15:0] S_hown;              // 主人方向（世界）
reg         S_dneg;                     // 除法结果要取负
reg  signed [8:0]  S_a;                 // 主人相对车头的角度（度，按绝对值四舍五入）
reg  [7:0]  S_aa;                       // |S_a|
reg         S_piv, S_pend;              // 正在原地转 / 超过 PIVOT_ENTER 在等确认
reg  [4:0]  S_pcnt;
reg  [3:0]  S_m;
reg  [3:0]  S_k;
reg  [7:0]  S_btd, S_btf;               // 离主人方向最近的方向：角度差、能走多远
reg         S_aok, S_bok;               // 有能走 ≥ AVOID_CM / ≥ CLEAR_CM 的方向
reg  [11:0] S_ac, S_bc;                 // 各自最小的代价
reg  signed [6:0] S_apsi, S_bpsi;      // 它的角度
reg  [7:0]  S_af, S_bf;                 // 它能走多远
reg         S_pv;                       // 上次绕行的方向有效
reg  signed [15:0] S_hprev;             // 上次绕行的方向（世界）
reg  signed [6:0]  S_ppsi;              // 它相对车头的角度（度，限在 ±63）
reg  [23:0] S_hold;                     // 绕完以后还要直走多远（前进量 × 次数，见 HOLD_Q）
reg         S_av;                       // 这一次用绕行的转向上限
reg         S_hv;                       // 目标航向有效（停车 / 原地转以后重新定）
reg  signed [15:0] S_htgt;              // 目标航向（世界）
reg  signed [15:0] S_hc;                // 选中的绕行方向（世界）
reg  [7:0]  S_tfar;                     // 远处挡路的门限 T（厘米）
reg         S_fok;                      // 有能走 ≥ T 的方向
reg  [11:0] S_fc;                       // 它们里最小的代价
reg  signed [6:0] S_fpsi;               // 它的角度
reg  [7:0]  S_ffr;                      // 它能走多远
reg  signed [15:0] S_hfar;              // 它的世界方向
reg         S_scan, S_sph, S_sdir;      // 找出口：正在找 / 停着看（0 = 转）/ 往右转
reg  [6:0]  S_scnt;                     //   这一段（停 / 转）第几次
reg  [5:0]  S_snum;                     //   转完了几步
reg  [16:0] S_stot;                     //   这次找出口一共转了多少（航向角单位）
reg  signed [15:0] S_s0;                //   这一步开始时的车头
reg         S_stuck;                    // 困住了
reg  signed [15:0] S_fwd;
reg  [7:0]  S_flim;                     // 前进上限按这个距离算
reg  [15:0] S_arelu, S_prelu, S_ebu;    // 主人 / 上次绕行方向 / 目标航向 和车头的差：绝对值
reg         S_arelneg, S_prelneg, S_ebneg;   //   符号
reg  signed [12:0] S_e16;               // 航向差（1/16 度）
reg  signed [23:0] S_p, S_di, S_iacc;   // P 项、这次积分的增量、积分累加器（1/256 PWM）
reg  signed [23:0] S_d;                 // D 项
reg  signed [15:0] S_ft, S_tt;          // 前进、转向的目标（斜坡前）
reg  signed [15:0] S_fr, S_to;          // 现在的前进、转向（斜坡后）

// 主人相对车头的角度：航向差 → 度（|差| × 45 / 8192，四舍五入）
wire signed [15:0] S_arel  = S_hown - S_yaw;
wire [21:0] S_arel45 = mul45(S_arelu) + 22'd4096;
// 上次绕行的方向相对车头的角度（度，同样四舍五入，限在 ±63：候选方向都在 ±19° 以内，超出部分只差一个常数，不改变挑选结果）
wire signed [15:0] S_prel  = S_hprev - S_yaw;
wire [21:0] S_prel45 = mul45(S_prelu) + 22'd4096;
wire [7:0]  S_pdeg  = S_prel45[20:13];
wire [5:0]  S_pd63  = (S_pdeg > 8'd63) ? 6'd63 : S_pdeg[5:0];
// 搜索：方向 S_hb 的角度、能走多远、角度差、代价
wire [7:0]  S_fb   = S_fl[8 * (S_hb - 4'd4) +: 8];
wire signed [9:0] S_d1 = $signed({{3{S_psi[6]}}, S_psi}) - $signed({S_a[8], S_a});
wire [7:0]  S_dt   = S_d1[9] ? -S_d1[7:0] : S_d1[7:0];
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
wire        S_far  = (S_btd <= FAR_ANG) && (S_btf < S_tfar);        // 远处挡路
wire [7:0]  S_fmfr = (S_f0 < S_ffr) ? S_f0 : S_ffr;               // 提前绕时：正前方和要去的方向里近的
wire [15:0] S_fru  = S_fr[15] ? 16'd0 : S_fr;                      // 上一次发出去的前进量（直走那段用来估走了多远）
// 找出口：这一步往要转的方向转了多少
wire signed [15:0] S_sd  = S_sdir ? S_yaw - S_s0 : S_s0 - S_yaw;
wire        S_sgo  = (S_sd >= SCAN_BAM);                              // 有符号比较：往反方向转的是负数，不算
wire [16:0] S_stn  = S_stot + (S_sd[15] ? 17'd0 : {1'b0, S_sd});        // 加上这一步实际转的
// 原地转的状态（这一次之后的值）
wire        S_nopiv = (!S_blk && S_hold != 24'd0) || S_scan;   // 刚绕完还在直走、找出口（困住时也还在"找出口"里）：先不原地转
reg         S_piv_n, S_pend_n;
reg  [4:0]  S_pcnt_n;
always @* begin
    S_piv_n = S_piv; S_pend_n = S_pend; S_pcnt_n = S_pcnt;
    if (!S_piv) begin
        if (S_aa <= PIVOT_ENTER)  S_pend_n = 1'b0;
        else if (!S_pend)         begin S_pend_n = 1'b1; S_pcnt_n = 5'd0; end
        else begin
            S_pcnt_n = (S_pcnt == 5'd31) ? 5'd31 : S_pcnt + 5'd1;
            if (S_pcnt_n >= CONF_N && !S_nopiv) S_piv_n = 1'b1;
        end
    end else if (S_aa < PIVOT_EXIT) begin
        S_piv_n = 1'b0; S_pend_n = 1'b0;
    end
end
// 目标航向的回差：新的方向和现在的目标差多少
wire signed [15:0] S_dgo  = S_hown - S_htgt;
wire [15:0] S_dgou = S_dgo[15] ? -S_dgo : S_dgo;
wire signed [15:0] S_dav  = S_hc - S_htgt;
wire [15:0] S_davu = S_dav[15] ? -S_dav : S_dav;
wire signed [15:0] S_dfa  = S_hfar - S_htgt;
wire [15:0] S_dfau = S_dfa[15] ? -S_dfa : S_dfa;
// 角度环
wire signed [15:0] S_eb   = S_htgt - S_yaw;
wire [21:0] S_eb45 = mul45(S_ebu);
wire signed [15:0] S_md   = S_mm - S_hown;                     // 新量到的主人方向和平滑值差多少
wire signed [23:0] S_inew = S_iacc + S_di;
wire signed [23:0] S_isum = S_p + (S_iacc >>> 8) - S_d;
wire signed [23:0] S_tmax = S_av ? AVOID_TURN_MAX : TURN_MAX;
wire signed [15:0] S_tup  = S_to + TURN_SLEW;
wire signed [15:0] S_tdn  = S_to - TURN_SLEW;

function [15:0] obs_lim;                // 前进上限：START_PWM + (f − CLEAR_CM) × KP_OBS（f < CLEAR_CM 按 CLEAR_CM 算）
    input [7:0] f;
    obs_lim = START_PWM + ((f > CLEAR_CM) ? (f - CLEAR_CM) * KP_OBS : 0);
endfunction

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        S_f <= F_WAIT; S_ms <= 5'd0; S_ok <= 1'b0; S_fresh <= 1'b0; S_iok <= 1'b0; S_cm <= 10'd0; S_fl <= {9{8'd0}};
        S_yaw <= 16'sd0; S_gz <= 16'sd0; S_mm <= 16'sd0; S_avalid <= 1'b0; S_hown <= 16'sd0; S_dneg <= 1'b0; S_a <= 9'sd0; S_aa <= 8'd0;
        S_piv <= 1'b0; S_pend <= 1'b0; S_pcnt <= 5'd0;
        S_m <= M_LOST; S_k <= 4'd0; S_hb <= 4'd8; S_btd <= 8'd255; S_btf <= 8'd0; S_bok <= 1'b0; S_bc <= 12'd4095;
        S_aok <= 1'b0; S_ac <= 12'd4095; S_apsi <= 7'sd0; S_af <= 8'd0; S_bpsi <= 7'sd0; S_bf <= 8'd0;
        S_pv <= 1'b0; S_hprev <= 16'sd0; S_ppsi <= 7'sd0; S_hold <= 24'd0; S_av <= 1'b0; S_hv <= 1'b0; S_htgt <= 16'sd0; S_hc <= 16'sd0;
        S_tfar <= 8'd0; S_fok <= 1'b0; S_fc <= 12'd4095; S_fpsi <= 7'sd0; S_ffr <= 8'd0; S_hfar <= 16'sd0;
        S_scan <= 1'b0; S_sph <= 1'b0; S_sdir <= 1'b0; S_scnt <= 7'd0; S_snum <= 6'd0; S_stot <= 17'd0; S_s0 <= 16'sd0; S_stuck <= 1'b0;
        S_fwd <= 16'sd0; S_flim <= 8'd0; S_arelu <= 16'd0; S_prelu <= 16'd0; S_ebu <= 16'd0; S_arelneg <= 1'b0; S_prelneg <= 1'b0; S_ebneg <= 1'b0; S_e16 <= 13'sd0; S_p <= 24'sd0; S_di <= 24'sd0; S_iacc <= 24'sd0; S_d <= 24'sd0;
        S_ft <= 16'sd0; S_tt <= 16'sd0; S_fr <= 16'sd0; S_to <= 16'sd0;
        S_dq <= 16'd0; S_drem <= 9'd0; S_dcnt <= 5'd0;
        O_cmd_valid <= 1'b0; O_cmd_stop <= 1'b1; O_cmd_l <= 14'sd0; O_cmd_r <= 14'sd0; O_state <= M_LOST;
    end else begin
        O_cmd_valid <= 1'b0;
        if (S_dbusy) begin                                            // 除法器每拍出一位商
            S_drem <= S_dge ? S_dtry - ANGLE_FILTER : S_dtry;
            S_dq   <= {S_dq[14:0], S_dge};
            S_dcnt <= S_dcnt - 5'd1;
        end
        case (S_f)
            F_WAIT: if (I_tick_1ms) begin
                        if (S_ms == PERIOD_MS - 1) begin
                            S_ms <= 5'd0;
                            S_ok <= I_tgt_ok; S_cm <= I_tgt_cm;
                            S_fresh <= (S_oage != OBS_TIMEOUT_MS); S_fl <= S_free;
                            S_iok <= I_imu_ok; S_yaw <= I_yaw; S_gz <= I_gz; S_mm <= I_yaw + bam(I_tgt_deg);
                            S_f <= F_FILT;
                        end else S_ms <= S_ms + 5'd1;
                    end
            F_FILT: begin                                             // 1. 主人方向（世界）平滑
                        if (!S_ok)            begin S_avalid <= 1'b0; S_m <= M_LOST; S_f <= F_STOP; end
                        else if (!S_iok)      begin S_avalid <= 1'b0; S_m <= M_NIMU; S_f <= F_STOP; end
                        else if (!S_avalid)   begin S_hown <= S_mm; S_avalid <= 1'b1; S_f <= F_ANG0; end
                        else begin
                            S_dq <= S_md[15] ? -S_md : S_md; S_dneg <= S_md[15];
                            S_drem <= 9'd0; S_dcnt <= 5'd16; S_f <= F_FDIV;
                        end
                    end
            F_FDIV: if (!S_dbusy) begin
                        S_hown <= S_dneg ? S_hown - $signed(S_dq) : S_hown + $signed(S_dq);
                        S_f <= F_ANG0;
                    end
            F_ANG0: begin                                             // 主人、上次绕行方向和车头的差（绝对值、符号）
                        S_arelu <= S_arel[15] ? -S_arel : S_arel; S_arelneg <= S_arel[15];
                        S_prelu <= S_prel[15] ? -S_prel : S_prel; S_prelneg <= S_prel[15];
                        S_f <= F_ANG;
                    end
            F_ANG:  begin                                             // → 相对车头的度数（四舍五入）
                        S_aa <= S_arel45[20:13];
                        S_a  <= S_arelneg ? -$signed({1'b0, S_arel45[20:13]}) : $signed({1'b0, S_arel45[20:13]});
                        S_ppsi <= S_prelneg ? -$signed({1'b0, S_pd63}) : $signed({1'b0, S_pd63});
                        S_f <= F_DEC1;
                    end
            F_DEC1: begin                                             // 2. 停的条件
                        if (!S_fresh)             begin S_m <= M_NCAM; S_f <= F_STOP; end
                        else if (S_cm <= STOP_CM) begin S_m <= M_HERE; S_f <= F_STOP; end
                        else begin                                    // 3. 往前走：先搜 9 个方向
                            S_fwd <= ((START_PWM + (S_cm - STOP_CM) * KP_D) > MAX_FWD) ? MAX_FWD : START_PWM + (S_cm - STOP_CM) * KP_D;
                            S_tfar <= (S_cm < OWNER_GAP_CM) ? 8'd0 : ((S_cm - OWNER_GAP_CM) > AVOID_FAR_CM) ? AVOID_FAR_CM : S_cm - OWNER_GAP_CM;
                            S_k <= 4'd0; S_hb <= pref(4'd0); S_btd <= 8'd255; S_btf <= 8'd0;
                            S_aok <= 1'b0; S_ac <= 12'd4095; S_bok <= 1'b0; S_bc <= 12'd4095; S_fok <= 1'b0; S_fc <= 12'd4095;
                            S_f <= F_SRCH;
                        end
                    end
            F_SRCH: begin                                             // 9 拍：离主人最近的方向；能走的方向里代价最小的
                        if (S_dt < S_btd) begin S_btd <= S_dt; S_btf <= S_fb; end
                        if (S_fb >= AVOID_CM && S_cost < S_ac) begin S_ac <= S_cost; S_aok <= 1'b1; S_apsi <= S_psi; S_af <= S_fb; end
                        if (S_fb >= CLEAR_CM && S_cost < S_bc) begin S_bc <= S_cost; S_bok <= 1'b1; S_bpsi <= S_psi; S_bf <= S_fb; end
                        if (S_fb >= S_tfar   && S_cost < S_fc) begin S_fc <= S_cost; S_fok <= 1'b1; S_fpsi <= S_psi; S_ffr <= S_fb; end
                        if (S_k == 4'd8) S_f <= F_PREP;
                        else begin S_k <= S_k + 4'd1; S_hb <= pref(S_k + 4'd1); end
                    end
            F_PREP: begin                                             // 绕行方向换成世界方向
                        S_hc   <= S_yaw + bam({S_cpsi[6], S_cpsi});
                        S_hfar <= S_yaw + bam({S_fpsi[6], S_fpsi});
                        S_f <= F_DEC2;
                    end
            F_DEC2: begin                                             // 原地转向主人、挡不挡路、目标航向
                        S_piv <= S_piv_n; S_pend <= S_pend_n; S_pcnt <= S_pcnt_n;
                        if (S_piv_n) begin
                            S_m <= M_TURN; S_f <= F_SPIN;
                        end else if (!S_blk) begin
                            S_scan <= 1'b0; S_stuck <= 1'b0;
                            if (S_hold != 24'd0) begin                // 刚绕完：保持航向直走，走够 AVOID_HOLD_CM
                                S_m <= M_AVD; S_av <= 1'b1; S_hold <= (S_hold > {8'd0, S_fru}) ? S_hold - {8'd0, S_fru} : 24'd0;
                                if (!S_hv) begin S_htgt <= S_yaw; S_hv <= 1'b1; end
                                S_flim <= S_fmin;
                            end else if (S_far && S_fok) begin        // 远处挡路：提前绕
                                S_m <= M_AVD; S_av <= 1'b1; S_hprev <= S_hfar; S_pv <= 1'b1;
                                if (!S_hv || S_dfau > DB_BAM) begin S_htgt <= S_hfar; S_hv <= 1'b1; end
                                S_flim <= S_fmfr;
                            end else begin
                                S_m <= M_GO; S_av <= 1'b0; S_pv <= 1'b0;
                                if (!S_hv || S_dgou > DB_BAM) begin S_htgt <= S_hown; S_hv <= 1'b1; end
                                S_flim <= S_fmin;
                            end
                            S_f <= F_LIM;
                        end else if (!S_bok) begin                    // 哪边都不到 CLEAR_CM：找出口
                            if (S_stuck) begin
                                S_m <= M_BLK; S_f <= F_STOP;
                            end else if (!S_scan) begin               // 开始：先停下看
                                S_scan <= 1'b1; S_sph <= 1'b1; S_scnt <= 7'd0; S_snum <= 6'd0; S_stot <= 17'd0; S_s0 <= S_yaw; S_sdir <= ~S_a[8];
                                S_m <= M_BLK; S_f <= F_STOP;
                            end else if (S_sph) begin                 // 停着看
                                if (S_scnt != PAUSE_N - 1) begin S_scnt <= S_scnt + 7'd1; S_m <= M_BLK; S_f <= F_STOP; end
                                else if (S_stn >= ROUND_BAM || S_snum == SCAN_MAX) begin S_stuck <= 1'b1; S_m <= M_BLK; S_f <= F_STOP; end
                                else begin S_stot <= S_stn; S_sph <= 1'b0; S_scnt <= 7'd0; S_s0 <= S_yaw; S_m <= M_SPIN; S_f <= F_SPIN; end
                            end else begin                            // 转：转够了（或者转太久）就停下看
                                if (S_sgo || S_scnt == STEP_N - 1) begin S_snum <= S_snum + 6'd1; S_sph <= 1'b1; S_scnt <= 7'd0; S_m <= M_BLK; S_f <= F_STOP; end
                                else begin S_scnt <= S_scnt + 7'd1; S_m <= M_SPIN; S_f <= F_SPIN; end
                            end
                        end else begin
                            S_scan <= 1'b0; S_stuck <= 1'b0;
                            S_hprev <= S_hc; S_pv <= 1'b1; S_hold <= HOLD_Q;
                            if (S_f0 < SPIN_CM) begin S_m <= M_SPIN; S_htgt <= S_hc; S_hv <= 1'b0; S_f <= F_SPIN; end
                            else begin
                                S_m <= M_AVD; S_av <= 1'b1;
                                if (!S_hv || S_davu > DB_BAM) begin S_htgt <= S_hc; S_hv <= 1'b1; end
                                S_flim <= S_fmav; S_f <= F_LIM;
                            end
                        end
                    end
            F_LIM:  begin                                             // 前进不超过避障的上限
                        if (obs_lim(S_flim) < S_fwd) S_fwd <= obs_lim(S_flim);
                        S_ebu <= S_eb[15] ? -S_eb : S_eb; S_ebneg <= S_eb[15];          // 目标航向和车头的差
                        S_f <= F_E;
                    end
            F_E:    begin                                             // 4. 角度环：航向差（1/16 度，向下取整）
                        S_e16 <= S_ebneg ? -$signed({1'b0, S_eb45[20:9]}) - ((S_eb45[8:0] != 9'd0) ? 13'sd1 : 13'sd0)
                                          :  $signed({1'b0, S_eb45[20:9]});
                        S_f <= F_MUL;
                    end
            F_MUL:  begin
                        S_p  <= (S_e16 * HEAD_KP) >>> 4;
                        S_di <= (S_e16 * KIC) >>> 4;
                        S_d  <= (S_gz * KDC) >>> 16;
                        S_f <= F_ACC;
                    end
            F_ACC:  begin                                             // 积分（积分分离、限幅）
                        if (S_e16 <= IZQ && S_e16 >= -IZQ) S_iacc <= (S_inew > IMAXQ) ? IMAXQ : (S_inew < -IMAXQ) ? -IMAXQ : S_inew;
                        S_f <= F_SUM;
                    end
            F_SUM:  begin                                             // 转向目标（限幅）、前进目标
                        S_tt <= (S_isum > S_tmax) ? S_tmax[15:0] : (S_isum < -S_tmax) ? -S_tmax[15:0] : S_isum[15:0];
                        S_ft <= S_fwd;
                        S_f <= F_RAMP;
                    end
            F_SPIN: begin                                             // 原地转（TURN：朝主人；SPIN：朝能走的方向 / 找出口时往定好的那边）
                        S_iacc <= 24'sd0; S_hv <= 1'b0;
                        S_pv <= (S_m == M_SPIN) ? S_pv : 1'b0; S_hold <= (S_m == M_SPIN) ? S_hold : 24'd0;
                        if (S_m == M_TURN) S_htgt <= S_hown;
                        S_ft <= 16'sd0;
                        if ((S_m == M_TURN) ? (S_a > 9'sd0) : S_bok ? (S_cpsi > 7'sd0) : S_sdir) S_tt <= (S_m == M_TURN) ?  PIVOT_PWM :  SPIN_PWM;
                        else                                                                     S_tt <= (S_m == M_TURN) ? -PIVOT_PWM : -SPIN_PWM;
                        S_f <= F_RAMP;
                    end
            F_RAMP: begin                                             // 5. 前进走斜坡、转向限速
                        S_fr <= ramp(S_fr, S_ft);
                        S_to <= (S_tt > S_tup) ? S_tup : (S_tt < S_tdn) ? S_tdn : S_tt;
                        S_f <= F_OUT;
                    end
            F_OUT: begin                                              // 两轮 = 前进 ± 转向（限幅），发出去
                        O_cmd_valid <= 1'b1; O_cmd_stop <= 1'b0; O_state <= S_m;
                        O_cmd_l <= clampw(S_fr + S_to); O_cmd_r <= clampw(S_fr - S_to);
                        S_f <= F_WAIT;
                    end
            F_STOP: begin                                             // 停：命令直接归 0，绕行的记忆、积分清掉，目标航向 = 现在的车头；不是找出口（BLK）的停，找出口也作废
                        S_fr <= 16'sd0; S_to <= 16'sd0; S_pv <= 1'b0; S_hold <= 24'd0; S_hv <= 1'b0; S_iacc <= 24'sd0; S_htgt <= S_yaw;
                        if (S_m != M_BLK) begin S_scan <= 1'b0; S_stuck <= 1'b0; end
                        O_cmd_valid <= 1'b1; O_cmd_stop <= 1'b1; O_cmd_l <= 14'sd0; O_cmd_r <= 14'sd0; O_state <= S_m;
                        S_f <= F_WAIT;
                    end
            default: S_f <= F_WAIT;
        endcase
    end
end

// ---- 屏幕：目标航向（度，四舍五入）= × 45 / 8192 ----
wire signed [22:0] S_t45 = ($signed({{7{S_htgt[15]}}, S_htgt}) <<< 5) + ($signed({{7{S_htgt[15]}}, S_htgt}) <<< 3) +
                           ($signed({{7{S_htgt[15]}}, S_htgt}) <<< 2) +  $signed({{7{S_htgt[15]}}, S_htgt});
wire signed [22:0] S_tr45 = S_t45 + 23'sd4096;
assign O_tgt_deg = S_tr45[21:13];
assign O_stuck   = S_stuck;

endmodule
