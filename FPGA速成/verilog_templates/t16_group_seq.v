// 6 个有效输入为一组、组间不重叠；第 6 位采样后的下一个上升沿输出结果。
// 下一组不必等待结果输出，可以在这个上升沿同时采下一个组的第 1 位。
module group_seq6 (
    input clk, input rst_n, input valid, input din,
    output reg match, output reg not_match
);
reg [5:0] shift;
reg [2:0] count;
reg pending, saved_match;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        shift <= 0; count <= 0; pending <= 0; saved_match <= 0;
        match <= 0; not_match <= 0;
    end else begin
        match <= pending && saved_match;
        not_match <= pending && !saved_match;
        pending <= 0;
        if (valid) begin
            shift <= {shift[4:0], din};
            if (count == 3'd5) begin
                saved_match <= ({shift[4:0], din} == 6'b011010);
                pending <= 1;
                count <= 0;
            end else count <= count + 1'b1;
        end
    end
end
endmodule
