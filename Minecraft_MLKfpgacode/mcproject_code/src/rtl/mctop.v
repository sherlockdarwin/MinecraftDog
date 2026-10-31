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
//   SW1~SW3 ─► mc_key(短按/长按) ─► mc_bench(SW2/SW3 短按 → 相机亮度键)
//   TF 卡 ─ WAV ─► mc_audio ─► ES8388 ─► 喇叭（背景音乐上电自动循环 + 进食音效，同时播）
//   霍尔传感器 ─► mc_hall ─► mc_behavior（喂食：进食音效；以后 UWB 的"丢了就叫"也接这里）─► mc_audio（尾巴 mc_tail 2026-10-25 不用了，注释掉）
//   各模块的状态 ─► mc_osd_dash ─文字写入总线─► mc_disp_if 里的文字层 ─► 画面中间状态带的 5 行文字
//   STM32（UWB：主人在哪）─UART─► mc_m0_link ─► mc_follow（+ 避障结果 + 陀螺仪角度环）─► 两个轮子的 PWM ─UART─► STM32（电机）
//   JY61P 陀螺仪 ─UART─► mc_imu_jy61p（上电自动配置、车停稳后航向角归零）─► 车头航向 / 角速度 ─► mc_follow、屏幕第 6 行
//   （轮子的控制放在另一块单片机上，这里没有电机驱动 / 编码器）
// 画面：竖屏 800×1280，上半相机、中间状态带、下半避障处理画面；厂商 video_out 顺序读帧缓存，版面见 mc_mixer.v
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

    // ---- 尾巴：步进电机（ZDT X42S，UART 115200 8N1，只发不收）——2026-10-25 不用了，注释掉（恢复见第 4 节）----
