`timescale 1ns / 1ps
// 测试 mc_i2s_tx：用一个标准 I2S 接收器（上升沿采样，LRCK 变化后第 2 个上升沿起是数据最高位）把输出解出来，
//   1) 连续送一串采样，解出来的左右声道必须逐帧等于送进去的；
//   2) 缺数据（I_valid=0）的帧发静音并给 O_underrun 脉冲；
//   3) MCLK = 12.5 MHz；SCLK、LRCK 的周期随 I_rate_sel（比值 256/384/512/768/1024）变化；
//   4) 一帧里的位数：SCLK 64 个，数据高 16 位、低 16 位补零。
module tb_i2s;

reg clk = 0, rst_n = 0;
always #5 clk = ~clk;                       // 100 MHz

reg  [2:0]  rate_sel = 0;
reg         valid = 0;
reg  [15:0] l_in = 0, r_in = 0;
wire        ack, under, mclk, sclk, lrck, dsdin;

mc_i2s_tx dut (
    .I_clk(clk), .I_rst_n(rst_n), .I_rate_sel(rate_sel), .I_valid(valid), .I_l(l_in), .I_r(r_in),
    .O_ack(ack), .O_underrun(under), .O_mclk(mclk), .O_sclk(sclk), .O_lrck(lrck), .O_dsdin(dsdin)
);

integer errors = 0;

// ---------------- 标准 I2S 接收器 ----------------
reg        lrck_q = 1;
integer    cnt = 0;
reg [15:0] sh = 0;
reg [15:0] rx_l = 0, rx_r = 0;
integer    n_frames = 0;                    // 收到的完整帧数（左右都收到）
reg        got_l = 0;
reg [15:0] exp_l [0:255];
reg [15:0] exp_r [0:255];
integer    exp_n = 0;
reg        pad_nonzero = 0;
always @(posedge sclk) begin
    if (lrck != lrck_q) cnt = 0; else cnt = cnt + 1;
    lrck_q = lrck;
    if (cnt >= 1 && cnt <= 16) sh = {sh[14:0], dsdin};
    if (cnt >= 17 && cnt <= 31 && dsdin !== 1'b0) pad_nonzero = 1;
    if (cnt == 16) begin
        if (lrck == 1'b0) begin rx_l = sh; got_l = 1; end
        else if (got_l) begin
            rx_r = sh; got_l = 0;
            // 与期望序列逐帧比较
            if (n_frames < exp_n) begin
                if (rx_l !== exp_l[n_frames] || rx_r !== exp_r[n_frames]) begin
                    if (errors < 10) $display("FAIL frame %0d: got L=%h R=%h expected L=%h R=%h", n_frames, rx_l, rx_r, exp_l[n_frames], exp_r[n_frames]);
                    errors = errors + 1;
                end
            end
            n_frames = n_frames + 1;
        end
    end
end

// ---------------- 供数侧：记录每次被取走的采样（决定期望序列）----------------
reg [15:0] src_l [0:255];
integer    src_n = 0, src_i = 0;
integer    n_ack = 0, n_under = 0;
always @(posedge clk) begin
    if (ack) begin
        exp_l[exp_n] = l_in; exp_r[exp_n] = r_in; exp_n = exp_n + 1; n_ack = n_ack + 1;
        // 取走后准备下一个采样（外面有一整帧的时间）
        src_i = src_i + 1;
        if (src_i < src_n) begin l_in <= 16'h1000 + src_i * 16'h0123; r_in <= 16'hF000 - src_i * 16'h0111; end
        else valid <= 1'b0;
    end
    if (under) begin
        exp_l[exp_n] = 16'h0000; exp_r[exp_n] = 16'h0000; exp_n = exp_n + 1; n_under = n_under + 1;
    end
end

// ---------------- 时钟频率测量 ----------------
integer t_mclk_a, t_mclk_b, mclk_edges;
integer t_sclk_a, t_sclk_b;
integer t_lrck_a, t_lrck_b;
realtime tm0, tm1;

task measure;
    input integer expect_ratio;
    realtime ta, tb, tl0, tl1, ts0, ts1;
    integer k;
    begin
        // MCLK 周期
        @(posedge mclk); ta = $realtime;
        for (k = 0; k < 10; k = k + 1) @(posedge mclk);
        tb = $realtime;
        if ((tb - ta) / 10.0 < 79.9 || (tb - ta) / 10.0 > 80.1) begin
            $display("FAIL MCLK period %f ns, expected 80", (tb - ta) / 10.0); errors = errors + 1;
        end
        // SCLK 周期 = MCLK 周期 × 比值/64 = 80 ns × ratio / 64
        @(posedge sclk); ts0 = $realtime;
        for (k = 0; k < 8; k = k + 1) @(posedge sclk);
        ts1 = $realtime;
        if ((ts1 - ts0) / 8.0 < 80.0 * expect_ratio / 64.0 - 0.1 || (ts1 - ts0) / 8.0 > 80.0 * expect_ratio / 64.0 + 0.1) begin
            $display("FAIL SCLK period %f ns, expected %f", (ts1 - ts0) / 8.0, 80.0 * expect_ratio / 64.0); errors = errors + 1;
        end
        // LRCK 周期 = MCLK 周期 × 比值
        @(posedge lrck); tl0 = $realtime;
        @(posedge lrck); tl1 = $realtime;
        if (tl1 - tl0 < 80.0 * expect_ratio - 0.5 || tl1 - tl0 > 80.0 * expect_ratio + 0.5) begin
            $display("FAIL LRCK period %f ns, expected %f", tl1 - tl0, 80.0 * expect_ratio); errors = errors + 1;
        end
    end
endtask

integer i;
initial begin
    for (i = 0; i < 40; i = i + 1) src_l[i] = i;
    repeat (10) @(posedge clk); rst_n = 1;

    // ---------- 1) 比值 256：连续 24 个采样 ----------
    rate_sel = 0;
    src_n = 24; src_i = 0;
    l_in = 16'h1000; r_in = 16'hF000; valid = 1;
    measure(256);
    wait (n_ack >= 24);
    repeat (6000) @(posedge clk);                          // 再等几帧：缺数据，应该是静音
    if (n_under < 2) begin $display("FAIL expected underrun pulses after data ran out, got %0d", n_under); errors = errors + 1; end
    if (n_frames < 26) begin $display("FAIL only %0d frames received", n_frames); errors = errors + 1; end
    if (pad_nonzero) begin $display("FAIL padding bits (low 16 bits of each slot) are not zero"); errors = errors + 1; end

    // ---------- 2) 比值 768（16 kHz 级）----------
    rate_sel = 3;
    repeat (20000) @(posedge clk);
    src_n = 10; src_i = 0; l_in <= 16'h1000; r_in <= 16'hF000; valid <= 1;
    repeat (3) @(posedge clk);
    measure(768);
    wait (n_ack >= 34);
    repeat (20000) @(posedge clk);
    if (n_frames + 3 < exp_n) begin $display("FAIL ratio 768: received %0d frames, expected about %0d", n_frames, exp_n); errors = errors + 1; end

    // ---------- 3) 比值 1024、384、512 只看周期 ----------
    rate_sel = 4; repeat (30000) @(posedge clk); measure(1024);
    rate_sel = 1; repeat (30000) @(posedge clk); measure(384);
    rate_sel = 2; repeat (30000) @(posedge clk); measure(512);

    if (errors == 0) $display("PASS  tb_i2s");
    else             $display("FAIL  tb_i2s: %0d errors", errors);
    $finish;
end

initial begin #50_000_000; $display("FAIL  tb_i2s: timeout"); $finish; end

endmodule
