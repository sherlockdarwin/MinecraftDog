`timescale 1ns / 1ps
// =============================================================================
// mc_audio_mix.v  两路音频（背景音乐 + 音效）→ 重采样到 I2S 的帧率 → 背景音乐放左声道、音效放右声道 → 交给 mc_i2s_tx
//
//   I2S 的 LRCK 固定 12.5 MHz ÷ 256 = 48828.125 Hz（ES8388 的比值不变，不会因为换曲目出杂音）。每一路的 WAV 采样率可以不同，
//   这里按"每一路自己的采样率 ÷ 48828.125"决定每个 I2S 帧要不要从播放器取新的一帧，不取就重复上一帧（保持采样，零阶保持）：
//     · 48 kHz（≥ 47.5 kHz 都当原生 48 kHz）：每帧取一次，不重采样；实际速度比标称快 1.7 %（12.5 MHz 不是标准的 12.288 MHz，听不出来）
//     · 其他采样率（44.1 / 32 / 24 / 16 / 12 kHz …）：按比例间隔取，速度准确，但音质比 48 kHz 稍差（高频有一点毛）。
//     所以背景音乐最好转成 48 kHz（见 audio.md 的 ffmpeg 命令）；音效随便。
//   取样的节拍：mc_i2s_tx 每取走一帧给一个 I_frame 脉冲，这里据此算下一帧（一帧 ≥ 2048 个时钟，足够）。
//   播放器那边：O_i2s_valid = 有一帧等着被取；我们取走时给 O_ack，播放器才去准备下一帧。取样时播放器没准备好 = 欠载（O_ur 脉冲，
//   这一帧补静音）；播放器没在播（状态 ≠ 2）时这一路送静音。
//
//   混音：左声道 = 背景音乐（立体声先左右取平均变成单声道），右声道 = 音效（同样取平均）
//         → 两个喇叭口各接一个喇叭：J12（左）放背景音乐，J11（右）放音效，两路各响各的。
// =============================================================================
module mc_audio_mix (
    input  wire        I_clk,
    input  wire        I_rst_n,

    // ---- 流 0：背景音乐（mc_wav_player）----
    input  wire [1:0]  I_st0,               // 播放器状态：2 = 播放中
    input  wire        I_v0,                // 有一帧等着取
    input  wire [15:0] I_l0,
    input  wire [15:0] I_r0,
    input  wire [15:0] I_rate0,             // 这个文件的采样率（Hz）
    output reg         O_ack0,              // 单周期脉冲：取走了这一帧
    output reg         O_ur0,               // 单周期脉冲：该取的时候没有（欠载）

    // ---- 流 1：音效 ----
    input  wire [1:0]  I_st1,
    input  wire        I_v1,
    input  wire [15:0] I_l1,
    input  wire [15:0] I_r1,
    input  wire [15:0] I_rate1,
    output reg         O_ack1,
    output reg         O_ur1,

    // ---- mc_i2s_tx ----
    input  wire        I_frame,             // 单周期脉冲：I2S 取走了一帧，该算下一帧了
    output reg         O_valid,             // 恒为 1（复位后）
    output reg  [15:0] O_l,
    output reg  [15:0] O_r
);

localparam [19:0] FS8 = 20'd390625;         // 48828.125 Hz × 8（用 1/8 Hz 做单位，整数运算）

function [19:0] rate8;                      // 采样率（Hz）→ ×8；≥ 47500 的当作原生 48 kHz（每帧都取）
    input [15:0] r;
    begin
        rate8 = (r >= 16'd47500) ? FS8 : {1'b0, r, 3'b000};
    end
endfunction

reg  [19:0] S_ph0, S_ph1;                   // 相位累加器
reg         S_take0, S_take1;
reg  [1:0]  S_st;                           // 0 等 I_frame  1 取样  2 输出
reg  signed [15:0] S_h0l, S_h0r, S_h1l, S_h1r;      // 每路当前的保持采样

wire [19:0] S_n0 = S_ph0 + rate8(I_rate0);
wire [19:0] S_n1 = S_ph1 + rate8(I_rate1);
wire        S_act0 = (I_st0 == 2'd2);
wire        S_act1 = (I_st1 == 2'd2);

// 左右相加取平均（17 位和不会溢出；[16:1] = 除以 2）
wire signed [16:0] S_t0 = $signed({S_h0l[15], S_h0l}) + $signed({S_h0r[15], S_h0r});
wire signed [16:0] S_t1 = $signed({S_h1l[15], S_h1l}) + $signed({S_h1r[15], S_h1r});

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        S_ph0   <= 20'd0;
        S_ph1   <= 20'd0;
        S_take0 <= 1'b0;
        S_take1 <= 1'b0;
        S_st    <= 2'd0;
        S_h0l   <= 16'sd0;
        S_h0r   <= 16'sd0;
        S_h1l   <= 16'sd0;
        S_h1r   <= 16'sd0;
        O_ack0  <= 1'b0;
        O_ack1  <= 1'b0;
        O_ur0   <= 1'b0;
        O_ur1   <= 1'b0;
        O_valid <= 1'b1;
        O_l     <= 16'd0;
        O_r     <= 16'd0;
    end else begin
        O_ack0 <= 1'b0;
        O_ack1 <= 1'b0;
        O_ur0  <= 1'b0;
        O_ur1  <= 1'b0;
        case (S_st)
            2'd0: if (I_frame) begin
                // 相位累加：加上这一路的采样率，满一个 I2S 帧的量就取新的一帧；没在播时预置成"下一帧就取"
                if (S_act0) begin
                    if (S_n0 >= FS8) begin S_ph0 <= S_n0 - FS8; S_take0 <= 1'b1; end
                    else             begin S_ph0 <= S_n0;       S_take0 <= 1'b0; end
                end else begin
                    S_ph0   <= FS8;                  // 预置成"一开播第一帧就取"，和上一个文件的采样率无关
                    S_take0 <= 1'b0;
                    S_h0l   <= 16'sd0;
                    S_h0r   <= 16'sd0;
                end
                if (S_act1) begin
                    if (S_n1 >= FS8) begin S_ph1 <= S_n1 - FS8; S_take1 <= 1'b1; end
                    else             begin S_ph1 <= S_n1;       S_take1 <= 1'b0; end
                end else begin
                    S_ph1   <= FS8;
                    S_take1 <= 1'b0;
                    S_h1l   <= 16'sd0;
                    S_h1r   <= 16'sd0;
                end
                S_st <= 2'd1;
            end

            2'd1: begin                                  // 取样
                if (S_take0) begin
                    if (I_v0) begin S_h0l <= I_l0; S_h0r <= I_r0; O_ack0 <= 1'b1; end
                    else      begin S_h0l <= 16'sd0; S_h0r <= 16'sd0; O_ur0 <= 1'b1; end
                end
                if (S_take1) begin
                    if (I_v1) begin S_h1l <= I_l1; S_h1r <= I_r1; O_ack1 <= 1'b1; end
                    else      begin S_h1l <= 16'sd0; S_h1r <= 16'sd0; O_ur1 <= 1'b1; end
                end
                S_st <= 2'd2;
            end

            default: begin                               // 输出
                O_l  <= S_t0[16:1];
                O_r  <= S_t1[16:1];
                S_st <= 2'd0;
            end
        endcase
    end
end

endmodule
