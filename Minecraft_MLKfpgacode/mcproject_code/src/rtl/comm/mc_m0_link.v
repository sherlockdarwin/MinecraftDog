`timescale 1ns / 1ps
// =============================================================================
// mc_m0_link.v  和 STM32 的串口通讯（115200 8N1，ASCII 帧，位数不够前面补 0；名字里的 m0 是以前接 MSPM0 时起的）
//
//   STM32 → FPGA：主人（UWB 标签）在哪
//     $l12350&   = 主人在左 12°、350 cm（l = 左、r = 右，大小写都行；角度 2 位 00~99°，距离 3 位 000~999 cm）
//     $S&        = 收不到 UWB（大小写都行）
//     每次 UWB 更新发一帧；超过 UWB_TIMEOUT_MS 没收到有效帧也算收不到。格式不对的帧整帧丢掉（下一个 '$' 重新开始）。
//   FPGA → STM32：两个轮子的 PWM（mc_follow 每 20 ms 给一次命令，这里收到就发）
//     #+3000-0500*  = 左轮 +3000、右轮 −500（每个轮子 = 符号 + 4 位，正 = 向前；STM32 直接给电机）
//     #S*           = 马上停车
//     发送一帧约 1 ms；正在发的时候来的新命令丢掉（命令 20 ms 一次，不会撞上）。
//
//   输出的目标：O_tgt_ok（有效）、O_tgt_deg（有符号，左负右正）、O_tgt_cm。
//   O_rx_alive：UWB_TIMEOUT_MS 内收到过任何一个完整字节（停止位对的），不管是不是有效帧 = 和 STM32 的线是通的。
//     屏幕上：O_tgt_ok → OK；O_rx_alive 但没有有效帧 → LOST（STM32 在发 $S&，或者帧不对）；都没有 → NOLK（线没接通 / STM32 没发）。
// =============================================================================
module mc_m0_link #(
    parameter CLK_HZ         = 100_000_000,
    parameter BAUD           = 115200,
    parameter UWB_TIMEOUT_MS = 300
)(
    input  wire              I_clk,
    input  wire              I_rst_n,
    input  wire              I_tick_1ms,

    input  wire              I_rx,             // ← STM32 PB10（USART3 TX）
    output wire              O_tx,             // → STM32 PB11（USART3 RX）

    output reg               O_tgt_ok,
    output reg  signed [7:0] O_tgt_deg,
    output reg  [9:0]        O_tgt_cm,
    output reg               O_rx_alive,

    input  wire              I_cmd_valid,      // 发一帧命令
    input  wire              I_cmd_stop,       // 1：发 #S*
    input  wire signed [13:0] I_cmd_l,         // 左右轮 PWM（−9999 ~ +9999）
    input  wire signed [13:0] I_cmd_r
);

// ---------------------------------------------------------------------------
// 收：字节 → 帧
// ---------------------------------------------------------------------------
wire       S_rv;
wire [7:0] S_rd;
mc_uart_rx #(.CLK_HZ (CLK_HZ), .BAUD (BAUD)) u_rx (.I_clk (I_clk), .I_rst_n (I_rst_n), .I_rx (I_rx), .O_valid (S_rv), .O_data (S_rd));

localparam [3:0] P_IDLE = 4'd0, P_DIR = 4'd1, P_A1 = 4'd2, P_A2 = 4'd3, P_D1 = 4'd4, P_D2 = 4'd5, P_D3 = 4'd6, P_END = 4'd7, P_LOST = 4'd8;
reg  [3:0] S_ps;
reg        S_left;
reg  [6:0] S_ang;                       // 0~99
reg  [9:0] S_dist;                      // 0~999
reg  [9:0] S_age;                       // 上一个有效帧以后多少毫秒
reg  [9:0] S_rage;                      // 上一个字节以后多少毫秒

wire       S_dig = (S_rd >= 8'h30) && (S_rd <= 8'h39);
wire [3:0] S_dv  = S_rd[3:0];
wire [6:0] S_ang10  = {S_ang[3:0], 3'd0} + {2'd0, S_ang[3:0], 1'b0};          // 十位 × 10（S_ang 这时只有一位）
wire [9:0] S_dist10 = {S_dist[6:0], 3'd0} + {S_dist[8:0], 1'b0};             // × 10

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        S_ps <= P_IDLE; S_left <= 1'b0; S_ang <= 7'd0; S_dist <= 10'd0; S_age <= 10'd0;
        S_rage <= 10'd0; O_rx_alive <= 1'b0;
        O_tgt_ok <= 1'b0; O_tgt_deg <= 8'sd0; O_tgt_cm <= 10'd0;
    end else begin
        if (I_tick_1ms && O_tgt_ok) begin
            if (S_age == UWB_TIMEOUT_MS - 1) O_tgt_ok <= 1'b0;
            else                             S_age <= S_age + 10'd1;
        end
        if (S_rv) begin                                         // 收到一个字节：线是通的
            O_rx_alive <= 1'b1; S_rage <= 10'd0;
        end else if (I_tick_1ms && O_rx_alive) begin
            if (S_rage == UWB_TIMEOUT_MS - 1) O_rx_alive <= 1'b0;
            else                              S_rage <= S_rage + 10'd1;
        end
        if (S_rv) begin
            if (S_rd == "$") S_ps <= P_DIR;
            else case (S_ps)
                P_DIR:  if (S_rd == "l" || S_rd == "L")      begin S_left <= 1'b1; S_ps <= P_A1; end
                        else if (S_rd == "r" || S_rd == "R") begin S_left <= 1'b0; S_ps <= P_A1; end
                        else if (S_rd == "S" || S_rd == "s") S_ps <= P_LOST;
                        else S_ps <= P_IDLE;
                P_A1:   if (S_dig) begin S_ang  <= {3'd0, S_dv};                    S_ps <= P_A2; end else S_ps <= P_IDLE;
                P_A2:   if (S_dig) begin S_ang  <= S_ang10 + {3'd0, S_dv};          S_ps <= P_D1; end else S_ps <= P_IDLE;
                P_D1:   if (S_dig) begin S_dist <= {6'd0, S_dv};                    S_ps <= P_D2; end else S_ps <= P_IDLE;
                P_D2:   if (S_dig) begin S_dist <= S_dist10 + {6'd0, S_dv};         S_ps <= P_D3; end else S_ps <= P_IDLE;
                P_D3:   if (S_dig) begin S_dist <= S_dist10 + {6'd0, S_dv};         S_ps <= P_END; end else S_ps <= P_IDLE;
                P_END:  begin
                            if (S_rd == "&") begin
                                O_tgt_ok  <= 1'b1; S_age <= 10'd0;
                                O_tgt_deg <= S_left ? -$signed({1'b0, S_ang}) : $signed({1'b0, S_ang});
                                O_tgt_cm  <= S_dist;
                            end
                            S_ps <= P_IDLE;
                        end
                P_LOST: begin
                            if (S_rd == "&") O_tgt_ok <= 1'b0;
                            S_ps <= P_IDLE;
                        end
                default: S_ps <= P_IDLE;
            endcase
        end
    end
end

// ---------------------------------------------------------------------------
// 发：命令 → 字符
// ---------------------------------------------------------------------------
wire       S_tready;
reg        S_tvalid;
reg  [7:0] S_tdata;
mc_uart_tx #(.CLK_HZ (CLK_HZ), .BAUD (BAUD)) u_tx (.I_clk (I_clk), .I_rst_n (I_rst_n), .I_data (S_tdata), .I_valid (S_tvalid), .O_ready (S_tready), .O_tx (O_tx));

// 绝对值 → 4 位 BCD（逐位移位加 3，14 拍；两个轮子一起转）
function [15:0] add3;                   // 每一位 ≥ 5 加 3
    input [15:0] b;
    integer k;
    begin
        for (k = 0; k < 4; k = k + 1) add3[4*k +: 4] = (b[4*k +: 4] >= 4'd5) ? b[4*k +: 4] + 4'd3 : b[4*k +: 4];
    end
endfunction

reg        S_busy;
reg        S_conv;
reg  [3:0] S_ci;                        // 转换：第几位
reg        S_stop, S_nl, S_nr;
reg [13:0] S_bl, S_br;                  // 被移出的绝对值
reg [15:0] S_dl, S_dr;                  // BCD
reg  [3:0] S_k;                         // 发到第几个字符
wire [3:0] S_last = S_stop ? 4'd2 : 4'd11;

wire [15:0] S_dl3 = add3(S_dl);
wire [15:0] S_dr3 = add3(S_dr);
wire [13:0] S_al = I_cmd_l[13] ? -I_cmd_l : I_cmd_l;
wire [13:0] S_ar = I_cmd_r[13] ? -I_cmd_r : I_cmd_r;

function [7:0] ch;                      // 第 k 个字符
    input [3:0] k;
    begin
        if (S_stop) ch = (k == 4'd0) ? "#" : (k == 4'd1) ? "S" : "*";
        else case (k)
            4'd0:  ch = "#";
            4'd1:  ch = S_nl ? "-" : "+";
            4'd2:  ch = {4'h3, S_dl[15:12]};
            4'd3:  ch = {4'h3, S_dl[11:8]};
            4'd4:  ch = {4'h3, S_dl[7:4]};
            4'd5:  ch = {4'h3, S_dl[3:0]};
            4'd6:  ch = S_nr ? "-" : "+";
            4'd7:  ch = {4'h3, S_dr[15:12]};
            4'd8:  ch = {4'h3, S_dr[11:8]};
            4'd9:  ch = {4'h3, S_dr[7:4]};
            4'd10: ch = {4'h3, S_dr[3:0]};
            default: ch = "*";
        endcase
    end
endfunction

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        S_busy <= 1'b0; S_conv <= 1'b0; S_ci <= 4'd0; S_stop <= 1'b1; S_nl <= 1'b0; S_nr <= 1'b0;
        S_bl <= 14'd0; S_br <= 14'd0; S_dl <= 16'd0; S_dr <= 16'd0; S_k <= 4'd0;
        S_tvalid <= 1'b0; S_tdata <= 8'd0;
    end else begin
        if (!S_busy) begin
            if (I_cmd_valid) begin
                S_busy <= 1'b1; S_conv <= 1'b1; S_ci <= 4'd0; S_k <= 4'd0;
                S_stop <= I_cmd_stop; S_nl <= I_cmd_l[13]; S_nr <= I_cmd_r[13];
                S_bl <= S_al; S_br <= S_ar; S_dl <= 16'd0; S_dr <= 16'd0;
            end
        end else if (S_conv) begin
            S_dl <= {S_dl3[14:0], S_bl[13]}; S_bl <= {S_bl[12:0], 1'b0};
            S_dr <= {S_dr3[14:0], S_br[13]}; S_br <= {S_br[12:0], 1'b0};
            if (S_ci == 4'd13) S_conv <= 1'b0;
            S_ci <= S_ci + 4'd1;
        end else if (S_tvalid) begin
            if (S_tready) begin                                     // 这个字符被收下了
                S_tvalid <= 1'b0;
                if (S_k == S_last) S_busy <= 1'b0;
                S_k <= S_k + 4'd1;
            end
        end else begin
            S_tvalid <= 1'b1; S_tdata <= ch(S_k);
        end
    end
end

endmodule
