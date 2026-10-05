`timescale 1ns / 1ps
// =============================================================================
// mctop.v  MinecraftDog 顶层（相当于 C 工程的 main + syscfg）
// 只做三件事：声明板级端口、产生时钟/复位/节拍、例化并连接子模块。功能逻辑都在子模块里。
// 管脚：src/pin/mc_pin.adc（DDR2 管脚在 ip/ddr2/src/adc）   时钟约束：src/pin/mc_timing.sdc
// 命名：I_ 输入 / O_ 输出 / IO_ 双向 / S_ 内部信号 / _n 低有效（同米联客例程）
//
// 图像通路（M1+M2）：
//   IMX415 ─MIPI CSI 4lane─► mc_cam_if ─像素流─► mc_framebuf(DDR2) ─像素流─► mc_disp_if ─MIPI DSI 4lane─► 10.1" 屏
//                                                      ▲                          ▲
//                             状态/活动监测 ───────────┴─► 屏幕上的 8 个状态方块     │ 文字写入总线
// 人机交互 / 执行器（M3）：
//   SW1~SW3 ─► mc_key(短按/长按) ─► mc_bench(SW2/SW3 短按 → 相机增益键)
//   TF 卡 ─ WAV ─► mc_audio ─► ES8388 ─► 喇叭（背景音乐上电自动循环 + 进食音效，同时播）
//   霍尔传感器 ─► mc_hall ─► mc_behavior（喂食：摇尾巴 + 进食音效；以后 UWB 的"距离 < 5 m 摇尾巴"、"丢了就叫"也接这里）─► mc_tail ─UART(只发)─► 步进驱动器（尾巴）/ mc_audio
//   各模块的状态 ─► mc_osd_dash ─文字写入总线─► mc_disp_if 里的文字层 ─► 画面中间状态带的 3 行文字
//   （轮子的控制放在另一块单片机上，这里没有电机驱动 / 编码器）
// 画面：竖屏 800×1280，上半相机、中间状态带、下半留给避障；厂商 video_out 顺序读帧缓存，版面见 mc_mixer.v
// =============================================================================
module mctop (
    input  wire         I_sys_clk,          // 25 MHz 晶振 (C4)
    input  wire [2:0]   I_key,              // SW1 (R10) / SW2 (N2) / SW3 (J14)，按下为低；[0]=SW1 ... [2]=SW3
    output wire [2:0]   O_led,              // LED1~3 (K16/K17/J18)，高电平亮

    // ---- 摄像头（CSI 口 + IMX415 模组）----
    output wire         O_cam_scl,          // T9
    inout  wire         IO_cam_sda,         // U9
    output wire         O_cam_24m,          // V9  传感器 INCK
    output wire         O_cam_rst,          // V8
    inout  wire         IO_rx_clk_pad_n,    // MIPI DPHY0（硬核引脚，无需管脚约束）
    inout  wire         IO_rx_clk_pad_p,
    inout  wire [3:0]   IO_rx_data_pad_n,
    inout  wire [3:0]   IO_rx_data_pad_p,

    // ---- 屏幕（DSI 口 + 10.1" 屏）----
    inout  wire         IO_tx_clk_pad_n,    // MIPI DPHY1
    inout  wire         IO_tx_clk_pad_p,
    inout  wire [3:0]   IO_tx_data_pad_n,
    inout  wire [3:0]   IO_tx_data_pad_p,
    output wire         O_dsi_pwm,          // R11 背光
    output wire         O_dsi_rst_n,        // T10 面板复位

    // ---- 尾巴：步进电机（ZDT X42S，UART 115200 8N1，只发不收；括号里是 CEP 排针的物理脚号 / FPGA 管脚）----
    output wire         O_step_tx,          // CEP 15 / E17   → 驱动器 R/A/H 脚（驱动器 GND 接 CEP 脚 2）

    // ---- 喂食检测：霍尔传感器模块（CEP 排针，3.3V；磁铁靠近输出高电平、离开输出低电平）----
    input  wire         I_hall,             // CEP 17 / B17   传感器输出（模块请用 3.3V 供电）

    // ---- 音频：板载 ES8388（耳机口 / 两个喇叭口）----
    output wire         O_aud_mclk,         // F14   MCLK 12.5 MHz
    output wire         O_aud_sclk,         // K13
    output wire         O_aud_lrck,         // C13
    output wire         O_aud_dsdin,        // J13   FPGA → DAC
    output wire         O_aud_cclk,         // A13   I2C SCL
    inout  wire         IO_aud_cdata,       // B14   I2C SDA
    output wire         O_spk_ctl,          // K15   喇叭功放使能（高有效）

    // ---- TF 卡（SPI 模式）----
    output wire         O_sd_cs_n,          // E5    DAT3
    output wire         O_sd_sck,           // D9    CLK
    output wire         O_sd_mosi,          // C9    CMD
    input  wire         I_sd_miso,          // E6    DAT0

    // ---- DDR2（芯片内合封，管脚由 DDR2 IP 自带的 adc 约束）----
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

// =============================================================================
// 配置区（想改画面/时序/排线极性，只改这里）
// =============================================================================
// ---- 摄像头 ----
localparam [3:0] CAM_LANE_INVERT = 4'b0000;    // 不出图且通道错误时，试着把对应 lane 置 1（排线 P/N 接反）
localparam       WIN_W           = 800;        // 送屏的相机窗口宽（像素）= 屏宽，必须是 16 的倍数
localparam       WIN_H           = 560;        // 送屏的相机窗口高（行），WIN_W*WIN_H 必须是 1280 的整数倍（800×560 = 350×1280）
localparam       CROP_X0_GRP     = 141;        // 窗口左边在传感器 1920 宽里的位置：(1920-800)/2/4 + 1
localparam       CROP_Y0         = 261;        // 窗口上边的行号：(1080-560)/2 + 1，必须是奇数（Bayer 相位）
// ---- 屏幕（ILI9881C 10.1" 800×1280，竖屏）----
localparam       PANEL_H         = 800;        // 屏的列数（竖屏时的"宽"）
localparam       PANEL_V         = 1280;       // 屏的行数
localparam [3:0] TPG_MODE        = 4'd9;       // 测试图案：1红 2绿 3蓝 4白 5~8渐变 9马赛克 10斜线 11网格（只在 BG_PATTERN=1 时显示）
localparam       BG_PATTERN      = 0;          // 0：没内容的地方是黑色；1：显示上面的测试图案（排查屏幕链路用）
localparam       RB_SWAP         = 0;          // 红蓝反了就改成 1
// ---- 画面版面（见 mc_mixer.v）：上半相机窗口 v 0~559；中间状态带 v 560~719（方块 v 568~607、文字 v 616~711）；下半 v 720~1279 留给避障 ----
localparam       SQ_V0           = 568;        // 状态方块起始行
localparam       SQ_H            = 40;         // 状态方块高（宽 80）
localparam       OSD_X0          = 40;         // 文字框左上角 u（列）
localparam       OSD_Y0          = 616;        // 文字框左上角 v（行）
localparam       OSD_COLS        = 45;         // 每行字符数（mc_osd_dash 的版面按 45 列排）
localparam       OSD_ROWS        = 3;          // 行数（版面按 3 行排）
localparam       OSD_SH          = 1;          // 字符放大 2^OSD_SH 倍：1 → 每个字符 16×32 像素，字太小就加大到 2（但要缩小行列数）
// ---- 按键 ----
localparam       KEY_LONG_MS     = 800;        // 长按判定时间
localparam       RST_HOLD_MS     = 2000;       // SW1 按住多久整机复位；0 = 取消这个功能
// ---- 尾巴（步进电机，见 mc_tail.v）----
localparam       TAIL_SWING_DEG  = 30;         // 摆幅（度）
localparam       TAIL_GEAR_X100  = 100;        // 减速比×100：尾巴直接装在电机轴上 = 100；电机转 3 圈尾巴转 1 圈 = 300
localparam       TAIL_LEFT_CCW   = 1;          // 向左摆 = 电机逆时针；摆反了就改成 0
localparam       TAIL_RPM        = 80;         // 摇摆转速
localparam       TAIL_LEG_MS     = 150;        // 摇摆每一段的等待时间（要大于走完一段的时间）
localparam       TAIL_INIT_MS    = 1000;       // 上电（或整机复位）后等多久开始回零（等驱动器上电）
localparam       TAIL_HOME_MS    = 2000;       // 发出"单圈就近回零"后等多久再把那里设为坐标零点（要大于回零走完的时间）
// ---- 喂食检测（霍尔传感器，见 mc_hall.v / mc_behavior.v）----
localparam       HALL_DEBOUNCE_MS = 20;        // 去抖时间
// ---- 音频（见 mc_audio.v）----
localparam [5:0] AUD_HP_VOL      = 6'd33;      // 耳机口音量 0~33（30 = 0 dB，每级 1.5 dB；33 = 最大）
localparam [5:0] AUD_SPK_VOL     = 6'd33;      // 喇叭口音量 0~33（33 = 最大 +4.5 dB；破音就改回 30）
localparam [6:0] AUD_BGM_CLIP    = 7'd1;       // 背景音乐 = TF 卡根目录的 1.wav（上电自动循环播放）
localparam [6:0] AUD_EAT_CLIP    = 7'd2;       // 进食音效 = 2.wav
localparam [6:0] AUD_BARK_CLIP   = 7'd3;       // 狗叫音效 = 3.wav
// 混音固定：背景音乐在左喇叭口 J12、音效在右喇叭口 J11（两个口各接一个喇叭）

// =============================================================================
// 1. 时钟：PLL（IP Catalog 生成的 mcsys_pll；输出与厂商 08 例程一致）
// =============================================================================
wire S_clk_100m;        // 主逻辑时钟 / MIPI RX 的 lp_clk
wire S_clk_24m;         // 摄像头 INCK / I2C 配置
wire S_clk_dpll_ref;    // 52.173913 MHz：DSI TX 的 DPLL 参考
wire S_clk_10m;         // DSI 面板 LP 配置
wire S_pll_lock;

// 整机复位 = SW1 按住 RST_HOLD_MS（它跑在晶振时钟上，PLL 被复位时也不会停）。上电时 PLL 自己起振并锁定。
wire S_pll_rst;

mc_hold_reset #(
    .CLK_HZ  (25_000_000),
    .HOLD_MS (RST_HOLD_MS)
) u_hold_rst (
    .I_clk   (I_sys_clk),
    .I_key_n (I_key[0]),
    .O_rst   (S_pll_rst)
);

mcsys_pll u_sys_pll (
    .refclk   (I_sys_clk     ),
    .reset    (S_pll_rst     ),     // 高有效：PLL 失锁 → 全系统复位
    .clk0_out (S_clk_100m    ),
    .clk1_out (S_clk_24m     ),
    .clk2_out (S_clk_dpll_ref),
    .clk3_out (S_clk_10m     ),
    .lock     (S_pll_lock    )
);

// =============================================================================
// 2. 复位 / 节拍（100 MHz 域）
// =============================================================================
wire S_rst_n_100m;

mc_rst_sync u_rst_sync_100m (
    .I_clk    (S_clk_100m  ),
    .I_arst_n (S_pll_lock  ),
    .O_rst_n  (S_rst_n_100m)
);

wire        S_tick_1us;
wire        S_tick_1ms;
wire        S_tick_10ms;
wire        S_tick_100ms;
wire [31:0] S_time_ms;

mc_tick #(
    .CLK_HZ (100_000_000)
) u_mc_tick (
    .I_clk        (S_clk_100m  ),
    .I_rst_n      (S_rst_n_100m),
    .O_tick_1us   (S_tick_1us  ),
    .O_tick_1ms   (S_tick_1ms  ),
    .O_tick_10ms  (S_tick_10ms ),
    .O_tick_100ms (S_tick_100ms),
    .O_time_ms    (S_time_ms   )
);

// =============================================================================
// 3. 按键 + 台架测试（100 MHz 域；以后这里换成你的状态机）
// =============================================================================
wire [2:0]  S_key_pressed;
wire [2:0]  S_key_down;
wire [2:0]  S_key_short;
wire [2:0]  S_key_long;

mc_key #(
    .N           (3),
    .TICK_MS     (10),                     // 与 S_tick_10ms 的周期一致
    .DEBOUNCE_MS (20),
    .LONG_MS     (KEY_LONG_MS)
) u_key (
    .I_clk     (S_clk_100m),
    .I_rst_n   (S_rst_n_100m),
    .I_tick    (S_tick_10ms),              // 10 ms 扫描一次
    .I_key     (I_key),
    .O_pressed (S_key_pressed),
    .O_down    (S_key_down),
    .O_short   (S_key_short),
    .O_long    (S_key_long)
);

wire [1:0]  S_cam_key_n;                       // 相机增益键（低有效脉冲，SW2/SW3 短按）
wire        S_sfx_busy;
wire        S_hall_fed;                                 // 霍尔：1 = 正在喂食（磁铁靠近）
wire        S_beh_wag;                                  // 行为层：喂食时让尾巴摇一个来回
wire        S_beh_sfx_play;                             // 行为层：触发音效
wire [6:0]  S_beh_sfx_clip;
wire        S_audio_ready;
wire [1:0]  S_sfx_state;

mc_bench u_bench (
    .I_clk        (S_clk_100m),
    .I_rst_n      (S_rst_n_100m),
    .I_tick_10ms  (S_tick_10ms),
    .I_key_short  (S_key_short),
    .O_cam_key_n  (S_cam_key_n)
);

// =============================================================================
// 4. 尾巴：上电回零 / 摇摆（步进电机，UART 只发）
// =============================================================================
wire        S_tail_busy;
wire [1:0]  S_tail_seq;                                 // 0 空闲 1 回零 2 摇摆（屏幕文字显示）

mc_tail #(
    .CLK_HZ       (100_000_000),
    .BAUD         (115200),
    .SWING_DEG    (TAIL_SWING_DEG),
    .GEAR_X100    (TAIL_GEAR_X100),
    .LEFT_IS_CCW  (TAIL_LEFT_CCW),
    .RPM          (TAIL_RPM),
    .LEG_MS       (TAIL_LEG_MS),
    .HOME_MS      (TAIL_HOME_MS),
    .INIT_DELAY_MS(TAIL_INIT_MS)
) u_tail (
    .I_clk       (S_clk_100m),
    .I_rst_n     (S_rst_n_100m),
    .I_tick_1ms  (S_tick_1ms),
    .I_cmd_wag   (S_beh_wag),                       // 喂食时行为层给的
    .O_busy      (S_tail_busy),
    .O_seq       (S_tail_seq),
    .O_tx        (O_step_tx)
);

// =============================================================================
// 5. 图像通路：相机 → 帧缓存 → 屏幕
// =============================================================================
wire         S_cam_pix_clk;
wire         S_cam_pix_fs;
wire         S_cam_pix_valid;
wire [127:0] S_cam_pix_data;
wire         S_cam_cfg_done;
wire [3:0]   S_cam_lane_error;
wire         S_csi_frame_tog;
wire         S_isp_frame_tog;
wire [7:0]   S_cam_ae;

// 相机增益键 S_cam_key_n 来自 mc_bench：第 0 页的 SW2/SW3 短按 → 40 ms 低电平脉冲

mc_cam_if #(
    .LANE_INVERT (CAM_LANE_INVERT),
    .CROP_X0_GRP (CROP_X0_GRP),
    .CROP_W_GRP  (WIN_W / 4),
    .CROP_Y0     (CROP_Y0),
    .CROP_H      (WIN_H),
    .IMG_W       (WIN_W),
    .IMG_H       (WIN_H)
) u_cam (
    .I_rst_n           (S_pll_lock),
    .I_clk_100m        (S_clk_100m),
    .I_clk_24m         (S_clk_24m),
    .I_key_n           (S_cam_key_n),

    .O_cam_scl         (O_cam_scl),
    .IO_cam_sda        (IO_cam_sda),
    .O_cam_clk         (O_cam_24m),
    .O_cam_rst         (O_cam_rst),

    .IO_rx_clk_pad_n   (IO_rx_clk_pad_n),
    .IO_rx_clk_pad_p   (IO_rx_clk_pad_p),
    .IO_rx_data_pad_n  (IO_rx_data_pad_n),
    .IO_rx_data_pad_p  (IO_rx_data_pad_p),

    .O_pix_clk         (S_cam_pix_clk),
    .O_pix_frame_start (S_cam_pix_fs),
    .O_pix_valid       (S_cam_pix_valid),
    .O_pix_data        (S_cam_pix_data),

    .O_cfg_done        (S_cam_cfg_done),
    .O_ae              (S_cam_ae),
    .O_lane_error      (S_cam_lane_error),
    .O_csi_frame_tog   (S_csi_frame_tog),
    .O_isp_frame_tog   (S_isp_frame_tog)
);

wire        S_dsi_clk;
wire        S_dsi_vsync;
wire        S_dsi_rd_en;
wire [23:0] S_dsi_rd_data;
wire        S_ddr_ready;

mc_framebuf u_fb (
    .I_rst_n           (S_pll_lock),
    .I_clk_sys         (I_sys_clk),

    .I_cam_clk         (S_cam_pix_clk),
    .I_cam_frame_start (S_cam_pix_fs),
    .I_cam_valid       (S_cam_pix_valid),
    .I_cam_data        (S_cam_pix_data),

    .I_dsi_clk         (S_dsi_clk),
    .I_dsi_vsync       (S_dsi_vsync),
    .I_dsi_rd_en       (S_dsi_rd_en),
    .O_dsi_data        (S_dsi_rd_data),

    .O_ddr_ready       (S_ddr_ready),

    .ddr_addr          (ddr_addr),
    .ddr_ba            (ddr_ba),
    .ddr_cke           (ddr_cke),
    .ddr_odt           (ddr_odt),
    .ddr_cs_n          (ddr_cs_n),
    .ddr_ras_n         (ddr_ras_n),
    .ddr_cas_n         (ddr_cas_n),
    .ddr_we_n          (ddr_we_n),
    .ddr_ck_p          (ddr_ck_p),
    .ddr_ck_n          (ddr_ck_n),
    .ddr_dm            (ddr_dm),
    .ddr_dq            (ddr_dq),
    .ddr_dqs_p         (ddr_dqs_p),
    .ddr_dqs_n         (ddr_dqs_n)
);

// ---- 状态汇总（全部同步到 100 MHz 域）----
wire S_ddr_ready_s;
wire S_cam_cfg_done_s;
wire S_panel_ready_s;
wire S_lane_error_s;
wire S_csi_tog_s;
wire S_isp_tog_s;
wire S_panel_ready;

mc_sync_bits #(.W(5)) u_sync_status (
    .I_clk (S_clk_100m),
    .I_d   ({S_ddr_ready, S_cam_cfg_done, S_panel_ready, |S_cam_lane_error, S_csi_frame_tog}),
    .O_q   ({S_ddr_ready_s, S_cam_cfg_done_s, S_panel_ready_s, S_lane_error_s, S_csi_tog_s})
);

mc_sync_bits #(.W(1)) u_sync_isp (
    .I_clk (S_clk_100m),
    .I_d   (S_isp_frame_tog),
    .O_q   (S_isp_tog_s)
);

wire S_csi_alive;
wire S_isp_alive;

mc_activity_mon #(.TIMEOUT_MS(100)) u_alive_csi (
    .I_clk(S_clk_100m), .I_rst_n(S_rst_n_100m), .I_tick_1ms(S_tick_1ms),
    .I_toggle(S_csi_tog_s), .O_alive(S_csi_alive)
);

mc_activity_mon #(.TIMEOUT_MS(100)) u_alive_isp (
    .I_clk(S_clk_100m), .I_rst_n(S_rst_n_100m), .I_tick_1ms(S_tick_1ms),
    .I_toggle(S_isp_tog_s), .O_alive(S_isp_alive)
);

wire S_heartbeat = S_time_ms[9];                    // ≈ 1 Hz

// 屏幕上的 8 个状态方块（绿=1 红=0），从左到右：
//   [0]心跳(每秒红绿交替)  [1]DDR 校准完成  [2]面板初始化完成  [3]相机寄存器配置完成
//   [4]MIPI 收到 CSI 帧     [5]ISP 帧进入帧缓存  [6]无 MIPI 通道错误  [7]常绿（红绿色序参考）
wire [7:0] S_status = {1'b1, ~S_lane_error_s, S_isp_alive, S_csi_alive,
                       S_cam_cfg_done_s, S_panel_ready_s, S_ddr_ready_s, S_heartbeat};

// ---- 音频：TF 卡里的 WAV → ES8388 → 耳机口 / 喇叭口（见 mc_audio.v；曲目 N = TF 卡根目录的 N.wav）----
//   背景音乐（AUD_BGM_CLIP.wav）上电自动循环播放（左声道 J12）；音效（行为层触发）走另一路（右声道 J11），同时播放
wire [2:0]  S_aud_sd;
wire [1:0]  S_aud_codec;
wire [1:0]  S_bgm_state;

mc_audio #(
    .CLK_HZ    (100_000_000),
    .HP_VOL    (AUD_HP_VOL),
    .SPK_VOL   (AUD_SPK_VOL),
    .BGM_CLIP  (AUD_BGM_CLIP)
) u_audio (
    .I_clk         (S_clk_100m),
    .I_rst_n       (S_rst_n_100m),
    .I_tick_1ms    (S_tick_1ms),

    .I_sfx_play    (S_beh_sfx_play),
    .I_sfx_clip    (S_beh_sfx_clip),

    .O_sd_state    (S_aud_sd),
    .O_codec_state (S_aud_codec),
    .O_nclips      (),
    .O_ready       (S_audio_ready),
    .O_bgm_state   (S_bgm_state),
    .O_bgm_err     (),
    .O_bgm_ur      (),
    .O_sfx_state   (S_sfx_state),
    .O_sfx_cur     (),
    .O_sfx_err     (),
    .O_sfx_ur      (),
    .O_sfx_busy    (S_sfx_busy),

    .O_aud_mclk    (O_aud_mclk),
    .O_aud_sclk    (O_aud_sclk),
    .O_aud_lrck    (O_aud_lrck),
    .O_aud_dsdin   (O_aud_dsdin),
    .O_aud_cclk    (O_aud_cclk),
    .IO_aud_cdata  (IO_aud_cdata),
    .O_spk_ctl     (O_spk_ctl),

    .O_sd_cs_n     (O_sd_cs_n),
    .O_sd_sck      (O_sd_sck),
    .O_sd_mosi     (O_sd_mosi),
    .I_sd_miso     (I_sd_miso)
);

// ---- 喂食检测：霍尔传感器（磁铁放在食物模型上，靠近 = 1）----
mc_hall #(
    .DEBOUNCE_MS (HALL_DEBOUNCE_MS)
) u_hall (
    .I_clk      (S_clk_100m),
    .I_rst_n    (S_rst_n_100m),
    .I_tick_1ms (S_tick_1ms),
    .I_hall     (I_hall),
    .O_fed      (S_hall_fed)
);

// ---- 行为层：喂食时摇尾巴 + 播进食音效；UWB 的"距离 < 5 m 摇尾巴"、"丢了 / 太远就叫"以后接 I_near / I_bark（现在接 0）----
mc_behavior #(
    .EAT_CLIP    (AUD_EAT_CLIP),
    .BARK_CLIP   (AUD_BARK_CLIP)
) u_behavior (
    .I_clk         (S_clk_100m),
    .I_rst_n       (S_rst_n_100m),
    .I_hall        (S_hall_fed),
    .I_near        (1'b0),
    .I_bark        (1'b0),
    .I_audio_ready (S_audio_ready),
    .I_sfx_busy    (S_sfx_busy),
    .I_sfx_state   (S_sfx_state),
    .I_tail_busy   (S_tail_busy),
    .O_tail_wag    (S_beh_wag),
    .O_sfx_play    (S_beh_sfx_play),
    .O_sfx_clip    (S_beh_sfx_clip)
);

// ---- 屏幕文字层：状态带里的 3 行文字（版面见 mc_osd_dash.v）----
wire [19:0] S_osd_bus;

mc_osd_dash #(
    .ROWS (OSD_ROWS),
    .COLS (OSD_COLS)
) u_dash (
    .I_clk         (S_clk_100m),
    .I_rst_n       (S_rst_n_100m),
    .I_tick_1ms    (S_tick_1ms),
    .I_tick_100ms  (S_tick_100ms),

    .I_key_pressed (S_key_pressed),
    .I_key_short   (S_key_short),
    .I_key_long    (S_key_long),

    .I_cam_ae      (S_cam_ae),
    .I_hall        (S_hall_fed),
    .I_tail_seq    (S_tail_seq),

    .I_aud_sd      (S_aud_sd),
    .I_aud_codec   (S_aud_codec),
    .I_bgm_state   (S_bgm_state),
    .I_sfx_state   (S_sfx_state),

    .O_bus         (S_osd_bus)
);

mc_disp_if #(
    .H_ACTIVE   (PANEL_H),
    .V_ACTIVE   (PANEL_V),
    .IMG_W      (WIN_W),
    .IMG_H      (WIN_H),
    .SQ_V0      (SQ_V0),
    .SQ_H       (SQ_H),
    .TPG_MODE   (TPG_MODE),
    .BG_PATTERN (BG_PATTERN),
    .RB_SWAP    (RB_SWAP),
    .TXT_U0     (OSD_X0),
    .TXT_V0     (OSD_Y0),
    .TXT_COLS   (OSD_COLS),
    .TXT_ROWS   (OSD_ROWS),
    .TXT_SH     (OSD_SH)
) u_disp (
    .I_rst_n         (S_pll_lock),
    .I_clk_dpll_ref  (S_clk_dpll_ref),
    .I_clk_lp        (S_clk_10m),

    .O_dsi_clk       (S_dsi_clk),
    .O_vsync         (S_dsi_vsync),
    .O_rd_en         (S_dsi_rd_en),
    .I_rd_data       (S_dsi_rd_data),

    .I_win_en        (S_isp_alive),
    .I_status        (S_status),
    .O_panel_ready   (S_panel_ready),

    .I_txt_clk       (S_clk_100m),
    .I_txt_bus       (S_osd_bus),

    .O_dsi_pwm       (O_dsi_pwm),
    .O_dsi_rst_n     (O_dsi_rst_n),

    .IO_tx_clk_pad_n  (IO_tx_clk_pad_n),
    .IO_tx_clk_pad_p  (IO_tx_clk_pad_p),
    .IO_tx_data_pad_n (IO_tx_data_pad_n),
    .IO_tx_data_pad_p (IO_tx_data_pad_p)
);

// =============================================================================
// 6. 状态灯（屏幕还没亮的时候，靠它判断卡在哪一级）
//    LED1  约 1 Hz 闪烁 = PLL 与节拍正常
//    LED2  灭 = DDR2 校准未完成 ／ 闪(约 2 Hz) = DDR 好了、屏幕初始化脚本还没发完 ／ 亮 = 显示部分全部就绪
//    LED3  灭 = 相机寄存器还没配完 ／ 闪 = 配完了但没有图像帧进来 ／ 亮 = 图像帧持续进入帧缓存
// =============================================================================
wire S_blink2hz = S_time_ms[8];
assign O_led[0] = S_heartbeat;
assign O_led[1] = S_ddr_ready_s ? (S_panel_ready_s ? 1'b1 : S_blink2hz) : 1'b0;
assign O_led[2] = S_isp_alive   ? 1'b1 : (S_cam_cfg_done_s ? S_blink2hz : 1'b0);

endmodule
