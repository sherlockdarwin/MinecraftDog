`timescale 1ns / 1ps
// 测试 mc_obs_core（分类 + 去噪 + 列扫描 / 扇区 / 合框 / 距离 / 选方向 + 送显示的写总线和双缓冲）。
//   测试台自己按规格写一份模型（数组 + 循环，不照 RTL 的流水结构）：
//     分类：Y=(R+2G+B)>>2，Cb=B−Y，Cr=R−Y，色度格 = 限幅(⌊(c+64)/8⌋, 0, 15)，亮度格 = Y>>4；
//           地面 = Hc ≥ TC 且（第 NR 行以下 Hs，以上 Hy）≥ TY。参考区点计数的条件：判成地面，或者同一列第 CHK = 82 − 6 行是地面（上电前 RF 帧、重学那一帧全部计数）。
//           每帧结束：计数够参考区的 1/4（或全学）才更新：Hc ← Hc − ⌊Hc/4⌋ + Σ3×3 邻格的本帧参考区计数（≤ 4095），Hy 同理（±YS 格；本文件 YS = 2，tb_obs_core_ys4.v 用 4），Hs 同理（±YSN 格）；
//           不够 = 模型不动，连续 RF 帧不够 → 下一帧全学。
//     去噪：3×3 里 ≥ 5 个障碍（越界复制边上的点）。
//     列扫描：只看第 ROW_MIN 行以下（宏 TB_OBS_RM，本文件 29；tb_obs_core_cur.v 用 mctop 现在的 53）；每列最靠下的一段连续 ≥ 2 行的障碍 → 上沿、下沿。
//     扇区 / 合框 / 距离（实数公式：离地 174 mm；本文件和 _ys4 下倾 15°，配测试专用的固定几何表 models/mc_obs_lut_t15.v，下面的场景按它设计；
//       _cur 用车上的几何表：按"第 60 行看到 135 cm、那条线左右宽 170 cm"反推的倾角和焦距（宏 TB_OBS_REAL））/ 两帧取小 / 最近障碍 /
//     选方向：方向 b = 4~12（扇区 b−1、b 的分界线）；扇区 j 挡住 b ⇔ 距离 ≤ floor(15 / sin(地面上 j 靠近 b 的那条边和 b 的夹角))（挨着的两个扇区多远都挡）；
//             b 能走多远 = 挡住它的最近距离（没挡 = 255）；按 8,7,9,6,10,5,11,4,12 的顺序取最远（最多 150），< D_STOP 停（本文件 35，_cur 用 mctop 现在的 60）。地面角度 = atan(列偏移 × cos(倾角) / F)。
//   核对：每帧 O_done 后的方向 / 距离输出；送显示的写总线：发布的那一块画面（亮度高 7 位 + 去噪后的障碍位）和框表逐字节；
//         写总线从不写显示端正在显示的那一块；显示端没跟上时这一帧不写、不发布。
//   场景（8 帧）：地面带噪声、上方是墙；蓝 / 红两个相邻且上下重叠的障碍（合成一个框）、跨过判断区上沿（ROW_MIN 行）的暗色障碍（上沿截在 ROW_MIN，ROW_MIN = 29 时）、
//         只有 ROW_MIN 前后 2 行的绿带（只算到 1 行 → 不算障碍）、贴左边界的品红障碍、单点噪声（被去掉）、障碍逐帧下移（两帧取小）、
//         显示端不跟（跳帧）、参考区里放东西（模型跟着学）、没有障碍（直走）、全挡住（停）。
//   边界场景（第 9~14 帧，无噪声的精确颜色，见 special）：第 9 帧往参考区里放几种颜色各 16 个（其中一种 X 放在参考区 4 条边上），
//         之后几帧不放，模型按 16 → 12 → 9 衰减：正好等于门限 12 的那一帧必须判地面、9 必须判障碍；
//         色度格 0 / 15 的邻格不能绕回另一头、Cb 量化正好 15 不能被压成 14、亮度邻格 ±2 的两头和最后一格（15）都要算到；
//         去噪的左边界复制、下边界复制、一帧最后一个点（3×3 里正好差它一个就过半）。
//   扫描 / 选方向的边界（第 15~21 帧，每个场景放两帧，让"和上一帧取近"稳定）：最右边的方向（12）是唯一最好的、
//         方向 4 和 12 一样远（中间的都被正前方的障碍挡住）、最好的方向正好等于 D_STOP（不停）、两个扇区的上下范围正好挨着（合成一个框）、
//         只有最后一列碰到最后一行（一帧最后一个点）、只有 2 行高的障碍 + 扇区最后一列独有的最高 / 最低点、障碍距离正好等于车宽门限（算挡住）。
//         （第 15~21 帧和第 2 帧的"场景检查"按 ROW_MIN = 29 设计，ROW_MIN 别的值时只比 RTL 和模型、不查场景。）
//   判断区上沿（第 22 帧，按 ROW_MIN 摆）：正好 ROW_MIN、ROW_MIN+1 两行（算）、跨过上沿（上沿截在 ROW_MIN）、只有 ROW_MIN 一行在里面（不算）、整块在上面（不管）。
//   学习的门（第 7~9 帧、第 23~29 帧）：连续 RF 帧认不出参考区 → 下一帧全学（第 9、13 帧靠它教颜色；中间夹一帧能认出的就重新数）；
//         墙进了参考区不学成地面（第 23 帧）；模型冻住时不衰减、正好 1/4 的点能认出就更新、差一个点就冻住（第 24~27 帧，靠颜色 M 的 16 → 12 → 9 衰减看出来）；
//         近处 / 远处的亮度门限正好在 NR 行切换、近处判成障碍的颜色进参考区不学、地面慢慢变亮能跟上（第 28~29 帧）；
//         花纹和墙（第 30~33 帧）：不认识的颜色从第 CHK 行一直连到参考区 = 墙，不学；只差一行（第 CHK 行是地面）= 花纹，学；参考区最左 / 最右一列也对；
//         学过的花纹颜色衰减到门限以下以后，再进参考区还能学回来（不会一跌破就永远学不回来）。
`ifndef TB_OBS_YS
`define TB_OBS_YS 2
`endif
`ifndef TB_OBS_REAL
`define TB_OBS_REAL 0
`endif
`ifndef TB_OBS_DSTOP
`define TB_OBS_DSTOP 35
`endif
`ifndef TB_OBS_RM
`define TB_OBS_RM 29
`endif
`ifndef TB_OBS_NR
`define TB_OBS_NR 70
`endif
`ifndef TB_OBS_TC
`define TB_OBS_TC 12
`endif
`ifndef TB_OBS_YSN
`define TB_OBS_YSN 1
`endif
module tb_obs_core;
localparam YS = `TB_OBS_YS;            // 亮度邻格放宽几格（YSPREAD）：本文件 2（下面的边界场景按 ±2 设计）；tb_obs_core_ys4.v 用 4、tb_obs_core_cur.v 用 mctop 现在的值（2）
localparam RM = `TB_OBS_RM;            // 从第几行起判断障碍（ROW_MIN）：本文件 29（第 15~21 帧的场景按它设计）；tb_obs_core_cur.v 用 53（mctop 现在的值）
localparam GEO_REAL = `TB_OBS_REAL;      // 0：测试专用的 15° 几何表；1：车上的几何表（mc_obs_lut.v）
localparam DSTOP = `TB_OBS_DSTOP;        // 最好的方向也不到这么远就停（D_STOP）
localparam YSN = `TB_OBS_YSN;            // 近处亮度放宽几格（YS_NEAR）：本文件 1（第 28~29 帧按它设计）；tb_obs_core_ys4.v 用 2
localparam NR  = `TB_OBS_NR;             // 从第几行往下算近处（NEAR_ROW）：本文件 70（不是默认的 65，没传进去就对不上）；tb_obs_core_cur.v 用 mctop 现在的 65
localparam TCV = `TB_OBS_TC;             // 地面门限（TC = TY）：本文件 12（第 9~14 帧的衰减边界按它设计）；tb_obs_core_cur.v 用 mctop 现在的 16，边界检查跳过，只比 RTL 和模型
localparam RF  = 2;                      // RELEARN_FR：连续 2 帧认不出就重学（场景用得短一点）
localparam REF_MIN = 96;                 // 参考区 48 × 8 = 384 点的 1/4
localparam CHK = 76;                     // 第 82 − 6 行：这一行是地面，参考区里不认识的点算花纹
integer F17_BOT;                        // 第 17 帧一整面墙的下沿：最靠下的、距离还 ≥ D_STOP 的一行（15° 表：67 = 35 cm 正好等于；车上的表按表算）
integer F7_ROW;                         // 第 7 帧"全挡住"从这一行往下（15° 表：75；车上的表：F17_BOT 的下一行，已经 < D_STOP）

reg clk = 0, rst_n = 0;
always #5 clk = ~clk;

reg         v = 0;
reg  [6:0]  row = 0;
reg  [7:0]  col = 0;
reg  [23:0] rgb = 0;
reg         disp_bank = 0;
wire [24:0] wbus;
wire        pub_bank, pub_valid, done, stop;
wire [5:0]  go;
wire [127:0] sec_dist;
wire [3:0]  go_head;
wire [71:0] head_free;
wire        res_tog;
wire signed [6:0] go_deg, near_deg;
wire [7:0]  go_free, near_cm;

mc_obs_core #(.TC(TCV), .TY(TCV), .YSPREAD(YS), .YS_NEAR(YSN), .NEAR_ROW(NR), .RELEARN_FR(RF), .ROW_MIN(RM), .D_STOP(DSTOP)) dut (
    .I_clk(clk), .I_rst_n(rst_n), .I_valid(v), .I_row(row), .I_col(col), .I_rgb(rgb),
    .O_wbus(wbus), .O_pub_bank(pub_bank), .O_pub_valid(pub_valid), .O_go(go), .I_disp_bank(disp_bank),
    .O_done(done), .O_sec_dist(sec_dist), .O_go_head(go_head), .O_go_deg(go_deg), .O_go_free(go_free),
    .O_stop(stop), .O_near_cm(near_cm), .O_near_deg(near_deg), .O_head_free(head_free), .O_res_tog(res_tog)
);

integer errors = 0;
always @(errors) if (errors > 25) begin #1; $display("FAIL  tb_obs_core: too many errors"); $finish; end

// ---------------- 几何（独立按公式算）----------------
real PI, F;
integer LUT_D [0:89];
integer SEC_DEG [0:15], HEAD_DEG [0:15];
integer THR [0:255];                   // 车宽门限：[方向 × 16 + 扇区]
integer ROW_MIN;
function integer rnd; input real x; rnd = (x < 0) ? -$rtoi(-x + 0.5) : $rtoi(x + 0.5); endfunction
task init_geom;
    integer r, k, b, j, e, t;
    real a, dd, ct, g, tilt;
    begin
        PI = 3.14159265358979;
        ROW_MIN = RM;
        if (!GEO_REAL) begin F = 960.0 / $tan(36.0 * PI / 180.0); tilt = 15.0 * PI / 180.0; end   // 测试表：视场 72°、下倾 15°
        else begin                                                                         // 车上：第 60 行看到 135 cm、那条线左右宽 170 cm，倾角和焦距一起反推
            F = 1500.0;
            for (k = 0; k < 20; k = k + 1) begin
                tilt = $atan(17.4 / 135.0) - $atan((12.0 * 60 + 5.5 - 539.5) / F);
                F = 960.0 * (135.0 * $cos(tilt) + 17.4 * $sin(tilt)) / 85.0;
            end
        end
        for (r = 0; r < 90; r = r + 1) begin
            a = tilt + $atan((12.0 * r + 5.5 - 539.5) / F);
            if (a <= 0.5 * PI / 180.0) LUT_D[r] = 255;
            else begin
                dd = 17.4 / $tan(a);
                LUT_D[r] = (rnd(dd) > 255) ? 255 : rnd(dd);
            end
        end
        F17_BOT = RM; for (r = RM; r < 90; r = r + 1) if (LUT_D[r] >= DSTOP) F17_BOT = r;
        F7_ROW = 75;                                          // 要盖过第 CHK 行：立着的东西，不是花纹
        ct = $cos(tilt);                                      // 地面角度：列偏移 × cos(倾角) / F
        for (k = 0; k < 16; k = k + 1) SEC_DEG[k] = rnd($atan(((10.0 * k + 4.5) * 12.0 + 5.5 - 959.5) * ct / F) * 180.0 / PI);
        for (b = 0; b < 16; b = b + 1) HEAD_DEG[b] = rnd($atan((120.0 * b - 960.0) * ct / F) * 180.0 / PI);
        for (b = 0; b < 16; b = b + 1)
            for (j = 0; j < 16; j = j + 1) begin
                if (j == b - 1 || j == b) THR[b * 16 + j] = 255;
                else begin
                    e = (j >= b) ? j : j + 1;                     // 扇区 j 靠近方向 b 的那条边
                    g = $atan((120.0 * e - 960.0) * ct / F) - $atan((120.0 * b - 960.0) * ct / F);
                    if (g < 0) g = -g;
                    t = $rtoi(15.0 / $sin(g));
                    THR[b * 16 + j] = (t > 255) ? 255 : t;
                end
            end
    end
endtask

// 几何表逐项核对（编进来的是哪张就核对哪张：15° 测试表 / 车上的表）：每一行的距离、16 个扇区角、15 个方向角、全部车宽门限
reg  [6:0] lr = 0;
reg  [3:0] ls = 0, lh = 0, ltb = 0, ltj = 0;
wire [7:0] l_dist, l_thr;
wire signed [6:0] l_sdeg, l_hdeg;
mc_obs_lut u_lutchk (.I_row(lr), .O_dist(l_dist), .I_sec(ls), .O_sec_deg(l_sdeg), .I_head(lh), .O_head_deg(l_hdeg), .I_tb(ltb), .I_tj(ltj), .O_thr(l_thr));
task check_lut;
    integer r, k, b, j, nb;
    begin
        nb = 0;
        for (r = 0; r < 90; r = r + 1) begin lr = r; #1; if (l_dist !== LUT_D[r]) begin if (nb < 4) $display("FAIL geometry table: row %0d distance %0d, expected %0d", r, l_dist, LUT_D[r]); nb = nb + 1; end end
        for (k = 0; k < 16; k = k + 1) begin ls = k; #1; if (l_sdeg !== SEC_DEG[k]) begin if (nb < 4) $display("FAIL geometry table: sector %0d angle %0d, expected %0d", k, l_sdeg, SEC_DEG[k]); nb = nb + 1; end end
        for (b = 1; b < 16; b = b + 1) begin lh = b; #1; if (l_hdeg !== HEAD_DEG[b]) begin if (nb < 4) $display("FAIL geometry table: heading %0d angle %0d, expected %0d", b, l_hdeg, HEAD_DEG[b]); nb = nb + 1; end end
        for (b = 1; b < 16; b = b + 1)
            for (j = 0; j < 16; j = j + 1) begin
                ltb = b; ltj = j; #1;
                if (l_thr !== THR[b * 16 + j]) begin if (nb < 4) $display("FAIL geometry table: threshold (heading %0d, sector %0d) %0d, expected %0d", b, j, l_thr, THR[b * 16 + j]); nb = nb + 1; end
            end
        if (nb != 0) errors = errors + 1;
    end
endtask

// ---------------- 场景 ----------------
// 边界场景的颜色：{R,G,B}，注释是 (Cb 格, Cr 格) / 亮度格（Y = (R+2G+B)/4，格 = Y/16）
localparam [23:0] C_X  = {8'd100, 8'd132, 8'd148},  // (10,4) / 8：色度只有它自己（地面在 (3~5, 9~12) / 7~8）
                  C_Z  = {8'd238, 8'd217, 8'd188},  // 地面色度 / 13：亮度只有它自己
                  C_W  = {8'd119, 8'd98,  8'd69},   // 地面色度 / 6（亮度格错用 Y[6:3] 时是 12，只剩 Z 撑着）
                  C_V  = {8'd207, 8'd186, 8'd157},  // 地面色度 / 11：只靠 2 格外的 Z（亮度邻格最后一个）
                  C_U  = {8'd251, 8'd230, 8'd201},  // 地面色度 / 14：第 13 帧起靠亮度格 15 的 K
                  C_K  = {8'd253, 8'd242, 8'd223},  // (5,9) 地面附近 / 15
                  C_R1 = {8'd36,  8'd110, 8'd0},    // (0,4) / 4
                  C_P1 = {8'd36,  8'd48,  8'd124},  // (15,4)：Cb+1 绕回 0 才会碰到 R1
                  C_R2 = {8'd66,  8'd33,  8'd124},  // (15,8)
                  C_P2 = {8'd66,  8'd95,  8'd0},    // (0,8)：Cb−1 绕回 15 才会碰到 R2
                  C_R3 = {8'd100, 8'd24,  8'd108},  // (13,12)
                  C_P3 = {8'd100, 8'd16,  8'd124},  // (15,12)，Cb 量化前正好 15：压成 14 才会碰到 R3
                  C_R4 = {8'd124, 8'd33,  8'd66},   // (8,15)
                  C_P4 = {8'd0,   8'd95,  8'd66},   // (8,0)：Cr−1 绕回 15 才会碰到 R4
                  C_R5 = {8'd28,  8'd88,  8'd52},   // (6,3)
                  C_P5 = {8'd20,  8'd92,  8'd52},   // (6,2)：只靠 Cr+1 那个邻格（R5）
                  C_L  = {8'd20,  8'd14,  8'd0},     // (6,9) / 0：亮度只有 4 格外的 R1~R5（第 4 格）撑着 = YS 是 4 时的最后一个邻格；YS 小于 4 时够不着
                  C_O  = {8'd20,  8'd20,  8'd20},   // 暗：障碍
                  C_M  = {8'd60,  8'd100, 8'd180},  // (15,1) / 6：色度谁都没教过，亮度在地面范围里（看衰减用）
                  C_T  = {8'd190, 8'd170, 8'd140},  // 地面色度 / 10：比地面（7~8）亮 2 格：远处算地面、近处算障碍
                  C_N  = {8'd170, 8'd150, 8'd120},  // 地面色度 / 9：比地面亮 1 格，近处也算地面（参考区全换成它 = 地面慢慢变亮）
                  C_Q  = {8'd30,  8'd110, 8'd70};   // (6,1) / 5：色度谁都没教过，亮度远处算地面、近处不算（花纹和墙用）
function [24:0] special;                // {有, 颜色}
    input integer f, r, c;
    begin
        special = 25'd0;
        if (f >= 9 && f <= 14) begin
            if (r >= 40 && r <= 45) begin                                    // 测试块 6×6（参考区外）
                if (c >= 4   && c <= 9)   special = {1'b1, C_X};
                if (c >= 14  && c <= 19)  special = {1'b1, C_Z};
                if (c >= 24  && c <= 29)  special = {1'b1, C_W};
                if (c >= 34  && c <= 39)  special = {1'b1, C_P1};
                if (c >= 44  && c <= 49)  special = {1'b1, C_P2};
                if (c >= 54  && c <= 59)  special = {1'b1, C_P3};
                if (c >= 64  && c <= 69)  special = {1'b1, C_P4};
                if (c >= 74  && c <= 79)  special = {1'b1, C_P5};
                if (c >= 84  && c <= 89)  special = {1'b1, C_V};
                if (c >= 94  && c <= 99)  special = {1'b1, C_U};
                if (c >= 104 && c <= 109) special = {1'b1, C_K};
                if (c >= 114 && c <= 119) special = {1'b1, C_L};
            end
            // 左边界：(61,0) 的 3×3（左邻复制自己）正好 5 个障碍；左邻错拿第 1 列只有 4 个
            if (((r == 60 || r == 61) && c == 0) || (r == 62 && c == 1)) special = {1'b1, C_O};
            // 下边界：(89,141) 的 3×3（下邻复制自己）只有 2 个障碍；下邻错拿第 86 行就有 5 个
            if ((r == 86 && c >= 139 && c <= 145) || (r == 88 && (c == 140 || c == 141))) special = {1'b1, C_O};
            // 右下角：(89,159) 的 3×3 不算它自己有 4 个障碍，它自己占 4 份
            if ((r == 88 && c == 159) || (r == 89 && c == 158)) special = {1'b1, C_O};
        end
        if (f == 9) begin                                                    // 教模型：每种 16 个
            if ((c == 56 || c == 103) && r >= 83 && r <= 86) special = {1'b1, C_X};   // X 在参考区 4 条边上（不含角）
            if ((r == 82 || r == 89) && c >= 60 && c <= 63) special = {1'b1, C_X};
            if (c >= 70 && c <= 85) begin
                if (r == 83) special = {1'b1, C_R4};
                if (r == 84) special = {1'b1, C_R1};
                if (r == 85) special = {1'b1, C_Z};
                if (r == 86) special = {1'b1, C_R2};
                if (r == 87) special = {1'b1, C_R3};
                if (r == 88) special = {1'b1, C_R5};
            end
        end
        if (f == 13 && r == 85 && c >= 70 && c <= 85) special = {1'b1, C_K};
        if (f == 15) begin                    // 扇区 3~6 在 40 cm、扇区 9 在 103 cm：只有方向 12（+19°）不被挡
            if (r >= 50 && r <= 61 && c >= 30 && c <= 69) special = {1'b1, C_O};
            if (r >= 30 && r <= 34 && c >= 90 && c <= 99) special = {1'b1, C_O};
        end
        if (f == 16 && r >= 35 && r <= 42 && c >= 70 && c <= 89) special = {1'b1, C_O};   // 正前方（扇区 7、8）71 cm：方向 5~11 被挡，4 和 12 一样远
        if (f == 17 && r >= F17_BOT - 7 && r <= F17_BOT && !(c >= 56 && c <= 103 && r >= 82)) special = {1'b1, C_O};   // 一整面墙，下沿正好 = D_STOP（不进参考区：
                                                                                    // 车上的表这一行在参考区里，墙学成地面后面的暗障碍就判不出来了；参考区那几列旁边的扇区照样把每个方向挡在 D_STOP）
        if (f == 18) begin                    // 扇区 1 的下沿 = 扇区 2 的上沿（第 60 行）
            if (r >= 50 && r <= 60 && c >= 12 && c <= 17) special = {1'b1, C_O};
            if (r >= 60 && r <= 70 && c >= 22 && c <= 27) special = {1'b1, C_O};
        end
        if (f == 19 && r >= 80 && c == 159) special = {1'b1, C_O};            // 只有最后一列碰到最后一行
        if (f == 20) begin                    // 扇区 2 只有 2 行高的带子；扇区 7 的最高 / 最低点只在它的最后一列（79）
            if ((r == 60 || r == 61) && c >= 21 && c <= 28) special = {1'b1, C_O};
            if (r >= 55 && r <= 62 && c >= 70 && c <= 74) special = {1'b1, C_O};
            if (r >= 45 && r <= 72 && (c == 79 || c == 80)) special = {1'b1, C_O};
        end
        if (f == 21 && r >= 40 && r <= 48 && c >= 40 && c <= 49) special = {1'b1, C_O};   // 只有扇区 4，58 cm = 方向 8 的车宽门限（正好算挡住）
        if (f == 22) begin                    // 判断区上沿（ROW_MIN）附近：扇区 2 正好两行在里面（算）、扇区 6 跨过上沿、扇区 10 只有一行在里面（不算）、扇区 13 整块在上面
            if (r >= RM     && r <= RM + 1 && c >= 20  && c <= 29)  special = {1'b1, C_O};
            if (r >= RM - 6 && r <= RM + 3 && c >= 60  && c <= 69)  special = {1'b1, C_O};
            if (r >= RM - 8 && r <= RM     && c >= 100 && c <= 109) special = {1'b1, C_O};
            if (r >= RM - 9 && r <= RM - 2 && c >= 130 && c <= 139) special = {1'b1, C_O};
        end
        if (f == 23 && r >= 70 && r <= 84) special = {1'b1, C_O};            // 墙：下沿进了参考区 3 行（144 点），还有 240 点是地面
        if (f >= 24 && f <= 27 && r >= 40 && r <= 45 && c >= 14 && c <= 19) special = {1'b1, C_M};   // 看 M 的衰减
        if (f == 24 && r >= 70 && r <= 87) special = {1'b1, C_O};            // 参考区只剩 2 行地面 = 正好 96 点：照常更新
        if (f == 25 && ((r >= 70 && r <= 87) || (r == 88 && c == 56))) special = {1'b1, C_O};   // 差一个点：95 点 → 冻住
        if (f == 26 && r == 85 && c >= 70 && c <= 85) special = {1'b1, C_M};  // 教 M：16 个
        if (f == 28 || f == 29) begin
            if (r >= NR - 3 && r <= NR + 2 && c >= 30 && c <= 49) special = {1'b1, C_T};    // T：NR 行以上算地面，往下算障碍
        end
        if (f == 28 && r >= 72 && r <= 85 && c >= 60 && c <= 80) special = {1'b1, C_T};     // T 立在参考区里（一直连到第 CHK 行以上）：近处算障碍，不学
        if (f == 29 && r >= 82 && c >= 56 && c <= 103) special = {1'b1, C_N};              // 参考区全变亮 1 格：近处还认得（在 ±1 里）→ 学进去，T 这下也在 ±1 里了
        if (f >= 30 && f <= 33 && r >= 40 && r <= 45 && c >= 24 && c <= 29) special = {1'b1, C_Q};   // 看 Q 认不认得
        if (f == 30 && r >= CHK && r <= 84 && (c == 56 || c == 103 || (c >= 60 && c <= 69))) special = {1'b1, C_Q};     // 从第 CHK 行连到参考区：墙，不学
        if (f == 31 && r >= CHK + 1 && r <= 84 && (c == 56 || c == 103 || (c >= 60 && c <= 69))) special = {1'b1, C_Q}; // 第 CHK 行是地面：花纹，学（36 个点：两头的列各 3 个、中间 30 个）
    end
endfunction
function [7:0] cl; input integer x; cl = (x < 0) ? 8'd0 : (x > 255) ? 8'd255 : x; endfunction
function [23:0] scene;
    input integer f, r, c;
    integer n0, n1, n2, br, bg, bb;
    reg [31:0] h;
    begin
        h = (r * 7919 + c * 104729 + f * 31) * 32'd2654435761;
        n0 = h[20:17] % 13 - 6; n1 = h[24:21] % 13 - 6; n2 = h[28:25] % 13 - 6;
        br = 150; bg = 130; bb = 100;                                          // 地面
        if (r < 14) begin br = 90; bg = 95; bb = 105; end                       // 墙
        if (f == 7 && r >= F7_ROW) begin br = 40; bg = 160; bb = 200; end           // 全挡住
        if (f >= 2 && f <= 8 && f != 6 && f != 7) begin
            if (c >= 30 && c <= 49 && r >= 50 + 2 * (f - 2) && r <= 70 + 2 * (f - 2)) begin br = 40; bg = 60; bb = 170; end   // 蓝（逐帧下移）
            if (c >= 50 && c <= 57 && r >= 40 && r <= 60) begin br = 190; bg = 40; bb = 40; end                                // 红
            if (c >= 120 && c <= 139 && r >= 22 && r <= 33) begin br = 20; bg = 20; bb = 20; end                               // 暗
            if (c >= 100 && c <= 109 && (r == ROW_MIN - 1 || r == ROW_MIN)) begin br = 40; bg = 150; bb = 60; end              // 绿带
            if (c <= 6 && r >= 75 && r <= 85) begin br = 170; bg = 50; bb = 160; end                                           // 品红（左边界）
            if (c == 80 && r == 60) begin br = 40; bg = 60; bb = 170; end                                                      // 单点
        end
        if (f == 5 && r >= 84 && r <= 86 && c >= 70 && c <= 75) begin br = 200; bg = 200; bb = 40; end                       // 参考区里有东西
        scene = {cl(br + n0), cl(bg + n1), cl(bb + n2)};
        if (special(f, r, c) >> 24) scene = special(f, r, c);
    end
endfunction

// ---------------- 模型 ----------------
integer Hc [0:255], Hy [0:15], Hs [0:15], Ac [0:255], Ay [0:15];
integer m_boot = 1, m_again = 0, m_frz = 0, m_nr = 0;   // 上电全学 / 重学这一帧 / 帧计数 / 这一帧学了几个点
reg     ABOVE [0:159];                  // 第 CHK 行这一列是不是地面
reg     RAW [0:14399], FLT [0:14399];
reg [6:0] Y7 [0:14399];
integer DPREV [0:15];
integer m_has [0:15], m_top [0:15], m_bot [0:15], m_x0 [0:15], m_x1 [0:15];
integer b_v [0:15], b_top [0:15], b_bot [0:15], b_x0 [0:15], b_x1 [0:15];
integer m_f [0:15];
integer e_go_head, e_go_free, e_stop, e_near, e_near_k;
integer HF [0:15];                     // 每个方向能走多远

function integer fdiv8; input integer x; fdiv8 = (x + 1024) / 8 - 128; endfunction       // ⌊x/8⌋（x 可以是负数）
function integer q16; input integer x; integer t; begin t = fdiv8(x + 64); q16 = (t < 0) ? 0 : (t > 15) ? 15 : t; end endfunction

task model_frame;                       // 用当前模型给这一帧分类，再更新模型
    input integer f;
    integer r, c, y, cb, cr, bc, by, i, j, k, s, cnt, rr, cc, a, b, best, run_len, run_start, ltop, lbot, lhas;
    reg [23:0] p;
    integer act, mt, mb, mx0, mx1, id, wv, wcap, order, m_all, upd;
    begin
        m_all = m_boot | m_again; m_nr = 0;
        for (i = 0; i < 256; i = i + 1) Ac[i] = 0;
        for (i = 0; i < 16; i = i + 1) Ay[i] = 0;
        for (r = 0; r < 90; r = r + 1)
            for (c = 0; c < 160; c = c + 1) begin
                p = scene(f, r, c);
                y = (p[23:16] + 2 * p[15:8] + p[7:0]) / 4;
                cb = p[7:0] - y; cr = p[23:16] - y;
                bc = q16(cb) * 16 + q16(cr); by = y / 16;
                RAW[r * 160 + c] = !(Hc[bc] >= TCV && ((r >= NR) ? Hs[by] : Hy[by]) >= TCV);
                Y7[r * 160 + c] = y / 2;
                if (r == CHK) ABOVE[c] = !RAW[r * 160 + c];
                if (c >= 56 && c <= 103 && r >= 82 && r <= 89 && (m_all || !RAW[r * 160 + c] || ABOVE[c])) begin Ac[bc] = Ac[bc] + 1; Ay[by] = Ay[by] + 1; m_nr = m_nr + 1; end
            end
        // 模型更新：够 1/4 或者全学才更新
        upd = m_all || (m_nr >= REF_MIN);
        if (m_boot) begin m_frz = m_frz + 1; if (m_frz == RF) begin m_boot = 0; m_frz = 0; end end
        else if (upd) begin m_again = 0; m_frz = 0; end
        else begin m_frz = m_frz + 1; if (m_frz == RF) begin m_again = 1; m_frz = 0; end end
        if (upd) for (i = 0; i < 256; i = i + 1) begin
            s = 0;
            for (a = -1; a <= 1; a = a + 1)
                for (b = -1; b <= 1; b = b + 1)
                    if (i / 16 + a >= 0 && i / 16 + a <= 15 && i % 16 + b >= 0 && i % 16 + b <= 15) s = s + Ac[(i / 16 + a) * 16 + i % 16 + b];
            Hc[i] = Hc[i] - Hc[i] / 4 + s;
            if (Hc[i] > 4095) Hc[i] = 4095;
        end
        if (upd) for (i = 0; i < 16; i = i + 1) begin
            s = 0;
            for (a = -YS; a <= YS; a = a + 1) if (i + a >= 0 && i + a <= 15) s = s + Ay[i + a];
            Hy[i] = Hy[i] - Hy[i] / 4 + s;
            if (Hy[i] > 4095) Hy[i] = 4095;
            s = 0;
            for (a = -YSN; a <= YSN; a = a + 1) if (i + a >= 0 && i + a <= 15) s = s + Ay[i + a];
            Hs[i] = Hs[i] - Hs[i] / 4 + s;
            if (Hs[i] > 4095) Hs[i] = 4095;
        end
        // 去噪
        for (r = 0; r < 90; r = r + 1)
            for (c = 0; c < 160; c = c + 1) begin
                cnt = 0;
                for (a = -1; a <= 1; a = a + 1)
                    for (b = -1; b <= 1; b = b + 1) begin
                        rr = (r + a < 0) ? 0 : (r + a > 89) ? 89 : r + a;
                        cc = (c + b < 0) ? 0 : (c + b > 159) ? 159 : c + b;
                        cnt = cnt + RAW[rr * 160 + cc];
                    end
                FLT[r * 160 + c] = (cnt >= 5);
            end
        // 列扫描 → 扇区
        for (k = 0; k < 16; k = k + 1) begin m_has[k] = 0; m_top[k] = 127; m_bot[k] = 0; m_x0[k] = 0; m_x1[k] = 0; end
        for (c = 0; c < 160; c = c + 1) begin
            lhas = 0; ltop = 0; lbot = 0; run_len = 0; run_start = 0;
            for (r = ROW_MIN; r < 90; r = r + 1) begin
                if (FLT[r * 160 + c]) begin
                    if (run_len == 0) run_start = r;
                    run_len = run_len + 1;
                    if (run_len >= 2) begin lhas = 1; ltop = run_start; lbot = r; end
                end else run_len = 0;
            end
            k = c / 10;
            if (lhas) begin
                if (!m_has[k]) m_x0[k] = c;
                m_x1[k] = c;
                if (ltop < m_top[k]) m_top[k] = ltop;
                if (lbot > m_bot[k]) m_bot[k] = lbot;
                m_has[k] = 1;
            end
        end
        // 合框
        act = 0; id = 0;
        for (k = 0; k < 16; k = k + 1) b_v[k] = 0;
        for (k = 0; k <= 16; k = k + 1) begin
            if (k < 16 && m_has[k] && act && m_top[k] <= mb && mt <= m_bot[k]) begin
                if (m_top[k] < mt) mt = m_top[k];
                if (m_bot[k] > mb) mb = m_bot[k];
                mx1 = m_x1[k];
                b_v[k] = id + 1;                                        // 暂存框号 + 1
            end else begin
                if (act) for (j = 0; j < 16; j = j + 1) if (b_v[j] == id + 1) begin b_top[j] = mt; b_bot[j] = mb; b_x0[j] = mx0; b_x1[j] = mx1; end
                if (k < 16 && m_has[k]) begin
                    if (act) id = id + 1;
                    act = 1; mt = m_top[k]; mb = m_bot[k]; mx0 = m_x0[k]; mx1 = m_x1[k];
                    b_v[k] = id + 1;
                end else begin
                    if (act) id = id + 1;
                    act = 0;
                end
            end
        end
        // 距离、两帧取小
        for (k = 0; k < 16; k = k + 1) begin
            a = m_has[k] ? LUT_D[m_bot[k]] : 255;
            m_f[k] = (a < DPREV[k]) ? a : DPREV[k];
            DPREV[k] = a;
        end
        // 选方向
        e_go_free = 0; e_go_head = 8;
        for (order = 0; order < 9; order = order + 1) begin
            s = (order % 2 == 0) ? 8 + order / 2 : 8 - (order + 1) / 2;
            wv = 255;
            for (j = 0; j < 16; j = j + 1) if (m_f[j] <= THR[s * 16 + j] && m_f[j] < wv) wv = m_f[j];
            HF[s] = wv;
            wcap = (wv > 150) ? 150 : wv;
            if (wcap > e_go_free) begin e_go_free = wcap; e_go_head = s; end
        end
        e_stop = (e_go_free < DSTOP);
        e_near = 255; e_near_k = 0;
        for (k = 0; k < 16; k = k + 1) if (m_f[k] < e_near) begin e_near = m_f[k]; e_near_k = k; end
    end
endtask

// ---------------- 写总线镜像（显示端的两块缓冲）----------------
reg [7:0] IMG [0:1][0:14399];
reg [7:0] BOX [0:1][0:63];
integer   nw_img = 0, nw_box = 0, bad_bank = 0;
integer   ndone = 0;
always @(posedge clk) if (done) ndone = ndone + 1;
// 时序前提（测试台自己守住）：模型更新时不来点；扫描在收结果的时候不收新点
integer   n_late_class = 0, n_late_scan = 0;
always @(posedge clk) if (v && dut.u_class.O_busy) n_late_class = n_late_class + 1;
always @(posedge clk) if (dut.S_m_v && dut.u_scan.S_st !== 3'd1) n_late_scan = n_late_scan + 1;
always @(posedge clk) begin
    if (wbus[24]) begin
        if (wbus[23] === disp_bank) bad_bank = bad_bank + 1;
        if (!wbus[22]) begin IMG[wbus[23]][wbus[21:8]] = wbus[7:0]; nw_img = nw_img + 1; end
        else            begin BOX[wbus[23]][wbus[13:8]] = wbus[7:0]; nw_box = nw_box + 1; end
    end
end

// ---------------- 送一帧 ----------------
task send_frame;
    input integer f;
    integer r, c;
    begin
        repeat (6000) @(posedge clk);                             // 硬件上：上一帧末尾 + 消隐 + 新一帧前 12 行（约 1 万拍）
        for (r = 0; r < 90; r = r + 1) begin
            for (c = 0; c < 160; c = c + 1) begin
                @(posedge clk); v <= 1'b1; row <= r; col <= c; rgb <= scene(f, r, c);
                @(posedge clk); v <= 1'b0; rgb <= {$random} % 24'hFFFFFF;
                @(posedge clk);
            end
            repeat (1500) @(posedge clk);
        end
    end
endtask

task check_frame;
    input integer f, expect_pub;          // expect_pub：这一帧应该送显示
    integer k, r, c, nbad, pb, nimg0, nbox0, t, nd0;
    reg old_pub, old_tog;
    begin
        nimg0 = nw_img; nbox0 = nw_box; old_pub = pub_bank; nd0 = ndone; old_tog = res_tog;
        send_frame(f);
        t = 0;
        while (ndone == nd0 && t < 20000) begin @(posedge clk); t = t + 1; end
        if (ndone != nd0 + 1) begin $display("FAIL frame %0d: no O_done", f); errors = errors + 1; end
        model_frame(f);
        repeat (5) @(posedge clk);
        // 方向 / 距离
        for (k = 0; k < 16; k = k + 1)
            if (sec_dist[8*k +: 8] !== m_f[k]) begin $display("FAIL frame %0d sector %0d distance %0d, expected %0d", f, k, sec_dist[8*k +: 8], m_f[k]); errors = errors + 1; end
        for (k = 4; k <= 12; k = k + 1)
            if (head_free[8*(k-4) +: 8] !== HF[k]) begin $display("FAIL frame %0d heading %0d free %0d, expected %0d", f, k, head_free[8*(k-4) +: 8], HF[k]); errors = errors + 1; end
        if (res_tog === old_tog) begin $display("FAIL frame %0d: result toggle did not flip", f); errors = errors + 1; end
        if (go_head !== e_go_head || go_free !== e_go_free || stop !== e_stop || go_deg !== HEAD_DEG[e_go_head]) begin
            $display("FAIL frame %0d plan: heading %0d free %0d stop %b deg %0d, expected %0d %0d %0d %0d", f, go_head, go_free, stop, go_deg, e_go_head, e_go_free, e_stop, HEAD_DEG[e_go_head]);
            errors = errors + 1;
        end
        if (near_cm !== e_near || near_deg !== ((e_near == 255) ? 0 : SEC_DEG[e_near_k])) begin
            $display("FAIL frame %0d nearest: %0d cm %0d deg, expected %0d %0d", f, near_cm, near_deg, e_near, (e_near == 255) ? 0 : SEC_DEG[e_near_k]);
            errors = errors + 1;
        end
        // 送显示
        $display("frame %0d: go heading %0d (%0d deg) free %0d stop %0d near %0d cm (%0d deg)", f, go_head, go_deg, go_free, stop, near_cm, near_deg);
        if (expect_pub) begin
            if (pub_bank === old_pub || pub_valid !== 1'b1) begin $display("FAIL frame %0d: not published", f); errors = errors + 1; end
            if (nw_img - nimg0 != 14400 || nw_box - nbox0 != 64) begin $display("FAIL frame %0d: %0d image / %0d box writes", f, nw_img - nimg0, nw_box - nbox0); errors = errors + 1; end
            pb = pub_bank;
            nbad = 0;
            for (r = 0; r < 90; r = r + 1)
                for (c = 0; c < 160; c = c + 1)
                    if (IMG[pb][r * 160 + c] !== {Y7[r * 160 + c], FLT[r * 160 + c]}) begin
                        if (nbad < 4) $display("FAIL frame %0d view (%0d,%0d) = %h, expected %h", f, c, r, IMG[pb][r * 160 + c], {Y7[r * 160 + c], FLT[r * 160 + c]});
                        nbad = nbad + 1;
                    end
            for (k = 0; k < 16; k = k + 1) begin
                if (BOX[pb][4*k][7] !== (b_v[k] != 0)) begin $display("FAIL frame %0d box %0d valid %b, expected %0d", f, k, BOX[pb][4*k][7], b_v[k] != 0); nbad = nbad + 1; end
                else if (b_v[k] != 0 && (BOX[pb][4*k][6:0] !== b_top[k] || BOX[pb][4*k+1] !== b_bot[k] || BOX[pb][4*k+2] !== b_x0[k] || BOX[pb][4*k+3] !== b_x1[k])) begin
                    $display("FAIL frame %0d box %0d = %0d %0d %0d %0d, expected %0d %0d %0d %0d", f, k, BOX[pb][4*k][6:0], BOX[pb][4*k+1], BOX[pb][4*k+2], BOX[pb][4*k+3], b_top[k], b_bot[k], b_x0[k], b_x1[k]);
                    nbad = nbad + 1;
                end
            end
            if (go !== {1'b1, e_stop[0], e_go_head[3:0]}) begin $display("FAIL frame %0d O_go %b", f, go); nbad = nbad + 1; end
            if (nbad != 0) errors = errors + 1;
        end else begin
            if (pub_bank !== old_pub) begin $display("FAIL frame %0d: published although the display had not caught up", f); errors = errors + 1; end
            if (nw_img != nimg0 || nw_box != nbox0) begin $display("FAIL frame %0d: %0d writes although the display had not caught up", f, nw_img - nimg0 + nw_box - nbox0); errors = errors + 1; end
        end
    end
endtask

integer i, nbox_seen;
task want;                               // 场景检查：模型的分类（raw = 0 地面 / 1 障碍，flt = 去噪后）
    input integer f, r, c, flt, e;
    input [8*24:1] what;
    if ((flt ? FLT[r * 160 + c] : RAW[r * 160 + c]) != e) begin
        $display("FAIL scene setup: frame %0d %0s should be %0s", f, what, e ? "obstacle" : "ground"); errors = errors + 1;
    end
endtask
task want_frame;                         // 第 9~14 帧都应该成立的
    input integer f;
    begin
        want(f, 42, 26, 0, 0, "W"); want(f, 42, 36, 0, 1, "P1"); want(f, 42, 46, 0, 1, "P2"); want(f, 42, 56, 0, 1, "P3"); want(f, 42, 66, 0, 1, "P4");
        want(f, 61, 0, 1, 1, "left edge (61,0)"); want(f, 89, 141, 1, 0, "bottom edge (89,141)"); want(f, 89, 159, 1, 0, "corner (89,159)");
    end
endtask
initial begin
    init_geom;
    check_lut;
    for (i = 0; i < 256; i = i + 1) Hc[i] = 0;
    for (i = 0; i < 16; i = i + 1) begin Hy[i] = 0; Hs[i] = 0; DPREV[i] = 255; end
    repeat (5) @(posedge clk);
    rst_n = 1;
    repeat (400) @(posedge clk);                                   // 上电清表
    if (pub_valid !== 1'b0) begin $display("FAIL published before any frame"); errors = errors + 1; end

    check_frame(1, 1); disp_bank = pub_bank;                     // 第 1 帧：模型是空的 → 全是障碍
    check_frame(2, 1); disp_bank = pub_bank;
    nbox_seen = 0; for (i = 0; i < 16; i = i + 1) nbox_seen = nbox_seen + (b_v[i] != 0);
    if (RM == 29 && nbox_seen < 5) begin $display("FAIL scene setup: only %0d sectors boxed in frame 2", nbox_seen); errors = errors + 1; end
    if (RM == 29 && !(b_v[3] != 0 && b_v[3] == b_v[5])) begin $display("FAIL scene setup: blue and red should merge into one box"); errors = errors + 1; end
    if (m_has[10]) begin $display("FAIL scene setup: the 2-row green band should not count"); errors = errors + 1; end
    check_frame(3, 1);                                           // 显示端不跟
    check_frame(4, 0); disp_bank = pub_bank;                     // → 这一帧不送显示
    check_frame(5, 1); disp_bank = pub_bank;
    check_frame(6, 1); disp_bank = pub_bank;
    check_frame(6, 1); disp_bank = pub_bank;                     // 两帧都没有障碍（两帧取小以后才算没有）
    if (e_stop || e_go_head != 8 || e_near != 255) begin $display("FAIL scene setup: frame 6 should be clear straight ahead"); errors = errors + 1; end
    check_frame(7, 1); disp_bank = pub_bank;                     // 参考区全挡：冻住 1 帧（第 7 帧的颜色不学）
    if (!e_stop) begin $display("FAIL scene setup: frame 7 should stop"); errors = errors + 1; end
    if (m_again || m_frz != 1) begin $display("FAIL scene setup: frame 7 should freeze the model"); errors = errors + 1; end
    check_frame(8, 1); disp_bank = pub_bank;                     // 能认出：重新数
    if (m_frz != 0) begin $display("FAIL scene setup: frame 8 should restart the freeze count"); errors = errors + 1; end
    check_frame(7, 1); disp_bank = pub_bank;
    if (m_again) begin $display("FAIL scene setup: one frozen frame after frame 8 should not relearn"); errors = errors + 1; end
    check_frame(7, 1); disp_bank = pub_bank;                     // 连续 2 帧：下一帧全学
    if (!m_again) begin $display("FAIL scene setup: two frozen frames should relearn"); errors = errors + 1; end
    // 边界场景：第 9 帧教（全学），之后 16 → 12 → 9
    check_frame(9, 1);  disp_bank = pub_bank; want_frame(9);
    want(9, 42, 6, 0, 1, "X (not in the model)");
    if (TCV == 12) begin
    check_frame(10, 1); disp_bank = pub_bank; want_frame(10);
    want(10, 42, 6, 0, 0, "X (16)"); want(10, 42, 16, 0, 0, "Z (16)"); want(10, 42, 76, 0, 0, "P5 (16)"); want(10, 42, 86, 0, 0, "V"); want(10, 42, 106, 0, 0, "K (16)");
    want(10, 42, 116, 0, (YS >= 4) ? 0 : 1, "L (luma bin 0, only 4 bins up)");
    check_frame(11, 1); disp_bank = pub_bank; want_frame(11);
    want(11, 42, 6, 0, 0, "X (exactly 12)"); want(11, 42, 16, 0, 0, "Z (exactly 12)"); want(11, 42, 96, 0, 0, "U (exactly 12)");
    check_frame(12, 1); disp_bank = pub_bank; want_frame(12);
    want(12, 42, 6, 0, 1, "X (9)"); if (YS == 2) want(12, 42, 16, 0, 1, "Z (9)");   /* 这两条是按亮度 ±2 设计的边界，±4 时 Z / V 本来就算地面 */ want(12, 42, 76, 0, 1, "P5 (9)");
    end else begin
        check_frame(10, 1); disp_bank = pub_bank; check_frame(11, 1); disp_bank = pub_bank; check_frame(12, 1); disp_bank = pub_bank;
    end
    check_frame(7, 1); disp_bank = pub_bank; check_frame(7, 1); disp_bank = pub_bank;   // 第 13 帧要教 K：先冻住 2 帧（模型不动，衰减接着算）
    check_frame(13, 1); disp_bank = pub_bank; want_frame(13);
    if (TCV == 12) begin want(13, 42, 96, 0, 1, "U (7)"); want(13, 42, 106, 0, 1, "K (7)"); end
    check_frame(14, 1); disp_bank = pub_bank; want_frame(14);
    if (TCV == 12) begin want(14, 42, 96, 0, 0, "U (bin 15 neighbour)"); want(14, 42, 106, 0, 0, "K (22)"); if (YS == 2) want(14, 42, 86, 0, 1, "V"); end
    // 扫描 / 选方向的边界：每个场景放两帧
    check_frame(15, 1); disp_bank = pub_bank; check_frame(15, 1); disp_bank = pub_bank;
    if (RM == 29 && (e_go_head != 12 || HF[11] == 255)) begin $display("FAIL scene setup: frame 15 only heading 12 should be free"); errors = errors + 1; end
    check_frame(16, 1); disp_bank = pub_bank; check_frame(16, 1); disp_bank = pub_bank;
    if (RM == 29 && (e_go_head != 4 || HF[12] != 255 || HF[11] == 255 || HF[5] == 255)) begin $display("FAIL scene setup: frame 16 should pick heading 4 over the equally free heading 12"); errors = errors + 1; end
    check_frame(17, 1); disp_bank = pub_bank; check_frame(17, 1); disp_bank = pub_bank;
    if (RM <= F17_BOT - 1 && (e_go_free != LUT_D[F17_BOT] || e_stop || (!GEO_REAL && LUT_D[F17_BOT] != DSTOP))) begin $display("FAIL scene setup: frame 17 should be the last row not below D_STOP (exactly D_STOP on the test table), go"); errors = errors + 1; end
    check_frame(18, 1); disp_bank = pub_bank; check_frame(18, 1); disp_bank = pub_bank;
    if (RM == 29 && (m_bot[1] != 60 || m_top[2] != 60 || b_v[1] == 0 || b_v[1] != b_v[2] || b_bot[1] != 70)) begin $display("FAIL scene setup: frame 18 touching sectors should merge"); errors = errors + 1; end
    check_frame(19, 1); disp_bank = pub_bank; check_frame(19, 1); disp_bank = pub_bank;
    if (m_bot[15] != 89 || m_has[14]) begin $display("FAIL scene setup: frame 19 only column 159 should reach row 89"); errors = errors + 1; end
    check_frame(20, 1); disp_bank = pub_bank; check_frame(20, 1); disp_bank = pub_bank;
    if (RM == 29 && (!m_has[2] || m_bot[2] != 61 || m_top[7] > 47 || m_bot[7] < 70)) begin $display("FAIL scene setup: frame 20"); errors = errors + 1; end
    check_frame(21, 1); disp_bank = pub_bank; check_frame(21, 1); disp_bank = pub_bank;
    if (RM == 29 && (m_f[4] != 58 || THR[8 * 16 + 4] != 58 || HF[8] != 58 || e_go_head != 9)) begin $display("FAIL scene setup: frame 21 sector 4 should block heading 8 exactly at its threshold"); errors = errors + 1; end
    check_frame(22, 1); disp_bank = pub_bank; check_frame(22, 1); disp_bank = pub_bank;
    if (!m_has[2] || m_top[2] != RM || m_bot[2] != RM + 1 || !m_has[6] || m_top[6] != RM || m_bot[6] != RM + 3 || m_has[10] || m_has[13])
        begin $display("FAIL scene setup: frame 22 (rows around ROW_MIN = %0d)", RM); errors = errors + 1; end
    // 学习的门：墙进了参考区
    check_frame(23, 1); disp_bank = pub_bank; want(23, 75, 30, 1, 1, "wall");
    check_frame(23, 1); disp_bank = pub_bank; want(23, 75, 30, 1, 1, "wall (not learned)"); want(23, 83, 80, 1, 1, "wall in the reference (not learned)");
    check_frame(23, 1); disp_bank = pub_bank; want(23, 83, 80, 1, 1, "wall in the reference (3rd frame)");
    // 正好 1/4 能认出：照常更新（M 16 → 12 → 9）；差一个点：冻住（M 不衰减）
    check_frame(7, 1); disp_bank = pub_bank; check_frame(7, 1); disp_bank = pub_bank;   // 下一帧全学
    check_frame(26, 1); disp_bank = pub_bank;                     // 教 M：16
    if (Hc[15 * 16 + 1] != 16) begin $display("FAIL scene setup: M should be 16, is %0d", Hc[15 * 16 + 1]); errors = errors + 1; end
    check_frame(24, 1); disp_bank = pub_bank;
    if (Hc[15 * 16 + 1] != 12 || m_nr != REF_MIN) begin $display("FAIL scene setup: frame 24: M %0d, %0d reference points", Hc[15 * 16 + 1], m_nr); errors = errors + 1; end
    check_frame(25, 1); disp_bank = pub_bank;
    if (Hc[15 * 16 + 1] != 12 || m_nr != REF_MIN - 1) begin $display("FAIL scene setup: frame 25: M %0d, %0d reference points", Hc[15 * 16 + 1], m_nr); errors = errors + 1; end
    if (TCV == 12) want(25, 42, 16, 0, 0, "M (12, frozen)");
    check_frame(27, 1); disp_bank = pub_bank;
    if (TCV == 12) want(27, 42, 16, 0, 0, "M (exactly 12)");
    if (Hc[15 * 16 + 1] != 9) begin $display("FAIL scene setup: frame 27: M %0d", Hc[15 * 16 + 1]); errors = errors + 1; end
    check_frame(27, 1); disp_bank = pub_bank;
    want(27, 42, 16, 0, 1, "M (9)");
    // 近处 / 远处的亮度门限；近处算障碍的颜色不学；地面慢慢变亮跟得上
    check_frame(27, 1); disp_bank = pub_bank;                     // 第 26~27 帧的衰减走完，地面回到正常
    check_frame(28, 1); disp_bank = pub_bank;
    want(28, NR - 1, 35, 0, 0, "T far (ground)"); want(28, NR, 35, 0, (YSN == 1) ? 1 : 0, "T near (obstacle)");
    check_frame(28, 1); disp_bank = pub_bank;
    want(28, NR, 35, 0, (YSN == 1) ? 1 : 0, "T near (not learned)");
    check_frame(29, 1); disp_bank = pub_bank;                     // 参考区全部亮 1 格：还认得，学进去
    check_frame(29, 1); disp_bank = pub_bank;
    want(29, NR, 35, 0, 0, "T near (floor drifted brighter)");
    // 花纹和墙：Q 从第 CHK 行连到参考区 = 墙，不学；第 CHK 行是地面 = 花纹，学
    check_frame(27, 1); disp_bank = pub_bank; check_frame(27, 1); disp_bank = pub_bank;   // 地面回到正常
    check_frame(30, 1); disp_bank = pub_bank; want(30, 42, 26, 0, 1, "Q (never seen)");
    check_frame(30, 1); disp_bank = pub_bank; want(30, 42, 26, 0, 1, "Q (wall, not learned)");
    if (Hc[6 * 16 + 1] != 0) begin $display("FAIL scene setup: Q should not be in the model, %0d", Hc[6 * 16 + 1]); errors = errors + 1; end
    check_frame(31, 1); disp_bank = pub_bank; want(31, 42, 26, 0, 1, "Q (first frame in the reference)");
    if (Hc[6 * 16 + 1] != 36) begin $display("FAIL scene setup: Q (flat pattern, both edge columns too) should be 36, is %0d", Hc[6 * 16 + 1]); errors = errors + 1; end
    check_frame(32, 1); disp_bank = pub_bank; want(32, 42, 26, 0, 0, "Q (learned)");
    // Q 不在参考区：一直衰减到门限以下，再进参考区也能学回来
    for (i = 0; i < 16 && Hc[6 * 16 + 1] >= TCV; i = i + 1) begin check_frame(32, 1); disp_bank = pub_bank; end
    check_frame(32, 1); disp_bank = pub_bank; want(32, 42, 26, 0, 1, "Q (decayed below the threshold)");
    check_frame(31, 1); disp_bank = pub_bank;
    check_frame(33, 1); disp_bank = pub_bank; want(33, 42, 26, 0, 0, "Q (learned back)");
    if (n_late_class != 0 || n_late_scan != 0) begin $display("FAIL testbench timing: %0d points during the model update, %0d while the scan was busy", n_late_class, n_late_scan); errors = errors + 1; end
    if (bad_bank != 0) begin $display("FAIL %0d writes went to the bank being displayed", bad_bank); errors = errors + 1; end

    if (errors == 0) begin
        if (GEO_REAL) $display("PASS  tb_obs_core (YSPREAD %0d, ROW_MIN %0d, D_STOP %0d, car geometry)", YS, RM, DSTOP);
        else          $display("PASS  tb_obs_core (YSPREAD %0d, ROW_MIN %0d, D_STOP %0d, 15-degree test geometry)", YS, RM, DSTOP);
    end
    else             $display("FAIL  tb_obs_core: %0d error(s)", errors);
    $finish;
end

initial begin #200_000_000; $display("FAIL  tb_obs_core: timeout"); $finish; end

endmodule
