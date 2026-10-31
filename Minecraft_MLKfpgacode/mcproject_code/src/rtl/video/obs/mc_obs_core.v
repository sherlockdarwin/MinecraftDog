`timescale 1ns / 1ps
// =============================================================================
// mc_obs_core.v  避障的核心（像素时钟域）：160×90 小图 → 分类 → 去噪 → 列扫描 / 扇区 / 框 / 选方向，并把结果送到显示端
//
//   mc_obs_class ─障碍位─► mc_obs_morph ─去噪后─┬─► mc_obs_scan ─► 框表、方向、距离
//                                               └─► 显示画面（亮度 + 障碍位）
//
//   送显示：写总线 O_wbus = {写使能, 缓冲块, 选择(0 = 画面 1 = 框表), 地址[13:0], 数据[7:0]}（显示端 mc_obs_view 里两块缓冲）。
//     画面：地址 = 行 × 160 + 列，数据 = {亮度高 7 位, 障碍位}；框表：地址 = 扇区 × 4 + 字节。
//   双缓冲（不撕裂）：O_pub_bank = 最近写完的那一块；显示端每帧开头把它锁存成"正在显示的块"，经 I_disp_bank 告诉这里。
//     每帧开始写之前：显示端已经在显示最近写完的那块 → 这一帧写另一块，写完（框表也写完）发布；
//     显示端还没跟上（它 46 帧 / 秒，相机 60 帧 / 秒）→ 这一帧不送显示（扫描结果照常出）。
//   O_go_* 跟着发布一起变，和画面、框表配套（显示端用来画"建议方向"）。
//   O_res_tog：每帧扫描结果出来翻转一次，结果寄存器到下一帧结果出来之前不变（跟随决策在 100 MHz 域用它取结果）。
// =============================================================================
module mc_obs_core #(
    parameter [7:0]  REF_X0 = 8'd56,
    parameter [7:0]  REF_X1 = 8'd103,
    parameter [6:0]  REF_Y0 = 7'd82,
    parameter [6:0]  REF_Y1 = 7'd89,
    parameter [11:0] TC     = 12'd12,
    parameter [11:0] TY     = 12'd12,
    parameter [2:0]  YSPREAD = 3'd2,
    parameter [2:0]  YS_NEAR = 3'd1,
    parameter [6:0]  NEAR_ROW = 7'd65,
    parameter [9:0]  RELEARN_FR = 10'd300,
    parameter [6:0]  ROW_MIN = 7'd29,
    parameter [7:0]  D_CAP  = 8'd150,
    parameter [7:0]  D_STOP = 8'd35
)(
    input  wire        I_clk,
    input  wire        I_rst_n,

    input  wire        I_valid,         // 160×90 小图（mc_obs_down）
    input  wire [6:0]  I_row,
    input  wire [7:0]  I_col,
    input  wire [23:0] I_rgb,

    output reg  [24:0] O_wbus,          // → 显示端
    output reg         O_pub_bank,
    output reg         O_pub_valid,     // 至少发布过一次
    output reg  [5:0]  O_go,            // {有效, 停, 方向[3:0]}（跟着发布变）
    input  wire        I_disp_bank,     // ← 显示端正在显示哪一块（显示时钟域，内部同步）

    output wire        O_done,          // 每帧结果出来时打一拍
    output wire [127:0] O_sec_dist,
    output wire [3:0]  O_go_head,
    output wire signed [6:0] O_go_deg,
    output wire [7:0]  O_go_free,
    output wire        O_stop,
    output wire [7:0]  O_near_cm,
    output wire signed [6:0] O_near_deg,
    output wire [71:0] O_head_free,     // 方向 4~12 各能走多远
    output reg         O_res_tog        // 每帧结果出来翻转一次（给别的时钟域：翻转以后结果保持一帧不变）
);

// ---- 分类 ----
wire       S_c_v, S_c_obs;
wire [6:0] S_c_row;
wire [7:0] S_c_col, S_c_y;
mc_obs_class #(
    .REF_X0 (REF_X0), .REF_X1 (REF_X1), .REF_Y0 (REF_Y0), .REF_Y1 (REF_Y1), .TC (TC), .TY (TY), .YSPREAD (YSPREAD),
    .YS_NEAR (YS_NEAR), .NEAR_ROW (NEAR_ROW), .RELEARN_FR (RELEARN_FR)
) u_class (
    .I_clk (I_clk), .I_rst_n (I_rst_n),
    .I_valid (I_valid), .I_row (I_row), .I_col (I_col), .I_rgb (I_rgb),
    .O_valid (S_c_v), .O_row (S_c_row), .O_col (S_c_col), .O_y (S_c_y), .O_obs (S_c_obs), .O_busy ()
);

// ---- 去噪 ----
wire       S_m_v, S_m_obs, S_m_done;
wire [6:0] S_m_row, S_m_y7;
wire [7:0] S_m_col;
mc_obs_morph u_morph (
    .I_clk (I_clk), .I_rst_n (I_rst_n),
    .I_valid (S_c_v), .I_row (S_c_row), .I_col (S_c_col), .I_y (S_c_y), .I_obs (S_c_obs),
    .O_valid (S_m_v), .O_row (S_m_row), .O_col (S_m_col), .O_y7 (S_m_y7), .O_obs (S_m_obs), .O_frame_done (S_m_done)
);

// ---- 扫描 / 框 / 方向 ----
wire       S_bw;
wire [5:0] S_baddr;
wire [7:0] S_bdata;
mc_obs_scan #(.ROW_MIN (ROW_MIN), .D_CAP (D_CAP), .D_STOP (D_STOP)) u_scan (
    .I_clk (I_clk), .I_rst_n (I_rst_n),
    .I_valid (S_m_v), .I_row (S_m_row), .I_col (S_m_col), .I_obs (S_m_obs), .I_frame_done (S_m_done),
    .O_bw (S_bw), .O_baddr (S_baddr), .O_bdata (S_bdata), .O_done (O_done),
    .O_sec_dist (O_sec_dist), .O_go_head (O_go_head), .O_go_deg (O_go_deg), .O_go_free (O_go_free),
    .O_stop (O_stop), .O_near_cm (O_near_cm), .O_near_deg (O_near_deg), .O_head_free (O_head_free)
);

// ---- 双缓冲 + 写总线 ----
wire S_disp;
mc_sync_bits #(.W(1)) u_sync (.I_clk (I_clk), .I_d (I_disp_bank), .O_q (S_disp));

reg  S_wr;                              // 这一帧送显示
reg  S_w;                               // 写哪一块
wire S_first = S_m_v && (S_m_row == 7'd0) && (S_m_col == 8'd0);
wire S_wr_now = S_first ? (S_disp == O_pub_bank) : S_wr;      // 第 0 行第 0 列那一拍就要用上新决定
wire S_w_now  = S_first ? ~O_pub_bank : S_w;
wire [13:0] S_paddr = {S_m_row, 7'd0} + {2'd0, S_m_row, 5'd0} + {6'd0, S_m_col};   // 行 × 160 + 列

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        S_wr <= 1'b0; S_w <= 1'b0;
        O_wbus <= 25'd0; O_pub_bank <= 1'b0; O_pub_valid <= 1'b0; O_go <= 6'd0; O_res_tog <= 1'b0;
    end else begin
        if (S_first) begin S_wr <= S_wr_now; S_w <= S_w_now; end
        if (O_done) O_res_tog <= ~O_res_tog;
        if (S_m_v && S_wr_now)
            O_wbus <= {1'b1, S_w_now, 1'b0, S_paddr, S_m_y7, S_m_obs};
        else if (S_bw && S_wr)
            O_wbus <= {1'b1, S_w, 1'b1, 8'd0, S_baddr, S_bdata};
        else
            O_wbus <= {1'b0, O_wbus[23:0]};
        if (O_done && S_wr) begin                                   // 框表写完：发布
            O_pub_bank  <= S_w;
            O_pub_valid <= 1'b1;
            O_go        <= {1'b1, O_stop, O_go_head};
        end
    end
end

endmodule
