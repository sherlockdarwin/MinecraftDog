`timescale 1ns / 1ps
// 测试 取窗 mc_crop + isp_top（去马赛克 + 白平衡）出来的颜色对不对（Bayer 排列 / 相位）。输出每拍 4 个像素 {R,G,B}，第一个在最高位。
//   假相机：IMX415 的滤色片排列 —— 传感器偶数行 G B G B…、奇数行 R G R G…（GBRG；
//           上板实测：按 BGGR 解出来橙色变蓝、蓝色变红、绿色不变 = 红蓝对调，对应的就是这个排列）。
//   数据格式和 raw10_unpacket_4lane 一样：一拍 4 个像素，先到的像素在 [9:0]；4 拍有效 + 1 拍空；行间有空隙。
//   像素值 = 窗口坐标 (x, y) 的线性函数：R = 10 + x，G = 90 + 3y，B = 250 − x（每个 10 位原始值的低 2 位放了干扰，
//           ISP 只用高 8 位）。双线性插值对线性函数是精确的，所以窗口内部每个像素去马赛克后的 R、G、B 都应该等于函数值；
//           再乘白平衡增益：期望 R = min(255, (函数值 × 增益) >> 16)，B 同理，G 不变。
//           增益直接读 awb 里这一帧在用的值（增益怎么算由 tb_awb 检查，这里只关心颜色有没有放对通道）。
//   取窗：和上板一样 Y0 是奇数、X0 是 4 的倍数（mctop：Y0 = 261，X0 = 141×4；这两个值由 tb_top 检查），尺寸缩小以便仿真快。
//         窗口宽度不能小于约 52 组：厂商 zhenghe 在每行结束后 50 个时钟（data_complete_delay）内读出这一行，
//         宽度 ≤ 51 组时第 2 帧起就不再出帧开始（上板是 200 组，没问题）。
//   ISP 用 isp_top 的默认 BAYER_MODE（mc_cam_if 不覆盖它），所以这里测的就是上板的设置。
//   对齐：厂商去马赛克输出比输入晚 1 行、右移 1 组 —— 输出 (x, y) = 输入 (x − 4, y − 1)，输出第 0 行和最左 4 个像素是填充，
//         窗口最后一行 / 最后一组不输出（上板也一样：画面整体下移 1 行、右移 4 像素，看不出来）。
//   检查：前 3 帧每帧输出像素数 = W×H；内部像素（输出 5 ≤ x ≤ W−2、y ≥ 2，3×3 邻域都是真实输入）的 R、G、B 和期望值完全相等；
//         其余（边缘）只统计不判。
module tb_isp;

localparam X0_GRP = 3,  W_GRP = 60, Y0 = 5, H = 24;     // 窗口：像素 12 起 240 宽，第 5 行起 24 行
localparam W      = W_GRP * 4;
localparam SW_GRP = 80, SH = 32;                         // 假传感器一行 80 组（320 像素），一帧 32 行
localparam GAP    = 150;                                 // 行间空隙（时钟）
localparam NF     = 3;                                   // 检查前 3 帧

reg clk = 0, rst_n = 0;
always #5 clk = ~clk;

reg         fs = 0, raw_valid = 0;
reg  [39:0] raw_data = 0;

wire [39:0]  c_tdata;
wire         c_tvalid, c_tuser, c_tlast;
wire [95:0]  o_tdata;
wire         o_tuser, o_tvalid;

mc_crop #(.X0_GRP(X0_GRP), .W_GRP(W_GRP), .Y0(Y0), .H(H)) u_crop (
    .I_clk(clk), .I_rst_n(rst_n),
    .I_raw_data(raw_data), .I_raw_valid(raw_valid), .I_raw_frame_start(fs),
    .O_raw_tdata(c_tdata), .O_raw_tvalid(c_tvalid), .O_raw_tuser(c_tuser), .O_raw_tlast(c_tlast)
);

isp_top #(.IMG_WIDTH(W), .IMG_HEIGHT(H)) u_isp (
    .axi4s_video_aclk(clk), .I_rst_n(rst_n),
    .I_tlast(c_tlast), .I_tuser(c_tuser), .I_tdata(c_tdata), .I_tvalid(c_tvalid), .I_tdest(10'd0),
    .O_tready(1'b1), .O_tdata(o_tdata), .O_tlast(), .O_tuser(o_tuser), .O_tvalid(o_tvalid), .I_tready()
);

// ---------------- 场景 ----------------
function integer fR; input integer x, y; fR = 10 + x;      endfunction
function integer fG; input integer x, y; fG = 90 + 3 * y;  endfunction
function integer fB; input integer x, y; fB = 250 - x;     endfunction

function [9:0] pix;                         // 传感器 (sx, sy) 的 10 位原始值
    input integer sx, sy;
    integer x, y, v;
    begin
        x = sx - X0_GRP * 4;
        y = sy - Y0;
        if (sy % 2 == 0) v = (sx % 2 == 0) ? fG(x, y) : fB(x, y);
        else             v = (sx % 2 == 0) ? fR(x, y) : fG(x, y);
        if (v < 0)   v = 0;
        if (v > 255) v = 255;
        pix = v * 4 + ((sx * 7 + sy * 3) % 4);
    end
endfunction

task send_frame;
    integer sy, g;
    begin
        @(posedge clk) fs <= 1'b1;
        @(posedge clk) fs <= 1'b0;
        repeat (60) @(posedge clk);
        for (sy = 0; sy < SH; sy = sy + 1) begin
            for (g = 0; g < SW_GRP; g = g + 1) begin
                @(posedge clk);
                raw_valid <= 1'b1;
                raw_data  <= {pix(4*g+3, sy), pix(4*g+2, sy), pix(4*g+1, sy), pix(4*g, sy)};
                if (g % 4 == 3) begin
                    @(posedge clk);
                    raw_valid <= 1'b0;
                    raw_data  <= 40'd0;
                end
            end
            @(posedge clk);
            raw_valid <= 1'b0;
            raw_data  <= 40'd0;
            repeat (GAP) @(posedge clk);
        end
    end
endtask

// ---------------- 边收边查 ----------------
integer frame = 0, nbytes = 0, k, n, x, y, er, eg, eb;
integer errors = 0, edge_bad = 0, checked = 0;
integer gain_r = 0, gain_b = 0;
reg     gain_taken = 0;
reg [7:0] pb [0:2];                         // 正在拼的像素的 3 个字节

function integer wb;                        // 白平衡后的期望值
    input integer v, g;
    integer p;
    begin
        p  = (v * g) >>> 16;
        wb = (p > 255) ? 255 : p;
    end
endfunction

always @(posedge clk) begin
    if (o_tuser) begin
        if (frame >= 1 && frame <= NF && nbytes != W * H * 3) begin
            $display("FAIL frame %0d: %0d bytes, expected %0d (W*H*3)", frame, nbytes, W * H * 3);
            errors = errors + 1;
        end
        frame      = frame + 1;
        nbytes     = 0;
        gain_taken = 0;
    end
    if (o_tvalid && frame >= 1 && frame <= NF) begin
        if (!gain_taken) begin              // 这一帧第一个输出数据时 awb 用的增益（整帧不变）
            gain_r     = u_isp.u_awb.in_r_r1;
            gain_b     = u_isp.u_awb.in_b_r1;
            gain_taken = 1;
        end
        for (k = 0; k < 12; k = k + 1) begin
            pb[(nbytes + k) % 3] = o_tdata[95 - 8*k -: 8];
            if ((nbytes + k) % 3 == 2) begin
                n = (nbytes + k) / 3;
                x = n % W;  y = n / W;
                er = wb(fR(x - 4, y - 1), gain_r);  eg = fG(x - 4, y - 1);  eb = wb(fB(x - 4, y - 1), gain_b);
                if (n >= W * H) begin
                    // 多出来的像素：帧尾的字节数检查会报
                end else if (pb[0] !== er || pb[1] !== eg || pb[2] !== eb) begin
                    if (x < 5 || x > W - 2 || y < 2)
                        edge_bad = edge_bad + 1;
                    else begin
                        if (errors < 12)
                            $display("FAIL frame %0d pixel (%0d,%0d): RGB = %0d %0d %0d, expected %0d %0d %0d (gains R %h B %h)",
                                     frame, x, y, pb[0], pb[1], pb[2], er, eg, eb, gain_r, gain_b);
                        errors = errors + 1;
                    end
                end else if (x >= 5 && x <= W - 2 && y >= 2)
                    checked = checked + 1;
            end
        end
        nbytes = nbytes + 12;
    end
end

// ---------------- 主流程 ----------------
initial begin
    repeat (400) @(posedge clk);
    rst_n = 1;
    repeat (400) @(posedge clk);
    repeat (NF + 1) send_frame;
    repeat (200) @(posedge clk);

    if (frame < NF + 1) begin
        $display("FAIL only %0d frame start(s) seen at the ISP output, expected %0d", frame, NF + 1);
        errors = errors + 1;
    end
    $display("interior pixels exact: %0d of %0d (%0d frames); edge pixels differing (not checked): %0d",
             checked, NF * (W - 6) * (H - 2), NF, edge_bad);
    if (errors == 0 && checked == NF * (W - 6) * (H - 2)) $display("PASS  tb_isp");
    else                                                  $display("FAIL  tb_isp: %0d error(s)", errors);
    $finish;
end

initial begin
    #20000000;
    $display("FAIL  tb_isp: timeout");
    $finish;
end

endmodule
