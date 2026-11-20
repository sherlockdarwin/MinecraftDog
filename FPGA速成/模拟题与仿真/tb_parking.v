`timescale 1ns/1ns
module tb_parking;
reg clk=0, rst_n=0, enter=0, leave=0;
wire [2:0] count;
wire full, empty;
integer errors=0;
always #5 clk=~clk;
parking_ctrl dut(.clk(clk),.rst_n(rst_n),.enter(enter),.leave(leave),.count(count),.full(full),.empty(empty));
task step;
  input en, lv; input [2:0] expected;
  begin
    @(negedge clk); enter=en; leave=lv;
    @(posedge clk); #1;
    if (count !== expected || full !== (expected==5) || empty !== (expected==0)) begin
      $display("FAIL time=%0t count=%0d full=%b empty=%b expected_count=%0d",$time,count,full,empty,expected); errors=errors+1;
    end
  end
endtask
initial begin
  repeat(2) @(negedge clk); rst_n=1;
  step(0,1,0); step(1,1,0);
  step(1,0,1); step(1,0,2); step(1,0,3); step(1,0,4); step(1,0,5);
  step(1,0,5); step(1,1,5); step(0,1,4); step(1,1,4); step(0,0,4);
  step(0,1,3); step(0,1,2); step(0,1,1); step(0,1,0);
  if(errors==0) $display("PASS tb_parking"); else $display("FAIL tb_parking errors=%0d",errors);
  $stop;
end
endmodule
