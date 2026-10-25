`timescale 1ns / 1ps
// 测试 mc_follow（跟随 + 避障决策）。
//   测试台自己的模型 = STM32 follow.c 逐行照搬（C 的整数除法向 0 取整，Verilog 的整数 / 也是）+ obstacle.md §6 的避障规格，
//   每个 20 ms 周期和 RTL 的命令逐个比较：停 / 左右轮 / 状态；两次命令之间正好 20 个节拍。
//   没有障碍时模型就是 follow.c 本身 → RTL 和 STM32 的跟随测试模式输出一模一样。
//   两个实例：默认参数（= STM32 follow.h + 避障默认值）和一组全都不一样的参数（每个参数都要真的接进去）。
//   避障结果由另一个时钟（111 MHz）送：每 5 个节拍翻转一次，数据保持不变；"相机断了"就不翻转。
//   场景：LOST / NCAM / GO（平滑、死区、转向限速、远处限幅）/ HERE 边界 / 原地转（确认时间、迟滞、角度跳一下）/
//         正前方挡、主人方向挡、只剩 ≥ CLEAR 的方向、全挡（BLK）、太近原地转（SPIN）、绕完直走（hold）、
//         绕行不来回换边（上次方向的代价）、前面有东西就慢、原地转优先、丢了 UWB 再找回（平滑重来）。
//   边界：正好 90° / 正好 SPIN / 正好 AVOID / 正好 CLEAR、主人正好在两个方向中间、退一步挑时平局、负角度的截断、
//         相机停的时候翻转信号是 1、相机断了 + 主人很近、退出原地转后马上又超过、GO / TURN 以后旧的绕行方向作废、负向限幅。
module tb_follow;

reg clk = 0, oclk = 0;
always #5 clk = ~clk;
always #4.49 oclk = ~oclk;
reg rst_n = 0;
reg tick = 0;

reg               tgt_ok = 0;
reg signed [7:0]  tgt_deg = 0;
reg [9:0]         tgt_cm = 0;
reg               otog = 0;
reg [71:0]        ofree = {9{8'd255}};

wire              v0, s0, v1, s1;
wire signed [13:0] l0, r0, l1, r1;
wire [2:0]        st0, st1;

mc_follow d0 (.I_clk(clk), .I_rst_n(rst_n), .I_tick_1ms(tick), .I_tgt_ok(tgt_ok), .I_tgt_deg(tgt_deg), .I_tgt_cm(tgt_cm),
              .I_obs_tog(otog), .I_obs_free(ofree), .O_cmd_valid(v0), .O_cmd_stop(s0), .O_cmd_l(l0), .O_cmd_r(r0), .O_state(st0));
mc_follow #(
    .STOP_CM(250), .START_PWM(2500), .KP_D(20), .MAX_FWD(6400), .ANGLE_FILTER(4), .DEADBAND(2),
    .TURN_PER10K(100), .TURN_MAX_10K(3000), .TURN_STEP(50), .PIVOT_ENTER(60), .PIVOT_CONFIRM_MS(200), .PIVOT_EXIT(30),
    .PIVOT_PWM(3000), .MAX_WHEEL(6000), .ACC(300), .DEC(500),
    .AVOID_CM(120), .CLEAR_CM(70), .SPIN_CM(50), .KP_OBS(30), .SPIN_PWM(6500),
    .AVOID_PER10K(200), .AVOID_MAX_10K(2500), .AVOID_STEP(80), .AVOID_HOLD_MS(300), .W_TGT(3), .W_PREV(2)
) d1 (.I_clk(clk), .I_rst_n(rst_n), .I_tick_1ms(tick), .I_tgt_ok(tgt_ok), .I_tgt_deg(tgt_deg), .I_tgt_cm(tgt_cm),
              .I_obs_tog(otog), .I_obs_free(ofree), .O_cmd_valid(v1), .O_cmd_stop(s1), .O_cmd_l(l1), .O_cmd_r(r1), .O_state(st1));

integer errors = 0;
always @(errors) if (errors > 20) begin #1; $display("FAIL  tb_follow: too many errors"); $finish; end

// ---------------- 参数（两个实例）----------------
integer P_STOP [0:1], P_START [0:1], P_KPD [0:1], P_MAXF [0:1], P_AF [0:1], P_DB [0:1], P_TP [0:1], P_TMAX [0:1], P_TSTEP [0:1];
integer P_PIN [0:1], P_PCONF [0:1], P_POUT [0:1], P_PPWM [0:1], P_MAXW [0:1], P_ACC [0:1], P_DEC [0:1];
integer P_AVOID [0:1], P_CLEAR [0:1], P_SPIN [0:1], P_KPO [0:1], P_SPWM [0:1], P_AP [0:1], P_AMAX [0:1], P_ASTEP [0:1], P_HOLD [0:1], P_WT [0:1], P_WP [0:1];
task set_params;
    begin
        P_STOP[0] = 300; P_START[0] = 3000; P_KPD[0] = 10; P_MAXF[0] = 5000; P_AF[0] = 3; P_DB[0] = 5; P_TP[0] = 30; P_TMAX[0] = 900; P_TSTEP[0] = 12;
        P_PIN[0] = 90; P_PCONF[0] = 300; P_POUT[0] = 40; P_PPWM[0] = 2200; P_MAXW[0] = 6500; P_ACC[0] = 200; P_DEC[0] = 400;
        P_AVOID[0] = 100; P_CLEAR[0] = 60; P_SPIN[0] = 45; P_KPO[0] = 20; P_SPWM[0] = 2200; P_AP[0] = 120; P_AMAX[0] = 3000; P_ASTEP[0] = 40;
        P_HOLD[0] = 500; P_WT[0] = 2; P_WP[0] = 1;
        P_STOP[1] = 250; P_START[1] = 2500; P_KPD[1] = 20; P_MAXF[1] = 6400; P_AF[1] = 4; P_DB[1] = 2; P_TP[1] = 100; P_TMAX[1] = 3000; P_TSTEP[1] = 50;
        P_PIN[1] = 60; P_PCONF[1] = 200; P_POUT[1] = 30; P_PPWM[1] = 3000; P_MAXW[1] = 6000; P_ACC[1] = 300; P_DEC[1] = 500;
        P_AVOID[1] = 120; P_CLEAR[1] = 70; P_SPIN[1] = 50; P_KPO[1] = 30; P_SPWM[1] = 6500; P_AP[1] = 200; P_AMAX[1] = 2500; P_ASTEP[1] = 80;
        P_HOLD[1] = 300; P_WT[1] = 3; P_WP[1] = 2;
    end
endtask

// ---------------- 模型 ----------------
integer HEAD_DEG [0:15];
// follow.c 的状态（每个实例一份）
integer avalid [0:1], x16 [0:1], piv [0:1], pend [0:1], since [0:1], turn [0:1], cl [0:1], cr [0:1];
// 避障加的状态
integer pv [0:1], ppsi [0:1], hold [0:1];
integer age;                              // 避障结果的"年龄"（节拍）
integer nper = 0;                         // 第几个 20 ms 周期
integer e_stop [0:1], e_l [0:1], e_r [0:1], e_st [0:1];
integer cnt [0:7];                        // 默认实例各状态出现的次数
integer c_tie, c_hyst, c_fallback, c_lim, c_dead, c_step, c_clampw, c_pend_reset, c_reacq;
// 边界场景（默认实例，另一组只记负向限幅）：正好 90° / 正好 SPIN / 选中的方向正好 AVOID / 正好 CLEAR、离主人最近的方向平局且一挡一不挡、
// 退一步挑时平局、按主人方向（不是正前方）限速、hold 时按绕行方向限速会不一样、负角度带小数（截断 ≠ 向下取整）、
// 相机断了 + 主人很近、找回时角度变号、退出原地转后直接重新等确认、GO / TURN 之后旧的绕行方向会改变选择、负向限幅
integer c_e_piv, c_e_spin, c_e_avoid, c_e_clear, c_ntie, c_btie, c_slim, c_hlim, c_frac, c_ncam_near, c_flip, c_reenter, c_stale_go, c_stale_turn, c_clampn;
integer lastm [0:1], exitp [0:1];         // 上一次的状态；刚退出原地转、还没回到 PIVOT_ENTER 以内

function integer iabs; input integer x; iabs = (x < 0) ? -x : x; endfunction
function integer imin; input integer a, b; imin = (a < b) ? a : b; endfunction
function integer clampw; input integer v, m; clampw = (v > m) ? m : (v < -m) ? -m : v; endfunction
function integer ramp;                    // follow.c Follow_RampCommand
    input integer cur, tgt, acc, dec;
    integer st;
    begin
        st = (iabs(tgt) < iabs(cur)) ? dec : acc;
        ramp = (tgt - cur > st) ? cur + st : (tgt - cur < -st) ? cur - st : tgt;
    end
endfunction
function integer fr; input integer b; fr = ofree[8*(b-4) +: 8]; endfunction
function integer pref; input integer k; pref = (k % 2 == 0) ? 8 + k / 2 : 8 - (k + 1) / 2; endfunction

task stop_it;                             // Follow_StopImmediately + 避障记忆清掉
    input integer i, m;
    begin cl[i] = 0; cr[i] = 0; turn[i] = 0; pv[i] = 0; hold[i] = 0; e_stop[i] = 1; e_st[i] = m; end
endtask

task decide;
    integer i, m, a, aa, fwd, k, b, psi, f, dt, cost, btd, btf, aok, ac, apsi, af, bok, bc, bpsi, bf, cpsi, cf, f0, blk, av, err, flim, lim;
    integer ea, db, per, t, stp, tl, tr, raw16, c9_7, c9_9, btc, lim2;
    begin
        nper = nper + 1;
        for (i = 0; i < 2; i = i + 1) begin
            e_stop[i] = 0; tl = 0; tr = 0; m = 5;
            if (!tgt_ok) begin
                avalid[i] = 0; stop_it(i, 0);
            end else begin
                raw16 = tgt_deg * 16;
                if (!avalid[i]) begin
                    if (i == 0 && nper > 1) begin
                        c_reacq = c_reacq + 1;
                        if ((x16[i] > 0) != (raw16 > 0) && iabs(raw16 - x16[i]) >= 48) c_flip = c_flip + 1;
                    end
                    x16[i] = raw16; avalid[i] = 1;
                end
                else x16[i] = x16[i] + (raw16 - x16[i]) / P_AF[i];
                a = x16[i] / 16;
                if (age >= 100) begin stop_it(i, 1); if (i == 0 && tgt_cm <= P_STOP[i]) c_ncam_near = c_ncam_near + 1; end
                else if (tgt_cm <= P_STOP[i]) stop_it(i, 2);
                else begin
                    aa = iabs(a);
                    // follow.c：超过 PIVOT_ENTER 要保持 PIVOT_CONFIRM_MS（这里按周期算时间）才原地转，回到 PIVOT_EXIT 以内退出
                    if (!piv[i]) begin
                        if (i == 0 && aa == P_PIN[i]) c_e_piv = c_e_piv + 1;
                        if (aa <= P_PIN[i]) begin if (pend[i] && i == 0) c_pend_reset = c_pend_reset + 1; pend[i] = 0; exitp[i] = 0; end
                        else if (!pend[i]) begin pend[i] = 1; since[i] = nper; if (exitp[i] && i == 0) c_reenter = c_reenter + 1; exitp[i] = 0; end
                        else if ((nper - since[i]) * 20 >= P_PCONF[i]) piv[i] = 1;
                    end else if (aa < P_POUT[i]) begin piv[i] = 0; pend[i] = 0; exitp[i] = 1; end
                    if (piv[i]) begin
                        m = 4; turn[i] = 0; pv[i] = 0; hold[i] = 0;
                        tl = (a > 0) ? P_PPWM[i] : -P_PPWM[i]; tr = -tl;
                    end else begin
                        fwd = P_START[i] + (tgt_cm - P_STOP[i]) * P_KPD[i];
                        if (fwd > P_MAXF[i]) fwd = P_MAXF[i];
                        // 9 个方向：离主人最近的；能走 ≥ AVOID / ≥ CLEAR 的里代价最小的
                        btd = 1000; btf = 0; aok = 0; ac = 1000000; bok = 0; bc = 1000000; apsi = 0; af = 0; bpsi = 0; bf = 0; btc = -1;
                        for (k = 0; k < 9; k = k + 1) begin
                            b = pref(k); psi = HEAD_DEG[b]; f = fr(b);
                            dt = iabs(psi - a);
                            if (dt == btd && i == 0 && ((f < P_AVOID[i]) != (btf < P_AVOID[i]))) c_ntie = c_ntie + 1;
                            if (dt < btd) begin btd = dt; btf = f; end
                            cost = P_WT[i] * dt + (pv[i] ? P_WP[i] * iabs(psi - ppsi[i]) : 0);
                            if (f >= P_AVOID[i] && cost == ac && i == 0) c_tie = c_tie + 1;
                            if (f >= P_CLEAR[i] && cost == bc) btc = cost;
                            if (f >= P_AVOID[i] && cost < ac) begin ac = cost; aok = 1; apsi = psi; af = f; end
                            if (f >= P_CLEAR[i] && cost < bc) begin bc = cost; bok = 1; bpsi = psi; bf = f; end
                        end
                        cpsi = aok ? apsi : bpsi; cf = aok ? af : bf;
                        if (i == 0 && !aok && bok) c_fallback = c_fallback + 1;
                        f0 = fr(8);
                        blk = (f0 < P_AVOID[i]) || (btf < P_AVOID[i]);
                        if (i == 0 && blk && bok) begin
                            if (f0 == P_SPIN[i])               c_e_spin  = c_e_spin + 1;
                            if (aok && af == P_AVOID[i])       c_e_avoid = c_e_avoid + 1;
                            if (!aok && bf == P_CLEAR[i])      c_e_clear = c_e_clear + 1;
                            if (!aok && btc == bc && !pv[i])   c_btie    = c_btie + 1;
                        end
                        av = 0; err = 0; flim = 255;
                        if (!blk) begin
                            if (hold[i] > 0) begin m = 6; av = 1; err = 0; hold[i] = hold[i] - 1; end
                            else begin m = 5; av = 0; err = a; pv[i] = 0; end
                            flim = imin(f0, btf);
                        end else if (!bok) begin
                            m = 3;
                        end else begin
                            // 绕行的选择要是没有"上次方向"那一项会换边：记一次
                            if (i == 0 && pv[i]) begin
                                c9_7 = 1000000; c9_9 = 0;
                                for (k = 0; k < 9; k = k + 1) begin
                                    b = pref(k); f = fr(b); dt = P_WT[i] * iabs(HEAD_DEG[b] - a);
                                    if (f >= (aok ? P_AVOID[i] : P_CLEAR[i]) && dt < c9_7) begin c9_7 = dt; c9_9 = HEAD_DEG[b]; end
                                end
                                if (c9_9 != cpsi) c_hyst = c_hyst + 1;
                            end
                            // 上一次是 GO / TURN（绕行记忆清掉了）：要是还按旧的绕行方向算，会选别的方向
                            if (i == 0 && !pv[i] && (lastm[i] == 5 || lastm[i] == 4)) begin
                                c9_7 = 1000000; c9_9 = 0;
                                for (k = 0; k < 9; k = k + 1) begin
                                    b = pref(k); f = fr(b); dt = P_WT[i] * iabs(HEAD_DEG[b] - a) + P_WP[i] * iabs(HEAD_DEG[b] - ppsi[i]);
                                    if (f >= (aok ? P_AVOID[i] : P_CLEAR[i]) && dt < c9_7) begin c9_7 = dt; c9_9 = HEAD_DEG[b]; end
                                end
                                if (c9_9 != cpsi) begin if (lastm[i] == 5) c_stale_go = c_stale_go + 1; else c_stale_turn = c_stale_turn + 1; end
                            end
                            ppsi[i] = cpsi; pv[i] = 1; hold[i] = P_HOLD[i] / 20;
                            if (f0 < P_SPIN[i]) begin
                                m = 7; turn[i] = 0;
                                tl = (cpsi > 0) ? P_SPWM[i] : -P_SPWM[i]; tr = -tl;
                            end else begin
                                m = 6; av = 1; err = cpsi; flim = imin(f0, cf);
                            end
                        end
                        if (m == 3) stop_it(i, 3);
                        else if (m == 5 || m == 6) begin
                            lim = P_START[i] + ((flim > P_CLEAR[i]) ? (flim - P_CLEAR[i]) * P_KPO[i] : 0);
                            if (i == 0 && !blk) begin
                                if (btf < f0 && lim < fwd) c_slim = c_slim + 1;
                                lim2 = imin(f0, cf); lim2 = P_START[i] + ((lim2 > P_CLEAR[i]) ? (lim2 - P_CLEAR[i]) * P_KPO[i] : 0);
                                if (imin(lim, fwd) != imin(lim2, fwd)) c_hlim = c_hlim + 1;
                            end
                            if (lim < fwd) begin fwd = lim; if (i == 0) c_lim = c_lim + 1; end
                            ea = iabs(err); db = av ? 0 : P_DB[i];
                            if (ea > db) begin
                                per = (ea - db) * (av ? P_AP[i] : P_TP[i]);
                                if (per > (av ? P_AMAX[i] : P_TMAX[i])) per = av ? P_AMAX[i] : P_TMAX[i];
                                t = fwd * per / 10000;
                                if (err < 0) t = -t;
                            end else begin t = 0; if (i == 0 && err != 0) c_dead = c_dead + 1; end
                            stp = av ? P_ASTEP[i] : P_TSTEP[i];
                            if (i == 0 && m == 5 && x16[i] < 0 && x16[i] % 16 != 0 && ea > db && t >= turn[i] - stp && t <= turn[i] + stp) c_frac = c_frac + 1;
                            if (t > turn[i] + stp)      begin t = turn[i] + stp; if (i == 0) c_step = c_step + 1; end
                            else if (t < turn[i] - stp) begin t = turn[i] - stp; if (i == 0) c_step = c_step + 1; end
                            turn[i] = t;
                            tl = fwd + t; tr = fwd - t;
                        end
                    end
                    if (!e_stop[i]) begin
                        if ((tl > P_MAXW[i] || tl < -P_MAXW[i] || tr > P_MAXW[i] || tr < -P_MAXW[i]) && i == 1) c_clampw = c_clampw + 1;
                                                cl[i] = ramp(cl[i], clampw(tl, P_MAXW[i]), P_ACC[i], P_DEC[i]);
                        cr[i] = ramp(cr[i], clampw(tr, P_MAXW[i]), P_ACC[i], P_DEC[i]);
                        if (i == 1 && ((tl < -P_MAXW[i] && cl[i] == -P_MAXW[i]) || (tr < -P_MAXW[i] && cr[i] == -P_MAXW[i]))) c_clampn = c_clampn + 1;   // 斜坡走到了负向限幅
                        e_st[i] = m;
                    end
                end
            end
            e_l[i] = cl[i]; e_r[i] = cr[i]; lastm[i] = e_st[i];
            if (i == 0) cnt[e_st[0]] = cnt[e_st[0]] + 1;
        end
    end
endtask

// ---------------- 节拍 + 避障结果 ----------------
localparam TICK = 200;                    // 一个"毫秒"节拍 = 200 个时钟（仿真加速）
integer ntick = 0;
reg     cam_on = 0;
integer pending = 0, pending1 = 0;
integer last_cmd_tick = -1;
task one_tick;
    begin
        repeat (TICK - 1) @(posedge clk);
        @(posedge clk) tick <= 1'b1;
        @(posedge clk) tick <= 1'b0;
        ntick = ntick + 1;
        if (ntick % 20 == 0) begin decide; pending = 1; pending1 = 1; end
        if (age < 100) age = age + 1;
        if (cam_on && ntick % 5 == 0) begin
            repeat (10) @(posedge clk);
            @(posedge oclk) otog <= ~otog;
            age = 0;
        end
    end
endtask

always @(posedge clk) if (v0) begin
    if (!pending) begin $display("FAIL command without a decision tick (tick %0d)", ntick); errors = errors + 1; end
    if (last_cmd_tick >= 0 && ntick - last_cmd_tick != 20) begin $display("FAIL commands %0d ticks apart", ntick - last_cmd_tick); errors = errors + 1; end
    last_cmd_tick = ntick;
    pending = 0;
    if (s0 !== e_stop[0][0] || l0 !== e_l[0] || r0 !== e_r[0] || st0 !== e_st[0]) begin
        $display("FAIL [default] period %0d: stop %b L %0d R %0d state %0d, expected %0d %0d %0d %0d (ok %b deg %0d cm %0d age %0d)",
                 nper, s0, l0, r0, st0, e_stop[0], e_l[0], e_r[0], e_st[0], tgt_ok, tgt_deg, tgt_cm, age);
        errors = errors + 1;
    end
end
always @(posedge clk) if (v1) begin                     // 第二个实例：状态机走的路不一样长，命令可能晚几拍
    if (!pending1) begin $display("FAIL [other] command without a decision tick (tick %0d)", ntick); errors = errors + 1; end
    pending1 = 0;
    if (s1 !== e_stop[1][0] || l1 !== e_l[1] || r1 !== e_r[1] || st1 !== e_st[1]) begin
        $display("FAIL [other] period %0d: stop %b L %0d R %0d state %0d, expected %0d %0d %0d %0d",
                 nper, s1, l1, r1, st1, e_stop[1], e_l[1], e_r[1], e_st[1]);
        errors = errors + 1;
    end
end

task periods; input integer n; integer t; for (t = 0; t < n * 20; t = t + 1) one_tick; endtask
task set_free;                            // 方向 4~12 的"能走多远"
    input [7:0] f4, f5, f6, f7, f8, f9, f10, f11, f12;
    ofree = {f12, f11, f10, f9, f8, f7, f6, f5, f4};
endtask
task all_free; set_free(255, 255, 255, 255, 255, 255, 255, 255, 255); endtask
task lose; begin tgt_ok = 0; periods(1); tgt_ok = 1; end endtask   // 丢一个周期，调用的人再给新角度（找回时直接用新角度）

// ---------------- 场景 ----------------
real PI, F, ct;
integer b, i;
initial begin
    PI = 3.14159265358979; F = 960.0 / $tan(36.0 * PI / 180.0); ct = $cos(15.0 * PI / 180.0);
    for (b = 0; b < 16; b = b + 1) HEAD_DEG[b] = $rtoi($atan((120.0 * b - 960.0) * ct / F) * 180.0 / PI + ((b >= 8) ? 0.5 : -0.5));
    set_params;
    for (i = 0; i < 2; i = i + 1) begin avalid[i] = 0; x16[i] = 0; piv[i] = 0; pend[i] = 0; since[i] = 0; turn[i] = 0; cl[i] = 0; cr[i] = 0; pv[i] = 0; ppsi[i] = 0; hold[i] = 0; lastm[i] = 0; exitp[i] = 0; end
    for (i = 0; i < 8; i = i + 1) cnt[i] = 0;
    c_tie = 0; c_hyst = 0; c_fallback = 0; c_lim = 0; c_dead = 0; c_step = 0; c_clampw = 0; c_pend_reset = 0; c_reacq = 0;
    c_e_piv = 0; c_e_spin = 0; c_e_avoid = 0; c_e_clear = 0; c_ntie = 0; c_btie = 0; c_slim = 0; c_hlim = 0; c_frac = 0;
    c_ncam_near = 0; c_flip = 0; c_reenter = 0; c_stale_go = 0; c_stale_turn = 0; c_clampn = 0;
    age = 100;
    repeat (5) @(posedge clk); rst_n = 1;

    periods(2);                                                           // 没 UWB → LOST
    tgt_ok = 1; tgt_deg = 0; tgt_cm = 500; periods(2);                    // 有 UWB、没相机 → NCAM
    cam_on = 1; all_free; periods(8);                                     // 全空、正前方 → GO，斜坡
    tgt_deg = 30; periods(12);                                            // 右 30°：平滑慢慢跟上，转向每次最多变 STEP
    tgt_deg = -8; periods(10);                                            // 左 8°：刚出死区
    tgt_deg = 4; periods(10);                                             // 4°：死区里不拐（另一组死区 2° 要拐）
    tgt_deg = -10; periods(20);                                           // 左 10°：平滑值停在 −158（−9.875°），C 截断成 −9（向下取整就是 −10）
    tgt_cm = 999; tgt_deg = 0; periods(25);                               // 远：前进到上限
    tgt_deg = 40; periods(25);                                            // 远 + 偏：另一组的轮子被限幅
    tgt_deg = 0; tgt_cm = 300; periods(2);                                // 300 → HERE（另一组 250 还在走）
    tgt_cm = 301; periods(2);
    tgt_cm = 250; periods(2);                                             // 另一组 HERE
    tgt_cm = 600;
    tgt_deg = 99; periods(3); tgt_deg = 0; periods(3);                    // 角度跳一下：不原地转
    tgt_deg = 99; periods(12); tgt_deg = 0; periods(6);                   // 超过了但没保持够就回来：等待作废
    tgt_deg = 99; periods(25);                                            // 一直在侧面：确认以后原地转（另一组更早）
    tgt_deg = 35; periods(8);                                             // 35：默认退出（< 40），另一组还在转（≥ 30）
    tgt_deg = 20; periods(8);
    tgt_deg = -120; periods(25);                                          // 左后方：向左原地转
    lose; tgt_deg = 0; periods(1);                                        // 原地转时丢了 UWB、找回在正前方：退出原地转（丢的时候原地转的状态不清，和 follow.c 一样）
    lose; tgt_deg = -120; periods(20);                                    // 马上又到左后方：重新等确认，不接着上次的计时
    lose; tgt_deg = 0; periods(1);
    lose; tgt_deg = 90; periods(25);                                      // 正好 90°：默认不原地转（要 > 90），另一组（60）转
    tgt_deg = 0; periods(20);                                             // 平滑角度回到正好 0
    // ---- 避障 ----
    set_free(255, 255, 255, 255, 80, 255, 255, 255, 255); periods(6);     // 正前方 80 cm：绕；左右一样近 → 先看的（左 5°）
    tgt_deg = 2; periods(6);                                              // 主人偏右一点：不换边（上次方向的代价）
    all_free; periods(30);                                                // 障碍没了：先直走 hold 次，再朝主人
    set_free(255, 255, 255, 255, 80, 255, 255, 255, 255); periods(8);     // 又挡了：上次的绕行方向（左）已经作废，按主人（偏右）往右绕
    all_free; periods(28);
    tgt_deg = 15; set_free(255, 255, 255, 255, 255, 255, 255, 90, 255); periods(8);   // 正前方空、主人方向（11）挡：绕到 12
    set_free(80, 80, 90, 90, 90, 90, 90, 90, 80); tgt_deg = 0; periods(8);          // 没有 ≥ AVOID 的：退到 ≥ CLEAR 里挑
    set_free(40, 30, 20, 10, 0, 10, 20, 30, 50); periods(4);                       // 都不到 CLEAR → BLK
    set_free(255, 255, 255, 255, 40, 255, 255, 255, 255); periods(25);              // 太近 → 原地转向能走的方向（另一组的轮子走到负向限幅）
    set_free(255, 255, 255, 255, 45, 255, 255, 255, 255); periods(3);              // 正好 SPIN_CM（45）：一边走一边绕；另一组（50）原地转（转速超过它的限幅）
    set_free(255, 255, 255, 255, 150, 255, 255, 255, 255); periods(10);            // 正前方 150：不挡路，但前进被限
    all_free; periods(28);                                                         // 绕行记忆过期、回到 GO
    set_free(70, 70, 70, 70, 50, 70, 70, 70, 70); periods(3);                      // 只有 ≥ CLEAR 的、左右 5° 一样：挑先看的（左）
    set_free(70, 70, 70, 60, 50, 59, 70, 70, 70); periods(3);                      // 正好 CLEAR（60）算能走，59 不算
    set_free(255, 255, 255, 100, 80, 99, 255, 255, 255); periods(3);               // 正好 AVOID（100）算能走，99 不算
    lose; tgt_deg = 17; set_free(255, 255, 255, 255, 255, 255, 255, 90, 255); periods(30);   // 17° 在 15° 和 19° 正中间：离主人最近的取靠正前方的 15°（挡了）→ 绕到 19°
    set_free(255, 255, 255, 255, 255, 255, 255, 120, 255); periods(4);             // 15° 不挡了：先直走，按正前方和 15° 里近的限速（不按绕行方向 19°）
    set_free(255, 255, 255, 255, 80, 255, 255, 50, 255); tgt_deg = 99; periods(24); // 挡路绕到 19°，主人到侧面 → 原地转
    tgt_deg = 50; periods(16);                                                     // 50° 还在原地转（≥ 40）
    tgt_deg = -99; periods(10);                                                    // 一下跳到 0°：退出，正好挡路、左右 5° 一样 → 挑先看的（左）；原地转清掉了上次的 19°（不清就会往右）
    set_free(255, 255, 255, 60, 70, 60, 255, 255, 255); tgt_deg = 100; periods(25); // 主人在侧面：原地转优先于绕行
    tgt_deg = 0; all_free; periods(5);
    set_free(255, 255, 255, 255, 80, 255, 255, 255, 255); periods(3);
    cam_on = 0;                                                           // 相机断了 → NCAM，绕行记忆清掉；停的时候翻转信号正好是 1
    @(posedge clk);                                                      // 等最后一次翻转生效再看
    if (!otog) begin repeat (10) @(posedge clk); @(posedge oclk) otog <= 1'b1; age = 0; end
    periods(7);
    tgt_cm = 200; periods(2);                                             // 相机断了 + 主人很近：报 NCAM（看不见路优先）
    cam_on = 1; all_free; tgt_cm = 600; tgt_deg = 30; periods(8);         // 主人在右边
    tgt_ok = 0; periods(2);                                               // UWB 丢了 → LOST
    tgt_ok = 1; tgt_deg = -30; tgt_cm = 450; periods(6);                  // 找回在左边：平滑从新角度开始（不从右边慢慢过来）
    repeat (5) one_tick;

    $display("states: LOST %0d NCAM %0d HERE %0d BLK %0d TURN %0d GO %0d AVD %0d SPIN %0d; tie %0d hyst %0d fallback %0d limit %0d deadband %0d step %0d clamp %0d pend-reset %0d reacquire %0d",
             cnt[0], cnt[1], cnt[2], cnt[3], cnt[4], cnt[5], cnt[6], cnt[7], c_tie, c_hyst, c_fallback, c_lim, c_dead, c_step, c_clampw, c_pend_reset, c_reacq);
    for (i = 0; i < 8; i = i + 1) if (cnt[i] < 2) begin $display("FAIL scene setup: state %0d seen %0d times", i, cnt[i]); errors = errors + 1; end
    if (c_tie < 1 || c_hyst < 1 || c_fallback < 1 || c_lim < 1 || c_dead < 1 || c_step < 5 || c_clampw < 1 || c_pend_reset < 1 || c_reacq < 1) begin
        $display("FAIL scene setup: some branch was not exercised"); errors = errors + 1;
    end
    $display("edges: piv90 %0d spin45 %0d avoid100 %0d clear60 %0d near-tie %0d fallback-tie %0d side-limit %0d hold-limit %0d frac %0d ncam-near %0d flip %0d reenter %0d stale-go %0d stale-turn %0d clamp-neg %0d",
             c_e_piv, c_e_spin, c_e_avoid, c_e_clear, c_ntie, c_btie, c_slim, c_hlim, c_frac, c_ncam_near, c_flip, c_reenter, c_stale_go, c_stale_turn, c_clampn);
    if (c_e_piv < 16 || c_e_spin < 1 || c_e_avoid < 1 || c_e_clear < 1 || c_ntie < 1 || c_btie < 1 || c_slim < 1 || c_hlim < 1 || c_frac < 1 ||
        c_ncam_near < 1 || c_flip < 1 || c_reenter < 1 || c_stale_go < 1 || c_stale_turn < 1 || c_clampn < 1) begin
        $display("FAIL scene setup: some edge case was not exercised"); errors = errors + 1;
    end
    if (errors == 0) $display("PASS  tb_follow");
    else             $display("FAIL  tb_follow: %0d error(s)", errors);
    $finish;
end

initial begin #400_000_000; $display("FAIL  tb_follow: timeout"); $finish; end

endmodule
