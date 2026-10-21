`timescale 1ns / 1ps
// 测试 mc_gamma（RAW10 查表：减黑电平 50 + sRGB 伽马；每帧平均亮度统计）。
//   1. 查表：四个像素位置各把 0~1023 全部走一遍，期望值由测试台自己按公式（实数运算）算：
//      v = max(0, x − 50) / 973；v ≤ 0.0031308 → 12.92·v，否则 1.055·v^(1/2.4) − 0.055；×255 四舍五入。
//      输出 = {查表值, 2'b00}，比输入晚 1 拍；tvalid / tuser / tlast 也正好晚 1 拍；无效拍输出 0。
//   2. 统计（STAT_SHIFT = 4，小帧好算）：每帧的和 = Σ min(查表值, 200)，帧开始时 O_mean = 和 >> 4（超过 255 取 255）、
//      O_mean_tog 翻转。场景：普通帧、含亮于 200 的像素（限幅）、上一帧最后一拍紧挨着下一帧开始（不能丢）、
//      帧中间有空拍、和超过 255×16（饱和）、空帧（只有帧开始，没有像素）。
module tb_gamma;

reg clk = 0, rst_n = 0;
always #5 clk = ~clk;

reg  [39:0] d = 0;
reg         v = 0, u = 0, l = 0;
wire [39:0] od;
wire        ov, ou, ol, otog;
wire [7:0]  omean;

mc_gamma #(.STAT_SHIFT(4)) dut (
    .I_clk(clk), .I_rst_n(rst_n),
    .I_tdata(d), .I_tvalid(v), .I_tuser(u), .I_tlast(l),
    .O_tdata(od), .O_tvalid(ov), .O_tuser(ou), .O_tlast(ol),
    .O_mean(omean), .O_mean_tog(otog)
);

integer errors = 0;
always @(errors) if (errors > 20) begin #1; $display("FAIL  tb_gamma: too many errors"); $finish; end

function integer g;                         // 期望的查表值
    input integer x;
    real vv, s;
    begin
        vv = (x - 50) / 973.0;
        if (vv < 0.0) vv = 0.0;
        if (vv <= 0.0031308) s = 12.92 * vv;
        else                 s = 1.055 * $pow(vv, 1.0 / 2.4) - 0.055;
        g = $rtoi(s * 255.0 + 0.5);
        if (g > 255) g = 255;
    end
endfunction

function integer clip200;
    input integer y;
    clip200 = (y > 200) ? 200 : y;
endfunction

// ---- 输出检查：每拍把上一拍的输入和这一拍的输出比 ----
reg  [39:0] pd = 0;
reg         pv = 0, pu = 0, pl = 0;
integer     k, nchk = 0;
always @(posedge clk) begin
    if (rst_n) begin
        if (ov !== pv || ou !== pu || ol !== pl) begin
            $display("FAIL control delay: valid/user/last = %b%b%b, expected %b%b%b (t=%0t)", ov, ou, ol, pv, pu, pl, $time);
            errors = errors + 1;
        end
        if (pv) begin
            for (k = 0; k < 4; k = k + 1)
                if (od[10*k +: 10] !== {g(pd[10*k +: 10]), 2'b00}) begin
                    $display("FAIL lut: lane %0d x=%0d -> %0d, expected %0d", k, pd[10*k +: 10], od[10*k+2 +: 8], g(pd[10*k +: 10]));
                    errors = errors + 1;
                end
            nchk = nchk + 1;
        end else if (od !== 40'd0) begin
            $display("FAIL idle beat output %h, expected 0", od);
            errors = errors + 1;
        end
    end
    pd <= d; pv <= v; pu <= u; pl <= l;
end

// ---- 统计模型 ----
integer acc = 0, exp_mean = 0, ntog = 0;
reg     last_tog = 0;
task beat;                                  // 一拍：4 个像素，可选帧开始 / 行结束
    input [9:0] x0, x1, x2, x3;
    input       fs, ls;
    begin
        if (fs) begin
            exp_mean = acc >> 4;
            if (exp_mean > 255) exp_mean = 255;
            acc = 0;
        end
        acc = acc + clip200(g(x0)) + clip200(g(x1)) + clip200(g(x2)) + clip200(g(x3));
        d <= {x3, x2, x1, x0}; v <= 1'b1; u <= fs; l <= ls;
        @(posedge clk);
        d <= {$random, $random}; v <= 1'b0; u <= 1'b0; l <= 1'b0;     // 空拍时输入给杂数：输出必须是 0
    end
endtask
task frame_start_only;                      // 空帧：只有帧开始（窗口外的帧开始在实际中不会单独出现，这里测统计的边界）
    begin
        exp_mean = acc >> 4; if (exp_mean > 255) exp_mean = 255; acc = 0;
        u <= 1'b1; @(posedge clk); u <= 1'b0;
    end
endtask
task check_mean;                            // 帧开始后 2 拍检查
    input [8*24-1:0] what;
    begin
        @(posedge clk); @(posedge clk);
        if (otog === last_tog) begin $display("FAIL %0s: O_mean_tog did not toggle", what); errors = errors + 1; end
        last_tog = otog;
        if (omean !== exp_mean) begin $display("FAIL %0s: O_mean = %0d, expected %0d", what, omean, exp_mean); errors = errors + 1; end
        ntog = ntog + 1;
    end
endtask

integer i, x;
initial begin
    repeat (5) @(posedge clk);
    rst_n = 1;
    repeat (3) @(posedge clk);
    if (omean !== 8'd0 || otog !== 1'b0) begin $display("FAIL reset values"); errors = errors + 1; end

    // 1. 查表全覆盖（一帧 1024 拍，中间每 5 拍空 1 拍）
    for (i = 0; i < 1024; i = i + 1) begin
        beat(i, (i + 256) % 1024, (i + 512) % 1024, (i + 768) % 1024, i == 0, (i % 64) == 63);
        if (i % 5 == 4) @(posedge clk);
    end
    repeat (3) @(posedge clk);
    if (otog !== 1'b1 || omean !== 8'd0) begin $display("FAIL first frame start: tog %b mean %0d", otog, omean); errors = errors + 1; end
    last_tog = otog;
    // 2. 下一帧开始：交出上面那一帧的和（含限幅：一半以上的像素亮于 200）
    beat(10'd100, 10'd60, 10'd51, 10'd1023, 1'b1, 1'b0);
    check_mean("frame of all values");
    beat(10'd200, 10'd300, 10'd0, 10'd49, 1'b0, 1'b1);
    // 3. 上一帧最后一拍紧挨着下一帧的帧开始
    beat(10'd700, 10'd700, 10'd700, 10'd700, 1'b0, 1'b0);
    beat(10'd70, 10'd80, 10'd90, 10'd95, 1'b1, 1'b0);
    check_mean("back-to-back frame start");
    // 4. 饱和：和 >> 4 > 255
    for (i = 0; i < 40; i = i + 1) beat(10'd1000, 10'd900, 10'd800, 10'd650, 1'b0, 1'b0);
    beat(10'd52, 10'd52, 10'd52, 10'd52, 1'b1, 1'b0);
    check_mean("saturated mean");
    // 4b. 限幅边界：16 个查表值 201 的像素（限幅成 200）、再 16 个 199 的（不限幅），各一帧
    for (i = 0; i < 4; i = i + 1) beat(10'd616, 10'd616, 10'd616, 10'd616, 1'b0, 1'b0);
    beat(10'd52, 10'd52, 10'd52, 10'd52, 1'b1, 1'b0);
    check_mean("clip: 201 -> 200");
    for (i = 0; i < 4; i = i + 1) beat(10'd603, 10'd603, 10'd603, 10'd603, 1'b0, 1'b0);
    beat(10'd52, 10'd52, 10'd52, 10'd52, 1'b1, 1'b0);
    check_mean("clip: 199 kept");
    // 5. 一个小帧，然后空帧
    for (i = 0; i < 7; i = i + 1) beat(i * 37, i * 61, i * 11 + 50, i * 90, 1'b0, 1'b0);
    repeat (4) @(posedge clk);
    frame_start_only;
    check_mean("small frame");
    repeat (3) @(posedge clk);
    frame_start_only;
    check_mean("empty frame");

    repeat (5) @(posedge clk);
    if (nchk < 1024 + 50) begin $display("FAIL only %0d beats checked", nchk); errors = errors + 1; end
    if (errors == 0) $display("PASS  tb_gamma (%0d beats, %0d frame means)", nchk, ntog);
    else             $display("FAIL  tb_gamma: %0d error(s)", errors);
    $finish;
end

initial begin #2000000; $display("FAIL  tb_gamma: timeout"); $finish; end

endmodule
