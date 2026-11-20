// 有符号分组累加：每 4 个有效输入求和；valid=0 不计数，组与组之间可以连续输入。
// 输入是 4 位二补码 -8~7，4 个数的和为 -32~28，6 位有符号数足够。
module signed_sum4 (
    input clk, input rst_n,
    input valid, input signed [3:0] din,
    output reg signed [5:0] result,
    output reg ready
);
reg signed [5:0] acc;
reg [1:0] count;
// 负数扩位要复制符号位，不能像无符号数那样一律补 0。
wire signed [5:0] extended = {{2{din[3]}}, din};

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        acc <= 0; count <= 0; result <= 0; ready <= 0;
    end else begin
        ready <= 0;
        if (valid) begin
            if (count == 2'd3) begin
                result <= acc + extended; // 前 3 个数 + 当前第 4 个数
                acc <= 0;
                count <= 0;
                ready <= 1;
            end else begin
                acc <= acc + extended;
                count <= count + 1'b1;
            end
        end
    end
end
endmodule
