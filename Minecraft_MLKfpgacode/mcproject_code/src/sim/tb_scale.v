`timescale 1ns / 1ps
// 测试 mc_scale（等比缩小 2.4 倍 + 打包成 128 位字）。
//   期望值按规格直接算二维加权和（不是 RTL 的"先横向和、再按行相位往 RAM 累加器里加"）：
//     输出 (j, k) 的通道 ch = ( Σ_i Σ_m  w[j%5][i] × w[k%5][m] × 输入(12·(j/5)+i, 12·(k/5)+m, ch) + 128 ) >> 8，
//     w[0] = {7,7,2,0…}、w[1] = {0,0,4,7,5,…}、w[2] = {…,1,7,7,1,…}、w[3] = {…,5,7,4,…}、w[4] = {…,2,7,7}（12 个输入里的位置）。
//   输出字节流按"第一个字节在最高位、每像素 R G B"拆开逐像素比；每帧字数 = OUT_W×OUT_H×3/16；O_fs = I_fs 晚 1 拍。
//   输入图案：每帧不同的伪随机值，夹着整行 0 / 整行 255 / 整列 255（查饱和和舍入）。
//   实例 small：384×48 → 160×17（输出 20 行丢掉最后 3 行：第 16 行（相位 4）留、第 17 行（相位 7）丢；真实尺寸是第 447 行（相位 7）留、448（相位 9）丢），输入随机空拍；第 2 帧送到第 28 行的第 30 拍就来下一帧的帧开始
//              （下一帧必须完全正确：计数器、打包、累加器都要重新开始）。
//   实例 full ：真实参数 1920×1080 → 800×448，每行 480 拍连续送（和去马赛克的输出一样）。
module scale_case #(
    parameter IN_W  = 384,
    parameter IN_H  = 48,
    parameter OUT_H = 17,
    parameter GAPS  = 1,                    // 1：输入随机空拍
    parameter TRUNC = 1,                    // 1：第 2 帧送一半就截断
    parameter NF    = 3
)(
    input  wire clk,
    output reg  fin = 0,
    output reg  [31:0] err = 0
);
localparam OUT_W = IN_W * 5 / 12;
localparam WPF   = OUT_W * OUT_H * 3 / 16;  // 每帧字数

reg         rst_n = 0, fs = 0, v = 0;
reg  [95:0] d = 0;
wire        ofs, ov;
wire [127:0] od;

mc_scale #(.IN_W(IN_W), .IN_H(IN_H), .OUT_H(OUT_H)) dut (
    .I_clk(clk), .I_rst_n(rst_n), .I_fs(fs), .I_valid(v), .I_data(d),
    .O_fs(ofs), .O_valid(ov), .O_data(od)
);

integer frame = 0;                          // 正在送的帧号（1 起）
function [7:0] pix;                         // 帧 f、行 r、列 x、通道 ch 的输入值
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
function integer w;                         // 第 p 个输出相位、第 i 个输入位置的权重
    input integer p, i;
    begin
        w = 0;
        case (p)
            0: case (i) 0: w = 7; 1: w = 7; 2: w = 2; endcase
            1: case (i) 2: w = 4; 3: w = 7; 4: w = 5; endcase
            2: case (i) 4: w = 1; 5: w = 7; 6: w = 7; 7: w = 1; endcase
            3: case (i) 7: w = 5; 8: w = 7; 9: w = 4; endcase
            4: case (i) 9: w = 2; 10: w = 7; 11: w = 7; endcase
        endcase
    end
endfunction
function [7:0] expect_px;
    input integer f, j, k, ch;
    integer i, m, s;
    begin
        s = 0;
        for (i = 2 * (j % 5) + (j % 5 > 2); i <= 2 * (j % 5) + (j % 5 > 1) + 2; i = i + 1)       // 只走权重不为 0 的位置（省仿真时间）
            for (m = 2 * (k % 5) + (k % 5 > 2); m <= 2 * (k % 5) + (k % 5 > 1) + 2; m = m + 1)
                if (w(j % 5, i) != 0 && w(k % 5, m) != 0)
                    s = s + w(j % 5, i) * w(k % 5, m) * pix(f, 12 * (j / 5) + i, 12 * (k / 5) + m, ch);
        expect_px = (s + 128) >> 8;
    end
endfunction

// ---- 送帧 ----
task send_frame;
    input integer f, rows, extra;          // 送 rows 整行，再送下一行的前 extra 拍（截断用）
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
integer ofr = 0, nw = 0, nbyte, n, j, k, ch, nchk = 0, bi;
reg [7:0] pb [0:2];
reg       fs_d = 0;
always @(posedge clk) begin
    fs_d <= fs;
    if (rst_n && ofs !== fs_d) begin $display("FAIL [%0d] O_fs is not I_fs delayed by 1 (t=%0t)", IN_W, $time); err = err + 1; end
    if (ofs) begin
        if (ofr >= 1 && !(TRUNC && ofr == 2) && nw != WPF) begin
            $display("FAIL [%0d] frame %0d: %0d words, expected %0d", IN_W, ofr, nw, WPF); err = err + 1;
        end
        ofr = ofr + 1; nw = 0;
    end
    if (ov) begin
        if (!(TRUNC && ofr == 2)) begin
            for (bi = 0; bi < 16; bi = bi + 1) begin
                nbyte = nw * 16 + bi;
                pb[nbyte % 3] = od[127 - 8*bi -: 8];
                if (nbyte % 3 == 2) begin
                    n = nbyte / 3; j = n / OUT_W; k = n % OUT_W;
                    for (ch = 0; ch < 3; ch = ch + 1)
                        if (j < OUT_H && pb[ch] !== expect_px(ofr, j, k, ch)) begin
                            if (err < 10) $display("FAIL [%0d] frame %0d pixel (%0d,%0d) ch %0d = %0d, expected %0d",
                                                   IN_W, ofr, k, j, ch, pb[ch], expect_px(ofr, j, k, ch));
                            err = err + 1;
                        end
                    nchk = nchk + 1;
                end
            end
        end
        nw = nw + 1;
    end
end

integer f;
initial begin
    repeat (10) @(posedge clk);
    rst_n = 1;
    repeat (10) @(posedge clk);
    for (f = 1; f <= NF; f = f + 1)
        send_frame(f, (TRUNC && f == 2) ? IN_H / 2 + 4 : IN_H, (TRUNC && f == 2) ? 30 : 0);   // 截断在一个"输出行结束"的输入行（第 28 行，相位 4）的第 30 拍：12 行周期中间、一行中间、打包器里还有没送出的字节
    @(posedge clk) fs <= 1'b1;              // 最后一帧的结尾检查靠下一个帧开始
    @(posedge clk) fs <= 1'b0;
    repeat (10) @(posedge clk);
    if (ofr != NF + 1) begin $display("FAIL [%0d] %0d output frame starts, expected %0d", IN_W, ofr, NF + 1); err = err + 1; end
    if (nchk != (NF - TRUNC) * OUT_W * OUT_H) begin
        $display("FAIL [%0d] checked %0d pixels, expected %0d", IN_W, nchk, (NF - TRUNC) * OUT_W * OUT_H); err = err + 1;
    end
    $display("[%0d x %0d -> %0d x %0d] %0d pixels checked, %0d error(s)", IN_W, IN_H, OUT_W, OUT_H, nchk, err);
    fin = 1;
end
endmodule

module tb_scale;
reg clk = 0;
always #4 clk = ~clk;
wire f0, f1;
wire [31:0] e0, e1;
scale_case #(.IN_W(384),  .IN_H(48),   .OUT_H(17),  .GAPS(1), .TRUNC(1), .NF(3)) c_small (.clk(clk), .fin(f0), .err(e0));
scale_case #(.IN_W(1920), .IN_H(1080), .OUT_H(448), .GAPS(0), .TRUNC(0), .NF(1)) c_full  (.clk(clk), .fin(f1), .err(e1));
initial begin
    wait (f0 && f1);
    if (e0 + e1 == 0) $display("PASS  tb_scale");
    else              $display("FAIL  tb_scale: errors %0d %0d", e0, e1);
    $finish;
end
initial begin #20000000; $display("FAIL  tb_scale: timeout"); $finish; end
endmodule
