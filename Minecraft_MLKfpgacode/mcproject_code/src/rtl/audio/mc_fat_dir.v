`timescale 1ns / 1ps
// =============================================================================
// mc_fat_dir.v  FAT32 的"挂载 + 扫根目录 + 目录表"。背景音乐和音效两路读文件模块（mc_fat_rd）共用这一份：上电后只扫一遍卡。
//
//   在 TF 卡根目录放 1.wav、2.wav、…（文件名是数字，最大 64 个；"01.wav" 和 "1.wav" 都算第 1 首）。长文件名项、
//   已删除项、子目录、卷标、名字不是数字的文件，一律跳过。只支持 FAT32（卡 ≤ 32 GB 默认格式；64 GB 以上默认是 exFAT，不行）；
//   扇区 512 字节，每簇扇区数 1 ~ 128，FAT 份数 1 或 2；带 MBR 分区表（第 1 个分区，类型 0x0B / 0x0C）或没有分区表（整盘一个卷）都行。
//
//   做法全是"流式"：mc_sd_spi 把扇区的 512 个字节一个一个送过来（I_byte_valid / I_byte / I_byte_idx），这里在字节流经过的时候
//   抓需要的字段（引导扇区参数、目录项的文件名 / 起始簇 / 大小、FAT 表项），不需要再存一份扇区缓冲。
//   挂载完成（O_mounted）以后给读文件模块用的东西：
//     · 目录表：每个编号对应的 {文件大小, 起始簇}，存在小 RAM 里（64 项）。读文件模块每路一个读口（两份内容一样的 RAM，各读各的，
//       不用排队）；O_present 的第 N-1 位 = 有没有 N.wav；
//     · FAT 表和数据区的起始扇区、每簇扇区数。
// =============================================================================
module mc_fat_dir (
    input  wire        I_clk,
    input  wire        I_rst_n,

    // ---- 读扇区口（只在挂载期间用；mc_fat32 把它接到 0 号读扇区口）----
    input  wire        I_sd_ready,
    input  wire        I_sd_fail,
    output reg         O_rd_start,
    output reg  [31:0] O_lba,
    input  wire        I_rd_busy,
    input  wire        I_byte_valid,
    input  wire [7:0]  I_byte,
    input  wire [8:0]  I_byte_idx,
    input  wire        I_rd_done,
    input  wire        I_rd_err,

    // ---- 挂载状态 ----
    output reg         O_mounted,           // 卷已识别、目录已扫完
    output reg         O_mount_fail,
    output reg  [2:0]  O_mount_code,        // 1 没有 FAT32  2 引导扇区不对  3 簇/FAT 参数不支持  4 读卡错误
    output reg  [7:0]  O_nclips,            // 找到的 N.wav 个数

    // ---- 给读文件模块的共用信息（挂载完成以后有效）----
    output reg  [31:0] O_fat_lba,           // FAT 表的第一个扇区
    output reg  [31:0] O_data_lba,          // 数据区（第 2 簇）的第一个扇区
    output wire [7:0]  O_spc,               // 每簇扇区数
    output reg  [2:0]  O_spc_log,           // log2(每簇扇区数)
    output reg  [63:0] O_present,           // 第 N-1 位 = 有 N.wav
    input  wire [5:0]  I_q_addr0,           // 目录表读口 0 / 1：地址 = 编号 - 1，下一拍给出数据
    output wire [27:0] O_q_cl0,             //   起始簇
    output wire [31:0] O_q_sz0,             //   文件大小（字节）
    input  wire [5:0]  I_q_addr1,
    output wire [27:0] O_q_cl1,
    output wire [31:0] O_q_sz1
);

localparam N_CLIPS = 64;

localparam [3:0]
    ST_WAIT_SD = 4'd0, ST_ISSUE = 4'd1,  ST_RD0_W = 4'd2,   ST_RDV_W = 4'd3, ST_CALC = 4'd4, ST_SCAN_RD = 4'd5,
    ST_SCAN_W  = 4'd6, ST_FAT_RD = 4'd7, ST_FAT_W = 4'd8,   ST_IDLE = 4'd9,  ST_FAIL = 4'd10;

reg [3:0]  S_st;
reg [3:0]  S_ret;                           // ISSUE 发出读扇区命令以后去哪
reg [31:0] S_lba_req;

// ---- 引导扇区 / 分区表参数（流式抓取）----
reg [7:0]  S_b0;
reg [15:0] S_bps;
reg [7:0]  S_spc;
reg [15:0] S_resv;
reg [7:0]  S_nfats;
reg [31:0] S_fatsz;
reg [7:0]  S_ptype;
reg [31:0] S_part_lba;                      // 分区的起始扇区：第 0 扇区的分区表里取；没有分区表就是 0
reg [7:0]  S_sig0, S_sig1;

// ---- 目录扫描 ----
reg [31:0] S_cl;                            // 挂载时 = 根目录起始簇（引导扇区里取）；扫描时 = 当前簇
reg [7:0]  S_sec;                           // 簇内第几个扇区
reg [9:0]  S_scanned;                       // 已扫扇区数（保险）
reg        S_dir_end;
reg [7:0]  S_e0;
reg [7:0]  S_attr;
reg [9:0]  S_num;
reg [1:0]  S_nd;
reg        S_ns, S_bad;
reg [23:0] S_ext;
reg [15:0] S_cl_hi, S_cl_lo;
reg [23:0] S_sz_lo;

// ---- 目录表：编号 → {大小, 起始簇}。两份内容一样的 RAM，每路读文件模块读自己的一份 ----
reg [59:0] S_tab0 [0:63];
reg [59:0] S_tab1 [0:63];
reg        S_tab_we;
reg [5:0]  S_tab_waddr;
reg [59:0] S_tab_wdata;
reg [59:0] S_q0, S_q1;
always @(posedge I_clk) begin
    if (S_tab_we) begin
        S_tab0[S_tab_waddr] <= S_tab_wdata;
        S_tab1[S_tab_waddr] <= S_tab_wdata;
    end
    S_q0 <= S_tab0[I_q_addr0];
    S_q1 <= S_tab1[I_q_addr1];
end
assign O_q_cl0 = S_q0[27:0];
assign O_q_sz0 = S_q0[59:28];
assign O_q_cl1 = S_q1[27:0];
assign O_q_sz1 = S_q1[59:28];

// ---- FAT 表查询（目录占了不止一个簇时沿簇链找）----
reg [27:0] S_nx;

assign O_spc = S_spc;

wire [4:0] S_e   = I_byte_idx[4:0];
wire       S_e_first = (S_e == 5'd0);

function [2:0] log2spc;
    input [7:0] v;
    begin
        case (v)
            8'd1:   log2spc = 3'd0;
            8'd2:   log2spc = 3'd1;
            8'd4:   log2spc = 3'd2;
            8'd8:   log2spc = 3'd3;
            8'd16:  log2spc = 3'd4;
            8'd32:  log2spc = 3'd5;
            8'd64:  log2spc = 3'd6;
            default: log2spc = 3'd7;           // 128
        endcase
    end
endfunction
wire S_spc_ok = (S_spc == 8'd1) || (S_spc == 8'd2) || (S_spc == 8'd4) || (S_spc == 8'd8) ||
                (S_spc == 8'd16) || (S_spc == 8'd32) || (S_spc == 8'd64) || (S_spc == 8'd128);

// 簇号 → 该簇第 0 个扇区的 LBA
wire [31:0] S_cl_lba = O_data_lba + ((S_cl - 32'd2) << O_spc_log);

// 目录项文件名里数字的解析（组合：下一状态值）
wire [9:0] S_num_b = S_e_first ? 10'd0 : S_num;
wire [1:0] S_nd_b  = S_e_first ? 2'd0  : S_nd;
wire       S_ns_b  = S_e_first ? 1'b0  : S_ns;
wire       S_bad_b = S_e_first ? 1'b0  : S_bad;
wire       S_is_digit = (I_byte >= 8'h30) && (I_byte <= 8'h39);
wire [9:0] S_num_n = {S_num_b[6:0], 3'b000} + {S_num_b[8:0], 1'b0} + {6'd0, I_byte[3:0]};    // num*10 + digit

wire S_ent_valid_name = !S_bad_b && S_ns_b && (S_nd_b != 2'd0);         // 数字 + 空格填充，至少 1 位数字
wire S_ent_in_range   = (S_num != 10'd0) && (S_num <= N_CLIPS);
// 一个目录项是不是"我们要的 N.WAV"：不是已删除项、不是长文件名项、不是子目录/卷标，扩展名 WAV，名字是 1~64 的数字，起始簇非 0
wire S_ent_ok = (S_e0 != 8'hE5) && (S_attr != 8'h0F) && ((S_attr & 8'h18) == 8'h00) && (S_ext == "WAV") &&
                S_ent_valid_name && S_ent_in_range && ({S_cl_hi, S_cl_lo} != 32'd0);

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        S_st         <= ST_WAIT_SD;
        S_ret        <= ST_IDLE;
        O_rd_start   <= 1'b0;
        O_lba        <= 32'd0;
        S_lba_req    <= 32'd0;
        O_mounted    <= 1'b0;
        O_mount_fail <= 1'b0;
        O_mount_code <= 3'd0;
        O_nclips     <= 8'd0;
        O_present    <= 64'd0;
        S_tab_we     <= 1'b0;
        S_cl         <= 32'd0;
        S_sec        <= 8'd0;
        S_scanned    <= 10'd0;
        S_dir_end    <= 1'b0;
    end else begin
        O_rd_start   <= 1'b0;
        S_tab_we     <= 1'b0;

        // ------------------------------------------------------------------
        // 流式抓取：每来一个字节，按所在状态记下需要的字段
        // ------------------------------------------------------------------
        if (I_byte_valid) begin
            case (S_st)
                ST_RD0_W, ST_RDV_W: begin                   // 分区表 / 引导扇区
                    case (I_byte_idx)
                        9'd0:   S_b0 <= I_byte;
                        9'd11:  S_bps[7:0] <= I_byte;
                        9'd12:  S_bps[15:8] <= I_byte;
                        9'd13:  S_spc <= I_byte;
                        9'd14:  S_resv[7:0] <= I_byte;
                        9'd15:  S_resv[15:8] <= I_byte;
                        9'd16:  S_nfats <= I_byte;
                        9'd36:  S_fatsz[7:0] <= I_byte;
                        9'd37:  S_fatsz[15:8] <= I_byte;
                        9'd38:  S_fatsz[23:16] <= I_byte;
                        9'd39:  S_fatsz[31:24] <= I_byte;
                        9'd44:  S_cl[7:0] <= I_byte;        // 根目录起始簇
                        9'd45:  S_cl[15:8] <= I_byte;
                        9'd46:  S_cl[23:16] <= I_byte;
                        9'd47:  S_cl[31:24] <= I_byte;
                        9'd450: S_ptype <= I_byte;
                        9'd510: S_sig0 <= I_byte;
                        9'd511: S_sig1 <= I_byte;
                        default: ;
                    endcase
                    if (S_st == ST_RD0_W) begin             // 分区起始扇区：只在第 0 扇区（分区表）里取
                        case (I_byte_idx)
                            9'd454: S_part_lba[7:0]   <= I_byte;
                            9'd455: S_part_lba[15:8]  <= I_byte;
                            9'd456: S_part_lba[23:16] <= I_byte;
                            9'd457: S_part_lba[31:24] <= I_byte;
                            default: ;
                        endcase
                    end
                end

                ST_SCAN_W: begin                            // 根目录：每 32 字节一项
                    if (S_e <= 5'd7) begin                  // 文件名前 8 字节：数字 + 空格填充
                        if (S_e_first) S_e0 <= I_byte;
                        if (S_ns_b) begin
                            S_ns <= 1'b1; S_nd <= S_nd_b; S_num <= S_num_b;
                            S_bad <= S_bad_b | (I_byte != 8'h20);
                        end else if (S_is_digit) begin
                            S_ns <= 1'b0;
                            S_nd <= (S_nd_b == 2'd3) ? 2'd3 : (S_nd_b + 2'd1);
                            S_num <= S_num_n;
                            S_bad <= S_bad_b | (S_nd_b == 2'd3);            // 超过 3 位
                        end else if (I_byte == 8'h20 && S_nd_b != 2'd0) begin
                            S_ns <= 1'b1; S_nd <= S_nd_b; S_num <= S_num_b; S_bad <= S_bad_b;
                        end else begin
                            S_ns <= S_ns_b; S_nd <= S_nd_b; S_num <= S_num_b; S_bad <= 1'b1;
                        end
                    end else if (S_e <= 5'd10) S_ext <= {S_ext[15:0], I_byte};
                    else if (S_e == 5'd11) S_attr <= I_byte;
                    else if (S_e == 5'd20) S_cl_hi[7:0] <= I_byte;
                    else if (S_e == 5'd21) S_cl_hi[15:8] <= I_byte;
                    else if (S_e == 5'd26) S_cl_lo[7:0] <= I_byte;
                    else if (S_e == 5'd27) S_cl_lo[15:8] <= I_byte;
                    else if (S_e == 5'd28) S_sz_lo[7:0] <= I_byte;
                    else if (S_e == 5'd29) S_sz_lo[15:8] <= I_byte;
                    else if (S_e == 5'd30) S_sz_lo[23:16] <= I_byte;
                    else if (S_e == 5'd31) begin             // 一项收完：判断
                        if (S_e0 == 8'h00) S_dir_end <= 1'b1;
                        else if (S_ent_ok) begin
                            S_tab_we    <= 1'b1;
                            S_tab_waddr <= S_num[5:0] - 6'd1;
                            S_tab_wdata <= {I_byte, S_sz_lo, S_cl_hi[11:0], S_cl_lo};   // {大小 32 位, 起始簇 28 位}
                            if (!O_present[S_num[5:0] - 6'd1]) begin
                                O_present[S_num[5:0] - 6'd1] <= 1'b1;
                                O_nclips <= O_nclips + 8'd1;
                            end
                        end
                    end
                end

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
                default: ;
            endcase
        end

        // ------------------------------------------------------------------
        // 状态机
        // ------------------------------------------------------------------
        case (S_st)
            ST_WAIT_SD: begin                               // 等卡初始化好
                if (I_sd_ready) begin S_lba_req <= 32'd0; S_ret <= ST_RD0_W; S_st <= ST_ISSUE; end
                else if (I_sd_fail) begin O_mount_fail <= 1'b1; O_mount_code <= 3'd4; S_st <= ST_FAIL; end
            end

            ST_ISSUE: begin                                 // 发"读扇区"命令（等 SD 控制器空闲）
                if (!I_rd_busy) begin
                    O_lba      <= S_lba_req;
                    O_rd_start <= 1'b1;
                    S_st       <= S_ret;
                end
            end

            // ---- 第 0 扇区：分区表或引导扇区 ----
            ST_RD0_W: begin
                if (I_rd_err) begin O_mount_fail <= 1'b1; O_mount_code <= 3'd4; S_st <= ST_FAIL; end
                else if (I_rd_done) begin
                    if (S_sig0 == 8'h55 && S_sig1 == 8'hAA && (S_b0 == 8'hEB || S_b0 == 8'hE9) && S_bps == 16'd512 && S_fatsz != 32'd0) begin
                        S_part_lba <= 32'd0;                // 没有分区表：整盘一个卷，引导扇区就是第 0 扇区
                        S_st       <= ST_CALC;
                    end else if (S_sig0 == 8'h55 && S_sig1 == 8'hAA && (S_ptype == 8'h0B || S_ptype == 8'h0C)) begin
                        S_lba_req  <= S_part_lba;           // 分区表里的分区起始扇区（已经抓到 S_part_lba）
                        S_ret      <= ST_RDV_W;
                        S_st       <= ST_ISSUE;
                    end else begin
                        O_mount_fail <= 1'b1; O_mount_code <= 3'd1; S_st <= ST_FAIL;
                    end
                end
            end

            // ---- 分区的引导扇区 ----
            ST_RDV_W: begin
                if (I_rd_err) begin O_mount_fail <= 1'b1; O_mount_code <= 3'd4; S_st <= ST_FAIL; end
                else if (I_rd_done) begin
                    if (S_sig0 == 8'h55 && S_sig1 == 8'hAA && S_bps == 16'd512 && S_fatsz != 32'd0) S_st <= ST_CALC;
                    else begin O_mount_fail <= 1'b1; O_mount_code <= 3'd2; S_st <= ST_FAIL; end
                end
            end

            ST_CALC: begin
                if (!S_spc_ok || (S_nfats != 8'd1 && S_nfats != 8'd2) || S_cl < 32'd2) begin
                    O_mount_fail <= 1'b1; O_mount_code <= 3'd3; S_st <= ST_FAIL;
                end else begin
                    O_fat_lba  <= S_part_lba + {16'd0, S_resv};
                    O_data_lba <= S_part_lba + {16'd0, S_resv} + S_fatsz + ((S_nfats == 8'd2) ? S_fatsz : 32'd0);
                    O_spc_log  <= log2spc(S_spc);
                    S_sec      <= 8'd0;
                    S_scanned  <= 10'd0;
                    S_dir_end  <= 1'b0;
                    S_st       <= ST_SCAN_RD;
                end
            end

            // ---- 扫描根目录 ----
            ST_SCAN_RD: begin
                S_lba_req <= S_cl_lba + {24'd0, S_sec};
                S_ret     <= ST_SCAN_W;
                S_st      <= ST_ISSUE;
            end
            ST_SCAN_W: begin
                if (I_rd_err) begin O_mount_fail <= 1'b1; O_mount_code <= 3'd4; S_st <= ST_FAIL; end
                else if (I_rd_done) begin
                    S_scanned <= S_scanned + 10'd1;
                    if (S_dir_end || S_scanned >= 10'd255) begin O_mounted <= 1'b1; S_st <= ST_IDLE; end
                    else if (S_sec == S_spc - 8'd1) S_st <= ST_FAT_RD;     // 这个簇扫完：沿簇链找下一个
                    else begin
                        S_sec <= S_sec + 8'd1;
                        S_st  <= ST_SCAN_RD;
                    end
                end
            end

            // ---- 查 FAT 表：S_cl 的下一个簇 ----
            ST_FAT_RD: begin
                S_lba_req <= O_fat_lba + {25'd0, S_cl[31:7]};
                S_ret     <= ST_FAT_W;
                S_st      <= ST_ISSUE;
            end
            ST_FAT_W: begin
                if (I_rd_err) begin O_mount_fail <= 1'b1; O_mount_code <= 3'd4; S_st <= ST_FAIL; end
                else if (I_rd_done) begin
                    if (S_nx >= 28'hFFFFFF8 || S_nx < 28'd2) begin O_mounted <= 1'b1; S_st <= ST_IDLE; end    // 目录到头
                    else begin S_cl <= {4'd0, S_nx}; S_sec <= 8'd0; S_st <= ST_SCAN_RD; end
                end
            end

            ST_IDLE: ;
            ST_FAIL: ;
            default: S_st <= ST_WAIT_SD;
        endcase
    end
end

endmodule
