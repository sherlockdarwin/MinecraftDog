// t11 消抖的自检 tb：抖动段（每段 < N 拍）输出不能变；稳定后第 N+1 个沿输出才变，且只变一次
`timescale 1ns/1ns
module tb_t11;

reg clk = 1'b0, rst_n = 1'b0;
always #5 clk = ~clk;
integer errors = 0;

localparam N = 20;
reg  key_in = 1'b0;
wire key_out, press;
debounce #(.N(N), .W(8)) u_db (.clk(clk), .rst_n(rst_n), .key_in(key_in), .key_out(key_out), .press(press));

integer cyc = 0, n_press = 0, n_change = 0;
reg     last_out = 1'b0;
always @(posedge clk) if (rst_n) cyc = cyc + 1;
always @(posedge press)   n_press  = n_press + 1;
always @(key_out) if (rst_n) n_change = n_change + 1;

// 抖动：在 level 和 ~level 之间来回跳，每段 1~(N-2) 拍，最后停在 level 上
integer seg, len, s_cyc, i;
task bounce_to(input level);
begin
    for (seg = 0; seg < 8; seg = seg + 1) begin
        len = 1 + (($random & 255) % (N - 2));
        @(negedge clk) key_in = (seg % 2 == 0) ? level : ~level;
        repeat (len - 1) @(negedge clk);
    end
    @(negedge clk) key_in = level;   // 从这一拍开始稳定
    s_cyc = cyc;                     // 稳定后第一个被采样的沿是第 s_cyc+1 个
end
endtask

task expect_change(input level);
begin
    // 期望：稳定后第 1、2 个沿过两级同步，第 3 ~ N+2 个沿连续数 N 拍，第 N+2 个沿之后 key_out = level
    @(negedge clk);
    while (cyc < s_cyc + N + 2) begin
        if (key_out !== ~level) begin
            errors = errors + 1; $display("[%0t] ERROR key_out changed too early (cyc %0d)", $time, cyc - s_cyc);
        end
        @(negedge clk);
    end
    if (key_out !== level) begin
        errors = errors + 1; $display("[%0t] ERROR key_out not %0d at cyc %0d", $time, level, cyc - s_cyc);
    end
end
endtask

initial begin
    repeat (2) @(negedge clk);
    rst_n = 1'b1;
    for (i = 0; i < 5; i = i + 1) begin
        bounce_to(1'b1);
        expect_change(1'b1);
        repeat (30) @(negedge clk);
        bounce_to(1'b0);
        expect_change(1'b0);
        repeat (30) @(negedge clk);
    end
    if (n_press !== 5)   begin errors = errors + 1; $display("ERROR press count %0d", n_press); end
    if (n_change !== 10) begin errors = errors + 1; $display("ERROR key_out changed %0d times", n_change); end
    if (errors == 0) $display("PASS tb_t11"); else $display("FAIL tb_t11: %0d errors", errors);
    $stop;
end

endmodule
