`timescale 1ns / 1ps
// 测试 mc_follow（跟随 + 避障决策）。
//   测试台按规格独立算每 20 个毫秒节拍的期望（整数运算，不照 RTL 的状态机），每次 O_cmd_valid 核对：停 / 左右轮 / 状态 / 选的方向。
//     状态：没 UWB → LOST；100 个节拍没有新的避障结果 → NCAM；距离 ≤ 300 → HERE；|角度| > 35 → TURN；
//           否则在方向 4~12（按 8,7,9,6,10,5,11,4,12 看）里挑能走 ≥ 60 cm、和主人角度差最小的（严格更小才换）→ GO，没有 → BLK。
//     GO：前进 = (距离 − 300) × KP_D 限在 600~MAX_FWD，再不超过 (能走多远 − 35) × 50；转向 = 方向角 × KP_A；TURN：前进 0、转向 = 主人角度 × KP_A。
//     左 = 前进 + 转向、右 = 前进 − 转向，限 ±6500；斜坡（目标绝对值比现在小每次最多 400，否则 200）；停的时候归 0。
//     方向角 = round(atan((120b − 960) × cos15° / F) 度)，F = 960 / tan36°（独立按公式算）。
//   两个实例：默认参数（KP_D 4、KP_A 35、MAX_FWD 6000）和"猛"参数（KP_D 12、KP_A 80），后者让前进限幅、±6500 限幅真的起作用。
//   避障结果由另一个时钟（111 MHz）送：每 5 个节拍翻转一次，数据保持不变；"相机断了"就不翻转。
//   每个命令也核对时间：两次命令之间正好 20 个节拍。选的方向从左右轮的差（方向角 × KP_A）和前进上限看得出来。
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
mc_follow #(.KP_D(12), .KP_A(80)) d1 (.I_clk(clk), .I_rst_n(rst_n), .I_tick_1ms(tick), .I_tgt_ok(tgt_ok), .I_tgt_deg(tgt_deg), .I_tgt_cm(tgt_cm),
              .I_obs_tog(otog), .I_obs_free(ofree), .O_cmd_valid(v1), .O_cmd_stop(s1), .O_cmd_l(l1), .O_cmd_r(r1), .O_state(st1));

integer errors = 0;
always @(errors) if (errors > 20) begin #1; $display("FAIL  tb_follow: too many errors"); $finish; end

// ---------------- 模型 ----------------
integer HEAD_DEG [0:15];
integer cl [0:1], cr [0:1];               // 两个实例的斜坡状态
integer kp_d [0:1], kp_a [0:1];
integer age;                              // 避障结果的"年龄"（节拍）
integer e_stop [0:1], e_l [0:1], e_r [0:1], e_st [0:1];
integer cnt_go, cnt_turn, cnt_blk, cnt_here, cnt_ncam, cnt_lost, cnt_clamp_fwd, cnt_clamp_wheel, cnt_obslim, cnt_dec, cnt_tie;

function integer iabs; input integer x; iabs = (x < 0) ? -x : x; endfunction
function integer ramp;
    input integer cur, tgt;
    integer st;
    begin
        st = (iabs(tgt) < iabs(cur)) ? 400 : 200;
        ramp = (tgt - cur > st) ? cur + st : (tgt - cur < -st) ? cur - st : tgt;
    end
endfunction
function integer fr; input integer b; fr = ofree[8*(b-4) +: 8]; endfunction

task decide;                              // 这一次的期望（两个实例）
    integer i, m, k, b, d, bd, bb, fw, fo, tn, tl, tr, deg, adeg;
    begin
        deg = tgt_deg; adeg = iabs(deg);
        for (i = 0; i < 2; i = i + 1) begin
            bb = 0; bd = 1000; tl = 0; tr = 0;
            if (!tgt_ok)            m = 0;
            else if (age >= 100)    m = 1;
            else if (tgt_cm <= 300) m = 2;
            else if (adeg > 35)     m = 4;
            else begin
                for (k = 0; k < 9; k = k + 1) begin
                    b = (k % 2 == 0) ? 8 + k / 2 : 8 - (k + 1) / 2;
                    d = iabs(HEAD_DEG[b] - deg);
                    if (i == 0 && fr(b) >= 60 && bb != 0 && d == bd) cnt_tie = cnt_tie + 1;
                    if (fr(b) >= 60 && d < bd) begin bd = d; bb = b; end
                end
                m = (bb == 0) ? 3 : 5;
            end
            if (m == 4) begin
                tn = deg * kp_a[i];
                tl = tn; tr = -tn;
            end else if (m == 5) begin
                fw = (tgt_cm - 300) * kp_d[i];
                if (fw < 600) fw = 600;
                if (fw > 6000) begin fw = 6000; if (i == 1) cnt_clamp_fwd = cnt_clamp_fwd + 1; end
                fo = (fr(bb) - 35) * 50;
                if (fo < fw) begin fw = fo; if (i == 0) cnt_obslim = cnt_obslim + 1; end
                tn = HEAD_DEG[bb] * kp_a[i];
                tl = fw + tn; tr = fw - tn;
            end
            if (tl > 6500 || tl < -6500 || tr > 6500 || tr < -6500) if (i == 1) cnt_clamp_wheel = cnt_clamp_wheel + 1;
            if (tl > 6500) tl = 6500; if (tl < -6500) tl = -6500;
            if (tr > 6500) tr = 6500; if (tr < -6500) tr = -6500;
            if (m == 4 || m == 5) begin
                if (i == 0 && (iabs(tl) < iabs(cl[i]) || iabs(tr) < iabs(cr[i])) && (cl[i] - tl > 400 || tl - cl[i] > 400 || cr[i] - tr > 400 || tr - cr[i] > 400)) cnt_dec = cnt_dec + 1;
                cl[i] = ramp(cl[i], tl); cr[i] = ramp(cr[i], tr);
                e_stop[i] = 0;
            end else begin
                cl[i] = 0; cr[i] = 0; e_stop[i] = 1;
            end
            e_l[i] = cl[i]; e_r[i] = cr[i]; e_st[i] = m;
            if (i == 0) case (m) 0: cnt_lost = cnt_lost + 1; 1: cnt_ncam = cnt_ncam + 1; 2: cnt_here = cnt_here + 1;
                                 3: cnt_blk = cnt_blk + 1; 4: cnt_turn = cnt_turn + 1; default: cnt_go = cnt_go + 1; endcase
        end
    end
endtask

// ---------------- 节拍 + 避障结果 ----------------
localparam TICK = 200;                    // 一个"毫秒"节拍 = 200 个时钟（仿真加速）
integer ntick = 0;
reg     cam_on = 0;
integer pending = 0;                      // 1：这一拍的命令还没核对
integer last_cmd_tick = -1;
task one_tick;
    begin
        repeat (TICK - 1) @(posedge clk);
        @(posedge clk) tick <= 1'b1;
        @(posedge clk) tick <= 1'b0;
        ntick = ntick + 1;
        if (ntick % 20 == 0) begin decide; pending = 1; end
        if (age < 100) age = age + 1;
        // 相机：每 5 个节拍出一次结果（在节拍之后 10 个时钟翻转，下一个节拍之前早就取到了）
        if (cam_on && ntick % 5 == 0) begin
            repeat (10) @(posedge clk);
            @(posedge oclk) otog <= ~otog;
            age = 0;
        end
    end
endtask

// 命令核对（两个实例同一拍出）
always @(posedge clk) if (v0) begin
    if (!pending) begin $display("FAIL command without a decision tick (tick %0d)", ntick); errors = errors + 1; end
    if (last_cmd_tick >= 0 && ntick - last_cmd_tick != 20) begin $display("FAIL commands %0d ticks apart", ntick - last_cmd_tick); errors = errors + 1; end
    last_cmd_tick = ntick;
    pending = 0;
    if (s0 !== e_stop[0][0] || l0 !== e_l[0] || r0 !== e_r[0] || st0 !== e_st[0]) begin
        $display("FAIL [default] tick %0d: stop %b L %0d R %0d state %0d, expected %0d %0d %0d %0d (ok %b deg %0d cm %0d age %0d)",
                 ntick, s0, l0, r0, st0, e_stop[0], e_l[0], e_r[0], e_st[0], tgt_ok, tgt_deg, tgt_cm, age);
        errors = errors + 1;
    end
    if (!v1 || s1 !== e_stop[1][0] || l1 !== e_l[1] || r1 !== e_r[1] || st1 !== e_st[1]) begin
        $display("FAIL [strong] tick %0d: valid %b stop %b L %0d R %0d state %0d, expected %0d %0d %0d %0d",
                 ntick, v1, s1, l1, r1, st1, e_stop[1], e_l[1], e_r[1], e_st[1]);
        errors = errors + 1;
    end
end

task periods;                             // 跑 n 个 20 ms 周期（输入在周期之间不变）
    input integer n;
    integer t;
    for (t = 0; t < n * 20; t = t + 1) one_tick;
endtask
task set_free;                            // 方向 4~12 的"能走多远"
    input [7:0] f4, f5, f6, f7, f8, f9, f10, f11, f12;
    ofree = {f12, f11, f10, f9, f8, f7, f6, f5, f4};
endtask

// ---------------- 场景 ----------------
real PI, F, ct;
integer b, i;
initial begin
    PI = 3.14159265358979; F = 960.0 / $tan(36.0 * PI / 180.0); ct = $cos(15.0 * PI / 180.0);
    for (b = 0; b < 16; b = b + 1) begin
        HEAD_DEG[b] = $rtoi($atan((120.0 * b - 960.0) * ct / F) * 180.0 / PI + ((b >= 8) ? 0.5 : -0.5));
    end
    kp_d[0] = 4; kp_a[0] = 35; kp_d[1] = 12; kp_a[1] = 80;
    for (i = 0; i < 2; i = i + 1) begin cl[i] = 0; cr[i] = 0; end
    age = 100;
    cnt_go = 0; cnt_turn = 0; cnt_blk = 0; cnt_here = 0; cnt_ncam = 0; cnt_lost = 0; cnt_clamp_fwd = 0; cnt_clamp_wheel = 0; cnt_obslim = 0; cnt_dec = 0; cnt_tie = 0;
    repeat (5) @(posedge clk); rst_n = 1;

    periods(2);                                                       // 没 UWB → LOST
    tgt_ok = 1; tgt_deg = 0; tgt_cm = 500; periods(2);                // 有 UWB、没相机 → NCAM
    cam_on = 1; set_free(255, 255, 255, 255, 255, 255, 255, 255, 255);
    periods(6);                                                       // 全空、正前方 → GO 方向 8，斜坡加上去
    tgt_deg = 12; periods(3);                                         // 右 12°：方向 10（10°）
    set_free(255, 255, 255, 255, 255, 255, 59, 255, 255); periods(2); // 方向 10 只有 59 cm（< 60）→ 方向 11（差 3°）
    set_free(255, 255, 255, 255, 255, 255, 60, 255, 255); periods(2); // 正好 60 → 又可以
    tgt_deg = 0; set_free(255, 255, 255, 255, 40, 255, 255, 255, 255); periods(2);   // 正前方挡住，7 和 9 一样近 → 先看的 7
    tgt_deg = -3; periods(2);
    set_free(255, 255, 255, 100, 70, 70, 255, 255, 255); tgt_deg = 0; tgt_cm = 800; periods(3);   // 正前方 70 cm：前进 2000 被避障限到 (70 − 35) × 50
    set_free(59, 30, 20, 10, 0, 10, 20, 30, 59); periods(3);          // 都不到 60 → BLK，归 0
    set_free(255, 255, 255, 255, 255, 255, 255, 255, 255);
    tgt_cm = 301; periods(2);                                         // 301：前进下限 600
    tgt_cm = 300; periods(2);                                         // 300 → HERE
    tgt_cm = 999; periods(34);                                        // 远：斜坡加满以后，猛参数的前进停在 6000（不是 8388）
    tgt_deg = 19; periods(4);
    tgt_deg = 35; periods(3);                                         // 35：还在视场里
    tgt_deg = 36; periods(8);                                         // 36 → 原地转（右），转到稳定
    tgt_deg = -36; periods(4);                                        // 反过来，绝对值一样：斜坡按"加速"走（不是减速）
    tgt_deg = 99; periods(52);                                        // 右 99 转到稳定（右轮从 +2880 走到 −6500 要 47 次）：猛参数 ±7920 被限到 ±6500
    tgt_deg = -99; periods(6);                                        // 左 99：原地转（左），反向
    tgt_deg = 0; periods(6);                                          // 回到正前方：减速的斜坡
    cam_on = 0; periods(6);                                           // 相机断了：100 个节拍以后 NCAM
    cam_on = 1; periods(2);
    tgt_ok = 0; periods(2);                                           // UWB 丢了 → LOST
    tgt_ok = 1; tgt_cm = 450; tgt_deg = -20; periods(5);
    tgt_deg = -36; periods(3);
    repeat (5) one_tick;

    $display("decisions: GO %0d TURN %0d BLK %0d HERE %0d NCAM %0d LOST %0d; ties %0d, obstacle limit %0d, decel %0d; strong: forward clamp %0d, wheel clamp %0d",
             cnt_go, cnt_turn, cnt_blk, cnt_here, cnt_ncam, cnt_lost, cnt_tie, cnt_obslim, cnt_dec, cnt_clamp_fwd, cnt_clamp_wheel);
    if (cnt_go < 10 || cnt_turn < 5 || cnt_blk < 2 || cnt_here < 2 || cnt_ncam < 2 || cnt_lost < 2 || cnt_tie < 1 || cnt_obslim < 1 ||
        cnt_dec < 1 || cnt_clamp_fwd < 1 || cnt_clamp_wheel < 1) begin
        $display("FAIL scene setup: some branch was not exercised"); errors = errors + 1;
    end
    if (last_cmd_tick < 0) begin $display("FAIL no command at all"); errors = errors + 1; end
    if (errors == 0) $display("PASS  tb_follow");
    else             $display("FAIL  tb_follow: %0d error(s)", errors);
    $finish;
end

initial begin #100_000_000; $display("FAIL  tb_follow: timeout"); $finish; end

endmodule
