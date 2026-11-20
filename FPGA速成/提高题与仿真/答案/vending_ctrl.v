// 参考答案：金额用无符号二进制；验收以题面定义的优先级和边界为准。
module vending_ctrl(
    input clk, input rst_n,
    input coin_valid, input [3:0] coin_value,
    input buy, input cancel,
    output reg [4:0] credit,
    output reg dispensing,
    output reg insufficient,
    output reg [4:0] refund
);
reg [2:0] left;
wire [5:0] added = {1'b0,credit} + (coin_valid ? {2'b00,coin_value} : 6'd0);
wire [5:0] limited = (added > 6'd20) ? 6'd20 : added;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        credit <= 0; dispensing <= 0; insufficient <= 0; refund <= 0; left <= 0;
    end else begin
        insufficient <= 0;
        refund <= 0;
        if (dispensing) begin
            if (left == 3'd1) begin
                left <= 0;
                dispensing <= 0;
            end else left <= left - 1'b1;
        end else if (cancel) begin
            refund <= credit;
            credit <= 0;
        end else if (buy) begin
            if (limited >= 6'd8) begin
                credit <= limited - 6'd8;
                dispensing <= 1;
                left <= 3'd4;
            end else begin
                credit <= limited;
                insufficient <= 1;
            end
        end else if (coin_valid) begin
            credit <= limited;
        end
    end
end
endmodule
