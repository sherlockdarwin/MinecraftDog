`timescale 1ns/1ns
module tb_vending();
reg clk=0, rst_n=0;
reg coin_valid=0, buy=0, cancel=0;
reg [3:0] coin_value=0;
wire [4:0] credit, refund;
wire dispensing, insufficient;
vending_ctrl u_dut(.clk(clk),.rst_n(rst_n),.coin_valid(coin_valid),.coin_value(coin_value),
    .buy(buy),.cancel(cancel),.credit(credit),.dispensing(dispensing),
    .insufficient(insufficient),.refund(refund));
always #5 clk=~clk;
initial begin
    rst_n=0; #12 rst_n=1;
    // 输入在下降沿变化，下一上升沿采样；金额用十进制显示。
    @(negedge clk); coin_valid=1; coin_value=4'd5;
    @(negedge clk); coin_valid=0; buy=1; // 余额不足
    @(negedge clk); buy=0;
    @(negedge clk); coin_valid=1; coin_value=4'd4; buy=1; // 同拍投币+购买
    @(negedge clk); coin_valid=1; coin_value=4'd9; buy=1; // 出货期间，输入无效
    @(negedge clk); coin_valid=0; buy=0; cancel=1;       // 出货期间，退款无效
    @(negedge clk); cancel=0;
    @(negedge clk); // 第 4 个周期结束
    @(negedge clk); cancel=1; // 退剩余金额
    @(negedge clk); cancel=0; coin_valid=1; coin_value=4'd9;
    @(negedge clk); coin_value=4'd9;
    @(negedge clk); coin_value=4'd9; // 超过 20 时饱和
    @(negedge clk); coin_valid=1; coin_value=4'd4; buy=1; cancel=1; // 退款优先
    @(negedge clk); coin_valid=0; buy=0; cancel=0;
    #20; $stop;
end
endmodule
