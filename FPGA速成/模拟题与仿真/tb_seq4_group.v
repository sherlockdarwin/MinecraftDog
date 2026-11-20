`timescale 1ns/1ns
module tb_seq4_group;
reg clk=0, rst_n=0, valid=0, din=0;
wire match, not_match;
integer errors=0;
always #5 clk=~clk;
seq4_group dut(.clk(clk),.rst_n(rst_n),.valid(valid),.din(din),.match(match),.not_match(not_match));
task step;
  input v, d, em, en;
  begin
    @(negedge clk); valid=v; din=d;
    @(posedge clk); #1;
    if (match !== em || not_match !== en) begin
      $display("FAIL time=%0t match=%b not_match=%b expected=%b%b",$time,match,not_match,em,en); errors=errors+1;
    end
  end
endtask
initial begin
  repeat(2) @(negedge clk); rst_n=1;
  step(1,1,0,0); step(1,0,0,0); step(0,1,0,0); step(1,1,0,0); step(1,1,1,0); // 1011
  step(1,1,0,0); step(1,0,0,0); step(1,1,0,0); step(1,0,0,1); // 1010
  step(1,1,0,0); step(1,0,0,0); step(1,1,0,0); step(1,1,1,0); // 1011
  step(0,0,0,0); step(0,1,0,0);
  if(errors==0) $display("PASS tb_seq4_group"); else $display("FAIL tb_seq4_group errors=%0d",errors);
  $stop;
end
endmodule
