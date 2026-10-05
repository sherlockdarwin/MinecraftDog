`timescale 1ns / 1ps
// 测试 mc_key：去抖、短按、长按、毛刺、复位时已被按住
// 运行：bash tools/sim.sh tb_key
module tb_key;

reg         clk = 0;
reg         rst_n = 0;
reg         tick = 0;
reg  [2:0]  key = 3'b111;               // 低有效，1 = 松开
wire [2:0]  pressed, down, shrt, lng;

always #5 clk = ~clk;                   // 100 MHz

mc_key #(.N(3), .TICK_MS(10), .DEBOUNCE_MS(20), .LONG_MS(800)) dut (
    .I_clk(clk), .I_rst_n(rst_n), .I_tick(tick), .I_key(key),
    .O_pressed(pressed), .O_down(down), .O_short(shrt), .O_long(lng)
);

// 扫描节拍：为了仿真快，每 16 个时钟给一个 tick（只数个数，不管实际时间）
integer tick_n = 0;
integer div = 0;
always @(posedge clk) begin
    tick <= 1'b0;
    div  <= div + 1;
    if (div == 15) begin
        div  <= 0;
        tick <= 1'b1;
        tick_n <= tick_n + 1;
    end
end

// 事件统计
integer cnt_down [0:2];
integer cnt_short[0:2];
integer cnt_long [0:2];
integer t_down   [0:2];
integer t_long   [0:2];
integer k;
initial for (k = 0; k < 3; k = k + 1) begin
    cnt_down[k] = 0; cnt_short[k] = 0; cnt_long[k] = 0; t_down[k] = 0; t_long[k] = 0;
end

always @(posedge clk) begin
    for (k = 0; k < 3; k = k + 1) begin
        if (down[k]) begin cnt_down[k]  = cnt_down[k]  + 1; t_down[k] = tick_n; end
        if (shrt[k]) cnt_short[k] = cnt_short[k] + 1;
        if (lng[k])  begin cnt_long[k]  = cnt_long[k]  + 1; t_long[k] = tick_n; end
    end
end

integer errors = 0;
task check;
    input [255:0] name;
    input integer got;
    input integer exp;
    begin
        if (got !== exp) begin
            $display("FAIL  %0s: got %0d, expected %0d (t=%0t)", name, got, exp, $time);
            errors = errors + 1;
        end
    end
endtask

task wait_ticks;
    input integer n;
    integer j;
    begin
        for (j = 0; j < n; j = j + 1) @(posedge tick);
    end
endtask

// 带抖动的按下/松开：先抖几个节拍再稳定
task press_bounce;
    input integer idx;
    begin
        key[idx] = 1'b0; wait_ticks(1);
        key[idx] = 1'b1; wait_ticks(1);
        key[idx] = 1'b0; wait_ticks(1);
        key[idx] = 1'b1; wait_ticks(1);
        key[idx] = 1'b0;
    end
endtask
task release_bounce;
    input integer idx;
    begin
        key[idx] = 1'b1; wait_ticks(1);
        key[idx] = 1'b0; wait_ticks(1);
        key[idx] = 1'b1;
    end
endtask

initial begin
    // ---- 场景 4：复位释放时 key0 已被按住 ----
    key = 3'b110;                       // key0 按下
    repeat (20) @(posedge clk);
    rst_n = 1;
    wait_ticks(120);                    // 一直按着（> 长按时间）
    check("held-at-reset: down",  cnt_down[0],  0);
    check("held-at-reset: short", cnt_short[0], 0);
    check("held-at-reset: long",  cnt_long[0],  0);
    check("held-at-reset: pressed level", pressed[0], 1);
    key = 3'b111;                       // 松手
    wait_ticks(10);
    check("after release: short", cnt_short[0], 0);
    check("after release: pressed level", pressed[0], 0);

    // ---- 场景 1：key0 带抖动的短按（按 10 个节拍 = 100 ms）----
    press_bounce(0);
    wait_ticks(10);
    release_bounce(0);
    wait_ticks(10);
    check("short: down",  cnt_down[0],  1);
    check("short: short", cnt_short[0], 1);
    check("short: long",  cnt_long[0],  0);

    // ---- 再来一次短按（连续两次短按应该算两次）----
    press_bounce(0);
    wait_ticks(6);
    release_bounce(0);
    wait_ticks(10);
    check("short x2: short", cnt_short[0], 2);

    // ---- 场景 2：key1 长按 100 个节拍后松手 ----
    key[1] = 1'b0;
    wait_ticks(100);
    check("long: down",  cnt_down[1],  1);
    check("long: long",  cnt_long[1],  1);
    check("long: pressed", pressed[1], 1);
    check("long: delay from down to long (ticks)", t_long[1] - t_down[1], 80);
    key[1] = 1'b1;
    wait_ticks(10);
    check("long: no short on release", cnt_short[1], 0);
    check("long: long only once", cnt_long[1], 1);

    // ---- 场景 3：key2 只按 1 个节拍（毛刺）----
    key[2] = 1'b0; wait_ticks(1); key[2] = 1'b1;
    wait_ticks(10);
    check("glitch: down",  cnt_down[2],  0);
    check("glitch: short", cnt_short[2], 0);

    // ---- 场景 5：恰好长按 79 个节拍应当是短按 ----
    key[2] = 1'b0;
    wait_ticks(2 + 70);                 // 去抖 2 个节拍 + 保持 70 个节拍 < 80
    key[2] = 1'b1;
    wait_ticks(10);
    check("just under long: long",  cnt_long[2],  0);
    check("just under long: short", cnt_short[2], 1);

    if (errors == 0) $display("PASS  tb_key");
    else             $display("FAIL  tb_key: %0d errors", errors);
    $finish;
end

initial begin
    #200_000_000;
    $display("FAIL  tb_key: timeout");
    $finish;
end

endmodule
