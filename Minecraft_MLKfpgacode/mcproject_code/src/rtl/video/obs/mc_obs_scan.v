`timescale 1ns / 1ps
// =============================================================================
// mc_obs_scan.v  列扫描 → 16 个方向的最近障碍 → 障碍框 → 选方向
//
//   1. 列扫描（随去噪后的障碍图逐点做）：每列记住"最靠下的一段障碍"（连续 ≥ 2 行才算，挡掉单行误判）的上沿 / 下沿行号。
//      只看第 ROW_MIN 行以下（再往上太远，先不管；第几行对应多远见 mc_obs_lut 的距离表）。下沿 = 这一列离车最近的障碍点。
//   2. 一帧扫完：160 列每 10 列一个扇区（16 个方向，左 → 右）：扇区里有没有障碍、最近的下沿（行号最大）、
//      最高的上沿（行号最小）、障碍的最左 / 最右列。
//   3. 画框：相邻扇区都有障碍、而且上下范围重叠 → 算同一个障碍，合成一个框（上沿取最小、下沿取最大、左右取两头）。
//   4. 距离：扇区最近障碍的下沿行号 → 地面距离（mc_obs_lut，厘米）；没有障碍 = 255。和上一帧取较小值（防闪）。
//   5. 选方向（按车宽：mc_obs_lut 的 O_thr，车宽 20 cm + 两边各 5 cm）：候选方向 b = 4~12（扇区 b−1 和 b 的分界线，约 ±19°，b = 8 正前方）。
//      车沿方向 b 直走能走多远 = 挡住它的扇区里最近的距离；扇区 j 的距离 ≤ O_thr(b, j) 才算挡住（离路线横向不到半个车宽 + 余量），
//      一个都没挡 = 255。取最远的方向（最多算 D_CAP）；一样远时取离正前方近的（按 8,7,9,6,10,5,11,4,12 的顺序比，先到先得）。
//      最远的也不到 D_STOP → 停。每个方向逐个扇区比 16 拍，9 个方向约 150 拍。
//   6. 输出：框表（16 个扇区 × 4 字节，经写总线送到显示）+ 结果寄存器（方向、距离、最近的障碍、9 个方向各能走多远）；O_done 打一拍。
// =============================================================================
module mc_obs_scan #(
    parameter [6:0] ROW_MIN = 7'd29,   // 从这一行起往下才判断障碍（网格行 0~89）
    parameter [7:0] D_CAP  = 8'd150,    // 选方向时最远算到多少厘米
    parameter [7:0] D_STOP = 8'd35,     // 最好的方向也不到这么远 → 停
    parameter [6:0] LAST_ROW = 7'd89,
    parameter [7:0] LAST_COL = 8'd159
)(
    input  wire        I_clk,
    input  wire        I_rst_n,

    input  wire        I_valid,         // 去噪后的障碍图（mc_obs_morph），按行一拍一点
    input  wire [6:0]  I_row,
    input  wire [7:0]  I_col,
    input  wire        I_obs,
    input  wire        I_frame_done,

    output reg         O_bw,            // 框表写：第 {扇区, 字节} 个字节
    output reg  [5:0]  O_baddr,
    output reg  [7:0]  O_bdata,
    output reg         O_done,          // 这一帧的结果都出来了（框表写完）

    output reg  [127:0] O_sec_dist,     // 16 个方向的最近障碍距离（厘米，255 = 没有），扇区 0 在 [7:0]
    output reg  [3:0]  O_go_head,       // 选中的方向 4~12（扇区 b−1 和 b 的分界线，8 = 正前方）
    output reg  signed [6:0] O_go_deg,  // 它的方向（度，左负右正）
    output reg  [7:0]  O_go_free,       // 它能走多远（厘米，最多 D_CAP）
    output reg         O_stop,          // 哪边都走不了
    output reg  [7:0]  O_near_cm,       // 最近的障碍（厘米，255 = 判断区里没有）
    output reg  signed [6:0] O_near_deg,// 它的方向
    output reg  [71:0] O_head_free      // 方向 4~12 各能走多远（厘米，255 = 没挡），方向 4 在 [7:0]
);

// ---------------------------------------------------------------------------
// 几何表
// ---------------------------------------------------------------------------
reg  [6:0]  S_lut_row;
reg  [3:0]  S_lut_sec, S_lut_head;
wire [7:0]  S_lut_dist;
wire signed [6:0] S_sec_deg, S_head_deg;
reg  [3:0]  S_hb;                       // 选方向：正在算的方向
reg  [3:0]  S_hj;                       //         正在比的扇区
wire [7:0]  S_thr;                      //         扇区 S_hj 挡住方向 S_hb 的距离门限
mc_obs_lut u_lut (
    .I_row (S_lut_row), .O_dist (S_lut_dist),
    .I_sec (S_lut_sec), .O_sec_deg (S_sec_deg),
    .I_head (S_lut_head), .O_head_deg (S_head_deg),
    .I_tb (S_hb), .I_tj (S_hj), .O_thr (S_thr)
);

// ---------------------------------------------------------------------------
// 1. 列状态 RAM：{有障碍, 段上沿, 段下沿, 当前段上沿, 当前段长度(0~3), 上一行是不是障碍}
// ---------------------------------------------------------------------------
reg  [24:0] S_col [0:255];
reg  [24:0] S_rd;
reg  [7:0]  S_ra;                       // 扇区遍历时的读地址
reg         S_we;
reg  [7:0]  S_wa;
reg  [24:0] S_wd;
reg  [2:0]  S_st;
localparam [2:0] ST_INIT = 3'd0, ST_SCAN = 3'd1, ST_WAIT = 3'd2, ST_SEC = 3'd3, ST_MRG = 3'd4, ST_PLAN = 3'd5, ST_BOX = 3'd6, ST_HEAD = 3'd7;
wire [7:0]  S_raddr = (S_st == ST_SCAN) ? I_col : S_ra;   // 扫描时直接用输入列号：数据和第 1 拍的点对齐
always @(posedge I_clk) begin
    S_rd <= S_col[S_raddr];
    if (S_we) S_col[S_wa] <= S_wd;
end

reg [8:0] S_c;                          // 扇区遍历 / 清零用的列号
reg [3:0] S_k;                          // 扇区 / 步骤号
reg [5:0] S_j;
reg [2:0] S_wait;

// 扫描流水：第 0 拍给读地址，第 1 拍算新状态，第 2 拍写
reg        S1_v, S1_f;
reg [6:0]  S1_row;
reg [7:0]  S1_col;

wire       S_prev = S_rd[0];
wire [1:0] S_len  = S_rd[2:1];
wire [6:0] S_ctop = S_rd[9:3];
wire [6:0] S_rbot = S_rd[16:10];
wire [6:0] S_rtop = S_rd[23:17];
wire       S_has  = S_rd[24];

wire [6:0] S_ctop_n = (S1_f && !S_prev) ? S1_row : S_ctop;
wire [1:0] S_len_n  = !S1_f ? 2'd0 : !S_prev ? 2'd1 : (S_len == 2'd3) ? 2'd3 : S_len + 2'd1;
wire       S_take   = S1_f && (S_len_n >= 2'd2);
wire [24:0] S_new   = {S_take ? 1'b1 : S_has, S_take ? S_ctop_n : S_rtop, S_take ? S1_row : S_rbot, S_ctop_n, S_len_n, S1_f};

// ---------------------------------------------------------------------------
// 2. 扇区统计
// ---------------------------------------------------------------------------
reg        S_sec_has [0:15];
reg [6:0]  S_sec_top [0:15];
reg [6:0]  S_sec_bot [0:15];
reg [7:0]  S_sec_x0  [0:15];
reg [7:0]  S_sec_x1  [0:15];
reg        S_a_has;
reg [6:0]  S_a_top, S_a_bot;
reg [7:0]  S_a_x0, S_a_x1;
reg        S_d_v;                       // 扇区遍历：这一拍的读数据有效
reg [7:0]  S_d_c;                       // 它是哪一列
reg [3:0]  S_d_k;                       // 哪个扇区
reg [3:0]  S_d_in;                      // 扇区里第几列

// ---------------------------------------------------------------------------
// 3. 合框：每个扇区记"属于哪个框"，框表另存
// ---------------------------------------------------------------------------
reg        S_r_v  [0:15];               // 扇区有框
reg [3:0]  S_r_id [0:15];
reg [6:0]  S_b_top [0:15];
reg [6:0]  S_b_bot [0:15];
reg [7:0]  S_b_x0  [0:15];
reg [7:0]  S_b_x1  [0:15];
reg        S_m_act;
reg [3:0]  S_m_id;
reg [6:0]  S_m_top, S_m_bot;
reg [7:0]  S_m_x0, S_m_x1;

// ---------------------------------------------------------------------------
// 4/5. 距离、选方向
// ---------------------------------------------------------------------------
reg [7:0]  S_dprev [0:15];              // 上一帧
reg [7:0]  S_f [0:15];                  // 两帧较小值
reg [7:0]  S_best_w;
reg [3:0]  S_best_s;
reg [7:0]  S_near;
reg [3:0]  S_near_k;
reg [4:0]  S_nj;                        // 找最近的障碍：扇区序号（16 = 找完）
reg [3:0]  S_hk;                        // 选方向：第几个方向（按 pref 的顺序，9 = 算完）
reg        S_pv, S_plast;               //   第 1 拍：取到扇区距离和门限（S_plast = 这个方向的最后一个扇区）
reg [7:0]  S_pf, S_pt;
reg [3:0]  S_pb;
reg [7:0]  S_acc;                       //   第 2 拍：这个方向到目前为止被挡的最近距离
reg        S_qv;                        //   第 3 拍：一个方向算完：存起来、和最好的比
reg [7:0]  S_qm;
reg [3:0]  S_qb;
reg [7:0]  S_hf [4:12];                 // 每个方向能走多远

function [3:0] pref;                    // 第 k 个比较的方向：8,7,9,6,10,5,11,4,12
    input [3:0] k;
    pref = k[0] ? 4'd8 - ((k + 4'd1) >> 1) : 4'd8 + (k >> 1);
endfunction
function [7:0] min8;
    input [7:0] a, b;
    min8 = (a < b) ? a : b;
endfunction
wire [7:0] S_cand = (S_pf <= S_pt) ? S_pf : 8'd255;        // 扇区挡住这个方向才算它的距离
wire [7:0] S_qcap = min8(S_qm, D_CAP);

integer i;
always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        S_st <= ST_INIT; S_c <= 9'd0; S_k <= 4'd0; S_j <= 6'd0; S_wait <= 3'd0;
        S_ra <= 8'd0; S_we <= 1'b0; S_wa <= 8'd0; S_wd <= 25'd0;
        S1_v <= 1'b0; S1_f <= 1'b0; S1_row <= 7'd0; S1_col <= 8'd0;
        S_a_has <= 1'b0; S_a_top <= 7'd127; S_a_bot <= 7'd0; S_a_x0 <= 8'd0; S_a_x1 <= 8'd0;
        S_d_v <= 1'b0; S_d_c <= 8'd0; S_d_k <= 4'd0; S_d_in <= 4'd0;
        S_m_act <= 1'b0; S_m_id <= 4'd0; S_m_top <= 7'd0; S_m_bot <= 7'd0; S_m_x0 <= 8'd0; S_m_x1 <= 8'd0;
        S_best_w <= 8'd0; S_best_s <= 4'd8; S_near <= 8'd255; S_near_k <= 4'd0; S_nj <= 5'd0;
        S_hk <= 4'd0; S_hb <= 4'd8; S_hj <= 4'd0; S_pv <= 1'b0; S_plast <= 1'b0; S_pf <= 8'd0; S_pt <= 8'd0; S_pb <= 4'd0;
        S_acc <= 8'd255; S_qv <= 1'b0; S_qm <= 8'd0; S_qb <= 4'd0;
        S_lut_row <= 7'd0; S_lut_sec <= 4'd0; S_lut_head <= 4'd8;
        O_bw <= 1'b0; O_baddr <= 6'd0; O_bdata <= 8'd0; O_done <= 1'b0;
        O_sec_dist <= {16{8'd255}}; O_go_head <= 4'd8; O_go_deg <= 7'sd0; O_go_free <= 8'd0; O_stop <= 1'b1;
        O_near_cm <= 8'd255; O_near_deg <= 7'sd0; O_head_free <= {9{8'd255}};
        for (i = 4; i <= 12; i = i + 1) S_hf[i] <= 8'd255;
        for (i = 0; i < 16; i = i + 1) begin
            S_sec_has[i] <= 1'b0; S_sec_top[i] <= 7'd0; S_sec_bot[i] <= 7'd0; S_sec_x0[i] <= 8'd0; S_sec_x1[i] <= 8'd0;
            S_r_v[i] <= 1'b0; S_r_id[i] <= 4'd0; S_b_top[i] <= 7'd0; S_b_bot[i] <= 7'd0; S_b_x0[i] <= 8'd0; S_b_x1[i] <= 8'd0;
            S_dprev[i] <= 8'd255; S_f[i] <= 8'd255;
        end
    end else begin
        S_we <= 1'b0;
        O_bw <= 1'b0;
        O_done <= 1'b0;
        case (S_st)
            // 上电：列状态清零
            ST_INIT: begin
                S_we <= 1'b1; S_wa <= S_c[7:0]; S_wd <= 25'd0;
                if (S_c[7:0] == 8'd255) begin S_st <= ST_SCAN; S_c <= 9'd0; end
                else S_c <= S_c + 9'd1;
            end
            // 1. 扫描：跟着输入走
            ST_SCAN: begin
                S1_v <= I_valid;
                S1_f <= I_obs && (I_row >= ROW_MIN);
                S1_row <= I_row; S1_col <= I_col;
                if (S1_v) begin S_we <= 1'b1; S_wa <= S1_col; S_wd <= S_new; end
                if (I_frame_done) begin S_st <= ST_WAIT; S_wait <= 3'd0; end
            end
            ST_WAIT: begin                                           // 等扫描流水里最后一个点写完
                S1_v <= 1'b0;
                if (S1_v) begin S_we <= 1'b1; S_wa <= S1_col; S_wd <= S_new; end
                if (S_wait == 3'd3) begin
                    S_st <= ST_SEC; S_c <= 9'd0; S_ra <= 8'd0; S_d_v <= 1'b0; S_d_k <= 4'd0; S_d_in <= 4'd0;
                    S_a_has <= 1'b0; S_a_top <= 7'd127; S_a_bot <= 7'd0;
                end else S_wait <= S_wait + 3'd1;
            end
            // 2. 扇区统计：第 c 拍读第 c 列，下一拍收；收完把这一列清零
            ST_SEC: begin
                S_d_v <= (S_c <= {1'b0, LAST_COL});
                S_d_c <= S_c[7:0];
                if (S_c <= {1'b0, LAST_COL}) begin
                    S_ra <= S_c[7:0] + 8'd1;
                    S_c <= S_c + 9'd1;
                end
                if (S_d_v) begin
                    S_we <= 1'b1; S_wa <= S_d_c; S_wd <= 25'd0;
                    if (S_has) begin
                        if (!S_a_has) S_a_x0 <= S_d_c;
                        S_a_x1 <= S_d_c;
                        if (S_rtop < S_a_top) S_a_top <= S_rtop;
                        if (S_rbot > S_a_bot) S_a_bot <= S_rbot;
                        S_a_has <= 1'b1;
                    end
                    if (S_d_in == 4'd9) begin                         // 一个扇区的 10 列收完
                        S_sec_has[S_d_k] <= S_a_has | S_has;
                        S_sec_top[S_d_k] <= (S_has && S_rtop < S_a_top) ? S_rtop : S_a_top;
                        S_sec_bot[S_d_k] <= (S_has && S_rbot > S_a_bot) ? S_rbot : S_a_bot;
                        S_sec_x0[S_d_k]  <= S_a_has ? S_a_x0 : S_d_c;
                        S_sec_x1[S_d_k]  <= S_has ? S_d_c : S_a_x1;
                        S_a_has <= 1'b0; S_a_top <= 7'd127; S_a_bot <= 7'd0;
                        S_d_in <= 4'd0; S_d_k <= S_d_k + 4'd1;
                        if (S_d_k == 4'd15) begin
                            S_st <= ST_MRG; S_k <= 4'd0; S_m_act <= 1'b0; S_m_id <= 4'd0;
                        end
                    end else S_d_in <= S_d_in + 4'd1;
                end
            end
            // 3. 合框（16 拍）+ 收尾一拍
            ST_MRG: begin
                if (S_sec_has[S_k] && S_m_act && (S_sec_top[S_k] <= S_m_bot) && (S_m_top <= S_sec_bot[S_k])) begin
                    if (S_sec_top[S_k] < S_m_top) S_m_top <= S_sec_top[S_k];      // 接着上一个框
                    if (S_sec_bot[S_k] > S_m_bot) S_m_bot <= S_sec_bot[S_k];
                    S_m_x1 <= S_sec_x1[S_k];
                    S_r_v[S_k] <= 1'b1; S_r_id[S_k] <= S_m_id;
                end else begin
                    if (S_m_act) begin                                           // 上一个框到头了：存起来
                        S_b_top[S_m_id] <= S_m_top; S_b_bot[S_m_id] <= S_m_bot;
                        S_b_x0[S_m_id]  <= S_m_x0;  S_b_x1[S_m_id]  <= S_m_x1;
                    end
                    if (S_sec_has[S_k]) begin                                    // 开一个新框
                        S_m_act <= 1'b1;
                        S_m_id  <= S_m_act ? S_m_id + 4'd1 : S_m_id;
                        S_m_top <= S_sec_top[S_k]; S_m_bot <= S_sec_bot[S_k];
                        S_m_x0  <= S_sec_x0[S_k];  S_m_x1  <= S_sec_x1[S_k];
                        S_r_v[S_k] <= 1'b1; S_r_id[S_k] <= S_m_act ? S_m_id + 4'd1 : S_m_id;
                    end else begin
                        S_m_act <= 1'b0;
                        S_m_id  <= S_m_act ? S_m_id + 4'd1 : S_m_id;
                        S_r_v[S_k] <= 1'b0;
                    end
                end
                if (S_k == 4'd15) begin
                    S_st <= ST_PLAN; S_k <= 4'd0; S_j <= 6'd0;
                    S_lut_row <= S_sec_bot[0];
                end else S_k <= S_k + 4'd1;
            end
            // 4. 距离（16 拍，查表）→（ST_HEAD：最近的障碍 + 选方向）→ 结果
            ST_PLAN: begin
                if (S_j == 6'd0 && S_m_act) begin                            // 合框最后一个框还没存
                    S_b_top[S_m_id] <= S_m_top; S_b_bot[S_m_id] <= S_m_bot;
                    S_b_x0[S_m_id]  <= S_m_x0;  S_b_x1[S_m_id]  <= S_m_x1;
                    S_m_act <= 1'b0;
                end
                if (S_j < 6'd16) begin                                        // 距离：S_lut_row = 第 j 个扇区的最近行
                    S_f[S_j[3:0]]     <= min8(S_sec_has[S_j[3:0]] ? S_lut_dist : 8'd255, S_dprev[S_j[3:0]]);
                    S_dprev[S_j[3:0]] <= S_sec_has[S_j[3:0]] ? S_lut_dist : 8'd255;
                    S_lut_row <= S_sec_bot[S_j[3:0] + 4'd1];
                    S_j <= S_j + 6'd1;
                    if (S_j == 6'd15) begin
                        S_st <= ST_HEAD;
                        S_nj <= 5'd0; S_near <= 8'd255; S_near_k <= 4'd0;
                        S_hk <= 4'd0; S_hb <= pref(4'd0); S_hj <= 4'd0; S_pv <= 1'b0; S_qv <= 1'b0; S_acc <= 8'd255;
                        S_best_w <= 8'd0; S_best_s <= 4'd8;
                    end
                end else begin                                                // 结果（从 ST_HEAD 回来，S_j = 32）
                    S_lut_head <= S_best_s;
                    S_lut_sec <= S_near_k;
                    if (S_j == 6'd33) begin
                        O_go_head <= S_best_s;
                        O_go_deg  <= S_head_deg;
                        O_go_free <= S_best_w;
                        O_stop    <= (S_best_w < D_STOP);
                        O_near_cm <= S_near;
                        O_near_deg <= (S_near == 8'd255) ? 7'sd0 : S_sec_deg;
                        for (i = 0; i < 16; i = i + 1) O_sec_dist[8*i +: 8] <= S_f[i];
                        for (i = 4; i <= 12; i = i + 1) O_head_free[8*(i-4) +: 8] <= S_hf[i];
                        S_st <= ST_BOX; S_j <= 6'd0;
                    end else S_j <= S_j + 6'd1;
                end
            end
            // 4/5. 最近的障碍（16 拍）+ 选方向（同时：9 个方向 × 16 个扇区，三拍流水）
            ST_HEAD: begin
                if (!S_nj[4]) begin
                    if (S_f[S_nj[3:0]] < S_near) begin S_near <= S_f[S_nj[3:0]]; S_near_k <= S_nj[3:0]; end
                    S_nj <= S_nj + 5'd1;
                end
                if (S_hk <= 4'd8) begin                                       // 第 1 拍：取扇区距离、门限
                    S_pv <= 1'b1; S_pf <= S_f[S_hj]; S_pt <= S_thr; S_pb <= S_hb; S_plast <= (S_hj == 4'd15);
                    if (S_hj == 4'd15) begin S_hj <= 4'd0; S_hk <= S_hk + 4'd1; S_hb <= pref(S_hk + 4'd1); end
                    else S_hj <= S_hj + 4'd1;
                end else S_pv <= 1'b0;
                S_qv <= S_pv && S_plast;                                      // 第 2 拍：挡住的取最近
                if (S_pv) begin
                    if (S_plast) begin S_qm <= min8(S_acc, S_cand); S_qb <= S_pb; S_acc <= 8'd255; end
                    else S_acc <= min8(S_acc, S_cand);
                end
                if (S_qv) begin                                               // 第 3 拍：存起来、和最好的比
                    S_hf[S_qb] <= S_qm;
                    if (S_qcap > S_best_w) begin S_best_w <= S_qcap; S_best_s <= S_qb; end
                end
                if (S_hk > 4'd8 && !S_pv) begin S_st <= ST_PLAN; S_j <= 6'd32; end              // 最后一个方向的第 3 拍和这一拍同时做
            end
            // 6. 框表：16 个扇区 × 4 字节 = {有框, 上沿} {0, 下沿} 左列 右列
            ST_BOX: begin
                O_bw <= 1'b1;
                O_baddr <= S_j;
                case (S_j[1:0])
                    2'd0: O_bdata <= {S_r_v[S_j[5:2]], S_b_top[S_r_id[S_j[5:2]]]};
                    2'd1: O_bdata <= {1'b0, S_b_bot[S_r_id[S_j[5:2]]]};
                    2'd2: O_bdata <= S_b_x0[S_r_id[S_j[5:2]]];
                    default: O_bdata <= S_b_x1[S_r_id[S_j[5:2]]];
                endcase
                if (S_j == 6'd63) begin S_st <= ST_SCAN; O_done <= 1'b1; S_d_k <= 4'd0; S_d_in <= 4'd0; end
                S_j <= S_j + 6'd1;
            end
            default: S_st <= ST_SCAN;
        endcase
    end
end

endmodule
