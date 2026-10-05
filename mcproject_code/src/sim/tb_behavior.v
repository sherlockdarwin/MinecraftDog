`timescale 1ns / 1ps
// 测试 mc_behavior（行为层）。
// 每个实例外面接一个"尾巴模型"和一个"音效模型"：
//   尾巴模型：收到 O_tail_wag 脉冲且空闲时忙 TAIL_T 个时钟（忙的时候收到的脉冲丢掉，像 mc_tail）；
//   音效模型：收到 O_sfx_play 脉冲且空闲时忙 SFX_T 个时钟（忙的时候收到的命令丢掉，像 mc_audio），记下曲目号；
//             结束时状态回 0；FAIL_NEXT = 1 时这一次以"出错"（状态 3）结束。
// 覆盖：
//   尾巴：喂食（hall = 1）时每个来回结束再检查一次，还是 1 就再来一个来回；变 0 后把当前来回摇完就停；忙的时候不发脉冲；
//         脉冲只有一个时钟宽；I_near = 1 时同样摇；
//   音效：音频没准备好就等着；准备好以后只触发一次（磁铁没拿开就不重播）；播放中不重复触发；
//         出错结束以后不重试，磁铁拿开再靠近才重新来；
//         狗叫和进食音效冲突时排队（进食先、狗叫后；同一个时钟一起到来也一样），I_bark 一直为 1 就循环叫；
//         狗叫变回 0 再来 → 再叫一次；狗叫出错结束后不重试，变回 0 再来才重试；进食音效出错后，狗叫正常播完也不会让它重试。
module tb_behavior_case (
    output reg        fin,
    output reg [31:0] err
);

localparam TAIL_T = 400;
localparam SFX_T  = 700;

reg clk = 0, rst_n = 0;
always #5 clk = ~clk;

reg hall = 0, near = 0, bark = 0, ready = 0;
reg  fail_next = 0;

wire        wag;
wire        play;
wire [6:0]  clip;

reg         tail_busy = 0;
reg         sfx_busy = 0;
reg  [1:0]  sfx_state = 0;
integer     tail_cnt = 0, sfx_t = 0, tail_t = 0;
integer     n_wag = 0, n_play = 0;
integer     n_play_eat = 0, n_play_bark = 0;
integer     last_clip = 0;
reg         pending_fail = 0;

mc_behavior #(.EAT_CLIP(7'd2), .BARK_CLIP(7'd3)) dut (
    .I_clk(clk), .I_rst_n(rst_n),
    .I_hall(hall), .I_near(near), .I_bark(bark),
    .I_audio_ready(ready), .I_sfx_busy(sfx_busy), .I_sfx_state(sfx_state), .I_tail_busy(tail_busy),
    .O_tail_wag(wag), .O_sfx_play(play), .O_sfx_clip(clip)
);

// ---- 尾巴 / 音效模型 + 违规检查 ----
reg wag_d = 0, play_d = 0;
always @(posedge clk) begin
    wag_d  <= wag;
    play_d <= play;
    if (wag && wag_d)    begin $display("FAIL wag pulse wider than 1 clock (t=%0t)", $time); err = err + 1; end
    if (play && play_d)  begin $display("FAIL play pulse wider than 1 clock (t=%0t)", $time); err = err + 1; end

    // 尾巴
    if (wag) begin
        if (tail_busy) begin $display("FAIL wag pulse while the tail is busy (t=%0t)", $time); err = err + 1; end
        else begin tail_busy <= 1'b1; tail_t <= TAIL_T; n_wag <= n_wag + 1; end
    end else if (tail_busy) begin
        if (tail_t <= 1) tail_busy <= 1'b0; else tail_t <= tail_t - 1;
    end

    // 音效
    if (play) begin
        if (!ready) begin $display("FAIL play pulse while the audio is not ready (t=%0t)", $time); err = err + 1; end
        if (sfx_busy) begin $display("FAIL play pulse while a sound effect is playing (t=%0t)", $time); err = err + 1; end
        else begin
            sfx_busy <= 1'b1; sfx_state <= 2'd2; sfx_t <= SFX_T; pending_fail <= fail_next; fail_next <= 1'b0;
            n_play <= n_play + 1; last_clip <= clip;
            if (clip == 7'd2) n_play_eat <= n_play_eat + 1;
            if (clip == 7'd3) n_play_bark <= n_play_bark + 1;
        end
    end else if (sfx_busy) begin
        if (sfx_t <= 1) begin sfx_busy <= 1'b0; sfx_state <= pending_fail ? 2'd3 : 2'd0; end
        else sfx_t <= sfx_t - 1;
    end
end

task expect;
    input [255:0] name;
    input integer got, exp;
    begin
        if (got !== exp) begin $display("FAIL [%0s] got %0d expected %0d (t=%0t)", name, got, exp, $time); err = err + 1; end
    end
endtask
task wait_clk; input integer n; begin repeat (n) @(posedge clk); end endtask

integer w0, p0, pe0, pb0;
initial begin
    fin = 0; err = 0;
    repeat (5) @(posedge clk); rst_n = 1; repeat (5) @(posedge clk);

    // ---------- 音效：音频没准备好就等着 ----------
    hall = 1;
    wait_clk(3000);
    expect("no play while the audio is not ready", n_play, 0);
    ready = 1;
    wait_clk(20);
    expect("play once when the audio becomes ready (clip 2 = eat)", n_play, 1);
    expect("eat clip number", last_clip, 2);

    // ---------- 播放中不重复触发；磁铁一直在 ----------
    wait_clk(SFX_T / 2);
    expect("still one play while the effect is playing", n_play, 1);
    wait_clk(SFX_T * 6);
    expect("no replay while the magnet stays", n_play, 1);

    // ---------- 尾巴：喂食期间一个来回接一个来回 ----------
    // hall = 1 已经持续了 SFX_T*6.5 = 4550 个时钟；尾巴每 TAIL_T+几个时钟摇一次
    if (n_wag < 8) begin $display("FAIL tail: only %0d wag cycles in 4500+ clocks while feeding (expected >= 8)", n_wag); err = err + 1; end

    // ---------- 磁铁拿开：当前来回摇完就停；再靠近重新开始 ----------
    wait_clk(100);                                       // 让当前这一圈在途中
    w0 = n_wag; p0 = n_play;
    hall = 0;
    wait_clk(TAIL_T + 50);
    if (n_wag - w0 > 1) begin $display("FAIL tail: %0d more cycles after the magnet left (expected at most 0 or 1)", n_wag - w0); err = err + 1; end
    w0 = n_wag;
    wait_clk(TAIL_T * 3);
    expect("tail idle after the magnet left", n_wag, w0);
    wait_clk(SFX_T);                                     // 进食音效（如果在播）播完
    p0 = n_play; pe0 = n_play_eat;
    hall = 1;
    wait_clk(30);
    expect("second feeding: a new play right away", n_play, p0 + 1);
    expect("second feeding plays clip 2", last_clip, 2);

    // ---------- 出错结束：不重试，磁铁拿开再靠近才重来 ----------
    wait_clk(SFX_T + 100);                               // 这次正常播完
    hall = 0; wait_clk(50);
    wait_clk(SFX_T);                                     // 保险：音效肯定已结束
    fail_next = 1;
    p0 = n_play;
    hall = 1;
    wait_clk(30);
    expect("play before the failing one", n_play, p0 + 1);
    wait_clk(SFX_T * 5);
    expect("no retry after an error while the magnet stays", n_play, p0 + 1);
    hall = 0; wait_clk(50); hall = 1; wait_clk(30);
    expect("magnet away and back: tries again", n_play, p0 + 2);
    wait_clk(SFX_T + 50);
    hall = 0; wait_clk(SFX_T + 50);

    // ---------- 尾巴：I_near 也让它摇 ----------
    w0 = n_wag;
    near = 1;
    wait_clk(TAIL_T * 4);
    if (n_wag - w0 < 3) begin $display("FAIL tail: near=1 gave only %0d cycles (expected >= 3)", n_wag - w0); err = err + 1; end
    near = 0;
    wait_clk(TAIL_T * 2);

    // ---------- 狗叫：和进食音效冲突时排队 ----------
    p0 = n_play; pe0 = n_play_eat; pb0 = n_play_bark;
    hall = 1; wait_clk(10);
    bark = 1;
    wait_clk(10);
    expect("eat started first", n_play_eat, pe0 + 1);
    expect("bark waits while the eat sound plays", n_play_bark, pb0);
    wait_clk(SFX_T + 30);
    expect("bark plays after the eat sound ended", n_play_bark, pb0 + 1);
    expect("bark clip number", last_clip, 3);
    wait_clk(SFX_T * 5);
    if (n_play_bark - pb0 < 4) begin $display("FAIL only %0d barks while bark stays 1 (expected >= 4)", n_play_bark - pb0); err = err + 1; end
    bark = 0; hall = 0;
    wait_clk(SFX_T * 3);
    p0 = n_play;
    wait_clk(SFX_T * 3);
    expect("nothing plays when no condition holds", n_play, p0);

    // ---------- 进食和狗叫在同一个时钟一起到来：进食先、狗叫后 ----------
    pe0 = n_play_eat; pb0 = n_play_bark;
    hall = 1; bark = 1;
    wait_clk(10);
    expect("both at once: eat first", n_play_eat, pe0 + 1);
    expect("both at once: bark waits", n_play_bark, pb0);
    wait_clk(SFX_T + 30);
    expect("both at once: bark follows", n_play_bark, pb0 + 1);
    hall = 0; bark = 0;
    wait_clk(SFX_T * 3);

    // ---------- 狗叫：变回 0 再来 → 再叫一次；出错以后只有变回 0 再来才重试 ----------
    pb0 = n_play_bark;
    bark = 1; wait_clk(30);
    expect("bark again after bark returned to 0", n_play_bark, pb0 + 1);
    wait_clk(SFX_T + 30);
    bark = 0; wait_clk(SFX_T * 2);
    fail_next = 1;
    pb0 = n_play_bark;
    bark = 1; wait_clk(30);
    expect("a bark that ends in an error is started once", n_play_bark, pb0 + 1);
    wait_clk(SFX_T * 5);
    expect("no bark retry after an error while bark stays 1", n_play_bark, pb0 + 1);
    bark = 0; wait_clk(50); bark = 1; wait_clk(30);
    expect("bark 0 then 1 after an error: tries again", n_play_bark, pb0 + 2);
    wait_clk(SFX_T + 30);
    bark = 0; wait_clk(SFX_T * 2);

    // ---------- 进食音效出错 + 狗叫：狗叫正常播完以后，进食音效也不重试（磁铁还在） ----------
    fail_next = 1;
    pe0 = n_play_eat;
    hall = 1; bark = 1;
    wait_clk(SFX_T * 4);
    expect("eat error, bark plays fine, eat does not retry", n_play_eat, pe0 + 1);
    hall = 0; bark = 0;
    wait_clk(SFX_T * 3);

    // ---------- 狗叫出错 + 进食：进食正常播完以后，狗叫也不重试（I_bark 还是 1） ----------
    fail_next = 1;
    pb0 = n_play_bark;
    bark = 1; wait_clk(SFX_T + 100);                     // 狗叫出错结束
    hall = 1; wait_clk(SFX_T * 4);
    expect("bark error, eat plays fine, bark does not retry", n_play_bark, pb0 + 1);
    hall = 0; bark = 0;
    wait_clk(SFX_T * 3);

    // ---------- 复位 ----------
    rst_n = 0; wait_clk(3); rst_n = 1; wait_clk(5);
    if (wag !== 1'b0 || play !== 1'b0) begin $display("FAIL outputs not idle after reset"); err = err + 1; end

    fin = 1;
end

endmodule


module tb_behavior;
wire f0;
wire [31:0] e0;
tb_behavior_case c0 (.fin(f0), .err(e0));
initial begin
    wait (f0);
    if (e0 == 0) $display("PASS  tb_behavior");
    else         $display("FAIL  tb_behavior: errors %0d", e0);
    $finish;
end
initial begin #20_000_000; $display("FAIL  tb_behavior: timeout"); $finish; end
endmodule
