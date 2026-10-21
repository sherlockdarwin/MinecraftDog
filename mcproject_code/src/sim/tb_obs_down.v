`timescale 1ns / 1ps
// 测试 mc_obs_down（1920×1080 → 每 12×12 求平均 → 160×90）。
//   期望值直接按定义算：格 (gy, gx) 的通道 ch = floor((Σ 144 个像素 + 72) / 144)（四舍五入的整数平均）。
//   检查：每帧输出点数 = (IN_W/12)×(IN_H/12)、行列号按顺序、两个输出点之间至少隔 3 拍、每个点 R/G/B 精确相等。
//   输入图案：每帧不同的伪随机值，夹着整行 0 / 整行 255 / 整列 255（查饱和、舍入）。
//   实例 small：240×48（20×4 格），随机空拍，第 2 帧送到一半就来下一帧的帧开始（下一帧要完全正确）；
//   实例 full ：真实 1920×1080，一帧，每行 480 拍连续送。
module obs_down_case #(
    parameter IN_W = 240,
    parameter IN_H = 48,
    parameter GAPS = 1,
    parameter TRUNC = 1,
    parameter NF = 3
)(
    input  wire clk,
    output reg  fin = 0,
    output reg  [31:0] err = 0
);
localparam GW = IN_W / 12, GH = IN_H / 12;

reg         rst_n = 0, fs = 0, v = 0;
reg  [95:0] d = 0;
wire        ov;
wire [6:0]  orow;
wire [7:0]  ocol;
wire [23:0] orgb;

mc_obs_down #(.IN_W(IN_W), .IN_H(IN_H)) dut (
    .I_clk(clk), .I_rst_n(rst_n), .I_fs(fs), .I_valid(v), .I_data(d),
    .O_fs(), .O_valid(ov), .O_row(orow), .O_col(ocol), .O_rgb(orgb)
);

integer frame = 0;
function [7:0] pix;
    input integer f, r, x, ch;
    reg [31:0] h;
    begin
        if (r == 5 || r == 30)             pix = 8'd255;
        else if (r == 17)                  pix = 8'd0;
        else if (x == 13 || x == IN_W - 1) pix = 8'd255;
        else begin
            h = (r * 131 + x * 71 + ch * 29 + f * 1013) * 32'd2654435761;
            pix = h[23:16];
        end
    end
endfunction
function [7:0] expect_px;
    input integer f, gy, gx, ch;
    integer i, m, s;
    begin
        s = 0;
        for (i = 0; i < 12; i = i + 1)
            for (m = 0; m < 12; m = m + 1)
                s = s + pix(f, 12 * gy + i, 12 * gx + m, ch);
        expect_px = (s + 72) / 144;
    end
endfunction

task send_frame;
    input integer f, rows, extra;
    integer r, b, q;
    begin
        frame = f;
        @(posedge clk) fs <= 1'b1;
        @(posedge clk) fs <= 1'b0;
        repeat (60) @(posedge clk);
        for (r = 0; r < rows + (extra > 0); r = r + 1) begin
            for (b = 0; b < ((r == rows) ? extra : IN_W / 4); b = b + 1) begin
                if (GAPS) while (($random & 3) == 0) begin @(posedge clk); v <= 1'b0; d <= {3{$random}}; end
                @(posedge clk);
                v <= 1'b1;
                for (q = 0; q < 4; q = q + 1)
                    d[95 - 24*q -: 24] <= {pix(f, r, 4*b+q, 0), pix(f, r, 4*b+q, 1), pix(f, r, 4*b+q, 2)};
            end
            @(posedge clk); v <= 1'b0; d <= 96'd0;
            repeat (GAPS ? 20 : 330) @(posedge clk);
        end
        repeat (100) @(posedge clk);
    end
endtask

// ---- 收 ----
integer n = 0, nchk = 0, last_t = -100, cyc = 0, efr = 0;
always @(posedge clk) cyc <= cyc + 1;
always @(posedge clk) begin
    if (ov) begin
        if (cyc - last_t < 3) begin $display("FAIL [%0d] outputs only %0d clocks apart", IN_W, cyc - last_t); err = err + 1; end
        last_t = cyc;
        if (!(TRUNC && frame == 2)) begin
            if (orow !== n / GW || ocol !== n % GW) begin
                $display("FAIL [%0d] frame %0d output %0d: row/col %0d/%0d, expected %0d/%0d", IN_W, frame, n, orow, ocol, n / GW, n % GW);
                err = err + 1;
            end else if (orgb !== {expect_px(frame, orow, ocol, 0), expect_px(frame, orow, ocol, 1), expect_px(frame, orow, ocol, 2)}) begin
                if (err < 10) $display("FAIL [%0d] frame %0d cell (%0d,%0d) = %h, expected %h", IN_W, frame, ocol, orow, orgb,
                                       {expect_px(frame, orow, ocol, 0), expect_px(frame, orow, ocol, 1), expect_px(frame, orow, ocol, 2)});
                err = err + 1;
            end
            nchk = nchk + 1;
        end
        n = n + 1;
    end
    if (fs) begin
        if (efr >= 1 && !(TRUNC && efr == 2) && n != GW * GH) begin
            $display("FAIL [%0d] frame %0d: %0d outputs, expected %0d", IN_W, efr, n, GW * GH); err = err + 1;
        end
        efr = efr + 1; n = 0;
    end
end

integer f;
initial begin
    repeat (10) @(posedge clk);
    rst_n = 1;
    repeat (10) @(posedge clk);
    for (f = 1; f <= NF; f = f + 1)
        send_frame(f, (TRUNC && f == 2) ? 17 : IN_H, (TRUNC && f == 2) ? 25 : 0);   // 截断：第 17 行（格内第 5 行）的第 25 拍
    @(posedge clk) fs <= 1'b1;
    @(posedge clk) fs <= 1'b0;
    repeat (10) @(posedge clk);
    if (nchk != (NF - TRUNC) * GW * GH) begin $display("FAIL [%0d] checked %0d cells, expected %0d", IN_W, nchk, (NF - TRUNC) * GW * GH); err = err + 1; end
    $display("[%0d x %0d -> %0d x %0d] %0d cells checked, %0d error(s)", IN_W, IN_H, GW, GH, nchk, err);
    fin = 1;
end
endmodule

module tb_obs_down;
reg clk = 0;
always #4 clk = ~clk;
wire f0, f1;
wire [31:0] e0, e1;
obs_down_case #(.IN_W(240),  .IN_H(48),   .GAPS(1), .TRUNC(1), .NF(3)) c_small (.clk(clk), .fin(f0), .err(e0));
obs_down_case #(.IN_W(1920), .IN_H(1080), .GAPS(0), .TRUNC(0), .NF(1)) c_full  (.clk(clk), .fin(f1), .err(e1));
initial begin
    wait (f0 && f1);
    if (e0 + e1 == 0) $display("PASS  tb_obs_down");
    else              $display("FAIL  tb_obs_down: errors %0d %0d", e0, e1);
    $finish;
end
initial begin #20000000; $display("FAIL  tb_obs_down: timeout"); $finish; end
endmodule
