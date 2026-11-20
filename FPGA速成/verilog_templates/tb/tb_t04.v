// t04 边沿检测的自检 tb：记录每个上升沿采到的值，按定义算 rise / fall
`timescale 1ns/1ns
module tb_t04;

reg clk = 1'b0, rst_n = 1'b0;
always #5 clk = ~clk;
integer errors = 0;
`define CHK(got, exp, name) if ((got) !== (exp)) begin errors = errors + 1; if (errors < 20) $display("[%0t] ERROR %0s: got %0d exp %0d", $time, name, got, exp); end

reg  sig = 1'b0;
wire r1, f1, r2, f2;
edge_detect u_ed (.clk(clk), .rst_n(rst_n), .sig(sig), .rise(r1), .fall(f1));
sync_edge   u_se (.clk(clk), .rst_n(rst_n), .sig(sig), .rise(r2), .fall(f2));

// s1 = 上一个沿采到的 sig，s2 = 上上个，s3 = 再前一个（复位期间按 0 算）
reg s1 = 1'b0, s2 = 1'b0, s3 = 1'b0;
always @(posedge clk) begin
    if (!rst_n) begin s1 = 1'b0; s2 = 1'b0; s3 = 1'b0; end
    else begin s3 = s2; s2 = s1; s1 = sig; end
end

integer i, n_rise = 0;
initial begin
    repeat (2) @(negedge clk);
    rst_n = 1'b1;
    for (i = 0; i < 2000; i = i + 1) begin
        @(negedge clk);
        sig = (i % 50 < 25) ? $random : (i % 7 < 3);       // 一半随机，一半是几拍宽的方波
        #1;
        `CHK(r1,  sig & ~s1, "edge rise")
        `CHK(f1, ~sig &  s1, "edge fall")
        `CHK(r2,  s2 & ~s3,  "sync rise")
        `CHK(f2, ~s2 &  s3,  "sync fall")
        if (r1) n_rise = n_rise + 1;
    end
    if (n_rise < 100) begin errors = errors + 1; $display("ERROR: too few edges"); end
    if (errors == 0) $display("PASS tb_t04"); else $display("FAIL tb_t04: %0d errors", errors);
    $stop;
end

endmodule
