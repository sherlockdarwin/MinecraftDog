`timescale 1ns / 1ps
// 测试 mc_audio_mix（两路音频重采样 + 混音）：外面接两个"播放器模型"（和 mc_wav_player 同样的取样握手：一帧等着被取，
// 取走（O_ack）以后过一会儿再给下一帧；数据取完状态回空闲）和一个 I2S 帧节拍发生器（每 2048 个时钟一个 I_frame 脉冲，同 mc_i2s_tx）。
// 参考模型在测试台里用整数运算独立写了一遍（采样率 ÷ 48828.125 的相位累加、取样、保持、混音、饱和）。
// 覆盖：
//   · 两路都空闲 → 输出静音；一路先开始、另一路中途加入；一路结束后输出回静音；
//   · 采样率：48 kHz（原生，每帧取一次）、16 kHz、44.1 kHz、12 kHz；取样的个数 = 帧数 × 采样率 ÷ 48828.125（±1）；
//   · 混音：左 = 背景音乐（立体声左右取平均）、右 = 音效（立体声左右取平均），两路各响各的（含正负极值）；
//   · 欠载：该取样的时候播放器没准备好 → 这一帧这一路补静音、O_ur 一个脉冲，没取走的采样下一次再取；
//   · 播放器状态不是 2（没在播）时这一路送静音。
module tb_audio_mix_case (
    output reg        fin,
    output reg [31:0] err
);

reg clk = 0, rst_n = 0;
always #5 clk = ~clk;

// ---------------- 采样值（带极值，测饱和）----------------
function [15:0] smp;
    input integer id, ch, n;
    integer m;
    begin
        m = n % 7;
        if (m == 3)      smp = 16'h7FFF;
        else if (m == 5) smp = 16'h8000;
        else             smp = (n * 131 + ch * 7919 + id * 5003 + 17) & 16'hFFFF;
    end
endfunction

// ---------------- 播放器模型 ----------------
reg         start0 = 0, start1 = 0;
integer     tot0 = 0, tot1 = 0;
reg         stereo0 = 0, stereo1 = 0;
reg  [15:0] rate0 = 16'd48000, rate1 = 16'd16000;
reg  [1:0]  st0 = 0, st1 = 0;
reg         v0 = 0, v1 = 0;
reg  [15:0] l0 = 0, r0 = 0, l1 = 0, r1 = 0;
reg         stall0 = 0, stall1 = 0;
integer     idx0 = 0, idx1 = 0, dly0 = 0, dly1 = 0;
wire        ack0, ack1, ur0, ur1;

always @(posedge clk) begin
    if (start0) begin idx0 = 0; dly0 = 30; st0 <= 2'd1; v0 <= 1'b0; end
    else if (st0 != 2'd0) begin
        if (ack0) begin v0 <= 1'b0; idx0 = idx0 + 1; dly0 = 25; end
        else if (!v0 && !stall0) begin
            if (dly0 > 0) dly0 = dly0 - 1;
            else if (idx0 < tot0) begin
                v0 <= 1'b1; l0 <= smp(0, 0, idx0); r0 <= stereo0 ? smp(0, 1, idx0) : smp(0, 0, idx0); st0 <= 2'd2;
            end else st0 <= 2'd0;
        end
    end
end
always @(posedge clk) begin
    if (start1) begin idx1 = 0; dly1 = 30; st1 <= 2'd1; v1 <= 1'b0; end
    else if (st1 != 2'd0) begin
        if (ack1) begin v1 <= 1'b0; idx1 = idx1 + 1; dly1 = 25; end
        else if (!v1 && !stall1) begin
            if (dly1 > 0) dly1 = dly1 - 1;
            else if (idx1 < tot1) begin
                v1 <= 1'b1; l1 <= smp(1, 0, idx1); r1 <= stereo1 ? smp(1, 1, idx1) : smp(1, 0, idx1); st1 <= 2'd2;
            end else st1 <= 2'd0;
        end
    end
end

// ---------------- I2S 帧节拍 ----------------
reg  frame = 0;
integer fcnt = 0;
always @(posedge clk) begin
    frame <= 1'b0;
    if (fcnt == 2047) begin fcnt <= 0; frame <= 1'b1; end
    else fcnt <= fcnt + 1;
end

wire        o_valid;
wire [15:0] o_l, o_r;

mc_audio_mix dut (
    .I_clk(clk), .I_rst_n(rst_n),
    .I_st0(st0), .I_v0(v0), .I_l0(l0), .I_r0(r0), .I_rate0(rate0), .O_ack0(ack0), .O_ur0(ur0),
    .I_st1(st1), .I_v1(v1), .I_l1(l1), .I_r1(r1), .I_rate1(rate1), .O_ack1(ack1), .O_ur1(ur1),
    .I_frame(frame), .O_valid(o_valid), .O_l(o_l), .O_r(o_r)
);

// ---------------- 参考模型（整数运算）----------------
localparam integer FS8 = 390625;
function integer rate8; input integer r; begin rate8 = (r >= 47500) ? FS8 : r * 8; end endfunction
function integer s16;   input [15:0] v; begin s16 = (v >= 32768) ? (v - 65536) : v; end endfunction
function integer ashr;  input integer v; input integer n; integer d; begin d = 1 << n; ashr = (v >= 0) ? (v / d) : -(((-v) + d - 1) / d); end endfunction
function [15:0] sat;    input integer v; begin if (v > 32767) sat = 16'h7FFF; else if (v < -32768) sat = 16'h8000; else sat = v[15:0]; end endfunction

integer rph0 = 0, rph1 = 0, rn0, rn1;
reg     rtake0 = 0, rtake1 = 0;
integer rh0l = 0, rh0r = 0, rh1l = 0, rh1r = 0;
reg  frame_d = 0;
reg  [15:0] exp_l = 0, exp_r = 0;
integer takes0 = 0, takes1 = 0, frames_active0 = 0, frames_active1 = 0;
integer n_ur0 = 0, n_ur1 = 0, n_frames = 0, n_chk = 0;
integer mm, ol, orr;
reg  chk_en = 0;

always @(posedge clk) begin
    frame_d <= frame;
    if (frame) begin
        if (st0 == 2'd2) begin
            rn0 = rph0 + rate8(rate0);
            if (rn0 >= FS8) begin rph0 = rn0 - FS8; rtake0 = 1; end else begin rph0 = rn0; rtake0 = 0; end
            frames_active0 = frames_active0 + 1;
        end else begin rph0 = FS8; rtake0 = 0; rh0l = 0; rh0r = 0; end
        if (st1 == 2'd2) begin
            rn1 = rph1 + rate8(rate1);
            if (rn1 >= FS8) begin rph1 = rn1 - FS8; rtake1 = 1; end else begin rph1 = rn1; rtake1 = 0; end
            frames_active1 = frames_active1 + 1;
        end else begin rph1 = FS8; rtake1 = 0; rh1l = 0; rh1r = 0; end
    end
    if (frame_d) begin                         // 下一拍取样（和 DUT 同一拍看 v0 / v1）
        if (rtake0) begin
            if (v0) begin rh0l = s16(l0); rh0r = s16(r0); takes0 = takes0 + 1; end
            else    begin rh0l = 0; rh0r = 0; end
        end
        if (rtake1) begin
            if (v1) begin rh1l = s16(l1); rh1r = s16(r1); takes1 = takes1 + 1; end
            else    begin rh1l = 0; rh1r = 0; end
        end
        // 混音
        ol  = ashr(rh0l + rh0r, 1);
        orr = ashr(rh1l + rh1r, 1);
        exp_l = sat(ol);
        exp_r = sat(orr);
        n_frames = n_frames + 1;
    end
    if (ur0) n_ur0 = n_ur0 + 1;
    if (ur1) n_ur1 = n_ur1 + 1;
end

// 每帧的 20 个时钟之后，把 DUT 输出和参考比一次
reg [4:0] sample_cnt = 0;
reg       sample_go = 0;
always @(posedge clk) begin
    if (frame) begin sample_cnt <= 5'd0; sample_go <= 1'b1; end
    else if (sample_go) begin
        sample_cnt <= sample_cnt + 5'd1;
        if (sample_cnt == 5'd20) begin
            sample_go <= 1'b0;
            if (chk_en) begin
                n_chk = n_chk + 1;
                if (o_l !== exp_l || o_r !== exp_r) begin
                    if (err < 10) $display("FAIL [mix] frame %0d: got L=%h R=%h expected L=%h R=%h (st0=%0d st1=%0d)", n_frames, o_l, o_r, exp_l, exp_r, st0, st1);
                    err = err + 1;
                end
            end
        end
    end
end

task wait_frames; input integer n; begin repeat (n) @(posedge frame); end endtask
task expect;
    input [255:0] name;
    input integer got, exp;
    begin
        if (got !== exp) begin $display("FAIL [%0s] got %0d expected %0d", name, got, exp); err = err + 1; end
    end
endtask
task expect_range;
    input [255:0] name;
    input integer got, lo, hi;
    begin
        if (got < lo || got > hi) begin $display("FAIL [%0s] got %0d expected %0d..%0d", name, got, lo, hi); err = err + 1; end
    end
endtask
task begin_stream0; input integer n; input stereo; input [15:0] rate;
    begin tot0 = n; stereo0 = stereo; rate0 = rate; takes0 = 0; frames_active0 = 0; @(posedge clk); start0 <= 1'b1; @(posedge clk); start0 <= 1'b0; end
endtask
task begin_stream1; input integer n; input stereo; input [15:0] rate;
    begin tot1 = n; stereo1 = stereo; rate1 = rate; takes1 = 0; frames_active1 = 0; @(posedge clk); start1 <= 1'b1; @(posedge clk); start1 <= 1'b0; end
endtask

integer k, ur_before;
initial begin
    fin = 0; err = 0;
    repeat (10) @(posedge clk); rst_n = 1;
    wait_frames(3);
    chk_en = 1;

    // ---------- 1) 都空闲 ----------
    wait_frames(20);
    if (o_l !== 16'd0 || o_r !== 16'd0) begin $display("FAIL [mix] idle output not silent: %h %h", o_l, o_r); err = err + 1; end
    if (o_valid !== 1'b1) begin $display("FAIL [mix] O_valid must stay 1"); err = err + 1; end
    expect("no underrun while both are idle", n_ur0 + n_ur1, 0);

    // ---------- 2) 流 0：48 kHz 立体声，每帧取一次；流 1 中途加入：16 kHz 单声道 ----------
    begin_stream0(300, 1'b1, 16'd48000);
    wait_frames(80);
    begin_stream1(120, 1'b0, 16'd16000);
    wait_frames(400);                                   // 流 0（300 帧）和流 1（120 个采样 ≈ 366 帧）都应结束
    expect("stream 0: every frame takes a sample at 48 kHz", takes0, 300);
    expect("stream 0: 300 frames used for 300 samples at 48 kHz", frames_active0, 300);
    expect("stream 1: all 120 samples taken at 16 kHz", takes1, 120);
    // 16 kHz：每个采样大约占 3.05 个帧
    expect("stream 1: frames used for 120 samples at 16 kHz", frames_active1, ((120 - 1) * FS8 + rate8(16000) - 1) / rate8(16000));
    wait_frames(20);
    if (st0 !== 2'd0 || st1 !== 2'd0) begin $display("FAIL [mix] players should have ended"); err = err + 1; end
    if (o_l !== 16'd0 || o_r !== 16'd0) begin $display("FAIL [mix] output not silent after both ended: %h %h", o_l, o_r); err = err + 1; end

    // ---------- 3) 44.1 kHz（流 0，单声道）+ 12 kHz（流 1，立体声）----------
    begin_stream0(200, 1'b0, 16'd44100);
    begin_stream1(50, 1'b1, 16'd12000);
    wait_frames(260);
    expect("stream 0: all 200 samples at 44.1 kHz", takes0, 200);
    expect("stream 1: all 50 samples at 12 kHz", takes1, 50);
    expect("stream 0: frames used for 200 samples at 44.1 kHz", frames_active0, ((200 - 1) * FS8 + rate8(44100) - 1) / rate8(44100));
    expect("stream 1: frames used for 50 samples at 12 kHz", frames_active1, ((50 - 1) * FS8 + rate8(12000) - 1) / rate8(12000));
    expect("no underrun in normal playback", n_ur0 + n_ur1, 0);
    wait_frames(10);

    // ---------- 3b) 刚要开播（状态 1：打开中）时碰上一个帧节拍：这一路还不算在播，不取样、不报欠载 ----------
    @(posedge frame);
    repeat (2030) @(posedge clk);                         // 离下一个帧节拍还有约 17 个时钟，而播放器要 30 多个时钟才给出第一个采样
    ur_before = n_ur0 + n_ur1;
    begin_stream0(30, 1'b0, 16'd48000);
    wait_frames(40);
    expect("a stream that is still opening at a frame tick: no underrun", n_ur0 + n_ur1, ur_before);
    expect("that stream still plays all its samples", takes0, 30);
    wait_frames(10);
    @(posedge frame);                                     // 流 1 同样
    repeat (2030) @(posedge clk);
    ur_before = n_ur0 + n_ur1;
    begin_stream1(30, 1'b0, 16'd48000);
    wait_frames(40);
    expect("stream 1 still opening at a frame tick: no underrun", n_ur0 + n_ur1, ur_before);
    expect("stream 1 still plays all its samples", takes1, 30);
    wait_frames(10);

    // ---------- 4) 欠载：流 0 的某个采样迟到 3 帧 ----------
    begin_stream0(40, 1'b0, 16'd48000);
    wait_frames(10);
    stall0 = 1;                                         // 现在起不再给新采样
    wait_frames(3);
    stall0 = 0;
    wait_frames(60);
    if (n_ur0 < 1) begin $display("FAIL [mix] no underrun reported while stream 0 was starved"); err = err + 1; end
    expect("stream 0 finishes all samples after the stall", takes0, 40);
    wait_frames(10);

    // ---------- 4b) 音效这一路也欠载：采样迟到 3 帧 → 这一路补静音、O_ur1 一个脉冲 ----------
    begin_stream1(40, 1'b0, 16'd48000);
    wait_frames(10);
    stall1 = 1;
    wait_frames(3);
    stall1 = 0;
    wait_frames(60);
    if (n_ur1 < 1) begin $display("FAIL [mix] no underrun reported while stream 1 was starved"); err = err + 1; end
    expect("stream 1 finishes all samples after the stall", takes1, 40);
    wait_frames(10);

    // ---------- 4c) "当作原生 48 kHz"的边界：47500 Hz 起每帧取一次，47499 Hz 就按比例取（偶尔跳过一个帧）----------
    begin_stream0(200, 1'b0, 16'd47500);
    begin_stream1(200, 1'b0, 16'd47499);
    wait_frames(230);
    expect("stream 0: 47500 Hz counts as native (one frame per sample)", frames_active0, 200);
    expect("stream 0: all 200 samples at 47500 Hz", takes0, 200);
    expect("stream 1: 47499 Hz is resampled (a few more frames than samples)", frames_active1, ((200 - 1) * FS8 + rate8(47499) - 1) / rate8(47499));
    expect("stream 1: all 200 samples at 47499 Hz", takes1, 200);
    wait_frames(10);

    // ---------- 4d) 相位累加正好等于一个帧的量的那一帧也要取样（8000 Hz / 4000 Hz：每 3125 帧出现一次刚好相等；参考模型按"够一个帧就取"算）----------
    begin_stream0(560, 1'b0, 16'd8000);
    begin_stream1(280, 1'b1, 16'd4000);
    wait_frames(3500);
    expect("stream 0: all 560 samples at 8 kHz", takes0, 560);
    expect("stream 1: all 280 samples at 4 kHz", takes1, 280);
    wait_frames(10);

    // ---------- 5) 饱和：两路都用极值多的采样，混音模式下会撞到限幅；这里直接让两路同时播同样长度 ----------
    begin_stream0(140, 1'b1, 16'd48000);
    begin_stream1(140, 1'b1, 16'd48000);
    wait_frames(160);
    wait_frames(10);

    if (n_chk < 1000) begin $display("FAIL [mix] only %0d frames were compared", n_chk); err = err + 1; end
    fin = 1;
end

endmodule


module tb_audio_mix;
wire f0;
wire [31:0] e0;
tb_audio_mix_case c0 (.fin(f0), .err(e0));
initial begin
    wait (f0);
    if (e0 == 0) $display("PASS  tb_audio_mix");
    else         $display("FAIL  tb_audio_mix: errors %0d", e0);
    $finish;
end
initial begin #400_000_000; $display("FAIL  tb_audio_mix: timeout"); $finish; end
endmodule
