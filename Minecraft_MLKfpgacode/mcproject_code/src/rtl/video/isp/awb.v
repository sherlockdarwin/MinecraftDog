`timescale 1ns / 1ps
// =============================================================================
// awb.v  自动白平衡（灰色世界法）：把 R、B 通道乘一个增益，让整幅画面的 R、B 平均值和 G 一样
//   （本项目改写：原来是米联客例程的 awb.v，接口、数据延迟线 signal_delay、输出的乘法 / 饱和与原版一样，
//    只把"怎么算增益"换掉了，见 video_pipeline.md §9）
//
//   原版：每个像素都把"本帧到目前为止"的累加和送进两个流水线除法器（每个时钟出一个商），增益在一帧里不停地变
//         （画面上面几行只用了很少的像素算增益，偏色会跳），两个除法器占了约 1400 LUT + 2200 进位 + 5500 个寄存器。
//   现在：一帧里只累加，帧开始（I_tuser）时用上一帧的累加和算一次增益：一个移位相减的除法器（一位一个时钟），
//         先算 G/R 再算 G/B，约 100 个时钟算完；新增益平滑一下（新 = 旧 + (算出来的 - 旧) / 4），下一帧开始时才换上，
//         整帧用同一组增益。比原版稳定（不会帧内偏色跳动），也省掉了两个除法器。
//
//   增益格式：Q16（0x10000 = 1.0），限制在 0 ~ 4.0（暗场景 / 单色场景不会把某个颜色拉到很夸张）。
//   统计：每拍 4 个像素里只取第 0 个（和原版一样），R+G+B ≥ 720 的亮像素不统计（接近白色、可能已经饱和）。
//   延迟：输入 → 输出约 54 个时钟（signal_delay 50 拍 + 乘法），帧开始 O_tuser 不延迟 —— 和原版一样，
//         下游 video_in 靠这段间隔在第一个像素到来之前复位它的 FIFO，不能缩短。
// =============================================================================
module awb  #(
    parameter IMG_HEIGHT = 1080,
    parameter IMG_WIDTH  = 1920
)
(
    input                   I_clk  ,
    input                   I_rst_n,

    input                   I_tlast  ,
    input                   I_tuser  ,
    input [95:0]            I_tdata  ,
    input                   I_tvalid ,
    output                  I_tready ,

    output                  O_tlast  ,
    output                  O_tuser  ,
    output [95:0]           O_tdata  ,
    output                  O_tvalid ,
    input                   O_tready
);

localparam [19:0] GAIN_ONE = 20'h10000;     // 1.0
localparam [19:0] GAIN_MAX = 20'h3FFFF;     // 不到 4.0

// ---------------------------------------------------------------------------
// 1. 输入打拍（和原版一样两拍，送 signal_delay）
// ---------------------------------------------------------------------------
reg         I_tvalid_r0, I_tvalid_r1;
reg  [95:0] I_tdata_d0, I_tdata_d1;

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        I_tdata_d0  <= 96'd0;
        I_tdata_d1  <= 96'd0;
        I_tvalid_r0 <= 1'b0;
        I_tvalid_r1 <= 1'b0;
    end else begin
        I_tdata_d0  <= I_tdata;
        I_tdata_d1  <= I_tdata_d0;
        I_tvalid_r0 <= I_tvalid;
        I_tvalid_r1 <= I_tvalid_r0;
    end
end

// ---------------------------------------------------------------------------
// 2. 一帧的累加（只取每拍的第 0 个像素；亮像素不算）。帧开始时把上一帧的和交给除法器，然后从 1 重新累加
//    （从 1 开始：一帧里全是亮像素时分母也不为 0，增益 = 1.0）
// ---------------------------------------------------------------------------
reg  [9:0]  S_lum;                          // 第 0 个像素的 R+G+B（晚一拍，和 I_tdata_d0 对齐）
reg  [31:0] S_sum_r, S_sum_g, S_sum_b;

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)      S_lum <= 10'd0;
    else if (I_tvalid) S_lum <= {2'b00, I_tdata[16+:8]} + {2'b00, I_tdata[8+:8]} + {2'b00, I_tdata[0+:8]};
end

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        S_sum_r <= 32'd1;
        S_sum_g <= 32'd1;
        S_sum_b <= 32'd1;
    end else if (I_tuser) begin
        S_sum_r <= 32'd1;
        S_sum_g <= 32'd1;
        S_sum_b <= 32'd1;
    end else if (I_tvalid_r0 && (S_lum < 10'd720)) begin
        S_sum_r <= S_sum_r + I_tdata_d0[16+:8];
        S_sum_g <= S_sum_g + I_tdata_d0[8+:8];
        S_sum_b <= S_sum_b + I_tdata_d0[0+:8];
    end
end

// ---------------------------------------------------------------------------
// 3. 增益：帧开始时 ① 把上一帧算好的增益换上（整帧用它）② 锁存上一帧的和，算新的 G/R、G/B
//    除法：{余数, 商} 每个时钟左移一位，余数 ≥ 分母就减掉、商这一位 = 1（48 位被除数 = G 的和 × 65536，48 个时钟）
// ---------------------------------------------------------------------------
reg  [19:0] in_r_r1, in_b_r1;               // 这一帧用的增益（乘法用）
reg  [19:0] S_next_r, S_next_b;             // 下一帧用的增益
reg  [31:0] S_den_r, S_den_b;               // 锁存的 R、B 的和（分母）
reg  [47:0] S_num;                          // 锁存的 G 的和 × 65536（被除数）
reg  [31:0] S_rem;
reg  [47:0] S_quo;
reg  [5:0]  S_cnt;
reg  [1:0]  S_dv;                           // 0 空闲 1 正在算 G/R 2 正在算 G/B

wire [31:0] S_den   = (S_dv == 2'd1) ? S_den_r : S_den_b;
wire [32:0] S_shift = {S_rem, S_quo[47]};
wire        S_ge    = (S_shift >= {1'b0, S_den});
wire [32:0] S_diff  = S_shift - {1'b0, S_den};

// 商限幅到 GAIN_MAX；平滑：新 = 旧 + (商 - 旧) / 4（有符号算术右移）
wire [19:0] S_q     = (|S_quo[47:20] || S_quo[19:0] > GAIN_MAX) ? GAIN_MAX : S_quo[19:0];
wire [19:0] S_old   = (S_dv == 2'd1) ? in_r_r1 : in_b_r1;
wire signed [20:0] S_delta = $signed({1'b0, S_q}) - $signed({1'b0, S_old});
wire signed [20:0] S_step  = S_delta >>> 2;
wire [19:0] S_new   = S_old + S_step[19:0];

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        in_r_r1  <= GAIN_ONE;
        in_b_r1  <= GAIN_ONE;
        S_next_r <= GAIN_ONE;
        S_next_b <= GAIN_ONE;
        S_den_r  <= 32'd1;
        S_den_b  <= 32'd1;
        S_num    <= 48'd0;
        S_rem    <= 32'd0;
        S_quo    <= 48'd0;
        S_cnt    <= 6'd0;
        S_dv     <= 2'd0;
    end else if (I_tuser) begin
        in_r_r1 <= S_next_r;
        in_b_r1 <= S_next_b;
        S_den_r <= S_sum_r;
        S_den_b <= S_sum_b;
        S_num   <= {S_sum_g, 16'd0};
        S_rem   <= 32'd0;
        S_quo   <= {S_sum_g, 16'd0};
        S_cnt   <= 6'd0;
        S_dv    <= 2'd1;
    end else if (S_dv != 2'd0) begin
        if (S_cnt == 6'd48) begin                           // 一个商算完
            if (S_dv == 2'd1) begin
                S_next_r <= S_new;
                S_rem    <= 32'd0;
                S_quo    <= S_num;
                S_cnt    <= 6'd0;
                S_dv     <= 2'd2;
            end else begin
                S_next_b <= S_new;
                S_dv     <= 2'd0;
            end
        end else begin
            S_rem <= S_ge ? S_diff[31:0] : S_shift[31:0];
            S_quo <= {S_quo[46:0], S_ge};
            S_cnt <= S_cnt + 6'd1;
        end
    end
end

// ---------------------------------------------------------------------------
// 4. 数据延迟线（原版不变）：让输出的第一个像素比帧开始晚约 50 个时钟
// ---------------------------------------------------------------------------
wire  [95:0] data_d0;
wire         valid_d0;
wire         I_tuser_r0;

signal_delay #(
    .IMG_HEIGHT   (IMG_HEIGHT),
    .IMG_WIDTH    (IMG_WIDTH ),
    .DATA_WIDTH   (96  ),
    .DELAY_CYCLE  (50)
) signal_delay_d (
    .I_clk  (I_clk      ),
    .I_rst_n(I_rst_n    ),
    .I_tuser(I_tuser    ),
    .I_valid(I_tvalid_r1),
    .I_data (I_tdata_d1 ),
    .O_valid(valid_d0   ),
    .O_data (data_d0    ),
    .O_tuser(I_tuser_r0 )
);

reg  [95:0] data_d1;
reg         valid_d1;

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        valid_d1 <= 1'b0;
        data_d1  <= 96'd0;
    end else begin
        valid_d1 <= valid_d0;
        data_d1  <= data_d0;
    end
end

// ---------------------------------------------------------------------------
// 5. 乘增益 + 饱和（原版不变）：4 个像素，R、B 各乘增益，G 不变
// ---------------------------------------------------------------------------
reg [27:0] R_new_r1, R_new_r2, R_new_r3, R_new_r4;
reg [27:0] B_new_r1, B_new_r2, B_new_r3, B_new_r4;
reg [7:0]  G_new_r1, G_new_r2, G_new_r3, G_new_r4;

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        R_new_r1 <= 28'd0; G_new_r1 <= 8'd0; B_new_r1 <= 28'd0;
        R_new_r2 <= 28'd0; G_new_r2 <= 8'd0; B_new_r2 <= 28'd0;
        R_new_r3 <= 28'd0; G_new_r3 <= 8'd0; B_new_r3 <= 28'd0;
        R_new_r4 <= 28'd0; G_new_r4 <= 8'd0; B_new_r4 <= 28'd0;
    end else if (valid_d1) begin
        R_new_r1 <= in_r_r1 * data_d1[16+:8]; G_new_r1 <= data_d1[8+:8];  B_new_r1 <= in_b_r1 * data_d1[0+:8];
        R_new_r2 <= in_r_r1 * data_d1[40+:8]; G_new_r2 <= data_d1[32+:8]; B_new_r2 <= in_b_r1 * data_d1[24+:8];
        R_new_r3 <= in_r_r1 * data_d1[64+:8]; G_new_r3 <= data_d1[56+:8]; B_new_r3 <= in_b_r1 * data_d1[48+:8];
        R_new_r4 <= in_r_r1 * data_d1[88+:8]; G_new_r4 <= data_d1[80+:8]; B_new_r4 <= in_b_r1 * data_d1[72+:8];
    end
end

function [7:0] sat8;                        // 乘积 >> 16，超过 255 就取 255
    input [27:0] p;
    sat8 = (|p[27:24]) ? 8'd255 : p[23:16];
endfunction

reg valid_d2;
always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) valid_d2 <= 1'b0;
    else          valid_d2 <= valid_d1;
end

assign O_tlast  = (valid_d1 == 1'b0) && (valid_d2 == 1'b1);
assign O_tuser  = I_tuser;
assign O_tvalid = valid_d2;
assign O_tdata  = O_tvalid ? {sat8(R_new_r4), G_new_r4, sat8(B_new_r4),
                              sat8(R_new_r3), G_new_r3, sat8(B_new_r3),
                              sat8(R_new_r2), G_new_r2, sat8(B_new_r2),
                              sat8(R_new_r1), G_new_r1, sat8(B_new_r1)} : 96'd0;
assign I_tready = O_tready;

endmodule
