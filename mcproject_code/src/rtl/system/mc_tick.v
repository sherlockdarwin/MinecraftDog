`timescale 1ns / 1ps
// =============================================================================
// mc_tick.v  系统节拍发生器（FPGA 版的 1ms 定时器 + 调度器）
// 输出单周期脉冲。各模块在同一时钟下用 tick 当使能，就能按固定周期执行"任务"：
//     always @(posedge S_clk_100m) if (S_tick_10ms) begin ... end   // 每 10 ms 一次
// 与 C 调度器不同：所有任务是并行硬件，互不阻塞，加任务只需多接一根 tick。
// =============================================================================
module mc_tick #(
    parameter CLK_HZ = 100_000_000      // I_clk 频率，须为 1 MHz 的整数倍
)(
    input  wire        I_clk,
    input  wire        I_rst_n,
    output reg         O_tick_1us,
    output reg         O_tick_1ms,
    output reg         O_tick_10ms,
    output reg         O_tick_100ms,
    output reg  [31:0] O_time_ms        // 上电毫秒计数（≈ g_time_ms），约 49.7 天回绕
);

localparam US_DIV = CLK_HZ / 1_000_000;

reg [15:0] S_cnt_us;                    // 0 .. US_DIV-1
reg [9:0]  S_cnt_ms;                    // 0 .. 999  (1us 个数)
reg [3:0]  S_cnt_10ms;                  // 0 .. 9    (1ms 个数)
reg [3:0]  S_cnt_100ms;                 // 0 .. 9    (10ms 个数)

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        S_cnt_us     <= 16'd0;
        S_cnt_ms     <= 10'd0;
        S_cnt_10ms   <= 4'd0;
        S_cnt_100ms  <= 4'd0;
        O_tick_1us   <= 1'b0;
        O_tick_1ms   <= 1'b0;
        O_tick_10ms  <= 1'b0;
        O_tick_100ms <= 1'b0;
        O_time_ms    <= 32'd0;
    end else begin
        O_tick_1us   <= 1'b0;
        O_tick_1ms   <= 1'b0;
        O_tick_10ms  <= 1'b0;
        O_tick_100ms <= 1'b0;

        if (S_cnt_us == US_DIV - 1) begin
            S_cnt_us   <= 16'd0;
            O_tick_1us <= 1'b1;

            if (S_cnt_ms == 10'd999) begin
                S_cnt_ms   <= 10'd0;
                O_tick_1ms <= 1'b1;
                O_time_ms  <= O_time_ms + 32'd1;

                if (S_cnt_10ms == 4'd9) begin
                    S_cnt_10ms  <= 4'd0;
                    O_tick_10ms <= 1'b1;

                    if (S_cnt_100ms == 4'd9) begin
                        S_cnt_100ms  <= 4'd0;
                        O_tick_100ms <= 1'b1;
                    end else begin
                        S_cnt_100ms <= S_cnt_100ms + 4'd1;
                    end
                end else begin
                    S_cnt_10ms <= S_cnt_10ms + 4'd1;
                end
            end else begin
                S_cnt_ms <= S_cnt_ms + 10'd1;
            end
        end else begin
            S_cnt_us <= S_cnt_us + 16'd1;
        end
    end
end

endmodule