//  output wire         O_step_tx,          // CEP 15 / E17   → 驱动器 R/A/H 脚（驱动器 GND 接 CEP 脚 2）

    // ---- 喂食检测：霍尔传感器模块（CEP 排针，3.3V 供电；磁铁靠近输出低电平、离开输出高电平）----
    input  wire         I_hall_n,           // CEP 17 / B17   传感器输出（低 = 磁铁靠近；脚上开了上拉，没接模块 = 没喂食）

    // ---- STM32（轮子 + UWB，工程 Minecraft_MCU/MinecraftDog_STM32）：UART 115200 8N1，ASCII 帧见 mc_m0_link.v；STM32 的 GND 接 CEP 脚 2 ----
    output wire         O_m0_tx,            // CEP 3 / L15    → STM32 PB11（USART3 RX）
    input  wire         I_m0_rx,            // CEP 4 / L16    ← STM32 PB10（USART3 TX；脚上开了上拉，没接 = 一直空闲）

    // ---- 陀螺仪 JY61P（维特，UART，模块 VCC 接 CEP 脚 1 的 3.3 V、GND 接脚 2）：出厂 9600 → FPGA 上电自动改成 115200、100 Hz ----
    output wire         O_imu_tx,           // CEP 5 / H14    → JY61P RX
    input  wire         I_imu_rx,           // CEP 6 / H13    ← JY61P TX（脚上开了上拉）

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
// ---- 摄像头（完整视场：传感器的 1920×1080 等比缩小 2.4 倍 → 800×448，见 mc_scale.v；画面偏暗 / 偏亮由自动曝光 mc_ae 调）----
localparam [3:0] CAM_LANE_INVERT = 4'b0000;    // 不出图且通道错误时，试着把对应 lane 置 1（排线 P/N 接反）
localparam       CROP_X0_GRP     = 1;          // 1920×1080 在传感器每行 1944 像素里从第 4 个开始（1 组 = 4 像素）
localparam       CROP_Y0         = 13;         // 从第 13 行开始（必须是奇数：Bayer 相位）；传感器有效行 1~1095，录像区 11~1090
localparam       WIN_W           = 800;        // 送屏的相机窗口宽 = 1920 / 2.4（固定，由 mc_scale 决定）
localparam       WIN_H           = 448;        // 送屏的相机窗口高：1080 / 2.4 = 450，帧缓存要求 WIN_W*WIN_H 是 1280 的倍数 → 448（丢最后 2 行）
// ---- 屏幕（ILI9881C 10.1" 800×1280，竖屏）----
localparam       PANEL_H         = 800;        // 屏的列数（竖屏时的"宽"）
localparam       PANEL_V         = 1280;       // 屏的行数
localparam [3:0] TPG_MODE        = 4'd9;       // 测试图案：1红 2绿 3蓝 4白 5~8渐变 9马赛克 10斜线 11网格（只在 BG_PATTERN=1 时显示）
localparam       BG_PATTERN      = 0;          // 0：没内容的地方是黑色；1：显示上面的测试图案（排查屏幕链路用）
// ---- 画面版面（见 mc_mixer.v）：相机窗口 v 0~447；状态带（方块 v 452~491、文字 6 行 v 496~687、Logo v 690~817）；避障画面 v 830~1279（上方 v 820~827 是建议方向的绿条）----
localparam       SQ_V0           = 452;        // 状态方块起始行
localparam       SQ_H            = 40;         // 状态方块高（宽 80）
localparam       OSD_X0          = 40;         // 文字框左上角 u（列）
localparam       OSD_Y0          = 496;        // 文字框左上角 v（行）
localparam       OSD_COLS        = 45;         // 每行字符数（mc_osd_dash 的版面按 45 列排）
localparam       OSD_ROWS        = 6;          // 行数（版面按 6 行排；第 6 行是陀螺仪）
localparam       LOGO_U0         = 160;        // 安路 Logo（480×128 白底横幅，比赛要求）左上角：水平居中，放在文字框（到 v 687）和避障方向条（v 820）之间
localparam       LOGO_V0         = 690;
localparam       OSD_SH          = 1;          // 字符放大 2^OSD_SH 倍：1 → 每个字符 16×32 像素，字太小就加大到 2（但要缩小行列数）
// ---- 避障（见 mc_obs*.v；镜头离地 174 mm、竖直装，按上车实测（灰线处 1.35 m、左右宽 1.7 m）反推的倾角和焦距写在 tools/gen_obs_lut.pl）----
localparam [10:0] OBS_V0         = 11'd830;    // 避障处理画面起始行（800×450 = 160×90 格 × 5）
localparam [7:0]  OBS_REF_X0     = 8'd56;      // 地面参考区（网格坐标，160×90，最多 511 格）：车正前方、画面最下面 48 列 × 8 行（约 49~58 cm 远）
localparam [7:0]  OBS_REF_X1     = 8'd103;
localparam [6:0]  OBS_REF_Y0     = 7'd82;
localparam [6:0]  OBS_REF_Y1     = 7'd89;
localparam [11:0] OBS_TC         = 12'd12;     // 地面颜色门限：越大越容易把东西判成障碍
localparam [11:0] OBS_TY         = 12'd12;
localparam [2:0]  OBS_YSPREAD    = 3'd2;       // 地面亮度宽容度（每格 16 级）：反光 / 阴影的地面被判成障碍就加大（最大 7），和地面一样灰的东西判不出来就减小（10-30：回到最开始的 2，识别更灵敏；4 太宽、3 偏宽）
localparam [6:0]  OBS_ROW_MIN    = 7'd53;      // 判断画面第 53~89 行（160×90 网格）= 镜头前约 49 cm ~ 2.36 m（10-30 由 60 = 1.35 m 改远，给 AVOID_FAR_CM 提前绕用；1~1.35 m 的照样只是"看得见、不算挡路"）。第 52 行以上 > 2.5 m、第 44 行以上是地平线以上，没有距离。第 60 行 1.35 m、55 行约 2 m、70 行约 84 cm，见 mc_obs_lut.v
localparam [7:0]  OBS_D_CAP      = 8'd150;     // 选方向最远算到多少厘米
localparam [7:0]  OBS_D_STOP     = 8'd60;      // 最好的方向也不到这么远（厘米）→ 屏幕第 4 行 STOP、不画绿条（镜头竖直装最近只看得到约 49 cm，和 AVOID_SPIN_CM 一样取 60）
// ---- 跟随 + 避障决策 + 角度环（mc_follow，每 20 ms 一次，PWM 满量程 8000；运行逻辑见 obstacle.md §6）----
// 跟随（前进量、原地转的条件和 STM32 follow.h 一样；转向改成陀螺仪角度环）
localparam       FOLLOW_STOP_CM     = 200;     // 离主人这么近就停，再远就走过去（10-30：3 m 改成 2 m。别再小于约 1.5 m：主人的脚进了 1 m 会被当成挡路）
localparam       FOLLOW_START_PWM   = 3300;    // 起步（600 推不动，2500 能走；10-30 由 3000 提高到 3300）
localparam       FOLLOW_KP_D        = 10;      // 每远 1 cm 多加多少
localparam       FOLLOW_MAX_FWD     = 5000;
localparam       FOLLOW_ANGLE_FILTER= 3;       // 主人方向平滑：每次只跟上新方向的 1/3
localparam       FOLLOW_DEADBAND    = 4;       // 主人方向和现在的目标航向差不到 4° 就不改目标（一段一段走直线；3 在 UWB 跳动大时会左右摆）
localparam       FOLLOW_PIVOT_ENTER = 90;      // 偏超过 90° 并保持 FOLLOW_PIVOT_MS 才原地转
localparam       FOLLOW_PIVOT_MS    = 300;
localparam       FOLLOW_PIVOT_EXIT  = 40;      // 转到 40° 以内再往前走（剩下的交给角度环）
localparam       FOLLOW_PIVOT_PWM   = 2200;    // 原地转时两轮一正一反
localparam       FOLLOW_MAX_WHEEL   = 6500;
localparam       FOLLOW_ACC         = 200;     // 前进斜坡：每 20 ms 最多加 / 减
localparam       FOLLOW_DEC         = 400;
localparam       FOLLOW_TURN_SLEW   = 600;     // 转向每 20 ms 最多变多少
localparam       FOLLOW_CMS_FULL    = 92;      // 满量程 8000 时车每秒走多少厘米（没测过，估的；只用来把 AVOID_HOLD_CM 换成"前进量 × 时间"）
// 角度环（陀螺仪；转向 = KP × 误差 + KI × 误差积分 − KD × 角速度，见 obstacle.md §6 ⑤，还没上车调）
localparam       HEAD_KP            = 55;      // 每 1° 误差转多少 PWM：转得慢 / 拐不过去 → 加大；左右摆 → 减小
localparam       HEAD_KI            = 20;      // 每 1° 误差每秒累加多少 PWM：走直线时一直偏一点 → 加大
localparam       HEAD_KD            = 8;       // 每 1°/s 角速度减多少 PWM：冲过头、来回摆 → 加大
localparam       HEAD_I_MAX         = 400;     // 积分最多补多少 PWM（两个电机快慢不一样的差）
localparam       HEAD_I_ZONE        = 10;      // 误差在 10° 以内才积分（积分分离）
localparam       HEAD_TURN_MAX      = 800;     // 跟随（GO）时转向最多多少 PWM
// 避障（FPGA 加的，还没上车调）
localparam       AVOID_CM           = 100;     // 正前方或主人方向不到这么远 = 挡路；绕行方向先挑能走这么远的
localparam       AVOID_CLEAR_CM     = 60;      // 实在没有，退一步挑能走这么远的；再没有就找出口（AVOID_SCAN_*）
localparam       AVOID_SPIN_CM      = 60;      // 正前方不到这么远：原地转向能走的方向（SPIN）。镜头竖直装，最近只看得到约 49 cm（画面最下面 9 行 = 49~59 cm）
localparam       AVOID_KP_OBS       = 20;      // 前进上限 = 起步 + (前面能走多远 − AVOID_CLEAR_CM) × 这个
localparam       AVOID_SPIN_PWM     = 2200;
localparam       AVOID_TURN_MAX     = 1200;    // 绕行（AVD）时转向最多多少 PWM
localparam       AVOID_HOLD_CM      = 50;      // 绕过去以后先保持航向直走多远（约一个车长）再朝主人转（障碍出了视场还在旁边；10-30 由 0.5 s 改成按距离）；这段里也不原地转
localparam       AVOID_W_TGT        = 2;       // 挑方向的代价 = W_TGT × |方向 − 主人| + W_PREV × |方向 − 上次绕的方向|
localparam       AVOID_W_PREV       = 1;
localparam       AVOID_FAR_CM       = 200;     // 远处挡路：主人在前面（±17° 左右）、那个方向 2 m 以内有东西 → 提前挑别的方向绕（改成 ≤ AVOID_CM 就不提前绕）
localparam       AVOID_OWNER_GAP_CM = 60;      //   只算比主人（UWB 距离）近 60 cm 以上的：再远的可能是主人自己的腿
localparam       AVOID_SCAN_DEG     = 20;      // 哪边都走不了（都 < AVOID_CLEAR_CM）：原地一步转 20°（往主人那边）……
localparam       AVOID_SCAN_PAUSE_MS= 200;     //   ……每步停 0.2 s 看清楚；转满一圈还没有出口 → 困住：停着、狗叫
localparam       AVOID_SCAN_STEP_MS = 1000;    //   一步转了 1 s 还没转够 20°（电机推不动）也算一步
// ---- 按键 ----
localparam       KEY_LONG_MS     = 800;        // 长按判定时间
localparam       RST_HOLD_MS     = 2000;       // SW1 按住多久整机复位；0 = 取消这个功能
// // ---- 尾巴（步进电机，见 mc_tail.v）----
// localparam       TAIL_SWING_DEG  = 45;         // 摆幅（度）（和 STM32 tail.h 一样：45°、10 RPM、两头停 50 ms、中间停 500 ms）
// localparam       TAIL_GEAR_X100  = 100;        // 减速比×100：尾巴直接装在电机轴上 = 100；电机转 3 圈尾巴转 1 圈 = 300
// localparam       TAIL_LEFT_CCW   = 1;          // 向左摆 = 电机逆时针；摆反了就改成 0
// localparam       TAIL_RPM        = 10;         // 摇摆转速（走完一段的时间按摆幅和转速自动算：45°、10 RPM = 750 ms）
// localparam       TAIL_SIDE_MS    = 50;         // 摆到左 / 右两头后停多久
// localparam       TAIL_CENTER_MS  = 500;        // 回到中间停多久
// localparam       TAIL_INIT_MS    = 1000;       // 上电（或整机复位）后等多久开始回零（等驱动器上电）
// localparam       TAIL_HOME_MS    = 2000;       // 发出"单圈就近回零"后等多久再把那里设为坐标零点（要大于回零走完的时间）
// ---- 喂食检测（霍尔传感器，见 mc_hall.v / mc_behavior.v）----
localparam       HALL_DEBOUNCE_MS = 20;        // 去抖时间
// ---- 音频（见 mc_audio.v）----
localparam [5:0] AUD_SPK_VOL     = 6'd22;      // 喇叭音量：寄存器值 0~33，不是 dB；增益 = (值 − 30) × 1.5 dB（33 = +4.5 dB 最大，30 = 0 dB，22 = −12 dB，18 = −18 dB）。33 太响：喇叭尖叫、功放把电源拉低、屏幕变灰（10-23）。耳机口不用（ES8388 的耳机输出关了）
localparam [6:0] AUD_BGM_CLIP    = 7'd1;       // 背景音乐 = TF 卡根目录的 1.wav（上电自动循环播放）
localparam [6:0] AUD_EAT_CLIP    = 7'd2;       // 进食音效 = 2.wav
localparam [6:0] AUD_BARK_CLIP   = 7'd3;       // 狗叫音效 = 3.wav
localparam       BARK_CM         = 999;        // 主人这么远（厘米）就叫：STM32 超过 999 cm 都发 999，所以现在 = 10 m 以上（要 20 m 得把协议改成 4 位距离）
localparam       BARK_MS         = 1000;       // 太远 / 收不到 UWB 要连续这么久才叫（STM32 的线不通不叫）；困住（转一圈没出口）马上叫
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

