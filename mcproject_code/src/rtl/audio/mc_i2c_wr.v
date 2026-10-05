`timescale 1ns / 1ps
// =============================================================================
// mc_i2c_wr.v  I2C 主机（只会写）：一次事务 = 起始 + 器件地址(写) + 寄存器地址 + 数据 + 停止，共 3 个字节
//   用法（和 STM32 的 HAL_I2C_Mem_Write 对应）：O_busy = 0 时给 I_start 一个脉冲，同时给好 I_dev / I_reg / I_data；
//   之后 O_busy 拉高，做完给 O_done 一个脉冲；O_nack = 1 表示这次有字节没被从机应答（O_done 那一拍有效）。
//   SCL 推挽输出；SDA 开漏（IO_sda：拉低 = 驱动 0，放开 = 高阻，靠板上上拉电阻变高）。
//   速率 I2C_HZ（默认 100 kHz；ES8388 最高支持 400 kHz）。
// =============================================================================
module mc_i2c_wr #(
    parameter CLK_HZ = 100_000_000,
    parameter I2C_HZ = 100_000
)(
    input  wire       I_clk,
    input  wire       I_rst_n,

    input  wire       I_start,
    input  wire [6:0] I_dev,                // 7 位器件地址
    input  wire [7:0] I_reg,
    input  wire [7:0] I_data,
    output reg        O_busy,
    output reg        O_done,
    output reg        O_nack,

    output wire       O_scl,
    inout  wire       IO_sda
);

localparam Q = CLK_HZ / (I2C_HZ * 4);       // 四分之一位时间的时钟数

localparam [2:0] ST_IDLE = 3'd0, ST_START = 3'd1, ST_BIT = 3'd2, ST_STOP = 3'd3;

reg [15:0] S_q;
reg [2:0]  S_st;
reg [1:0]  S_ph;                            // 位内的第几个四分之一（0 .. 3）；START/STOP 里用 0 .. 2
reg [1:0]  S_byte;                          // 第几个字节（0 .. 2）
reg [3:0]  S_bit;                           // 字节内第几位（0 .. 7 = 数据位，8 = 应答位）
reg [23:0] S_bytes;
reg        S_scl;
reg        S_sda_low;                       // 1 = 拉低 SDA
reg [1:0]  S_sda_s;                         // IO_sda 同步
reg        S_nack;

assign O_scl  = S_scl;
assign IO_sda = S_sda_low ? 1'b0 : 1'bz;

wire S_tick = (S_q == Q - 1);

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        S_q       <= 16'd0;
        S_st      <= ST_IDLE;
        S_ph      <= 2'd0;
        S_byte    <= 2'd0;
        S_bit     <= 4'd0;
        S_bytes   <= 24'd0;
        S_scl     <= 1'b1;
        S_sda_low <= 1'b0;
        S_sda_s   <= 2'b11;
        S_nack    <= 1'b0;
        O_busy    <= 1'b0;
        O_done    <= 1'b0;
        O_nack    <= 1'b0;
    end else begin
        O_done  <= 1'b0;
        S_sda_s <= {S_sda_s[0], IO_sda};

        if (S_st == ST_IDLE) begin
            S_q <= 16'd0;
            if (I_start && !O_busy) begin
                S_bytes <= {I_dev, 1'b0, I_reg, I_data};
                S_nack  <= 1'b0;
                O_busy  <= 1'b1;
                S_st    <= ST_START;
                S_ph    <= 2'd0;
            end
        end else begin
            S_q <= S_tick ? 16'd0 : (S_q + 16'd1);
            if (S_tick) begin
                case (S_st)
                    ST_START: begin                     // SDA 高 → 低（SCL 高）→ SCL 低
                        case (S_ph)
                            2'd0: begin S_sda_low <= 1'b0; S_scl <= 1'b1; S_ph <= 2'd1; end
                            2'd1: begin S_sda_low <= 1'b1;                S_ph <= 2'd2; end
                            default: begin
                                S_scl  <= 1'b0;
                                S_st   <= ST_BIT;
                                S_ph   <= 2'd0;
                                S_byte <= 2'd0;
                                S_bit  <= 4'd0;
                            end
                        endcase
                    end

                    ST_BIT: begin
                        case (S_ph)
                            2'd0: begin                 // SCL 低时放好数据（应答位放开 SDA）
                                S_scl <= 1'b0;
                                if (S_bit == 4'd8) S_sda_low <= 1'b0;
                                else               S_sda_low <= ~S_bytes[23 - S_byte * 8 - S_bit];
                                S_ph <= 2'd1;
                            end
                            2'd1: begin S_scl <= 1'b1; S_ph <= 2'd2; end
                            2'd2: begin                 // SCL 高的中间采样
                                if (S_bit == 4'd8 && S_sda_s[1]) S_nack <= 1'b1;
                                S_ph <= 2'd3;
                            end
                            default: begin
                                S_scl <= 1'b0;
                                S_ph  <= 2'd0;
                                if (S_bit == 4'd8) begin
                                    S_bit <= 4'd0;
                                    if (S_byte == 2'd2) begin
                                        S_st <= ST_STOP;
                                        S_ph <= 2'd0;
                                    end else begin
                                        S_byte <= S_byte + 2'd1;
                                    end
                                end else begin
                                    S_bit <= S_bit + 4'd1;
                                end
                            end
                        endcase
                    end

                    ST_STOP: begin                      // SDA 低 → SCL 高 → SDA 高
                        case (S_ph)
                            2'd0: begin S_sda_low <= 1'b1; S_scl <= 1'b0; S_ph <= 2'd1; end
                            2'd1: begin S_scl <= 1'b1;                    S_ph <= 2'd2; end
                            default: begin
                                S_sda_low <= 1'b0;
                                S_st      <= ST_IDLE;
                                O_busy    <= 1'b0;
                                O_done    <= 1'b1;
                                O_nack    <= S_nack;
                            end
                        endcase
                    end

                    default: S_st <= ST_IDLE;
                endcase
            end
        end
    end
end

endmodule
