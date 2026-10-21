`timescale 1ns / 1ps
// =============================================================================
// mc_ae.v  自动曝光：按上一帧的平均亮度调传感器的曝光时间和增益，让画面平均亮度接近目标（替代原来的手动增益）
//
//   亮度统计来自 mc_gamma（伽马以后的 8 位平均值，亮点限幅过），目标 = T_MID + (档位 − 4) × T_STEP，
//   档位 O_ev 0~8 由 SW2 / SW3 调（屏幕上显示 EV−4 ~ EV+4，默认 EV+0）。
//
//   控制（每次写完寄存器，等 SETTLE 帧让新曝光生效，再看一帧统计）：
//     平均 / 目标  < 0.5    0.69   0.84   0.94 │ 1.06   1.19   1.5    2  <
//     调整 (0.3 dB)  +24    +12    +5     +2   │  −2     −5    −12   −24      中间（0.94~1.06）不动
//     调亮：先加长曝光（最长 VMAX − 8 行 ≈ 1 帧），到头了再加增益（最多 G_MAX）；
//     调暗：先减增益，减到 0 再缩短曝光（最短 4 行）。这样暗处优先用长曝光（噪点少），亮处用短曝光。
//     曝光按倍数变：×1.07 / ×1.19 / ×1.51 / ×2.29（调暗 ×0.93 / ×0.84 / ×0.66 / ×0.44），每次至少变 1 行；
//     增益按 0.3 dB 一级加减（传感器的 GAIN_PGC_0 = dB × 10/3）。
//   上电：初始寄存器写完后先写一次 曝光 = 最长、增益 = 0。
//   写寄存器：O_req 拉高，看到 I_wr_done 变 0（uicfgimx415 开始写）就放下，I_wr_done 回到 1 = 写完。
//   O_shr0 / O_gain 只在不写的时候变。
// =============================================================================
module mc_ae #(
    parameter        VMAX   = 2283,     // 传感器每帧行数（uiimx415reg 里的 VMAX）
    parameter [7:0]  G_MAX  = 8'd150,   // 增益上限：150 × 0.3 dB = 45 dB（30 dB 以上是数字增益，噪点明显）
    parameter [7:0]  T_MID  = 8'd112,   // EV+0 的目标平均亮度（0~255，伽马以后）
    parameter [7:0]  T_STEP = 8'd16,    // 每一档目标亮度差
    parameter        SETTLE = 3         // 写完寄存器后等第几帧的统计
)(
    input  wire        I_clk,           // 24 MHz（和 I2C 配置同一个时钟）
    input  wire        I_rst_n,
    input  wire        I_cfg_done,      // 传感器初始寄存器写完
    input  wire        I_wr_done,       // uicfgimx415 的 O_ae_cfg_done：1 = 空闲 / 上一次写完
    input  wire [7:0]  I_mean,          // [像素时钟域] 上一帧平均亮度（每帧只变一次）
    input  wire        I_mean_tog,      // [像素时钟域] O_mean 每更新一次翻转一次
    input  wire [1:0]  I_key_n,         // 亮度键（低有效脉冲 ≥ 30 ms）：[0] 亮一档，[1] 暗一档
    output reg         O_req,
    output wire [15:0] O_shr0,          // 写给传感器的 SHR0 = VMAX − 曝光行数
    output reg  [7:0]  O_gain,          // 写给传感器的 GAIN_PGC_0（0.3 dB 一级）
    output reg  [11:0] O_exp,           // 曝光行数（屏幕显示）
    output reg  [3:0]  O_ev             // 亮度档 0~8（屏幕显示 −4~+4）
);

localparam [11:0] E_MAX = VMAX - 8;
localparam [11:0] E_MIN = 12'd4;

assign O_shr0 = VMAX - O_exp;

// ---- 跨时钟域：统计翻转同步过来，翻转了就采样平均值（它在一帧里不变）----
wire [2:0] S_sync;
mc_sync_bits #(.W(3)) u_sync (.I_clk(I_clk), .I_d({I_mean_tog, I_key_n}), .O_q(S_sync));
reg        S_tog_d;
reg  [1:0] S_key_d;
wire       S_frame = (S_sync[2] != S_tog_d);
wire       S_up    = S_key_d[0] && !S_sync[0];      // 下降沿
wire       S_dn    = S_key_d[1] && !S_sync[1];

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        S_tog_d <= 1'b0;
        S_key_d <= 2'b00;              // 先看到高电平才算按下（同步器刚起来时不误触发）
        O_ev    <= 4'd4;
    end else begin
        S_tog_d <= S_sync[2];
        S_key_d <= S_sync[1:0];
        if (S_up && O_ev != 4'd8)      O_ev <= O_ev + 4'd1;
        else if (S_dn && O_ev != 4'd0) O_ev <= O_ev - 4'd1;
    end
end

// ---- 判断：平均值和目标比 ----
reg  [7:0]  S_mean;
wire [8:0]  S_t   = T_MID - 4 * T_STEP + O_ev * T_STEP;  // 目标
wire [12:0] S_m32 = {S_mean, 5'd0};

reg        S_bright;            // 1 = 调亮，0 = 调暗
reg  [4:0] S_d;                 // 调整量（0.3 dB），0 = 不动
always @(*) begin
    S_bright = 1'b1; S_d = 5'd0;
    if      (S_m32 < S_t * 16) begin S_bright = 1'b1; S_d = 5'd24; end
    else if (S_m32 < S_t * 22) begin S_bright = 1'b1; S_d = 5'd12; end
    else if (S_m32 < S_t * 27) begin S_bright = 1'b1; S_d = 5'd5;  end
    else if (S_m32 < S_t * 30) begin S_bright = 1'b1; S_d = 5'd2;  end
    else if (S_m32 > S_t * 64) begin S_bright = 1'b0; S_d = 5'd24; end
    else if (S_m32 > S_t * 48) begin S_bright = 1'b0; S_d = 5'd12; end
    else if (S_m32 > S_t * 38) begin S_bright = 1'b0; S_d = 5'd5;  end
    else if (S_m32 > S_t * 34) begin S_bright = 1'b0; S_d = 5'd2;  end
end

// 曝光倍数（/256）：调亮 10^(d·0.3/20)，调暗它的倒数
reg [9:0] S_k;
always @(*) begin
    case (S_d)
        5'd24:   S_k = S_bright ? 10'd586 : 10'd112;
        5'd12:   S_k = S_bright ? 10'd387 : 10'd169;
        5'd5:    S_k = S_bright ? 10'd304 : 10'd215;
        default: S_k = S_bright ? 10'd274 : 10'd239;
    endcase
end
wire [21:0] S_ek = O_exp * S_k;
wire [13:0] S_e1 = S_ek[21:8];                      // 曝光 × 倍数

reg  [11:0] S_e_new;
reg  [7:0]  S_g_new;
always @(*) begin
    S_e_new = O_exp;
    S_g_new = O_gain;
    if (S_d != 5'd0) begin
        if (S_bright) begin
            if (O_exp < E_MAX) begin
                if (S_e1 <= O_exp)       S_e_new = O_exp + 12'd1;
                else if (S_e1 >= E_MAX)  S_e_new = E_MAX;
                else                     S_e_new = S_e1[11:0];
            end else begin
                S_g_new = (O_gain + S_d >= G_MAX) ? G_MAX : O_gain + S_d;
            end
        end else begin
            if (O_gain != 8'd0) begin
                S_g_new = (O_gain > S_d) ? O_gain - S_d : 8'd0;
            end else begin
                if (S_e1 >= O_exp)       S_e_new = (O_exp > E_MIN) ? O_exp - 12'd1 : E_MIN;
                else if (S_e1 <= E_MIN)  S_e_new = E_MIN;
                else                     S_e_new = S_e1[11:0];
            end
        end
    end
end

// ---- 状态机 ----
localparam [2:0] ST_INIT = 3'd0, ST_REQ = 3'd1, ST_WRITE = 3'd2, ST_WAIT = 3'd3, ST_CALC = 3'd4;
reg [2:0] S_st;
reg [2:0] S_nfr;                // 写完以后过了几帧

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        S_st   <= ST_INIT;
        S_nfr  <= 3'd0;
        S_mean <= 8'd0;
        O_req  <= 1'b0;
        O_exp  <= E_MAX;
        O_gain <= 8'd0;
    end else begin
        case (S_st)
            ST_INIT:  if (I_cfg_done) begin O_req <= 1'b1; S_st <= ST_REQ; end
            ST_REQ:   if (!I_wr_done) begin O_req <= 1'b0; S_st <= ST_WRITE; end
            ST_WRITE: if (I_wr_done)  begin S_nfr <= 3'd0; S_st <= ST_WAIT; end
            ST_WAIT:  if (S_frame) begin
                          if (S_nfr == SETTLE - 1) begin S_mean <= I_mean; S_st <= ST_CALC; end
                          else S_nfr <= S_nfr + 3'd1;
                      end
            ST_CALC:  if (S_e_new != O_exp || S_g_new != O_gain) begin
                          O_exp  <= S_e_new;
                          O_gain <= S_g_new;
                          O_req  <= 1'b1;
                          S_st   <= ST_REQ;
                      end else begin
                          S_nfr <= SETTLE - 1;              // 不用改：下一帧接着看
                          S_st  <= ST_WAIT;
                      end
            default:  S_st <= ST_INIT;
        endcase
    end
end

endmodule
