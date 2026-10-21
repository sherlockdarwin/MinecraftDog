`timescale 1ns / 1ps
// 测试 mc_obs_view（避障处理画面的显示端）。
//   像 mc_mixer 的第 1 拍寄存器一样每拍给一个画布坐标（u, v），输出晚 4 拍（这边在下一个时钟沿之前读，所以对的是 5 拍前送的坐标）；按规格独立算每个像素的期望：
//     区域：v = V0 ~ V0+449、u < 800 → 画面；v = V0−10 ~ V0−3 → 方向条；其余不归本层（O_hit = 0）。
//     画面：格 = (u/5, (v−V0)/5)，格内偏移 = 余数；扇区 = 格列 / 10。
//       红框：这个扇区有框，格在框里，并且（左列且偏移 < 2）或（右列且偏移 ≥ 3）或（上行且偏移 < 2）或（下行且偏移 ≥ 3）。
//       黄框：参考区边上 1 像素（左列偏移 0、右列偏移 4、上行偏移 0、下行偏移 4）。
//       否则：1.5 m 线（ROW_MIN）以上暗灰 (y,y,y)；障碍 (y+64, y+32, y+128)；地面 (y, y+96, y)。y = 存的 7 位亮度。
//     方向条：有效且不停时，扇区是选中方向 b 两边的那两个（b−1、b）→ 绿，否则黑。还没发布过：整块黑。
//   场景：一块缓冲写满图（亮度、障碍位按公式），框表里一个跨 3 个扇区的框、一个单列单行的框、一个压在参考区右下角的框（红盖黄）；发布后下一帧才生效；
//         帧中间换发布块、换建议方向都不影响这一帧；换块后显示另一块的内容；停的时候不画方向条。
//   I_go 跨时钟域要几拍：改了以后等 10 拍再开始下一帧（真实情况里一帧最多变一次）。
module tb_obs_view;

localparam V0 = 20;

reg clk = 0, wclk = 0;
always #7 clk = ~clk;
always #4 wclk = ~wclk;

reg  [10:0] u = 0, v = 0;
reg         vs = 0;
reg  [24:0] wbus = 0;
reg         pub = 0, pvalid = 0;
reg  [5:0]  go = 0;
wire        hit, dbank;
wire [23:0] rgb;

mc_obs_view #(.V0(V0)) dut (
    .I_clk(clk), .I_vsync(vs), .I_u(u), .I_v(v), .O_hit(hit), .O_rgb(rgb),
    .I_wclk(wclk), .I_wbus(wbus), .I_pub_bank(pub), .I_pub_valid(pvalid), .I_go(go), .O_disp_bank(dbank)
);

integer errors = 0;
always @(errors) if (errors > 20) begin #1; $display("FAIL  tb_obs_view: too many errors"); $finish; end

integer ROW_MIN;
// 每块缓冲的内容（模型）
reg [7:0] IMG [0:1][0:14399];
reg [7:0] BX [0:1][0:63];

function [7:0] cell_val;                // 第 b 块的格内容
    input integer b, r, c;
    reg [6:0] y;
    reg       o;
    begin
        y = (r * 3 + c * 5 + b * 40) % 128;
        o = ((r / 7 + c / 9 + b) % 3 == 0);
        cell_val = {y, o};
    end
endfunction

task wr;                                // 写总线写一个字节
    input integer b, sel, addr, data;
    begin
        @(posedge wclk); wbus <= {1'b1, b[0], sel[0], addr[13:0], data[7:0]};
        @(posedge wclk); wbus <= 25'd0;
    end
endtask
task setbox;
    input integer b, k, valid, top, bot, x0, x1;
    begin
        BX[b][4*k] = {valid[0], top[6:0]}; BX[b][4*k+1] = bot; BX[b][4*k+2] = x0; BX[b][4*k+3] = x1;
        wr(b, 1, 4*k, BX[b][4*k]); wr(b, 1, 4*k+1, BX[b][4*k+1]); wr(b, 1, 4*k+2, BX[b][4*k+2]); wr(b, 1, 4*k+3, BX[b][4*k+3]);
    end
endtask
task fill;
    input integer b;
    integer r, c, k;
    begin
        for (r = 0; r < 90; r = r + 1) for (c = 0; c < 160; c = c + 1) begin IMG[b][r * 160 + c] = cell_val(b, r, c); wr(b, 0, r * 160 + c, IMG[b][r * 160 + c]); end
        for (k = 0; k < 16; k = k + 1) setbox(b, k, 0, 0, 0, 0, 0);
    end
endtask

// 期望（用"显示块"bk、"有效"vd、方向 g）
function [24:0] expect_px;              // {hit, rgb}
    input integer bk, vd, uu, vv;
    input [5:0] g;
    integer cx, cy, sx, sy, sec, y7, t, bt, bb, x0, x1;
    reg [7:0] p;
    reg bv, edge_r, edge_y;
    begin
        if (uu < 800 && vv >= V0 - 10 && vv < V0 - 2) begin
            sec = (uu / 5) / 10;
            expect_px = {1'b1, (vd && g[5] && !g[4] && (sec == g[3:0] - 1 || sec == g[3:0])) ? 24'h00FF00 : 24'h000000};
        end else if (uu < 800 && vv >= V0 && vv < V0 + 450) begin
            cx = uu / 5; cy = (vv - V0) / 5; sx = uu % 5; sy = (vv - V0) % 5; sec = cx / 10;
            p = IMG[bk][cy * 160 + cx]; y7 = p[7:1];
            bv = BX[bk][4*sec][7]; bt = BX[bk][4*sec][6:0]; bb = BX[bk][4*sec+1]; x0 = BX[bk][4*sec+2]; x1 = BX[bk][4*sec+3];
            edge_r = bv && cx >= x0 && cx <= x1 && cy >= bt && cy <= bb &&
                     ((cx == x0 && sx < 2) || (cx == x1 && sx >= 3) || (cy == bt && sy < 2) || (cy == bb && sy >= 3));
            edge_y = cx >= 56 && cx <= 103 && cy >= 82 && cy <= 89 &&
                     ((cx == 56 && sx == 0) || (cx == 103 && sx == 4) || (cy == 82 && sy == 0) || (cy == 89 && sy == 4));
            if (!vd)              expect_px = {1'b1, 24'h000000};
            else if (edge_r)      expect_px = {1'b1, 24'hFF0000};
            else if (edge_y)      expect_px = {1'b1, 24'hFFDC00};
            else if (cy < ROW_MIN) expect_px = {1'b1, y7[7:0], y7[7:0], y7[7:0]};
            else if (p[0])        expect_px = {1'b1, y7[7:0] + 8'd64, y7[7:0] + 8'd32, y7[7:0] + 8'd128};
            else                  expect_px = {1'b1, y7[7:0], y7[7:0] + 8'd96, y7[7:0]};
        end else expect_px = 25'd0;
    end
endfunction

// 扫一帧：vsync 脉冲，然后 v = V0−12 ~ VMAX、u = 0 ~ 805；检查输出
reg  [10:0] pu [0:4], pv [0:4];
reg  [4:0]  pval;
integer nchk, nbad;
task frame;
    input integer bk, vd;               // 这一帧应该显示的块、有效
    input [5:0] g;
    input integer vmax;
    input integer flip_mid;             // 1：帧中间把发布块翻过来（这一帧不能受影响）
    integer x, y;
    reg [24:0] e;
    begin
        @(posedge clk) vs <= 1'b1;
        repeat (4) @(posedge clk);
        vs <= 1'b0;
        repeat (4) @(posedge clk);
        nbad = 0;
        for (y = V0 - 12; y < vmax; y = y + 1) begin
            if (flip_mid && y == V0 + 100) begin pub = ~pub; go = go ^ 6'b011111; end
            for (x = 0; x < 806; x = x + 1) begin
                @(posedge clk); u <= x; v <= y;
                // 5 拍之前送进去的坐标
                if (pval[4]) begin
                    e = expect_px(bk, vd, pu[4], pv[4], g);
                    if (hit !== e[24] || (e[24] && rgb !== e[23:0])) begin
                        if (nbad < 5) $display("FAIL (u,v)=(%0d,%0d): hit %b rgb %h, expected %b %h", pu[4], pv[4], hit, rgb, e[24], e[23:0]);
                        nbad = nbad + 1;
                    end
                    nchk = nchk + 1;
                end
                pu[4] = pu[3]; pv[4] = pv[3]; pu[3] = pu[2]; pv[3] = pv[2]; pu[2] = pu[1]; pv[2] = pv[1]; pu[1] = pu[0]; pv[1] = pv[0]; pu[0] = x; pv[0] = y;
                pval = {pval[3:0], 1'b1};
            end
        end
        if (nbad != 0) errors = errors + 1;
    end
endtask

integer k;
initial begin
    ROW_MIN = 29;
    pval = 0; nchk = 0;
    repeat (5) @(posedge clk);
    // 还没发布：整块黑
    frame(0, 0, 6'd0, V0 + 60, 0);
    // 第 1 块：图 + 框（扇区 2~4 一个框，扇区 9 一个单格框，扇区 10 一个框压住参考区右下角，扇区 15 一个框贴着右边和底边）
    fill(1);
    for (k = 2; k <= 4; k = k + 1) setbox(1, k, 1, 30, 50, 23, 47);
    setbox(1, 9, 1, 60, 60, 95, 95);
    setbox(1, 10, 1, 85, 89, 100, 109);
    setbox(1, 15, 1, 70, 89, 150, 159);
    pub = 1; pvalid = 1; go = {1'b1, 1'b0, 4'd5};
    repeat (10) @(posedge clk);
    if (dbank !== 1'b0) begin $display("FAIL display bank changed before the frame start"); errors = errors + 1; end
    frame(1, 1, {1'b1, 1'b0, 4'd5}, V0 + 452, 1);              // 中途把发布块翻成 0：这一帧还是第 1 块
    if (dbank !== 1'b1) begin $display("FAIL display bank should be 1"); errors = errors + 1; end
    // 第 0 块：另一张图、要停
    fill(0);
    setbox(0, 7, 1, 40, 80, 70, 79);
    pub = 0; go = {1'b1, 1'b1, 4'd2};
    repeat (10) @(posedge clk);
    frame(0, 1, {1'b1, 1'b1, 4'd2}, V0 + 452, 0);
    if (dbank !== 1'b0) begin $display("FAIL display bank should be 0"); errors = errors + 1; end
    $display("%0d pixels checked", nchk);
    if (errors == 0) $display("PASS  tb_obs_view");
    else             $display("FAIL  tb_obs_view: %0d error(s)", errors);
    $finish;
end

initial begin #200_000_000; $display("FAIL  tb_obs_view: timeout"); $finish; end

endmodule
