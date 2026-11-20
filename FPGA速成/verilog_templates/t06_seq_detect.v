// =============================================================================
// t06 序列检测（例：串行输入里找 1011，允许重叠：1011011 算两次）
//   seq_det_shift  移位寄存器存最近 4 位，直接比较（最简单，换序列只改 PAT）
//   seq_det_fsm    状态机写法（题目要求画 / 写状态机时用）
// 两个都是 Moore 型：收到最后一位的那个上升沿之后，found 为 1 一拍
// Mealy 型（同一拍就出结果）：found = (state == S3) && din;
// =============================================================================

// din 是串行的一位输入，每个上升沿采一位；PAT 是例化时可修改的四位目标序列。
module seq_det_shift #(
    parameter [3:0] PAT = 4'b1011  // 先收到的位在左边（最高位）
)(
    input  clk,
    input  rst_n,
    input  din,
    output found
);

reg [3:0] sh;                      // 最近 4 位，sh[0] 是最新的
reg [2:0] n;                       // 已收到几位，到 4 就不再加（防止复位后的 0 被当成序列的一部分）

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        sh <= 4'b0000;
        n  <= 3'd0;
    end else begin
        sh <= {sh[2:0], din};
        if (n != 3'd4) n <= n + 3'd1;
    end
end

assign found = (n == 3'd4) && (sh == PAT);

endmodule


module seq_det_fsm (
    input  clk,
    input  rst_n,
    input  din,
    output found
);

// 状态名 = 已经匹配上的前缀
localparam S0 = 3'd0,              // 什么都没匹配
           S1 = 3'd1,              // "1"
           S2 = 3'd2,              // "10"
           S3 = 3'd3,              // "101"
           S4 = 3'd4;              // "1011" 找到

reg [2:0] state, next_state;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) state <= S0;
    else        state <= next_state;
end

// ? 前为条件：din=1 选冒号左边，din=0 选右边；组合逻辑先算 next_state，上升沿才存入 state。
// 按顺序输入 1011：S0→S1→S2→S3→S4；输入 1010 时末尾 10 可复用，所以 S3→S2。
// 不匹配时不一定回 S0：看已收到的位的结尾还能当哪个前缀用
always @(*) begin
    case (state)
        S0: next_state = din ? S1 : S0;
        S1: next_state = din ? S1 : S2;   // "11"   → 结尾 "1"
        S2: next_state = din ? S3 : S0;   // "100"  → 什么都不剩
        S3: next_state = din ? S4 : S2;   // "1010" → 结尾 "10"
        S4: next_state = din ? S1 : S2;   // "10111"→ "1"；"10110" → "10"
        default: next_state = S0;
    endcase
end

assign found = (state == S4);

endmodule
