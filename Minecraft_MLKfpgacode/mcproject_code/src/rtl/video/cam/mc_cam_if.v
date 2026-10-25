`timescale 1ns / 1ps
// =============================================================================
// mc_cam_if.v  摄像头接口：IMX415 → MIPI CSI-2(4 lane) → RAW10 → 取 1920×1080 → 伽马 → ISP → 缩小成 800×OUT_H → 打包的 RGB 像素流
//
//   上电时序 mc_cam_pwrup ─► I2C 配置 uicfgimx415 ◄─ mc_ae(自动曝光：曝光时间 + 增益；SW2/SW3 调亮度档)
//   MIPI 引脚 ─► D-PHY RX 硬核封装 ─► csi_unpacket_4lane ─► raw10_unpacket_4lane
//             ─► mc_crop(取 1920×1080) ─► mc_gamma(减黑电平 + 伽马；每帧平均亮度 → mc_ae)
//             ─► isp_top(去马赛克 + 白平衡) ─┬─► mc_scale(等比缩小 2.4 倍 + 打包) ─► O_pix_*  (去帧缓存)
//                                             └─► O_isp_*（给避障 mc_obs）
//
// 输出像素流时钟 = MIPI 字节时钟（891Mbps/lane ÷ 8 ≈ 111.4 MHz）。
// 数据格式：128bit = 16 像素 × 24bit RGB 打包的 3 个字（第一个字节在最高位），每帧 800×OUT_H 像素。
// 传感器（2/2 binning）每帧送 1097 行 RAW10、每行 1944 像素：第 0 行是 Dummy，1~1095 行是有效像素
// （录像区 1920×1080 = 第 11~1090 行、第 6~1925 列），见数据手册 "Drive Timing Chart for Horizontal / Vertical 2/2-line binning mode"。
// =============================================================================
module mc_cam_if #(
    parameter [3:0] LANE_INVERT = 4'b0000,  // 某一对差分线接反时置位对应 bit
    parameter       CROP_X0_GRP = 1,        // 1920×1080 从每行第几组开始(4像素/组)
    parameter       CROP_Y0     = 13,       //           从第几行开始（必须是奇数：Bayer 相位）
    parameter       OUT_H       = 448       // 缩小后的高度（1080 / 2.4 = 450，帧缓存要求 宽×高 是 1280 的倍数，取 448）
)(
    input  wire         I_rst_n,            // 异步复位，低有效（接 PLL lock）
    input  wire         I_clk_100m,         // MIPI RX 的 LP 采样时钟
    input  wire         I_clk_24m,          // 摄像头 INCK / I2C 配置时钟
    input  wire [1:0]   I_key_n,            // 亮度键（低有效）：[0] 亮一档，[1] 暗一档；每个低电平脉冲（≥ 30 ms）改一档。顶层由 mc_bench 给

    // 摄像头板
    output wire         O_cam_scl,
    inout  wire         IO_cam_sda,
    output wire         O_cam_clk,          // 24 MHz → 传感器 INCK
    output wire         O_cam_rst,          // 传感器复位（高电平 = 运行）

    // MIPI CSI 引脚（DPHY0）
    inout  wire         IO_rx_clk_pad_n,
    inout  wire         IO_rx_clk_pad_p,
    inout  wire [3:0]   IO_rx_data_pad_n,
    inout  wire [3:0]   IO_rx_data_pad_p,

    // 输出像素流（时钟域 = O_pix_clk）
    output wire         O_pix_clk,
    output wire         O_pix_frame_start,
    output wire         O_pix_valid,
    output wire [127:0] O_pix_data,

    // 白平衡后的 1920×1080（同一时钟域，和 mc_scale 并联）：给避障 mc_obs
    output wire         O_isp_fs,
    output wire         O_isp_valid,
    output wire [95:0]  O_isp_data,

    // 状态
    output wire         O_cfg_done,         // [24MHz 域] 传感器寄存器已写完
    output wire [7:0]   O_ae_gain,          // [24MHz 域] 自动曝光当前的增益（0.3 dB 一级，屏幕显示）
    output wire [11:0]  O_ae_exp,           // [24MHz 域] 当前曝光行数（最长 2275 ≈ 1 帧）
    output wire [3:0]   O_ae_ev,            // [24MHz 域] 亮度档 0~8（屏幕显示 −4~+4）
    output wire [3:0]   O_lane_error,       // [字节时钟域] MIPI 通道错误
    output reg          O_csi_frame_tog,    // [字节时钟域] 每收到一个 CSI 帧起始翻转一次
    output reg          O_isp_frame_tog     // [字节时钟域] 每输出一个 ISP 帧起始翻转一次
);

// ---------------------------------------------------------------------------
// 1. 上电时序 + I2C 配置
// ---------------------------------------------------------------------------
wire       S_cam_rst_n;
wire       S_cfg_rst_n;
wire        S_ae_req;
wire [15:0] S_ae_shr0;
wire [7:0]  S_ae_gain;
wire        S_ae_cfg_done;
wire [7:0]  S_mean;                 // [像素时钟域] mc_gamma 统计的上一帧平均亮度
wire        S_mean_tog;

mc_cam_pwrup u_pwrup (
    .I_clk       (I_clk_24m),
    .I_rst_n     (I_rst_n),
    .O_cam_rst_n (S_cam_rst_n),
    .O_cfg_rst_n (S_cfg_rst_n)
);

assign O_cam_clk = I_clk_24m;
assign O_ae_gain = S_ae_gain;
assign O_cam_rst = S_cam_rst_n;

mc_ae u_ae (
    .I_clk      (I_clk_24m),
    .I_rst_n    (S_cfg_rst_n),
    .I_cfg_done (O_cfg_done),
    .I_wr_done  (S_ae_cfg_done),
    .I_mean     (S_mean),
    .I_mean_tog (S_mean_tog),
    .I_key_n    (I_key_n),
    .O_req      (S_ae_req),
    .O_shr0     (S_ae_shr0),
    .O_gain     (S_ae_gain),
    .O_exp      (O_ae_exp),
    .O_ev       (O_ae_ev)
);

uicfgimx415 #(
    .CLK_DIV (24_000_000 / 100_000 - 1)         // I2C 100 kHz
) u_cfg (
    .I_clk         (I_clk_24m),
    .I_rst_n       (S_cfg_rst_n),
    .I_ae_req      (S_ae_req),
    .I_ae_shr0     (S_ae_shr0),
    .I_ae_gain     (S_ae_gain),
    .O_cam_scl     (O_cam_scl),
    .IO_cam_sda    (IO_cam_sda),
    .O_cfg_done    (O_cfg_done),
    .O_ae_cfg_done (S_ae_cfg_done)
);

// ---------------------------------------------------------------------------
// 2. MIPI D-PHY RX（4 lane，lane0 在最高字节，与 csi_unpacket_4lane 的假设一致）
// ---------------------------------------------------------------------------
wire        S_hs_rx_clk;
wire        S_hs_rx_valid;
wire [31:0] S_hs_rx_data;

mipi_dphy_rx_ph1p_mipiio_wrapper #(
    .DPHY_RX_LOCATION ("DPHY0"),
    .HS_EQUALIZER     ("0dB"),
    .HS_VGA_GAIN      ("8dB"),
    .LANE_NUM         (4),
    .BYTE_NUM         (1)
) u_mipi_rx (
    .I_lp_clk              (I_clk_100m),
    .I_rst                 (~I_rst_n),

    .I_clk_lane_in_delay   (6'd0),
    .I_data_lane0_in_delay (6'd0),
    .I_data_lane1_in_delay (6'd0),
    .I_data_lane2_in_delay (6'd0),
    .I_data_lane3_in_delay (6'd0),

    .I_lane_invert         (LANE_INVERT),

    .O_hs_rx_clk           (S_hs_rx_clk),
    .O_hs_rx_valid         (S_hs_rx_valid),
    .O_hs_rx_data          (S_hs_rx_data),

    .O_lp_rx_lane0_p       (),
    .O_lp_rx_lane0_n       (),

    .I_lp_tx_en            (1'b0),
    .I_lp_tx_lane0_p       (1'b1),
    .I_lp_tx_lane0_n       (1'b1),

    .O_lane_match_error    (),
    .O_lane_error          (O_lane_error),

    .IO_rx_clk_pad_n       (IO_rx_clk_pad_n),
    .IO_rx_clk_pad_p       (IO_rx_clk_pad_p),
    .IO_rx_data_pad_n      (IO_rx_data_pad_n),
    .IO_rx_data_pad_p      (IO_rx_data_pad_p)
);

assign O_pix_clk = S_hs_rx_clk;

// ---------------------------------------------------------------------------
// 3. CSI-2 包解析 → RAW10 解包（4 像素/拍）
// ---------------------------------------------------------------------------
wire        S_csi_frame_start;
wire        S_csi_frame_end;
wire        S_csi_valid;
wire [31:0] S_csi_data;

csi_unpacket_4lane u_csi (
    .I_clk             (S_hs_rx_clk),
    .I_rst_n           (I_rst_n),
    .I_hs_valid        (S_hs_rx_valid),
    .I_hs_data         (S_hs_rx_data),
    .O_csi_frame_start (S_csi_frame_start),
    .O_csi_frame_end   (S_csi_frame_end),
    .O_csi_valid       (S_csi_valid),
    .O_csi_data        (S_csi_data)
);

wire        S_raw10_frame_start;
wire        S_raw10_frame_end;
wire        S_raw10_valid;
wire [39:0] S_raw10_data;

raw10_unpacket_4lane u_raw10 (
    .I_clk               (S_hs_rx_clk),
    .I_rst_n             (I_rst_n),
    .I_csi_frame_start   (S_csi_frame_start),
    .I_csi_frame_end     (S_csi_frame_end),
    .I_csi_valid         (S_csi_valid),
    .I_csi_data          (S_csi_data),
    .O_raw10_frame_start (S_raw10_frame_start),
    .O_raw10_frame_end   (S_raw10_frame_end),
    .O_raw10_valid       (S_raw10_valid),
    .O_raw10_data        (S_raw10_data)
);

// ---------------------------------------------------------------------------
// 4. 取 1920×1080 → 伽马 → ISP → 缩小 + 打包
// ---------------------------------------------------------------------------
localparam IN_W = 1920, IN_H = 1080;

wire [39:0] S_crop_tdata;
wire        S_crop_tvalid;
wire        S_crop_tuser;
wire        S_crop_tlast;

mc_crop #(
    .X0_GRP (CROP_X0_GRP),
    .W_GRP  (IN_W / 4),
    .Y0     (CROP_Y0),
    .H      (IN_H)
) u_crop (
    .I_clk             (S_hs_rx_clk),
    .I_rst_n           (I_rst_n),
    .I_raw_data        (S_raw10_data),
    .I_raw_valid       (S_raw10_valid),
    .I_raw_frame_start (S_raw10_frame_start),
    .O_raw_tdata       (S_crop_tdata),
    .O_raw_tvalid      (S_crop_tvalid),
    .O_raw_tuser       (S_crop_tuser),
    .O_raw_tlast       (S_crop_tlast)
);

wire [39:0] S_gam_tdata;
wire        S_gam_tvalid;
wire        S_gam_tuser;
wire        S_gam_tlast;

mc_gamma u_gamma (                          // 统计：1920×1080 ≈ 2^21 个像素，用默认的 STAT_SHIFT = 21
    .I_clk      (S_hs_rx_clk),
    .I_rst_n    (I_rst_n),
    .I_tdata    (S_crop_tdata),
    .I_tvalid   (S_crop_tvalid),
    .I_tuser    (S_crop_tuser),
    .I_tlast    (S_crop_tlast),
    .O_tdata    (S_gam_tdata),
    .O_tvalid   (S_gam_tvalid),
    .O_tuser    (S_gam_tuser),
    .O_tlast    (S_gam_tlast),
    .O_mean     (S_mean),
    .O_mean_tog (S_mean_tog)
);

wire [95:0] S_isp_tdata;
wire        S_isp_tuser;
wire        S_isp_tvalid;

isp_top #(                                  // Bayer 排列用 isp_top 的默认值（RGGB），tb_isp 测的就是它
    .IMG_WIDTH  (IN_W),
    .IMG_HEIGHT (IN_H)
) u_isp (
    .axi4s_video_aclk (S_hs_rx_clk),
    .I_rst_n          (I_rst_n),
    .I_tlast          (S_gam_tlast),
    .I_tuser          (S_gam_tuser),
    .I_tdata          (S_gam_tdata),
    .I_tvalid         (S_gam_tvalid),
    .I_tdest          (10'd0),
    .O_tready         (1'b1),
    .O_tdata          (S_isp_tdata),
    .O_tlast          (),
    .O_tuser          (S_isp_tuser),
    .O_tvalid         (S_isp_tvalid),
    .I_tready         ()
);

assign O_isp_fs    = S_isp_tuser;
assign O_isp_valid = S_isp_tvalid;
assign O_isp_data  = S_isp_tdata;

mc_scale #(
    .IN_W  (IN_W),
    .IN_H  (IN_H),
    .OUT_H (OUT_H)
) u_scale (
    .I_clk   (S_hs_rx_clk),
    .I_rst_n (I_rst_n),
    .I_fs    (S_isp_tuser),
    .I_valid (S_isp_tvalid),
    .I_data  (S_isp_tdata),
    .O_fs    (O_pix_frame_start),
    .O_valid (O_pix_valid),
    .O_data  (O_pix_data)
);

// ---------------------------------------------------------------------------
// 5. 活动指示（翻转型，交给 mctop 做跨时钟域同步和超时判断）
// ---------------------------------------------------------------------------
always @(posedge S_hs_rx_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        O_csi_frame_tog <= 1'b0;
        O_isp_frame_tog <= 1'b0;
    end else begin
        if (S_csi_frame_start) O_csi_frame_tog <= ~O_csi_frame_tog;
        if (O_pix_frame_start) O_isp_frame_tog <= ~O_isp_frame_tog;
    end
end

endmodule
