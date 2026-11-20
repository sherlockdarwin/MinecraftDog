// t01 计数器的自检 tb：随机给输入，和整数参考模型逐拍比较
`timescale 1ns/1ns
module tb_t01;

reg clk = 1'b0, rst_n = 1'b0;
always #5 clk = ~clk;
integer errors = 0;
`define CHK(got, exp, name) if ((got) !== (exp)) begin errors = errors + 1; if (errors < 20) $display("[%0t] ERROR %0s: got %0d exp %0d", $time, name, got, exp); end

reg        en = 1'b0, load = 1'b0, up = 1'b0, down = 1'b0;
reg  [7:0] din = 8'd0;
wire [3:0] cnt10;  wire co10;
wire [2:0] cnt6;   wire co6;
wire [7:0] ucnt;

cnt_mod #(.N(10), .W(4)) u_m10 (.clk(clk), .rst_n(rst_n), .en(en), .cnt(cnt10), .co(co10));
cnt_mod #(.N(6),  .W(3)) u_m6  (.clk(clk), .rst_n(rst_n), .en(en), .cnt(cnt6),  .co(co6));
cnt_updown #(.W(8))      u_ud  (.clk(clk), .rst_n(rst_n), .load(load), .din(din), .up(up), .down(down), .cnt(ucnt));

// 参考模型：上升沿更新
integer m10 = 0, m6 = 0, mud = 0, i;
always @(posedge clk) if (rst_n) begin
    if (en) begin
        m10 = (m10 + 1) % 10;
        m6  = (m6 + 1) % 6;
    end
    if (load)              mud = din;
    else if (up && !down)  mud = (mud + 1) % 256;
    else if (down && !up)  mud = (mud + 255) % 256;
end

initial begin
    repeat (2) @(negedge clk);
    rst_n = 1'b1;
    for (i = 0; i < 3000; i = i + 1) begin
        @(negedge clk);
        `CHK(cnt10, m10, "cnt10")
        `CHK(cnt6,  m6,  "cnt6")
        `CHK(ucnt,  mud, "updown")
        en   = ($random & 3) != 0;
        load = ($random & 15) == 0;
        din  = $random;
        up   = $random;
        down = (i < 1500) ? $random : (($random & 3) != 0);   // 后半段多减，测从 0 回绕
        #1;
        `CHK(co10, (en && m10 == 9), "co10")
        `CHK(co6,  (en && m6 == 5),  "co6")
    end
    if (errors == 0) $display("PASS tb_t01"); else $display("FAIL tb_t01: %0d errors", errors);
    $stop;
end

endmodule