wire [1:0]  S_cam_key_n;                       // 相机亮度键（低有效脉冲，SW2/SW3 短按）
wire        S_sfx_busy;
wire        S_hall_fed;                                 // 霍尔：1 = 正在喂食（磁铁靠近）
// wire        S_beh_wag;                               // 行为层：喂食时让尾巴摇一个来回（尾巴注释掉了）
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
//    2026-10-25 不用了，整段注释掉（mc_tail.v / mc_stepper_emm.v 文件还在）。恢复：去掉这一段和配置区 TAIL_* 的注释、
//    端口 O_step_tx 的注释、mc_pin.adc 里 O_step_tx 那一行的注释，再把行为层的 I_tail_busy / O_tail_wag、文字面板的 I_tail_seq 接回来。
// =============================================================================
// wire        S_tail_busy;
// wire [1:0]  S_tail_seq;                                 // 0 空闲 1 回零 2 摇摆（屏幕文字显示）
// 
// mc_tail #(
//     .CLK_HZ       (100_000_000),
//     .BAUD         (115200),
//     .SWING_DEG    (TAIL_SWING_DEG),
//     .GEAR_X100    (TAIL_GEAR_X100),
//     .LEFT_IS_CCW  (TAIL_LEFT_CCW),
//     .RPM          (TAIL_RPM),
//     .SIDE_PAUSE_MS(TAIL_SIDE_MS),
//     .CENTER_PAUSE_MS(TAIL_CENTER_MS),
//     .HOME_MS      (TAIL_HOME_MS),
//     .INIT_DELAY_MS(TAIL_INIT_MS)
// ) u_tail (
//     .I_clk       (S_clk_100m),
//     .I_rst_n     (S_rst_n_100m),
//     .I_tick_1ms  (S_tick_1ms),
//     .I_cmd_wag   (S_beh_wag),                       // 喂食时行为层给的
//     .O_busy      (S_tail_busy),
//     .O_seq       (S_tail_seq),
//     .O_tx        (O_step_tx)
// );

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
wire         S_isp_fs;                         // 白平衡后的 1920×1080（给避障）
wire         S_isp_valid;
wire [95:0]  S_isp_data;
wire [7:0]   S_cam_gain;                       // 自动曝光的增益 / 曝光行数 / 亮度档（屏幕文字显示）
wire [11:0]  S_cam_exp;
wire [3:0]   S_cam_ev;

