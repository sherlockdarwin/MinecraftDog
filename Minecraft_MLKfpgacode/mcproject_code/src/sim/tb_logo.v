`timescale 1ns / 1ps
// 测试 mc_osd_logo（安路 Logo 层）+ mc_logo_rom：
//   期望 = 测试台自己读 logo_480x128.hex（生成脚本写出的每个像素的颜色号，和 ROM 同一份数据）再查调色板；
//   O_hit 每个坐标都核对，O_rgb 只在框里核对（框外颜色没人用）。
//   两个实例：默认调色板、左上角 (37, 5)；另一组调色板、贴着画布原点 (0, 0)（参数真的接上、框的四条边不多不少）。
//   坐标：先逐行把 (0~521, 0~135) 扫一遍（两个框和四周都盖到），再随机跳着给 3 万个坐标（流水线不能依赖顺序）；
//   输出晚 4 拍，每拍都核对。还核对四种颜色都出现过（位图和调色板的四个口都走到）。
module tb_logo;

reg clk = 0;
always #5 clk = ~clk;

reg  [10:0] u = 0, v = 0;
wire        h0, h1;
wire [23:0] c0, c1;

mc_osd_logo #(.U0(37), .V0(5)) d0 (.I_clk(clk), .I_u(u), .I_v(v), .O_hit(h0), .O_rgb(c0));
mc_osd_logo #(.U0(0), .V0(0), .C0(24'h010203), .C1(24'h405060), .C2(24'h708090), .C3(24'hA0B0C0))
            d1 (.I_clk(clk), .I_u(u), .I_v(v), .O_hit(h1), .O_rgb(c1));

localparam W = 480, H = 128;
reg [1:0] img [0:W * H - 1];
initial $readmemh("logo_480x128.hex", img);

function [23:0] pal0; input [1:0] k; pal0 = (k == 0) ? 24'hFFFFFF : (k == 1) ? 24'h1E2D5A : (k == 2) ? 24'hDC232D : 24'h969EB6; endfunction
function [23:0] pal1; input [1:0] k; pal1 = (k == 0) ? 24'h010203 : (k == 1) ? 24'h405060 : (k == 2) ? 24'h708090 : 24'hA0B0C0; endfunction

integer errors = 0;
always @(errors) if (errors > 20) begin #1; $display("FAIL  tb_logo: too many errors"); $finish; end

// 每个下降沿给一个坐标；坐标在下一个上升沿被采样，第 4 个上升沿之后输出出来 → 第 4 个下降沿核对
integer hu [0:7], hv [0:7];
integer n = 0;                              // 已经给出的坐标个数
integer seen [0:7];                         // 两个实例各自 4 种颜色出现的次数
integer nhit0 = 0, nmiss0 = 0, nhit1 = 0, nmiss1 = 0;

task check;
    input integer cu, cv;
    reg in0, in1;
    begin
        in0 = (cu >= 37) && (cu < 37 + W) && (cv >= 5) && (cv < 5 + H);
        in1 = (cu < W) && (cv < H);
        if (h0 !== in0) begin $display("FAIL d0 (%0d,%0d): hit %b, expected %b", cu, cv, h0, in0); errors = errors + 1; end
        if (h1 !== in1) begin $display("FAIL d1 (%0d,%0d): hit %b, expected %b", cu, cv, h1, in1); errors = errors + 1; end
        if (in0) begin
            nhit0 = nhit0 + 1; seen[img[(cv - 5) * W + (cu - 37)]] = seen[img[(cv - 5) * W + (cu - 37)]] + 1;
            if (c0 !== pal0(img[(cv - 5) * W + (cu - 37)])) begin
                $display("FAIL d0 (%0d,%0d): rgb %h, expected %h", cu, cv, c0, pal0(img[(cv - 5) * W + (cu - 37)])); errors = errors + 1;
            end
        end else nmiss0 = nmiss0 + 1;
        if (in1) begin
            nhit1 = nhit1 + 1; seen[4 + img[cv * W + cu]] = seen[4 + img[cv * W + cu]] + 1;
            if (c1 !== pal1(img[cv * W + cu])) begin
                $display("FAIL d1 (%0d,%0d): rgb %h, expected %h", cu, cv, c1, pal1(img[cv * W + cu])); errors = errors + 1;
            end
        end else nmiss1 = nmiss1 + 1;
    end
endtask

task give;                                  // 下降沿给坐标，同时核对 4 个坐标以前的输出
    input integer nu, nv;
    begin
        @(negedge clk);
        if (n >= 4) check(hu[(n - 4) % 8], hv[(n - 4) % 8]);
        u = nu; v = nv; hu[n % 8] = nu; hv[n % 8] = nv; n = n + 1;
    end
endtask

integer x, y, k, seed;
initial begin
    for (k = 0; k < 8; k = k + 1) seen[k] = 0;
    seed = 7;
    for (y = 0; y < 136; y = y + 1)
        for (x = 0; x < 522; x = x + 1) give(x, y);
    for (k = 0; k < 30000; k = k + 1) give({$random(seed)} % 600, {$random(seed)} % 150);
    for (k = 0; k < 4; k = k + 1) give(1000, 1000);                     // 把最后 4 个坐标的结果也核对掉
    for (k = 0; k < 8; k = k + 1)
        if (seen[k] == 0) begin $display("FAIL scene setup: instance %0d never showed colour %0d", k / 4, k % 4); errors = errors + 1; end
    if (nhit0 == 0 || nmiss0 == 0 || nhit1 == 0 || nmiss1 == 0) begin $display("FAIL scene setup: hits/misses %0d %0d %0d %0d", nhit0, nmiss0, nhit1, nmiss1); errors = errors + 1; end
    if (errors == 0) $display("PASS  tb_logo");
    else             $display("FAIL  tb_logo: %0d error(s)", errors);
    $finish;
end

endmodule
