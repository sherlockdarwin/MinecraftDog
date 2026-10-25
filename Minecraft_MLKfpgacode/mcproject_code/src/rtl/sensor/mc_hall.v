`timescale 1ns / 1ps
// =============================================================================
// mc_hall.v  霍尔传感器输入：两级同步 + 去抖 → O_fed（1 = 磁铁靠近，即"正在喂食"）
//
//   模块输出高电平 = 磁铁靠近、低电平 = 磁铁离开。
//   去抖：输入连续 DEBOUNCE_MS 毫秒都和当前 O_fed 不一样，才翻转 O_fed（磁铁刚靠近时输出可能抖几下）。
//   复位后 O_fed = 0（当作"没有磁铁"）；上电时磁铁就在旁边的话，DEBOUNCE_MS 之后变成 1。
//   管脚没接东西时：mc_pin.adc 里给了下拉，读到 0，不会误触发。
// =============================================================================
module mc_hall #(
    parameter DEBOUNCE_MS = 20              // 去抖时间（毫秒，1 ~ 255）
)(
    input  wire I_clk,
    input  wire I_rst_n,
    input  wire I_tick_1ms,
    input  wire I_hall,                     // 来自管脚（异步）
    output reg  O_fed                       // 去抖后的"磁铁靠近"（高有效）
);

reg [1:0] S_sync;
reg [7:0] S_cnt;
wire      S_in = S_sync[1];                 // 同步后的"磁铁靠近"

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        S_sync <= 2'b00;                     // 复位时按"没有磁铁"处理
        S_cnt  <= 8'd0;
        O_fed  <= 1'b0;
    end else begin
        S_sync <= {S_sync[0], I_hall};
        if (S_in == O_fed) begin
            S_cnt <= 8'd0;
        end else if (I_tick_1ms) begin
            if (S_cnt >= DEBOUNCE_MS - 1) begin
                O_fed <= S_in;
                S_cnt <= 8'd0;
            end else begin
                S_cnt <= S_cnt + 8'd1;
            end
        end
    end
end

endmodule
