`timescale 1ns / 1ps
// =============================================================================
// mc_disp_if.v  显示接口：像素流 → MIPI DSI（4 lane）→ 10.1" 800×1280 屏（驱动 IC ILI9881C）
//
//   mc_panel_ctrl ─► display_config_wrapper(ROM 里的 ILI9881C 初始化脚本，LP 模式发出)
//   video_tpg(时序+背景图案) ─► mc_mixer(相机窗口/状态方块/文字层，竖屏) ─► rgb_24b_to_32b ─► dsi_video_mode_packet
//                                                                    ─► D-PHY TX 硬核封装 ─► DSI 引脚
//
// 时钟：D-PHY TX 的 DPLL 以 I_clk_dpll_ref(52.17MHz) × (DPLL_MULTI_RATIO+1) / 16 产生字节时钟
//       = 68.49 MHz（与厂商 7 寸屏例程相同，已在这块板上验证过），整条视频流水线都跑在这个时钟上，
//       即 1 个字节时钟 = 1 个像素。所以屏幕刷新率 = 68.49MHz / (HTOTAL × VTOTAL) = 68.49M / (1120 × 1317) ≈ 46.4 Hz。
// 水平消隐 HSA/HBP/HFP = 24/136/160：和厂商例程（在这块板上点亮过）一字不差。加密的 DSI 打包核（rgb_24b_to_32b +
//   dsi_video_mode_packet）不看 D-PHY 的 ready，靠消隐时间留出"高速包发完 → 回到 LP → 下一个包"的空隙；
//   以前给的 24/100/76（共 200 个时钟）比厂商少 120 个时钟，上板现象（竖条纹、字被压扁、画面抖、偶尔全黑）
//   符合"包撞在一起、屏丢行同步"。所以消隐只照抄厂商的，不再自己压缩。
// 垂直：VSA 6 / VBP 15 / VFP 16，ILI9881C 10.1" 800×1280 面板的典型值（Linux 内核 K101-IM2BYL02）。
// =============================================================================
module mc_disp_if #(
    // ---- 有效区域与消隐（单位：像素时钟）----
    parameter H_ACTIVE = 800,
    parameter HSA      = 24,
    parameter HBP      = 136,
    parameter HFP      = 160,
    parameter V_ACTIVE = 1280,
    parameter VSA      = 6,
    parameter VBP      = 15,
    parameter VFP      = 16,
    // ---- 画面内容（版面见 mc_mixer.v）----
    parameter IMG_W    = 800,       // 相机窗口宽
    parameter IMG_H    = 560,       // 相机窗口高
    parameter SQ_V0    = 568,       // 状态方块起始行（画布）
    parameter SQ_H     = 40,        // 状态方块高
    parameter [3:0] TPG_MODE = 4'd9,// 背景测试图案：1红 2绿 3蓝 4白 5~8渐变 9马赛克 10斜线 11网格（BG_PATTERN=1 时才显示）
    parameter BG_PATTERN = 0,       // 0：背景黑色；1：背景用测试图案
    parameter RB_SWAP  = 0,         // 红蓝互换
    // ---- 文字层（见 mc_osd_text.v）：画布下方的字符区 ----
    parameter TXT_U0   = 40,        // 文字框左上角 u（画布列）
    parameter TXT_V0   = 616,       // 文字框左上角 v（画布行）
    parameter TXT_COLS = 45,        // 每行字符数
    parameter TXT_ROWS = 3,         // 行数
    parameter TXT_SH   = 1,         // 字符放大倍数 = 2^TXT_SH（1 → 16×32 像素/字符）
    // ---- D-PHY ----
    parameter DPLL_MULTI_RATIO = 20
)(
    input  wire         I_rst_n,            // 异步复位，低有效（接 PLL lock）
    input  wire         I_clk_dpll_ref,     // 52.173913 MHz
    input  wire         I_clk_lp,           // 10 MHz（LP 命令发送 / 面板时序）

    // 与帧缓存对接（像素时钟域 = O_dsi_clk）
    output wire         O_dsi_clk,
    output wire         O_vsync,
    output wire         O_rd_en,            // 读一个相机像素（厂商 video_out，顺序读）
    input  wire [23:0]  I_rd_data,

    // 状态输入 / 输出
    input  wire         I_win_en,           // 相机帧是否持续到来
    input  wire [7:0]   I_status,           // 状态方块位
    output wire         O_panel_ready,      // [10MHz 域] 面板初始化脚本已发完

    // 文字层写入（系统 100 MHz 域）：总线格式见 mc_osd_text.v，由 mc_osd_dash 产生
    input  wire         I_txt_clk,
    input  wire [19:0]  I_txt_bus,

    // 面板控制脚（经 TXS0108E 转 1.8V）
    output wire         O_dsi_pwm,          // 背光 PWM（这里恒高 = 最亮），初始化完成后才拉高
    output wire         O_dsi_rst_n,        // 面板复位，低有效

    // MIPI DSI 引脚（DPHY1）
    inout  wire         IO_tx_clk_pad_n,
    inout  wire         IO_tx_clk_pad_p,
    inout  wire [3:0]   IO_tx_data_pad_n,
    inout  wire [3:0]   IO_tx_data_pad_p
);

localparam HTOTAL = H_ACTIVE + HSA + HBP + HFP;
localparam VTOTAL = V_ACTIVE + VSA + VBP + VFP;

wire        S_dsi_clk;
wire        S_dpll_locked;
wire        S_config_start;
wire        S_config_done;
wire        S_lp_tx_p;
wire        S_lp_tx_n;

assign O_dsi_clk     = S_dsi_clk;
assign O_panel_ready = S_config_done;

// ---------------------------------------------------------------------------
// 1. 面板上电时序 + 初始化脚本
// ---------------------------------------------------------------------------
mc_panel_ctrl u_panel_ctrl (
    .I_clk          (I_clk_lp),
    .I_rst_n        (S_dpll_locked),
    .I_config_done  (S_config_done),
    .O_panel_rst_n  (O_dsi_rst_n),
    .O_config_start (S_config_start),
    .O_backlight    (O_dsi_pwm)
);

display_config_wrapper u_display_config (
    .I_clk          (I_clk_lp),
    .I_rst          (~I_rst_n),
    .I_config_start (S_config_start),
    .O_config_done  (S_config_done),
    .O_lp_tx_p      (S_lp_tx_p),
    .O_lp_tx_n      (S_lp_tx_n)
);

// ---------------------------------------------------------------------------
// 2. 视频时序 + 背景图案（video_tpg 输出的 HSYNC/VSYNC 是低有效，取反后变成高有效脉冲）
// ---------------------------------------------------------------------------
wire        S_tpg_de;
wire        S_tpg_hsync_n;
wire        S_tpg_vsync_n;
wire [23:0] S_tpg_data;
wire        S_tpg_rst = (~I_rst_n) | (~S_config_done);

video_tpg #(
    .HTOTAL (HTOTAL), .HSA (HSA), .HBP (HBP), .HFP (HFP),
    .VTOTAL (VTOTAL), .VSA (VSA), .VBP (VBP), .VFP (VFP)
) u_tpg (
    .PCLK     (S_dsi_clk),
    .Reset    (S_tpg_rst),
    .DEN_TPG  (1'b1),
    .TPG_mode (TPG_MODE),
    .PDEN     (S_tpg_de),
    .HSYNC    (S_tpg_hsync_n),
    .VSYNC    (S_tpg_vsync_n),
    .PDATA    (S_tpg_data)
);

wire S_vsync = ~S_tpg_vsync_n;
wire S_hsync = ~S_tpg_hsync_n;

assign O_vsync = S_vsync;

// ---------------------------------------------------------------------------
// 3. 画面合成：相机窗口 + 状态方块 + 背景
// ---------------------------------------------------------------------------
wire        S_mix_vsync;
wire        S_mix_hsync;
wire        S_mix_de;
wire [23:0] S_mix_data;

mc_mixer #(
    .PANEL_W    (H_ACTIVE),
    .PANEL_H    (V_ACTIVE),
    .IMG_W      (IMG_W),
    .IMG_H      (IMG_H),
    .SQ_V0      (SQ_V0),
    .SQ_H       (SQ_H),
    .TXT_U0     (TXT_U0),
    .TXT_V0     (TXT_V0),
    .TXT_COLS   (TXT_COLS),
    .TXT_ROWS   (TXT_ROWS),
    .TXT_SH     (TXT_SH),
    .BG_PATTERN (BG_PATTERN),
    .RB_SWAP    (RB_SWAP)
) u_mixer (
    .I_clk     (S_dsi_clk),
    .I_vsync   (S_vsync),
    .I_hsync   (S_hsync),
    .I_de      (S_tpg_de),
    .I_bg_data (S_tpg_data),
    .I_win_en  (I_win_en),
    .I_status  (I_status),
    .I_txt_clk (I_txt_clk),
    .I_txt_bus (I_txt_bus),
    .O_rd_en   (O_rd_en),
    .I_rd_data (I_rd_data),
    .O_vsync   (S_mix_vsync),
    .O_hsync   (S_mix_hsync),
    .O_de      (S_mix_de),
    .O_data    (S_mix_data)
);

// ---------------------------------------------------------------------------
// 4. DSI 打包（24bit 像素 → 32bit 字 → DSI 视频模式包）
// ---------------------------------------------------------------------------
wire        S_32b_vsync;
wire        S_32b_hsync;
wire        S_32b_de;
wire [31:0] S_32b_data;

rgb_24b_to_32b #(
    .H_ACTIVE (H_ACTIVE)
) u_rgb_24b_to_32b (
    .I_clk   (S_dsi_clk),
    .I_rst   (~I_rst_n),
    .I_vsync (S_mix_vsync),
    .I_hsync (S_mix_hsync),
    .I_de    (S_mix_de),
    .I_data  (S_mix_data),
    .O_vsync (S_32b_vsync),
    .O_hsync (S_32b_hsync),
    .O_de    (S_32b_de),
    .O_data  (S_32b_data)
);

wire        S_hs_tx_valid;
wire [31:0] S_hs_tx_data;
wire        S_hs_tx_last;
wire        S_hs_tx_ready;

dsi_video_mode_packet #(
    .H_ACTIVE (H_ACTIVE)
) u_dsi_video_mode_packet (
    .I_clk     (S_dsi_clk),
    .I_rst     (~I_rst_n),
    .I_vsync   (S_32b_vsync),
    .I_hsync   (S_32b_hsync),
    .I_de      (S_32b_de),
    .I_data    (S_32b_data),
    .O_hs_en   (S_hs_tx_valid),
    .O_hs_data (S_hs_tx_data),
    .O_hs_last (S_hs_tx_last)
);

// ---------------------------------------------------------------------------
// 5. MIPI D-PHY TX（4 lane，时钟连续模式）
// ---------------------------------------------------------------------------
mipi_dphy_tx_over_ph1p_mipiio_wrapper #(
    .DPHY_TX_LOCATION      ("DPHY1"),
    .BYTE_NUM              (1),
    .LANE_NUM              (4),
    .CLK_LANE_MODE         ("CONTINUE"),
    .HS_OUTPUT_VOD         ("200mV"),
    .HS_OUTPUT_IMPEDANCE   ("50ohm"),
    .HS_OUTPUT_DE_EMPHASIS ("0dB"),
    .CK_OUTPUT_DELAY       (0),
    .L0_OUTPUT_DELAY       (0),
    .L1_OUTPUT_DELAY       (0),
    .L2_OUTPUT_DELAY       (0),
    .L3_OUTPUT_DELAY       (0),
    .DPLL_MULTI_RATIO      (DPLL_MULTI_RATIO),
    .DPLL_DIV_RATIO        (1),
    .T_DATA_LPX            (10),
    .T_DATA_HS_PREPARE     (10),
    .T_DATA_HS_ZERO        (20),
    .T_DATA_HS_TRAIL       (10),
    .T_CLK_LPX             (10),
    .T_CLK_PREPARE         (10),
    .T_CLK_ZERO            (10),
    .T_CLK_PRE             (10),
    .T_CLK_POST            (10),
    .T_CLK_TRAIL           (10)
) u_mipi_tx (
    .I_dphy_pll_ref_clk (I_clk_dpll_ref),
    .I_rst              (~I_rst_n),
    .O_dpll_locked      (S_dpll_locked),

    .O_hs_tx_clk        (S_dsi_clk),
    .I_hs_tx_valid      (S_hs_tx_valid),
    .I_hs_tx_data       (S_hs_tx_data),
    .I_hs_tx_last       (S_hs_tx_last),
    .O_hs_tx_ready      (S_hs_tx_ready),

    .I_lp_tx_p          (S_lp_tx_p),
    .I_lp_tx_n          (S_lp_tx_n),

    .I_lp_rx_en         (1'b0),
    .O_lp_rx_p          (),
    .O_lp_rx_n          (),

    .IO_tx_clk_pad_n    (IO_tx_clk_pad_n),
    .IO_tx_clk_pad_p    (IO_tx_clk_pad_p),
    .IO_tx_data_pad_n   (IO_tx_data_pad_n),
    .IO_tx_data_pad_p   (IO_tx_data_pad_p)
);

endmodule
