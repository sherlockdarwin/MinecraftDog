`timescale 1ns / 1ps
// 测试 mc_tail（含 mc_stepper_emm / mc_uart_tx），驱动器只收不回：
//   1) 上电回零：INIT_DELAY_MS 到点后发且只发一遍"解除保护 → 使能 → 单圈就近回零 → 设坐标零点"（19 字节），
//      回零帧和设零点帧之间隔 HOME_MS；O_seq = 1；之后再无字节。
//   2) 回零做完之前（到点前 / 回零中）的摇摆请求一律不理（不排队）。
//   3) 摇摆：使能 + 左 / 中 / 右 / 中 四个绝对位置帧（58 字节），段间隔 LEG_MS；O_seq = 2；摇摆中再给摇摆命令不理。
//   4) 复位后重新回零一遍。
//   5) 第二个实例换一组参数（地址 2、向左 = CW、减速比 3、摆幅 20°、120 RPM）核对摇摆帧，抓参数接错。
//   发送线用测试台自己的解码器（不借用任何 RTL）：逐字节记录内容和时刻，并检查起始位 / 停止位 / 位宽。
// 为了仿真快：波特率取 1 Mbps，各段等待取几毫秒。
module tb_tail;

localparam CLK_HZ = 100_000_000;
localparam BAUD   = 1_000_000;

reg  clk = 0;
reg  rst_n = 0;
always #5 clk = ~clk;

// 1 ms 节拍
reg tick1ms = 0;
integer tdiv = 0;
always @(posedge clk) begin
    tick1ms <= 1'b0;
    if (tdiv == CLK_HZ/1000 - 1) begin tdiv <= 0; tick1ms <= 1'b1; end
    else tdiv <= tdiv + 1;
end
integer ms = 0;
always @(posedge clk) if (tick1ms) ms = ms + 1;

// ---- 实例 A：默认参数（地址 1、向左 = CCW、直驱、30°、80 RPM）----
reg  wag_a = 0;
wire busy_a, tx_a;
wire [1:0] seq_a;

mc_tail #(
    .CLK_HZ(CLK_HZ), .BAUD(BAUD), .ADDR(8'd1),
    .PULSES_PER_REV(3200), .GEAR_X100(100), .SWING_DEG(30), .LEFT_IS_CCW(1),
    .RPM(80), .ACC(0),
    .LEG_MS(3), .HOME_MS(6), .GAP_MS(2), .INIT_DELAY_MS(5)
) dut_a (
    .I_clk(clk), .I_rst_n(rst_n), .I_tick_1ms(tick1ms),
    .I_cmd_wag(wag_a),
    .O_busy(busy_a), .O_seq(seq_a),
    .O_tx(tx_a)
);

// ---- 实例 B：另一组参数 ----
reg  wag_b = 0;
wire busy_b, tx_b;
wire [1:0] seq_b;

mc_tail #(
    .CLK_HZ(CLK_HZ), .BAUD(BAUD), .ADDR(8'd2),
    .PULSES_PER_REV(3200), .GEAR_X100(300), .SWING_DEG(20), .LEFT_IS_CCW(0),
    .RPM(120), .ACC(7),
    .LEG_MS(2), .HOME_MS(3), .GAP_MS(1), .INIT_DELAY_MS(2)
) dut_b (
    .I_clk(clk), .I_rst_n(rst_n), .I_tick_1ms(tick1ms),
    .I_cmd_wag(wag_b),
    .O_busy(busy_b), .O_seq(seq_b),
    .O_tx(tx_b)
);

wire [15:0] bad_a, bad_b;
tb_tail_mon #(.BAUD(BAUD)) mon_a (.tx(tx_a), .bad(bad_a));
tb_tail_mon #(.BAUD(BAUD)) mon_b (.tx(tx_b), .bad(bad_b));

integer errors = 0;

// 期望字节流
reg [7:0] exp [0:127];
integer   exp_n;
task expect_clear; begin exp_n = 0; end endtask
task ex; input [7:0] v; begin exp[exp_n] = v; exp_n = exp_n + 1; end endtask
task compare_a;                                   // mon_a.mem[start .. ] 与期望比较
    input [255:0] name;
    input integer start;
    integer j;
    begin
        if (mon_a.n - start !== exp_n) begin
            $display("FAIL %0s: got %0d bytes, expected %0d", name, mon_a.n - start, exp_n);
            errors = errors + 1;
        end
        for (j = 0; j < exp_n; j = j + 1)
            if (mon_a.mem[start + j] !== exp[j]) begin
                $display("FAIL %0s: byte %0d = %h, expected %h", name, j, mon_a.mem[start + j], exp[j]);
                errors = errors + 1;
            end
    end
endtask
task compare_b;
    input [255:0] name;
    input integer start;
    integer j;
    begin
        if (mon_b.n - start !== exp_n) begin
            $display("FAIL %0s: got %0d bytes, expected %0d", name, mon_b.n - start, exp_n);
            errors = errors + 1;
        end
        for (j = 0; j < exp_n; j = j + 1)
            if (mon_b.mem[start + j] !== exp[j]) begin
                $display("FAIL %0s: byte %0d = %h, expected %h", name, j, mon_b.mem[start + j], exp[j]);
                errors = errors + 1;
            end
    end
endtask
task chk;
    input [255:0] what;
    input         ok;
    begin
        if (!ok) begin $display("FAIL %0s", what); errors = errors + 1; end
    end
endtask

task home_bytes;                                  // 回零序列（地址 a）
    input [7:0] a;
    begin
        ex(a); ex(8'h0E); ex(8'h52); ex(8'h6B);                                   // 解除保护
        ex(a); ex(8'hF3); ex(8'hAB); ex(8'h01); ex(8'h00); ex(8'h6B);             // 使能
        ex(a); ex(8'h9A); ex(8'h00); ex(8'h00); ex(8'h6B);                        // 单圈就近回零
        ex(a); ex(8'h0A); ex(8'h6D); ex(8'h6B);                                   // 设坐标零点
    end
endtask
task pos_frame;
    input [7:0] a;
    input       dir;
    input [15:0] rpm;
    input [7:0] acc;
    input [31:0] pul;
    begin
        ex(a); ex(8'hFD); ex({7'd0, dir}); ex(rpm[15:8]); ex(rpm[7:0]); ex(acc);
        ex(pul[31:24]); ex(pul[23:16]); ex(pul[15:8]); ex(pul[7:0]); ex(8'h01); ex(8'h00); ex(8'h6B);
    end
endtask

task pulse_wag_a; begin @(posedge clk); wag_a <= 1'b1; @(posedge clk); wag_a <= 1'b0; end endtask
task pulse_wag_b; begin @(posedge clk); wag_b <= 1'b1; @(posedge clk); wag_b <= 1'b0; end endtask

// 帧间隔核对：第 last 个字节（一帧的最后一个）到下一个字节，等待 T 个 1 ms 节拍 → 间隔在 (T−1, T] ms 再加约 10 位时间。
// 每个等待的节拍相位不同，所以"多等一拍 / 少等一拍"的错误在几个间隔里总有一个会超出 (T−1, T+0.05]。
task gap_a; input integer last; input integer T; real g; begin
    g = (mon_a.t[last + 1] - mon_a.t[last]) / 1.0e6;
    if (!(g > T - 1 && g <= T + 0.05)) begin $display("FAIL gap A after byte %0d: %0f ms, expected (%0d, %0d.05]", last, g, T - 1, T); errors = errors + 1; end
end endtask
task gap_b; input integer last; input integer T; real g; begin
    g = (mon_b.t[last + 1] - mon_b.t[last]) / 1.0e6;
    if (!(g > T - 1 && g <= T + 0.05)) begin $display("FAIL gap B after byte %0d: %0f ms, expected (%0d, %0d.05]", last, g, T - 1, T); errors = errors + 1; end
end endtask

task wait_idle_a;
    integer to;
    begin
        to = 0;
        repeat (20) @(posedge clk);
        while (busy_a && to < 200) begin @(posedge tick1ms); to = to + 1; end
        if (busy_a) begin $display("FAIL wait_idle_a timeout"); errors = errors + 1; end
        repeat (200) @(posedge clk);
    end
endtask

// O_seq 在忙的时候取过哪些值
reg seen_seq1_a = 0, seen_seq2_a = 0, seen_bad_a = 0;
always @(posedge clk) begin
    if (busy_a && seq_a == 2'd1) seen_seq1_a <= 1'b1;
    if (busy_a && seq_a == 2'd2) seen_seq2_a <= 1'b1;
    if (busy_a && (seq_a == 2'd0 || seq_a == 2'd3)) seen_bad_a <= 1'b1;
    if (!busy_a && seq_a != 2'd0) seen_bad_a <= 1'b1;
end

integer s0, t_busy, i, k;

initial begin
    repeat (10) @(posedge clk); rst_n = 1;

    // ------------------ 2) 到点前的摇摆请求：不理 ------------------
    wait (ms == 2); pulse_wag_a;
    repeat (100) @(posedge clk);
    chk("wag before homing: not busy", !busy_a);

    // ------------------ 1) 上电回零 ------------------
    t_busy = -1;
    while (!busy_a && ms < 20) @(posedge clk);
    t_busy = ms;
    chk("homing starts exactly at the 5th 1-ms tick (INIT_DELAY_MS = 5)", t_busy == 5);
    // 回零中（发设零点帧之前）再给摇摆：不理
    wait (mon_a.n >= 15); repeat (1000) @(posedge clk);
    chk("seq = 1 during homing", seq_a == 2'd1);
    pulse_wag_a;
    wait_idle_a;
    expect_clear; home_bytes(8'h01);
    compare_a("homing", 0);
    // 帧间隔：解除保护 → 使能 = GAP_MS(2)，使能 → 回零 = GAP_MS(2)，回零 → 设零点 = HOME_MS(6)
    gap_a(3, 2); gap_a(9, 2); gap_a(14, 6);
    // 回零中给的摇摆不能排队：回零做完后等一会儿，没有新字节
    s0 = mon_a.n;
    repeat (15) @(posedge tick1ms);
    chk("no bytes after homing (wag during homing ignored)", mon_a.n == s0 && !busy_a);

    // ------------------ 3) 摇摆 ------------------
    s0 = mon_a.n;
    pulse_wag_a;
    repeat (50) @(posedge clk);
    chk("seq = 2 during wag", seq_a == 2'd2);
    repeat (2) @(posedge tick1ms);
    pulse_wag_a;                                                // 摇摆中再给：不理
    wait_idle_a;
    expect_clear;
    ex(8'h01); ex(8'hF3); ex(8'hAB); ex(8'h01); ex(8'h00); ex(8'h6B);           // 使能
    pos_frame(8'h01, 1'b1, 16'd80, 8'd0, 32'd267);                              // 左 30°：CCW，267 脉冲
    pos_frame(8'h01, 1'b0, 16'd80, 8'd0, 32'd0);                                // 中
    pos_frame(8'h01, 1'b0, 16'd80, 8'd0, 32'd267);                              // 右 30°：CW
    pos_frame(8'h01, 1'b0, 16'd80, 8'd0, 32'd0);                                // 中
    compare_a("wag", s0);
    // 帧间隔：使能 → 左 = GAP_MS(2)，左 → 中 → 右 → 中 = LEG_MS(3)
    gap_a(s0 + 5, 2); gap_a(s0 + 18, 3); gap_a(s0 + 31, 3); gap_a(s0 + 44, 3);
    s0 = mon_a.n;
    repeat (15) @(posedge tick1ms);
    chk("only one wag", mon_a.n == s0);

    // ------------------ 4) 复位后重新回零 ------------------
    @(posedge clk); rst_n = 0; repeat (10) @(posedge clk); rst_n = 1;
    s0 = mon_a.n;
    wait (busy_a);
    wait_idle_a;
    expect_clear; home_bytes(8'h01);
    compare_a("homing after reset", s0);

    chk("seq values (1 while homing, 2 while wagging, 0 when idle)", seen_seq1_a && seen_seq2_a && !seen_bad_a);

    // ------------------ 5) 实例 B：另一组参数 ------------------
    wait (mon_b.n >= 19 && !busy_b); repeat (200) @(posedge clk);
    s0 = mon_b.n;
    pulse_wag_b;
    repeat (20) @(posedge clk);
    while (busy_b) @(posedge clk);
    repeat (200) @(posedge clk);
    expect_clear;
    ex(8'h02); ex(8'hF3); ex(8'hAB); ex(8'h01); ex(8'h00); ex(8'h6B);
    pos_frame(8'h02, 1'b0, 16'd120, 8'd7, 32'd533);                             // 左 = CW，3200×3×20/360 = 533
    pos_frame(8'h02, 1'b0, 16'd120, 8'd7, 32'd0);
    pos_frame(8'h02, 1'b1, 16'd120, 8'd7, 32'd533);                             // 右 = CCW
    pos_frame(8'h02, 1'b0, 16'd120, 8'd7, 32'd0);
    compare_b("wag (instance B)", s0);
    // 实例 B 的回零序列（地址 2）在开头
    expect_clear; home_bytes(8'h02);
    for (k = 0; k < 19; k = k + 1)
        if (mon_b.mem[k] !== exp[k]) begin $display("FAIL homing B byte %0d = %h, expected %h", k, mon_b.mem[k], exp[k]); errors = errors + 1; end
    gap_b(3, 1); gap_b(9, 1); gap_b(14, 3);                                    // GAP_MS = 1、HOME_MS = 3
    gap_b(s0 + 5, 1); gap_b(s0 + 18, 2); gap_b(s0 + 31, 2); gap_b(s0 + 44, 2);   // LEG_MS = 2

    chk("tx waveform A (start/stop/bit width)", bad_a == 0);
    chk("tx waveform B (start/stop/bit width)", bad_b == 0);

    if (errors == 0) $display("PASS  tb_tail");
    else             $display("FAIL  tb_tail: %0d errors", errors);
    $finish;
end

initial begin #400_000_000; $display("FAIL  tb_tail: timeout"); $finish; end

endmodule


// =============================================================================
// 发送线解码器（测试台用，行为级）：记录每个字节的内容和"停止位采样时刻"（ns），检查起始位 / 停止位，
// 并检查下降沿到下一字节之间的位宽（起始位必须保持一整个位时间）。
// =============================================================================
module tb_tail_mon #(
    parameter BAUD = 1_000_000
)(
    input  wire        tx,
    output reg  [15:0] bad
);
localparam real BIT_NS = 1.0e9 / BAUD;

reg [7:0] mem [0:255];
real      t   [0:255];
integer   n = 0;
reg [7:0] b;
integer   bi;
real      t0;

initial begin
    bad = 0;
    forever begin
        @(negedge tx);
        t0 = $realtime;
        #(BIT_NS / 2);
        if (tx !== 1'b0) bad = bad + 1;                 // 起始位
        for (bi = 0; bi < 8; bi = bi + 1) begin
            #(BIT_NS);
            b[bi] = tx;
        end
        #(BIT_NS);
        if (tx !== 1'b1) bad = bad + 1;                 // 停止位
        mem[n] = b;
        t[n]   = $realtime;
        n = n + 1;
    end
end

// 位宽：任何一次电平变化都必须落在"起始沿 + 整数个位时间"附近（±2%）
always @(tx) begin
    if (n > 0 || $realtime > 0) begin : chkw
        real d, frac;
        d = ($realtime - t0) / BIT_NS;
        frac = d - $floor(d + 0.5);
        if (d > 0.5 && d < 9.6 && (frac > 0.02 || frac < -0.02)) bad = bad + 1;
    end
end

endmodule
