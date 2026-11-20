`timescale 1ns/1ns
module tb_elevator();
reg clk=0, rst_n=0, request=0, emergency=0;
reg [3:0] requested_floor=0, people=0;
reg [9:0] weight=0;
wire [3:0] current_floor, target_floor;
wire busy, alert;
elevator_ctrl u_dut(.clk(clk),.rst_n(rst_n),.request(request),
    .requested_floor(requested_floor),.emergency(emergency),.people(people),.weight(weight),
    .current_floor(current_floor),.target_floor(target_floor),.busy(busy),.alert(alert));
always #5 clk=~clk;
initial begin
    rst_n=0; #12 rst_n=1;
    @(negedge clk); request=1; requested_floor=4'd3; emergency=0; // 非紧急不能去 3 楼
    @(negedge clk); request=0;
    @(negedge clk); request=1; requested_floor=4'd6; // 请求 6 楼
    @(negedge clk); request=0;
    @(negedge clk); people=4'd14; // 超员，暂停
    @(negedge clk); people=4'd13; weight=10'd1001; // 超重，继续暂停
    @(negedge clk); weight=10'd1000; request=1; requested_floor=4'd8; // 恢复，行进中请求无效
    @(negedge clk); request=0;
    @(negedge clk);
    @(negedge clk);
    @(negedge clk); // 到达 6 楼后请求紧急前往 3 楼
    request=1; requested_floor=4'd3; emergency=1;
    @(negedge clk); request=0; emergency=0;
    @(negedge clk);
    @(negedge clk);
    @(negedge clk); request=1; requested_floor=4'd9; // 越界请求无效
    @(negedge clk); request=0;
    #20; $stop;
end
endmodule
