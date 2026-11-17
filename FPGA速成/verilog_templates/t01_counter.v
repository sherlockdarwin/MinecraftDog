// =============================================================================
// t01 计数器
//   cnt_mod     模 N 计数：0,1,...,N-1,0,...；en=1 才走；co = 走到 N-1 的那一拍（给下一级当 en）
//   cnt_updown  加 / 减 / 置数
// 规律：从 0 数 N 拍，最后一拍是 cnt == N-1（不是 == N）
// =============================================================================

module cnt_mod #(
    parameter N = 10,              // 模几
    parameter W = 4                // 位宽，要满足 2^W >= N
)(
    input              clk,
    input              rst_n,
    input              en,
    output reg [W-1:0] cnt,
    output             co          // 进位：en 有效且 cnt == N-1（和 cnt 同一拍）
);

assign co = en && (cnt == N-1);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)   cnt <= 0;
    else if (co)  cnt <= 0;        // 到 N-1 再走一格 → 回 0
    else if (en)  cnt <= cnt + 1'b1;
end

endmodule


module cnt_updown #(
    parameter W = 8
)(
    input              clk,
    input              rst_n,
    input              load,       // 置数，优先级最高
    input      [W-1:0] din,
    input              up,         // 加 1
    input              down,       // 减 1；up、down 同时来 → 不变
    output reg [W-1:0] cnt         // 0 再减 → 全 1（回绕）；要停在 0 用 t09
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)              cnt <= 0;
    else if (load)           cnt <= din;
    else if (up && !down)    cnt <= cnt + 1'b1;
    else if (down && !up)    cnt <= cnt - 1'b1;
end

endmodule
