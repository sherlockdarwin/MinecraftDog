// =============================================================================
// t10 PWM：周期 period 拍，其中高电平 duty 拍
//   duty = 0 → 一直低；duty >= period → 一直高；period 至少为 1
//   pwm_out 是寄存器输出，比 cnt 晚一拍（每个周期里高、低的拍数不受影响）
// =============================================================================

module pwm #(
    parameter W = 8
)(
    input          clk,
    input          rst_n,
    input  [W-1:0] period,
    input  [W-1:0] duty,
    output reg     pwm_out
);

reg [W-1:0] cnt;                   // 0 ~ period-1

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)                 cnt <= 0;
    else if (cnt >= period - 1) cnt <= 0;
    else                        cnt <= cnt + 1'b1;
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) pwm_out <= 1'b0;
    else        pwm_out <= (cnt < duty);
end

endmodule
