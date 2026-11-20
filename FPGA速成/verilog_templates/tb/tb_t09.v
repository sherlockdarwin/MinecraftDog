// t09 饱和加减的自检 tb：用整数（不会溢出）算期望值，再夹到 0 ~ 最大值
`timescale 1ns/1ns
module tb_t09;

reg clk = 1'b0, rst_n = 1'b0;
always #5 clk = ~clk;
integer errors = 0;
`define CHK(got, exp, name) if ((got) !== (exp)) begin errors = errors + 1; if (errors < 20) $display("[%0t] ERROR %0s: got %0d exp %0d", $time, name, got, exp); end

reg        add_en = 0, sub_en = 0;
reg  [3:0] a4 = 0, s4 = 0;
reg  [9:0] a10 = 0, s10 = 0;
wire [3:0] acc4;
wire [9:0] acc10;
acc_sat #(.W(4))  u4  (.clk(clk), .rst_n(rst_n), .add_en(add_en), .add_val(a4),  .sub_en(sub_en), .sub_val(s4),  .acc(acc4));
acc_sat #(.W(10)) u10 (.clk(clk), .rst_n(rst_n), .add_en(add_en), .add_val(a10), .sub_en(sub_en), .sub_val(s10), .acc(acc10));

integer m4 = 0, m10 = 0, i, n_top = 0, n_zero = 0, n_both = 0;
always @(posedge clk) if (rst_n) begin
    m4  = m4  + (add_en ? a4  : 0) - (sub_en ? s4  : 0);
    m10 = m10 + (add_en ? a10 : 0) - (sub_en ? s10 : 0);
    if (m4 < 0)     begin m4 = 0; n_zero = n_zero + 1; end
    if (m4 > 15)    begin m4 = 15; n_top = n_top + 1; end
    if (m10 < 0)    m10 = 0;
    if (m10 > 1023) m10 = 1023;
    if (add_en && sub_en) n_both = n_both + 1;
end

initial begin
    repeat (2) @(negedge clk);
    rst_n = 1'b1;
    for (i = 0; i < 5000; i = i + 1) begin
        @(negedge clk);
        `CHK(acc4,  m4,  "acc4")
        `CHK(acc10, m10, "acc10")
        add_en = $random;  sub_en = $random;
        a4  = $random;  s4  = $random;
        a10 = (i % 1000 < 500) ? ($random & 255) : $random;   // 一段慢慢加，一段大起大落
        s10 = (i % 1000 < 500) ? ($random & 127) : $random;
    end
    $display("hit max %0d, hit 0 %0d, add+sub same cycle %0d", n_top, n_zero, n_both);
    if (n_top < 50 || n_zero < 50 || n_both < 500) begin errors = errors + 1; $display("ERROR: weak coverage"); end
    if (errors == 0) $display("PASS tb_t09"); else $display("FAIL tb_t09: %0d errors", errors);
    $stop;
end

endmodule
