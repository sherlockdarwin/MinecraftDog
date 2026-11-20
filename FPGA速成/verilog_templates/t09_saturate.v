// =============================================================================
// t09 余额类：同一拍又加又减，结果不低于 0、不超过最大值（游戏机计费、充值扣费）
// 要点：同一个寄存器一拍只赋值一次。先用 wire 把"加完再减"算好，最后只写一句 acc <= ...
//       （写成 if (add) acc <= acc + x;  if (sub) acc <= acc - y; 两句都执行时只有后一句生效，加的钱丢了）
// 比较 / 相减前多开 1 位，避免溢出后数值变小
// =============================================================================

module acc_sat #(
    parameter W = 10
)(
    input              clk,
    input              rst_n,
    input              add_en,
    input      [W-1:0] add_val,
    input              sub_en,
    input      [W-1:0] sub_val,
    output reg [W-1:0] acc
);

// 条件 ? A : B：使能时取前面补 0 的加数，否则取 W+1 位全 0；补位用来保留进位。
// {W{1'b1}} 是 W 个 1，正好填满 [W-1:0]；[W:0] 则有 W+1 位。
wire [W:0] sum  = {1'b0, acc} + (add_en ? {1'b0, add_val} : {(W+1){1'b0}});
wire [W:0] cost = sub_en ? {1'b0, sub_val} : {(W+1){1'b0}};
wire [W:0] diff = (sum >= cost) ? (sum - cost) : {(W+1){1'b0}};   // 不够扣 → 0

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)       acc <= 0;
    else if (diff[W]) acc <= {W{1'b1}};          // 超过 W 位能表示的最大值 → 停在最大
    else              acc <= diff[W-1:0];
end

endmodule
