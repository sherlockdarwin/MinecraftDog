// =============================================================================
// t03 状态机 + 每个状态停 N 拍（交通灯、密码锁、计费都是这个结构）
//   fsm_timer       三段式：状态寄存器 / 下一状态（组合）/ 输出（组合）
//   fsm_timer_1seg  一段式：同样的功能全写在一个 always 里（初学更好写，二选一）
// 两个模块行为完全一样（tb 里逐拍比过）
//
// 写状态机的步骤：
//   1. 列状态：localparam S_xxx = 编号;（编号随便，只要不重复、位宽装得下）
//   2. 每个状态写清：停多久？什么条件去哪个状态？输出是什么？
//   3. 按下面的模板填：计时器 cnt 在换状态时清零，状态里用 cnt == T-1 判断"停够了"
// 例子：红 10 拍 → 绿 10 拍 → 黄 3 拍 → 红 ...；绿灯时 skip=1 下一拍直接变黄
// =============================================================================

module fsm_timer (
    input            clk,
    input            rst_n,
    input            skip,         // 例：绿灯时提前结束（"中断"）
    output reg [1:0] light,        // 0 绿 1 黄 2 红
    output           ped_go        // 例：红灯时行人可走
);

localparam S_GREEN = 2'd0, S_YELLOW = 2'd1, S_RED = 2'd2;
localparam T_GREEN = 8'd10, T_YELLOW = 8'd3, T_RED = 8'd10;   // 每个状态停几拍

reg [1:0] state, next_state;
reg [7:0] cnt;                     // 进入当前状态后的第几拍，从 0 开始

// 第 1 段：状态寄存器
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) state <= S_RED;    // 复位后的状态
    else        state <= next_state;
end

// 状态计时：下一拍要换状态 → 清零，否则 +1
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)                   cnt <= 8'd0;
    else if (next_state != state) cnt <= 8'd0;
    else                          cnt <= cnt + 8'd1;
end

// 第 2 段：下一状态（组合逻辑，用 =，开头先给默认值"保持"）
always @(*) begin
    next_state = state;
    case (state)
        S_GREEN:  if (cnt == T_GREEN - 1 || skip) next_state = S_YELLOW;
        S_YELLOW: if (cnt == T_YELLOW - 1)        next_state = S_RED;
        S_RED:    if (cnt == T_RED - 1)           next_state = S_GREEN;
        default:                                  next_state = S_RED;
    endcase
end

// 第 3 段：输出（只看当前状态 = Moore 型）
always @(*) begin
    case (state)
        S_GREEN:  light = 2'd0;
        S_YELLOW: light = 2'd1;
        default:  light = 2'd2;
    endcase
end
assign ped_go = (state == S_RED);

endmodule


module fsm_timer_1seg (
    input            clk,
    input            rst_n,
    input            skip,
    output reg [1:0] light,
    output           ped_go
);

localparam S_GREEN = 2'd0, S_YELLOW = 2'd1, S_RED = 2'd2;
localparam T_GREEN = 8'd10, T_YELLOW = 8'd3, T_RED = 8'd10;

reg [1:0] state;
reg [7:0] cnt;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= S_RED;
        cnt   <= 8'd0;
    end else begin
        cnt <= cnt + 8'd1;         // 默认 +1；下面换状态时再写 cnt <= 0（同一个 always 里后写的生效）
        case (state)
            S_GREEN:  if (cnt == T_GREEN - 1 || skip) begin state <= S_YELLOW; cnt <= 8'd0; end
            S_YELLOW: if (cnt == T_YELLOW - 1)        begin state <= S_RED;    cnt <= 8'd0; end
            S_RED:    if (cnt == T_RED - 1)           begin state <= S_GREEN;  cnt <= 8'd0; end
            default:                                  begin state <= S_RED;    cnt <= 8'd0; end
        endcase
    end
end

always @(*) begin
    case (state)
        S_GREEN:  light = 2'd0;
        S_YELLOW: light = 2'd1;
        default:  light = 2'd2;
    endcase
end
assign ped_go = (state == S_RED);

endmodule
