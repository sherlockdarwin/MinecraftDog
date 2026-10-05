`timescale 1ns / 1ps
// 测试 mc_sd_arb 的接口约定（协议级：SD 卡一侧是脚本化的小模型，不读真的文件，几秒跑完）。
// 请求方的扇区号靠数值区分：请求方 0 用 0x1000 起，请求方 1 用 0x2000 起 —— 模型据此知道"这次传输该属于谁"。
// 持续核对（每个时钟）：
//   · 数据 / done / err 只出现在这次传输的主人那一侧，而且和 SD 卡侧同一拍（逐位相等，所以多出来的、少了的都会报）；
//   · O_busy0 / O_busy1 = 这一方有请求没做完（从提出请求的下一拍，到 done / err 的下一拍）；
//   · O_start 只有一个时钟宽，发出时 SD 卡不忙；每次发出的扇区号 = 被服务那一方的 I_lba；每次发出都对应一个还没服务的请求（没有"幽灵传输"）。
// 场景：单独读（0 / 1）、同一拍两方同时请求（"谁刚用过谁排后面"，两个方向）、一方传输中另一方来请求（被记住、之后服务）、
//       两方连续抢（严格交替）、读出错（只有主人收到 err，仲裁器恢复，另一方的请求不丢）、传输中复位（挂起的请求清掉）。
module tb_sdarb_proto;

localparam NB   = 8;                    // 每次"读扇区"送几个字节（真实是 512，仲裁器不关心）
localparam DLY  = 5;                    // 发出命令到第一个字节之间的时钟数
localparam TAIL = 3;                    // done / err 之后 SD 卡还"忙"几个时钟（仲裁器必须等它不忙才能发下一个）

reg clk = 0, rst_n = 0;
always #5 clk = ~clk;

// ---------------- 请求方 ----------------
reg         st0 = 0, st1 = 0;
reg  [31:0] lba0 = 0, lba1 = 0;
wire        busy0, busy1, v0, v1, d0, d1, e0, e1;
wire [7:0]  by0, by1;
wire [8:0]  ix0, ix1;

// ---------------- SD 卡一侧 ----------------
wire        sd_start;
wire [31:0] sd_lba;
reg         sd_busy = 0, sd_valid = 0, sd_done = 0, sd_err = 0;
reg  [7:0]  sd_byte = 0;
reg  [8:0]  sd_idx = 0;

mc_sd_arb dut (
    .I_clk(clk), .I_rst_n(rst_n),
    .I_start0(st0), .I_lba0(lba0), .O_busy0(busy0), .O_valid0(v0), .O_byte0(by0), .O_idx0(ix0), .O_done0(d0), .O_err0(e0),
    .I_start1(st1), .I_lba1(lba1), .O_busy1(busy1), .O_valid1(v1), .O_byte1(by1), .O_idx1(ix1), .O_done1(d1), .O_err1(e1),
    .O_start(sd_start), .O_lba(sd_lba),
    .I_sd_busy(sd_busy), .I_valid(sd_valid), .I_byte(sd_byte), .I_idx(sd_idx), .I_done(sd_done), .I_err(sd_err)
);

integer err = 0;
task fail; input [511:0] msg; begin $display("FAIL [%0s] (t=%0t)", msg, $time); err = err + 1; end endtask
task expect;
    input [511:0] name;
    input integer got, exp;
    begin if (got !== exp) begin $display("FAIL [%0s] got %0d expected %0d (t=%0t)", name, got, exp, $time); err = err + 1; end end
endtask

// ---------------- SD 卡模型 ----------------
integer    sm = 0, cnt = 0, nb = 0, cur_nb = NB;       // sm：0 空闲 1 等待 2 送数据 3 结束 4 结束后还忙
reg [31:0] cur_lba = 0;
reg        cur_owner = 0;                              // 这次传输属于谁（由扇区号判断）
reg        cur_fail = 0, fail_next = 0;
integer    n_start = 0;
reg [31:0] seq [0:255];                                // 每次传输的扇区号（按开始的先后）

always @(posedge clk) begin
    sd_valid <= 1'b0; sd_done <= 1'b0; sd_err <= 1'b0;
    if (!rst_n) begin
        sm <= 0; sd_busy <= 1'b0;
    end else case (sm)
        0: if (sd_start) begin
               cur_lba <= sd_lba; cur_owner <= (sd_lba >= 32'h2000);
               cur_fail <= fail_next; cur_nb <= fail_next ? 3 : NB; fail_next <= 1'b0;
               sd_busy <= 1'b1; cnt <= DLY; sm <= 1;
               seq[n_start] <= sd_lba; n_start <= n_start + 1;
           end
        1: if (cnt == 0) begin nb <= 0; sm <= 2; end else cnt <= cnt - 1;
        2: begin
               sd_valid <= 1'b1; sd_byte <= cur_lba[7:0] + nb[7:0]; sd_idx <= nb[8:0];
               nb <= nb + 1;
               if (nb == cur_nb - 1) sm <= 3;
           end
        3: begin
               if (cur_fail) sd_err <= 1'b1; else sd_done <= 1'b1;
               cnt <= TAIL; sm <= 4;
           end
        4: if (cnt == 0) begin sd_busy <= 1'b0; sm <= 0; end else cnt <= cnt - 1;
    endcase
end

// ---------------- 持续核对 ----------------
reg  chk_en = 0;
reg  sd_start_d = 0;
reg  out0 = 0, out1 = 0;                               // 这一方有请求没做完
integer req0_n = 0, req1_n = 0, gr0_n = 0, gr1_n = 0;  // 请求次数 / 被服务（O_start）次数
integer nv0 = 0, nv1 = 0, done0_n = 0, done1_n = 0, err0_n = 0, err1_n = 0;
reg  gr_owner;

always @(posedge clk) begin
    sd_start_d <= sd_start;
    if (!rst_n) begin
        out0 <= 1'b0; out1 <= 1'b0;
    end else if (chk_en) begin
        // 协议
        if (sd_start && sd_start_d) fail("O_start wider than 1 clock");
        if (sd_start && (sd_busy || sm != 0)) fail("O_start while the SD card is busy");
        // 路由：每个输出和 SD 卡侧同一拍，且只给主人
        if (v0 !== (sd_valid && !cur_owner)) fail("O_valid0 wrong");
        if (v1 !== (sd_valid &&  cur_owner)) fail("O_valid1 wrong");
        if (d0 !== (sd_done  && !cur_owner)) fail("O_done0 wrong");
        if (d1 !== (sd_done  &&  cur_owner)) fail("O_done1 wrong");
        if (e0 !== (sd_err   && !cur_owner)) fail("O_err0 wrong");
        if (e1 !== (sd_err   &&  cur_owner)) fail("O_err1 wrong");
        if (v0 && (by0 !== sd_byte || ix0 !== sd_idx)) fail("stream 0 byte / index not passed through");
        if (v1 && (by1 !== sd_byte || ix1 !== sd_idx)) fail("stream 1 byte / index not passed through");
        // busy
        if (busy0 !== out0) fail("O_busy0 wrong");
        if (busy1 !== out1) fail("O_busy1 wrong");
        if (st0) begin out0 <= 1'b1; req0_n <= req0_n + 1; end else if (d0 | e0) out0 <= 1'b0;
        if (st1) begin out1 <= 1'b1; req1_n <= req1_n + 1; end else if (d1 | e1) out1 <= 1'b0;
        // 计数
        if (v0) nv0 <= nv0 + 1;
        if (v1) nv1 <= nv1 + 1;
        if (d0) done0_n <= done0_n + 1;
        if (d1) done1_n <= done1_n + 1;
        if (e0) err0_n <= err0_n + 1;
        if (e1) err1_n <= err1_n + 1;
        // 每次发出：扇区号是被服务那一方的，而且确实有一个没服务的请求
        if (sd_start) begin
            gr_owner = (sd_lba >= 32'h2000);
            if (sd_lba !== (gr_owner ? lba1 : lba0)) fail("O_lba is not the served requester's I_lba");
            if (gr_owner) begin gr1_n <= gr1_n + 1; if (gr1_n + 1 > req1_n) fail("ghost transfer for requester 1"); end
            else          begin gr0_n <= gr0_n + 1; if (gr0_n + 1 > req0_n) fail("ghost transfer for requester 0"); end
        end
    end
end

// ---------------- 请求方的动作 ----------------
task start0; input [31:0] l; begin @(posedge clk); lba0 <= l; st0 <= 1'b1; @(posedge clk); st0 <= 1'b0; end endtask
task start1; input [31:0] l; begin @(posedge clk); lba1 <= l; st1 <= 1'b1; @(posedge clk); st1 <= 1'b0; end endtask
task wait_fin0; input integer target;             // 等请求方 0 累计结束（done + err）target 次
    integer t;
    begin t = 0; while (done0_n + err0_n < target && t < 3000) begin @(posedge clk); t = t + 1; end
          if (done0_n + err0_n < target) fail("timeout waiting for requester 0 to finish"); end
endtask
task wait_fin1; input integer target;
    integer t;
    begin t = 0; while (done1_n + err1_n < target && t < 3000) begin @(posedge clk); t = t + 1; end
          if (done1_n + err1_n < target) fail("timeout waiting for requester 1 to finish"); end
endtask
task wait_data; begin while (sm != 2) @(posedge clk); end endtask
task settle; begin repeat (20) @(posedge clk); end endtask

// 两方连续抢：每次结束后过一个时钟马上再请求
integer lp0 = 0, lp1 = 0;
task loop0; input integer n; integer i, tgt;
    begin
        for (i = 0; i < n; i = i + 1) begin
            tgt = done0_n + err0_n + 1;
            start0(32'h1100 + i);
            wait_fin0(tgt);
            @(posedge clk);
        end
        lp0 = 1;
    end
endtask
task loop1; input integer n; integer i, tgt;
    begin
        for (i = 0; i < n; i = i + 1) begin
            tgt = done1_n + err1_n + 1;
            start1(32'h2100 + i);
            wait_fin1(tgt);
            @(posedge clk);
        end
        lp1 = 1;
    end
endtask

integer k, s0, p0, p1, nv0_b, nv1_b;
initial begin
    repeat (5) @(posedge clk); rst_n = 1;
    repeat (3) @(posedge clk);
    chk_en = 1;

    // ---------- 1) 请求方 0 单独读 ----------
    nv0_b = nv0; nv1_b = nv1;
    start0(32'h1001);
    wait_fin0(1); settle;
    expect("requester 0 alone: done", done0_n, 1);
    expect("requester 0 alone: bytes", nv0 - nv0_b, NB);
    expect("requester 0 alone: nothing for 1", nv1 - nv1_b, 0);
    expect("transfers so far", n_start, 1);

    // ---------- 2) 请求方 1 单独读 ----------
    nv0_b = nv0; nv1_b = nv1;
    start1(32'h2002);
    wait_fin1(1); settle;
    expect("requester 1 alone: done", done1_n, 1);
    expect("requester 1 alone: bytes", nv1 - nv1_b, NB);
    expect("requester 1 alone: nothing for 0", nv0 - nv0_b, 0);

    // ---------- 3) 同一拍两方同时请求：上次是 1 用的 → 0 先；再来一次，上次是 0 用的 → 1 先 ----------
    s0 = n_start;
    fork start0(32'h1003); start1(32'h2004); join
    wait_fin0(2); wait_fin1(2); settle;
    expect("both at once: two transfers", n_start - s0, 2);
    if (seq[s0] >= 32'h2000 || seq[s0 + 1] < 32'h2000) fail("both at once after requester 1: requester 0 should go first");
    // 现在上一次是 1 用的；让 0 单独用一次，再同一拍两方请求 → 1 先
    start0(32'h1005); wait_fin0(3); settle;
    s0 = n_start;
    fork start0(32'h1006); start1(32'h2007); join
    wait_fin0(4); wait_fin1(3); settle;
    expect("both at once (2): two transfers", n_start - s0, 2);
    if (seq[s0] < 32'h2000 || seq[s0 + 1] >= 32'h2000) fail("both at once after requester 0: requester 1 should go first");

    // ---------- 4) 一方传输中另一方来请求：被记住，传完以后服务 ----------
    s0 = n_start; nv0_b = nv0; nv1_b = nv1;
    start0(32'h1008);
    wait_data;
    start1(32'h2009);                                   // 0 正在传
    wait_fin0(5); wait_fin1(4); settle;
    expect("pending request served after the running transfer", n_start - s0, 2);
    if (seq[s0] >= 32'h2000 || seq[s0 + 1] < 32'h2000) fail("order: requester 0 (running) then requester 1 (pending)");
    expect("pending: bytes 0", nv0 - nv0_b, NB);
    expect("pending: bytes 1", nv1 - nv1_b, NB);
    // 反过来：1 正在传，0 来请求
    s0 = n_start;
    start1(32'h200A);
    wait_data;
    start0(32'h100B);
    wait_fin1(5); wait_fin0(6); settle;
    expect("pending request (reverse) served", n_start - s0, 2);
    if (seq[s0] < 32'h2000 || seq[s0 + 1] >= 32'h2000) fail("order: requester 1 (running) then requester 0 (pending)");

    // ---------- 5) 两方连续抢：严格交替 ----------
    s0 = n_start; lp0 = 0; lp1 = 0;
    fork loop0(10); loop1(10); join
    settle;
    expect("overload: transfers", n_start - s0, 20);
    for (k = 1; k < 20; k = k + 1)
        if ((seq[s0 + k] >= 32'h2000) === (seq[s0 + k - 1] >= 32'h2000)) fail("overload: grants do not alternate");

    // ---------- 6) 读出错：只有主人收到 err；仲裁器恢复；另一方的请求不丢 ----------
    p0 = err0_n; p1 = err1_n; nv0_b = nv0; nv1_b = nv1;
    s0 = done0_n; k = done1_n;
    fail_next = 1;
    start0(32'h100C);
    wait_fin0(done0_n + err0_n + 1); settle;
    expect("error on requester 0: err0", err0_n - p0, 1);
    expect("error on requester 0: err1 untouched", err1_n - p1, 0);
    expect("error on requester 0: no done", done0_n - s0, 0);
    expect("error transfer delivers only 3 bytes", nv0 - nv0_b, 3);
    start1(32'h200D);                                   // 出错以后还能正常服务
    wait_fin1(done1_n + err1_n + 1); settle;
    expect("after an error requester 1 reads fine", done1_n - k, 1);
    // 1 出错，0 的请求在等
    p0 = err0_n; p1 = err1_n; s0 = done0_n; k = done1_n;
    fail_next = 1;
    start1(32'h200E);
    wait_data;
    start0(32'h100F);
    wait_fin1(done1_n + err1_n + 1); wait_fin0(done0_n + err0_n + 1); settle;
    expect("error on requester 1: err1", err1_n - p1, 1);
    expect("error on requester 1: err0 untouched", err0_n - p0, 0);
    expect("error on requester 1: no done for 1", done1_n - k, 0);
    expect("requester 0 waiting during the error is served", done0_n - s0, 1);

    // ---------- 7) 没有请求就什么都不发 ----------
    s0 = n_start;
    repeat (300) @(posedge clk);
    expect("no ghost transfers", n_start - s0, 0);

    // ---------- 8) 传输中复位：挂起的请求清掉；之后两方都能正常读 ----------
    start0(32'h1010);
    wait_data;
    start1(32'h2011);                                   // 1 挂起
    @(posedge clk);
    rst_n = 0; repeat (3) @(posedge clk); rst_n = 1;
    s0 = n_start;
    repeat (300) @(posedge clk);
    expect("after reset no transfer is started", n_start - s0, 0);
    if (busy0 !== 1'b0 || busy1 !== 1'b0) fail("busy flags not cleared by reset");
    p0 = done0_n; p1 = done1_n;
    start0(32'h1012); wait_fin0(done0_n + err0_n + 1);
    start1(32'h2013); wait_fin1(done1_n + err1_n + 1); settle;
    expect("after reset requester 0 reads fine", done0_n - p0, 1);
    expect("after reset requester 1 reads fine", done1_n - p1, 1);

    if (err == 0) $display("PASS  tb_sdarb_proto");
    else          $display("FAIL  tb_sdarb_proto: errors %0d", err);
    $finish;
end
initial begin #20_000_000; $display("FAIL  tb_sdarb_proto: timeout"); $finish; end

endmodule
