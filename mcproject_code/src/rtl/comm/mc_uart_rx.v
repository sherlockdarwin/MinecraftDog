`timescale 1ns / 1ps
// =============================================================================
// mc_uart_rx.v  串口接收（8N1，LSB 先收）
//
// 用法（相当于 C 里的"串口接收中断"）：收到一个完整字节（停止位是 1）时 O_valid 打一拍，O_data 是这个字节。
//   起始位：两级同步后的下降沿 → 等半个位 → 还是低才算（毛刺不算）→ 之后每隔一个位宽在位中间取样 8 个数据位和停止位；
//   停止位是 0（帧错误）就丢掉这个字节。波特率 = CLK_HZ / BAUD（取整），和 mc_uart_tx 一样。
// =============================================================================
module mc_uart_rx #(
    parameter CLK_HZ = 100_000_000,
    parameter BAUD   = 115200
)(
    input  wire       I_clk,
    input  wire       I_rst_n,
    input  wire       I_rx,             // 外部引脚（异步，空闲为高）
    output reg        O_valid,
    output reg  [7:0] O_data
);

localparam DIV  = CLK_HZ / BAUD;        // 每位多少个时钟
localparam HALF = DIV / 2;

reg [2:0]  S_sync;                      // 两级同步 + 上一拍（找下降沿）
wire       S_rx = S_sync[1];

reg        S_busy;
reg [15:0] S_cnt;                       // 到下一个取样点还差几个时钟
reg [3:0]  S_bit;                       // 0 起始位，1~8 数据位，9 停止位
reg [7:0]  S_shift;

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        S_sync  <= 3'b111;
        S_busy  <= 1'b0;
        S_cnt   <= 16'd0;
        S_bit   <= 4'd0;
        S_shift <= 8'd0;
        O_valid <= 1'b0;
        O_data  <= 8'd0;
    end else begin
        S_sync  <= {S_sync[1:0], I_rx};
        O_valid <= 1'b0;
        if (!S_busy) begin
            if (S_sync[2] && !S_rx) begin                       // 下降沿：可能是起始位
                S_busy <= 1'b1; S_cnt <= HALF - 1; S_bit <= 4'd0;
            end
        end else if (S_cnt != 16'd0) begin
            S_cnt <= S_cnt - 16'd1;
        end else begin                                          // 到了位中间：取样
            S_cnt <= DIV - 1;
            if (S_bit == 4'd0) begin
                if (S_rx) S_busy <= 1'b0;                       // 起始位中间是高：毛刺
                else      S_bit  <= 4'd1;
            end else if (S_bit <= 4'd8) begin
                S_shift <= {S_rx, S_shift[7:1]};
                S_bit   <= S_bit + 4'd1;
            end else begin                                      // 停止位
                S_busy <= 1'b0;
                if (S_rx) begin O_valid <= 1'b1; O_data <= S_shift; end
            end
        end
    end
end

endmodule