// 亮度键 S_cam_key_n 来自 mc_bench：SW2/SW3 短按 → 40 ms 低电平脉冲（自动曝光的目标亮度 +/− 一档）

mc_cam_if #(
    .LANE_INVERT (CAM_LANE_INVERT),
    .CROP_X0_GRP (CROP_X0_GRP),
    .CROP_Y0     (CROP_Y0),
    .OUT_H       (WIN_H)
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
    .O_ae_gain         (S_cam_gain),
    .O_ae_exp          (S_cam_exp),
    .O_ae_ev           (S_cam_ev),
    .O_lane_error      (S_cam_lane_error),
    .O_csi_frame_tog   (S_csi_frame_tog),
    .O_isp_frame_tog   (S_isp_frame_tog),
    .O_isp_fs          (S_isp_fs),
    .O_isp_valid       (S_isp_valid),
    .O_isp_data        (S_isp_data)
);

// ---- 避障：白平衡后的 1920×1080 → 160×90 → 地面 / 障碍 → 方向、框（相机像素时钟域）----
wire [24:0]  S_obs_wbus;
wire         S_obs_pub_bank, S_obs_pub_valid, S_obs_disp_bank;
wire [5:0]   S_obs_go;
wire [3:0]   S_obs_go_head;
wire [71:0]  S_obs_head_free;                  // 方向 4~12 各能走多远（给跟随决策）
wire         S_obs_res_tog;                    // 每帧结果翻转一次
wire [6:0]   S_obs_go_deg, S_obs_near_deg;
wire [7:0]   S_obs_go_free, S_obs_near;
wire         S_obs_stop;

