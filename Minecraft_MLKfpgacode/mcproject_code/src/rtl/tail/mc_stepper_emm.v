`timescale 1ns / 1ps
// =============================================================================
// mc_stepper_emm.v  ZDT X42S（Emm 固件）步进驱动器 —— 协议层，只发不收
//   字节格式按《ZDT_X42S 第二代闭环步进电机用户手册 V1.0.5》第 5 章（Emm 固件命令），并与 TI2026H 的
//   HARDWARE/MOTOR_STEP/stepper.c 逐字节一致。驱动器用出厂设置：P_Serial = UART_FUN、UartBaud = 115200、
//   ID_Addr = 1、Checksum = 0x6B、细分 16（3200 脉冲/圈）。
//   只接一根线：FPGA 的 O_tx → 驱动器的 R/A/H 脚（再加 GND 共地）。驱动器的应答不接、不读（用户决定）。
//
// 怎么"调用"（相当于 C 里 Stepper_Position(...) 一句话）：
//     等 O_busy = 0；给出 I_cmd 和参数，同时拉高 I_start 一个时钟；之后 O_busy 变 1，
//     整帧字节发完后 O_busy 回 0，并给 O_done 一个脉冲。参数在 I_start 那一拍被锁存，之后可以改。
//
// 命令（I_cmd）与帧格式（每帧都以 0x6B 结尾；A = 地址）：
//     0 CMD_ENABLE   使能                 A F3 AB 01 00 6B                         （手册 5.3.2）
//     1 CMD_POS      位置运动             A FD dir rpmH rpmL acc p3 p2 p1 p0 mode 00 6B   （手册 5.3.12）
//                    dir：0=CW 1=CCW；rpm：转速；acc：加速度档（0=不用曲线，直接按转速启动）；
//                    p：脉冲数（无符号 32 位）；mode：0 相对上次目标 / 1 绝对位置 / 2 相对当前位置。
//                    绝对模式下目标位置 = ±脉冲数，符号由 dir 决定（CW 为正）。
//     2 CMD_HOME     单圈就近回零         A 9A 00 00 6B                            （手册 5.4.2，回零模式 00）
//                    走到驱动器里存的"单圈回零零点"（驱动器菜单 O_Set → Set 0，或 A 93 88 01 6B 设置一次，掉电不丢）
//     3 CMD_ZERO     把当前位置设为坐标零点 A 0A 6D 6B                              （手册 5.2.3）
//     4 CMD_CLRPROT  解除堵转/过热保护    A 0E 52 6B                               （手册 5.2.4）
// =============================================================================
module mc_stepper_emm #(
    parameter CLK_HZ       = 100_000_000,
    parameter BAUD         = 115200,
    parameter [7:0] ADDR   = 8'd1
)(
    input  wire        I_clk,
    input  wire        I_rst_n,

    // ---- 命令口 ----
    input  wire        I_start,         // 单周期脉冲（O_busy = 0 时才会被接受）
    input  wire [2:0]  I_cmd,
    input  wire        I_dir,           // CMD_POS：0 = CW，1 = CCW
    input  wire [15:0] I_rpm,           // CMD_POS：转速
    input  wire [7:0]  I_acc,           // CMD_POS：加速度档
    input  wire [31:0] I_pulses,        // CMD_POS：脉冲数
    input  wire [7:0]  I_mode,          // CMD_POS：0 / 1 / 2
    output wire        O_busy,
    output reg         O_done,          // 单周期脉冲：整帧已发完

    // ---- 串口 ----
    output wire        O_tx
);

localparam [2:0] CMD_ENABLE  = 3'd0,
                 CMD_POS     = 3'd1,
                 CMD_HOME    = 3'd2,
                 CMD_ZERO    = 3'd3,
                 CMD_CLRPROT = 3'd4;

localparam [2:0] ST_IDLE = 3'd0, ST_REQ = 3'd1, ST_ACC = 3'd2, ST_NEXT = 3'd3, ST_FLUSH = 3'd4;

// ---------------------------------------------------------------------------
// 发送：锁存参数 → 逐字节送给 UART
// ---------------------------------------------------------------------------
reg [2:0]  S_state;
reg [2:0]  S_cmd;
reg        S_dir;
reg [15:0] S_rpm;
reg [7:0]  S_acc;
reg [31:0] S_pul;
reg [7:0]  S_mode;
reg [3:0]  S_idx;
reg [3:0]  S_len;
reg        S_valid;
reg [7:0]  S_data;
wire       S_ready;

assign O_busy = (S_state != ST_IDLE);

// 当前要发的字节（组合逻辑查表）
reg [7:0] S_byte;
always @* begin
    S_byte = 8'h6B;                                 // 默认 = 结尾字节
    case (S_cmd)
        CMD_ENABLE: begin
            case (S_idx)
                4'd0: S_byte = ADDR;
                4'd1: S_byte = 8'hF3;
                4'd2: S_byte = 8'hAB;
                4'd3: S_byte = 8'h01;               // 使能
                4'd4: S_byte = 8'h00;               // 同步标志 = 0
                default: S_byte = 8'h6B;
            endcase
        end
        CMD_POS: begin
            case (S_idx)
                4'd0:  S_byte = ADDR;
                4'd1:  S_byte = 8'hFD;
                4'd2:  S_byte = {7'd0, S_dir};
                4'd3:  S_byte = S_rpm[15:8];
                4'd4:  S_byte = S_rpm[7:0];
                4'd5:  S_byte = S_acc;
                4'd6:  S_byte = S_pul[31:24];
                4'd7:  S_byte = S_pul[23:16];
                4'd8:  S_byte = S_pul[15:8];
                4'd9:  S_byte = S_pul[7:0];
                4'd10: S_byte = S_mode;
                4'd11: S_byte = 8'h00;              // 同步标志 = 0
                default: S_byte = 8'h6B;
            endcase
        end
        CMD_HOME: begin
            case (S_idx)
                4'd0: S_byte = ADDR;
                4'd1: S_byte = 8'h9A;
                4'd2: S_byte = 8'h00;               // 回零模式 00 = 单圈就近回零
                4'd3: S_byte = 8'h00;               // 同步标志 = 0
                default: S_byte = 8'h6B;
            endcase
        end
        CMD_ZERO: begin
            case (S_idx)
                4'd0: S_byte = ADDR;
                4'd1: S_byte = 8'h0A;
                4'd2: S_byte = 8'h6D;
                default: S_byte = 8'h6B;
            endcase
        end
        default: begin                              // CMD_CLRPROT
            case (S_idx)
                4'd0: S_byte = ADDR;
                4'd1: S_byte = 8'h0E;
                4'd2: S_byte = 8'h52;
                default: S_byte = 8'h6B;
            endcase
        end
    endcase
end

// 每种命令的帧长（字节数）
function [3:0] frame_len;
    input [2:0] cmd;
    begin
        case (cmd)
            CMD_ENABLE: frame_len = 4'd6;
            CMD_POS:    frame_len = 4'd13;
            CMD_HOME:   frame_len = 4'd5;
            default:    frame_len = 4'd4;           // CMD_ZERO / CMD_CLRPROT
        endcase
    end
endfunction

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        S_state <= ST_IDLE;
        S_cmd   <= 3'd0;
        S_dir   <= 1'b0;
        S_rpm   <= 16'd0;
        S_acc   <= 8'd0;
        S_pul   <= 32'd0;
        S_mode  <= 8'd0;
        S_idx   <= 4'd0;
        S_len   <= 4'd0;
        S_valid <= 1'b0;
        S_data  <= 8'd0;
        O_done  <= 1'b0;
    end else begin
        O_done <= 1'b0;
        case (S_state)
            ST_IDLE: begin
                if (I_start) begin
                    S_cmd   <= I_cmd;
                    S_dir   <= I_dir;
                    S_rpm   <= I_rpm;
                    S_acc   <= I_acc;
                    S_pul   <= I_pulses;
                    S_mode  <= I_mode;
                    S_idx   <= 4'd0;
                    S_len   <= frame_len(I_cmd);
                    S_state <= ST_REQ;
                end
            end

            ST_REQ: begin                           // 把当前字节交给 UART（valid 拉高）
                S_data  <= S_byte;
                S_valid <= 1'b1;
                S_state <= ST_ACC;
            end

            ST_ACC: begin                           // 这一拍 valid 与 ready 同时为 1：字节被 UART 收下
                if (S_ready) begin
                    S_valid <= 1'b0;
                    S_idx   <= S_idx + 4'd1;
                    S_state <= (S_idx == S_len - 4'd1) ? ST_FLUSH : ST_NEXT;
                end
            end

            ST_NEXT: begin                          // 等 UART 发完当前字节（ready 回高）再送下一个
                if (S_ready) S_state <= ST_REQ;
            end

            ST_FLUSH: begin                         // 最后一个字节发完 = 整帧完成
                if (S_ready) begin
                    O_done  <= 1'b1;
                    S_state <= ST_IDLE;
                end
            end

            default: S_state <= ST_IDLE;
        endcase
    end
end

mc_uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_tx (
    .I_clk   (I_clk),
    .I_rst_n (I_rst_n),
    .I_data  (S_data),
    .I_valid (S_valid),
    .O_ready (S_ready),
    .O_tx    (O_tx)
);

endmodule
