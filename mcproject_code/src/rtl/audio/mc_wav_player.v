`timescale 1ns / 1ps
// =============================================================================
// mc_wav_player.v  WAV 播放器：从 mc_fat32 要一个文件的字节流 → 解析 WAV 头 → 一帧一帧交给 mc_i2s_tx
//
//   命令口（单周期脉冲；这就是"以后状态机直接调用"的接口）：
//     I_play + I_clip   播放第 I_clip 首（TF 卡根目录的 N.wav，N = 1 ~ 64）。正在播别的会先停掉再播。
//     I_loop            电平：1 = 播完一遍自动从头再播（循环），0 = 播一遍就停。
//   状态口：O_state 0 空闲 1 正在打开/解析头 2 正在播放 3 出错（O_err 是错误码）；O_cur 当前曲目号。
//     O_err：1 没有这个编号的文件  2 不是 WAV（头不对/格式块太短）  3 格式不支持（只支持 16 位 PCM，单声道或立体声，
//            采样率 8000 ~ 48828 Hz；采样率不用和 I2S 一致，由 mc_audio_mix 重采样）  4 读卡错误  5 TF 卡没准备好（没插卡/不是 FAT32）
//     O_busy：正在打开 / 播放（出错状态不算忙）；O_rate：当前文件的采样率（Hz），给 mc_audio_mix 用。
//     O_underrun：播放中 I2S 要采样时没有采样（数据没跟上）的次数；上板时应该一直是 0。
//
//   WAV 头解析：RIFF 块 → "WAVE" → 依次读各个块：fmt 块取格式（PCM、声道数、采样率、位数）、data 块开始播放，
//   其他块（LIST、fact 等）整块跳过（奇数长度补 1 字节对齐）。播放长度以 data 块的长度为准（但最多不超过文件实际内容）。
//   环形缓冲 2 KB（4 个扇区）：mc_fat32 在缓冲有 ≥ 512 字节空位时才去读下一个扇区，播放侧一个字节一个字节地取，
//   所以 SD 卡偶尔慢一两个扇区的时间（几毫秒）也不会断音。单声道的采样同时送左右声道。
// =============================================================================
module mc_wav_player (
    input  wire        I_clk,
    input  wire        I_rst_n,

    // ---- 命令 / 状态 ----
    input  wire        I_play,
    input  wire [6:0]  I_clip,
    input  wire        I_loop,
    output reg  [1:0]  O_state,
    output reg  [6:0]  O_cur,
    output reg  [7:0]  O_err,
    output reg  [7:0]  O_underrun,

    // ---- mc_fat32 ----
    input  wire        I_mounted,
    output reg         O_open,
    output reg  [6:0]  O_open_clip,
    output reg         O_close,
    input  wire        I_open_err,
    input  wire [2:0]  I_open_err_code,
    input  wire        I_data_valid,
    input  wire [7:0]  I_data,
    output wire        O_space_ok,
    input  wire        I_eof,
    input  wire        I_fat_active,

    // ---- 交给 mc_audio_mix（一帧一帧，取走时给 I_ack）----
    output wire        O_busy,
    output reg  [15:0] O_rate,
    output reg         O_i2s_valid,
    output reg  [15:0] O_l,
    output reg  [15:0] O_r,
    input  wire        I_ack,
    input  wire        I_i2s_underrun
);

// ---------------------------------------------------------------------------
// 环形缓冲 2 KB
// ---------------------------------------------------------------------------
reg [7:0]  S_ring [0:2047];
reg [11:0] S_wp, S_rp;                           // 多 1 位用来区分满/空
reg [10:0] S_raddr;
reg [7:0]  S_rdq;
wire [11:0] S_cnt = S_wp - S_rp;                 // 缓冲里有多少字节
assign O_space_ok = (S_cnt <= 12'd1536);         // 空位 ≥ 512

reg        S_flush;                              // 清空缓冲
always @(posedge I_clk) begin
    if (I_data_valid) S_ring[S_wp[10:0]] <= I_data;
    S_rdq <= S_ring[S_raddr];
end

// ---------------------------------------------------------------------------
// 取一个字节（请求—应答）：主状态机给一个 S_req 脉冲 → 缓冲里有数据时 3 拍后 S_bv 给一个脉冲，S_byte 有效。
//   每个字节都是"状态机想要才取"，不会多取。
// ---------------------------------------------------------------------------
reg [1:0]  F_st;
reg        S_req;
reg        S_pend;
reg        S_bv;
reg [7:0]  S_byte;

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        F_st    <= 2'd0;
        S_pend  <= 1'b0;
        S_bv    <= 1'b0;
        S_byte  <= 8'd0;
        S_raddr <= 11'd0;
        S_wp    <= 12'd0;
        S_rp    <= 12'd0;
    end else begin
        S_bv <= 1'b0;
        if (I_data_valid) S_wp <= S_wp + 12'd1;
        if (S_req) S_pend <= 1'b1;
        if (S_flush) begin
            S_wp   <= 12'd0;
            S_rp   <= 12'd0;
            F_st   <= 2'd0;
            S_pend <= 1'b0;
        end else begin
            case (F_st)
                2'd0: if (S_pend && S_cnt != 12'd0) begin S_raddr <= S_rp[10:0]; S_pend <= 1'b0; F_st <= 2'd1; end
                2'd1: F_st <= 2'd2;
                default: begin
                    S_byte <= S_rdq;
                    S_bv   <= 1'b1;
                    S_rp   <= S_rp + 12'd1;
                    F_st   <= 2'd0;
                end
            endcase
        end
    end
end

// ---------------------------------------------------------------------------
// 主状态机
// ---------------------------------------------------------------------------
localparam [4:0]
    P_IDLE = 5'd0,  P_STOPPING = 5'd1, P_START = 5'd2,  P_RIFF = 5'd3,  P_RSZ = 5'd4,   P_WAVE = 5'd5,
    P_CID  = 5'd6,  P_CSZ = 5'd7,      P_FMT = 5'd8,    P_SKIP = 5'd9,  P_PAD = 5'd10,  P_FRAME = 5'd11,
    P_END  = 5'd12, P_ERR = 5'd13;

reg [4:0]  S_st;
reg [4:0]  S_after;                              // P_STOPPING 做完后去哪
reg [6:0]  S_clip;
reg [31:0] S_id;
reg [31:0] S_cid;
reg [31:0] S_csz;
reg [31:0] S_ci;
reg [2:0]  S_n;
reg        S_fmt_seen;
reg [15:0] S_tag, S_chn, S_bits;
reg [31:0] S_rate;
reg [31:0] S_dleft;
reg [1:0]  S_fb;
reg        S_stereo;
reg        S_eof_seen;
reg        S_wait_bv;

localparam [31:0] ID_RIFF = 32'h52494646, ID_WAVE = 32'h57415645, ID_FMT = 32'h666D7420, ID_DATA = 32'h64617461;

wire S_want = (S_st == P_RIFF) || (S_st == P_RSZ) || (S_st == P_WAVE) || (S_st == P_CID) || (S_st == P_CSZ) ||
              (S_st == P_FMT)  || (S_st == P_SKIP) || (S_st == P_PAD) ||
              ((S_st == P_FRAME) && !O_i2s_valid && (S_dleft != 32'd0));

// 采样率：8000 ~ 48828 Hz（I2S 帧率 48828.125 Hz 以内；更高的没法降采样，不支持）
wire S_rate_ok = (S_rate >= 32'd8000) && (S_rate <= 32'd48828);
wire S_fmt_ok = (S_tag == 16'd1) && (S_chn == 16'd1 || S_chn == 16'd2) && (S_bits == 16'd16) && S_rate_ok;

// 忙 = 状态机不在空闲、也不在出错停靠状态（收到 I_play 后下一拍就变忙，外面据此做"播放中不能重复触发"）
assign O_busy = (S_st != P_IDLE) && (S_st != P_ERR);

task fail;                                       // 出错：记错误码，通知 mc_fat32 停下，等下一个命令
    input [7:0] code;
    begin
        O_err   <= code;
        O_state <= 2'd3;
        O_close <= 1'b1;
        S_st    <= P_ERR;
    end
endtask

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        S_st        <= P_IDLE;
        S_after     <= P_IDLE;
        S_clip      <= 7'd0;
        S_id        <= 32'd0;
        S_cid       <= 32'd0;
        S_csz       <= 32'd0;
        S_ci        <= 32'd0;
        S_n         <= 3'd0;
        S_fmt_seen  <= 1'b0;
        S_tag       <= 16'd0;
        S_chn       <= 16'd0;
        S_bits      <= 16'd0;
        S_rate      <= 32'd0;
        S_dleft     <= 32'd0;
        S_fb        <= 2'd0;
        S_stereo    <= 1'b0;
        S_eof_seen  <= 1'b0;
        S_wait_bv   <= 1'b0;
        S_req       <= 1'b0;
        S_flush     <= 1'b0;
        O_state     <= 2'd0;
        O_cur       <= 7'd0;
        O_err       <= 8'd0;
        O_underrun  <= 8'd0;
        O_open      <= 1'b0;
        O_open_clip <= 7'd0;
        O_close     <= 1'b0;
        O_rate      <= 16'd48000;
        O_i2s_valid <= 1'b0;
        O_l         <= 16'd0;
        O_r         <= 16'd0;
    end else begin
        O_open  <= 1'b0;
        O_close <= 1'b0;
        S_flush <= 1'b0;
        S_req   <= 1'b0;
        if (I_ack)        O_i2s_valid <= 1'b0;
        if (I_eof)        S_eof_seen  <= 1'b1;
        if (I_i2s_underrun && O_state == 2'd2 && O_underrun != 8'hFF) O_underrun <= O_underrun + 8'd1;

        // ---- 取字节的请求：状态机"想要"且没有请求在途时发一个 ----
        if (S_bv) S_wait_bv <= 1'b0;
        if (S_want && !S_wait_bv && !S_req) begin
            S_req     <= 1'b1;
            S_wait_bv <= 1'b1;
        end

        // ---- 命令：随时可以打断当前播放 ----
        if (I_play) begin
            O_close   <= 1'b1;
            S_clip    <= I_clip;
            S_after   <= P_START;
            S_st      <= P_STOPPING;
            S_wait_bv <= 1'b0;
        end else begin
            case (S_st)
                P_IDLE: if (O_state != 2'd3) O_state <= 2'd0;

                P_STOPPING: begin                          // 等 mc_fat32 停下来，清缓冲
                    O_state     <= 2'd0;
                    O_i2s_valid <= 1'b0;
                    S_wait_bv   <= 1'b0;
                    if (!I_fat_active && !O_close && !I_data_valid) begin
                        S_flush <= 1'b1;
                        O_err   <= 8'd0;
                        S_st    <= S_after;
                    end
                end

                P_START: begin                              // 发出"打开曲目"
                    if (!I_mounted) fail(8'd5);
                    else begin
                        O_open      <= 1'b1;
                        O_open_clip <= S_clip;
                        O_cur       <= S_clip;
                        O_state     <= 2'd1;
                        S_n         <= 3'd0;
                        S_ci        <= 32'd0;
                        S_fmt_seen  <= 1'b0;
                        S_eof_seen  <= 1'b0;
                        S_flush     <= 1'b1;
                        S_st        <= P_RIFF;
                    end
                end

                // ---- 文件头 ----
                P_RIFF, P_WAVE: if (S_bv) begin
                    S_id <= {S_id[23:0], S_byte};
                    if (S_n == 3'd3) begin
                        S_n <= 3'd0;
                        if ({S_id[23:0], S_byte} == ((S_st == P_RIFF) ? ID_RIFF : ID_WAVE)) S_st <= (S_st == P_RIFF) ? P_RSZ : P_CID;
                        else fail(8'd2);
                    end else S_n <= S_n + 3'd1;
                end
                P_RSZ: if (S_bv) begin
                    if (S_n == 3'd3) begin S_n <= 3'd0; S_st <= P_WAVE; end
                    else S_n <= S_n + 3'd1;
                end
                P_CID: if (S_bv) begin
                    S_id <= {S_id[23:0], S_byte};
                    if (S_n == 3'd3) begin S_n <= 3'd0; S_cid <= {S_id[23:0], S_byte}; S_st <= P_CSZ; end
                    else S_n <= S_n + 3'd1;
                end
                P_CSZ: if (S_bv) begin
                    case (S_n)
                        3'd0: S_csz[7:0]   <= S_byte;
                        3'd1: S_csz[15:8]  <= S_byte;
                        3'd2: S_csz[23:16] <= S_byte;
                        default: S_csz[31:24] <= S_byte;
                    endcase
                    if (S_n == 3'd3) begin
                        S_n  <= 3'd0;
                        S_ci <= 32'd0;
                        if (S_cid == ID_FMT) begin
                            if ({S_byte, S_csz[23:0]} < 32'd16) fail(8'd2);
                            else S_st <= P_FMT;
                        end else if (S_cid == ID_DATA) begin
                            S_dleft <= {S_byte, S_csz[23:0]};
                            S_fb    <= 2'd0;
                            if (!S_fmt_seen)  fail(8'd2);
                            else if (!S_fmt_ok) fail(8'd3);
                            else begin
                                O_rate     <= S_rate[15:0];
                                S_stereo   <= (S_chn == 16'd2);
                                S_st       <= P_FRAME;                   // O_state 仍是 1（打开中），第一帧装好才变成 2（播放中）
                            end
                        end else if ({S_byte, S_csz[23:0]} == 32'd0) S_st <= P_CID;
                        else S_st <= P_SKIP;
                    end else S_n <= S_n + 3'd1;
                end
                P_FMT: if (S_bv) begin
                    if (S_ci < 32'd16) begin                // 只有前 16 个字节里的字段有意义
                        case (S_ci[3:0])
                            4'd0:  S_tag[7:0]    <= S_byte;
                            4'd1:  S_tag[15:8]   <= S_byte;
                            4'd2:  S_chn[7:0]    <= S_byte;
                            4'd3:  S_chn[15:8]   <= S_byte;
                            4'd4:  S_rate[7:0]   <= S_byte;
                            4'd5:  S_rate[15:8]  <= S_byte;
                            4'd6:  S_rate[23:16] <= S_byte;
                            4'd7:  S_rate[31:24] <= S_byte;
                            4'd14: S_bits[7:0]   <= S_byte;
                            4'd15: S_bits[15:8]  <= S_byte;
                            default: ;
                        endcase
                    end
                    if (S_ci == S_csz - 32'd1) begin
                        S_fmt_seen <= 1'b1;
                        S_ci <= 32'd0;
                        S_st <= S_csz[0] ? P_PAD : P_CID;
                    end else S_ci <= S_ci + 32'd1;
                end
                P_SKIP: if (S_bv) begin
                    if (S_ci == S_csz - 32'd1) begin S_ci <= 32'd0; S_st <= S_csz[0] ? P_PAD : P_CID; end
                    else S_ci <= S_ci + 32'd1;
                end
                P_PAD: if (S_bv) S_st <= P_CID;

                // ---- 播放：一帧一帧装 ----
                P_FRAME: begin
                    if (S_bv) begin
                        S_dleft <= S_dleft - 32'd1;
                        case (S_fb)
                            2'd0: begin O_l[7:0] <= S_byte; S_fb <= 2'd1; end
                            2'd1: begin
                                O_l[15:8] <= S_byte;
                                if (!S_stereo) begin
                                    O_r         <= {S_byte, O_l[7:0]};
                                    O_i2s_valid <= 1'b1;
                                    O_state     <= 2'd2;
                                    S_fb        <= 2'd0;
                                end else S_fb <= 2'd2;
                            end
                            2'd2: begin O_r[7:0] <= S_byte; S_fb <= 2'd3; end
                            default: begin
                                O_r[15:8]   <= S_byte;
                                O_i2s_valid <= 1'b1;
                                O_state     <= 2'd2;
                                S_fb        <= 2'd0;
                            end
                        endcase
                    end
                    // data 块取完了，或者文件提前结束、缓冲里也没数据了 → 收尾（不完整的最后一帧丢掉）
                    if (S_dleft == 32'd0 || (S_eof_seen && S_cnt == 12'd0 && F_st == 2'd0 && !S_bv && !S_pend && !S_req))
                        S_st <= P_END;
                end
                P_END: begin                                // 最后一帧要等 I2S 取走再收尾
                    if (!O_i2s_valid) begin
                        if (I_loop) begin
                            O_close <= 1'b1;
                            S_after <= P_START;
                            S_st    <= P_STOPPING;
                        end else begin
                            O_state <= 2'd0;
                            O_cur   <= 7'd0;
                            S_st    <= P_IDLE;
                        end
                    end
                end

                P_ERR: ;                                    // 停在这里，等下一个命令

                default: S_st <= P_IDLE;
            endcase

            // ---- 打开失败（来自 mc_fat32）----
            if (I_open_err && (S_st == P_RIFF || S_st == P_RSZ || S_st == P_WAVE || S_st == P_CID || S_st == P_CSZ ||
                               S_st == P_FMT  || S_st == P_SKIP || S_st == P_PAD || S_st == P_FRAME)) begin
                O_err   <= (I_open_err_code == 3'd1) ? 8'd1 : 8'd4;
                O_state <= 2'd3;
                S_st    <= P_ERR;
            end
        end
    end
end

endmodule
