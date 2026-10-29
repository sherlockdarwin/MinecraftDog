`timescale 1ns / 1ps
// 测试 mc_mixer（屏幕画面合成：相机窗口 / 状态方块 / 文字层 / 安路 Logo / 没有相机）。
//   用缩小的版面跑（面板 104×168，相机窗口 104×56，8 个 10×10 的状态方块，文字框 11 列 × 2 行、8×16 字符），
//   整个逻辑是参数化的，缩小以后一帧只有约 2 万个时钟。整帧扫描，逐像素和测试台里按"版面规则"算出来的期望值核对：
//     期望 = 文字框内：前景 / 背景色（字形用另一个 mc_osd_text 实例当参考，直接喂画布坐标）；
//            否则相机窗口内（需要相机帧在到来）：相机像素（读 I_rd_data）；
//            否则状态方块内：绿（状态位 = 1）/ 红（= 0）；其余是背景色（黑，或测试图案）。
//   覆盖：有相机；**没有相机（I_win_en = 0）：窗口里是背景色，状态方块和文字照常**；状态位变化时方块颜色变化；
//         相机帧是否到来在帧起始处锁存：帧中途 I_win_en 变化，这一帧不变，下一帧才变；文字框底色盖住测试图案背景（BGP = 1）。
//   相机像素和读使能的对齐：读使能之后第 2 个时钟给数据（和厂商 video_out 的接口约定一样）。
//   避障画面（OBV 在面板里时）：先是还没发布（黑）；最后写入内容并发布：格子亮度按列 / 行变（判断区上沿 ROW_MIN 以上画灰、以下的地面偏绿），
//         建议方向 = 2（扇区 1、2 的分界线）：方向条盖住扇区 1、2（u 50~149）：检查这一层在画布上的位置（u、v 都不能偏一个像素）。
module tb_mixer_case #(
    parameter BGP  = 0,                      // 1：背景用测试图案（这里是蓝色），文字框的底色必须盖住它
    parameter SQV  = 58,                     // 状态方块起始行（改小可以让方块和相机窗口重叠，检查叠放的优先级）
    parameter TV   = 70,                     // 文字框起始行（改小可以让文字框盖住方块和窗口）
    parameter BGEN = 1,                      // TXT_BG_EN：0 = 文字框没有底色，只有笔画盖住下面的东西
    parameter [23:0] FG  = 24'hFFFFFF,       // 文字颜色 / 文字框底色
    parameter [23:0] BGT = 24'h000000,
    parameter [10:0] OBV = 11'd830,          // 避障画面起始行（默认在这块小面板外面；放进来时检查它的范围、优先级、对齐）
    parameter [6:0] RMN = 7'd29,           // 避障画面：这一行以上画暗灰（ROW_MIN；默认 29 = 小面板里看得见的 10 行全是灰的）
    parameter LGU = 2000,                    // 安路 Logo 左上角（默认在面板外面；放进来时它比小面板大，只露出左上一块）
    parameter LGV = 2000
)(
    output reg        fin,
    output reg [31:0] err
);

localparam PW = 104, PH = 168;
localparam IMG_W = 104, IMG_H = 56;
localparam SQ_V0 = SQV, SQ_U0 = 4, SQ_W = 10, SQ_H = 10, SQ_PITCH = 12;
localparam TU0 = 4, TV0 = TV, TCOLS = 11, TROWS = 2;
localparam BOXW = TCOLS * 8, BOXH = TROWS * 16;
localparam [23:0] BGC = (BGP != 0) ? 24'h0000FF : 24'h000000;      // 没有被任何东西盖住的像素的颜色
localparam OVL = (SQV < IMG_H) || (TV < SQV + SQ_H);                // 方块和相机窗口 / 文字框重叠的版面：下面"窗口里全是相机像素"这类只适用于不重叠版面的检查就跳过

reg clk = 0;
always #5 clk = ~clk;

reg         vsync = 0, hsync = 0, de = 0;
reg         win_en = 0;
reg  [7:0]  status = 8'hA5;
reg  [19:0] txt_bus = 0;
wire        rd_en;
wire        o_vs, o_hs, o_de;
wire [23:0] o_data;
reg  [23:0] rd_data = 0;
reg  [24:0] obs_wbus = 0;
reg         obs_pv = 0;
reg  [5:0]  obs_go = 0;

function [23:0] cam_val;
    input integer x, y;
    reg [7:0] xx, yy;
    begin
        xx = x; yy = y;
        cam_val = {1'b1, xx[6:0], 1'b0, yy[6:0], xx[3:0], yy[3:0]};
    end
endfunction

mc_mixer #(
    .PANEL_W(PW), .PANEL_H(PH), .IMG_W(IMG_W), .IMG_H(IMG_H),
    .SQ_V0(SQ_V0), .SQ_U0(SQ_U0), .SQ_W(SQ_W), .SQ_H(SQ_H), .SQ_PITCH(SQ_PITCH),
    .TXT_U0(TU0), .TXT_V0(TV0), .TXT_COLS(TCOLS), .TXT_ROWS(TROWS), .TXT_SH(0),
    .BG_PATTERN(BGP), .TXT_FG(FG), .TXT_BG(BGT), .TXT_BG_EN(BGEN), .OBS_V0(OBV), .ROW_MIN(RMN),
    .LOGO_U0(LGU), .LOGO_V0(LGV)
) dut (
    .I_clk(clk), .I_vsync(vsync), .I_hsync(hsync), .I_de(de), .I_bg_data(24'h0000FF),
    .I_win_en(win_en), .I_status(status),
    .I_txt_clk(clk), .I_txt_bus(txt_bus),
    .I_obs_wclk(clk), .I_obs_wbus(obs_wbus), .I_obs_pub_bank(1'b0), .I_obs_pub_valid(obs_pv), .I_obs_go(obs_go), .O_obs_disp_bank(),
    .O_rd_en(rd_en), .I_rd_data(rd_data),
    .O_vsync(o_vs), .O_hsync(o_hs), .O_de(o_de), .O_data(o_data)
);

// ---------------- 参考文字层（直接喂画布坐标，给出每个画布点是不是笔画）----------------
reg  [10:0] ref_x = 0, ref_y = 0;
wire        ref_hit, ref_on;
mc_osd_text #(.X0(TU0), .Y0(TV0), .COLS(TCOLS), .ROWS(TROWS), .SCALE_SH(0)) u_ref (
    .I_pclk(clk), .I_x(ref_x), .I_y(ref_y), .O_hit(ref_hit), .O_on(ref_on), .I_wclk(clk), .I_wbus(txt_bus)
);
reg ref_img [0:BOXW*BOXH-1];

task write_char;
    input integer row, col;
    input [7:0] ch;
    begin
        @(posedge clk); txt_bus <= {1'b1, row[3:0], col[6:0], ch};
        @(posedge clk); txt_bus <= 20'd0;
    end
endtask

integer ru, rv;
task fill_ref;
    begin
        for (rv = 0; rv < BOXH; rv = rv + 1)
            for (ru = 0; ru < BOXW; ru = ru + 1) begin
                @(posedge clk); ref_x <= TU0 + ru; ref_y <= TV0 + rv;
                repeat (6) @(posedge clk);
                ref_img[rv * BOXW + ru] = ref_on;
                if (!ref_hit) begin $display("FAIL reference text layer: point inside the box not hit"); err = err + 1; end
            end
    end
endtask

// ---------------- 相机像素：读使能之后第 2 个时钟给数据 ----------------
integer sx = 0, sy = 0;                      // 当前扫描的面板坐标（DE 内）
integer sx1 = 0, sy1 = 0, sx2 = 0, sy2 = 0;
always @(posedge clk) begin
    sx1 <= sx; sy1 <= sy; sx2 <= sx1; sy2 <= sy1;
    rd_data <= cam_val(sx1, sy1);            // 读使能那一拍坐标是 (sx, sy)，数据在后两拍出现
end

// ---------------- 读使能（给厂商 video_out 的读请求）：只能出现在 DE 期间；每帧的个数 = 窗口像素数（有相机帧）或 0（没有）----------------
integer rd_cnt = 0, rd_cnt_last = 0, rd_blank = 0;
always @(posedge clk) if (rd_en) begin rd_cnt = rd_cnt + 1; if (!de) rd_blank = rd_blank + 1; end

// ---------------- 扫描一帧 ----------------
localparam HB = 10;                          // 每行 DE 后面的消隐时钟数
integer win_chg_line = -1;                   // >= 0：扫到这一行开始时把 I_win_en 改成 win_chg_val（帧中途改）
reg     win_chg_val = 1'b0;
task scan_frame;
    integer line, px, k;
    begin
        rd_cnt = 0;
        // vsync 2 行 + 后沿 3 行
        for (line = 0; line < 5; line = line + 1) begin
            vsync <= (line < 2); de <= 0; hsync <= 1; repeat (4) @(posedge clk); hsync <= 0; repeat (PW + HB - 4) @(posedge clk);
        end
        vsync <= 0;
        for (line = 0; line < PH; line = line + 1) begin
            if (line == win_chg_line) win_en <= win_chg_val;
            for (px = 0; px < PW; px = px + 1) begin
                @(posedge clk); de <= 1; sx <= px; sy <= line;     // 用非阻塞赋值：另一个 always 块同一拍读 sx，不能有竞争
            end
            @(posedge clk); de <= 0; hsync <= 1;
            repeat (4) @(posedge clk); hsync <= 0;
            repeat (HB - 5) @(posedge clk);
        end
        repeat (2 * (PW + HB)) @(posedge clk);       // 前沿
        repeat (20) @(posedge clk);                  // 让流水线排空
        rd_cnt_last = rd_cnt;
    end
endtask

// ---------------- 抓输出 ----------------
reg [23:0] outpix [0:PW*PH-1];
integer ox = 0, oy = 0, n_out = 0;
reg o_vs_d = 0, o_de_d = 0;
always @(posedge clk) begin
    o_vs_d <= o_vs; o_de_d <= o_de;
    if (o_vs && !o_vs_d) begin ox = 0; oy = 0; n_out = 0; end
    if (o_de) begin
        if (ox < PW && oy < PH) outpix[oy * PW + ox] = o_data;
        ox = ox + 1; n_out = n_out + 1;
    end
    if (!o_de && o_de_d) begin ox = 0; oy = oy + 1; end
end

// ---------------- 同步信号的对齐：输出 = 输入延迟 6 个时钟（所有信号等量延迟，对屏幕没有影响，但 vsync / hsync / de 三者之间的相对位置不能变）----------------
reg [5:0] vs_sh = 0, hs_sh = 0, de_sh = 0;
reg       sync_chk = 0;
integer   sync_bad = 0;
always @(posedge clk) begin
    vs_sh <= {vs_sh[4:0], vsync}; hs_sh <= {hs_sh[4:0], hsync}; de_sh <= {de_sh[4:0], de};
    if (sync_chk && (o_vs !== vs_sh[5] || o_hs !== hs_sh[5] || o_de !== de_sh[5])) sync_bad = sync_bad + 1;
end

// ---------------- 避障画面的内容：第 0 块，格 (cx, cy) 的亮度 ----------------
function [6:0] obs_y; input integer cx, cy; obs_y = (cx * 5 + cy * 3) % 128; endfunction
task obs_publish;                           // 写面板里看得见的格子（10 行 × 21 列）+ 16 个空框，发布第 0 块、方向 2（绿条在扇区 1、2）
    integer cx, cy, a;
    begin
        for (cy = 0; cy < 10; cy = cy + 1) for (cx = 0; cx < 21; cx = cx + 1) begin
            a = cy * 160 + cx;
            @(posedge clk); obs_wbus <= {1'b1, 1'b0, 1'b0, a[13:0], obs_y(cx, cy), 1'b0};
        end
        for (a = 0; a < 64; a = a + 1) begin @(posedge clk); obs_wbus <= {1'b1, 1'b0, 1'b1, a[13:0], 8'd0}; end
        @(posedge clk); obs_wbus <= 25'd0; obs_pv <= 1'b1; obs_go <= {1'b1, 1'b0, 4'd2};
    end
endtask

// ---------------- 期望值 ----------------
reg [1:0] logo [0:480 * 128 - 1];                // 安路 Logo 位图（生成脚本写的颜色号）
initial $readmemh("logo_480x128.hex", logo);
function [23:0] logo_pal; input [1:0] k; logo_pal = (k == 0) ? 24'hFFFFFF : (k == 1) ? 24'h1E2D5A : (k == 2) ? 24'hDC232D : 24'h969EB6; endfunction
function [23:0] expect_px;
    input integer x, y;
    input         win_f;
    input [7:0]   st;
    input         obs_on;                    // 避障画面已发布内容
    integer k;
    reg txt_hit, txt_ovr, stroke, inwin, sqa, sqo;
    reg [23:0] e;
    begin
        txt_hit = (x >= TU0) && (x < TU0 + BOXW) && (y >= TV0) && (y < TV0 + BOXH);
        stroke  = txt_hit ? ref_img[(y - TV0) * BOXW + (x - TU0)] : 1'b0;
        txt_ovr = txt_hit && ((BGEN != 0) || stroke);                  // 有底色：整个文字框都盖住；没有底色：只有笔画盖住
        inwin   = win_f && (y < IMG_H);
        sqa = 0; sqo = 0;
        if (y >= SQ_V0 && y < SQ_V0 + SQ_H)
            for (k = 0; k < 8; k = k + 1)
                if (x >= SQ_U0 + k * SQ_PITCH && x < SQ_U0 + k * SQ_PITCH + SQ_W) begin sqa = 1; sqo = st[k]; end
        // 叠放优先级（从上到下）：文字层 > Logo > 相机窗口 > 避障画面（没发布：黑色）> 状态方块 > 背景
        if (txt_ovr)    e = stroke ? FG : BGT;
        else if (x >= LGU && x < LGU + 480 && y >= LGV && y < LGV + 128) e = logo_pal(logo[(y - LGV) * 480 + (x - LGU)]);
        else if (inwin) e = cam_val(x, y);
        else if ((y >= OBV - 10) && (y < OBV - 2)) e = (obs_on && x / 50 >= 1 && x / 50 <= 2) ? 24'h00FF00 : 24'h000000;
        else if ((y >= OBV) && (y < OBV + 450))    e = !obs_on ? 24'h000000 : ((y - OBV) / 5 < RMN) ? {3{1'b0, obs_y(x / 5, (y - OBV) / 5)}} :                       // 判断区以上：暗灰
                                                       {1'b0, obs_y(x / 5, (y - OBV) / 5), {1'b0, obs_y(x / 5, (y - OBV) / 5)} + 8'd96, 1'b0, obs_y(x / 5, (y - OBV) / 5)};   // 地面：偏绿
        else if (sqa)   e = sqo ? 24'h00C800 : 24'hC80000;
        else            e = BGC;
        expect_px = e;
    end
endfunction

task check_frame;
    input [8*50-1:0] name;
    input integer win_f;                     // 本帧窗口应该显示相机吗
    input [7:0]   st;
    input         obs_on;
    integer x, y, bad;
    reg [23:0] e;
    begin
        bad = 0;
        if (n_out != PW * PH) begin $display("FAIL [BG%0d %0s] output has %0d active pixels, expected %0d", BGP, name, n_out, PW * PH); err = err + 1; end
        for (y = 0; y < PH; y = y + 1)
            for (x = 0; x < PW; x = x + 1) begin
                e = expect_px(x, y, win_f != 0, st, obs_on);
                if (outpix[y * PW + x] !== e) begin
                    if (bad < 4) $display("FAIL [BG%0d %0s] pixel (%0d,%0d): got %h expected %h", BGP, name, x, y, outpix[y * PW + x], e);
                    bad = bad + 1;
                end
            end
        if (bad != 0) begin $display("FAIL [BG%0d %0s] %0d pixels differ", BGP, name, bad); err = err + 1; end
        if (rd_cnt_last != ((win_f != 0) ? IMG_H * PW : 0)) begin $display("FAIL [BG%0d %0s] %0d read-enable cycles in the frame, expected %0d", BGP, name, rd_cnt_last, (win_f != 0) ? IMG_H * PW : 0); err = err + 1; end
    end
endtask

integer cnt_cam, cnt_bg, x, y;
initial begin
    fin = 0; err = 0;
    repeat (20) @(posedge clk);
    // 文字：四个角落各放一个字，方向一错就看得出来
    write_char(0, 0, "F");
    write_char(0, 5, "I");
    write_char(1, 10, "x");
    write_char(1, 0, "Q");
    write_char(1, 5, "L");
    repeat (50) @(posedge clk);
    fill_ref;

    // ---- 1) 有相机帧 ----
    win_en = 1; status = 8'hA5;
    repeat (10) @(posedge clk);
    scan_frame;                              // 这一帧只是让混合器锁存 win_en（帧起始处锁存）
    sync_chk = 1;
    scan_frame;
    check_frame("with camera", 1, 8'hA5, 1'b0);
    // 不能只靠期望函数：窗口里至少要有大量相机像素，下面还要有方块
    cnt_cam = 0;
    for (y = 0; y < IMG_H; y = y + 1) for (x = 0; x < PW; x = x + 1) if (outpix[y * PW + x] === cam_val(x, y)) cnt_cam = cnt_cam + 1;
    if (!OVL && cnt_cam != IMG_H * PW) begin $display("FAIL [BG%0d] with camera: only %0d of %0d window pixels show the camera", BGP, cnt_cam, IMG_H * PW); err = err + 1; end

    // ---- 2) 没有相机（I_win_en = 0）：窗口里是背景色，方块和文字照常 ----
    win_en = 0;
    repeat (10) @(posedge clk);
    scan_frame;                              // 帧起始处锁存新的 win_en
    scan_frame;
    check_frame("no camera", 0, 8'hA5, 1'b0);
    cnt_bg = 0;
    for (y = 0; y < IMG_H; y = y + 1) for (x = 0; x < PW; x = x + 1) if (outpix[y * PW + x] === BGC) cnt_bg = cnt_bg + 1;
    if (!OVL && cnt_bg != IMG_H * PW) begin $display("FAIL [BG%0d] no camera: window not background-coloured (%0d of %0d)", BGP, cnt_bg, IMG_H * PW); err = err + 1; end
    // 方块和文字确实画出来了
    if (!OVL && outpix[(SQ_V0 + 5) * PW + SQ_U0 + 5] !== 24'h00C800) begin $display("FAIL [BG%0d] no camera: status square 0 should be green", BGP); err = err + 1; end
    if (!OVL && outpix[(SQ_V0 + 5) * PW + SQ_U0 + SQ_PITCH + 5] !== 24'hC80000) begin $display("FAIL [BG%0d] no camera: status square 1 should be red", BGP); err = err + 1; end

    // ---- 3) 状态位变化 ----
    status = 8'h5A;
    repeat (10) @(posedge clk);
    scan_frame;
    check_frame("status changed", 0, 8'h5A, 1'b0);

    // ---- 4) 相机回来 ----
    win_en = 1;
    repeat (10) @(posedge clk);
    scan_frame; scan_frame;
    check_frame("camera back", 1, 8'h5A, 1'b0);

    // ---- 5) 帧中途相机帧"消失"：这一帧窗口不变（帧起始处锁存），下一帧才没有 ----
    win_chg_line = IMG_H / 2; win_chg_val = 1'b0;           // 改在相机窗口的行里（0 ~ IMG_H-1），否则窗口那几行已经输出完了，等于没改
    scan_frame;
    win_chg_line = -1;
    check_frame("camera disappears mid-frame: this frame unchanged", 1, 8'h5A, 1'b0);
    scan_frame;
    check_frame("camera gone: next frame has no window", 0, 8'h5A, 1'b0);

    // ---- 6) 帧中途相机帧"出现"：这一帧没有窗口，下一帧才有 ----
    win_chg_line = IMG_H / 2; win_chg_val = 1'b1;
    scan_frame;
    win_chg_line = -1;
    check_frame("camera appears mid-frame: this frame still without window", 0, 8'h5A, 1'b0);
    scan_frame;
    check_frame("camera present: next frame has the window", 1, 8'h5A, 1'b0);

    // ---- 7) 避障画面发布内容（面板里看得见它的时候）----
    if (OBV < PH) begin
        obs_publish;
        repeat (10) @(posedge clk);
        scan_frame;                          // 帧起始处锁存发布的块
        check_frame("obstacle view published", 1, 8'h5A, 1'b1);
    end

    if (rd_blank != 0) begin $display("FAIL [BG%0d] the read enable went high outside the active video (%0d cycles)", BGP, rd_blank); err = err + 1; end
    if (sync_bad != 0) begin $display("FAIL [BG%0d] vsync / hsync / de are not the input delayed by 6 clocks (%0d mismatches)", BGP, sync_bad); err = err + 1; end
    fin = 1;
end

endmodule


module tb_mixer;
wire f0, f1, f2, f3;
wire [31:0] e0, e1, e2, e3;
tb_mixer_case #(.BGP(0)) c0 (.fin(f0), .err(e0));
tb_mixer_case #(.BGP(1), .OBV(120), .LGU(10), .LGV(100)) c1 (.fin(f1), .err(e1));   // Logo 在 v 100~167：压着文字框最后 2 行（文字在上）、避障方向条和画面（Logo 在上）      // 背景是测试图案：文字框底色盖住它、窗口没有相机时露出背景；避障画面区（v 110~117、120~167）没发布时是黑的、发布后是内容
// 版面重叠（方块起始行 50 压在相机窗口 0~55 行里、文字框 54~85 行压在方块和窗口上）+ 自定义文字颜色：检查叠放优先级、颜色参数
tb_mixer_case #(.BGP(0), .SQV(50), .TV(54), .FG(24'h123456), .BGT(24'hABCDEF), .LGU(30), .LGV(40)) c2 (.fin(f2), .err(e2));   // Logo 在 v 40~：压着相机窗口、状态方块（Logo 在上）和文字框（文字在上）
// 文字框没有底色（TXT_BG_EN = 0）：只有笔画盖住下面的东西，其余透出窗口 / 方块 / 测试图案背景
tb_mixer_case #(.BGP(1), .SQV(50), .TV(54), .BGEN(0), .FG(24'h00FFFF), .OBV(120), .RMN(4)) c3 (.fin(f3), .err(e3));   // 避障画面第 4 行起是判断区（地面偏绿）：ROW_MIN 要传到 mc_obs_view
initial begin
    wait (f0 && f1 && f2 && f3);
    if (e0 + e1 + e2 + e3 == 0) $display("PASS  tb_mixer");
    else                        $display("FAIL  tb_mixer: errors %0d %0d %0d %0d", e0, e1, e2, e3);
    $finish;
end
initial begin #2_000_000_000; $display("FAIL  tb_mixer: timeout"); $finish; end
endmodule
