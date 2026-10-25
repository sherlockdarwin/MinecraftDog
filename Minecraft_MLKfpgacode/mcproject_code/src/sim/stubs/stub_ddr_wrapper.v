`timescale 1ns / 1ps
// 仿真替身：ph1p35_324_ddr_wrapper（厂商 DDR2 控制器封装，加密 IP，仿真不了）。
// 用一块行为级存储器顶替，接口和真实封装一致（MIG 风格应用口：命令 + 写数据，读数据按命令顺序延迟返回）。
// 用来在 tb_fb.v 里把真实的 video_in / video_out / mc_to_user_interface 全部连起来跑。
// 存储器按四个缓冲区基地址（0 / 7,000,000 / 14,000,000 / 21,000,000）压缩成一小块。
module ph1p35_324_ddr_wrapper (
    input  wire         I_sys_clk,
    input  wire         I_sys_rst_n,

    output wire         O_ddr_clk,
    output reg          O_init_calib_complete,
    input  wire [24:0]  I_mc_app_addr,
    input  wire [2:0]   I_mc_app_cmd,
    input  wire         I_mc_app_en,
    input  wire [127:0] I_mc_app_wdf_data,
    input  wire         I_mc_app_wdf_end,
    input  wire [15:0]  I_mc_app_wdf_mask,
    input  wire         I_mc_app_wdf_wren,
    output reg  [127:0] O_mc_app_rd_data,
    output wire         O_mc_app_rd_data_end,
    output reg          O_mc_app_rd_data_valid,
    output wire         O_mc_app_rdy,
    output wire         O_mc_app_wdf_rdy,

    output wire [12:0]  ddr_addr,
    output wire [1:0]   ddr_ba,
    output wire         ddr_cke,
    output wire         ddr_odt,
    output wire         ddr_cs_n,
    output wire         ddr_ras_n,
    output wire         ddr_cas_n,
    output wire         ddr_we_n,
    output wire         ddr_ck_p,
    output wire         ddr_ck_n,
    inout  wire [1:0]   ddr_dm,
    inout  wire [15:0]  ddr_dq,
    inout  wire [1:0]   ddr_dqs_p,
    inout  wire [1:0]   ddr_dqs_n
);

parameter LAT      = 24;        // 读延迟（DDR 时钟数）
parameter LAT_JIT  = 12;        // 额外随机抖动
parameter STALL_N  = 6;         // 平均每 STALL_N 个时钟有 1 个时钟不接收命令（背压）

reg clk = 1'b0;
always #3.76 clk = ~clk;        // 约 133 MHz
assign O_ddr_clk = clk;

assign ddr_addr = 13'd0; assign ddr_ba = 2'd0; assign ddr_cke = 1'b0; assign ddr_odt = 1'b0;
assign ddr_cs_n = 1'b1; assign ddr_ras_n = 1'b1; assign ddr_cas_n = 1'b1; assign ddr_we_n = 1'b1;
assign ddr_ck_p = 1'b0; assign ddr_ck_n = 1'b1;
assign ddr_dm = 2'bzz; assign ddr_dq = 16'hzzzz; assign ddr_dqs_p = 2'bzz; assign ddr_dqs_n = 2'bzz;

reg  rdy_r = 1'b0;
assign O_mc_app_rdy     = rdy_r;
assign O_mc_app_wdf_rdy = rdy_r;
assign O_mc_app_rd_data_end = O_mc_app_rd_data_valid;

reg [127:0] mem [0:16383];                                  // 4 个缓冲区 × 4096 字

function [13:0] map;
    input [24:0] a;
    reg [24:0] off;
    reg [1:0]  reg_i;
    begin
        if      (a < 25'd3500000)  begin reg_i = 2'd0; off = a;               end
        else if (a < 25'd10500000) begin reg_i = 2'd1; off = a - 25'd7000000;  end
        else if (a < 25'd17500000) begin reg_i = 2'd2; off = a - 25'd14000000; end
        else                       begin reg_i = 2'd3; off = a - 25'd21000000; end
        map = {reg_i, off[14:3]};
    end
endfunction

integer cyc = 0;
integer q_t [0:1023];
reg [127:0] q_d [0:1023];
integer qh = 0, qt = 0;
integer rnd = 12345;
integer n_wr = 0, n_rd = 0;

always @(posedge clk) begin
    cyc = cyc + 1;
    O_mc_app_rd_data_valid <= 1'b0;

    if (cyc > 300) O_init_calib_complete <= 1'b1;
    else           O_init_calib_complete <= 1'b0;

    // 读数据按顺序返回
    if (qh != qt && q_t[qh % 1024] <= cyc) begin
        O_mc_app_rd_data_valid <= 1'b1;
        O_mc_app_rd_data       <= q_d[qh % 1024];
        qh = qh + 1;
    end

    // 命令
    if (I_mc_app_en && rdy_r) begin
        if (I_mc_app_cmd[0]) begin                          // 读
            q_t[qt % 1024] = cyc + LAT + (($random(rnd) & 32'h7FFF) % (LAT_JIT + 1));
            q_d[qt % 1024] = mem[map(I_mc_app_addr)];            // 读到的是命令发出那一刻的内容
            qt = qt + 1;
            n_rd = n_rd + 1;
        end else begin                                      // 写
            mem[map(I_mc_app_addr)] = I_mc_app_wdf_data;
            n_wr = n_wr + 1;
        end
    end

    rdy_r <= (($random(rnd) & 32'h7FFF) % STALL_N) != 0;
end

endmodule
