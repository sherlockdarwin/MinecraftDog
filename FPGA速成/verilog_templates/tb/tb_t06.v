// t06 序列检测的自检 tb：记下最近收到的位，按定义判断是否匹配
`timescale 1ns/1ns
module tb_t06;

reg clk = 1'b0, rst_n = 1'b0;
always #5 clk = ~clk;
integer errors = 0;
`define CHK(got, exp, name) if ((got) !== (exp)) begin errors = errors + 1; if (errors < 20) $display("[%0t] ERROR %0s: got %0d exp %0d", $time, name, got, exp); end

reg  din = 1'b0;
wire f_sh, f_fsm, f_0011;
seq_det_shift                   u_sh   (.clk(clk), .rst_n(rst_n), .din(din), .found(f_sh));
seq_det_fsm                     u_fsm  (.clk(clk), .rst_n(rst_n), .din(din), .found(f_fsm));
seq_det_shift #(.PAT(4'b0011))  u_0011 (.clk(clk), .rst_n(rst_n), .din(din), .found(f_0011));

reg [31:0] hist = 0;   // hist[0] = 最近一个沿收到的位
integer    n = 0, i, hits = 0, hits0011 = 0;
always @(posedge clk) if (rst_n) begin
    hist = {hist[30:0], din};
    n    = n + 1;
end

initial begin
    repeat (2) @(negedge clk);
    rst_n = 1'b1;
    din = 1'b1; @(negedge clk);      // 复位后先来 "11"：0011 版本不能把复位时的 0 算进去
    din = 1'b1; @(negedge clk);
    for (i = 0; i < 4000; i = i + 1) begin
        `CHK(f_sh,   (n >= 4 && hist[3:0] == 4'b1011), "shift 1011")
        `CHK(f_fsm,  (n >= 4 && hist[3:0] == 4'b1011), "fsm 1011")
        `CHK(f_0011, (n >= 4 && hist[3:0] == 4'b0011), "shift 0011")
        if (f_fsm)  hits = hits + 1;
        if (f_0011) hits0011 = hits0011 + 1;
        din = (i % 300 < 150) ? $random : ((i % 3) != 1);   // 后一段 "101101..." 有很多重叠
        @(negedge clk);
    end
    $display("1011 found %0d times, 0011 found %0d times", hits, hits0011);
    if (hits < 100 || hits0011 < 20) begin errors = errors + 1; $display("ERROR: too few hits"); end
    if (errors == 0) $display("PASS tb_t06"); else $display("FAIL tb_t06: %0d errors", errors);
    $stop;
end

endmodule
