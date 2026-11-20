// =============================================================================
// t11 按键消抖：输入和当前输出不一样、并且连续 N 拍都不一样，才接受新电平
//   key_out  消抖后的电平（复位为 0：按下 = 1 的按键；按下 = 0 的按键把复位值改成 1）
//   press    key_out 0→1 的那一拍
// 仿真题里 N 一般给得很小（真实板子上 20 ms 要几十万拍）
// =============================================================================

module debounce #(
    parameter N = 20,
    parameter W = 8
)(
    input      clk,
    input      rst_n,
    input      key_in,
    output reg key_out,
    output     press
);

reg [1:0]   sync;                  // 两级同步
reg [W-1:0] cnt;                   // 和 key_out 不一样已经连续几拍
reg         key_d;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) sync <= 2'b00;
    else        sync <= {sync[0], key_in};
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        cnt     <= 0;
        key_out <= 1'b0;
    end else if (sync[1] == key_out) begin
        cnt <= 0;                  // 一样：不用变，计数清零（抖动回来也清零）
    end else if (cnt == N-1) begin
        cnt     <= 0;
        key_out <= sync[1];        // 连续 N 拍都不一样 → 接受
    end else
        cnt <= cnt + 1'b1;
end

// key_d 保存上一拍的 key_out；key_out 从 0 变 1 时 key_d 暂为 0，press 高一拍。
// 时序块在该沿采到 press，通常是在 key_out 变高后的下一个上升沿。
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) key_d <= 1'b0;
    else        key_d <= key_out;
end
assign press = key_out & ~key_d;

endmodule