mc_obs #(
    .REF_X0 (OBS_REF_X0), .REF_X1 (OBS_REF_X1), .REF_Y0 (OBS_REF_Y0), .REF_Y1 (OBS_REF_Y1),
    .TC (OBS_TC), .TY (OBS_TY), .YSPREAD (OBS_YSPREAD), .ROW_MIN (OBS_ROW_MIN), .D_CAP (OBS_D_CAP), .D_STOP (OBS_D_STOP)
) u_obs (
    .I_clk       (S_cam_pix_clk),
    .I_rst_n     (S_pll_lock),
    .I_fs        (S_isp_fs),
    .I_valid     (S_isp_valid),
    .I_data      (S_isp_data),
    .O_wbus      (S_obs_wbus),
    .O_pub_bank  (S_obs_pub_bank),
    .O_pub_valid (S_obs_pub_valid),
    .O_go        (S_obs_go),
    .I_disp_bank (S_obs_disp_bank),
    .O_done      (),
    .O_sec_dist  (),
    .O_go_head   (S_obs_go_head),
    .O_go_deg    (S_obs_go_deg),
    .O_go_free   (S_obs_go_free),
    .O_stop      (S_obs_stop),
    .O_near_cm   (S_obs_near),
    .O_near_deg  (S_obs_near_deg),
    .O_head_free (S_obs_head_free),
    .O_res_tog   (S_obs_res_tog)
);

