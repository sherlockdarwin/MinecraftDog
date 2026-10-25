`timescale 1ns / 1ps
// 测试 mc_sd_arb + mc_fat32：mc_fat32 里的两路读文件（背景音乐一路、音效一路，共用一份挂载 + 目录表）共用一个 mc_sd_spi（接行为级 SD 卡模型，卡里是 tools/mk_sd_test_image.pl 的镜像）。
//   · 挂载只扫一遍目录（挂载期间 0 号读扇区口归挂载模块），两路各自找到 8 个曲目；
//   · 两路同时读不同的文件（含碎片化、簇号很大、在目录第 2 个簇里的文件），各自逐字节核对内容和长度，缓冲区"忙闲"随机（I_space_ok 间歇为 0）；
//   · 两路反复交替打开不同的曲目，任意一路中途关闭、另一路不受影响；
//   · 任意一路打开不存在的编号 → 只有这一路报错；两路同时打开不存在的编号 → 都报错（两路的"有没有这个编号"各查各的）。
// 每一路的"消费者"是 tb_sdarb_rd 模块（收字节、核对、报告）。
module tb_sdarb_rd #(
    parameter IMAGE = "sd_mbr",
    parameter SEED  = 1
)(
    input  wire       clk,
    input  wire       rst_n,
    // 接 mc_fat32
    output reg        O_open,
    output reg [6:0]  O_clip,
    output reg        O_close,
    output reg        O_space_ok,
    input  wire       I_open_err,
    input  wire [2:0] I_err_code,
    input  wire       I_data_valid,
    input  wire [7:0] I_data,
    input  wire       I_eof,
    // 控制
    input  wire       I_go,                 // 脉冲：开始读 I_want 号曲目
    input  wire [6:0] I_want,
    input  wire       I_abort_at,           // 电平：收到 I_abort_n 个字节以后中途关闭（0 = 不关）
    input  wire [15:0] I_abort_n,
    output reg        O_busy,
    output reg [31:0] O_bad,                // 累计：内容不对 / 长度不对的次数
    output reg [31:0] O_ok,                 // 累计：完整读对的次数
    output reg [31:0] O_errs,               // 累计：打开失败的次数
    output reg [2:0]  O_last_err,
    output reg [31:0] O_post                // 关闭命令发出之后又收到的字节数（应该是 0，最多容许 2 个已经在流水线里的）
);

reg [7:0] expd [0:8191];
integer   size = 0, n_got = 0, fd, c, k;
reg [8*64-1:0] fname;
integer   rnd = SEED;
integer   bad_here = 0;
integer   quiet = 0;
reg       aborting = 0;

initial begin O_busy = 0; O_bad = 0; O_ok = 0; O_errs = 0; O_last_err = 0; O_post = 0; O_open = 0; O_close = 0; O_clip = 0; O_space_ok = 1; end

always @(posedge clk) O_space_ok <= (($random(rnd) & 32'h7FFF) % 100) < 60;

always @(posedge clk) begin
    O_open  <= 1'b0;
    O_close <= 1'b0;
    if (I_go) begin
        for (k = 0; k < 8192; k = k + 1) expd[k] = 8'h00;
        $sformat(fname, "%0s_clip%0d.size", IMAGE, I_want);
        fd = $fopen(fname, "r");
        if (fd != 0) begin
            c = $fscanf(fd, "%d", size); $fclose(fd);
            $sformat(fname, "%0s_clip%0d.hex", IMAGE, I_want);
            $readmemh(fname, expd);
        end else size = -1;                                     // 没有这个文件（编号不存在）：不读期望内容
        n_got = 0; bad_here = 0; aborting = 0; quiet = 0; O_post <= 32'd0;
        O_clip <= I_want; O_open <= 1'b1; O_busy <= 1'b1;
    end
    if (I_data_valid && aborting) O_post <= O_post + 32'd1;
    if (I_data_valid) begin
        if (n_got < 8192 && I_data !== expd[n_got]) bad_here = bad_here + 1;
        n_got = n_got + 1;
        if (I_abort_at && n_got == I_abort_n && !aborting) begin O_close <= 1'b1; aborting = 1; end
    end
    if (I_eof && O_busy) begin
        O_busy <= 1'b0;
        if (bad_here != 0 || n_got != size) O_bad <= O_bad + 1; else O_ok <= O_ok + 1;
    end
    if (I_open_err) begin O_busy <= 1'b0; O_errs <= O_errs + 1; O_last_err <= I_err_code; end
    if (aborting && O_busy) begin                       // 关闭以后字节流必须停：连续一段时间没有再来数据就算这一路完成（不报告读完）
        if (I_data_valid) quiet = 0; else quiet = quiet + 1;
        if (quiet > 4000) O_busy <= 1'b0;
    end
end

endmodule


module tb_sdarb_case #(
    parameter IMAGE = "sd_mbr",
    parameter SDHC  = 1,
    parameter V2    = 1
)(
    output reg        fin,
    output reg [31:0] err
);

reg clk = 0, rst_n = 0;
always #5 clk = ~clk;

reg tick1ms = 0;
integer tdiv = 0;
always @(posedge clk) begin
    tick1ms <= 1'b0;
    if (tdiv == 99_999) begin tdiv <= 0; tick1ms <= 1'b1; end
    else tdiv <= tdiv + 1;
end

wire cs_n, sck, mosi, miso;
wire sd_ready, sd_fail, sdhc;
wire [2:0] sd_fail_code;
wire        rd_start, rd_busy, byte_valid, rd_done, rd_err;
wire [31:0] lba;
wire [7:0]  byte_d;
wire [8:0]  byte_idx;

mc_sd_spi sd (
    .I_clk(clk), .I_rst_n(rst_n), .I_tick_1ms(tick1ms),
    .O_cs_n(cs_n), .O_sck(sck), .O_mosi(mosi), .I_miso(miso),
    .I_init(1'b0), .O_ready(sd_ready), .O_fail(sd_fail), .O_fail_code(sd_fail_code), .O_sdhc(sdhc),
    .I_rd_start(rd_start), .I_lba(lba), .O_rd_busy(rd_busy),
    .O_byte_valid(byte_valid), .O_byte(byte_d), .O_byte_idx(byte_idx), .O_rd_done(rd_done), .O_rd_err(rd_err)
);

sd_card_model #(.IMAGE_FILE({IMAGE, ".hex"}), .SDHC(SDHC), .V2(V2), .ACMD41_TRIES(3), .READ_DELAY(5)) card (
    .cs_n(cs_n), .sck(sck), .mosi(mosi), .miso(miso)
);

wire        f0_start, f1_start, f0_busy, f1_busy;
wire [31:0] f0_lba, f1_lba;
wire        f0_valid, f1_valid, f0_done, f1_done, f0_err, f1_err;
wire [7:0]  f0_byte, f1_byte;
wire [8:0]  f0_idx, f1_idx;

mc_sd_arb arb (
    .I_clk(clk), .I_rst_n(rst_n),
    .I_start0(f0_start), .I_lba0(f0_lba), .O_busy0(f0_busy), .O_valid0(f0_valid), .O_byte0(f0_byte), .O_idx0(f0_idx), .O_done0(f0_done), .O_err0(f0_err),
    .I_start1(f1_start), .I_lba1(f1_lba), .O_busy1(f1_busy), .O_valid1(f1_valid), .O_byte1(f1_byte), .O_idx1(f1_idx), .O_done1(f1_done), .O_err1(f1_err),
    .O_start(rd_start), .O_lba(lba), .I_sd_busy(rd_busy),
    .I_valid(byte_valid), .I_byte(byte_d), .I_idx(byte_idx), .I_done(rd_done), .I_err(rd_err)
);

wire        m, mf, oerr0, oerr1, dv0, dv1, sp0, sp1, eof0, eof1, act0, act1, open0, open1, close0, close1;
wire [2:0]  mcode, ec0, ec1;
wire [7:0]  nc, d0, d1;
wire [6:0]  clip0, clip1;

mc_fat32 fat (
    .I_clk(clk), .I_rst_n(rst_n), .I_sd_ready(sd_ready), .I_sd_fail(sd_fail),
    .O_rd_start0(f0_start), .O_lba0(f0_lba), .I_rd_busy0(f0_busy), .I_byte_valid0(f0_valid), .I_byte0(f0_byte), .I_byte_idx0(f0_idx), .I_rd_done0(f0_done), .I_rd_err0(f0_err),
    .O_rd_start1(f1_start), .O_lba1(f1_lba), .I_rd_busy1(f1_busy), .I_byte_valid1(f1_valid), .I_byte1(f1_byte), .I_byte_idx1(f1_idx), .I_rd_done1(f1_done), .I_rd_err1(f1_err),
    .O_mounted(m), .O_mount_fail(mf), .O_mount_code(mcode), .O_nclips(nc),
    .I_open0(open0), .I_clip0(clip0), .I_close0(close0), .O_open_err0(oerr0), .O_err_code0(ec0),
    .O_data_valid0(dv0), .O_data0(d0), .I_space_ok0(sp0), .O_eof0(eof0), .O_active0(act0),
    .I_open1(open1), .I_clip1(clip1), .I_close1(close1), .O_open_err1(oerr1), .O_err_code1(ec1),
    .O_data_valid1(dv1), .O_data1(d1), .I_space_ok1(sp1), .O_eof1(eof1), .O_active1(act1)
);

reg        go0 = 0, go1 = 0, ab0 = 0, ab1 = 0;
reg [6:0]  want0 = 0, want1 = 0;
reg [15:0] abn0 = 0, abn1 = 0;
wire       busy0, busy1;
wire [31:0] bad0, ok0, errs0, bad1, ok1, errs1;
wire [2:0]  lerr0, lerr1;
wire [31:0] post0, post1;

// 白盒：读文件模块只在自己这一路的缓冲有空位（I_space_ok = 1）时才去读下一个数据扇区——进"读扇区"状态（ST_STR_RD = 5）那一拍，前一拍的 space_ok 必须是 1
reg sp0_d = 1'b1, sp1_d = 1'b1;
integer n_space_bad = 0;
always @(posedge clk) begin
    sp0_d <= sp0; sp1_d <= sp1;
    if (fat.u_rd0.S_st == 4'd5 && !sp0_d) n_space_bad = n_space_bad + 1;
    if (fat.u_rd1.S_st == 4'd5 && !sp1_d) n_space_bad = n_space_bad + 1;
end

tb_sdarb_rd #(.IMAGE(IMAGE), .SEED(11)) rd0 (
    .clk(clk), .rst_n(rst_n), .O_open(open0), .O_clip(clip0), .O_close(close0), .O_space_ok(sp0),
    .I_open_err(oerr0), .I_err_code(ec0), .I_data_valid(dv0), .I_data(d0), .I_eof(eof0),
    .I_go(go0), .I_want(want0), .I_abort_at(ab0), .I_abort_n(abn0),
    .O_busy(busy0), .O_bad(bad0), .O_ok(ok0), .O_errs(errs0), .O_last_err(lerr0), .O_post(post0)
);
tb_sdarb_rd #(.IMAGE(IMAGE), .SEED(22)) rd1 (
    .clk(clk), .rst_n(rst_n), .O_open(open1), .O_clip(clip1), .O_close(close1), .O_space_ok(sp1),
    .I_open_err(oerr1), .I_err_code(ec1), .I_data_valid(dv1), .I_data(d1), .I_eof(eof1),
    .I_go(go1), .I_want(want1), .I_abort_at(ab1), .I_abort_n(abn1),
    .O_busy(busy1), .O_bad(bad1), .O_ok(ok1), .O_errs(errs1), .O_last_err(lerr1), .O_post(post1)
);

task start0; input integer n; begin @(posedge clk); want0 <= n; go0 <= 1'b1; @(posedge clk); go0 <= 1'b0; end endtask
task start1; input integer n; begin @(posedge clk); want1 <= n; go1 <= 1'b1; @(posedge clk); go1 <= 1'b0; end endtask
task wait_idle;
    integer t;
    begin
        t = 0;
        repeat (5) @(posedge clk);
        while ((busy0 || busy1) && t < 4_000_000) begin @(posedge clk); t = t + 1; end
        if (busy0 || busy1) begin $display("FAIL [%0s] timeout waiting for both readers (busy0=%b busy1=%b)", IMAGE, busy0, busy1); err = err + 1; end
        t = 0;                                                  // 中途关闭的那一路，要等它把正在读的扇区读完、变成不活动，才能接受下一个打开命令（mc_wav_player 也是这样等的）
        while ((act0 || act1) && t < 4_000_000) begin @(posedge clk); t = t + 1; end
        if (act0 || act1) begin $display("FAIL [%0s] FAT reader stays active (act0=%b act1=%b)", IMAGE, act0, act1); err = err + 1; end
        repeat (200) @(posedge clk);
    end
endtask

integer ok0_b, ok1_b, bad0_b, bad1_b, e0_b, e1_b, i;
integer pair [0:7][0:1];
initial begin
    fin = 0; err = 0;
    repeat (10) @(posedge clk); rst_n = 1;

    // 挂载（两路共用一次）：挂载成功，找到 8 个曲目
    wait (m || mf || sd_fail);
    if (!m || mf || sd_fail) begin $display("FAIL [%0s] mount: m=%b mf=%b code=%0d sd_fail=%b", IMAGE, m, mf, mcode, sd_fail); err = err + 1; end
    if (nc !== 8'd8) begin $display("FAIL [%0s] nclips = %0d, expected 8", IMAGE, nc); err = err + 1; end

    // ---- 同时读不同的文件（几组搭配）----
    pair[0][0] = 2;  pair[0][1] = 5;        // 碎片化、簇号很大 ↔ 在目录第 2 个簇里
    pair[1][0] = 1;  pair[1][1] = 2;
    pair[2][0] = 10; pair[2][1] = 3;
    pair[3][0] = 2;  pair[3][1] = 2;        // 两路读同一个文件
    pair[4][0] = 4;  pair[4][1] = 1;        // 目录里写的大小 >= 16 MB 的那个（读到簇链结束）
    pair[5][0] = 5;  pair[5][1] = 10;
    pair[6][0] = 3;  pair[6][1] = 4;
    pair[7][0] = 1;  pair[7][1] = 5;
    for (i = 0; i < 8; i = i + 1) begin
        ok0_b = ok0; ok1_b = ok1; bad0_b = bad0; bad1_b = bad1;
        start0(pair[i][0]); start1(pair[i][1]);             // 同一拍开始
        wait_idle;
        if (ok0 !== ok0_b + 1 || bad0 !== bad0_b) begin $display("FAIL [%0s] pair %0d: reader 0 (clip %0d) ok %0d->%0d bad %0d->%0d", IMAGE, i, pair[i][0], ok0_b, ok0, bad0_b, bad0); err = err + 1; end
        if (ok1 !== ok1_b + 1 || bad1 !== bad1_b) begin $display("FAIL [%0s] pair %0d: reader 1 (clip %0d) ok %0d->%0d bad %0d->%0d", IMAGE, i, pair[i][1], ok1_b, ok1, bad1_b, bad1); err = err + 1; end
    end

    // ---- 一路中途关闭，另一路不受影响 ----
    ok1_b = ok1; bad1_b = bad1; ok0_b = ok0; bad0_b = bad0;
    ab0 = 1; abn0 = 700;                                    // 读 02.wav 读到 700 字节时关闭（共 2444 字节）
    start0(2); start1(5);
    wait_idle;
    ab0 = 0;
    if (ok1 !== ok1_b + 1 || bad1 !== bad1_b) begin $display("FAIL [%0s] reader 1 disturbed by reader 0 closing (ok %0d->%0d bad %0d->%0d)", IMAGE, ok1_b, ok1, bad1_b, bad1); err = err + 1; end
    if (ok0 !== ok0_b || bad0 !== bad0_b) begin $display("FAIL [%0s] reader 0 should not report a finished file after closing", IMAGE); err = err + 1; end
    if (post0 > 2) begin $display("FAIL [%0s] reader 0 kept sending %0d bytes after the close", IMAGE, post0); err = err + 1; end
    // 关闭以后还能重新读
    ok0_b = ok0;
    start0(2); wait_idle;
    if (ok0 !== ok0_b + 1) begin $display("FAIL [%0s] reader 0 cannot read again after closing", IMAGE); err = err + 1; end

    // ---- 反过来：1 路中途关闭，0 路不受影响 ----
    ok0_b = ok0; bad0_b = bad0; ok1_b = ok1; bad1_b = bad1;
    ab1 = 1; abn1 = 700;
    start0(5); start1(2);
    wait_idle;
    ab1 = 0;
    if (ok0 !== ok0_b + 1 || bad0 !== bad0_b) begin $display("FAIL [%0s] reader 0 disturbed by reader 1 closing (ok %0d->%0d bad %0d->%0d)", IMAGE, ok0_b, ok0, bad0_b, bad0); err = err + 1; end
    if (ok1 !== ok1_b || bad1 !== bad1_b) begin $display("FAIL [%0s] reader 1 should not report a finished file after closing", IMAGE); err = err + 1; end
    if (post1 > 2) begin $display("FAIL [%0s] reader 1 kept sending %0d bytes after the close", IMAGE, post1); err = err + 1; end
    ok1_b = ok1;
    start1(2); wait_idle;
    if (ok1 !== ok1_b + 1) begin $display("FAIL [%0s] reader 1 cannot read again after closing", IMAGE); err = err + 1; end

    // ---- 一路打开不存在的编号：只有这一路报错 ----
    e0_b = errs0; e1_b = errs1; ok1_b = ok1; bad1_b = bad1;
    start0(6); start1(2);
    wait_idle;
    if (errs0 !== e0_b + 1 || lerr0 !== 3'd1) begin $display("FAIL [%0s] reader 0 should get open error 1 for the missing clip 6 (errs %0d->%0d code %0d)", IMAGE, e0_b, errs0, lerr0); err = err + 1; end
    if (errs1 !== e1_b || ok1 !== ok1_b + 1 || bad1 !== bad1_b) begin $display("FAIL [%0s] reader 1 disturbed by reader 0's open error", IMAGE); err = err + 1; end
    // 反过来：1 路打开不存在的编号，0 路不受影响
    e0_b = errs0; e1_b = errs1; ok0_b = ok0; bad0_b = bad0;
    start0(2); start1(6);
    wait_idle;
    if (errs1 !== e1_b + 1 || lerr1 !== 3'd1) begin $display("FAIL [%0s] reader 1 should get open error 1 for the missing clip 6 (errs %0d->%0d code %0d)", IMAGE, e1_b, errs1, lerr1); err = err + 1; end
    if (errs0 !== e0_b || ok0 !== ok0_b + 1 || bad0 !== bad0_b) begin $display("FAIL [%0s] reader 0 disturbed by reader 1's open error", IMAGE); err = err + 1; end
    // 两路同时打开不存在的编号（9 不存在，99 超出这张卡上的文件）：都报错
    e0_b = errs0; e1_b = errs1;
    start0(9); start1(99);
    wait_idle;
    if (errs0 !== e0_b + 1 || errs1 !== e1_b + 1 || lerr0 !== 3'd1 || lerr1 !== 3'd1) begin $display("FAIL [%0s] both readers should get open error 1 (errs %0d->%0d, %0d->%0d)", IMAGE, e0_b, errs0, e1_b, errs1); err = err + 1; end

    // ---- 压力：两路各自反复打开，每次都要对 ----
    ok0_b = ok0; ok1_b = ok1; bad0_b = bad0; bad1_b = bad1;
    for (i = 0; i < 12; i = i + 1) begin
        start0((i % 4 == 0) ? 1 : (i % 4 == 1) ? 10 : (i % 4 == 2) ? 3 : 8);
        start1((i % 3 == 0) ? 2 : (i % 3 == 1) ? 5 : 4);
        wait_idle;
    end
    if (ok0 !== ok0_b + 12 || bad0 !== bad0_b) begin $display("FAIL [%0s] stress: reader 0 ok %0d->%0d bad %0d->%0d", IMAGE, ok0_b, ok0, bad0_b, bad0); err = err + 1; end
    if (ok1 !== ok1_b + 12 || bad1 !== bad1_b) begin $display("FAIL [%0s] stress: reader 1 ok %0d->%0d bad %0d->%0d", IMAGE, ok1_b, ok1, bad1_b, bad1); err = err + 1; end

    if (n_space_bad != 0) begin $display("FAIL [%0s] %0d data-sector reads started while that channel's buffer had no space", IMAGE, n_space_bad); err = err + 1; end
    fin = 1;
end

endmodule


module tb_sdarb;
wire f0, f1;
wire [31:0] e0, e1;
tb_sdarb_case #(.IMAGE("sd_mbr"),  .SDHC(1), .V2(1)) c0 (.fin(f0), .err(e0));
tb_sdarb_case #(.IMAGE("sd_flat"), .SDHC(0), .V2(0)) c1 (.fin(f1), .err(e1));
// 任何一个实例报错就马上结束（突变检查时省时间）
initial begin
    forever begin
        #20000;
        if (e0 != 0 || e1 != 0) begin $display("FAIL  tb_sdarb: errors %0d %0d, aborting early", e0, e1); $finish; end
    end
end
initial begin
    wait (f0 && f1);
    if (e0 + e1 == 0) $display("PASS  tb_sdarb");
    else              $display("FAIL  tb_sdarb: errors %0d %0d", e0, e1);
    $finish;
end
initial begin #300_000_000; $display("FAIL  tb_sdarb: timeout"); $finish; end
endmodule
