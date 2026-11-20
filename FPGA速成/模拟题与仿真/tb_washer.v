`timescale 1ns/1ns
module tb_washer;
reg clk=0, rst_n=0, start=0, stop=0;
wire [1:0] phase;
wire busy;
integer errors=0;
always #5 clk=~clk;
washer_ctrl dut(.clk(clk),.rst_n(rst_n),.start(start),.stop(stop),.phase(phase),.busy(busy));
task step;
  input s, x; input [1:0] expected;
  begin
    @(negedge clk); start=s; stop=x;
    @(posedge clk); #1;
    if (phase !== expected || busy !== (expected != 0)) begin
      $display("FAIL time=%0t phase=%0d busy=%b expected=%0d",$time,phase,busy,expected); errors=errors+1;
    end
  end
endtask
initial begin
  repeat(2) @(negedge clk); rst_n=1;
  step(1,0,1); // 启动，进入洗涤
  step(0,0,1); step(1,0,1); step(0,0,1); step(0,0,2); // 4 拍后漂洗
  step(0,0,2); step(0,0,2); step(0,0,3); // 3 拍后脱水
  step(0,0,3); step(0,0,0); // 2 拍后待机
  step(1,0,1); step(1,1,0); // stop 高于 start
  step(1,0,1); step(0,0,1); step(0,0,1); step(0,0,1); step(0,0,2);
  step(0,1,0); step(0,0,0);
  if(errors==0) $display("PASS tb_washer"); else $display("FAIL tb_washer errors=%0d",errors);
  $stop;
end
endmodule