// ---- 跟随：STM32 送来主人在哪 → 决策（+ 避障结果）→ 两个轮子的 PWM 送回 STM32（100 MHz 域）----
wire               S_uwb_ok;
wire               S_uwb_link;                         // 300 ms 内收到过 STM32 的字节（屏幕上区分 LOST / NOLK）
wire signed [7:0]  S_uwb_deg;
wire [9:0]         S_uwb_cm;
wire               S_cmd_valid, S_cmd_stop;
wire signed [13:0] S_cmd_l, S_cmd_r;
wire [3:0]         S_cmd_state;
wire               S_follow_stuck;                     // 转了一圈没有出口（狗叫）

mc_m0_link u_m0 (
    .I_clk       (S_clk_100m),
    .I_rst_n     (S_rst_n_100m),
    .I_tick_1ms  (S_tick_1ms),
    .I_rx        (I_m0_rx),
    .O_tx        (O_m0_tx),
    .O_tgt_ok    (S_uwb_ok),
    .O_tgt_deg   (S_uwb_deg),
    .O_tgt_cm    (S_uwb_cm),
    .O_rx_alive  (S_uwb_link),
    .I_cmd_valid (S_cmd_valid),
    .I_cmd_stop  (S_cmd_stop),
    .I_cmd_l     (S_cmd_l),
    .I_cmd_r     (S_cmd_r)
);

// ---- 陀螺仪：JY61P（UART）→ 车头航向、Z 角速度（右转为正，上电车停稳后归零）----
wire               S_imu_ok;
wire [2:0]         S_imu_state;                        // 0 NOLK 1 CFG 2 WAIT 3 OK 4 LOST（屏幕）
wire signed [15:0] S_imu_yaw, S_imu_gz;
wire signed [8:0]  S_imu_yaw_deg;
wire signed [11:0] S_imu_gz_dps;
wire signed [8:0]  S_head_tgt_deg;

