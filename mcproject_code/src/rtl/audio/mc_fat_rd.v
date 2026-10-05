`timescale 1ns / 1ps
// =============================================================================
// mc_fat_rd.v  读一个文件：按 mc_fat_dir 的目录表找到文件的起始簇和大小，沿 FAT 簇链一个扇区一个扇区地读，
//              把文件内容一个字节一个字节地送出来（背景音乐、音效各用一个）
//
//   取数接口：I_open + I_clip 打开第 N 首；之后每个扇区读好就把数据字节一个一个送出（O_data_valid / O_data），共"文件大小"个字节，
//   最后给 O_eof 一个脉冲。I_space_ok = 1（外面的缓冲区有 ≥ 512 字节空位）时才读下一个扇区。I_close 中途放弃
//   （O_active 在已经读了一半的那个扇区读完、真正停下以后才落下）。
//   换簇时去读 FAT 表找下一个簇（碎片化的文件也能读）。打开错误（O_open_err 脉冲，O_err_code：1 没有这个编号  4 读卡错误）。
//   没挂载好（目录表是空的）就打开：同样报"没有这个编号"。
// =============================================================================
module mc_fat_rd (
    input  wire        I_clk,
    input  wire        I_rst_n,

    // ---- 读扇区口（接 mc_sd_arb）----
    output reg         O_rd_start,
    output reg  [31:0] O_lba,
    input  wire        I_rd_busy,
    input  wire        I_byte_valid,
    input  wire [7:0]  I_byte,
    input  wire [8:0]  I_byte_idx,
    input  wire        I_rd_done,
    input  wire        I_rd_err,

    // ---- 目录信息（来自 mc_fat_dir）----
    input  wire [31:0] I_fat_lba,
    input  wire [31:0] I_data_lba,
    input  wire [7:0]  I_spc,
    input  wire [2:0]  I_spc_log,
    input  wire [63:0] I_present,
    output reg  [5:0]  O_q_addr,            // 查目录表：编号 - 1
    input  wire [27:0] I_q_cl,              //   起始簇（地址给出后第 2 拍有效）
    input  wire [31:0] I_q_sz,              //   文件大小

    // ---- 打开 + 取数 ----
    input  wire        I_open,              // 单周期脉冲，I_clip = 1 .. 64
    input  wire [6:0]  I_clip,
    input  wire        I_close,             // 单周期脉冲：放弃当前文件
    output reg         O_open_err,          // 单周期脉冲：打不开（O_err_code：1 没有这个编号  4 读卡错误）
    output reg  [2:0]  O_err_code,
    output reg         O_data_valid,
    output reg  [7:0]  O_data,
    input  wire        I_space_ok,
    output reg         O_eof,               // 单周期脉冲：文件内容全部送完
    output wire        O_active             // 正在打开 / 送数据
);

localparam N_CLIPS = 64;

localparam [3:0]
    ST_IDLE = 4'd0,    ST_ISSUE = 4'd1,   ST_LOOK1 = 4'd2,   ST_LOOK2 = 4'd3,  ST_STR_CHK = 4'd4,
    ST_STR_RD = 4'd5,  ST_STR_W = 4'd6,   ST_NEXT = 4'd7,    ST_FAT_RD = 4'd8, ST_FAT_W = 4'd9;

reg [3:0]  S_st;
reg        S_ret_fat;                       // ISSUE 发出读扇区命令以后去哪：1 = 读 FAT 表，0 = 读文件数据
reg [31:0] S_lba_req;

reg [31:0] S_cl;                            // 文件当前簇
reg [7:0]  S_sec;                           // 簇内第几个扇区
reg [27:0] S_nx;                            // FAT 表查询结果（下一个簇）
reg [31:0] S_left;                          // 文件还剩多少字节没送
reg        S_abort;
reg        S_opening;                       // 从接受 I_open 到文件送完 / 出错 / 被关闭

assign O_active = S_opening;

// 簇号 → 该簇第 0 个扇区的 LBA
wire [31:0] S_cl_lba = I_data_lba + ((S_cl - 32'd2) << I_spc_log);

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        S_st         <= ST_IDLE;
        S_ret_fat    <= 1'b0;
        O_rd_start   <= 1'b0;
        O_lba        <= 32'd0;
        S_lba_req    <= 32'd0;
        O_open_err   <= 1'b0;
        O_err_code   <= 3'd0;
        O_data_valid <= 1'b0;
        O_data       <= 8'd0;
        O_eof        <= 1'b0;
        S_abort      <= 1'b0;
        S_opening    <= 1'b0;
        S_left       <= 32'd0;
        S_cl         <= 32'd0;
        S_sec        <= 8'd0;
        O_q_addr     <= 6'd0;
    end else begin
        O_rd_start   <= 1'b0;
        O_open_err   <= 1'b0;
        O_data_valid <= 1'b0;
        O_eof        <= 1'b0;
        if (I_close) S_abort <= 1'b1;

        // ------------------------------------------------------------------
        // 流式抓取：每来一个字节，按所在状态处理
        // ------------------------------------------------------------------
        if (I_byte_valid) begin
            case (S_st)
                ST_FAT_W: begin                             // FAT 表：取这个簇对应的 4 字节
                    if (I_byte_idx[8:2] == S_cl[6:0]) begin
                        case (I_byte_idx[1:0])
                            2'd0: S_nx[7:0]   <= I_byte;
                            2'd1: S_nx[15:8]  <= I_byte;
                            2'd2: S_nx[23:16] <= I_byte;
                            default: S_nx[27:24] <= I_byte[3:0];
                        endcase
                    end
                end

                ST_STR_W: begin                             // 文件数据：送出去（只送文件大小那么多字节）
                    if (S_left != 32'd0 && !S_abort) begin
                        O_data_valid <= 1'b1;
                        O_data       <= I_byte;
                        S_left       <= S_left - 32'd1;
                    end
                end
                default: ;
            endcase
        end

        // ------------------------------------------------------------------
        // 状态机
        // ------------------------------------------------------------------
        case (S_st)
            ST_IDLE: begin
                S_abort <= 1'b0;                            // 空闲时的关闭命令没有意义
                if (I_open) begin
                    S_opening <= 1'b1;
                    if (I_clip == 7'd0 || I_clip > N_CLIPS || !I_present[I_clip - 7'd1]) begin
                        O_open_err <= 1'b1; O_err_code <= 3'd1; S_opening <= 1'b0;
                    end else begin
                        O_q_addr <= I_clip[5:0] - 6'd1;
                        S_st <= ST_LOOK1;
                    end
                end
            end

            ST_ISSUE: begin                                 // 发"读扇区"命令（等读扇区口空闲）
                if (!I_rd_busy) begin
                    O_lba      <= S_lba_req;
                    O_rd_start <= 1'b1;
                    S_st       <= S_ret_fat ? ST_FAT_W : ST_STR_W;
                end
            end

            ST_LOOK1: S_st <= ST_LOOK2;                     // 目录表 RAM 读要一拍
            ST_LOOK2: begin
                S_cl   <= {4'd0, I_q_cl};
                S_left <= I_q_sz;
                S_sec  <= 8'd0;
                S_st   <= ST_STR_CHK;
            end

            // ---- 取数：一个扇区一个扇区地读 ----
            ST_STR_CHK: begin
                if (S_abort) begin S_opening <= 1'b0; S_st <= ST_IDLE; end
                else if (S_left == 32'd0) begin O_eof <= 1'b1; S_opening <= 1'b0; S_st <= ST_IDLE; end
                else if (I_space_ok) S_st <= ST_STR_RD;
            end
            ST_STR_RD: begin
                S_lba_req <= S_cl_lba + {24'd0, S_sec};
                S_ret_fat <= 1'b0;
                S_st      <= ST_ISSUE;
            end
            ST_STR_W: begin
                if (I_rd_err) begin O_open_err <= 1'b1; O_err_code <= 3'd4; S_opening <= 1'b0; S_st <= ST_IDLE; end
                else if (I_rd_done) S_st <= ST_NEXT;
            end
            ST_NEXT: begin
                if (S_abort) begin S_opening <= 1'b0; S_st <= ST_IDLE; end
                else if (S_left == 32'd0) begin O_eof <= 1'b1; S_opening <= 1'b0; S_st <= ST_IDLE; end
                else if (S_sec == I_spc - 8'd1) S_st <= ST_FAT_RD;      // 簇用完：查下一个簇
                else begin S_sec <= S_sec + 8'd1; S_st <= ST_STR_CHK; end
            end

            // ---- 查 FAT 表：S_cl 的下一个簇 ----
            ST_FAT_RD: begin
                S_lba_req <= I_fat_lba + {25'd0, S_cl[31:7]};
                S_ret_fat <= 1'b1;
                S_st      <= ST_ISSUE;
            end
            ST_FAT_W: begin
                if (I_rd_err) begin O_open_err <= 1'b1; O_err_code <= 3'd4; S_opening <= 1'b0; S_st <= ST_IDLE; end
                else if (I_rd_done) begin
                    if (S_nx >= 28'hFFFFFF8 || S_nx < 28'd2) begin O_eof <= 1'b1; S_opening <= 1'b0; S_st <= ST_IDLE; end   // 簇链提前结束
                    else begin S_cl <= {4'd0, S_nx}; S_sec <= 8'd0; S_st <= ST_STR_CHK; end
                end
            end

            default: S_st <= ST_IDLE;
        endcase
    end
end

endmodule
