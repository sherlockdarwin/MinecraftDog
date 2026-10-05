`timescale 1ns / 1ps
// =============================================================================
// mc_uart_tx.v  串口发送（8N1，LSB 先发）
//
// 用法（相当于 C 里的"发一个字节"）：
//     等 O_ready == 1，然后在某个时钟沿让 I_valid = 1 并给出 I_data；
//     I_valid 与 O_ready 同时为 1 的那个时钟沿，字节被接收，之后 O_ready 拉低直到这个字节发完。
// 波特率 = CLK_HZ / BAUD（取整）。100 MHz / 115200 = 868，误差 0.006%，远小于 UART 允许的 ±2%。
// =============================================================================
module mc_uart_tx #(
    parameter CLK_HZ = 100_000_000,
    parameter BAUD   = 115200
)(
    input  wire       I_clk,
    input  wire       I_rst_n,
    input  wire [7:0] I_data,
    input  wire       I_valid,
    output wire       O_ready,          // 1 = 空闲，可以接收新字节
    output reg        O_tx              // 空闲为高
);

localparam DIV = CLK_HZ / BAUD;         // 每位多少个时钟

reg        S_busy;
reg [15:0] S_cnt;                       // 位内计数
reg [3:0]  S_bit;                       // 当前位序号：0 起始位，1~8 数据位，9 停止位
reg [9:0]  S_shift;                     // {停止位, 数据[7:0], 起始位}

assign O_ready = ~S_busy;

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        S_busy  <= 1'b0;
        S_cnt   <= 16'd0;
        S_bit   <= 4'd0;
        S_shift <= 10'h3FF;
        O_tx    <= 1'b1;
    end else if (!S_busy) begin
        if (I_valid) begin
            S_shift <= {1'b1, I_data, 1'b0};
            S_bit   <= 4'd0;
            S_cnt   <= 16'd0;
            S_busy  <= 1'b1;
            O_tx    <= 1'b0;                        // 起始位
        end
    end else begin
        if (S_cnt == DIV - 1) begin
            S_cnt <= 16'd0;
            if (S_bit == 4'd9) begin                // 停止位发完
                S_busy <= 1'b0;
                O_tx   <= 1'b1;
            end else begin
                S_bit <= S_bit + 4'd1;
                O_tx  <= S_shift[S_bit + 4'd1];
            end
        end else begin
            S_cnt <= S_cnt + 16'd1;
        end
    end
end

endmodule
