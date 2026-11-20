// 带冷却中断的自动交通灯（国赛测试2 题二）
// 复位后主干道红（行人绿）10 拍 → 绿 10 拍 → 黄 3 拍 → 红 ...
// 主干道绿灯时按钮有效、且不在冷却期 → 下一个上升沿直接变黄，同时开始 18 拍冷却
// 冷却从"中断被触发"开始算（题目背景："中断触发后具有冷却保护期"）；红、黄灯时按按钮没有任何作用
// 状态编号正好等于 main_light 的编码：0 绿 1 黄 2 红
module traffic_button_ctrl(
    input            clk,
    input            rst_n,
    input            ped_btn,
    output reg [1:0] main_light, // 0:Green, 1:Yellow, 2:Red
    output reg [1:0] ped_light   // 0:Red, 1:Green
);

localparam S_GREEN = 2'd0, S_YELLOW = 2'd1, S_RED = 2'd2;
localparam T_GREEN = 5'd10, T_YELLOW = 5'd3, T_RED = 5'd10, T_COOL = 5'd18;

reg [1:0] state, next_state;
reg [4:0] cnt;                     // 进入当前状态后的第几拍
reg [4:0] cool;                    // 冷却剩余拍数，0 = 不在冷却

wire btn_ok = ped_btn && (state == S_GREEN) && (cool == 5'd0);   // 中断被接受

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) state <= S_RED;
    else        state <= next_state;
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)                   cnt <= 5'd0;
    else if (next_state != state) cnt <= 5'd0;
    else                          cnt <= cnt + 5'd1;
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)            cool <= 5'd0;
    else if (btn_ok)       cool <= T_COOL;
    else if (cool != 5'd0) cool <= cool - 5'd1;
end

always @(*) begin
    next_state = state;
    case (state)
        S_GREEN:  if (btn_ok || cnt == T_GREEN - 1) next_state = S_YELLOW;
        S_YELLOW: if (cnt == T_YELLOW - 1)          next_state = S_RED;
        S_RED:    if (cnt == T_RED - 1)             next_state = S_GREEN;
        default:                                    next_state = S_RED;
    endcase
end

always @(*) begin
    main_light = state;
    ped_light  = (state == S_RED) ? 2'd1 : 2'd0;
end

endmodule
