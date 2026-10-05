`timescale 1ns / 1ps
// =============================================================================
// mc_audio.v  音频子系统：TF 卡里的 WAV → 板载 ES8388 → 耳机口 / 喇叭口（TT8642 功放）
//             两路同时播：背景音乐（循环，上电自动开始）+ 音效（触发一次播一遍）
//
//                                 ┌ 读文件 #0 ─ mc_wav_player #0 ─┐（背景音乐：BGM_CLIP.wav，循环）
//   TF 卡 ─ mc_sd_spi ─ mc_sd_arb ─ mc_fat32                          ├─ mc_audio_mix ─ mc_i2s_tx ─► ES8388 ─► 耳机 / 喇叭
//   (SPI)   读扇区      轮流给      │（挂载 + 目录表一份）            │                               ▲ I2C 配置：mc_es8388_cfg
//                                 └ 读文件 #1 ─ mc_wav_player #1 ─┘（音效：I_sfx_clip.wav，单次）
//
//   两路各有一个读文件的模块（共用 mc_fat32 里的挂载 + 目录表），共用一个 SD 卡读扇区控制器（mc_sd_arb 轮流给）；混音在 mc_audio_mix：
//     背景音乐在左声道（喇叭口 J12），音效在右声道（喇叭口 J11），各响各的（两个口各接一个喇叭）。
//
//   怎么用：
//     背景音乐：不用命令。上电并且 TF 卡、ES8388 都准备好以后自动从头循环播放 BGM_CLIP.wav（出错 = 没这个文件等，不重试）。
//     I_sfx_play+I_sfx_clip  单周期脉冲：播放音效 <I_sfx_clip>.wav 一遍；音效正在播的时候收到的播放命令被忽略（不会被反复触发、也不会被打断）。
//   TF 卡要求：FAT32（≤ 32 GB 的卡出厂默认就是），WAV 文件放根目录，文件名是数字（1.wav、2.wav …，最多 64 个）；
//     WAV 格式：16 位 PCM，单声道或立体声，采样率 8000 ~ 48828 Hz（48 kHz 最好，其他采样率会自动重采样，见 mc_audio_mix.v）。
//   状态：O_sd_state 0 初始化中 1 就绪 2 没卡 3 不是 FAT32；O_codec_state 0 配置中 1 正常 2 I2C 无应答；
//         O_ready = TF 卡已挂载 + ES8388 已配置好；O_nclips 找到几个 N.wav；
//         O_bgm_state / O_sfx_state：0 空闲 1 打开中 2 播放中 3 出错（O_bgm_err / O_sfx_err 是错误码，见 mc_wav_player.v）；
//         O_sfx_busy：音效正在打开 / 播放；O_bgm_ur / O_sfx_ur：这一路数据没跟上的次数（上板应该一直是 0）。
//
//   引脚（见 pin/mc_pin.adc）：ES8388：MCLK F14、SCLK K13、LRCK C13、DSDIN J13、I2C SCL A13 / SDA B14、
//        SPK_CTL K15（功放使能，高有效，这里恒高）；CE（A12）板上上拉，不用接。TF 卡 SPI 模式：CS = DAT3（E5）、
//        SCK = CLK（D9）、MOSI = CMD（C9）、MISO = DAT0（E6）。
// =============================================================================
module mc_audio #(
    parameter CLK_HZ      = 100_000_000,
    parameter [5:0] HP_VOL  = 6'd21,                // 耳机音量 0 ~ 33（30 = 0 dB，33 = 最大 +4.5 dB；本项目在 mctop.v 配置成 33）
    parameter [5:0] SPK_VOL = 6'd30,                // 喇叭音量 0 ~ 33（30 = 0 dB，33 = 最大 +4.5 dB；本项目在 mctop.v 配置成 33）
    parameter [6:0] BGM_CLIP = 7'd1                 // 背景音乐是 TF 卡根目录的第几个 N.wav
)(
    input  wire        I_clk,                       // 100 MHz
    input  wire        I_rst_n,
    input  wire        I_tick_1ms,

    // ---- 命令 ----
    input  wire        I_sfx_play,
    input  wire [6:0]  I_sfx_clip,

    // ---- 状态 ----
    output wire [2:0]  O_sd_state,
    output wire [1:0]  O_codec_state,
    output wire [7:0]  O_nclips,
    output wire        O_ready,
    output wire [1:0]  O_bgm_state,
    output wire [7:0]  O_bgm_err,
    output wire [7:0]  O_bgm_ur,
    output wire [1:0]  O_sfx_state,
    output wire [6:0]  O_sfx_cur,
    output wire [7:0]  O_sfx_err,
    output wire [7:0]  O_sfx_ur,
    output wire        O_sfx_busy,

    // ---- ES8388 ----
    output wire        O_aud_mclk,
    output wire        O_aud_sclk,
    output wire        O_aud_lrck,
    output wire        O_aud_dsdin,
    output wire        O_aud_cclk,
    inout  wire        IO_aud_cdata,
    output wire        O_spk_ctl,

    // ---- TF 卡（SPI 模式）----
    output wire        O_sd_cs_n,
    output wire        O_sd_sck,
    output wire        O_sd_mosi,
    input  wire        I_sd_miso
);

assign O_spk_ctl = 1'b1;

// ---------------------------------------------------------------------------
// ES8388：I2C 配置
// ---------------------------------------------------------------------------
wire       S_cfg_done, S_cfg_err;

mc_es8388_cfg #(
    .CLK_HZ  (CLK_HZ),
    .HP_VOL  (HP_VOL),
    .SPK_VOL (SPK_VOL)
) u_cfg (
    .I_clk      (I_clk),
    .I_rst_n    (I_rst_n),
    .I_tick_1ms (I_tick_1ms),
    .O_scl      (O_aud_cclk),
    .IO_sda     (IO_aud_cdata),
    .O_done     (S_cfg_done),
    .O_err      (S_cfg_err)
);

assign O_codec_state = S_cfg_err ? 2'd2 : (S_cfg_done ? 2'd1 : 2'd0);

// ---------------------------------------------------------------------------
// TF 卡：SPI 读扇区（一个）+ 仲裁 + FAT32 读文件（挂载 + 目录表一份，两路各一个读文件模块）
// ---------------------------------------------------------------------------
wire        S_sd_ready, S_sd_fail, S_sdhc;
wire [2:0]  S_sd_fail_code;
wire        S_rd_start, S_rd_busy, S_byte_valid, S_rd_done, S_rd_err;
wire [31:0] S_lba;
wire [7:0]  S_byte;
wire [8:0]  S_byte_idx;

mc_sd_spi u_sd (
    .I_clk        (I_clk),
    .I_rst_n      (I_rst_n),
    .I_tick_1ms   (I_tick_1ms),
    .O_cs_n       (O_sd_cs_n),
    .O_sck        (O_sd_sck),
    .O_mosi       (O_sd_mosi),
    .I_miso       (I_sd_miso),
    .I_init       (1'b0),
    .O_ready      (S_sd_ready),
    .O_fail       (S_sd_fail),
    .O_fail_code  (S_sd_fail_code),
    .O_sdhc       (S_sdhc),
    .I_rd_start   (S_rd_start),
    .I_lba        (S_lba),
    .O_rd_busy    (S_rd_busy),
    .O_byte_valid (S_byte_valid),
    .O_byte       (S_byte),
    .O_byte_idx   (S_byte_idx),
    .O_rd_done    (S_rd_done),
    .O_rd_err     (S_rd_err)
);

// 请求方 0 = 背景音乐，1 = 音效
wire        S_f0_start, S_f1_start, S_f0_busy, S_f1_busy;
wire [31:0] S_f0_lba, S_f1_lba;
wire        S_f0_valid, S_f1_valid, S_f0_done, S_f1_done, S_f0_err, S_f1_err;
wire [7:0]  S_f0_byte, S_f1_byte;
wire [8:0]  S_f0_idx, S_f1_idx;

mc_sd_arb u_arb (
    .I_clk     (I_clk),
    .I_rst_n   (I_rst_n),
    .I_start0  (S_f0_start), .I_lba0 (S_f0_lba), .O_busy0 (S_f0_busy),
    .O_valid0  (S_f0_valid), .O_byte0 (S_f0_byte), .O_idx0 (S_f0_idx), .O_done0 (S_f0_done), .O_err0 (S_f0_err),
    .I_start1  (S_f1_start), .I_lba1 (S_f1_lba), .O_busy1 (S_f1_busy),
    .O_valid1  (S_f1_valid), .O_byte1 (S_f1_byte), .O_idx1 (S_f1_idx), .O_done1 (S_f1_done), .O_err1 (S_f1_err),
    .O_start   (S_rd_start),
    .O_lba     (S_lba),
    .I_sd_busy (S_rd_busy),
    .I_valid   (S_byte_valid),
    .I_byte    (S_byte),
    .I_idx     (S_byte_idx),
    .I_done    (S_rd_done),
    .I_err     (S_rd_err)
);

wire        S_m, S_mf;
wire        S_open0, S_close0, S_oerr0, S_dv0, S_space0, S_eof0, S_act0;
wire        S_open1, S_close1, S_oerr1, S_dv1, S_space1, S_eof1, S_act1;
wire [6:0]  S_oclip0, S_oclip1;
wire [2:0]  S_oecode0, S_oecode1;
wire [7:0]  S_d0, S_d1;

mc_fat32 u_fat (
    .I_clk         (I_clk),
    .I_rst_n       (I_rst_n),
    .I_sd_ready    (S_sd_ready),
    .I_sd_fail     (S_sd_fail),
    .O_rd_start0   (S_f0_start),
    .O_lba0        (S_f0_lba),
    .I_rd_busy0    (S_f0_busy),
    .I_byte_valid0 (S_f0_valid),
    .I_byte0       (S_f0_byte),
    .I_byte_idx0   (S_f0_idx),
    .I_rd_done0    (S_f0_done),
    .I_rd_err0     (S_f0_err),
    .O_rd_start1   (S_f1_start),
    .O_lba1        (S_f1_lba),
    .I_rd_busy1    (S_f1_busy),
    .I_byte_valid1 (S_f1_valid),
    .I_byte1       (S_f1_byte),
    .I_byte_idx1   (S_f1_idx),
    .I_rd_done1    (S_f1_done),
    .I_rd_err1     (S_f1_err),
    .O_mounted     (S_m),
    .O_mount_fail  (S_mf),
    .O_mount_code  (),
    .O_nclips      (O_nclips),
    .I_open0       (S_open0),
    .I_clip0       (S_oclip0),
    .I_close0      (S_close0),
    .O_open_err0   (S_oerr0),
    .O_err_code0   (S_oecode0),
    .O_data_valid0 (S_dv0),
    .O_data0       (S_d0),
    .I_space_ok0   (S_space0),
    .O_eof0        (S_eof0),
    .O_active0     (S_act0),
    .I_open1       (S_open1),
    .I_clip1       (S_oclip1),
    .I_close1      (S_close1),
    .O_open_err1   (S_oerr1),
    .O_err_code1   (S_oecode1),
    .O_data_valid1 (S_dv1),
    .O_data1       (S_d1),
    .I_space_ok1   (S_space1),
    .O_eof1        (S_eof1),
    .O_active1     (S_act1)
);

assign O_sd_state = S_sd_fail ? 3'd2 : (S_mf ? 3'd3 : (S_m ? 3'd1 : 3'd0));
assign O_ready    = S_cfg_done & S_m;

// ---------------------------------------------------------------------------
// 背景音乐的控制：准备好以后自动播 BGM_CLIP（循环），只发一次播放命令
// ---------------------------------------------------------------------------
reg  S_bgm_tried;               // 已经发过播放命令
reg  S_bgm_play;

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        S_bgm_tried <= 1'b0;
        S_bgm_play  <= 1'b0;
    end else begin
        S_bgm_play <= 1'b0;
        if (O_ready && !S_bgm_tried) begin
            S_bgm_play  <= 1'b1;
            S_bgm_tried <= 1'b1;
        end
    end
end

// ---------------------------------------------------------------------------
// 两个 WAV 播放器
// ---------------------------------------------------------------------------
wire        S_ack0, S_ack1, S_ur0, S_ur1;
wire        S_v0, S_v1;
wire [15:0] S_l0, S_r0, S_l1, S_r1, S_rate0, S_rate1;
wire [1:0]  S_st0, S_st1;
wire        S_busy0, S_busy1;

mc_wav_player u_p0 (
    .I_clk          (I_clk),
    .I_rst_n        (I_rst_n),
    .I_play         (S_bgm_play),
    .I_clip         (BGM_CLIP),
    .I_loop         (1'b1),
    .O_state        (S_st0),
    .O_cur          (),
    .O_err          (O_bgm_err),
    .O_underrun     (O_bgm_ur),
    .I_mounted      (S_m),
    .O_open         (S_open0),
    .O_open_clip    (S_oclip0),
    .O_close        (S_close0),
    .I_open_err     (S_oerr0),
    .I_open_err_code(S_oecode0),
    .I_data_valid   (S_dv0),
    .I_data         (S_d0),
    .O_space_ok     (S_space0),
    .I_eof          (S_eof0),
    .I_fat_active   (S_act0),
    .O_busy         (S_busy0),
    .O_rate         (S_rate0),
    .O_i2s_valid    (S_v0),
    .O_l            (S_l0),
    .O_r            (S_r0),
    .I_ack          (S_ack0),
    .I_i2s_underrun (S_ur0)
);

assign O_bgm_state = S_st0;

mc_wav_player u_p1 (
    .I_clk          (I_clk),
    .I_rst_n        (I_rst_n),
    .I_play         (I_sfx_play & ~S_busy1),            // 音效正在播：新的播放命令不理（不重复触发、不打断）
    .I_clip         (I_sfx_clip),
    .I_loop         (1'b0),
    .O_state        (S_st1),
    .O_cur          (O_sfx_cur),
    .O_err          (O_sfx_err),
    .O_underrun     (O_sfx_ur),
    .I_mounted      (S_m),
    .O_open         (S_open1),
    .O_open_clip    (S_oclip1),
    .O_close        (S_close1),
    .I_open_err     (S_oerr1),
    .I_open_err_code(S_oecode1),
    .I_data_valid   (S_dv1),
    .I_data         (S_d1),
    .O_space_ok     (S_space1),
    .I_eof          (S_eof1),
    .I_fat_active   (S_act1),
    .O_busy         (S_busy1),
    .O_rate         (S_rate1),
    .O_i2s_valid    (S_v1),
    .O_l            (S_l1),
    .O_r            (S_r1),
    .I_ack          (S_ack1),
    .I_i2s_underrun (S_ur1)
);

assign O_sfx_state = S_st1;
assign O_sfx_busy  = S_busy1;

// ---------------------------------------------------------------------------
// 混音 + I2S
// ---------------------------------------------------------------------------
wire        S_mix_valid;
wire [15:0] S_mix_l, S_mix_r;
wire        S_frame;

mc_audio_mix u_mix (
    .I_clk   (I_clk),
    .I_rst_n (I_rst_n),
    .I_st0   (S_st0), .I_v0 (S_v0), .I_l0 (S_l0), .I_r0 (S_r0), .I_rate0 (S_rate0), .O_ack0 (S_ack0), .O_ur0 (S_ur0),
    .I_st1   (S_st1), .I_v1 (S_v1), .I_l1 (S_l1), .I_r1 (S_r1), .I_rate1 (S_rate1), .O_ack1 (S_ack1), .O_ur1 (S_ur1),
    .I_frame (S_frame),
    .O_valid (S_mix_valid),
    .O_l     (S_mix_l),
    .O_r     (S_mix_r)
);

mc_i2s_tx u_i2s (
    .I_clk      (I_clk),
    .I_rst_n    (I_rst_n),
    .I_rate_sel (3'd0),                                 // 固定比值 256：LRCK = 12.5 MHz ÷ 256 = 48828.125 Hz
    .I_valid    (S_mix_valid),
    .I_l        (S_mix_l),
    .I_r        (S_mix_r),
    .O_ack      (S_frame),
    .O_underrun (),
    .O_mclk     (O_aud_mclk),
    .O_sclk     (O_aud_sclk),
    .O_lrck     (O_aud_lrck),
    .O_dsdin    (O_aud_dsdin)
);

endmodule
