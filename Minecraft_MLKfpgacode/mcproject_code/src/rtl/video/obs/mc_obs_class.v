`timescale 1ns / 1ps
// =============================================================================
// mc_obs_class.v  地面 / 障碍分类（每个 160×90 网格点一个判断），思路来自 Ulrich & Nourbakhsh 2000"按外观找障碍"：
//   车正前方脚下那一块（参考区）当作"地面样本"，统计它的颜色分布；画面里颜色在这个分布里常见的格子 = 地面，不常见的 = 障碍。
//
//   1. 颜色：亮度 Y = (R + 2G + B) / 4，色度 Cb = B − Y、Cr = R − Y（都是移位加减，不用乘法）。
//      色度量化成 16 × 16 格（−64 ~ +63，每格 8），亮度量化成 16 格（每格 16）。
//   2. 地面模型 = 两张直方图：Hc[Cb, Cr]（256 格）、Hy[Y]（16 格），12 位。
//      判断：Hc[这个点的格] ≥ TC 且 Hy[这个点的格] ≥ TY → 地面（O_obs = 0），否则障碍（O_obs = 1）。
//   3. 学习：参考区（REF_X0~X1 列、REF_Y0~Y1 行）里的点在本帧计数 Ac / Ay。一帧最后一个点处理完后更新模型：
//        Hc[b] ← Hc[b] − Hc[b]/4 + Σ(b 和它周围 3×3 格的 Ac)     （色度相近的也算，避免落在格子边上的地面被当成障碍）
//        Hy[y] ← Hy[y] − Hy[y]/4 + Σ(y−2 ~ y+2 格的 Ay)          （亮度放宽 ±2 格，阴影不至于全算成障碍）
//      参考区最多 511 个点（Ac / Ay 9 位）→ H 最大 4 × 511 < 4096，12 位不会溢出；然后把 Ac / Ay 清零。旧模型每帧只留 3/4：参考区被短暂挡住（比如脚踩进来）不会马上把模型带偏，
//      换了一种地面几帧以后就学会。上电先把四张表清零（前一帧全判成障碍，第二帧开始正常）。
//   时序：输入一拍一个点，两个点之间至少隔 3 拍（mc_obs_down 保证）；输出比输入晚 3 拍（附带行列号、亮度）。
//         模型更新约 3300 拍，在一帧最后一个点之后、下一帧第一个点之前做完（中间至少隔 12 行 ≈ 1 万拍）。
// =============================================================================
module mc_obs_class #(
    parameter [7:0]  REF_X0 = 8'd56,    // 参考区（网格坐标，含两端）
    parameter [7:0]  REF_X1 = 8'd103,
    parameter [6:0]  REF_Y0 = 7'd82,
    parameter [6:0]  REF_Y1 = 7'd89,
    parameter [11:0] TC     = 12'd12,   // 色度直方图门限
    parameter [11:0] TY     = 12'd12,   // 亮度直方图门限
    parameter [6:0]  LAST_ROW = 7'd89,
    parameter [7:0]  LAST_COL = 8'd159
)(
    input  wire        I_clk,
    input  wire        I_rst_n,

    input  wire        I_valid,
    input  wire [6:0]  I_row,
    input  wire [7:0]  I_col,
    input  wire [23:0] I_rgb,

    output reg         O_valid,
    output reg  [6:0]  O_row,
    output reg  [7:0]  O_col,
    output reg  [7:0]  O_y,
    output reg         O_obs,
    output wire        O_busy           // 模型更新中（测试用）
);

// ---------------------------------------------------------------------------
// 第 1 拍：Y / Cb / Cr，参考区判断
// ---------------------------------------------------------------------------
wire [9:0] S_ysum = {2'd0, I_rgb[23:16]} + {1'd0, I_rgb[15:8], 1'b0} + {2'd0, I_rgb[7:0]};
wire [7:0] S_y0   = S_ysum[9:2];

reg        S1_v, S1_ref, S1_last;
reg [6:0]  S1_row;
reg [7:0]  S1_col;
reg [7:0]  S1_y;
reg signed [9:0] S1_cb, S1_cr;

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        S1_v <= 1'b0; S1_ref <= 1'b0; S1_last <= 1'b0; S1_row <= 7'd0; S1_col <= 8'd0; S1_y <= 8'd0;
        S1_cb <= 10'sd0; S1_cr <= 10'sd0;
    end else begin
        S1_v    <= I_valid;
        S1_ref  <= I_valid && (I_col >= REF_X0) && (I_col <= REF_X1) && (I_row >= REF_Y0) && (I_row <= REF_Y1);
        S1_last <= I_valid && (I_row == LAST_ROW) && (I_col == LAST_COL);
        S1_row  <= I_row;
        S1_col  <= I_col;
        S1_y    <= S_y0;
        S1_cb   <= $signed({2'd0, I_rgb[7:0]})   - $signed({2'd0, S_y0});
        S1_cr   <= $signed({2'd0, I_rgb[23:16]}) - $signed({2'd0, S_y0});
    end
end

// 量化：(c + 64) / 8，限制在 0~15
function [3:0] q16;
    input signed [9:0] c;
    reg signed [9:0] t;
    begin
        t = (c + 10'sd64) >>> 3;
        q16 = (t < 0) ? 4'd0 : (t > 15) ? 4'd15 : t[3:0];
    end
endfunction
wire [7:0] S_bin_c = {q16(S1_cb), q16(S1_cr)};     // 色度格 = {Cb 格, Cr 格}
wire [3:0] S_bin_y = S1_y[7:4];

// ---------------------------------------------------------------------------
// 直方图 RAM：Hc / Hy（模型）、Ac / Ay（本帧参考区计数）。读：给地址的下一拍出数据
// ---------------------------------------------------------------------------
reg [11:0] S_hc [0:255];
reg [11:0] S_hy [0:15];
reg [8:0]  S_ac [0:255];
reg [8:0]  S_ay [0:15];

// 更新引擎要独占这些 RAM（只在两帧之间）
localparam [2:0] E_IDLE = 3'd0, E_HC = 3'd1, E_HY = 3'd2, E_CLR = 3'd3, E_INIT = 3'd4;
reg  [2:0]  S_est;
reg  [8:0]  S_eb;                       // 当前格
reg  [3:0]  S_ej;                       // 当前邻格序号
reg  [11:0] S_esum;                     // 邻格和
reg  [11:0] S_eh;                       // 这一格的旧模型值
assign O_busy = (S_est != E_IDLE);

// 邻格：色度 3×3（j = 0~8 → dcb = j/3 − 1，dcr = j%3 − 1）；亮度 ±2（j = 0~4 → dy = j − 2）
reg  [3:0]  S_ncb, S_ncr;
reg         S_nin;
always @(*) begin
    S_ncb = S_eb[7:4] + ((S_ej < 4'd3) ? 4'hF : (S_ej < 4'd6) ? 4'h0 : 4'h1);
    S_ncr = S_eb[3:0] + ((S_ej == 4'd0 || S_ej == 4'd3 || S_ej == 4'd6) ? 4'hF : (S_ej == 4'd1 || S_ej == 4'd4 || S_ej == 4'd7) ? 4'h0 : 4'h1);
    S_nin = !((S_eb[7:4] == 4'd0 && S_ej < 4'd3) || (S_eb[7:4] == 4'd15 && S_ej >= 4'd6) ||
              (S_eb[3:0] == 4'd0 && (S_ej == 4'd0 || S_ej == 4'd3 || S_ej == 4'd6)) ||
              (S_eb[3:0] == 4'd15 && (S_ej == 4'd2 || S_ej == 4'd5 || S_ej == 4'd8)));
end
wire [4:0] S_ny  = {1'b0, S_eb[3:0]} + {1'b0, S_ej} - 5'd2;            // 亮度邻格（5 位，带越界）
wire       S_nyin = (S_ny <= 5'd15);

// 地址选择
wire [7:0] S_ac_ra = (S_est == E_HC) ? {S_ncb, S_ncr} : S_bin_c;
wire [3:0] S_ay_ra = (S_est == E_HY) ? S_ny[3:0] : S_bin_y;
wire [7:0] S_hc_ra = (S_est == E_HC) ? S_eb[7:0] : S_bin_c;
wire [3:0] S_hy_ra = (S_est == E_HY) ? S_eb[3:0] : S_bin_y;

reg [11:0] S_hc_rd, S_hy_rd;
reg [8:0]  S_ac_rd, S_ay_rd;
always @(posedge I_clk) begin
    S_hc_rd <= S_hc[S_hc_ra];
    S_hy_rd <= S_hy[S_hy_ra];
    S_ac_rd <= S_ac[S_ac_ra];
    S_ay_rd <= S_ay[S_ay_ra];
end

// ---------------------------------------------------------------------------
// 第 2 拍：查到直方图值 → 判断；参考区计数加 1（写在下一拍）
// ---------------------------------------------------------------------------
reg        S2_v, S2_ref, S2_last;
reg [6:0]  S2_row;
reg [7:0]  S2_col, S2_y, S2_bc;
reg [3:0]  S2_by;

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        S2_v <= 1'b0; S2_ref <= 1'b0; S2_last <= 1'b0; S2_row <= 7'd0; S2_col <= 8'd0; S2_y <= 8'd0;
        S2_bc <= 8'd0; S2_by <= 4'd0;
        O_valid <= 1'b0; O_row <= 7'd0; O_col <= 8'd0; O_y <= 8'd0; O_obs <= 1'b0;
    end else begin
        S2_v <= S1_v; S2_ref <= S1_ref; S2_last <= S1_last;
        S2_row <= S1_row; S2_col <= S1_col; S2_y <= S1_y; S2_bc <= S_bin_c; S2_by <= S_bin_y;
        O_valid <= S2_v;
        O_row   <= S2_row;
        O_col   <= S2_col;
        O_y     <= S2_y;
        O_obs   <= !((S_hc_rd >= TC) && (S_hy_rd >= TY));
    end
end

// ---------------------------------------------------------------------------
// RAM 写：参考区计数（流），模型更新 / 清零（引擎）
// ---------------------------------------------------------------------------
reg        S_wc_ac, S_wc_ay, S_wc_hc, S_wc_hy;
reg [7:0]  S_wa_ac, S_wa_hc;
reg [3:0]  S_wa_ay, S_wa_hy;
reg [8:0]  S_wd_ac, S_wd_ay;
reg [11:0] S_wd_hc, S_wd_hy;

always @(posedge I_clk) begin
    if (S_wc_ac) S_ac[S_wa_ac] <= S_wd_ac;
    if (S_wc_ay) S_ay[S_wa_ay] <= S_wd_ay;
    if (S_wc_hc) S_hc[S_wa_hc] <= S_wd_hc;
    if (S_wc_hy) S_hy[S_wa_hy] <= S_wd_hy;
end

// 引擎：每格先读 9（或 5）个邻格累加，再读出旧模型、写新模型
//   读地址在 S_ej 计数时给出，下一拍数据到；S_ej 从 0 走到 N（N = 邻格数），第 N 拍收最后一个邻格
reg  [11:0] S_hnew;
reg         S_pend_last;                // 本帧最后一个点已经过了第 2 拍，等它的计数写完再启动引擎
reg         S_e_dv;                     // 上一拍发出的邻格读是否在范围内（数据这一拍有效）

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        S_est <= E_INIT; S_eb <= 9'd0; S_ej <= 4'd0; S_esum <= 12'd0; S_eh <= 12'd0; S_pend_last <= 1'b0; S_e_dv <= 1'b0;
        S_wc_ac <= 1'b0; S_wc_ay <= 1'b0; S_wc_hc <= 1'b0; S_wc_hy <= 1'b0;
        S_wa_ac <= 8'd0; S_wa_hc <= 8'd0; S_wa_ay <= 4'd0; S_wa_hy <= 4'd0;
        S_wd_ac <= 9'd0; S_wd_ay <= 9'd0; S_wd_hc <= 12'd0; S_wd_hy <= 12'd0;
    end else begin
        S_wc_ac <= 1'b0; S_wc_ay <= 1'b0; S_wc_hc <= 1'b0; S_wc_hy <= 1'b0;
        // 流：参考区计数 +1（第 2 拍读到的旧值）
        if (S2_v && S2_ref) begin                                    // 参考区在一帧最后，模型更新在两帧之间，不会撞上
            S_wc_ac <= 1'b1; S_wa_ac <= S2_bc; S_wd_ac <= S_ac_rd + 9'd1;
            S_wc_ay <= 1'b1; S_wa_ay <= S2_by; S_wd_ay <= S_ay_rd + 9'd1;
        end
        if (S2_v && S2_last) S_pend_last <= 1'b1;

        case (S_est)
            E_IDLE: if (S_pend_last) begin                              // 最后一个点的计数和这一拍同时写进去，引擎下一拍才读
                        S_pend_last <= 1'b0;
                        S_est <= E_HC; S_eb <= 9'd0; S_ej <= 4'd0; S_esum <= 12'd0; S_e_dv <= 1'b0;
                    end
            E_HC: begin                                                // 每格 10 拍：j = 0~8 发邻格读，j = 9 收最后一个、写
                      S_e_dv <= S_nin && (S_ej <= 4'd8);
                      if (S_ej != 4'd0 && S_e_dv) S_esum <= S_esum + {3'd0, S_ac_rd};
                      if (S_ej == 4'd1) S_eh <= S_hc_rd;                 // j = 0 时读的旧模型
                      if (S_ej == 4'd9) begin
                          S_wc_hc <= 1'b1; S_wa_hc <= S_eb[7:0];
                          S_wd_hc <= S_hnew;
                          S_ej <= 4'd0; S_esum <= 12'd0; S_e_dv <= 1'b0;
                          if (S_eb == 9'd255) begin S_est <= E_HY; S_eb <= 9'd0; end
                          else S_eb <= S_eb + 9'd1;
                      end else S_ej <= S_ej + 4'd1;
                  end
            E_HY: begin                                                // 每格 6 拍：j = 0~4 发邻格读，j = 5 收最后一个、写
                      S_e_dv <= S_nyin && (S_ej <= 4'd4);
                      if (S_ej != 4'd0 && S_e_dv) S_esum <= S_esum + {3'd0, S_ay_rd};
                      if (S_ej == 4'd1) S_eh <= S_hy_rd;
                      if (S_ej == 4'd5) begin
                          S_wc_hy <= 1'b1; S_wa_hy <= S_eb[3:0];
                          S_wd_hy <= S_hnew;
                          S_ej <= 4'd0; S_esum <= 12'd0; S_e_dv <= 1'b0;
                          if (S_eb == 9'd15) begin S_est <= E_CLR; S_eb <= 9'd0; end
                          else S_eb <= S_eb + 9'd1;
                      end else S_ej <= S_ej + 4'd1;
                  end
            E_CLR, E_INIT: begin                                       // 清本帧计数（上电时连模型一起清）
                      S_wc_ac <= 1'b1; S_wa_ac <= S_eb[7:0]; S_wd_ac <= 9'd0;
                      S_wc_ay <= 1'b1; S_wa_ay <= S_eb[3:0]; S_wd_ay <= 9'd0;
                      if (S_est == E_INIT) begin
                          S_wc_hc <= 1'b1; S_wa_hc <= S_eb[7:0]; S_wd_hc <= 12'd0;
                          S_wc_hy <= 1'b1; S_wa_hy <= S_eb[3:0]; S_wd_hy <= 12'd0;
                      end
                      if (S_eb == 9'd255) begin S_est <= E_IDLE; S_eb <= 9'd0; end
                      else S_eb <= S_eb + 9'd1;
                  end
            default: S_est <= E_IDLE;
        endcase
    end
end

// 新模型 = 旧 − 旧/4 + 邻格和（最后一个邻格这一拍才到，一起加）
always @(*) begin
    S_hnew = S_eh - {2'd0, S_eh[11:2]} + S_esum + ((S_e_dv) ? {3'd0, (S_est == E_HC) ? S_ac_rd : S_ay_rd} : 12'd0);
end

endmodule
