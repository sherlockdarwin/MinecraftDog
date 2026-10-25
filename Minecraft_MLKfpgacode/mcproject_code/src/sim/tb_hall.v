`timescale 1ns / 1ps
// 测试 mc_hall（霍尔传感器输入：两级同步 + 去抖）：
//   1) 复位后 O_fed = 0（磁铁离开）；
//   2) 比去抖时间短的脉冲（毛刺）不会让 O_fed 变化；稳定超过去抖时间才变，变得不能太早也不能太晚；
//   3) 抖动（反复翻转）的过程中不翻转，稳定之后才翻转；
//   4) 上电时磁铁就在旁边：去抖时间之后 O_fed = 1。
// "1 ms" 节拍取 100 个时钟（1 us），去抖 5 ms。
module tb_hall;

reg clk = 0, rst_n = 0;
always #5 clk = ~clk;

reg tick1 = 0;
integer dcnt = 0;
always @(posedge clk) begin
    tick1 <= 1'b0;
    if (dcnt == 99) begin dcnt <= 0; tick1 <= 1'b1; end
    else dcnt <= dcnt + 1;
end

reg  hall_a = 0;           // 靠近输出高
reg  hall_c = 0;           // 复位释放时就是高（上电时磁铁就在旁边）
wire fed_a, fed_c;

mc_hall #(.DEBOUNCE_MS(5)) dut_a (.I_clk(clk), .I_rst_n(rst_n), .I_tick_1ms(tick1), .I_hall(hall_a), .O_fed(fed_a));
mc_hall #(.DEBOUNCE_MS(5)) dut_c (.I_clk(clk), .I_rst_n(rst_n), .I_tick_1ms(tick1), .I_hall(hall_c), .O_fed(fed_c));

integer errors = 0;
task expect;
    input [255:0] name;
    input got, exp;
    begin
        if (got !== exp) begin $display("FAIL [%0s] got %b expected %b (t=%0t)", name, got, exp, $time); errors = errors + 1; end
    end
endtask

task ms; input integer n; begin repeat (n) @(posedge tick1); end endtask

integer t_rise;
initial begin
    repeat (5) @(posedge clk);
    rst_n = 1;
    hall_c = 1;                                // 复位一释放，C 就是高
    repeat (5) @(posedge clk);
    expect("A idle after reset", fed_a, 1'b0);

    // ---- 2) 毛刺 ----
    hall_a = 1; ms(3); hall_a = 0; ms(10);
    expect("A: 3 ms glitch ignored", fed_a, 1'b0);

    // ---- 稳定的高：5 ms 去抖（翻转发生在输入变化之后的第 5 个 1 ms 节拍；每次检查都放在节拍之后 3 个时钟，让寄存器更新完）----
    hall_a = 1;
    ms(3);  repeat (3) @(posedge clk); expect("A: not yet at 3 ms", fed_a, 1'b0);
    ms(1);  repeat (3) @(posedge clk); expect("A: not yet at 4 ms", fed_a, 1'b0);
    ms(1);  repeat (3) @(posedge clk); expect("A: high at exactly 5 ms", fed_a, 1'b1);
    ms(10); expect("A: stays high", fed_a, 1'b1);

    // ---- 低方向的毛刺 / 稳定 ----
    hall_a = 0; ms(2); hall_a = 1; ms(10);
    expect("A: 2 ms low glitch ignored", fed_a, 1'b1);
    hall_a = 0;
    ms(4);  repeat (3) @(posedge clk); expect("A: still high at 4 ms", fed_a, 1'b1);
    ms(1);  repeat (3) @(posedge clk); expect("A: low at exactly 5 ms", fed_a, 1'b0);

    // ---- 3) 抖动：每 1 ms 翻转一次，共 20 次，期间不能翻；最后停在高，之后才翻 ----
    repeat (20) begin hall_a = ~hall_a; ms(1); end
    hall_a = 1;                                // 20 次翻转后（偶数次）这里本来就是 1，保持
    expect("A: no change while bouncing", fed_a, 1'b0);
    ms(7);
    expect("A: high after bouncing stopped", fed_a, 1'b1);

    // ---- 4) 上电时磁铁就在旁边 ----
    expect("C: fed after the debounce time with the magnet already near", fed_c, 1'b1);

    // ---- 复位清零 ----
    rst_n = 0; @(posedge clk); #1;
    expect("A: reset clears fed", fed_a, 1'b0);
    expect("C: reset clears fed", fed_c, 1'b0);
    rst_n = 1;

    if (errors == 0) $display("PASS  tb_hall");
    else             $display("FAIL  tb_hall: %0d errors", errors);
    $finish;
end

initial begin #50_000_000; $display("FAIL  tb_hall: timeout"); $finish; end

endmodule
