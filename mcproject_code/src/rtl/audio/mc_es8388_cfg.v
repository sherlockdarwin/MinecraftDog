`timescale 1ns / 1ps
// =============================================================================
// mc_es8388_cfg.v  上电后把 ES8388 配置成"I2S 从模式、16 位、DAC 播放（耳机 + 喇叭输出）"
//
//   顺序和数值参考厂商例程 09_aud8388_loop 的 ES8388_Config.v（在这块板上验证过的），改动只有：不用 ADC（电源关掉）、
//   DAC 数字音量 0 dB、混频器只放 DAC（不混模拟输入）、音量做成参数。寄存器含义见 ES8388 数据手册 Revision 12.0 第 6 章。
//   器件地址 0x11（CE 引脚被板上上拉到高电平，写地址字节 0x22）。MCLK/SCLK/LRCK 由 mc_i2s_tx 一直在给，配置开始前已经稳定。
//
//   O_done = 1：全部寄存器写完且都被应答；O_err = 1：有一次没被应答（线没接好 / 地址不对 / 芯片没上电），之后不再重试。
//   上电后先等 PWRUP_MS 毫秒再开始写（等芯片上电稳定）。
// =============================================================================
module mc_es8388_cfg #(
    parameter CLK_HZ   = 100_000_000,
    parameter I2C_HZ   = 100_000,
    parameter PWRUP_MS = 20,
    parameter [5:0] HP_VOL  = 6'd21,        // 耳机输出音量 0 ~ 33（30 = 0 dB，每级 1.5 dB；21 ≈ -13.5 dB，耳机别太响）
    parameter [5:0] SPK_VOL = 6'd30         // 喇叭输出音量 0 ~ 33（30 = 0 dB）
)(
    input  wire I_clk,
    input  wire I_rst_n,
    input  wire I_tick_1ms,

    output wire O_scl,
    inout  wire IO_sda,

    output reg  O_done,
    output reg  O_err
);

localparam [6:0] DEV = 7'h11;
localparam [4:0] N_REG = 5'd21;

localparam [2:0] ST_PWR = 3'd0, ST_SEND = 3'd1, ST_WAIT_I2C = 3'd2, ST_DELAY = 3'd3, ST_END = 3'd4;

reg [2:0]  S_st;
reg [4:0]  S_idx;
reg [15:0] S_ms;
reg        S_start;
wire       S_busy, S_i2c_done, S_nack;

// ---- 寄存器表：{寄存器号, 数据}，以及写完这一条后要不要等一会儿（毫秒）----
reg [15:0] S_entry;
reg [7:0]  S_wait_ms;
always @* begin
    S_wait_ms = 8'd0;
    case (S_idx)
        5'd0:  S_entry = {8'd0,  8'h80};                 // R0  软复位
        5'd1:  begin S_entry = {8'd0,  8'h00}; S_wait_ms = 8'd20; end   // R0  复位结束，等芯片稳定
        5'd2:  S_entry = {8'd1,  8'h58};                 // R1  模拟电源先低功耗上电
        5'd3:  S_entry = {8'd1,  8'h50};                 // R1  整个模拟电源打开
        5'd4:  S_entry = {8'd2,  8'hF3};                 // R2  数字部分先复位着
        5'd5:  S_entry = {8'd2,  8'h00};                 // R2  ADC/DAC 数字部分、DLL、参考全部放开
        5'd6:  S_entry = {8'd3,  8'hFF};                 // R3  ADC 部分全部断电（只播放，不录音）
        5'd7:  S_entry = {8'd0,  8'h06};                 // R0  使能参考，VMID 500K 分压
        5'd8:  S_entry = {8'd4,  8'h3C};                 // R4  左右 DAC 上电，LOUT1/ROUT1/LOUT2/ROUT2 全部使能
        5'd9:  S_entry = {8'd8,  8'h00};                 // R8  从模式，MCLK 不分频
        5'd10: S_entry = {8'd23, 8'h18};                 // R23 DAC：I2S 格式，16 位
        5'd11: S_entry = {8'd24, 8'h02};                 // R24 DAC：单倍速，MCLK/LRCK = 256（从模式下芯片自动识别比值）
        5'd12: S_entry = {8'd26, 8'h00};                 // R26 左 DAC 数字音量 0 dB
        5'd13: S_entry = {8'd27, 8'h00};                 // R27 右 DAC 数字音量 0 dB
        5'd14: S_entry = {8'd39, 8'h90};                 // R39 左混频器：只放左 DAC
        5'd15: S_entry = {8'd42, 8'h90};                 // R42 右混频器：只放右 DAC
        5'd16: S_entry = {8'd43, 8'h80};                 // R43 DAC 与 ADC 共用 LRCK
        5'd17: S_entry = {8'd46, 2'b00, HP_VOL};         // R46 LOUT1 音量（耳机左）
        5'd18: S_entry = {8'd47, 2'b00, HP_VOL};         // R47 ROUT1 音量（耳机右）
        5'd19: S_entry = {8'd48, 2'b00, SPK_VOL};        // R48 LOUT2 音量（喇叭左，经板上 TT8642 功放）
        default: S_entry = {8'd49, 2'b00, SPK_VOL};      // R49 ROUT2 音量（喇叭右）
    endcase
end

// ---- 顺序写 ----
always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        S_st    <= ST_PWR;
        S_idx   <= 5'd0;
        S_ms    <= 16'd0;
        S_start <= 1'b0;
        O_done  <= 1'b0;
        O_err   <= 1'b0;
    end else begin
        S_start <= 1'b0;
        case (S_st)
            ST_PWR: begin                                   // 上电后等 PWRUP_MS 毫秒
                if (I_tick_1ms) begin
                    if (S_ms >= PWRUP_MS - 1) begin S_ms <= 16'd0; S_st <= ST_SEND; end
                    else                      S_ms <= S_ms + 16'd1;
                end
            end
            ST_SEND: begin
                if (!S_busy) begin
                    S_start <= 1'b1;
                    S_st    <= ST_WAIT_I2C;
                end
            end
            ST_WAIT_I2C: begin
                if (S_i2c_done) begin
                    if (S_nack) begin                       // 没被应答：报错并停下
                        O_err <= 1'b1;
                        S_st  <= ST_END;
                    end else if (S_wait_ms != 8'd0) begin
                        S_ms <= 16'd0;
                        S_st <= ST_DELAY;
                    end else if (S_idx == N_REG - 5'd1) begin
                        O_done <= 1'b1;
                        S_st   <= ST_END;
                    end else begin
                        S_idx <= S_idx + 5'd1;
                        S_st  <= ST_SEND;
                    end
                end
            end
            ST_DELAY: begin
                if (I_tick_1ms) begin
                    if (S_ms >= S_wait_ms - 1) begin
                        S_idx <= S_idx + 5'd1;
                        S_st  <= ST_SEND;
                    end else begin
                        S_ms <= S_ms + 16'd1;
                    end
                end
            end
            default: ;                                      // ST_END：停在这里
        endcase
    end
end

mc_i2c_wr #(.CLK_HZ(CLK_HZ), .I2C_HZ(I2C_HZ)) u_i2c (
    .I_clk   (I_clk),
    .I_rst_n (I_rst_n),
    .I_start (S_start),
    .I_dev   (DEV),
    .I_reg   (S_entry[15:8]),
    .I_data  (S_entry[7:0]),
    .O_busy  (S_busy),
    .O_done  (S_i2c_done),
    .O_nack  (S_nack),
    .O_scl   (O_scl),
    .IO_sda  (IO_sda)
);

endmodule
