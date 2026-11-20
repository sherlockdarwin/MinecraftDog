// t10 PWM 的自检 tb：每组 (period, duty) 稳定后数 K 个周期里的高电平拍数
`timescale 1ns/1ns
module tb_t10;

reg clk = 1'b0, rst_n = 1'b0;
always #5 clk = ~clk;
integer errors = 0;

reg  [7:0] period = 8'd10, duty = 8'd3;
wire       pwm_out;
pwm #(.W(8)) u_pwm (.clk(clk), .rst_n(rst_n), .period(period), .duty(duty), .pwm_out(pwm_out));

integer highs, k, exp;
task run_case(input [7:0] p, input [7:0] d);
begin
    @(negedge clk);
    period = p;  duty = d;
    repeat (2 * 256 + 2) @(negedge clk);     // 等旧的计数走完、稳定下来
    highs = 0;
    for (k = 0; k < 4 * p; k = k + 1) begin  // 正好 4 个周期
        @(negedge clk);
        if (pwm_out) highs = highs + 1;
    end
    exp = 4 * ((d < p) ? d : p);
    if (highs != exp) begin
        errors = errors + 1;
        $display("ERROR period=%0d duty=%0d: %0d high cycles in 4 periods, expect %0d", p, d, highs, exp);
    end
end
endtask

initial begin
    repeat (2) @(negedge clk);
    rst_n = 1'b1;
    run_case(10, 3);
    run_case(10, 0);
    run_case(10, 10);
    run_case(10, 15);
    run_case(1, 0);
    run_case(1, 1);
    run_case(7, 4);
    run_case(2, 1);
    run_case(255, 128);
    run_case(255, 254);
    if (errors == 0) $display("PASS tb_t10"); else $display("FAIL tb_t10: %0d errors", errors);
    $stop;
end

endmodule
