// =============================================================================
// t08 定时：保持 N 拍 / 冷却
//   hold_n    start 来一拍 → busy 连续为 1 共 N 拍（开锁 10 拍、报警 50 拍这类）
//   cooldown  请求被接受后的 N 拍内，再来的请求一律忽略（防连按）
// 两个都是"剩余拍数"倒计数：装入 N，每拍减 1，减到 0 就结束
// =============================================================================

module hold_n #(
    parameter N = 10,
    parameter W = 8
)(
    input  clk,
    input  rst_n,
    input  start,                  // 1 拍脉冲
    output busy,                   // start 之后的下一拍起，连续 N 拍为 1
    output done                    // busy 的最后一拍为 1
);

reg [W-1:0] left;                  // 还剩几拍
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)                    left <= 0;
    else if (start && left == 0)   left <= N;   // 忙的时候再来 start 忽略；要"重新计时"就去掉 && left == 0
    else if (left != 0)            left <= left - 1'b1;
end

assign busy = (left != 0);
assign done = (left == 1);

endmodule


module cooldown #(
    parameter N = 18,
    parameter W = 8
)(
    input  clk,
    input  rst_n,
    input  req,                    // 请求（比如按钮）
    input  cond,                   // 其他允许条件（比如"只有绿灯时有效"），不需要就接 1'b1
    output accept                  // 这一拍的请求被接受（和 req 同一拍）
);

reg [W-1:0] cd;                    // 冷却剩余拍数，0 = 不在冷却
assign accept = req && cond && (cd == 0);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)        cd <= 0;
    else if (accept)   cd <= N;     // 接受后的 N 拍里 cd != 0 → 忽略请求
    else if (cd != 0)  cd <= cd - 1'b1;
end

endmodule
