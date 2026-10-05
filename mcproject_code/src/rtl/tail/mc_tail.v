`timescale 1ns / 1ps
// =============================================================================
// mc_tail.v  尾巴控制：上电自动回零（回中）+ 左右摇摆
//   协议层 mc_stepper_emm 负责"怎么发一帧"，这里负责"发哪几帧、中间等多久"。只发不收（驱动器的应答不接）。
//
// 上电回零（自动，不用命令）：复位释放后等 INIT_DELAY_MS（等步进驱动器自己上电完成），然后
//     解除保护 → 使能 → 单圈就近回零（驱动器自己转到它存的"单圈回零零点"）→ 等 HOME_MS（回零走完）
//     → 把这里设为坐标零点。之后"绝对位置 0"= 正中。整机复位（SW1 按住 2 秒）以后同样重做一遍。
//     零点要先在驱动器上设一次（尾巴摆正中 → 驱动器菜单 O_Set → Set 0），掉电不丢；见 hmi_tail.md。
//     为什么不是"绝对位置 0"：驱动器的坐标零点 = 它上电那一刻的位置，发"回到绝对 0"等于原地不动（以前的写法，上板没回中）。
// 命令口：
//     I_cmd_wag  单周期脉冲：摇摆一个来回：中 → 左 SWING_DEG° → 中 → 右 SWING_DEG° → 中（先发一次使能，防止松轴）。
//                只在空闲、并且上电回零已经做完时接受（行为层会一直重发，回零做完就开始摇）。
// 状态口：
//     O_busy  正在执行（回零或摇摆）；O_seq  当前动作：0 空闲 1 回零 2 摇摆
//
// 位置都用"绝对位置"：0 = 正中，左 = LEFT 方向 × SWING_PULSES 个脉冲，右 = 反方向。摇多少次都不会累积偏差。
//
// 摆幅换算：脉冲数 = PULSES_PER_REV × 减速比 × 角度 / 360
//     默认 1.8° 电机 × 16 细分 = 3200 脉冲/圈，尾巴直接装在电机轴上（GEAR_X100 = 100，即 1.00）：30° → 267 脉冲。
//     如果尾巴经过减速（电机转 3 圈尾巴转 1 圈）：GEAR_X100 = 300。
// 每段动作等待时间 LEG_MS 必须比"走完这段"的时间长：
//     走完时间(ms) ≈ SWING_PULSES / (3200 × RPM / 60) × 1000；默认 267 脉冲、80 RPM ≈ 63 ms，取 150 ms 留足余量。
// HOME_MS 必须比回零走完的时间长：单圈就近回零最多转半圈，驱动器默认回零转速 30 RPM → 最多 1 s，取 2 s。
// =============================================================================
module mc_tail #(
    parameter CLK_HZ         = 100_000_000,
    parameter BAUD           = 115200,
    parameter [7:0] ADDR     = 8'd1,        // 驱动器地址
    parameter PULSES_PER_REV = 3200,        // 电机一圈的脉冲数（步距角 × 细分，在驱动器上设）
    parameter GEAR_X100      = 100,         // 减速比 × 100（电机转几圈 = 尾巴转一圈）
    parameter SWING_DEG      = 30,          // 摆幅（度）
    parameter LEFT_IS_CCW    = 1,           // 1：尾巴向左摆 = 电机逆时针(CCW)；装反了就改这个
    parameter RPM            = 80,          // 摇摆转速
    parameter ACC            = 0,           // 加速度档（0 = 不用曲线加减速，响应最快）
    parameter LEG_MS         = 150,         // 摇摆每一段的等待时间
    parameter HOME_MS        = 2000,        // 发出"回零"后等多久再设坐标零点
    parameter GAP_MS         = 10,          // 连续两帧命令之间的间隔
    parameter INIT_DELAY_MS  = 1000         // 上电（或整机复位）后等多久开始回零（等驱动器自己上电完成），≥ 1
)(
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_tick_1ms,

    input  wire        I_cmd_wag,

    output wire        O_busy,
    output reg  [1:0]  O_seq,

    output wire        O_tx
);

// 摆幅脉冲数（四舍五入）
localparam SWING_PULSES = (PULSES_PER_REV * GEAR_X100 * SWING_DEG + 18000) / 36000;
localparam DIR_LEFT     = (LEFT_IS_CCW != 0) ? 1'b1 : 1'b0;
localparam DIR_RIGHT    = ~DIR_LEFT;
localparam [15:0] RPM_W = RPM;
localparam [7:0]  ACC_W = ACC;

// mc_stepper_emm 的命令编号（必须与它一致）
localparam [2:0] CMD_ENABLE = 3'd0, CMD_POS = 3'd1, CMD_HOME = 3'd2, CMD_ZERO = 3'd3, CMD_CLRPROT = 3'd4;

localparam [1:0] SEQ_IDLE = 2'd0, SEQ_HOME = 2'd1, SEQ_WAG = 2'd2;
localparam [1:0] K_END = 2'd0, K_SEND = 2'd1, K_WAIT = 2'd2;
localparam [1:0] ST_IDLE = 2'd0, ST_EXEC = 2'd1, ST_SEND = 2'd2, ST_WAIT = 2'd3;

reg  [1:0]  S_state;
reg  [3:0]  S_pc;                       // 当前动作里的第几步
reg  [15:0] S_wait;                     // 剩余等待毫秒数
reg         S_em_start;
reg  [15:0] S_init_cnt;                 // 上电回零前的毫秒计数
reg         S_init_pend;                // 1 = 计时到了、回零还没开始
reg         S_init_over;                // 1 = 计时已结束（只做一次）
reg         S_homed;                    // 1 = 上电回零已经做完

assign O_busy = (S_state != ST_IDLE);

// ---------------------------------------------------------------------------
// 动作表：(O_seq, S_pc) → 这一步做什么
// ---------------------------------------------------------------------------
reg [1:0]  T_kind;
reg [2:0]  T_cmd;
reg        T_dir;
reg [31:0] T_pul;
reg [15:0] T_wait;

always @* begin
    T_kind = K_END;
    T_cmd  = CMD_ENABLE;
    T_dir  = 1'b0;
    T_pul  = 32'd0;
    T_wait = GAP_MS;

    case (O_seq)
        SEQ_HOME: begin                 // 解除保护 → 使能 → 单圈就近回零 → 等走完 → 设坐标零点
            case (S_pc)
                4'd0: begin T_kind = K_SEND; T_cmd = CMD_CLRPROT; end
                4'd1: begin T_kind = K_WAIT; T_wait = GAP_MS; end
                4'd2: begin T_kind = K_SEND; T_cmd = CMD_ENABLE; end
                4'd3: begin T_kind = K_WAIT; T_wait = GAP_MS; end
                4'd4: begin T_kind = K_SEND; T_cmd = CMD_HOME; end
                4'd5: begin T_kind = K_WAIT; T_wait = HOME_MS; end
                4'd6: begin T_kind = K_SEND; T_cmd = CMD_ZERO; end
                4'd7: begin T_kind = K_WAIT; T_wait = GAP_MS; end
                default: T_kind = K_END;
            endcase
        end

        SEQ_WAG: begin                  // 使能 → 左 → 中 → 右 → 中
            case (S_pc)
                4'd0: begin T_kind = K_SEND; T_cmd = CMD_ENABLE; end
                4'd1: begin T_kind = K_WAIT; T_wait = GAP_MS; end
                4'd2: begin T_kind = K_SEND; T_cmd = CMD_POS; T_dir = DIR_LEFT;  T_pul = SWING_PULSES; end
                4'd3: begin T_kind = K_WAIT; T_wait = LEG_MS; end
                4'd4: begin T_kind = K_SEND; T_cmd = CMD_POS; T_dir = 1'b0;      T_pul = 32'd0; end
                4'd5: begin T_kind = K_WAIT; T_wait = LEG_MS; end
                4'd6: begin T_kind = K_SEND; T_cmd = CMD_POS; T_dir = DIR_RIGHT; T_pul = SWING_PULSES; end
                4'd7: begin T_kind = K_WAIT; T_wait = LEG_MS; end
                4'd8: begin T_kind = K_SEND; T_cmd = CMD_POS; T_dir = 1'b0;      T_pul = 32'd0; end
                4'd9: begin T_kind = K_WAIT; T_wait = LEG_MS; end
                default: T_kind = K_END;
            endcase
        end

        default: T_kind = K_END;
    endcase
end

// ---------------------------------------------------------------------------
// 顺序执行
// ---------------------------------------------------------------------------
wire S_em_done;

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        S_state     <= ST_IDLE;
        S_pc        <= 4'd0;
        S_wait      <= 16'd0;
        S_em_start  <= 1'b0;
        S_init_cnt  <= 16'd0;
        S_init_pend <= 1'b0;
        S_init_over <= 1'b0;
        S_homed     <= 1'b0;
        O_seq       <= SEQ_IDLE;
    end else begin
        S_em_start <= 1'b0;

        // 上电回零：计满 INIT_DELAY_MS 毫秒后挂一个请求，空闲时执行（只执行一次）
        if (!S_init_over && I_tick_1ms) begin
            if (S_init_cnt >= INIT_DELAY_MS - 1) begin
                S_init_over <= 1'b1;
                S_init_pend <= 1'b1;
            end else begin
                S_init_cnt <= S_init_cnt + 16'd1;
            end
        end

        case (S_state)
            ST_IDLE: begin
                S_pc <= 4'd0;
                if (S_init_pend) begin
                    O_seq       <= SEQ_HOME;
                    S_init_pend <= 1'b0;
                    S_state     <= ST_EXEC;
                end else if (I_cmd_wag && S_homed) begin
                    O_seq   <= SEQ_WAG;
                    S_state <= ST_EXEC;
                end
            end

            ST_EXEC: begin
                case (T_kind)
                    K_SEND: begin
                        S_em_start <= 1'b1;
                        S_state    <= ST_SEND;
                    end
                    K_WAIT: begin
                        S_wait  <= T_wait;
                        S_state <= ST_WAIT;
                    end
                    default: begin                              // K_END：动作完成
                        if (O_seq == SEQ_HOME) S_homed <= 1'b1;
                        O_seq   <= SEQ_IDLE;
                        S_state <= ST_IDLE;
                    end
                endcase
            end

            ST_SEND: begin                                      // 等这一帧发完
                if (S_em_done) begin
                    S_pc    <= S_pc + 4'd1;
                    S_state <= ST_EXEC;
                end
            end

            ST_WAIT: begin
                if (I_tick_1ms) begin
                    if (S_wait <= 16'd1) begin
                        S_pc    <= S_pc + 4'd1;
                        S_state <= ST_EXEC;
                    end else begin
                        S_wait <= S_wait - 16'd1;
                    end
                end
            end
        endcase
    end
end

mc_stepper_emm #(
    .CLK_HZ (CLK_HZ),
    .BAUD   (BAUD),
    .ADDR   (ADDR)
) u_emm (
    .I_clk     (I_clk),
    .I_rst_n   (I_rst_n),
    .I_start   (S_em_start),
    .I_cmd     (T_cmd),
    .I_dir     (T_dir),
    .I_rpm     (RPM_W),
    .I_acc     (ACC_W),
    .I_pulses  (T_pul),
    .I_mode    (8'd1),                  // 绝对位置模式
    .O_busy    (),
    .O_done    (S_em_done),
    .O_tx      (O_tx)
);

endmodule
