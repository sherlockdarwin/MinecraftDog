`timescale 1ns / 1ps
// 测试 mc_follow（跟随 + 避障决策 + 陀螺仪角度环）。
//   测试台自己的模型按 mc_follow.v 文件头 / obstacle.md §6 的规格写（世界方向的平滑、目标航向的回差、PID 的定点取整），
//   每个 20 ms 周期和 RTL 的命令逐个比较：停 / 左右轮 / 状态 / 屏幕上的目标航向；两次命令之间正好 20 个节拍。
//   两个实例：默认参数，和一组全都不一样的参数（ANGLE_FILTER = 1 → 主人方向不平滑，好造回差正好等于 DEADBAND 的边界）。
//   两段：
//   A. 车头由测试台直接给（固定值或跳变），覆盖决策：LOST / NIMU / NCAM / HERE / TURN（确认时间、迟滞）/ GO / AVD / SPIN / BLK、
//      避障的各种挑选（与上一版相同的场景）、目标航向回差（正好等于 / 大 1°）、±180° 回绕、D 项、积分限幅、转向限幅、
//      上次绕行方向（世界方向）在车转了以后换算、限在 ±63°、NIMU 以后平滑重来。
//   B. 闭环：测试台里有一个车的模型（两轮速度一阶滞后 60 ms，航向角速度 ∝ 两轮差，再加"左轮比右轮快"的偏差），
//      UWB 角度 = 主人的世界方向 − 车头。检查：有偏差也能走直（积分起作用）、主人方向跳 30° 能转过去且超调小、
//      主人在后面先原地转再走、绕障。这些是"参数合不合理"的检查（车的模型是估的），命令仍然逐个和模型核对。
module tb_follow;

reg clk = 0, oclk = 0;
always #5 clk = ~clk;
always #4.49 oclk = ~oclk;
reg rst_n = 0;
reg tick = 0;

reg               tgt_ok = 0;
reg signed [7:0]  tdeg0 = 0, tdeg1 = 0;
reg [9:0]         tgt_cm = 0;
reg               otog = 0;
reg [71:0]        ofree = {9{8'd255}};
reg               imu_ok = 0;
reg signed [15:0] yaw0 = 0, yaw1 = 0, gz0 = 0, gz1 = 0;

wire              v0, s0, v1, s1;
wire signed [13:0] l0, r0, l1, r1;
wire [3:0]        st0, st1;
wire signed [8:0] td0, td1;
wire              k0, k1;                 // 困住了

mc_follow d0 (.I_clk(clk), .I_rst_n(rst_n), .I_tick_1ms(tick), .I_tgt_ok(tgt_ok), .I_tgt_deg(tdeg0), .I_tgt_cm(tgt_cm),
              .I_obs_tog(otog), .I_obs_free(ofree), .I_imu_ok(imu_ok), .I_yaw(yaw0), .I_gz(gz0),
              .O_cmd_valid(v0), .O_cmd_stop(s0), .O_cmd_l(l0), .O_cmd_r(r0), .O_state(st0), .O_tgt_deg(td0), .O_stuck(k0));
mc_follow #(
    .STOP_CM(150), .START_PWM(2500), .KP_D(20), .MAX_FWD(6400), .ANGLE_FILTER(1), .DEADBAND(2),
    .PIVOT_ENTER(60), .PIVOT_CONFIRM_MS(200), .PIVOT_EXIT(30), .PIVOT_PWM(3000), .MAX_WHEEL(6000), .ACC(300), .DEC(500), .TURN_SLEW(700),
    .HEAD_KP(25), .HEAD_KI(50), .HEAD_KD(12), .HEAD_I_MAX(250), .HEAD_I_ZONE(6), .TURN_MAX(1400),
    .AVOID_CM(120), .CLEAR_CM(70), .SPIN_CM(50), .KP_OBS(30), .SPIN_PWM(6500), .AVOID_TURN_MAX(2500), .AVOID_HOLD_CM(30), .CMS_FULL(120), .W_TGT(3), .W_PREV(2),
    .AVOID_FAR_CM(180), .OWNER_GAP_CM(160), .SCAN_DEG(90), .SCAN_PAUSE_MS(60), .SCAN_STEP_MS(200)
) d1 (.I_clk(clk), .I_rst_n(rst_n), .I_tick_1ms(tick), .I_tgt_ok(tgt_ok), .I_tgt_deg(tdeg1), .I_tgt_cm(tgt_cm),
      .I_obs_tog(otog), .I_obs_free(ofree), .I_imu_ok(imu_ok), .I_yaw(yaw1), .I_gz(gz1),
      .O_cmd_valid(v1), .O_cmd_stop(s1), .O_cmd_l(l1), .O_cmd_r(r1), .O_state(st1), .O_tgt_deg(td1), .O_stuck(k1));

integer errors = 0;
always @(errors) if (errors > 20) begin #1; $display("FAIL  tb_follow: too many errors"); $finish; end

// ---------------- 参数（两个实例）----------------
integer P_STOP [0:1], P_START [0:1], P_KPD [0:1], P_MAXF [0:1], P_AF [0:1], P_DB [0:1];
integer P_PIN [0:1], P_PCONF [0:1], P_POUT [0:1], P_PPWM [0:1], P_MAXW [0:1], P_ACC [0:1], P_DEC [0:1];
integer P_KP [0:1], P_KI [0:1], P_KD [0:1], P_IMAX [0:1], P_TMAX [0:1], P_SLEW [0:1], P_IZ [0:1];
integer P_AVOID [0:1], P_CLEAR [0:1], P_SPIN [0:1], P_KPO [0:1], P_SPWM [0:1], P_AMAX [0:1], P_HOLDCM [0:1], P_CMS [0:1], P_WT [0:1], P_WP [0:1];
integer P_FAR [0:1], P_GAP [0:1], P_SDEG [0:1], P_SPAUSE [0:1], P_SSTEP [0:1];
integer KIC [0:1], HQ [0:1];
task set_params;
    integer i;
    begin
        P_STOP[0] = 200; P_START[0] = 3300; P_KPD[0] = 10; P_MAXF[0] = 5000; P_AF[0] = 3; P_DB[0] = 4;
        P_PIN[0] = 90; P_PCONF[0] = 300; P_POUT[0] = 40; P_PPWM[0] = 2200; P_MAXW[0] = 6500; P_ACC[0] = 200; P_DEC[0] = 400;
        P_KP[0] = 70; P_KI[0] = 20; P_KD[0] = 10; P_IMAX[0] = 400; P_TMAX[0] = 1500; P_SLEW[0] = 800; P_IZ[0] = 10;
        P_AVOID[0] = 100; P_CLEAR[0] = 60; P_SPIN[0] = 60; P_KPO[0] = 20; P_SPWM[0] = 2200; P_AMAX[0] = 1500; P_HOLDCM[0] = 50; P_CMS[0] = 92; P_WT[0] = 2; P_WP[0] = 1;
        P_FAR[0] = 200; P_GAP[0] = 60; P_SDEG[0] = 20; P_SPAUSE[0] = 200; P_SSTEP[0] = 1000;
        P_STOP[1] = 150; P_START[1] = 2500; P_KPD[1] = 20; P_MAXF[1] = 6400; P_AF[1] = 1; P_DB[1] = 2;
        P_PIN[1] = 60; P_PCONF[1] = 200; P_POUT[1] = 30; P_PPWM[1] = 3000; P_MAXW[1] = 6000; P_ACC[1] = 300; P_DEC[1] = 500;
        P_KP[1] = 25; P_KI[1] = 50; P_KD[1] = 12; P_IMAX[1] = 250; P_TMAX[1] = 1400; P_SLEW[1] = 700; P_IZ[1] = 6;
        P_AVOID[1] = 120; P_CLEAR[1] = 70; P_SPIN[1] = 50; P_KPO[1] = 30; P_SPWM[1] = 6500; P_AMAX[1] = 2500; P_HOLDCM[1] = 30; P_CMS[1] = 120; P_WT[1] = 3; P_WP[1] = 2;
        P_FAR[1] = 180; P_GAP[1] = 160; P_SDEG[1] = 90; P_SPAUSE[1] = 60; P_SSTEP[1] = 200;   // 间距 160 > 停车 150：好造"主人比间距还近"
        for (i = 0; i < 2; i = i + 1) KIC[i] = $rtoi(P_KI[i] * 20.0 * 256.0 / 1000.0 + 0.5);    // 规格：KI × 周期 × 256 / 1000 四舍五入
        for (i = 0; i < 2; i = i + 1) HQ[i] = P_HOLDCM[i] * 8000 * 50 / P_CMS[i];   // 规格：前进量每 20 ms 累加，加到 HOLD_CM ÷（CMS / 8000 cm/s × 0.02 s）（整数，向下取整）
    end
endtask

// ---------------- 模型 ----------------
integer HEAD_DEG [0:15];
integer avalid [0:1], hown [0:1], piv [0:1], pend [0:1], since [0:1], fr [0:1], to [0:1];
integer pv [0:1], hprev [0:1], hold [0:1], hv [0:1], htgt [0:1], iacc [0:1];
integer scan [0:1], sph [0:1], sdir [0:1], scnt [0:1], snum [0:1], sy0 [0:1], stuck [0:1], lastnp [0:1], stot [0:1];
integer e_stk [0:1];
integer age;                              // 避障结果的"年龄"（节拍）
integer nper = 0;
integer e_stop [0:1], e_l [0:1], e_r [0:1], e_st [0:1], e_td [0:1];
integer lastm [0:1], exitp [0:1];
integer cnt [0:8];                        // 默认实例各状态出现的次数
integer YW [0:1], GZ [0:1], TD [0:1];     // 这一周期两个实例的输入（决策那一拍）
integer lastpsi [0:1];                    // 上次绕行方向（相对当时的车头，只用来统计"换算有没有起作用"）
// 场景计数
integer c_tie, c_hyst, c_fallback, c_lim, c_clampw, c_pend_reset, c_reacq;
integer c_e_piv, c_e_spin, c_e_avoid, c_e_clear, c_ntie, c_btie, c_slim, c_hlim, c_ncam_near, c_flip, c_reenter, c_stale_go, c_stale_turn, c_clampn;
integer c_prnd, c_pwrap, c_stopgo, c_half, c_slew, c_izone, c_dbkeep, c_dbeq, c_dbret, c_avkeep, c_avret, c_holdlock, c_wrap, c_dterm, c_iclp, c_iclpn, c_tclp, c_tclpa, c_efloor, c_pclamp, c_prot, c_nimu, c_lostnimu, c_round;
integer c_far, c_far_eq, c_far_gap, c_far_ang3, c_far_ang4, c_far_none, c_far_t0, c_far_lim, c_far_hyst, c_far_keep, c_far_ret, c_hold_part, c_nopiv_hold, c_nopiv_scan, c_piv_after;
integer c_sc_stop, c_sc_start, c_sc_exit, c_sc_left, c_sc_lt, c_sc_neg, c_sc_eq, c_sc_to, c_stuck, c_stuck_stay, c_tot_eq, c_tot_lt, c_stuck_max;

function integer iabs; input integer x; iabs = (x < 0) ? -x : x; endfunction
function integer imin; input integer a, b; imin = (a < b) ? a : b; endfunction
function integer clampw; input integer v, m; clampw = (v > m) ? m : (v < -m) ? -m : v; endfunction
function integer w16; input integer v; begin w16 = v % 65536; if (w16 < 0) w16 = w16 + 65536; if (w16 >= 32768) w16 = w16 - 65536; end endfunction
function integer fdiv; input integer a, b; begin fdiv = a / b; if ((a % b) != 0 && a < 0) fdiv = fdiv - 1; end endfunction   // 向下取整（b > 0）
function integer rdeg;                    // 航向差 → 度：按绝对值四舍五入（规格）
    input integer x;
    real r;
    begin r = iabs(x) * 360.0 / 65536.0 + 0.5; rdeg = $rtoi(r); if (x < 0) rdeg = -rdeg; end
endfunction
function integer ramp;
    input integer cur, tgt, acc, dec;
    integer st;
    begin
        st = (iabs(tgt) < iabs(cur)) ? dec : acc;
        ramp = (tgt - cur > st) ? cur + st : (tgt - cur < -st) ? cur - st : tgt;
    end
endfunction
function integer ff; input integer b; ff = ofree[8*(b-4) +: 8]; endfunction
function integer pref; input integer k; pref = (k % 2 == 0) ? 8 + k / 2 : 8 - (k + 1) / 2; endfunction
function integer pick;                    // 能走 ≥ thr 的方向里代价最小的（上次方向 pp），用来统计"换一种算法会不会选别的"
    input integer i, a, pp, thr;
    integer k, b, c, best;
    begin
        best = 1000000; pick = 99;
        for (k = 0; k < 9; k = k + 1) begin
            b = pref(k); c = P_WT[i] * iabs(HEAD_DEG[b] - a) + P_WP[i] * iabs(HEAD_DEG[b] - pp);
            if (ff(b) >= thr && c < best) begin best = c; pick = HEAD_DEG[b]; end
        end
    end
endfunction

task stop_it;                             // 停：命令归 0、绕行记忆 / 积分清掉、目标航向 = 车头
    input integer i, m;
    begin
        fr[i] = 0; to[i] = 0; pv[i] = 0; hold[i] = 0; hv[i] = 0; iacc[i] = 0; htgt[i] = YW[i]; e_stop[i] = 1; e_st[i] = m;
        if (m != 3) begin if (i == 0 && (scan[0] || stuck[0])) c_sc_stop = c_sc_stop + 1; scan[i] = 0; stuck[i] = 0; end   // 别的原因停车：找出口作废
    end
endtask

task decide;
    integer i, m, mm, d, a, aa, fwd, k, b, psi, f, dt, cost, btd, btf, aok, ac, apsi, af, bok, bc, bpsi, bf, cpsi, cf, f0, blk, av, flim, lim;
    integer ft, tt, ol, orr, c9_7, c9_9, btc, lim2, ppsi, hc, e, e16, p, di, dd, t, tmax, ex, pt, pw;
    integer tfar, fok, fc, fpsi, ffr, far, nopiv, sd, tn;
    begin
        nper = nper + 1;
        for (i = 0; i < 2; i = i + 1) begin
            e_stop[i] = 0; ft = 0; tt = 0; m = 5;
            if (!tgt_ok) begin
                if (i == 0 && !imu_ok) c_lostnimu = c_lostnimu + 1;
                avalid[i] = 0; stop_it(i, 0);
            end else if (!imu_ok) begin
                avalid[i] = 0; stop_it(i, 8); if (i == 0) c_nimu = c_nimu + 1;
            end else begin
                mm = w16(YW[i] + TD[i] * 182);                        // 主人方向（世界）= 车头 + UWB 角度 × 182
                if (!avalid[i]) begin
                    if (i == 0 && nper > 1) begin
                        c_reacq = c_reacq + 1;
                        if (rdeg(w16(hown[i] - YW[i])) * TD[i] < 0 && iabs(rdeg(w16(hown[i] - YW[i])) - TD[i]) >= 3) c_flip = c_flip + 1;
                    end
                    hown[i] = mm; avalid[i] = 1;
                end else begin
                    d = w16(mm - hown[i]);
                    hown[i] = w16(hown[i] + d / P_AF[i]);              // Verilog 的整数除法向 0 取整（规格：向 0 取整）
                end
                if (i == 0 && (YW[i] + TD[i] * 182 > 32767 || YW[i] + TD[i] * 182 < -32768)) c_wrap = c_wrap + 1;
                a = rdeg(w16(hown[i] - YW[i]));
                if (i == 0 && a != w16(hown[i] - YW[i]) * 45 / 8192) c_round = c_round + 1;   // 四舍五入 ≠ 向 0 取整
                ppsi = rdeg(w16(hprev[i] - YW[i]));
                ex = w16(hprev[i] - YW[i]);
                pt = iabs(ex) * 45 / 8192; if (pt > 63) pt = 63; if (ex < 0) pt = -pt;                 // 向 0 取整的换算（不对的写法）
                pw = (iabs(ex) * 45 + 4096) / 8192 % 64; if (ex < 0) pw = -pw;                         // 不限幅、按 6 位回绕（不对的写法）
                if (pv[i] && iabs(ppsi) > 63 && i == 0) c_pclamp = c_pclamp + 1;
                if (ppsi > 63) ppsi = 63; else if (ppsi < -63) ppsi = -63;
                if (age >= 100) begin stop_it(i, 1); if (i == 0 && tgt_cm <= P_STOP[i]) c_ncam_near = c_ncam_near + 1; end
                else if (tgt_cm <= P_STOP[i]) stop_it(i, 2);
                else begin
                    aa = iabs(a);
                    // 先看路（原地转要不要进，取决于这一次挡不挡路）
                    fwd = P_START[i] + (tgt_cm - P_STOP[i]) * P_KPD[i];
                    if (fwd > P_MAXF[i]) fwd = P_MAXF[i];
                    tfar = tgt_cm - P_GAP[i]; if (tfar > P_FAR[i]) tfar = P_FAR[i]; if (tfar < 0) tfar = 0;     // 远处挡路的门限
                    btd = 1000; btf = 0; aok = 0; ac = 1000000; bok = 0; bc = 1000000; apsi = 0; af = 0; bpsi = 0; bf = 0; btc = -1;
                    fok = 0; fc = 1000000; fpsi = 0; ffr = 0;
                    for (k = 0; k < 9; k = k + 1) begin
                        b = pref(k); psi = HEAD_DEG[b]; f = ff(b);
                        dt = iabs(psi - a);
                        if (dt == btd && i == 0 && ((f < P_AVOID[i]) != (btf < P_AVOID[i]))) c_ntie = c_ntie + 1;
                        if (dt < btd) begin btd = dt; btf = f; end
                        cost = P_WT[i] * dt + (pv[i] ? P_WP[i] * iabs(psi - ppsi) : 0);
                        if (f >= P_AVOID[i] && cost == ac && i == 0) c_tie = c_tie + 1;
                        if (f >= P_CLEAR[i] && cost == bc) btc = cost;
                        if (f >= P_AVOID[i] && cost < ac) begin ac = cost; aok = 1; apsi = psi; af = f; end
                        if (f >= P_CLEAR[i] && cost < bc) begin bc = cost; bok = 1; bpsi = psi; bf = f; end
                        if (f >= tfar && cost < fc) begin fc = cost; fok = 1; fpsi = psi; ffr = f; end
                    end
                    cpsi = aok ? apsi : bpsi; cf = aok ? af : bf;
                    f0 = ff(8);
                    blk = (f0 < P_AVOID[i]) || (btf < P_AVOID[i]);
                    far = (btd <= 3) && (btf < tfar);
                    nopiv = (!blk && hold[i] > 0) || scan[i] || stuck[i];
                    if (!piv[i]) begin
                        if (i == 0 && aa == P_PIN[i]) c_e_piv = c_e_piv + 1;
                        if (aa <= P_PIN[i]) begin if (pend[i] && i == 0) c_pend_reset = c_pend_reset + 1; pend[i] = 0; exitp[i] = 0; end
                        else if (!pend[i]) begin pend[i] = 1; since[i] = nper; if (exitp[i] && i == 0) c_reenter = c_reenter + 1; exitp[i] = 0; end
                        else if ((nper - since[i]) * 20 >= P_PCONF[i]) begin
                            if (!nopiv) begin piv[i] = 1; if (i == 0 && lastnp[i]) c_piv_after = c_piv_after + 1; end
                            else if (i == 0) begin if (scan[i] || stuck[i]) c_nopiv_scan = c_nopiv_scan + 1; else c_nopiv_hold = c_nopiv_hold + 1; end
                        end
                    end else if (aa < P_POUT[i]) begin piv[i] = 0; pend[i] = 0; exitp[i] = 1; end
                    lastnp[i] = !piv[i] && pend[i] && (nper - since[i]) * 20 >= P_PCONF[i];
                    if (piv[i]) begin
                        m = 4; pv[i] = 0; hold[i] = 0; hv[i] = 0; iacc[i] = 0; htgt[i] = hown[i];
                        ft = 0; tt = (a > 0) ? P_PPWM[i] : -P_PPWM[i];
                    end else begin
                        if (i == 0 && !aok && bok) c_fallback = c_fallback + 1;
                        if (i == 0 && blk && bok) begin
                            if (f0 == P_SPIN[i])               c_e_spin  = c_e_spin + 1;
                            if (aok && af == P_AVOID[i])       c_e_avoid = c_e_avoid + 1;
                            if (!aok && bf == P_CLEAR[i])      c_e_clear = c_e_clear + 1;
                            if (!aok && btc == bc && !pv[i])   c_btie    = c_btie + 1;
                        end
                        av = 0; flim = 255;
                        if (i == 0 && blk && !bok) begin
                            if (!scan[0] && !stuck[0]) c_sc_start = c_sc_start + 1;
                        end
                        if (!blk) begin
                            if (i == 0 && (scan[0] || stuck[0])) c_sc_exit = c_sc_exit + 1;
                            scan[i] = 0; stuck[i] = 0;
                            if (hold[i] > 0) begin                     // 绕完直走：每次减掉上一次发出去的前进量
                                m = 6; av = 1;
                                if (i == 0 && fr[i] > 0 && hold[i] > fr[i]) c_hold_part = c_hold_part + 1;
                                hold[i] = (hold[i] > fr[i]) ? hold[i] - (fr[i] > 0 ? fr[i] : 0) : 0;
                                if (!hv[i]) begin htgt[i] = YW[i]; hv[i] = 1; if (i == 0) c_holdlock = c_holdlock + 1; end
                                flim = imin(f0, btf);
                            end else if (far && fok) begin             // 远处挡路：提前绕
                                m = 6; av = 1;
                                hc = w16(YW[i] + fpsi * 182);
                                if (i == 0 && pv[i]) begin               // 没有"上次方向"那一项就会选别的：记一次
                                    c9_7 = 1000000; c9_9 = 0;
                                    for (k = 0; k < 9; k = k + 1) begin
                                        b = pref(k); f = ff(b); dt = P_WT[i] * iabs(HEAD_DEG[b] - a);
                                        if (f >= tfar && dt < c9_7) begin c9_7 = dt; c9_9 = HEAD_DEG[b]; end
                                    end
                                    if (c9_9 != fpsi) c_far_hyst = c_far_hyst + 1;
                                end
                                hprev[i] = hc; pv[i] = 1; lastpsi[i] = fpsi;
                                if (hv[i] && iabs(w16(hc - htgt[i])) <= P_DB[i] * 182) begin if (i == 0) c_far_keep = c_far_keep + 1; end
                                else begin if (hv[i] && i == 0) c_far_ret = c_far_ret + 1; htgt[i] = hc; hv[i] = 1; end
                                flim = imin(f0, ffr);
                                lim = P_START[i] + (ffr - P_CLEAR[i]) * P_KPO[i];
                                if (i == 1 && ffr < f0 && lim < fwd && fr[i] + P_ACC[i] > lim) c_far_lim = c_far_lim + 1;   // 限幅真起作用（斜坡已经快爬到了）
                                if (i == 0) c_far = c_far + 1;
                                if (btd == 3) c_far_ang3 = c_far_ang3 + 1;
                                if (tgt_cm - P_GAP[i] < P_FAR[i]) c_far_gap = c_far_gap + 1;
                            end else begin
                                if (far && !fok && i == 0) c_far_none = c_far_none + 1;
                                if (btd <= 3 && btf == tfar) c_far_eq = c_far_eq + 1;
                                if (btd == 4 && btf < tfar) c_far_ang4 = c_far_ang4 + 1;
                                if (i == 1 && tgt_cm < P_GAP[i] && btf >= P_AVOID[i] && btf < P_FAR[i]) c_far_t0 = c_far_t0 + 1;
                                m = 5; av = 0; pv[i] = 0;
                                if (i == 0 && !hv[i] && lastm[i] != 4 && lastm[i] != 5 && lastm[i] != 6 && lastm[i] != 7 &&
                                    hown[i] != htgt[i] && iabs(w16(hown[i] - htgt[i])) <= P_DB[i] * 182) c_stopgo = c_stopgo + 1;   // 停车后：目标航向必须重新定（停车时的车头在回差里也不能留）
                                if (hv[i] && iabs(w16(hown[i] - htgt[i])) <= P_DB[i] * 182) begin
                                    if (i == 0) c_dbkeep = c_dbkeep + 1;
                                    if (i == 1 && iabs(w16(hown[i] - htgt[i])) == P_DB[i] * 182) c_dbeq = c_dbeq + 1;
                                end else begin
                                    if (hv[i] && i == 1 && iabs(w16(hown[i] - htgt[i])) <= P_DB[i] * 182 + 182) c_dbret = c_dbret + 1;
                                    htgt[i] = hown[i]; hv[i] = 1;
                                end
                                flim = imin(f0, btf);
                            end
                        end else if (!bok) begin                       // 找出口
                            m = 3;
                            if (stuck[i]) begin
                                if (i == 0) c_stuck_stay = c_stuck_stay + 1;
                            end else if (!scan[i]) begin
                                scan[i] = 1; sph[i] = 1; scnt[i] = 0; snum[i] = 0; stot[i] = 0; sy0[i] = YW[i]; sdir[i] = (a >= 0);
                                if (i == 0 && a < 0) c_sc_left = c_sc_left + 1;
                            end else if (sph[i]) begin
                                if (scnt[i] != P_SPAUSE[i] / 20 - 1) scnt[i] = scnt[i] + 1;
                                else begin                             // 停着看完：加上这一步实际转的（往反方向不算），满一圈或者步数到了上限 → 困住
                                    sd = sdir[i] ? w16(YW[i] - sy0[i]) : w16(sy0[i] - YW[i]);
                                    tn = stot[i] + ((sd > 0) ? sd : 0);
                                    if (i == 0 && tn == 360 * 182) c_tot_eq = c_tot_eq + 1;
                                    if (i == 0 && tn == 360 * 182 - 1) c_tot_lt = c_tot_lt + 1;
                                    if (tn >= 360 * 182 || snum[i] == 2 * ((360 + P_SDEG[i] - 1) / P_SDEG[i])) begin
                                        stuck[i] = 1; if (i == 0) c_stuck = c_stuck + 1; if (i == 1 && tn < 360 * 182) c_stuck_max = c_stuck_max + 1;
                                    end else begin stot[i] = tn; sph[i] = 0; scnt[i] = 0; sy0[i] = YW[i]; m = 7; end
                                end
                            end else begin
                                sd = sdir[i] ? w16(YW[i] - sy0[i]) : w16(sy0[i] - YW[i]);
                                if (i == 0 && sd == P_SDEG[i] * 182 - 1) c_sc_lt = c_sc_lt + 1;
                                if (i == 0 && sd < 0) c_sc_neg = c_sc_neg + 1;
                                if (sd >= P_SDEG[i] * 182 || scnt[i] == P_SSTEP[i] / 20 - 1) begin
                                    if (i == 0) begin if (sd == P_SDEG[i] * 182) c_sc_eq = c_sc_eq + 1; if (sd < P_SDEG[i] * 182) c_sc_to = c_sc_to + 1; end
                                    snum[i] = snum[i] + 1; sph[i] = 1; scnt[i] = 0;
                                end else begin scnt[i] = scnt[i] + 1; m = 7; end
                            end
                            if (m == 7) begin                          // 找出口时转：往定好的那边
                                hv[i] = 0; iacc[i] = 0;
                                ft = 0; tt = sdir[i] ? P_SPWM[i] : -P_SPWM[i];
                            end
                        end else begin
                            if (i == 0 && (scan[0] || stuck[0])) c_sc_exit = c_sc_exit + 1;
                            scan[i] = 0; stuck[i] = 0;
                            if (i == 0 && pv[i]) begin               // 没有"上次方向"那一项就会选别的：记一次
                                c9_7 = 1000000; c9_9 = 0;
                                for (k = 0; k < 9; k = k + 1) begin
                                    b = pref(k); f = ff(b); dt = P_WT[i] * iabs(HEAD_DEG[b] - a);
                                    if (f >= (aok ? P_AVOID[i] : P_CLEAR[i]) && dt < c9_7) begin c9_7 = dt; c9_9 = HEAD_DEG[b]; end
                                end
                                if (c9_9 != cpsi) c_hyst = c_hyst + 1;
                                // 车转过以后：上次方向要是还按"相对车头"存（不换算），会选别的
                                c9_7 = 1000000; c9_9 = 0;
                                for (k = 0; k < 9; k = k + 1) begin
                                    b = pref(k); f = ff(b); dt = P_WT[i] * iabs(HEAD_DEG[b] - a) + P_WP[i] * iabs(HEAD_DEG[b] - lastpsi[i]);
                                    if (f >= (aok ? P_AVOID[i] : P_CLEAR[i]) && dt < c9_7) begin c9_7 = dt; c9_9 = HEAD_DEG[b]; end
                                end
                                if (c9_9 != cpsi) c_prot = c_prot + 1;
                            end
                            if (i == 0 && !pv[i] && (lastm[i] == 5 || lastm[i] == 4)) begin
                                c9_7 = 1000000; c9_9 = 0;
                                for (k = 0; k < 9; k = k + 1) begin
                                    b = pref(k); f = ff(b); dt = P_WT[i] * iabs(HEAD_DEG[b] - a) + P_WP[i] * iabs(HEAD_DEG[b] - ppsi);
                                    if (f >= (aok ? P_AVOID[i] : P_CLEAR[i]) && dt < c9_7) begin c9_7 = dt; c9_9 = HEAD_DEG[b]; end
                                end
                                if (c9_9 != cpsi) begin if (lastm[i] == 5) c_stale_go = c_stale_go + 1; else c_stale_turn = c_stale_turn + 1; end
                            end
                            if (pv[i]) begin
                                if (pick(i, a, pt, aok ? P_AVOID[i] : P_CLEAR[i]) != cpsi) c_prnd = c_prnd + 1;
                                if (pick(i, a, pw, aok ? P_AVOID[i] : P_CLEAR[i]) != cpsi) c_pwrap = c_pwrap + 1;
                            end
                            hc = w16(YW[i] + cpsi * 182);
                            hprev[i] = hc; pv[i] = 1; hold[i] = HQ[i]; lastpsi[i] = cpsi;
                            if (f0 < P_SPIN[i]) begin
                                m = 7; htgt[i] = hc; hv[i] = 0; iacc[i] = 0;
                                ft = 0; tt = (cpsi > 0) ? P_SPWM[i] : -P_SPWM[i];
                            end else begin
                                m = 6; av = 1; flim = imin(f0, cf);
                                if (hv[i] && iabs(w16(hc - htgt[i])) <= P_DB[i] * 182) begin if (i == 0) c_avkeep = c_avkeep + 1; end
                                else begin if (hv[i] && i == 0) c_avret = c_avret + 1; htgt[i] = hc; hv[i] = 1; end
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
                            // 角度环
                            e   = w16(htgt[i] - YW[i]);
                            e16 = fdiv(e * 45, 512);
                            if (i == 0 && e < 0 && (e * 45) % 512 != 0) c_efloor = c_efloor + 1;
                            p   = fdiv(P_KP[i] * e16, 16);
                            di  = fdiv(KIC[i] * e16, 16);
                            if (iabs(e16) <= P_IZ[i] * 16) begin                // 积分分离
                                iacc[i] = iacc[i] + di;
                                if (iacc[i] > P_IMAX[i] * 256)  begin iacc[i] = P_IMAX[i] * 256;  if (i == 0) c_iclp = c_iclp + 1; end
                                if (iacc[i] < -P_IMAX[i] * 256) begin iacc[i] = -P_IMAX[i] * 256; if (i == 0) c_iclpn = c_iclpn + 1; end
                            end else if (i == 0) c_izone = c_izone + 1;
                            dd  = fdiv(P_KD[i] * 4000 * GZ[i], 65536);
                            if (i == 0 && dd != 0) c_dterm = c_dterm + 1;
                            t   = p + fdiv(iacc[i], 256) - dd;
                            tmax = av ? P_AMAX[i] : P_TMAX[i];
                            if (t > tmax || t < -tmax) begin if (i == 0) begin if (av) c_tclpa = c_tclpa + 1; else c_tclp = c_tclp + 1; end end
                            tt = clampw(t, tmax); ft = fwd;
                        end
                    end
                    if (!e_stop[i]) begin
                        fr[i] = ramp(fr[i], ft, P_ACC[i], P_DEC[i]);              // 前进：斜坡
                        if (iabs(tt - to[i]) > P_SLEW[i] && i == 0) c_slew = c_slew + 1;
                        to[i] = clampw(tt - to[i], P_SLEW[i]) + to[i];            // 转向：每次最多变 SLEW
                        ol = fr[i] + to[i]; orr = fr[i] - to[i];
                        if ((ol > P_MAXW[i] || ol < -P_MAXW[i] || orr > P_MAXW[i] || orr < -P_MAXW[i]) && i == 1) c_clampw = c_clampw + 1;
                        if (i == 1 && (ol < -P_MAXW[i] || orr < -P_MAXW[i])) c_clampn = c_clampn + 1;
                        e_l[i] = clampw(ol, P_MAXW[i]); e_r[i] = clampw(orr, P_MAXW[i]);
                        e_st[i] = m;
                    end
                end
            end
            if (e_stop[i]) begin e_l[i] = 0; e_r[i] = 0; end
            lastm[i] = e_st[i];
            e_td[i] = fdiv(htgt[i] * 45 + 4096, 8192);              // 屏幕：目标航向（度，.5 往上）
            if (i == 0 && (htgt[i] * 45 + 4096) % 8192 == 0) c_half = c_half + 1;
            if (i == 0) cnt[e_st[0]] = cnt[e_st[0]] + 1;
        end
    end
endtask

// ---------------- 车的模型（闭环段，尺寸按 3Dmodel/MinecraftDog_FPGA.stl）----------------
//   后轮驱动：电机装在两条后腿里（轴离腿底 28 mm），轮子在腿外侧（x = ±55~75 mm）→ 两轮中心距 TRACK = 130 mm；前腿里是万向轮。
//   原地转的中心 = 后轴中点（镜头在它前面约 37 cm）。轮径 STL 里没画，按腿下留的空间约 65 mm。
//   电机转速没有数据：按满量程 8000 时轮子约 270 rpm（0.92 m/s）→ VPWM = 每 1 PWM 1.15e-4 m/s（假设，上车再对）。
//   航向角速度 = (左轮 − 右轮) × VPWM / TRACK（rad/s）→ PG = VPWM / TRACK × 65536 / 2π / 1000（航向角单位 / ms，每 1 PWM 差）；
//   每个轮子的速度跟命令有 60 ms 的一阶滞后（电机 + 车身转动惯量）；PB = 左右电机不一样快（两轮同 PWM 时自己往右偏）。
reg  plant = 0;
real yr [0:1], vl [0:1], vr [0:1], owner [0:1];
real PG, PB, rate;
real VPWM, TRACK;
integer i2;
task plant_step;                          // 1 ms
    begin
        for (i2 = 0; i2 < 2; i2 = i2 + 1) begin
            vl[i2] = vl[i2] + ((e_stop[i2] ? 0.0 : e_l[i2]) - vl[i2]) / 60.0;
            vr[i2] = vr[i2] + ((e_stop[i2] ? 0.0 : e_r[i2]) - vr[i2]) / 60.0;
            rate = PG * (vl[i2] - vr[i2]) + PB * (vl[i2] + vr[i2]) / 2.0;     // 航向角单位 / 毫秒，右转为正
            yr[i2] = yr[i2] + rate;
            if (yr[i2] >= 32768.0) yr[i2] = yr[i2] - 65536.0;
            if (yr[i2] < -32768.0) yr[i2] = yr[i2] + 65536.0;
            if (i2 == 0) begin yaw0 = w16($rtoi(yr[0] + 32768.5) - 32768); gz0 = $rtoi(rate * 90.0 + ((rate < 0) ? -0.5 : 0.5)); end   // 原始值 = °/s × 16.384 = 航向角/ms × 90
            else         begin yaw1 = w16($rtoi(yr[1] + 32768.5) - 32768); gz1 = $rtoi(rate * 90.0 + ((rate < 0) ? -0.5 : 0.5)); end
        end
        tdeg0 = uwb(owner[0], yaw0); tdeg1 = uwb(owner[1], yaw1);
    end
endtask
function integer uwb;                     // UWB 角度 = 主人世界方向 − 车头（度，向 0 取整，限 ±99，和 STM32 一样）
    input real ow;
    input integer y;
    real dd;
    begin
        dd = ow - y; while (dd >= 32768.0) dd = dd - 65536.0; while (dd < -32768.0) dd = dd + 65536.0;
        uwb = $rtoi(dd * 360.0 / 65536.0);
        if (uwb > 99) uwb = 99; if (uwb < -99) uwb = -99;
    end
endfunction
// 闭环的记录：默认实例的航向误差（主人世界方向 − 车头，度）
real herr;
function real hdeg; input real ow; input integer y; real dd; begin dd = ow - y; while (dd >= 32768.0) dd = dd - 65536.0; while (dd < -32768.0) dd = dd + 65536.0; hdeg = dd * 360.0 / 65536.0; end endfunction

// ---------------- 节拍 + 避障结果 ----------------
localparam TICK = 200;                    // 一个"毫秒"节拍 = 200 个时钟（仿真加速）
integer ntick = 0;
reg     cam_on = 0;
// 闭环找出口用的"世界"：四面都是 30 cm 的墙，只有世界方向 world_gap 左右 12° 有个口子（world_open = 1 时）；按默认实例的车头算每个方向能走多远
reg     world_on = 0, world_open = 0;
real    world_gap;
integer wb;
real    wd;
task world_view;
    begin
        wd = hdeg(world_gap, yaw0);
        for (wb = 4; wb <= 12; wb = wb + 1) ofree[8*(wb-4) +: 8] = (world_open && HEAD_DEG[wb] - wd <= 12.0 && wd - HEAD_DEG[wb] <= 12.0) ? 8'd255 : 8'd30;
    end
endtask
integer pending = 0, pending1 = 0;
integer last_cmd_tick = -1;
task one_tick;
    begin
        repeat (TICK - 1) @(posedge clk);
        @(posedge clk) tick <= 1'b1;
        @(posedge clk) tick <= 1'b0;
        #1;                                                   // RTL 在这一拍的时钟沿取输入；之后再改
        ntick = ntick + 1;
        if (ntick % 20 == 0) begin
            YW[0] = yaw0; YW[1] = yaw1; GZ[0] = gz0; GZ[1] = gz1; TD[0] = tdeg0; TD[1] = tdeg1;
            decide; pending = 1; pending1 = 1;
        end
        if (plant) plant_step;
        if (age < 100) age = age + 1;
        if (cam_on && ntick % 5 == 0) begin
            if (world_on) world_view;
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
    if (s0 !== e_stop[0][0] || l0 !== e_l[0] || r0 !== e_r[0] || st0 !== e_st[0] || td0 !== e_td[0] || k0 !== stuck[0][0]) begin
        $display("FAIL [default] period %0d: stop %b L %0d R %0d state %0d tgt %0d stuck %b, expected %0d %0d %0d %0d %0d %0d (ok %b imu %b deg %0d yaw %0d gz %0d cm %0d age %0d)",
                 nper, s0, l0, r0, st0, td0, k0, e_stop[0], e_l[0], e_r[0], e_st[0], e_td[0], stuck[0], tgt_ok, imu_ok, TD[0], YW[0], GZ[0], tgt_cm, age);
        errors = errors + 1;
    end
end
always @(posedge clk) if (v1) begin
    if (!pending1) begin $display("FAIL [other] command without a decision tick (tick %0d)", ntick); errors = errors + 1; end
    pending1 = 0;
    if (s1 !== e_stop[1][0] || l1 !== e_l[1] || r1 !== e_r[1] || st1 !== e_st[1] || td1 !== e_td[1] || k1 !== stuck[1][0]) begin
        $display("FAIL [other] period %0d: stop %b L %0d R %0d state %0d tgt %0d stuck %b, expected %0d %0d %0d %0d %0d %0d (deg %0d yaw %0d gz %0d cm %0d)",
                 nper, s1, l1, r1, st1, td1, k1, e_stop[1], e_l[1], e_r[1], e_st[1], e_td[1], stuck[1], TD[1], YW[1], GZ[1], tgt_cm);
        errors = errors + 1;
    end
end

task periods; input integer n; integer t; for (t = 0; t < n * 20; t = t + 1) one_tick; endtask
task set_free;
    input [7:0] f4, f5, f6, f7, f8, f9, f10, f11, f12;
    ofree = {f12, f11, f10, f9, f8, f7, f6, f5, f4};
endtask
task all_free; set_free(255, 255, 255, 255, 255, 255, 255, 255, 255); endtask
task deg;  input integer d; begin tdeg0 = d; tdeg1 = d; end endtask
task head; input integer y; begin yaw0 = y; yaw1 = y; end endtask
task rate_; input integer g; begin gz0 = g; gz1 = g; end endtask
task lose; begin tgt_ok = 0; periods(1); tgt_ok = 1; end endtask

// 找出口（车头由测试台给）：在"转"的那段里，每个周期把车头摆到"这一步开始时的车头 + sx"（往要转的方向为正）
//   默认：第 1 步先差 1 个单位、再正好 SCAN_DEG；第 2 步往反方向（转太久才算一步，也不算转了多少）；后面每步 22°，
//         离一圈还差不到 2 步时：scan_mode = 1 正好补满一圈（360 × 182），= 0 补到差 1 个单位（再转一步才困住）。另一组同样，后面每步 100°。
integer sx, scan_mode = 1;
task scan_drive;
    begin
        if (scan[0] && !sph[0]) begin
            sx = (snum[0] == 0) ? ((scnt[0] == 0) ? P_SDEG[0] * 182 - 1 : P_SDEG[0] * 182) : (snum[0] == 1) ? -1000 :
                 (360 * 182 - stot[0] > 2 * 22 * 182 || 360 * 182 - stot[0] - 1 < P_SDEG[0] * 182) ? 22 * 182 : 360 * 182 - stot[0] - 1 + scan_mode;
            yaw0 = w16(sy0[0] + (sdir[0] ? sx : -sx));
        end
        if (scan[1] && !sph[1]) begin
            sx = (snum[1] == 0) ? ((scnt[1] == 0) ? P_SDEG[1] * 182 - 1 : P_SDEG[1] * 182) : (snum[1] == 1) ? 0 : 100 * 182;
            yaw1 = w16(sy0[1] + (sdir[1] ? sx : -sx));
        end
        periods(1);
    end
endtask

// 闭环检查：默认实例的 角度环误差（目标航向 − 车头）和 对主人的误差（主人世界方向 − 车头），度
real emax, emin, omax, omin;
task track;
    input integer n;
    integer t;
    begin
        emax = -1000.0; emin = 1000.0; omax = -1000.0; omin = 1000.0;
        for (t = 0; t < n; t = t + 1) begin
            periods(1);
            herr = hdeg(htgt[0], yaw0);
            if (herr > emax) emax = herr;
            if (herr < emin) emin = herr;
            herr = hdeg(owner[0], yaw0);
            if (herr > omax) omax = herr;
            if (herr < omin) omin = herr;
        end
    end
endtask

// ---------------- 场景 ----------------
real PI, F, ct, turned;
integer b, i, sv, sv2, t, yp;
initial begin
    PI = 3.14159265358979; F = 960.0 / $tan(36.0 * PI / 180.0); ct = $cos(15.0 * PI / 180.0);   // 方向角按测试专用的 15° 几何表（sim.sh 给 tb_follow 编的是 models/mc_obs_lut_t15.v，车上的表不影响这里的场景）
    for (b = 0; b < 16; b = b + 1) HEAD_DEG[b] = $rtoi($atan((120.0 * b - 960.0) * ct / F) * 180.0 / PI + ((b >= 8) ? 0.5 : -0.5));
    set_params;
    for (i = 0; i < 2; i = i + 1) begin avalid[i] = 0; hown[i] = 0; piv[i] = 0; pend[i] = 0; since[i] = 0; fr[i] = 0; to[i] = 0; pv[i] = 0; hprev[i] = 0; hold[i] = 0;
                                        hv[i] = 0; htgt[i] = 0; iacc[i] = 0; lastm[i] = 0; exitp[i] = 0; lastpsi[i] = 0; e_stop[i] = 1; e_l[i] = 0; e_r[i] = 0;
                                        scan[i] = 0; sph[i] = 0; sdir[i] = 0; scnt[i] = 0; snum[i] = 0; sy0[i] = 0; stuck[i] = 0; lastnp[i] = 0; stot[i] = 0; end
    for (i = 0; i < 9; i = i + 1) cnt[i] = 0;
    c_tie = 0; c_hyst = 0; c_fallback = 0; c_lim = 0; c_clampw = 0; c_pend_reset = 0; c_reacq = 0;
    c_e_piv = 0; c_e_spin = 0; c_e_avoid = 0; c_e_clear = 0; c_ntie = 0; c_btie = 0; c_slim = 0; c_hlim = 0;
    c_ncam_near = 0; c_flip = 0; c_reenter = 0; c_stale_go = 0; c_stale_turn = 0; c_clampn = 0;
    c_dbkeep = 0; c_dbeq = 0; c_dbret = 0; c_avkeep = 0; c_avret = 0; c_holdlock = 0; c_wrap = 0; c_dterm = 0; c_iclp = 0; c_iclpn = 0; c_tclp = 0; c_tclpa = 0;
    c_prnd = 0; c_pwrap = 0; c_stopgo = 0; c_half = 0; c_slew = 0; c_izone = 0; c_efloor = 0; c_pclamp = 0; c_prot = 0; c_nimu = 0; c_lostnimu = 0; c_round = 0;
    c_far = 0; c_far_eq = 0; c_far_gap = 0; c_far_ang3 = 0; c_far_ang4 = 0; c_far_none = 0; c_far_t0 = 0; c_far_lim = 0; c_far_hyst = 0; c_far_keep = 0; c_far_ret = 0;
    c_hold_part = 0; c_nopiv_hold = 0; c_nopiv_scan = 0; c_piv_after = 0;
    c_sc_stop = 0; c_sc_start = 0; c_sc_exit = 0; c_sc_left = 0; c_sc_lt = 0; c_sc_neg = 0; c_sc_eq = 0; c_sc_to = 0; c_stuck = 0; c_stuck_stay = 0; c_tot_eq = 0; c_tot_lt = 0; c_stuck_max = 0;
    age = 100;
    head(12000);
    repeat (5) @(posedge clk); rst_n = 1;

    // ======== A. 车头由测试台给 ========
    periods(2);                                                           // 没 UWB、陀螺仪也没好 → LOST（优先）
    tgt_ok = 1; deg(0); tgt_cm = 500; periods(2);                         // 有 UWB、陀螺仪没好 → NIMU
    imu_ok = 1; periods(2);                                               // 没相机 → NCAM
    cam_on = 1; all_free; periods(8);                                     // 全空、正前方 → GO，斜坡
    deg(30); periods(12);                                                 // 右 30°：平滑跟上、目标航向改了、P 和积分（积分到限幅）、转向限幅
    rate_(700); periods(3); rate_(-700); periods(3); rate_(0);            // D 项
    head(12000 + 30 * 182); deg(0); periods(10);                          // 车转过去了（车头 +30°，主人正前方）：误差回到 0，积分慢慢退
    deg(2); periods(4); deg(4); periods(4);                               // 回差里不改目标（另一组：正好 2°）
    deg(5); periods(6); deg(8); periods(6);                               // 超出回差改目标（另一组：3° 就改）
    head(12000 + 30 * 182 - 300); deg(8); periods(6);                     // 车头偏一点：航向差有小数（负数要向下取整）
    head(12000); deg(-10); periods(20);
    tgt_cm = 999; deg(0); periods(25);                                    // 远：前进到上限
    deg(40); periods(25);                                                 // 远 + 偏：另一组的轮子被限幅
    deg(0); tgt_cm = 300; periods(8);                                     // 中间距离：前进 = 起步 + (距离 − 停车距离) × 系数（两组都不到上限）
    tgt_cm = 200; periods(2);                                             // 200 → HERE（另一组 150 还在走）
    tgt_cm = 201; periods(2);
    tgt_cm = 150; periods(2);
    tgt_cm = 600;
    deg(3); periods(6); tgt_cm = 140; periods(2); tgt_cm = 600; periods(4); deg(0); periods(4);   // 停车再走、主人在回差里：目标航向重新定成主人方向（不留停车时的车头）
    deg(99); periods(3); deg(0); periods(3);                              // 角度跳一下：不原地转
    deg(99); periods(12); deg(0); periods(6);                             // 超过了但没保持够就回来：等待作废
    deg(99); periods(25);                                                 // 一直在侧面：确认以后原地转（另一组更早）
    deg(35); periods(8);                                                  // 35：默认退出（< 40），另一组还在转（≥ 30）
    deg(20); periods(8);
    deg(-120); periods(25);                                               // 左后方：向左原地转（UWB 限 99，这里直接给 −120 测符号）
    lose; deg(0); periods(1);
    lose; deg(-120); periods(20);                                         // 马上又到左后方：重新等确认
    lose; deg(0); periods(1);
    lose; deg(90); periods(25);                                           // 正好 90°（× 182 再四舍五入回来还是 90）：默认不原地转，另一组（60）转
    deg(0); periods(20);
    // ---- 陀螺仪掉了、回绕 ----
    head(4096); imu_ok = 0; periods(3); head(-4096); periods(2);          // NIMU（停车：目标航向 = 车头 = 正好 22.5° / −22.5°，屏幕四舍五入的边界）
    head(12000); periods(1); imu_ok = 1; deg(25); periods(6);             // → 平滑重来（直接用新角度）
    head(32700); deg(20); periods(8);                                     // 车头 +179.6°，主人再往右 20° → 世界方向回绕到 −160°
    head(-32700); deg(-20); periods(8); head(12000); deg(0); periods(10);
    // ---- 避障 ----
    set_free(255, 255, 255, 255, 80, 255, 255, 255, 255); periods(6);     // 正前方 80 cm：绕；左右一样近 → 先看的（左 5°）
    deg(2); periods(6);                                                   // 主人偏右一点：不换边（上次方向的代价）
    head(12000 - 15 * 182); periods(6);                                   // 车往左转了 15°：上次绕行的方向（世界）换算成相对车头 +10°（不换算就会选错）
    head(12000 + 90 * 182); periods(3);                                   // 车头一下差 90°：上次方向相对车头超出 ±63，限幅
    head(12000);
    all_free; periods(30);                                                // 障碍没了：先保持绕行的航向直走，再朝主人
    set_free(255, 255, 255, 255, 80, 255, 255, 255, 255); periods(8);     // 又挡了：上次的绕行方向已经作废
    all_free; periods(28);
    deg(15); set_free(255, 255, 255, 255, 255, 255, 255, 90, 255); periods(8);   // 正前方空、主人方向（11）挡：绕到 12
    set_free(80, 80, 90, 90, 90, 90, 90, 90, 80); deg(0); periods(8);          // 没有 ≥ AVOID 的：退到 ≥ CLEAR 里挑
    set_free(40, 30, 20, 10, 0, 10, 20, 30, 50); periods(4);                   // 都不到 CLEAR → BLK
    set_free(255, 255, 255, 255, 40, 255, 255, 255, 255); periods(25);          // 太近 → 原地转向能走的方向（另一组的轮子走到负向限幅）
    set_free(255, 255, 255, 255, 60, 255, 255, 255, 255); periods(3);          // 正好 SPIN_CM（60）：一边走一边绕（另一组 SPIN_CM 50，也是绕）
    set_free(255, 255, 255, 255, 150, 255, 255, 255, 255); periods(10);        // 正前方 150：不挡路，但前进被限（SPIN 以后先锁住现在的车头直走）
    all_free; periods(70);                                                     // 绕完直走按距离（默认约 50 个周期）走完，回到 GO
    set_free(70, 70, 70, 70, 50, 70, 70, 70, 70); periods(3);                  // 只有 ≥ CLEAR 的、左右 5° 一样：挑先看的（左）
    set_free(70, 70, 70, 60, 50, 59, 70, 70, 70); periods(3);                  // 正好 CLEAR（60）算能走，59 不算
    set_free(255, 255, 255, 100, 80, 99, 255, 255, 255); periods(3);           // 正好 AVOID（100）算能走，99 不算
    head(12000 + 4 * 182); periods(3); head(12000);                            // 绕行中车头小变：新的绕行方向在回差里不改目标
    lose; deg(17); set_free(255, 255, 255, 255, 255, 255, 255, 90, 255); periods(30);   // 17° 在 15° 和 19° 正中间
    set_free(255, 255, 255, 255, 255, 255, 255, 120, 255); periods(4);
    set_free(255, 255, 255, 255, 80, 255, 255, 50, 255); deg(99); periods(24); // 挡路绕到 19°，主人到侧面 → 原地转
    deg(50); periods(16);
    deg(-99); periods(10);                                                     // 一下跳到 0°：退出，挡路；原地转清掉了上次的 19°
    set_free(255, 255, 255, 60, 70, 60, 255, 255, 255); deg(100); periods(25); // 主人在侧面：原地转优先于绕行
    deg(0); all_free; periods(5);
    set_free(255, 255, 255, 255, 80, 255, 255, 255, 255); periods(3);
    cam_on = 0;                                                           // 相机断了 → NCAM；停的时候翻转信号正好是 1
    @(posedge clk);
    if (!otog) begin repeat (10) @(posedge clk); @(posedge oclk) otog <= 1'b1; age = 0; end
    periods(7);
    tgt_cm = 150; periods(2);                                             // 相机断了 + 主人很近：报 NCAM
    cam_on = 1; all_free; tgt_cm = 600; deg(30); periods(8);
    tgt_ok = 0; periods(2);                                               // UWB 丢了 → LOST
    tgt_ok = 1; deg(-30); tgt_cm = 450; periods(6);                       // 找回在左边：平滑从新角度开始
    deg(-45); rate_(-900); periods(30); rate_(0);                         // 误差大（积分分离：不积分）+ D 项
    set_free(255, 255, 255, 255, 40, 255, 255, 255, 255); deg(0); periods(10);   // SPIN
    all_free; periods(5);                                                 // 马上就不挡了：锁住现在的车头直走（hold）
    head(12000); deg(8); periods(250);                                    // 误差（目标航向追上一部分后约 5.6°，在积分区里）一直不变：积分到正的限幅
    // 上次绕行方向的换算（另一组 ANGLE_FILTER = 1：主人角度就是 UWB 角度，好造准确的场景）
    lose; head(12000); deg(2); set_free(255, 255, 255, 255, 80, 255, 255, 255, 255); periods(3);   // 挡路，主人偏右 2° → 选 +5°（上次方向 = 车头 + 5°）
    head(12000 + 4 * 182); deg(0); periods(1);                            // 车往右转 4°：上次方向相对车头 182 个单位（四舍五入 1°，向 0 取整 0°）；主人正前方，±5° 打平，靠上次方向挑
    lose; head(12000); deg(17); set_free(255, 255, 255, 255, 80, 255, 255, 90, 255); periods(3);  // 15° 挡 → 选 19°
    head(12000 - 51 * 182); set_free(255, 255, 255, 255, 80, 255, 255, 255, 255); periods(1);    // 车往左转 51°：上次方向相对车头 +70°（限到 63；不限按 6 位回绕成 6 会选 15°）
    all_free; lose; head(12000); deg(0); periods(2);                      // 停一下（积分清零），目标航向 = 主人 = 车头
    head(12000 + 8 * 182); deg(-8); periods(200);                         // 车头往右偏 8°、主人还在原来的世界方向：误差正好 −8°，积分到负的限幅
    // ---- 远处挡路：主人那个方向 T = min(AVOID_FAR_CM, 距离 − OWNER_GAP_CM) 以内有东西 → 提前绕 ----
    lose; head(12000); deg(0); tgt_cm = 400; all_free; periods(3);          // T：默认 min(200, 340) = 200；另一组 min(180, 240) = 180
    set_free(255, 255, 255, 255, 199, 255, 255, 255, 255); periods(4);       // 199：默认提前绕（左右一样 → 先看的左 5°），另一组 ≥ 180 不绕
    set_free(255, 255, 255, 255, 200, 255, 255, 255, 255); periods(4);       // 正好 200：默认不绕
    set_free(255, 255, 255, 255, 180, 255, 255, 255, 255); periods(3);       // 180：默认绕，另一组正好 180 不绕
    set_free(255, 255, 255, 255, 179, 255, 255, 255, 255); periods(3);       // 179：两组都绕
    deg(2); periods(4);                                                      // 主人偏右 2°：不换边（上次方向的代价）
    head(12000 - 3 * 182); periods(3);                                       // 车头往左 3°：新的绕行方向在回差里，不改目标
    head(12000 - 7 * 182); periods(3);                                       // 再往左（共 7°）：超出回差，改目标
    head(12000); deg(0);
    set_free(150, 150, 150, 150, 150, 150, 150, 150, 150); periods(4);       // 哪边都不到 T：照常 GO（近了再绕）
    all_free; periods(3);
    tgt_cm = 250; set_free(255, 255, 255, 255, 190, 255, 255, 255, 255); periods(3);   // 主人 250：默认 T = 250 − 60 = 190，正好 190 不绕（另一组 T = 90）
    set_free(255, 255, 255, 255, 189, 255, 255, 255, 255); periods(3);       // 189：默认绕
    tgt_cm = 155; set_free(255, 255, 255, 255, 130, 255, 255, 255, 255); periods(3);   // 另一组：主人 155 比间距 160 还近 → T = 0，不绕（默认 HERE）
    lose; tgt_cm = 400; deg(22); set_free(255, 255, 255, 255, 255, 255, 255, 255, 150); periods(4);   // 主人 22°：离它最近的方向 19° 差 3° → 算（绕到 15°）
    lose; deg(23); periods(4);                                               // 23°：差 4° → 不算
    lose; deg(10); set_free(190, 190, 190, 190, 255, 190, 150, 190, 190); periods(30); // 主人 10°（那个方向 150）：另一组绕到 5°（190），前进按 min(正前方, 190) 限（等斜坡爬上去：限幅要真起作用）
    all_free; deg(0); periods(6);
    // ---- 绕完直走那段不原地转（车头扫过的地方相机看不到）；挡着路的时候照常原地转（上面"原地转优先于绕行"）----
    lose; head(12000); deg(0); tgt_cm = 400; set_free(255, 255, 255, 255, 80, 255, 255, 255, 255); periods(5);
    all_free; deg(99); periods(80);                                          // 不挡了、主人到侧面：先走完直走那段（按前进量累加），马上原地转
    deg(0); periods(10);
    // ---- 找出口（车头由测试台给）----
    lose; head(12000); deg(30); tgt_cm = 400; all_free; periods(3);
    set_free(30, 30, 30, 30, 30, 30, 30, 30, 30);                            // 哪边都不到 CLEAR：先停下看，再往主人那边（右）一步一步转
    scan_mode = 1; for (t = 0; t < 600 && !stuck[0]; t = t + 1) scan_drive;   // 正好转满一圈 → 困住（另一组 100° 一步，转满一圈先到）
    if (!stuck[0] || !stuck[1]) begin $display("FAIL scan: never got stuck (%0d %0d)", stuck[0], stuck[1]); errors = errors + 1; end
    periods(5);                                                              // 困住了：一直停着（BLK），O_stuck = 1
    yaw0 = w16(yaw0 - 1); periods(3);                                        // 困住以后车头往回滑 1 个单位（加起来又差 1 个单位一圈）：还是困住，不再转
    deg(99); periods(20); deg(30); periods(2);                               // 困住的时候主人到侧面：不原地转
    set_free(30, 30, 30, 30, 30, 30, 30, 30, 255); periods(4);               // 右 19° 能走了：照常原地转向它（SPIN），不再困住
    set_free(30, 30, 30, 30, 30, 30, 30, 30, 30);                            // 又全挡：重新找（先停下看）
    scan_mode = 0; for (t = 0; t < 600 && !stuck[0]; t = t + 1) scan_drive;   // 差 1 个单位一圈：再转一步才困住
    if (!stuck[0]) begin $display("FAIL scan: never got stuck the second time"); errors = errors + 1; end
    lose; deg(-30); periods(14);                                             // 停车（LOST）以后找出口作废；主人在左：往左转
    set_free(255, 30, 30, 30, 30, 30, 30, 30, 30); periods(3);               // 转的时候左边出现能走的：照常绕
    set_free(30, 30, 30, 30, 30, 30, 30, 30, 30); deg(10); periods(3);
    deg(99); periods(30);                                                    // 找出口的时候主人到了侧面：不原地转
    tgt_cm = 150; periods(2);                                                // HERE：找出口作废
    deg(10); periods(2);                                                     // （主人还在侧面就先原地转向主人：全挡着也是）
    tgt_cm = 400; periods(115);                                              // 重新找；另一组每步都转不动 → 转了 8 步（2 圈的步数）就困住
    lose; periods(2);                                                        // LOST：困住作废
    all_free; deg(0); periods(5);

    // ======== B. 闭环：车的模型 ========
    VPWM = 1.15e-4; TRACK = 0.130;
    PG = VPWM / TRACK * 65536.0 / (2.0 * PI) / 1000.0;   // = 0.0092：两轮差 1 PWM → 0.05°/s（转向 400 = 两轮差 800 ≈ 40°/s）
    PB = 0.0007;                              // 偏差：两轮都 4000 时自己往右偏约 15°/s
    for (i = 0; i < 2; i = i + 1) begin yr[i] = 5000.0; vl[i] = 0.0; vr[i] = 0.0; owner[i] = 5000.0; end
    lose; tgt_cm = 800; all_free; plant = 1; head(5000); deg(0);
    track(50);
    $display("closed loop start: loop error %0.2f ~ %0.2f, owner %0.2f ~ %0.2f deg (1st second)", emin, emax, omin, omax);
    track(150);
    track(100);
    $display("closed loop straight: loop error %0.2f ~ %0.2f, owner %0.2f ~ %0.2f deg (4~6 s)", emin, emax, omin, omax);
    if (emax > 1.0 || emin < -1.0) begin $display("FAIL closed loop: does not hold the heading with motor imbalance"); errors = errors + 1; end
    owner[0] = owner[0] + 30.0 * 182.04; owner[1] = owner[1] + 30.0 * 182.04;   // 主人往右 30°
    track(50);
    $display("closed loop 30 deg step: loop error %0.2f ~ %0.2f, owner %0.2f ~ %0.2f deg (1st second)", emin, emax, omin, omax);
    if (omin < -6.0) begin $display("FAIL closed loop: overshoot more than 6 deg"); errors = errors + 1; end
    track(50);
    $display("closed loop 30 deg step: loop error %0.2f ~ %0.2f, owner %0.2f ~ %0.2f deg (2nd second)", emin, emax, omin, omax);
    if (emax > P_DB[0] + 0.5 || emin < -P_DB[0] - 0.5 || omax > 6.0 || omin < -6.0) begin $display("FAIL closed loop: not settled within 2 s"); errors = errors + 1; end   // 最后一次改目标（≤ 回差）可能落在第 2 秒
    track(50);
    $display("closed loop 30 deg step: loop error %0.2f ~ %0.2f, owner %0.2f ~ %0.2f deg (3rd second)", emin, emax, omin, omax);
    if (emax > 1.5 || emin < -1.5 || omax > 6.0 || omin < -6.0) begin $display("FAIL closed loop: not settled within 3 s"); errors = errors + 1; end
    sv = cnt[4];
    owner[0] = owner[0] + 175.0 * 182.04; owner[1] = owner[1] + 175.0 * 182.04; // 主人在右后方（10-31 转向调快后，150° 在 0.3 秒确认完之前就转回 90° 以内了，边走边转，不原地转）
    track(100); track(50);
    $display("closed loop owner behind: TURN periods %0d, loop error %0.2f ~ %0.2f, owner %0.2f ~ %0.2f deg (last second)", cnt[4] - sv, emin, emax, omin, omax);
    if (cnt[4] - sv < 5) begin $display("FAIL closed loop: did not pivot"); errors = errors + 1; end
    if (omax > 6.0 || omin < -6.0) begin $display("FAIL closed loop: not facing the owner after the pivot"); errors = errors + 1; end
    set_free(255, 255, 255, 255, 80, 255, 255, 255, 255); periods(15);   // 绕障
    all_free; periods(60);
    // 找出口：四面都是墙，只有一个口子（在主人那边，车头右 70°）
    lose; tgt_cm = 800;
    world_gap = yr[0] + 70.0 * 182.04; owner[0] = world_gap; owner[1] = yr[1] + 70.0 * 182.04;
    world_open = 1; world_on = 1;
    sv = cnt[3]; sv2 = cnt[7];
    track(100); track(50);
    $display("closed loop scan to a gap: BLK %0d SPIN %0d periods, owner %0.2f ~ %0.2f deg (last second)", cnt[3] - sv, cnt[7] - sv2, omin, omax);
    if (cnt[3] - sv < 10 || cnt[7] - sv2 < 2) begin $display("FAIL closed loop: did not scan for the gap"); errors = errors + 1; end
    if (stuck[0] || omax > 6.0 || omin < -6.0) begin $display("FAIL closed loop: not heading through the gap"); errors = errors + 1; end
    // 没有口子：转满一圈以后困住、停着
    world_open = 0; turned = 0.0;
    for (t = 0; t < 600 && !stuck[0]; t = t + 1) begin yp = yaw0; periods(1); turned = turned + hdeg(yaw0, yp); end
    $display("closed loop no gap: stuck after %0d periods, turned %0.1f deg", t, turned);
    if (!stuck[0] || turned < 360.0 && turned > -360.0 || turned > 450.0 || turned < -450.0) begin $display("FAIL closed loop: should give up after turning one full circle"); errors = errors + 1; end
    periods(10); yp = yaw0; periods(10);
    if (!stuck[0] || hdeg(yaw0, yp) > 0.5 || hdeg(yaw0, yp) < -0.5) begin $display("FAIL closed loop: should stay stopped while stuck"); errors = errors + 1; end
    world_gap = yr[0]; world_open = 1; periods(10);                     // 车头前面出现口子：出来
    if (stuck[0]) begin $display("FAIL closed loop: still stuck with a gap ahead"); errors = errors + 1; end
    world_on = 0; all_free;
    plant = 0; rate_(0);
    repeat (5) one_tick;

    $display("states: LOST %0d NCAM %0d HERE %0d BLK %0d TURN %0d GO %0d AVD %0d SPIN %0d NIMU %0d; tie %0d hyst %0d fallback %0d limit %0d clamp %0d pend-reset %0d reacquire %0d",
             cnt[0], cnt[1], cnt[2], cnt[3], cnt[4], cnt[5], cnt[6], cnt[7], cnt[8], c_tie, c_hyst, c_fallback, c_lim, c_clampw, c_pend_reset, c_reacq);
    for (i = 0; i < 9; i = i + 1) if (cnt[i] < 2) begin $display("FAIL scene setup: state %0d seen %0d times", i, cnt[i]); errors = errors + 1; end
    if (c_tie < 1 || c_hyst < 1 || c_fallback < 1 || c_lim < 1 || c_clampw < 1 || c_pend_reset < 1 || c_reacq < 1) begin
        $display("FAIL scene setup: some branch was not exercised"); errors = errors + 1;
    end
    $display("edges: piv90 %0d spin45 %0d avoid100 %0d clear60 %0d near-tie %0d fallback-tie %0d side-limit %0d hold-limit %0d ncam-near %0d flip %0d reenter %0d stale-go %0d stale-turn %0d clamp-neg %0d",
             c_e_piv, c_e_spin, c_e_avoid, c_e_clear, c_ntie, c_btie, c_slim, c_hlim, c_ncam_near, c_flip, c_reenter, c_stale_go, c_stale_turn, c_clampn);
    $display("slew %0d izone %0d prev-round %0d prev-wrap %0d stop-go %0d half-degree %0d", c_slew, c_izone, c_prnd, c_pwrap, c_stopgo, c_half);
    if (c_slew < 1 || c_izone < 1 || c_prnd < 1 || c_pwrap < 1 || c_stopgo < 1 || c_half < 1) begin $display("FAIL scene setup: slew / integral zone / prev-direction conversion / stop-go / half degree not exercised"); errors = errors + 1; end
    $display("heading: db-keep %0d db-equal %0d db-retarget+1 %0d avd-keep %0d avd-retarget %0d hold-lock %0d wrap %0d dterm %0d iclamp %0d/%0d tclamp go %0d avd %0d e-floor %0d prev-clamp %0d prev-rotated %0d nimu %0d lost+nimu %0d round %0d",
             c_dbkeep, c_dbeq, c_dbret, c_avkeep, c_avret, c_holdlock, c_wrap, c_dterm, c_iclp, c_iclpn, c_tclp, c_tclpa, c_efloor, c_pclamp, c_prot, c_nimu, c_lostnimu, c_round);
    if (c_e_piv < 16 || c_e_spin < 1 || c_e_avoid < 1 || c_e_clear < 1 || c_ntie < 1 || c_btie < 1 || c_slim < 1 || c_hlim < 1 ||
        c_ncam_near < 1 || c_flip < 1 || c_reenter < 1 || c_stale_go < 1 || c_stale_turn < 1 || c_clampn < 1) begin
        $display("FAIL scene setup: some edge case was not exercised"); errors = errors + 1;
    end
    if (c_dbkeep < 1 || c_dbeq < 1 || c_dbret < 1 || c_avkeep < 1 || c_avret < 1 || c_holdlock < 1 || c_wrap < 1 || c_dterm < 1 || c_iclp < 1 || c_iclpn < 1 ||
        c_tclp < 1 || c_tclpa < 1 || c_efloor < 1 || c_pclamp < 1 || c_prot < 1 || c_nimu < 2 || c_lostnimu < 2 || c_round < 1) begin
        $display("FAIL scene setup: some heading-loop case was not exercised"); errors = errors + 1;
    end
    $display("far: avd %0d edge %0d gap %0d ang3 %0d ang4 %0d none %0d t0 %0d limit %0d hyst %0d keep %0d retarget %0d; hold-part %0d nopiv hold %0d scan %0d pivot-after %0d",
             c_far, c_far_eq, c_far_gap, c_far_ang3, c_far_ang4, c_far_none, c_far_t0, c_far_lim, c_far_hyst, c_far_keep, c_far_ret, c_hold_part, c_nopiv_hold, c_nopiv_scan, c_piv_after);
    $display("scan: start %0d exit %0d stop %0d left %0d short-1 %0d backwards %0d exact %0d timeout %0d stuck %0d stuck-stay %0d",
             c_sc_start, c_sc_exit, c_sc_stop, c_sc_left, c_sc_lt, c_sc_neg, c_sc_eq, c_sc_to, c_stuck, c_stuck_stay);
    if (c_far < 1 || c_far_eq < 2 || c_far_gap < 1 || c_far_ang3 < 2 || c_far_ang4 < 2 || c_far_none < 1 || c_far_t0 < 1 || c_far_lim < 1 ||
        c_far_hyst < 1 || c_far_keep < 1 || c_far_ret < 1 || c_hold_part < 1 || c_nopiv_hold < 1 || c_nopiv_scan < 1 || c_piv_after < 1) begin
        $display("FAIL scene setup: some far-obstacle / hold case was not exercised"); errors = errors + 1;
    end
    $display("scan total: exact-circle %0d one-short %0d step-limit %0d", c_tot_eq, c_tot_lt, c_stuck_max);
    if (c_sc_start < 3 || c_sc_exit < 2 || c_sc_stop < 2 || c_sc_left < 1 || c_sc_lt < 1 || c_sc_neg < 1 || c_sc_eq < 1 || c_sc_to < 1 || c_stuck < 2 || c_stuck_stay < 1 ||
        c_tot_eq < 1 || c_tot_lt < 1 || c_stuck_max < 1) begin
        $display("FAIL scene setup: some scan case was not exercised"); errors = errors + 1;
    end
    if (errors == 0) $display("PASS  tb_follow");
    else             $display("FAIL  tb_follow: %0d error(s)", errors);
    $finish;
end

initial begin #900_000_000; $display("FAIL  tb_follow: timeout"); $finish; end

endmodule
