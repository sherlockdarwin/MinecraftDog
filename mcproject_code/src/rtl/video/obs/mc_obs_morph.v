`timescale 1ns / 1ps
// =============================================================================
// mc_obs_morph.v  障碍图去噪：3×3 多数表决（9 格里 ≥ 5 格是障碍才算障碍），去掉零星的误判点、补上障碍里的小洞
//
//   输入：mc_obs_class 的逐点结果（行列号 + 亮度 + 障碍位），一拍一个，按行顺序（行号 0~LAST_ROW，列号 0~LAST_COL）。
//   缓存：4 行环形缓存（每行一块 RAM，160 × {亮度高 7 位, 障碍位}），第 r 行写进第 r mod 4 块。
//   处理：第 r 行收齐（写完最后一列）后处理第 r−1 行（要用到它上下两行）；最后一行收齐后再处理最后一行。
//         边界复制：第 0 行的"上一行"、最后一行的"下一行"、最左 / 最右列的左右邻都用它自己。
//         处理一行：同时读三块 RAM 的同一列，3×3 窗口逐列右移，每拍输出一个点，约 165 拍一行。
//   输出：O_valid / O_row / O_col / O_y7（亮度 >> 1）/ O_obs（去噪后的障碍位），一行连续 160 拍；
//         一帧最后一行输出完后 O_frame_done 打一拍。
//   两帧之间不用清什么：行号直接来自输入；处理中途来了新行也不怕（新行写的是第 4 块）。
// =============================================================================
module mc_obs_morph #(
    parameter [6:0] LAST_ROW = 7'd89,
    parameter [7:0] LAST_COL = 8'd159
)(
    input  wire       I_clk,
    input  wire       I_rst_n,

    input  wire       I_valid,
    input  wire [6:0] I_row,
    input  wire [7:0] I_col,
    input  wire [7:0] I_y,
    input  wire       I_obs,

    output reg        O_valid,
    output reg  [6:0] O_row,
    output reg  [7:0] O_col,
    output reg  [6:0] O_y7,
    output reg        O_obs,
    output reg        O_frame_done
);

// ---- 4 行环形缓存 ----
reg [7:0] S_m0 [0:255];
reg [7:0] S_m1 [0:255];
reg [7:0] S_m2 [0:255];
reg [7:0] S_m3 [0:255];

wire [7:0] S_wd = {I_y[7:1], I_obs};
always @(posedge I_clk) begin
    if (I_valid && I_row[1:0] == 2'd0) S_m0[I_col] <= S_wd;
    if (I_valid && I_row[1:0] == 2'd1) S_m1[I_col] <= S_wd;
    if (I_valid && I_row[1:0] == 2'd2) S_m2[I_col] <= S_wd;
    if (I_valid && I_row[1:0] == 2'd3) S_m3[I_col] <= S_wd;
end

// ---- 行收齐 → 排队处理 ----
reg        S_req;                       // 有一行等着处理
reg [6:0]  S_req_row;
reg        S_req_last;                  // 处理完这一行以后还要处理最后一行

// ---- 处理引擎 ----
reg        S_busy;
reg [6:0]  S_p;                         // 正在处理的行
reg        S_then_last;
reg [8:0]  S_i;                         // 0~LAST_COL+1：读第 min(i, LAST_COL) 列
reg        S_rd_v;                      // 上一拍发了读
reg [7:0]  S_rd_col;                    // 上一拍读的列号（= 这一拍出来的数据是哪一列）

wire [6:0] S_up = (S_p == 7'd0) ? S_p : S_p - 7'd1;
wire [6:0] S_dn = (S_p == LAST_ROW) ? S_p : S_p + 7'd1;
wire [7:0] S_ra = (S_i > LAST_COL) ? LAST_COL : S_i[7:0];

reg  [7:0] S_q0, S_q1, S_q2, S_q3;
always @(posedge I_clk) begin
    S_q0 <= S_m0[S_ra];
    S_q1 <= S_m1[S_ra];
    S_q2 <= S_m2[S_ra];
    S_q3 <= S_m3[S_ra];
end
function [7:0] pick;
    input [1:0] s;
    input [7:0] a, b, c, d;
    pick = (s == 2'd0) ? a : (s == 2'd1) ? b : (s == 2'd2) ? c : d;
endfunction
reg [1:0] S_su, S_sp, S_sd;             // 上一拍读的时候三行在哪块（数据这一拍出来）
wire [7:0] S_du = pick(S_su, S_q0, S_q1, S_q2, S_q3);
wire [7:0] S_dp = pick(S_sp, S_q0, S_q1, S_q2, S_q3);
wire [7:0] S_dd = pick(S_sd, S_q0, S_q1, S_q2, S_q3);

// 3×3 窗口：每行 3 个障碍位（左 中 右），中间行再留中、右两列的亮度
reg [2:0] S_wu, S_wp, S_wd3;
reg [6:0] S_ym, S_yr;
reg [8:0] S_cnt_col;                    // 窗口里已经进了几列（第 2 列进来以后开始输出）

function [3:0] pop9;
    input [8:0] b;
    integer k;
    begin
        pop9 = 4'd0;
        for (k = 0; k < 9; k = k + 1) pop9 = pop9 + {3'd0, b[k]};
    end
endfunction

// 新一列进来以后的窗口（组合）：左 ← 中、中 ← 右、右 ← 新；输出中间那一列
wire [2:0] S_nu = {S_wu[1:0], S_du[0]};
wire [2:0] S_np = {S_wp[1:0], S_dp[0]};
wire [2:0] S_nd = {S_wd3[1:0], S_dd[0]};
wire       S_first = (S_cnt_col == 9'd1);  // 这次输出的是第 0 列：左邻复制中间
wire [8:0] S_win = S_first ? {S_nu[1], S_nu[1:0], S_np[1], S_np[1:0], S_nd[1], S_nd[1:0]}
                           : {S_nu, S_np, S_nd};

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        S_req <= 1'b0; S_req_row <= 7'd0; S_req_last <= 1'b0;
        S_busy <= 1'b0; S_p <= 7'd0; S_then_last <= 1'b0; S_i <= 9'd0; S_rd_v <= 1'b0; S_rd_col <= 8'd0;
        S_su <= 2'd0; S_sp <= 2'd0; S_sd <= 2'd0;
        S_wu <= 3'd0; S_wp <= 3'd0; S_wd3 <= 3'd0; S_ym <= 7'd0; S_yr <= 7'd0; S_cnt_col <= 9'd0;
        O_valid <= 1'b0; O_row <= 7'd0; O_col <= 8'd0; O_y7 <= 7'd0; O_obs <= 1'b0; O_frame_done <= 1'b0;
    end else begin
        O_valid <= 1'b0;
        O_frame_done <= 1'b0;

        // 行收齐：第 r 行（r ≥ 1）→ 处理 r−1；最后一行收齐时还要接着处理最后一行
        if (I_valid && I_col == LAST_COL && I_row != 7'd0) begin
            S_req <= 1'b1; S_req_row <= I_row - 7'd1; S_req_last <= (I_row == LAST_ROW);
        end

        if (!S_busy) begin
            if (S_req) begin
                S_req <= 1'b0;
                S_busy <= 1'b1; S_p <= S_req_row; S_then_last <= S_req_last;
                S_i <= 9'd0; S_rd_v <= 1'b0; S_cnt_col <= 9'd0;
            end
        end else begin
            // 发读：第 i 拍读 min(i, LAST_COL) 列（i = 0 ~ LAST_COL + 1）
            S_rd_v   <= (S_i <= {1'b0, LAST_COL} + 9'd1);
            S_rd_col <= S_ra;
            S_su <= S_up[1:0]; S_sp <= S_p[1:0]; S_sd <= S_dn[1:0];
            if (S_i <= {1'b0, LAST_COL} + 9'd1) S_i <= S_i + 9'd1;
            // 收数据：窗口右移
            if (S_rd_v) begin
                S_wu <= S_nu; S_wp <= S_np; S_wd3 <= S_nd;
                S_ym <= S_yr; S_yr <= S_dp[7:1];
                S_cnt_col <= S_cnt_col + 9'd1;
                if (S_cnt_col != 9'd0) begin                        // 窗口里有中间列了：输出它
                    O_valid <= 1'b1;
                    O_row   <= S_p;
                    O_col   <= S_cnt_col[7:0] - 8'd1;
                    O_y7    <= S_yr;                                // 中间列的亮度（这一拍之前在"右"位置）
                    O_obs   <= (pop9(S_win) >= 4'd5);
                end
                if (S_cnt_col == {1'b0, LAST_COL} + 9'd1) begin      // 最后一列输出完
                    if (S_then_last) begin
                        S_p <= LAST_ROW; S_then_last <= 1'b0;
                        S_i <= 9'd0; S_rd_v <= 1'b0; S_cnt_col <= 9'd0;
                    end else begin
                        S_busy <= 1'b0;
                        if (S_p == LAST_ROW) O_frame_done <= 1'b1;
                    end
                end
            end
        end
    end
end

endmodule
