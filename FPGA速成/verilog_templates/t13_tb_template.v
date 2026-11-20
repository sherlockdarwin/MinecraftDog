// =============================================================================
// t13 testbench 模板（这里测的是 t00_skeleton.v 里的 skeleton）
// 考试 tb 是题目给的，不用自己写；这个用来：看懂题目 tb、自己补测题目 tb 没覆盖的情况
// tb 也叫"激励文件"：它不是电路，只负责产生时钟 / 复位 / 输入（激励），把你的模块例化进来
// =============================================================================
`timescale 1ns/1ns                 // #1 = 1 ns，最小精度 1 ns

module tb_template;

// 1. 给被测模块的输入用 reg（tb 要给它赋值），接被测模块输出的用 wire
reg        clk   = 1'b0;
reg        rst_n = 1'b0;
reg        en    = 1'b0;
reg  [7:0] din   = 8'd0;
wire [7:0] dout_r;
wire [7:0] dout_w;
wire       flag;

// 2. 例化被测模块（DUT）：模块名 实例名 (.模块的端口(tb 里的信号), ...);
skeleton u_dut (
    .clk    (clk),
    .rst_n  (rst_n),
    .en     (en),
    .din    (din),
    .dout_r (dout_r),
    .dout_w (dout_w),
    .flag   (flag)
);

// 3. 时钟：每 5 ns 翻一次 → 周期 10 ns
always #5 clk = ~clk;

// 4. 小工具（task）：在下降沿改输入，避开上升沿（模块在上升沿采样，同时改会有先后之争）
integer errors = 0;

task check(input [7:0] got, input [7:0] exp, input [8*16-1:0] name);
begin
    if (got !== exp) begin         // !== 连 X 也能比出来
        errors = errors + 1;
        $display("[%0t] ERROR %0s = %0d, expect %0d", $time, name, got, exp);
    end
end
endtask

task en_for(input integer n);      // en 拉高 n 拍
begin
    @(negedge clk) en = 1'b1;
    repeat (n) @(negedge clk);
    en = 1'b0;
end
endtask

// 5. 激励（initial：从 0 时刻开始按顺序执行一遍）
initial begin
    // 要用 GTKWave 看波形时打开下面两行；ModelSim 不需要
    // $dumpfile("wave.vcd");
    // $dumpvars(0, tb_template);

    rst_n = 1'b0;
    repeat (3) @(negedge clk);     // 等 3 个下降沿
    rst_n = 1'b1;
    check(dout_w, 8'd0, "cnt after rst");

    din = 8'd42;
    @(negedge clk);                // 中间经过一个上升沿
    check(dout_r, 8'd42, "dout_r");

    en_for(5);
    check(dout_w, 8'd5, "cnt after 5");

    @(negedge clk) en = 1'b1;
    wait (flag == 1'b1);           // 一直等到 flag 变 1（cnt 到 99）。返回时刚过上升沿
    @(negedge clk);                // 注意：这个下降沿还在同一拍里，cnt 还是 99
    check(dout_w, 8'd99, "cnt at flag");
    @(negedge clk);                // 再过一个上升沿，cnt 才回 0
    check(dout_w, 8'd0, "cnt wrap");
    en = 1'b0;

    #100;                          // 再等 100 ns
    if (errors == 0) $display("PASS tb_template");
    else             $display("FAIL tb_template: %0d errors", errors);
    $stop;                         // 暂停（ModelSim 里停下来看波形）；$finish 是结束
end

// 6. 超时保护：wait 等不到时不会永远跑下去
initial begin
    #100000;
    $display("TIMEOUT");
    $stop;
end

// 7. 打印：$display 打一次；$monitor 任何一个变了就打一行；$strobe 在这一时刻所有赋值完成后打
// initial $monitor("%0t en=%b cnt=%0d flag=%b", $time, en, dout_w, flag);

endmodule
