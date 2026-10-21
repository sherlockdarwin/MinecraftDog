`timescale 1ns / 1ps
// 测试 自动曝光 mc_ae + 厂商 I2C 配置 uicfgimx415（改过的 AE 部分）+ 记录式 I2C 从机。
//   I2C 调到 1 MHz（CLK_DIV = 23）以加快仿真，其余和上板一样（初始 201 条寄存器、每 1,000,001 拍重写一次待机寄存器）。
//   模型（测试台自己按规格写）：目标 T = 48 + 16 × 档位；平均值 m 与 T 比：
//     m < 0.5T +24 ｜< 0.6875T +12 ｜< 0.84375T +5 ｜< 0.9375T +2 ｜> 2T −24 ｜> 1.5T −12 ｜> 1.1875T −5 ｜> 1.0625T −2 ｜其余不动；
//     调亮：曝光没到 2275 就曝光 × round(256·10^(0.015d))/256（至少 +1，最多 2275），到了就增益 +d（最多 150）；
//     调暗：增益 > 0 就增益 −d（最少 0），否则曝光 × round(256/10^(0.015d))/256（至少 −1，最少 4）。
//     写完寄存器后第 3 帧的统计才算数（前两帧给相反的诱饵值）；不用改时下一帧接着算。
//   检查：初始寄存器写完后，I2C 上只允许出现两种完整的序列：待机重写（3000=00, 3002=00）和曝光序列
//     （3001=01, 3050=SHR0 低, 3051=SHR0 高, 3090=增益, 3091=00, 3001=00）；每个曝光序列的值和模型给的一致、个数一致；
//     O_exp / O_gain / O_ev 和模型一致；档位键 +/− 到头不再变。
//   场景：初始写（曝光最长、增益 0）、一直暗（增益加到 150 封顶）、一直亮（增益减到 0、曝光一路缩短到 4）、
//     最小步长（曝光很短时 ×1.07 也至少 +1）、各档阈值和正好等于阈值的值、档位键、
//     曝光序列写到一半碰上待机重写（不许打断）、请求在待机重写过程中到来（等它写完再写，不许从中间接着写）。
module tb_ae;

reg clk = 0, rst_n = 0;
always #20 clk = ~clk;                      // 25 MHz（上板 24 MHz，无所谓）

reg  [7:0] mean = 0;
reg        tog = 0;
reg  [1:0] key_n = 2'b11;
wire       scl, sda;
pullup (sda);

wire        req, wr_done, cfg_done;
wire [15:0] shr0;
wire [7:0]  gain;
wire [11:0] exp_l;
wire [3:0]  ev;

mc_ae u_ae (
    .I_clk(clk), .I_rst_n(rst_n), .I_cfg_done(cfg_done), .I_wr_done(wr_done),
    .I_mean(mean), .I_mean_tog(tog), .I_key_n(key_n),
    .O_req(req), .O_shr0(shr0), .O_gain(gain), .O_exp(exp_l), .O_ev(ev)
);
uicfgimx415 #(.CLK_DIV(23)) u_cfg (
    .I_clk(clk), .I_rst_n(rst_n), .I_ae_req(req), .I_ae_shr0(shr0), .I_ae_gain(gain),
    .O_cam_scl(scl), .IO_cam_sda(sda), .O_cfg_done(cfg_done), .O_ae_cfg_done(wr_done)
);
i2c_rec_slave u_slv (.scl(scl), .sda(sda));

integer errors = 0;
always @(errors) if (errors > 20) begin #1; $display("FAIL  tb_ae: too many errors"); $finish; end

// ---------------- 模型 ----------------
integer M_E = 2275, M_G = 0, M_EV = 4, skip = 99;   // skip：还要跳过几帧（99 = 还没开始）
integer exp_q_e [0:255], exp_q_g [0:255], q_w = 0, q_r = 0;
integer n_eval = 0, n_change = 0;

function integer kfac;                      // 曝光倍数 ×256
    input integer d, up;
    real f;
    begin
        f = $pow(10.0, 0.015 * d);
        kfac = up ? $rtoi(256.0 * f + 0.5) : $rtoi(256.0 / f + 0.5);
    end
endfunction

task model_eval;
    input integer m;
    integer T, d, up, e1, ne, ng;
    real r;
    begin
        T = 48 + 16 * M_EV;
        r = m * 1.0 / T;
        d = 0; up = 1;
        if      (r < 0.5)     begin d = 24; up = 1; end
        else if (r < 0.6875)  begin d = 12; up = 1; end
        else if (r < 0.84375) begin d = 5;  up = 1; end
        else if (r < 0.9375)  begin d = 2;  up = 1; end
        else if (r > 2.0)     begin d = 24; up = 0; end
        else if (r > 1.5)     begin d = 12; up = 0; end
        else if (r > 1.1875)  begin d = 5;  up = 0; end
        else if (r > 1.0625)  begin d = 2;  up = 0; end
        ne = M_E; ng = M_G;
        if (d != 0) begin
            if (up) begin
                if (M_E < 2275) begin
                    e1 = (M_E * kfac(d, 1)) / 256;
                    ne = (e1 <= M_E) ? M_E + 1 : ((e1 > 2275) ? 2275 : e1);
                end else
                    ng = (M_G + d > 150) ? 150 : M_G + d;
            end else begin
                if (M_G > 0)
                    ng = (M_G > d) ? M_G - d : 0;
                else begin
                    e1 = (M_E * kfac(d, 0)) / 256;
                    ne = (e1 >= M_E) ? ((M_E > 4) ? M_E - 1 : 4) : ((e1 < 4) ? 4 : e1);
                end
            end
        end
        n_eval = n_eval + 1;
        if (ne != M_E || ng != M_G) begin
            M_E = ne; M_G = ng;
            exp_q_e[q_w % 256] = ne; exp_q_g[q_w % 256] = ng; q_w = q_w + 1;
            skip = 2;                       // 写完以后前两帧不算
            n_change = n_change + 1;
        end else
            skip = 0;
    end
endtask

// 一帧：先把平均值放好，过一会儿翻转（像素时钟域，和 clk 不对齐），再等一帧的时间
localparam FRAME_GAP = 12000;
task frame;
    input integer m;
    begin
        mean = m;
        #13 tog = ~tog;
        if (skip == 0) model_eval(m);
        else if (skip != 99) skip = skip - 1;
        repeat (FRAME_GAP) @(posedge clk);
    end
endtask
// 让下一帧一定被算：先送诱饵帧（值和 m 相反，被算到的话结果会不一样）
task eval_frame;
    input integer m;
    begin
        while (skip > 0) frame((m < 128) ? 255 : 0);
        frame(m);
    end
endtask
task check_outputs;
    input [8*24-1:0] what;
    begin
        if (exp_l !== M_E || gain !== M_G || ev !== M_EV || shr0 !== 2283 - M_E) begin
            $display("FAIL %0s: exp %0d gain %0d ev %0d shr0 %0d, expected %0d %0d %0d %0d", what, exp_l, gain, ev, shr0, M_E, M_G, M_EV, 2283 - M_E);
            errors = errors + 1;
        end
    end
endtask
task key;                                   // 按一下档位键（低电平 200 拍）
    input integer up;
    begin
        if (up) key_n[0] = 1'b0; else key_n[1] = 1'b0;
        repeat (200) @(posedge clk);
        key_n = 2'b11;
        repeat (50) @(posedge clk);
        if (up) M_EV = (M_EV < 8) ? M_EV + 1 : 8;
        else    M_EV = (M_EV > 0) ? M_EV - 1 : 0;
        if (ev !== M_EV) begin $display("FAIL key %0s: ev %0d, expected %0d", up ? "up" : "down", ev, M_EV); errors = errors + 1; end
    end
endtask

// ---------------- I2C 记录检查 ----------------
integer rd = -1, st = 0, n_ae = 0, n_st = 0, a_lo = 0, a_hi = 0, a_g = 0;
always @(posedge clk) begin
    if (rd < 0 && cfg_done) rd = u_slv.n;   // 初始寄存器写完以后开始查
    while (rd >= 0 && rd < u_slv.n) begin
        if (u_slv.len_log[rd] != 4 || u_slv.dev_log[rd] != 8'h34) begin
            $display("FAIL i2c write %0d: %0d bytes, device byte %h", rd, u_slv.len_log[rd], u_slv.dev_log[rd]); errors = errors + 1;
        end
        case (st)
            0: if (u_slv.reg_log[rd] == 16'h3000 && u_slv.dat_log[rd] == 8'h00) st = 10;
               else if (u_slv.reg_log[rd] == 16'h3001 && u_slv.dat_log[rd] == 8'h01) st = 1;
               else begin $display("FAIL i2c: unexpected %h=%h at start of a sequence (t=%0t)", u_slv.reg_log[rd], u_slv.dat_log[rd], $time); errors = errors + 1; end
            10: if (u_slv.reg_log[rd] == 16'h3002 && u_slv.dat_log[rd] == 8'h00) begin st = 0; n_st = n_st + 1; end
                else begin $display("FAIL i2c: standby rewrite broken by %h=%h (t=%0t)", u_slv.reg_log[rd], u_slv.dat_log[rd], $time); errors = errors + 1; st = 0; end
            1: if (u_slv.reg_log[rd] == 16'h3050) begin a_lo = u_slv.dat_log[rd]; st = 2; end
               else begin $display("FAIL i2c: AE sequence broken at SHR0 low by %h=%h (t=%0t)", u_slv.reg_log[rd], u_slv.dat_log[rd], $time); errors = errors + 1; st = 0; end
            2: if (u_slv.reg_log[rd] == 16'h3051) begin a_hi = u_slv.dat_log[rd]; st = 3; end
               else begin $display("FAIL i2c: AE sequence broken at SHR0 high by %h=%h (t=%0t)", u_slv.reg_log[rd], u_slv.dat_log[rd], $time); errors = errors + 1; st = 0; end
            3: if (u_slv.reg_log[rd] == 16'h3090) begin a_g = u_slv.dat_log[rd]; st = 4; end
               else begin $display("FAIL i2c: AE sequence broken at gain by %h=%h (t=%0t)", u_slv.reg_log[rd], u_slv.dat_log[rd], $time); errors = errors + 1; st = 0; end
            4: if (u_slv.reg_log[rd] == 16'h3091 && u_slv.dat_log[rd] == 8'h00) st = 5;
               else begin $display("FAIL i2c: AE sequence broken at gain high by %h=%h (t=%0t)", u_slv.reg_log[rd], u_slv.dat_log[rd], $time); errors = errors + 1; st = 0; end
            5: begin
                   if (u_slv.reg_log[rd] == 16'h3001 && u_slv.dat_log[rd] == 8'h00) begin
                       if (q_r >= q_w) begin
                           $display("FAIL i2c: AE write SHR0=%0d gain=%0d not expected (t=%0t)", a_hi * 256 + a_lo, a_g, $time); errors = errors + 1;
                       end else begin
                           if (a_hi * 256 + a_lo != 2283 - exp_q_e[q_r % 256] || a_g != exp_q_g[q_r % 256]) begin
                               $display("FAIL i2c: AE write #%0d SHR0=%0d gain=%0d, expected %0d %0d (t=%0t)", q_r, a_hi * 256 + a_lo, a_g,
                                        2283 - exp_q_e[q_r % 256], exp_q_g[q_r % 256], $time);
                               errors = errors + 1;
                           end
                           q_r = q_r + 1;
                       end
                       n_ae = n_ae + 1;
                   end else begin
                       $display("FAIL i2c: AE sequence not closed by REGHOLD=0: %h=%h (t=%0t)", u_slv.reg_log[rd], u_slv.dat_log[rd], $time); errors = errors + 1;
                   end
                   st = 0;
               end
        endcase
        rd = rd + 1;
    end
end

// ---------------- 主流程 ----------------
integer i, overlap_seen = 0, waited_seen = 0, overlap_hit = 0, waited_hit = 0;
always @(posedge clk) begin
    if (u_cfg.cnt == 1_000_000 && !wr_done)       overlap_hit = 1;   // 待机重写的时刻到了，曝光序列正在写
    if (req && cfg_done && !u_cfg.O_cfg_done_r)   waited_hit  = 1;   // 曝光请求在待机重写过程中
end
initial begin
    repeat (20) @(posedge clk);
    rst_n = 1;
    wait (cfg_done);
    // 初始写：曝光最长、增益 0
    exp_q_e[0] = 2275; exp_q_g[0] = 0; q_w = 1; skip = 2;
    wait (q_r == 1);
    repeat (100) @(posedge clk);
    check_outputs("after initial write");

    // 1. 一直暗：增益 +24 一直加到 150；之后不再写
    eval_frame(112);                                    // 正好在目标上：不动
    for (i = 0; i < 9; i = i + 1) eval_frame(10);
    check_outputs("dark: gain at max");
    // 1b. 写寄存器期间来的帧不算（写完以后才开始数 3 帧）
    while (skip > 0) frame(255);
    mean = 250; #13 tog = ~tog; model_eval(250);       // 被算到：调暗，开始写
    repeat (1500) @(posedge clk);
    if (wr_done !== 1'b0) begin $display("FAIL test setup: write should still be in progress"); errors = errors + 1; end
    mean = 0; #13 tog = ~tog;                          // 写到一半来的帧（被算成写完后的第 1 帧的话，后面的判断会提前一帧）
    repeat (FRAME_GAP) @(posedge clk);
    eval_frame(10);  check_outputs("frame during a write not counted");
    // 2. 一直亮：增益减到 0，再缩短曝光到 4；之后不再写
    for (i = 0; i < 16; i = i + 1) eval_frame(250);
    check_outputs("bright: exposure at min");
    // 3. 最小步长和各档调亮（从曝光 4 开始）
    eval_frame(101); check_outputs("+2 at exp 4 (min step)");
    eval_frame(90);  check_outputs("+5");
    eval_frame(70);  check_outputs("+12");
    eval_frame(240); check_outputs("-24 at exp 9: 9 x 0.44 = 3 -> clamped to 4");
    eval_frame(55);  check_outputs("m just below T/2 (+24)");
    eval_frame(76);  check_outputs("m just below 0.6875T (+12)");
    eval_frame(50);  check_outputs("+24");
    eval_frame(56);  check_outputs("m = T/2 exactly (+12)");
    for (i = 0; i < 8; i = i + 1) eval_frame(30);
    check_outputs("exposure back to max, then gain +24 x2");
    // 4. 各档调暗（先减增益，再减曝光）+ 正好等于阈值
    eval_frame(119); check_outputs("m = 1.0625T exactly (no change)");
    eval_frame(125); check_outputs("-2 gain");
    eval_frame(140); check_outputs("-5 gain");
    eval_frame(135); check_outputs("m just above 1.1875T (-5)");
    eval_frame(166); check_outputs("m just below 1.5T (-5)");
    eval_frame(222); check_outputs("m just below 2T (-12)");
    eval_frame(180); check_outputs("-12 gain");
    eval_frame(230); check_outputs("-24 gain");
    eval_frame(230); check_outputs("-24 gain, clamped to 0");
    eval_frame(125); check_outputs("-2 exposure");
    eval_frame(140); check_outputs("-5 exposure");
    eval_frame(180); check_outputs("-12 exposure");
    eval_frame(240); check_outputs("-24 exposure");
    eval_frame(105); check_outputs("deadband low edge (0.9375T = 105, no change)");
    // 5. 档位键
    for (i = 0; i < 5; i = i + 1) key(1);               // 4 → 8（第 5 下不再变）
    eval_frame(150); check_outputs("EV+4: 150 is dark (+2)");
    for (i = 0; i < 9; i = i + 1) key(0);               // 8 → 0（最后一下不再变）
    eval_frame(60);  check_outputs("EV-4: 60 is bright (-5)");
    eval_frame(48);  check_outputs("EV-4: on target");
    // 6. 曝光序列写到一半碰上待机重写：让请求在 cnt 到 1,000,000 之前约 1000 拍发出
    while (skip > 0) frame(255);
    wait (u_cfg.cnt == 999_000);
    frame(10);                                          // 很暗：一定要写
    if (q_r == q_w && n_st > 0) overlap_seen = 1;
    // 7. 请求在待机重写过程中到来
    while (skip > 0) frame(255);
    wait (u_cfg.cnt == 1_000_000);
    @(posedge clk); @(posedge clk);
    if (u_cfg.O_cfg_done_r !== 1'b0) begin $display("FAIL test setup: standby rewrite not running"); errors = errors + 1; end
    frame(10);
    if (q_r == q_w) waited_seen = 1;

    // 8. 待机重写的定时正好落在曝光序列两条寄存器之间（状态机回到状态 0 的那一个时钟）：原版会在这里打断曝光序列，
    //    先写待机寄存器、再从中间接着写曝光（漏掉 REGHOLD=1 和 SHR0 低字节）。把计数器在那一拍强制成 1,000,000
    while (skip > 0) frame(255);
    mean = 10; #13 tog = ~tog; model_eval(10);         // 被算到：调亮，开始写
    wait (!wr_done);
    wait (u_cfg.TS_S == 2'd3 && u_cfg.iic_busy === 1'b0 && u_cfg.reg_index == 8'd2);
    @(posedge clk);                                    // 这一拍状态 3 → 0
    #1 force u_cfg.cnt = 22'd1_000_000;
    @(posedge clk);                                    // 状态 0 看到计数到点
    if (u_cfg.TS_S !== 2'd1 && u_cfg.TS_S !== 2'd0) begin $display("FAIL test setup: unexpected state %0d", u_cfg.TS_S); errors = errors + 1; end
    #1 release u_cfg.cnt;
    repeat (FRAME_GAP) @(posedge clk);
    check_outputs("standby timer between two AE registers");

    repeat (20000) @(posedge clk);
    check_outputs("end");
    if (q_r != q_w) begin $display("FAIL %0d expected AE writes, %0d seen", q_w, q_r); errors = errors + 1; end
    if (st != 0)    begin $display("FAIL I2C log ends inside a sequence"); errors = errors + 1; end
    if (!overlap_hit || !waited_hit)  begin $display("FAIL concurrency cases not hit (%0d %0d)", overlap_hit, waited_hit); errors = errors + 1; end
    if (!overlap_seen || !waited_seen) begin $display("FAIL concurrency cases did not complete (%0d %0d)", overlap_seen, waited_seen); errors = errors + 1; end
    if (n_st < 2)   begin $display("FAIL only %0d standby rewrites seen", n_st); errors = errors + 1; end
    $display("evaluations %0d, changes %0d, AE writes %0d, standby rewrites %0d", n_eval, n_change, n_ae, n_st);
    if (errors == 0) $display("PASS  tb_ae");
    else             $display("FAIL  tb_ae: %0d error(s)", errors);
    $finish;
end

initial begin #400_000_000; $display("FAIL  tb_ae: timeout"); $finish; end

endmodule
