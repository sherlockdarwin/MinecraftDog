`timescale 1ns / 1ps
// =============================================================================
// mc_sd_arb.v  TF 卡读扇区的仲裁：两个 mc_fat32（背景音乐一个、音效一个）共用一个 mc_sd_spi
//
//   两个请求方的接口和 mc_fat32 的"读扇区口"一样：I_start 单周期脉冲 + I_lba（脉冲之后一直保持到读完），
//   O_busy 为 1 时请求方不会再发新请求；读回来的字节流、done、err 只送给提出这次请求的那一方。
//   一次读扇区不会被打断（SD 卡一个命令一个命令地做）；两边同时有请求时轮流（谁刚用过谁排后面）。
//   请求方发出脉冲以后只要等自己的 done / err，不用关心什么时候真正开始读：脉冲会被记下来（每方最多挂 1 个请求）。
// =============================================================================
module mc_sd_arb (
    input  wire        I_clk,
    input  wire        I_rst_n,

    // ---- 请求方 0 / 1（接 mc_fat32 的 O_rd_start / O_lba / I_rd_busy / I_byte_* / I_rd_done / I_rd_err）----
    input  wire        I_start0,
    input  wire [31:0] I_lba0,
    output wire        O_busy0,
    output wire        O_valid0,
    output wire [7:0]  O_byte0,
    output wire [8:0]  O_idx0,
    output wire        O_done0,
    output wire        O_err0,

    input  wire        I_start1,
    input  wire [31:0] I_lba1,
    output wire        O_busy1,
    output wire        O_valid1,
    output wire [7:0]  O_byte1,
    output wire [8:0]  O_idx1,
    output wire        O_done1,
    output wire        O_err1,

    // ---- mc_sd_spi ----
    output reg         O_start,
    output reg  [31:0] O_lba,
    input  wire        I_sd_busy,
    input  wire        I_valid,
    input  wire [7:0]  I_byte,
    input  wire [8:0]  I_idx,
    input  wire        I_done,
    input  wire        I_err
);

reg S_pend0, S_pend1;       // 请求已提出、还没发给 SD 卡
reg S_act;                  // 有一次读扇区在进行（从发给 SD 卡到 done / err）
reg S_own;                  // 正在读的是谁（0 / 1）
reg S_last;                 // 上一次是谁用的

assign O_busy0  = S_pend0 | (S_act & ~S_own);
assign O_busy1  = S_pend1 | (S_act &  S_own);

assign O_valid0 = I_valid & S_act & ~S_own;
assign O_valid1 = I_valid & S_act &  S_own;
assign O_byte0  = I_byte;
assign O_byte1  = I_byte;
assign O_idx0   = I_idx;
assign O_idx1   = I_idx;
assign O_done0  = I_done  & S_act & ~S_own;
assign O_done1  = I_done  & S_act &  S_own;
assign O_err0   = I_err   & S_act & ~S_own;
assign O_err1   = I_err   & S_act &  S_own;

wire S_grant0 = S_pend0 & (~S_pend1 | S_last);      // 两方都在等：上次是 1 用的就轮到 0
wire S_grant1 = S_pend1 & (~S_pend0 | ~S_last);
wire S_free   = ~S_act & ~I_sd_busy & ~O_start;

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        S_pend0 <= 1'b0;
        S_pend1 <= 1'b0;
        S_act   <= 1'b0;
        S_own   <= 1'b0;
        S_last  <= 1'b0;
        O_start <= 1'b0;
        O_lba   <= 32'd0;
    end else begin
        O_start <= 1'b0;
        if (I_start0) S_pend0 <= 1'b1;
        if (I_start1) S_pend1 <= 1'b1;

        if (S_act) begin
            if (I_done | I_err) S_act <= 1'b0;
        end else if (S_free) begin
            if (S_grant0) begin
                O_lba   <= I_lba0;
                O_start <= 1'b1;
                S_own   <= 1'b0;
                S_act   <= 1'b1;
                S_last  <= 1'b0;
                S_pend0 <= I_start0;                // 同一拍又来了新请求的话保留（正常不会发生）
            end else if (S_grant1) begin
                O_lba   <= I_lba1;
                O_start <= 1'b1;
                S_own   <= 1'b1;
                S_act   <= 1'b1;
                S_last  <= 1'b1;
                S_pend1 <= I_start1;
            end
        end
    end
end

endmodule