mc_imu_jy61p u_imu (
    .I_clk       (S_clk_100m),
    .I_rst_n     (S_rst_n_100m),
    .I_tick_1ms  (S_tick_1ms),
    .I_rx        (I_imu_rx),
    .O_tx        (O_imu_tx),
    .O_ok        (S_imu_ok),
    .O_state     (S_imu_state),
    .O_yaw       (S_imu_yaw),
    .O_gz        (S_imu_gz),
    .O_yaw_deg   (S_imu_yaw_deg),
    .O_gz_dps    (S_imu_gz_dps)
);

mc_follow #(
    .STOP_CM (FOLLOW_STOP_CM), .START_PWM (FOLLOW_START_PWM), .KP_D (FOLLOW_KP_D), .MAX_FWD (FOLLOW_MAX_FWD),
    .ANGLE_FILTER (FOLLOW_ANGLE_FILTER), .DEADBAND (FOLLOW_DEADBAND),
    .PIVOT_ENTER (FOLLOW_PIVOT_ENTER), .PIVOT_CONFIRM_MS (FOLLOW_PIVOT_MS), .PIVOT_EXIT (FOLLOW_PIVOT_EXIT), .PIVOT_PWM (FOLLOW_PIVOT_PWM),
    .MAX_WHEEL (FOLLOW_MAX_WHEEL), .ACC (FOLLOW_ACC), .DEC (FOLLOW_DEC), .TURN_SLEW (FOLLOW_TURN_SLEW), .CMS_FULL (FOLLOW_CMS_FULL),
    .HEAD_KP (HEAD_KP), .HEAD_KI (HEAD_KI), .HEAD_KD (HEAD_KD), .HEAD_I_MAX (HEAD_I_MAX), .HEAD_I_ZONE (HEAD_I_ZONE), .TURN_MAX (HEAD_TURN_MAX),
    .AVOID_CM (AVOID_CM), .CLEAR_CM (AVOID_CLEAR_CM), .SPIN_CM (AVOID_SPIN_CM), .KP_OBS (AVOID_KP_OBS), .SPIN_PWM (AVOID_SPIN_PWM),
    .AVOID_TURN_MAX (AVOID_TURN_MAX), .AVOID_HOLD_CM (AVOID_HOLD_CM),
    .W_TGT (AVOID_W_TGT), .W_PREV (AVOID_W_PREV), .AVOID_FAR_CM (AVOID_FAR_CM), .OWNER_GAP_CM (AVOID_OWNER_GAP_CM),
    .SCAN_DEG (AVOID_SCAN_DEG), .SCAN_PAUSE_MS (AVOID_SCAN_PAUSE_MS), .SCAN_STEP_MS (AVOID_SCAN_STEP_MS)
) u_follow (
    .I_clk       (S_clk_100m),
    .I_rst_n     (S_rst_n_100m),
    .I_tick_1ms  (S_tick_1ms),
    .I_tgt_ok    (S_uwb_ok),
    .I_tgt_deg   (S_uwb_deg),
    .I_tgt_cm    (S_uwb_cm),
    .I_obs_tog   (S_obs_res_tog),
    .I_obs_free  (S_obs_head_free),
    .I_imu_ok    (S_imu_ok),
    .I_yaw       (S_imu_yaw),
    .I_gz        (S_imu_gz),
    .O_cmd_valid (S_cmd_valid),
    .O_cmd_stop  (S_cmd_stop),
    .O_cmd_l     (S_cmd_l),
    .O_cmd_r     (S_cmd_r),
    .O_state     (S_cmd_state),
    .O_tgt_deg   (S_head_tgt_deg),
    .O_stuck     (S_follow_stuck)
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
    .I_hall     (~I_hall_n),                        // 模块是低有效的，取反后 1 = 磁铁靠近
    .O_fed      (S_hall_fed)
);

