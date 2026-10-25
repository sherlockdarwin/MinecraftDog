`timescale 1ns / 1ps
// =============================================================================
// mc_framebuf.v  帧缓存：用片内 DDR2 做 4 缓冲轮换（厂商 08 例程的 video_in / video_out 架构）
//
//   相机像素流 ─► video_in ──写──┐
//                                 ├─► mc_to_user_interface ─► DDR2 控制器(ph1p35_324_ddr_wrapper)
//   显示读请求 ─► video_out ◄─读──┘
//
// 帧布局：每帧按行优先、24bit/像素紧密打包进 128bit 字（16 像素 = 3 字），每个缓冲区间隔 7,000,000 地址。
// 约束（由 video_in/video_out 的突发长度 240 字决定）：
//   · 帧宽必须是 16 的倍数；
//   · 每帧总字数 = 宽×高×3/16 必须是 240 的整数倍（等价于 宽×高 是 1280 的整数倍），否则帧尾不满一次突发的
//     那部分数据写不进 DDR。800×448 = 358400 = 280×1280 ✓。
// 读端必须"每行恰好读 帧宽 个像素"，并且每帧只读相机窗口那几行（由 mc_mixer 的 O_rd_en 保证）。
// =============================================================================
module mc_framebuf (
    input  wire         I_rst_n,            // 异步复位，低有效（接 PLL lock）
    input  wire         I_clk_sys,          // 25 MHz 板载晶振，作为 DDR2 IP 的参考时钟

    // 写端：相机像素流（时钟域 I_cam_clk）
    input  wire         I_cam_clk,
    input  wire         I_cam_frame_start,
    input  wire         I_cam_valid,
    input  wire [127:0] I_cam_data,

    // 读端：显示（时钟域 I_dsi_clk）
    input  wire         I_dsi_clk,
    input  wire         I_dsi_vsync,        // 显示帧同步（高有效脉冲），上升沿 = 新的一帧开始读
    input  wire         I_dsi_rd_en,        // 读一个像素（每行连续拉高 帧宽 个时钟）
    output wire [23:0]  O_dsi_data,         // 像素 {R,G,B}，在 I_dsi_rd_en 之后第 2 个时钟有效

    // 状态
    output wire         O_ddr_ready,        // [DDR 时钟域] DDR2 初始化 / 校准完成

    // DDR2 引脚
    output wire [12:0]  ddr_addr,
    output wire [1:0]   ddr_ba,
    output wire [0:0]   ddr_cke,
    output wire [0:0]   ddr_odt,
    output wire [0:0]   ddr_cs_n,
    output wire         ddr_ras_n,
    output wire         ddr_cas_n,
    output wire         ddr_we_n,
    output wire [0:0]   ddr_ck_p,
    output wire [0:0]   ddr_ck_n,
    inout  wire [1:0]   ddr_dm,
    inout  wire [15:0]  ddr_dq,
    inout  wire [1:0]   ddr_dqs_p,
    inout  wire [1:0]   ddr_dqs_n
);

wire         S_ddr_clk;

wire         S_video_out_rd_busy;       // 厂商 video_out 忙
wire         S_video_in_wr_busy;
wire [1:0]   S_video_out_rp;

wire         S_vi_ddr_wr_en;
wire [24:0]  S_vi_ddr_wr_addr;
wire [127:0] S_vi_ddr_wr_data;

wire         S_vo_ddr_rd_en;
wire [24:0]  S_vo_ddr_rd_addr;

wire         S_ddr_user_wr_en;
wire         S_ddr_user_rd_en;
wire [24:0]  S_ddr_user_addr;
wire [127:0] S_ddr_user_wr_data;
wire         S_ddr_user_ready;
wire         S_ddr_user_rd_valid;
wire [127:0] S_ddr_user_rd_data;

wire [24:0]  S_mc_app_addr;
wire [2:0]   S_mc_app_cmd;
wire         S_mc_app_en;
wire [127:0] S_mc_app_wdf_data;
wire         S_mc_app_wdf_end;
wire [15:0]  S_mc_app_wdf_mask;
wire         S_mc_app_wdf_wren;
wire [127:0] S_mc_app_rd_data;
wire         S_mc_app_rd_data_end;
wire         S_mc_app_rd_data_valid;
wire         S_mc_app_rdy;
wire         S_mc_app_wdf_rdy;

// ---------------------------------------------------------------------------
// 写：相机流 → DDR（跨时钟域靠 video_in 里的异步 FIFO）
// ---------------------------------------------------------------------------
video_in u_video_in (
    .I_rst_n              (I_rst_n),

    .I_camera_clk         (I_cam_clk),
    .I_camera_frame_start (I_cam_frame_start),
    .I_camera_valid       (I_cam_valid),
    .I_camera_data        (I_cam_data),
    .I_mipi_rx_error      (1'b0),

    .I_ddr_clk            (S_ddr_clk),
    .I_display_pause      (1'b0),
    .I_video_out_rd_busy  (S_video_out_rd_busy),
    .O_video_in_wr_busy   (S_video_in_wr_busy),
    .O_video_out_rp       (S_video_out_rp),

    .O_ddr_user_wr_en     (S_vi_ddr_wr_en),
    .O_ddr_user_addr      (S_vi_ddr_wr_addr),
    .O_ddr_user_wr_data   (S_vi_ddr_wr_data),
    .I_ddr_user_ready     (S_ddr_user_ready)
);

// 读写共用一个 DDR 用户口：写优先（video_in/out 之间用 busy 信号互斥，不会同时有效）
assign S_ddr_user_wr_en   = S_vi_ddr_wr_en;
assign S_ddr_user_rd_en   = S_vo_ddr_rd_en;
assign S_ddr_user_addr    = S_vi_ddr_wr_en ? S_vi_ddr_wr_addr :
                            S_vo_ddr_rd_en ? S_vo_ddr_rd_addr : 25'd0;
assign S_ddr_user_wr_data = S_vi_ddr_wr_data;

// ---------------------------------------------------------------------------
// 读：DDR → 显示（跨时钟域靠 video_out 里的异步 FIFO）
// ---------------------------------------------------------------------------
video_out u_video_out (
    .I_rst_n             (I_rst_n),
    .I_ddr_clk           (S_ddr_clk),

    .O_video_out_rd_busy (S_video_out_rd_busy),
    .I_video_in_wr_busy  (S_video_in_wr_busy),
    .I_video_out_rp      (S_video_out_rp),

    .O_ddr_user_rd_en    (S_vo_ddr_rd_en),
    .O_ddr_user_addr     (S_vo_ddr_rd_addr),
    .I_ddr_user_ready    (S_ddr_user_ready),
    .I_ddr_user_rd_valid (S_ddr_user_rd_valid),
    .I_ddr_user_rd_data  (S_ddr_user_rd_data),

    .I_dsi_clk           (I_dsi_clk),
    .I_video_vsync       (I_dsi_vsync),
    .I_video_rd_en       (I_dsi_rd_en),
    .O_vdieo_data        (O_dsi_data)
);

// ---------------------------------------------------------------------------
// 用户口 → DDR 控制器应用口
// ---------------------------------------------------------------------------
mc_to_user_interface u_mc_to_user_interface (
    .I_clk                  (S_ddr_clk),
    .I_rst_n                (I_rst_n),

    .I_ddr_user_wr_en       (S_ddr_user_wr_en),
    .I_ddr_user_rd_en       (S_ddr_user_rd_en),
    .I_ddr_user_addr        (S_ddr_user_addr),
    .I_ddr_user_wr_data     (S_ddr_user_wr_data),
    .O_ddr_user_ready       (S_ddr_user_ready),
    .O_ddr_user_rd_valid    (S_ddr_user_rd_valid),
    .O_ddr_user_rd_data     (S_ddr_user_rd_data),

    .O_mc_app_en            (S_mc_app_en),
    .O_mc_app_addr          (S_mc_app_addr),
    .O_mc_app_cmd           (S_mc_app_cmd),
    .I_mc_app_rdy           (S_mc_app_rdy),
    .O_mc_app_wdf_wren      (S_mc_app_wdf_wren),
    .O_mc_app_wdf_data      (S_mc_app_wdf_data),
    .O_mc_app_wdf_end       (S_mc_app_wdf_end),
    .O_mc_app_wdf_mask      (S_mc_app_wdf_mask),
    .I_mc_app_wdf_rdy       (S_mc_app_wdf_rdy),
    .I_mc_app_rd_data       (S_mc_app_rd_data),
    .I_mc_app_rd_data_end   (S_mc_app_rd_data_end),
    .I_mc_app_rd_data_valid (S_mc_app_rd_data_valid)
);

ph1p35_324_ddr_wrapper u_ddr (
    .I_sys_clk              (I_clk_sys),
    .I_sys_rst_n            (I_rst_n),

    .O_ddr_clk              (S_ddr_clk),
    .O_init_calib_complete  (O_ddr_ready),
    .I_mc_app_addr          (S_mc_app_addr),
    .I_mc_app_cmd           (S_mc_app_cmd),
    .I_mc_app_en            (S_mc_app_en),
    .I_mc_app_wdf_data      (S_mc_app_wdf_data),
    .I_mc_app_wdf_end       (S_mc_app_wdf_end),
    .I_mc_app_wdf_mask      (S_mc_app_wdf_mask),
    .I_mc_app_wdf_wren      (S_mc_app_wdf_wren),
    .O_mc_app_rd_data       (S_mc_app_rd_data),
    .O_mc_app_rd_data_end   (S_mc_app_rd_data_end),
    .O_mc_app_rd_data_valid (S_mc_app_rd_data_valid),
    .O_mc_app_rdy           (S_mc_app_rdy),
    .O_mc_app_wdf_rdy       (S_mc_app_wdf_rdy),

    .ddr_addr               (ddr_addr),
    .ddr_ba                 (ddr_ba),
    .ddr_cke                (ddr_cke),
    .ddr_odt                (ddr_odt),
    .ddr_cs_n               (ddr_cs_n),
    .ddr_ras_n              (ddr_ras_n),
    .ddr_cas_n              (ddr_cas_n),
    .ddr_we_n               (ddr_we_n),
    .ddr_ck_p               (ddr_ck_p),
    .ddr_ck_n               (ddr_ck_n),
    .ddr_dm                 (ddr_dm),
    .ddr_dq                 (ddr_dq),
    .ddr_dqs_p              (ddr_dqs_p),
    .ddr_dqs_n              (ddr_dqs_n)
);

endmodule
