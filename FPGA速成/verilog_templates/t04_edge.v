// =============================================================================
// t04 边沿检测 / 同步
//   edge_detect  输入已经和 clk 同步（tb 里在时钟沿附近改的信号）时用：rise/fall 和 sig 同一拍
//   sync_edge    外部异步信号（按键、别的时钟域）先打两拍再检测：rise/fall 比 sig 晚 2 拍
// 用途：输入是"按住好几拍的电平"，但只想响应一次 → 用 rise
//       题目说输入本身就是 1 拍的脉冲（key_valid、confirm 这类）→ 直接用，不需要这个
// =============================================================================

module edge_detect (
    input  clk,
    input  rst_n,
    input  sig,
    output rise,                   // sig 0→1 的那一拍
    output fall                    // sig 1→0 的那一拍
);

reg sig_d;                         // sig 上一拍的值
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) sig_d <= 1'b0;
    else        sig_d <= sig;
end

assign rise =  sig & ~sig_d;
assign fall = ~sig &  sig_d;

endmodule


module sync_edge (
    input  clk,
    input  rst_n,
    input  sig,
    output rise,
    output fall
);

reg [2:0] d;                       // d[0]、d[1] 两级同步，d[2] 再存一拍用来比较
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) d <= 3'b000;
    else        d <= {d[1:0], sig};
end

assign rise =  d[1] & ~d[2];
assign fall = ~d[1] &  d[2];

endmodule
