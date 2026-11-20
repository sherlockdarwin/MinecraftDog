// =============================================================================
// t05 分频
//   div_even  偶数分频（N = 2、4、6 ...），占空比 50%
//   div_odd   奇数分频（N = 3、5、7 ...），占空比 50%（上升沿、下降沿各做一个波形再相或）
//   tick_gen  每 N 拍出一个 1 拍宽的脉冲（"使能节拍"）
// 题目要"输出一个分频后的时钟"→ 用前两个；只是"每隔 N 拍做一次事"→ 用 tick_gen 当 en，
// 不要拿分频出来的信号再去当别的 always 的时钟。
// =============================================================================

module div_even #(
    parameter N = 4,               // 偶数
    parameter W = 4
)(
    input      clk,
    input      rst_n,
    output reg clk_out
);

// W 是计数器位宽，要能表示计数终值；一拍按相邻两个上升沿算，是一个输入周期。
reg [W-1:0] cnt;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        cnt     <= 0;
        clk_out <= 1'b0;
    end else if (cnt == N/2 - 1) begin   // 每 N/2 拍翻转一次
        cnt     <= 0;
        clk_out <= ~clk_out;
    end else
        cnt <= cnt + 1'b1;
end

endmodule


module div_odd #(
    parameter N = 3,               // 奇数
    parameter W = 4
)(
    input  clk,
    input  rst_n,
    output clk_out
);

reg [W-1:0] cnt;
reg p, n;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)          cnt <= 0;
    else if (cnt == N-1) cnt <= 0;
    else                 cnt <= cnt + 1'b1;
end

// 例如 N=3：p 稳态高 1 个输入周期、低 2 个；n 延迟半周期后相或，高低各 1.5 周期。
// 上升沿做一个高 (N-1)/2 拍、低 (N+1)/2 拍的波形
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)                              p <= 1'b0;
    else if (cnt == (N-1)/2 || cnt == N-1)   p <= ~p;
end

// 下降沿把它晚半拍复制一份
always @(negedge clk or negedge rst_n) begin
    if (!rst_n) n <= 1'b0;
    else        n <= p;
end

assign clk_out = p | n;            // 高电平变成 N/2 拍

endmodule


module tick_gen #(
    parameter N = 5,
    parameter W = 4
)(
    input  clk,
    input  rst_n,
    output tick                    // 每 N 拍为 1 一拍
);

reg [W-1:0] cnt;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)          cnt <= 0;
    else if (cnt == N-1) cnt <= 0;
    else                 cnt <= cnt + 1'b1;
end
assign tick = (cnt == N-1);

endmodule
