`timescale 1ns / 1ps
// =============================================================================
// mc_imu_jy61p.v  维特 JY61P 六轴陀螺仪（UART）：上电自动配置 → 收角度 / 角速度帧 → 车停稳后航向角归零
//
//   协议（维特官网 wit-motion.yuque.com「串口通讯协议」，WIT 私有协议）：
//     模块 → FPGA：每帧 11 字节 55 TYPE D1L D1H D2L D2H D3L D3H D4L D4H SUM，SUM = 前 10 字节之和的低 8 位，数据低字节在前、有符号；
//       TYPE 52 = 角速度，D3 = Z 轴（原始值 × 2000 / 32768 = °/s）；TYPE 53 = 角度，D3 = 航向角 Yaw（× 180 / 32768 = 度）。
//       其他 TYPE（51 加速度、54 磁场……）校验对了只算"线是通的"，数据不用。校验不对整帧丢掉，从下一个 55 重新找。
//     FPGA → 模块：写寄存器 FF AA 地址 数据低 数据高；先解锁 FF AA 69 88 B5（解锁后约 200 ms 再发下一条），改完保存 FF AA 00 00 00。
//   上电配置（出厂是 9600 波特、10 Hz、输出加速度 + 角速度 + 角度 + 磁场；控制要 100 Hz，9600 带不动，所以改成 115200）：
//     1. 等 BOOT_MS（模块启动约 1 s），然后用 115200 听 PROBE_MS；
//     2. 没听到一个有效帧 → 当成出厂设置：用 9600 发 解锁、BAUD = 115200（模块收到马上换波特率）；
//     3. 用 115200 发 解锁、RSW = 0x000C（只输出角速度、角度）、RRATE = RATE_CODE（9 = 100 Hz）、保存（存进模块，下次上电直接 115200）。
//        第 1 步听到了有效帧（模块已经是 115200）就直接做第 3 步。每条命令后面等的时间见 cmd_wait。
//     运行中 LOST_MS 一个有效帧都没有（线断了 / 模块重启成别的设置）→ 回到第 1 步重新探测、配置、归零。
//   归零：配置完以后，|Z 角速度| ≤ STILL_RAW 连续 STILL_MS（车停稳了）→ 记下这一刻的航向角当零点；一直不静止，ZERO_MAX_MS 后也归零。
//   方向：本工程统一"右转为正"（和 UWB、避障的角度一样）。模块平放、元件面朝上时航向角逆时针增大 → CCW_POS = 1 取反；
//         模块朝下装就改成 0。上车先用手把车往右转，屏幕上 YAW 要变大。
//   输出：O_yaw  航向角（已减零点，65536 = 360°，16 位自然回绕：+179° 再往右转就是 −180°）
//         O_gz   Z 角速度原始值（右转为正，32768 = 2000°/s）
//         O_ok   已归零，并且 TIMEOUT_MS 内收到过角度帧和角速度帧（mc_follow 用：0 就停车）
//         O_state 给屏幕：1 CFG 正在配置 / 2 WAIT 数据正常、等着配置或等车停稳归零 / 3 OK；没有新数据时分两种（排查接线用）：
//                 0 NOLK = IDLE_MS 内线上一个下降沿都没有（模块 TX → 脚 6 不通、模块没电、没共地）
//                 4 LOST = 线上有动静但没有有效帧（模块在用别的波特率说话：FPGA 发的配置命令没到模块 RX（脚 5），或者模块被改成了 9600 / 115200 以外的波特率）
//         O_yaw_deg / O_gz_dps：给屏幕显示的度、度/秒（四舍五入）
// =============================================================================
module mc_imu_jy61p #(
    parameter CLK_HZ      = 100_000_000,
    parameter [3:0] RATE_CODE = 4'h9,   // 输出速率：8 = 50 Hz、9 = 100 Hz、0xB = 200 Hz
    parameter BOOT_MS     = 1200,
    parameter PROBE_MS    = 300,
    parameter TIMEOUT_MS  = 100,
    parameter LOST_MS     = 1000,
    parameter IDLE_MS     = 300,        // 屏幕：线上这么久没有下降沿 = NOLK
    parameter STILL_RAW   = 49,         // 3°/s
    parameter STILL_MS    = 1000,
    parameter ZERO_MAX_MS = 5000,
    parameter CCW_POS     = 1
)(
    input  wire               I_clk,
    input  wire               I_rst_n,
    input  wire               I_tick_1ms,

    input  wire               I_rx,           // ← 模块 TX
    output wire               O_tx,           // → 模块 RX

    output reg                O_ok,
    output reg  [2:0]         O_state,
    output reg  signed [15:0] O_yaw,
    output reg  signed [15:0] O_gz,
    output wire signed [8:0]  O_yaw_deg,
    output wire signed [11:0] O_gz_dps
);

// ---------------------------------------------------------------------------
// 收：字节 → 帧（一直用 115200 收）
// ---------------------------------------------------------------------------
wire       S_rv;
wire [7:0] S_rd;
mc_uart_rx #(.CLK_HZ (CLK_HZ), .BAUD (115200)) u_rx (.I_clk (I_clk), .I_rst_n (I_rst_n), .I_rx (I_rx), .O_valid (S_rv), .O_data (S_rd));

// 线上有没有动静（不管波特率对不对）：同步后的下降沿
reg  [2:0]  S_rxs;
always @(posedge I_clk or negedge I_rst_n)
    if (!I_rst_n) S_rxs <= 3'b111;
    else          S_rxs <= {S_rxs[1:0], I_rx};
wire        S_fall = S_rxs[2] & ~S_rxs[1];

reg  [3:0]  S_pi;                       // 帧里第几个字节（0 = 等 55）
reg  [7:0]  S_sum;
reg  [3:0]  S_typ;                      // TYPE 的低 4 位（高 4 位必须是 5）
reg  [15:0] S_d3;
reg         S_fv;                       // 收到一个校验对的帧（打一拍）
reg  [3:0]  S_ft;
reg  [15:0] S_fd;

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        S_pi <= 4'd0; S_sum <= 8'd0; S_typ <= 4'd0; S_d3 <= 16'd0; S_fv <= 1'b0; S_ft <= 4'd0; S_fd <= 16'd0;
    end else begin
        S_fv <= 1'b0;
        if (S_rv) begin
            case (S_pi)
                4'd0:  if (S_rd == 8'h55) begin S_pi <= 4'd1; S_sum <= 8'h55; end
                4'd1:  if (S_rd[7:4] == 4'h5) begin S_typ <= S_rd[3:0]; S_sum <= S_sum + S_rd; S_pi <= 4'd2; end
                       else begin S_pi <= (S_rd == 8'h55) ? 4'd1 : 4'd0; S_sum <= 8'h55; end
                4'd10: begin
                           if (S_rd == S_sum) begin S_fv <= 1'b1; S_ft <= S_typ; S_fd <= S_d3; S_pi <= 4'd0; end
                           else begin S_pi <= (S_rd == 8'h55) ? 4'd1 : 4'd0; S_sum <= 8'h55; end
                       end
                default: begin                                          // 第 2~9 个字节：数据
                           S_sum <= S_sum + S_rd;
                           if (S_pi == 4'd6) S_d3[7:0]  <= S_rd;
                           if (S_pi == 4'd7) S_d3[15:8] <= S_rd;
                           S_pi <= S_pi + 4'd1;
                       end
            endcase
        end
    end
end

// ---------------------------------------------------------------------------
// 发：两个发送器（9600 只在出厂设置时用一次），按 S_hi 选
// ---------------------------------------------------------------------------
reg        S_hi;                        // 1 = 用 115200 发
reg        S_txv;
reg  [7:0] S_txd;
wire       S_rdy_lo, S_rdy_hi, S_tx_lo, S_tx_hi;
mc_uart_tx #(.CLK_HZ (CLK_HZ), .BAUD (9600))   u_tx_lo (.I_clk (I_clk), .I_rst_n (I_rst_n), .I_data (S_txd), .I_valid (S_txv & ~S_hi), .O_ready (S_rdy_lo), .O_tx (S_tx_lo));
mc_uart_tx #(.CLK_HZ (CLK_HZ), .BAUD (115200)) u_tx_hi (.I_clk (I_clk), .I_rst_n (I_rst_n), .I_data (S_txd), .I_valid (S_txv &  S_hi), .O_ready (S_rdy_hi), .O_tx (S_tx_hi));
assign O_tx = S_hi ? S_tx_hi : S_tx_lo;
wire   S_rdy = S_hi ? S_rdy_hi : S_rdy_lo;

// 命令表：第 c 条命令的 {地址, 数据低, 数据高}、发完等多少毫秒。0~1 用 9600 发（只在出厂设置时），2~5 用 115200
function [23:0] cmd_reg;
    input [2:0] c;
    case (c)
        3'd0, 3'd2: cmd_reg = 24'h69_88_B5;                // 解锁
        3'd1:       cmd_reg = 24'h04_06_00;                // BAUD = 6（115200），模块马上换
        3'd3:       cmd_reg = 24'h02_0C_00;                // RSW = 0x000C：只输出角速度（52）、角度（53）
        3'd4:       cmd_reg = {8'h03, 4'h0, RATE_CODE, 8'h00};   // RRATE
        default:    cmd_reg = 24'h00_00_00;                // 保存
    endcase
endfunction
function [7:0] cmd_wait;
    input [2:0] c;
    case (c)
        3'd0, 3'd2: cmd_wait = 8'd200;                     // 解锁后等 200 ms（手册）
        3'd1:       cmd_wait = 8'd100;
        3'd3, 3'd4: cmd_wait = 8'd50;
        default:    cmd_wait = 8'd200;
    endcase
endfunction
wire [23:0] S_creg;
reg  [2:0]  S_ci;                       // 第几条命令
reg  [2:0]  S_bi;                       // 命令里第几个字节
assign S_creg = cmd_reg(S_ci);
wire [7:0]  S_cbyte = (S_bi == 3'd0) ? 8'hFF : (S_bi == 3'd1) ? 8'hAA : (S_bi == 3'd2) ? S_creg[23:16] :
                      (S_bi == 3'd3) ? S_creg[15:8] : S_creg[7:0];

// ---------------------------------------------------------------------------
// 主状态机：启动 → 探测 → 发命令 → 等车停稳归零 → 运行
// ---------------------------------------------------------------------------
localparam [2:0] B_BOOT = 3'd0, B_PROBE = 3'd1, B_SEND = 3'd2, B_WAIT = 3'd3, B_ZERO = 3'd4, B_RUN = 3'd5;
reg  [2:0]  S_b;
reg  [12:0] S_ms;                       // 这个状态里过了多少毫秒（到 8191 不再加）
reg         S_vf;                       // 探测时听到了有效帧
reg  [12:0] S_still;                    // 连续静止多少毫秒
reg  [12:0] S_aage, S_gage, S_lage;     // 上一个角度帧 / 角速度帧 / 任何有效帧以后多少毫秒（饱和）
reg  [12:0] S_eage;                     // 线上上一个下降沿以后多少毫秒（饱和）
reg  signed [15:0] S_yraw, S_graw;      // 最新的航向角、Z 角速度（已按 CCW_POS 换成右转为正）
reg  signed [15:0] S_zero;

wire        S_fresh = (S_aage < TIMEOUT_MS) && (S_gage < TIMEOUT_MS);
wire [15:0] S_gabs  = S_graw[15] ? -S_graw : S_graw;
wire signed [15:0] S_fdc = (CCW_POS != 0) ? -$signed(S_fd) : $signed(S_fd);

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        S_b <= B_BOOT; S_ms <= 13'd0; S_vf <= 1'b0; S_still <= 13'd0; S_hi <= 1'b0; S_txv <= 1'b0; S_txd <= 8'd0; S_ci <= 3'd0; S_bi <= 3'd0;
        S_aage <= 13'h1FFF; S_gage <= 13'h1FFF; S_lage <= 13'h1FFF; S_eage <= 13'h1FFF; S_yraw <= 16'sd0; S_graw <= 16'sd0; S_zero <= 16'sd0;
        O_ok <= 1'b0; O_state <= 3'd0; O_yaw <= 16'sd0; O_gz <= 16'sd0;
    end else begin
        // ---- 帧 → 数据、"多久没收到" ----
        if (S_fv) begin
            S_lage <= 13'd0;
            if (S_ft == 4'h2) begin S_graw <= S_fdc; S_gage <= 13'd0; end
            if (S_ft == 4'h3) begin S_yraw <= S_fdc; S_aage <= 13'd0; end
        end
        if (S_fall) S_eage <= 13'd0;
        if (I_tick_1ms) begin
            if (S_aage != 13'h1FFF && !(S_fv && S_ft == 4'h3)) S_aage <= S_aage + 13'd1;
            if (S_gage != 13'h1FFF && !(S_fv && S_ft == 4'h2)) S_gage <= S_gage + 13'd1;
            if (S_lage != 13'h1FFF && !S_fv)                   S_lage <= S_lage + 13'd1;
            if (S_eage != 13'h1FFF && !S_fall)                 S_eage <= S_eage + 13'd1;
            if (S_ms != 13'h1FFF) S_ms <= S_ms + 13'd1;
        end

        case (S_b)
            B_BOOT:  if (S_ms >= BOOT_MS) begin S_b <= B_PROBE; S_ms <= 13'd0; S_vf <= 1'b0; end
            B_PROBE: begin
                         if (S_fv) S_vf <= 1'b1;
                         if (S_vf)                    begin S_hi <= 1'b1; S_ci <= 3'd2; S_bi <= 3'd0; S_b <= B_SEND; end   // 已经是 115200
                         else if (S_ms >= PROBE_MS)   begin S_hi <= 1'b0; S_ci <= 3'd0; S_bi <= 3'd0; S_b <= B_SEND; end   // 出厂设置：先用 9600 改波特率
                     end
            B_SEND:  begin
                         if (S_txv) begin                                    // 发送器这一拍收下了
                             S_txv <= 1'b0;
                             if (S_bi == 3'd4) begin S_b <= B_WAIT; S_ms <= 13'd0; end
                             else S_bi <= S_bi + 3'd1;
                         end else if (S_rdy) begin
                             S_txv <= 1'b1; S_txd <= S_cbyte;
                         end
                     end
            B_WAIT:  if (S_rdy && S_ms >= cmd_wait(S_ci)) begin           // 最后一个字节发完、等够了
                         S_bi <= 3'd0;
                         if (S_ci == 3'd1) S_hi <= 1'b1;                    // 模块已经换成 115200
                         if (S_ci == 3'd5) begin S_b <= B_ZERO; S_ms <= 13'd0; S_still <= 13'd0; end
                         else begin S_ci <= S_ci + 3'd1; S_b <= B_SEND; end
                     end
            B_ZERO:  begin
                         if (I_tick_1ms) S_still <= (S_fresh && S_gabs <= STILL_RAW) ? ((S_still == 13'h1FFF) ? S_still : S_still + 13'd1) : 13'd0;
                         if (S_fresh && (S_still >= STILL_MS || S_ms >= ZERO_MAX_MS)) begin S_zero <= S_yraw; S_b <= B_RUN; end
                         else if (S_lage >= LOST_MS) begin S_b <= B_PROBE; S_ms <= 13'd0; S_vf <= 1'b0; end
                     end
            B_RUN:   if (S_lage >= LOST_MS) begin S_b <= B_PROBE; S_ms <= 13'd0; S_vf <= 1'b0; end
            default: S_b <= B_BOOT;
        endcase

        // ---- 输出 ----
        O_ok    <= (S_b == B_RUN) && S_fresh;
        O_state <= (S_b == B_SEND || S_b == B_WAIT) ? 3'd1 : !S_fresh ? ((S_eage < IDLE_MS) ? 3'd4 : 3'd0) : (S_b == B_RUN) ? 3'd3 : 3'd2;
        O_yaw   <= S_yraw - S_zero;
        O_gz    <= S_graw;
    end
end

// ---- 屏幕显示：度 = 航向角 × 360 / 65536 = × 45 / 8192；度/秒 = 原始值 × 2000 / 32768 = × 125 / 2048（四舍五入，移位相加）----
wire signed [22:0] S_y45  = ($signed({{7{O_yaw[15]}}, O_yaw}) <<< 5) + ($signed({{7{O_yaw[15]}}, O_yaw}) <<< 3) +
                            ($signed({{7{O_yaw[15]}}, O_yaw}) <<< 2) +  $signed({{7{O_yaw[15]}}, O_yaw});
wire signed [22:0] S_yr   = S_y45 + 23'sd4096;
assign O_yaw_deg = S_yr[21:13];
wire signed [23:0] S_g125 = ($signed({{8{O_gz[15]}}, O_gz}) <<< 7) - ($signed({{8{O_gz[15]}}, O_gz}) <<< 1) - $signed({{8{O_gz[15]}}, O_gz});
wire signed [23:0] S_gr   = S_g125 + 24'sd1024;
assign O_gz_dps = S_gr[22:11];

endmodule
