`timescale 1ns / 1ps
// =============================================================================
// mc_fat32.v  最小的 FAT32 读取器：挂载卡 → 扫根目录找 "数字.WAV" → 两路各自按文件的簇链把文件内容一个字节一个字节地送出来
//             （0 路 = 背景音乐，1 路 = 音效；挂载 + 目录表只有一份，两路共用）
//
//                  ┌ mc_fat_dir（挂载 + 扫根目录 + 目录表；上电后只做一次）
//   mc_fat32 ──────┼ mc_fat_rd #0 ─ 读扇区口 0 ─┐
//                  └ mc_fat_rd #1 ─ 读扇区口 1 ─┴─► mc_sd_arb ─► mc_sd_spi
//
//   mc_fat_dir 挂载期间用 0 号读扇区口（这时候 mc_fat_rd #0 还没有活干），挂载完成以后这个口归 mc_fat_rd #0。
//   两路读文件互不影响（各读各的扇区，由 mc_sd_arb 轮流给 SD 卡）。
//   规格、取数接口见 mc_fat_dir.v（TF 卡要求）和 mc_fat_rd.v（打开 / 取数 / 关闭）。
// =============================================================================
module mc_fat32 (
    input  wire        I_clk,
    input  wire        I_rst_n,

    // ---- mc_sd_spi（经 mc_sd_arb）：名字带 0 的接 0 号读扇区口，带 1 的接 1 号 ----
    input  wire        I_sd_ready,
    input  wire        I_sd_fail,
    output wire        O_rd_start0,
    output wire [31:0] O_lba0,
    input  wire        I_rd_busy0,
    input  wire        I_byte_valid0,
    input  wire [7:0]  I_byte0,
    input  wire [8:0]  I_byte_idx0,
    input  wire        I_rd_done0,
    input  wire        I_rd_err0,
    output wire        O_rd_start1,
    output wire [31:0] O_lba1,
    input  wire        I_rd_busy1,
    input  wire        I_byte_valid1,
    input  wire [7:0]  I_byte1,
    input  wire [8:0]  I_byte_idx1,
    input  wire        I_rd_done1,
    input  wire        I_rd_err1,

    // ---- 挂载状态（两路共用）----
    output wire        O_mounted,           // 卷已识别、目录已扫完
    output wire        O_mount_fail,
    output wire [2:0]  O_mount_code,        // 1 没有 FAT32  2 引导扇区不对  3 簇/FAT 参数不支持  4 读卡错误
    output wire [7:0]  O_nclips,            // 找到的 N.wav 个数

    // ---- 0 路 / 1 路：打开 + 取数 ----
    input  wire        I_open0,
    input  wire [6:0]  I_clip0,
    input  wire        I_close0,
    output wire        O_open_err0,
    output wire [2:0]  O_err_code0,
    output wire        O_data_valid0,
    output wire [7:0]  O_data0,
    input  wire        I_space_ok0,
    output wire        O_eof0,
    output wire        O_active0,

    input  wire        I_open1,
    input  wire [6:0]  I_clip1,
    input  wire        I_close1,
    output wire        O_open_err1,
    output wire [2:0]  O_err_code1,
    output wire        O_data_valid1,
    output wire [7:0]  O_data1,
    input  wire        I_space_ok1,
    output wire        O_eof1,
    output wire        O_active1
);

// ---- 挂载 + 目录表 ----
wire        S_dir_start;
wire [31:0] S_dir_lba;
wire [31:0] S_fat_lba, S_data_lba;
wire [7:0]  S_spc;
wire [2:0]  S_spc_log;
wire [63:0] S_present;
wire [5:0]  S_qa0, S_qa1;
wire [27:0] S_qcl0, S_qcl1;
wire [31:0] S_qsz0, S_qsz1;

mc_fat_dir u_dir (
    .I_clk        (I_clk),
    .I_rst_n      (I_rst_n),
    .I_sd_ready   (I_sd_ready),
    .I_sd_fail    (I_sd_fail),
    .O_rd_start   (S_dir_start),
    .O_lba        (S_dir_lba),
    .I_rd_busy    (I_rd_busy0),
    .I_byte_valid (I_byte_valid0),
    .I_byte       (I_byte0),
    .I_byte_idx   (I_byte_idx0),
    .I_rd_done    (I_rd_done0),
    .I_rd_err     (I_rd_err0),
    .O_mounted    (O_mounted),
    .O_mount_fail (O_mount_fail),
    .O_mount_code (O_mount_code),
    .O_nclips     (O_nclips),
    .O_fat_lba    (S_fat_lba),
    .O_data_lba   (S_data_lba),
    .O_spc        (S_spc),
    .O_spc_log    (S_spc_log),
    .O_present    (S_present),
    .I_q_addr0    (S_qa0),
    .O_q_cl0      (S_qcl0),
    .O_q_sz0      (S_qsz0),
    .I_q_addr1    (S_qa1),
    .O_q_cl1      (S_qcl1),
    .O_q_sz1      (S_qsz1)
);

// ---- 0 路（背景音乐）：挂载完成之前 0 号读扇区口给 mc_fat_dir ----
wire        S_rd0_start;
wire [31:0] S_rd0_lba;

assign O_rd_start0 = O_mounted ? S_rd0_start : S_dir_start;
assign O_lba0      = O_mounted ? S_rd0_lba   : S_dir_lba;

mc_fat_rd u_rd0 (
    .I_clk        (I_clk),
    .I_rst_n      (I_rst_n),
    .O_rd_start   (S_rd0_start),
    .O_lba        (S_rd0_lba),
    .I_rd_busy    (I_rd_busy0),
    .I_byte_valid (I_byte_valid0),
    .I_byte       (I_byte0),
    .I_byte_idx   (I_byte_idx0),
    .I_rd_done    (I_rd_done0),
    .I_rd_err     (I_rd_err0),
    .I_fat_lba    (S_fat_lba),
    .I_data_lba   (S_data_lba),
    .I_spc        (S_spc),
    .I_spc_log    (S_spc_log),
    .I_present    (S_present),
    .O_q_addr     (S_qa0),
    .I_q_cl       (S_qcl0),
    .I_q_sz       (S_qsz0),
    .I_open       (I_open0),
    .I_clip       (I_clip0),
    .I_close      (I_close0),
    .O_open_err   (O_open_err0),
    .O_err_code   (O_err_code0),
    .O_data_valid (O_data_valid0),
    .O_data       (O_data0),
    .I_space_ok   (I_space_ok0),
    .O_eof        (O_eof0),
    .O_active     (O_active0)
);

// ---- 1 路（音效）----
mc_fat_rd u_rd1 (
    .I_clk        (I_clk),
    .I_rst_n      (I_rst_n),
    .O_rd_start   (O_rd_start1),
    .O_lba        (O_lba1),
    .I_rd_busy    (I_rd_busy1),
    .I_byte_valid (I_byte_valid1),
    .I_byte       (I_byte1),
    .I_byte_idx   (I_byte_idx1),
    .I_rd_done    (I_rd_done1),
    .I_rd_err     (I_rd_err1),
    .I_fat_lba    (S_fat_lba),
    .I_data_lba   (S_data_lba),
    .I_spc        (S_spc),
    .I_spc_log    (S_spc_log),
    .I_present    (S_present),
    .O_q_addr     (S_qa1),
    .I_q_cl       (S_qcl1),
    .I_q_sz       (S_qsz1),
    .I_open       (I_open1),
    .I_clip       (I_clip1),
    .I_close      (I_close1),
    .O_open_err   (O_open_err1),
    .O_err_code   (O_err_code1),
    .O_data_valid (O_data_valid1),
    .O_data       (O_data1),
    .I_space_ok   (I_space_ok1),
    .O_eof        (O_eof1),
    .O_active     (O_active1)
);

endmodule
