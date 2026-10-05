`timescale 1ns / 1ps
// =============================================================================
// mc_i2s_tx.v  I2S 发送（给 ES8388 的 DAC 送数字音频）：同时产生 MCLK / SCLK / LRCK 三路时钟
//
//   ES8388 工作在"从模式"：MCLK、SCLK、LRCK 都由 FPGA 给，而且三者必须同源同步。这里全部由 100 MHz 系统时钟分出来：
//       MCLK = 100 MHz ÷ 8 = 12.5 MHz（占空比 50 %）
//       LRCK = MCLK ÷ 比值，比值 256 / 384 / 512 / 768 / 1024（I_rate_sel = 0 ~ 4）→ 采样率 48.83k / 32.55k / 24.41k / 16.28k / 12.21k
//       SCLK = LRCK × 64（一个声道占 32 个位时钟，高 16 位是数据，低 16 位补 0）
//     ES8388 在从模式下自动识别 MCLK/LRCK 的比值，只要是 256/384/512/768/1024 就行（数据手册 Table 1）。
//     12.5 MHz 不是标准的 12.288 MHz，所以实际采样率比 WAV 文件标称的高 1.7 %，听不出来（厂商例程也是这样）。
//   数据格式：I2S（LRCK 低 = 左声道；LRCK 变化后一个 SCLK 才出现数据最高位；SCLK 下降沿换数据，上升沿被采样），16 位。
//
//   取数：每个 LRCK 帧开始时（SCLK 下降沿，帧内第 0 位）看一眼 I_valid：
//        I_valid = 1：取走 I_l / I_r 作为这一帧的左 / 右声道，同时给 O_ack 一个单周期脉冲（外面据此准备下一个采样）；
//        I_valid = 0：这一帧送静音（全 0），给 O_underrun 一个单周期脉冲（计数用）。
//     一帧至少 2048 个时钟，外面有充足的时间在两帧之间准备好下一个采样。
//   I_rate_sel 在两个曲目之间的空闲时才改（改的瞬间可能有一帧时钟不规整，那时本来就是静音）。
// =============================================================================
module mc_i2s_tx (
    input  wire        I_clk,               // 100 MHz
    input  wire        I_rst_n,

    input  wire [2:0]  I_rate_sel,          // 0: 比值256  1: 384  2: 512  3: 768  4: 1024
    input  wire        I_valid,             // I_l / I_r 里是下一帧要发的采样
    input  wire [15:0] I_l,
    input  wire [15:0] I_r,
    output reg         O_ack,               // 单周期脉冲：这一帧取走了 I_l / I_r
    output reg         O_underrun,          // 单周期脉冲：这一帧没有采样可发，发了静音

    output wire        O_mclk,              // → ES8388 MCLK（F14）
    output reg         O_sclk,              // → ES8388 SCLK（K13）
    output reg         O_lrck,              // → ES8388 LRCK（C13）
    output reg         O_dsdin              // → ES8388 DSDIN（J13）
);

// ---- MCLK：每 4 个时钟翻转一次 → 12.5 MHz ----
reg [1:0] S_m_cnt;
reg       S_mclk;
assign O_mclk = S_mclk;

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        S_m_cnt <= 2'd0;
        S_mclk  <= 1'b0;
    end else begin
        S_m_cnt <= S_m_cnt + 2'd1;
        if (S_m_cnt == 2'd3) S_mclk <= ~S_mclk;
    end
end

// ---- SCLK 半周期（100 MHz 时钟数）= 比值 / 16 ----
reg [6:0] S_half;
always @* begin
    case (I_rate_sel)
        3'd0:    S_half = 7'd16;
        3'd1:    S_half = 7'd24;
        3'd2:    S_half = 7'd32;
        3'd3:    S_half = 7'd48;
        3'd4:    S_half = 7'd64;
        default: S_half = 7'd16;
    endcase
end

reg [6:0]  S_s_cnt;
reg [5:0]  S_n;                          // 帧内第几个 SCLK 下降沿（0 .. 63）
reg [63:0] S_sh;

wire S_fall = (O_sclk == 1'b1) && (S_s_cnt >= S_half - 7'd1);        // 这一拍之后 SCLK 变低

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        S_s_cnt    <= 7'd0;
        O_sclk     <= 1'b0;
        S_n        <= 6'd63;
        O_lrck     <= 1'b1;
        O_dsdin    <= 1'b0;
        S_sh       <= 64'd0;
        O_ack      <= 1'b0;
        O_underrun <= 1'b0;
    end else begin
        O_ack      <= 1'b0;
        O_underrun <= 1'b0;

        if (S_s_cnt >= S_half - 7'd1) begin
            S_s_cnt <= 7'd0;
            O_sclk  <= ~O_sclk;
        end else begin
            S_s_cnt <= S_s_cnt + 7'd1;
        end

        if (S_fall) begin                // 下降沿：换 LRCK / 数据
            S_n <= S_n + 6'd1;           // 63 → 0 自然回绕
            if (S_n == 6'd63) begin      // 新的一帧开始：LRCK 变低（左声道），装载采样
                O_lrck  <= 1'b0;
                O_dsdin <= 1'b0;         // 上一个声道最后一位（补零）
                if (I_valid) begin
                    S_sh  <= {I_l, 16'd0, I_r, 16'd0};
                    O_ack <= 1'b1;
                end else begin
                    S_sh       <= 64'd0;
                    O_underrun <= 1'b1;
                end
            end else begin
                if (S_n == 6'd31) O_lrck <= 1'b1;       // 右声道开始
                O_dsdin <= S_sh[63];                    // 最高位先出
                S_sh    <= {S_sh[62:0], 1'b0};
            end
        end
    end
end

endmodule
