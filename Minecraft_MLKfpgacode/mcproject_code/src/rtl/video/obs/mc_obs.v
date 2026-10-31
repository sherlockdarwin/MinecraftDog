`timescale 1ns / 1ps
// =============================================================================
// mc_obs.v  避障子系统（像素时钟域 = MIPI RX 字节时钟）：白平衡后的 1920×1080 → 160×90 → 分类 → 去噪 → 扫描 / 框 / 方向
//
//   isp 输出（和 mc_scale 并联）─► mc_obs_down ─► mc_obs_core ─┬─► 写总线 / 发布 → 显示端 mc_obs_view（屏幕下面的处理画面）
//                                                              └─► 方向、距离 → 屏幕文字 / 跟随决策（mc_follow）
//   参数说明见各子模块；几何（离地高度、倾角 → 每行多远）在 tools/gen_obs_lut.pl → mc_obs_lut.v；从第几行起判断障碍是 ROW_MIN。
// =============================================================================
module mc_obs #(
    parameter [7:0]  REF_X0 = 8'd56,    // 地面参考区（网格坐标）：车正前方、画面最下面
    parameter [7:0]  REF_X1 = 8'd103,
    parameter [6:0]  REF_Y0 = 7'd82,
    parameter [6:0]  REF_Y1 = 7'd89,
    parameter [11:0] TC     = 12'd12,   // 地面颜色门限（色度 / 亮度直方图）
    parameter [11:0] TY     = 12'd12,
    parameter [2:0]  YSPREAD = 3'd2,    // 学习地面时亮度往两边放宽几格（见 mc_obs_class.v）
    parameter [2:0]  YS_NEAR = 3'd1,    // 近处放宽几格
    parameter [6:0]  NEAR_ROW = 7'd65,  // 从这一行往下算近处
    parameter [9:0]  RELEARN_FR = 10'd300,  // 连续这么多帧认不出参考区 → 重学一帧
    parameter [6:0]  ROW_MIN = 7'd29,   // 从这一行起往下才判断障碍（160×90 网格的行；再往上太远，先不管）
    parameter [7:0]  D_CAP  = 8'd150,   // 选方向最远算到 150 cm
    parameter [7:0]  D_STOP = 8'd35     // 最好的方向也不到 35 cm → 停
)(
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_fs,            // isp 输出：帧开始 / 有效 / 每拍 4 像素
    input  wire        I_valid,
    input  wire [95:0] I_data,

    output wire [24:0] O_wbus,
    output wire        O_pub_bank,
    output wire        O_pub_valid,
    output wire [5:0]  O_go,
    input  wire        I_disp_bank,

    output wire        O_done,
    output wire [127:0] O_sec_dist,
    output wire [3:0]  O_go_head,
    output wire signed [6:0] O_go_deg,
    output wire [7:0]  O_go_free,
    output wire        O_stop,
    output wire [7:0]  O_near_cm,
    output wire signed [6:0] O_near_deg,
    output wire [71:0] O_head_free,
    output wire        O_res_tog
);

wire        S_d_v;
wire [6:0]  S_d_row;
wire [7:0]  S_d_col;
wire [23:0] S_d_rgb;

mc_obs_down u_down (
    .I_clk (I_clk), .I_rst_n (I_rst_n),
    .I_fs (I_fs), .I_valid (I_valid), .I_data (I_data),
    .O_fs (), .O_valid (S_d_v), .O_row (S_d_row), .O_col (S_d_col), .O_rgb (S_d_rgb)
);

mc_obs_core #(
    .REF_X0 (REF_X0), .REF_X1 (REF_X1), .REF_Y0 (REF_Y0), .REF_Y1 (REF_Y1),
    .TC (TC), .TY (TY), .YSPREAD (YSPREAD), .YS_NEAR (YS_NEAR), .NEAR_ROW (NEAR_ROW), .RELEARN_FR (RELEARN_FR), .ROW_MIN (ROW_MIN), .D_CAP (D_CAP), .D_STOP (D_STOP)
) u_core (
    .I_clk (I_clk), .I_rst_n (I_rst_n),
    .I_valid (S_d_v), .I_row (S_d_row), .I_col (S_d_col), .I_rgb (S_d_rgb),
    .O_wbus (O_wbus), .O_pub_bank (O_pub_bank), .O_pub_valid (O_pub_valid), .O_go (O_go), .I_disp_bank (I_disp_bank),
    .O_done (O_done), .O_sec_dist (O_sec_dist), .O_go_head (O_go_head), .O_go_deg (O_go_deg), .O_go_free (O_go_free),
    .O_stop (O_stop), .O_near_cm (O_near_cm), .O_near_deg (O_near_deg),
    .O_head_free (O_head_free), .O_res_tog (O_res_tog)
);

endmodule
