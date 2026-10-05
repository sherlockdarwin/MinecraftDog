`timescale 1ns / 1ps
// =============================================================================
// mc_sd_spi.v  TF 卡（SD 卡）SPI 模式读卡：上电初始化 + 读一个 512 字节扇区
//
//   为什么用 SPI 模式：板上 TF 座的 4 位 SDIO 线全接到 FPGA（3.3 V，各有 22 Ω 串阻和 4.7k 上拉），SPI 模式只用其中 4 根：
//        CS = DAT3（E5）  SCK = CLK（D9）  MOSI = CMD（C9）  MISO = DAT0（E6）；DAT1/DAT2 不用（座子上有上拉）。
//     SPI 模式比 SDIO 简单得多，速度（SCK 12.5 MHz ≈ 1.5 MB/s）远够播 48 kHz 立体声 16 位（0.19 MB/s）。
//   初始化流程（SD 物理层规范）：上电等 2 ms → CS 拉高发 80 个时钟 → CMD0（进空闲）→ CMD8（区分 v1/v2 卡）
//        → 反复 CMD55 + ACMD41 直到卡就绪（最多约 1.5 秒）→ CMD58 读 OCR 看是不是大容量卡（SDHC/SDXC：块地址；SDSC：字节地址）
//        → 非大容量卡再 CMD16 设块长 512 → SCK 提到 12.5 MHz。初始化期间 SCK = 100 MHz ÷ 256 ≈ 390 kHz（规范要求 ≤ 400 kHz）。
//   读扇区：CMD17 → 等 R1 = 0 → 等数据令牌 0xFE → 收 512 字节（每收到一个给 O_byte_valid 一个脉冲，O_byte_idx = 0..511）→ 2 字节 CRC（丢弃）。
//   CRC：SPI 模式默认不校验 CRC（只有 CMD0/CMD8 需要正确的 CRC，固定用 0x95 / 0x87），其余命令的 CRC 字节随便填。
//
//   O_fail_code：1 CMD0 没应答（没卡 / 卡没插好）  2 CMD8 应答异常  3 ACMD41 超时  4 读扇区时 CMD17 被拒  5 读扇区等不到数据令牌
//   初始化失败后停在 O_fail=1；再给一次 I_init 脉冲可以重新初始化（比如插上卡之后）。
// =============================================================================
module mc_sd_spi #(
    parameter SLOW_DIV = 128,               // SCK 半周期的时钟数（慢速：100 MHz / (2×128) = 390 kHz）
    parameter FAST_DIV = 4                  // 快速：100 MHz / (2×4) = 12.5 MHz
)(
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_tick_1ms,

    // SD 卡引脚（SPI 模式）
    output reg         O_cs_n,
    output reg         O_sck,
    output reg         O_mosi,
    input  wire        I_miso,

    // 控制
    input  wire        I_init,              // 单周期脉冲：重新初始化（复位后自动初始化一次，不需要给）
    output reg         O_ready,             // 卡已初始化，可以读
    output reg         O_fail,              // 初始化失败
    output reg  [2:0]  O_fail_code,
    output wire        O_sdhc,              // 大容量卡

    input  wire        I_rd_start,          // 单周期脉冲：读扇区 I_lba（O_ready = 1 且 O_rd_busy = 0 时才有效）
    input  wire [31:0] I_lba,
    output wire        O_rd_busy,
    output reg         O_byte_valid,        // 收到一个数据字节
    output reg  [7:0]  O_byte,
    output reg  [8:0]  O_byte_idx,          // 字节在扇区里的序号 0 .. 511
    output reg         O_rd_done,           // 单周期脉冲：整个扇区读完
    output reg         O_rd_err             // 单周期脉冲：读失败（O_fail_code 里有原因）
);

// ---------------------------------------------------------------------------
// 字节引擎：发一个字节，同时收一个字节（SPI 模式 0：SCK 空闲低，上升沿前 MISO 稳定，这里在高电平末尾采样）
// ---------------------------------------------------------------------------
localparam [1:0] E_IDLE = 2'd0, E_LOW = 2'd1, E_HIGH = 2'd2;

reg        S_fast;
reg [1:0]  E_st;
reg [7:0]  E_cnt;
reg [2:0]  E_bit;
reg [7:0]  E_sh;
reg [7:0]  E_rx;
reg        b_go;
reg [7:0]  b_tx;
reg        b_done;
reg [7:0]  b_rx;
reg [1:0]  S_miso_s;

wire [7:0] E_half = S_fast ? FAST_DIV : SLOW_DIV;

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        E_st     <= E_IDLE;
        E_cnt    <= 8'd0;
        E_bit    <= 3'd0;
        E_sh     <= 8'd0;
        E_rx     <= 8'd0;
        O_sck    <= 1'b0;
        O_mosi   <= 1'b1;
        b_done   <= 1'b0;
        b_rx     <= 8'hFF;
        S_miso_s <= 2'b11;
    end else begin
        b_done   <= 1'b0;
        S_miso_s <= {S_miso_s[0], I_miso};
        case (E_st)
            E_IDLE: begin
                O_sck <= 1'b0;
                if (b_go) begin
                    E_sh   <= {b_tx[6:0], 1'b0};
                    O_mosi <= b_tx[7];
                    E_bit  <= 3'd0;
                    E_cnt  <= 8'd0;
                    E_st   <= E_LOW;
                end
            end
            E_LOW: begin
                if (E_cnt >= E_half - 8'd1) begin
                    E_cnt <= 8'd0;
                    O_sck <= 1'b1;
                    E_st  <= E_HIGH;
                end else E_cnt <= E_cnt + 8'd1;
            end
            default: begin                                  // E_HIGH
                if (E_cnt >= E_half - 8'd1) begin
                    E_cnt <= 8'd0;
                    O_sck <= 1'b0;
                    E_rx  <= {E_rx[6:0], S_miso_s[1]};
                    if (E_bit == 3'd7) begin
                        b_rx   <= {E_rx[6:0], S_miso_s[1]};
                        b_done <= 1'b1;
                        O_mosi <= 1'b1;
                        E_st   <= E_IDLE;
                    end else begin
                        E_bit  <= E_bit + 3'd1;
                        O_mosi <= E_sh[7];
                        E_sh   <= {E_sh[6:0], 1'b0};
                        E_st   <= E_LOW;
                    end
                end else E_cnt <= E_cnt + 8'd1;
            end
        endcase
    end
end

// ---------------------------------------------------------------------------
// 主状态机：每个"动作状态"进入时发一个字节（do_byte），字节收完后跳到 S_next，收到的字节在 S_rx 里
// ---------------------------------------------------------------------------
localparam [5:0]
    T_PWR     = 6'd0,   T_PRE     = 6'd1,   T_PRE_CHK = 6'd2,
    T_CMD0    = 6'd3,   T_CMD0_CHK= 6'd4,
    T_CMD8    = 6'd5,   T_CMD8_CHK= 6'd6,
    T_ACMD55  = 6'd7,   T_ACMD41  = 6'd8,   T_ACMD41_CHK = 6'd9,
    T_CMD58   = 6'd10,  T_CMD58_CHK = 6'd11,
    T_CMD16   = 6'd12,  T_FAST    = 6'd13,
    T_IDLE    = 6'd14,
    T_RD_CMD  = 6'd15,  T_RD_R1CHK= 6'd16,  T_RD_TOK = 6'd17,  T_RD_TOKCHK = 6'd18,
    T_RD_DAT  = 6'd19,  T_RD_DATCHK = 6'd20,T_RD_CRC1 = 6'd21, T_RD_CRC2 = 6'd22,
    T_RD_END  = 6'd23,  T_RD_END2 = 6'd24,  T_RD_ERR = 6'd25,  T_RD_ERR2 = 6'd26,
    T_FAIL    = 6'd27,
    // 命令子流程
    C_START   = 6'd32,  C_WRDY    = 6'd33,  C_WRDY_CHK = 6'd34,
    C_B0      = 6'd35,  C_B1      = 6'd36,  C_B2 = 6'd37, C_B3 = 6'd38, C_B4 = 6'd39, C_B5 = 6'd40,
    C_R1      = 6'd41,  C_R1_CHK  = 6'd42,  C_EX = 6'd43, C_EX_CHK = 6'd44,
    C_END     = 6'd45,  C_END2    = 6'd46;

reg [5:0]  S_st, S_next, S_ret;
reg        S_wait_b;
reg [7:0]  S_rx;
reg [5:0]  S_cidx;
reg [31:0] S_carg;
reg [7:0]  S_ccrc;
reg [2:0]  S_cexn;
reg        S_keep_cs;
reg [7:0]  S_r1;
reg [31:0] S_extra;
reg [17:0] S_poll;
reg [7:0]  S_try;
reg [11:0] S_ms;
reg [11:0] S_to;                            // ACMD41 超时计时（毫秒）
reg        S_hcs;
reg        S_sdhc;
reg [3:0]  S_pre_n;
reg [8:0]  S_bidx;                          // 下一个要发出去的数据字节序号
reg [31:0] S_lba;
reg        S_init_pend;

assign O_sdhc    = S_sdhc;
assign O_rd_busy = (S_st != T_IDLE) && (S_st != T_FAIL);

task do_byte;
    input [7:0] tx;
    input [5:0] nxt;
    begin
        b_tx     <= tx;
        b_go     <= 1'b1;
        S_wait_b <= 1'b1;
        S_next   <= nxt;
    end
endtask

task start_cmd;
    input [5:0]  idx;
    input [31:0] arg;
    input [7:0]  crc;
    input [2:0]  exn;
    input        keep;
    input [5:0]  ret;
    begin
        S_cidx    <= idx;
        S_carg    <= arg;
        S_ccrc    <= crc;
        S_cexn    <= exn;
        S_keep_cs <= keep;
        S_ret     <= ret;
        S_st      <= C_START;
    end
endtask

task fail;
    input [2:0] code;
    begin
        O_fail      <= 1'b1;
        O_fail_code <= code;
        O_ready     <= 1'b0;
        O_cs_n      <= 1'b1;
        S_st        <= T_FAIL;
    end
endtask

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        S_st         <= T_PWR;
        S_next       <= T_PWR;
        S_ret        <= T_IDLE;
        S_wait_b     <= 1'b0;
        S_rx         <= 8'hFF;
        S_fast       <= 1'b0;
        b_go         <= 1'b0;
        b_tx         <= 8'hFF;
        O_cs_n       <= 1'b1;
        O_ready      <= 1'b0;
        O_fail       <= 1'b0;
        O_fail_code  <= 3'd0;
        O_byte_valid <= 1'b0;
        O_byte       <= 8'd0;
        O_byte_idx   <= 9'd0;
        O_rd_done    <= 1'b0;
        O_rd_err     <= 1'b0;
        S_ms         <= 12'd0;
        S_to         <= 12'd0;
        S_hcs        <= 1'b0;
        S_sdhc       <= 1'b0;
        S_try        <= 8'd0;
        S_poll       <= 18'd0;
        S_init_pend  <= 1'b0;
        S_pre_n      <= 4'd0;
        S_bidx       <= 9'd0;
        S_lba        <= 32'd0;
        S_r1         <= 8'hFF;
        S_extra      <= 32'd0;
        S_cidx       <= 6'd0;
        S_carg       <= 32'd0;
        S_ccrc       <= 8'd0;
        S_cexn       <= 3'd0;
        S_keep_cs    <= 1'b0;
    end else begin
        b_go         <= 1'b0;
        O_byte_valid <= 1'b0;
        O_rd_done    <= 1'b0;
        O_rd_err     <= 1'b0;
        if (I_init) S_init_pend <= 1'b1;
        if (I_tick_1ms && S_to != 12'hFFF) S_to <= S_to + 12'd1;

        if (S_wait_b) begin
            if (b_done) begin
                S_wait_b <= 1'b0;
                S_st     <= S_next;
                S_rx     <= b_rx;
            end
        end else begin
            case (S_st)
                // ------------------------- 上电 / 初始化 -------------------------
                T_PWR: begin                                        // 等 2 ms，CS 高
                    O_cs_n <= 1'b1;
                    S_fast <= 1'b0;
                    if (I_tick_1ms) begin
                        if (S_ms >= 12'd1) begin S_ms <= 12'd0; S_pre_n <= 4'd10; S_st <= T_PRE; end
                        else S_ms <= S_ms + 12'd1;
                    end
                end
                T_PRE: begin do_byte(8'hFF, T_PRE_CHK); end         // CS 高，发 10 个 0xFF = 80 个时钟
                T_PRE_CHK: begin
                    if (S_pre_n == 4'd1) begin S_try <= 8'd0; S_ms <= 12'd0; S_init_pend <= 1'b0; S_st <= T_CMD0; end
                    else begin S_pre_n <= S_pre_n - 4'd1; S_st <= T_PRE; end
                end
                T_CMD0: start_cmd(6'd0, 32'd0, 8'h95, 3'd0, 1'b0, T_CMD0_CHK);
                T_CMD0_CHK: begin
                    if (S_r1 == 8'h01) S_st <= T_CMD8;
                    else if (S_try >= 8'd20) fail(3'd1);
                    else begin S_try <= S_try + 8'd1; S_st <= T_CMD0; end
                end
                T_CMD8: start_cmd(6'd8, 32'h0000_01AA, 8'h87, 3'd4, 1'b0, T_CMD8_CHK);
                T_CMD8_CHK: begin
                    S_to <= 12'd0;                                  // ACMD41 超时从这里开始算
                    if (S_r1 == 8'h01 && S_extra[11:0] == 12'h1AA) begin S_hcs <= 1'b1; S_st <= T_ACMD55; end
                    else if (S_r1[2])                              begin S_hcs <= 1'b0; S_st <= T_ACMD55; end   // v1 卡：CMD8 非法命令
                    else fail(3'd2);
                end
                T_ACMD55: start_cmd(6'd55, 32'd0, 8'h65, 3'd0, 1'b0, T_ACMD41);
                T_ACMD41: start_cmd(6'd41, S_hcs ? 32'h4000_0000 : 32'd0, 8'h77, 3'd0, 1'b0, T_ACMD41_CHK);
                T_ACMD41_CHK: begin
                    if (S_r1 == 8'h00) S_st <= T_CMD58;
                    else if (S_to >= 12'd1500) fail(3'd3);
                    else S_st <= T_ACMD55;
                end
                T_CMD58: start_cmd(6'd58, 32'd0, 8'hFD, 3'd4, 1'b0, T_CMD58_CHK);
                T_CMD58_CHK: begin
                    S_sdhc <= S_extra[30];
                    if (S_extra[30]) S_st <= T_FAST;
                    else             S_st <= T_CMD16;
                end
                T_CMD16: start_cmd(6'd16, 32'd512, 8'h15, 3'd0, 1'b0, T_FAST);
                T_FAST: begin
                    S_fast  <= 1'b1;
                    O_ready <= 1'b1;
                    O_fail  <= 1'b0;
                    S_st    <= T_IDLE;
                end

                // ------------------------- 空闲：等读命令 -------------------------
                T_IDLE: begin
                    if (S_init_pend) begin                          // 重新初始化
                        O_ready <= 1'b0; S_ms <= 12'd0; S_st <= T_PWR; S_init_pend <= 1'b0;
                    end else if (I_rd_start) begin
                        S_lba <= I_lba;
                        S_st  <= T_RD_CMD;
                    end
                end
                T_FAIL: begin
                    if (S_init_pend) begin O_fail <= 1'b0; S_ms <= 12'd0; S_st <= T_PWR; S_init_pend <= 1'b0; end
                end

                // ------------------------- 读一个扇区 -------------------------
                T_RD_CMD: start_cmd(6'd17, S_sdhc ? S_lba : {S_lba[22:0], 9'd0}, 8'hFF, 3'd0, 1'b1, T_RD_R1CHK);
                T_RD_R1CHK: begin
                    if (S_r1 != 8'h00) begin O_fail_code <= 3'd4; S_st <= T_RD_ERR; end
                    else begin S_poll <= 18'd200000; S_st <= T_RD_TOK; end        // 等令牌最多约 130 ms
                end
                T_RD_TOK: do_byte(8'hFF, T_RD_TOKCHK);
                T_RD_TOKCHK: begin
                    if (S_rx == 8'hFE) begin S_bidx <= 9'd0; S_st <= T_RD_DAT; end
                    else if (S_rx == 8'hFF && S_poll != 18'd0) begin S_poll <= S_poll - 18'd1; S_st <= T_RD_TOK; end
                    else begin O_fail_code <= 3'd5; S_st <= T_RD_ERR; end
                end
                T_RD_DAT: do_byte(8'hFF, T_RD_DATCHK);
                T_RD_DATCHK: begin
                    O_byte_valid <= 1'b1;
                    O_byte       <= S_rx;
                    O_byte_idx   <= S_bidx;                         // 序号和字节同一拍给出
                    if (S_bidx == 9'd511) S_st <= T_RD_CRC1;
                    else begin S_bidx <= S_bidx + 9'd1; S_st <= T_RD_DAT; end
                end
                T_RD_CRC1: do_byte(8'hFF, T_RD_CRC2);
                T_RD_CRC2: do_byte(8'hFF, T_RD_END);
                T_RD_END: begin O_cs_n <= 1'b1; do_byte(8'hFF, T_RD_END2); end    // CS 拉高后再给 8 个时钟，让卡收尾
                T_RD_END2: begin O_rd_done <= 1'b1; S_st <= T_IDLE; end
                T_RD_ERR:  begin O_cs_n <= 1'b1; do_byte(8'hFF, T_RD_ERR2); end
                T_RD_ERR2: begin O_rd_err <= 1'b1; S_st <= T_IDLE; end

                // ------------------------- 命令子流程：发 6 字节 → 等 R1 → 收额外字节 → 收尾 -------------------------
                C_START: begin O_cs_n <= 1'b0; S_poll <= 18'd65535; S_st <= C_WRDY; end
                C_WRDY:  do_byte(8'hFF, C_WRDY_CHK);               // 先等卡不忙（MISO 回到 0xFF）
                C_WRDY_CHK: begin
                    if (S_rx == 8'hFF || S_poll == 18'd0) S_st <= C_B0;
                    else begin S_poll <= S_poll - 18'd1; S_st <= C_WRDY; end
                end
                C_B0: do_byte({2'b01, S_cidx}, C_B1);
                C_B1: do_byte(S_carg[31:24], C_B2);
                C_B2: do_byte(S_carg[23:16], C_B3);
                C_B3: do_byte(S_carg[15:8],  C_B4);
                C_B4: do_byte(S_carg[7:0],   C_B5);
                C_B5: begin S_poll <= 18'd16; do_byte(S_ccrc, C_R1); end
                C_R1: do_byte(8'hFF, C_R1_CHK);
                C_R1_CHK: begin
                    if (S_rx != 8'hFF) begin
                        S_r1 <= S_rx;
                        S_extra <= 32'd0;
                        if (S_cexn != 3'd0) S_st <= C_EX; else S_st <= C_END;
                    end else if (S_poll == 18'd0) begin
                        S_r1 <= 8'hFF;                              // 超时：没有应答
                        S_st <= C_END;
                    end else begin S_poll <= S_poll - 18'd1; S_st <= C_R1; end
                end
                C_EX: do_byte(8'hFF, C_EX_CHK);
                C_EX_CHK: begin
                    S_extra <= {S_extra[23:0], S_rx};
                    if (S_cexn == 3'd1) S_st <= C_END;
                    else begin S_cexn <= S_cexn - 3'd1; S_st <= C_EX; end
                end
                C_END: begin
                    if (S_keep_cs) S_st <= S_ret;                   // 读命令：CS 保持低，继续收数据
                    else begin O_cs_n <= 1'b1; do_byte(8'hFF, C_END2); end
                end
                C_END2: S_st <= S_ret;

                default: S_st <= T_PWR;
            endcase
        end
    end
end

endmodule