// ---- 行为层：喂食时摇尾巴 + 播进食音效；主人太远（≥ BARK_CM）/ 收不到 UWB 连续 BARK_MS、或者困住了 → 狗叫；"距离 < 5 m 摇尾巴"以后接 I_near（现在接 0）----
mc_behavior #(
    .EAT_CLIP    (AUD_EAT_CLIP),
    .BARK_CLIP   (AUD_BARK_CLIP),
    .BARK_CM     (BARK_CM),
    .BARK_MS     (BARK_MS)
) u_behavior (
    .I_clk         (S_clk_100m),
    .I_rst_n       (S_rst_n_100m),
    .I_tick_1ms    (S_tick_1ms),
    .I_hall        (S_hall_fed),
    .I_near        (1'b0),
    .I_uwb_link    (S_uwb_link),
    .I_uwb_ok      (S_uwb_ok),
    .I_uwb_cm      (S_uwb_cm),
    .I_stuck       (S_follow_stuck),
    .I_audio_ready (S_audio_ready),
    .I_sfx_busy    (S_sfx_busy),
    .I_sfx_state   (S_sfx_state),
    .I_tail_busy   (1'b0),                          // 尾巴注释掉了：当成一直空闲
    .O_tail_wag    (),                              // 尾巴注释掉了：摇尾巴命令不接
    .O_sfx_play    (S_beh_sfx_play),
    .O_sfx_clip    (S_beh_sfx_clip)
);

// ---- 屏幕文字层：状态带里的 5 行文字（版面见 mc_osd_dash.v）----
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

    .I_cam_gain    (S_cam_gain),
    .I_cam_exp     (S_cam_exp),
    .I_cam_ev      (S_cam_ev),
    .I_obs_near    (S_obs_near),
    .I_obs_near_deg(S_obs_near_deg),
    .I_obs_go_deg  (S_obs_go_deg),
    .I_obs_free    (S_obs_go_free),
    .I_obs_stop    (S_obs_stop),
    .I_hall        (S_hall_fed),
    .I_tail_seq    (2'd0),                          // 尾巴注释掉了（版面里那一格也注释掉了）
    .I_uwb_ok      (S_uwb_ok),
    .I_uwb_link    (S_uwb_link),
    .I_uwb_deg     (S_uwb_deg),
    .I_uwb_cm      (S_uwb_cm),
    .I_cmd_state   (S_cmd_state),
    .I_cmd_l       (S_cmd_l),
    .I_cmd_r       (S_cmd_r),
    .I_head_tgt    (S_head_tgt_deg),
    .I_imu_state   (S_imu_state),
    .I_imu_yaw     (S_imu_yaw_deg),
    .I_imu_gz      (S_imu_gz_dps),

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
    .TXT_U0     (OSD_X0),
    .TXT_V0     (OSD_Y0),
    .TXT_COLS   (OSD_COLS),
    .TXT_ROWS   (OSD_ROWS),
    .TXT_SH     (OSD_SH),
    .OBS_V0     (OBS_V0),
    .REF_X0     (OBS_REF_X0),
    .REF_X1     (OBS_REF_X1),
    .REF_Y0     (OBS_REF_Y0),
    .REF_Y1     (OBS_REF_Y1),
    .ROW_MIN    (OBS_ROW_MIN),
    .LOGO_U0    (LOGO_U0),
    .LOGO_V0    (LOGO_V0)
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

    .I_obs_wclk      (S_cam_pix_clk),
    .I_obs_wbus      (S_obs_wbus),
    .I_obs_pub_bank  (S_obs_pub_bank),
    .I_obs_pub_valid (S_obs_pub_valid),
    .I_obs_go        (S_obs_go),
    .O_obs_disp_bank (S_obs_disp_bank),

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
