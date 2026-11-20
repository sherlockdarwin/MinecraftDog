// 参考答案：目标只在待机且无警报时接收；过载时冻结当前楼层及目标。
module elevator_ctrl(
    input clk, input rst_n,
    input request, input [3:0] requested_floor, input emergency,
    input [3:0] people, input [9:0] weight,
    output reg [3:0] current_floor, output reg [3:0] target_floor,
    output busy, output alert
);
assign busy = (current_floor != target_floor);
assign alert = (people > 4'd13) || (weight > 10'd1000);
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        current_floor <= 4'd1;
        target_floor <= 4'd1;
    end else if (!alert) begin
        if (busy) begin
            if (current_floor < target_floor) current_floor <= current_floor + 1'b1;
            else current_floor <= current_floor - 1'b1;
        end else if (request && requested_floor >= 4'd1 && requested_floor <= 4'd8 &&
                     ((requested_floor != 4'd2 && requested_floor != 4'd3) || emergency)) begin
            target_floor <= requested_floor;
        end
    end
end
endmodule
