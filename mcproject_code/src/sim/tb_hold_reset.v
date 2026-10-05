`timescale 1ns / 1ps
// 测试 mc_hold_reset：按住够久才复位、松手后才能再次触发、短按不触发
// 为了仿真快：CLK_HZ 取 1 MHz（1 ms = 1000 个时钟），HOLD_MS = 20，PULSE_MS = 2
module tb_hold_reset;

reg  clk = 0;
reg  key_n = 1;
wire rst;

always #500 clk = ~clk;                 // 1 MHz

mc_hold_reset #(.CLK_HZ(1_000_000), .HOLD_MS(20), .PULSE_MS(2)) dut (
    .I_clk(clk), .I_key_n(key_n), .O_rst(rst)
);

integer errors = 0;
integer pulses = 0;
integer width_clk = 0;
reg rst_d = 0;
always @(posedge clk) begin
    rst_d <= rst;
    if (rst && !rst_d) pulses <= pulses + 1;
    if (rst) width_clk <= width_clk + 1;
end

task ms; input integer n; begin repeat (n * 1000) @(posedge clk); end endtask

initial begin
    // 短按 10 ms：不触发
    key_n = 0; ms(10); key_n = 1; ms(30);
    if (pulses !== 0) begin $display("FAIL short press triggered reset"); errors = errors + 1; end

    // 按住 50 ms：触发一次，宽度 ≈ 2 ms
    key_n = 0; ms(50);
    if (pulses !== 1) begin $display("FAIL hold: pulses=%0d expected 1", pulses); errors = errors + 1; end
    if (width_clk < 1900 || width_clk > 2200) begin $display("FAIL pulse width %0d clk (expected ~2000)", width_clk); errors = errors + 1; end
    if (rst !== 1'b0) begin $display("FAIL rst still high after pulse"); errors = errors + 1; end

    // 继续按着：不能重复触发
    ms(60);
    if (pulses !== 1) begin $display("FAIL retriggered while held: %0d", pulses); errors = errors + 1; end

    // 松手再按住：再触发一次
    key_n = 1; ms(5); key_n = 0; ms(40);
    if (pulses !== 2) begin $display("FAIL second hold: pulses=%0d expected 2", pulses); errors = errors + 1; end

    if (errors == 0) $display("PASS  tb_hold_reset");
    else             $display("FAIL  tb_hold_reset: %0d errors", errors);
    $finish;
end

endmodule
