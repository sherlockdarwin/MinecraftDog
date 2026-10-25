`timescale 1ns / 1ps
// 测试 mc_bench：SW2 短按 → 增益 + 键脉冲、SW3 短按 → 增益 - 键脉冲（低电平正好 4 个 10 ms 节拍）；
//   SW1 短按什么也不做；再按一次会重新计时（从按下那一拍起再低 4 拍）；两个键一起按两路各自出脉冲。
module tb_bench;

reg clk = 0, rst_n = 0;
always #5 clk = ~clk;

// 10 ms 节拍（仿真里每 100 个时钟一拍，模块只数拍数）
reg tick = 0;
integer tdiv = 0;
always @(posedge clk) begin
    tick <= 1'b0;
    if (tdiv == 99) begin tdiv <= 0; tick <= 1'b1; end
    else tdiv <= tdiv + 1;
end

reg  [2:0] ks = 0;
wire [1:0] cam_key_n;

mc_bench dut (
    .I_clk(clk), .I_rst_n(rst_n), .I_tick_10ms(tick), .I_key_short(ks), .O_cam_key_n(cam_key_n)
);

integer errors = 0;

// 低电平持续了几个节拍（每一路分别数）
integer low_ticks0 = 0, low_ticks1 = 0;
always @(posedge clk) if (tick) begin
    if (!cam_key_n[0]) low_ticks0 = low_ticks0 + 1;
    if (!cam_key_n[1]) low_ticks1 = low_ticks1 + 1;
end

task short_press; input [2:0] m; begin @(posedge clk); ks <= m; @(posedge clk); ks <= 3'b000; repeat (3) @(posedge clk); end endtask
task expect_cam;
    input [255:0] name;
    input [1:0] e;
    begin
        if (cam_key_n !== e) begin
            $display("FAIL [%0s] cam_key_n=%b, expected %b", name, cam_key_n, e);
            errors = errors + 1;
        end
    end
endtask
task expect_ticks;
    input [255:0] name;
    input integer e0, e1;
    begin
        if (low_ticks0 !== e0 || low_ticks1 !== e1) begin
            $display("FAIL [%0s] low ticks %0d/%0d, expected %0d/%0d", name, low_ticks0, low_ticks1, e0, e1);
            errors = errors + 1;
        end
    end
endtask

initial begin
    repeat (5) @(posedge clk); rst_n = 1; repeat (5) @(posedge clk);
    expect_cam("reset: keys idle high", 2'b11);

    // SW2 短：+ 键低 4 拍
    low_ticks0 = 0; low_ticks1 = 0;
    short_press(3'b010); expect_cam("SW2 short -> gain+ low", 2'b10);
    repeat (8) @(posedge tick); expect_cam("SW2 pulse ended", 2'b11);
    expect_ticks("SW2 pulse = 4 ticks", 4, 0);

    // SW3 短：- 键低 4 拍
    low_ticks0 = 0; low_ticks1 = 0;
    short_press(3'b100); expect_cam("SW3 short -> gain- low", 2'b01);
    repeat (8) @(posedge tick); expect_cam("SW3 pulse ended", 2'b11);
    expect_ticks("SW3 pulse = 4 ticks", 0, 4);

    // SW1 短：什么也不做
    low_ticks0 = 0; low_ticks1 = 0;
    short_press(3'b001); repeat (8) @(posedge tick);
    expect_ticks("SW1 short does nothing", 0, 0);

    // 两个一起
    low_ticks0 = 0; low_ticks1 = 0;
    short_press(3'b110); expect_cam("SW2 + SW3 together", 2'b00);
    repeat (8) @(posedge tick);
    expect_ticks("both pulses 4 ticks", 4, 4);

    // 脉冲中再按：重新计时（第 2 拍时再按 → 共 2 + 4 = 6 拍）
    low_ticks0 = 0; low_ticks1 = 0;
    short_press(3'b010);
    repeat (2) @(posedge tick); #1;
    short_press(3'b010);
    repeat (8) @(posedge tick);
    expect_ticks("re-press restarts the 4-tick pulse", 6, 0);

    if (errors == 0) $display("PASS  tb_bench");
    else             $display("FAIL  tb_bench: %0d errors", errors);
    $finish;
end

initial begin #5_000_000; $display("FAIL  tb_bench: timeout"); $finish; end

endmodule
