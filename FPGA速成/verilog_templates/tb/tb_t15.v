`timescale 1ns/1ns
module tb_t15;
reg clk=0, rst_n=0, valid=0;
reg signed [3:0] din=0;
wire signed [5:0] result;
wire ready;
integer errors=0;
always #5 clk=~clk;
signed_sum4 dut(.clk(clk),.rst_n(rst_n),.valid(valid),.din(din),.result(result),.ready(ready));
task step;
    input v; input signed [3:0] d; input er; input signed [5:0] value;
    begin
        @(negedge clk); valid=v; din=d;
        @(posedge clk); #1;
        if (ready !== er || (er && result !== value)) begin
            $display("FAIL signed: t=%0t ready=%b result=%0d expected=%0d",$time,ready,result,value);
            errors=errors+1;
        end
    end
endtask
initial begin
    repeat (2) @(negedge clk); rst_n=1;
    step(1,-8,0,0); step(1,-8,0,0); step(0,7,0,0); step(1,-8,0,0); step(1,-8,1,-32);
    step(1,7,0,0); step(1,7,0,0); step(1,7,0,0); step(1,7,1,28);
    step(1,-3,0,0); step(1,5,0,0); step(1,-8,0,0); step(1,7,1,1);
    step(0,0,0,0);
    if (errors==0) $display("PASS tb_t15"); else $display("FAIL tb_t15 errors=%0d",errors);
    $stop;
end
endmodule
