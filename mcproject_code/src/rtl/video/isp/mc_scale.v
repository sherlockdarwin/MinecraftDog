`timescale 1ns / 1ps
// =============================================================================
// mc_scale.v  等比缩小 2.4 倍：白平衡输出的 1920×1080 → 800×OUT_H（只缩小、不拉伸），打包成帧缓存要的 128 位字
//
//   输入：每拍 4 个像素 {R,G,B}×4（96 位，第一个像素在最高位），每行 IN_W/4 拍；I_fs = 帧开始，
//         必须比这一帧的第一拍早（awb 的帧开始比数据早约 50 拍）。
//   缩小：每 12 个输入像素合成 5 个输出像素（12 / 5 = 2.4），横向、纵向一样。权重按"输出像素覆盖了输入像素多少"
//         取近似整数，每个输出的权重和都是 16（所以横竖一共除以 256，只要移位）：
//             输出 0 = (7·p0 + 7·p1 + 2·p2) / 16          输出 3 = (5·p7 + 7·p8 + 4·p9) / 16
//             输出 1 = (4·p2 + 7·p3 + 5·p4) / 16          输出 4 = (2·p9 + 7·p10 + 7·p11) / 16
//             输出 2 = (1·p4 + 7·p5 + 7·p6 + 1·p7) / 16
//         每个输入像素的总权重是 6 或 7（几乎均匀），相当于先做一个 2.4×2.4 的平均再取样，不会出现锯齿 / 摩尔纹。
//   结构：
//     ① 横向：凑够 3 拍（12 个像素）算 5 个"横向和"（每通道 12 位，未除以 16）；
//     ② 纵向：每个输出列组（5 个像素）在 RAM 里有一个累加器（5 像素 × 3 通道 × 16 位）；输入第 r 行按行相位
//        pr = r mod 12 把"横向和 × 纵向权重"加进去，这一行是某个输出行的最后一行时：
//        输出 = (累加 + 128) >> 8（四舍五入），累加器换成下一个输出行的起始值。
//        行相位表（wa = 加进当前输出行的权重，fin = 当前输出行在这一行结束，wb = 下一个输出行的起始权重）：
//             pr   0 1 2 3 4 5 6 7 8 9 10 11
//             wa   7 7 2 7 5 7 7 1 7 4 7  7
//             fin  0 0 1 0 1 0 0 1 0 1 0  1
//             wb   - - 4 - 1 - - 5 - 2 -  0
//        pr = 0 时当作累加器是 0（上一个周期最后一行已经清零，这里再保险一次）。
//        输出行号 ≥ OUT_H 的行不输出（1080 行缩出 450 行，帧缓存要的是 448 行，最后 2 行丢掉）。
//     ③ 打包：每 5 个输出像素 = 15 字节，拼成 16 字节的字（第一个字节在最高位）。每来 15 字节最多出 1 个字，
//        每行 800 像素 = 150 个字，正好在行尾对齐。
//   约束：IN_W、IN_H 是 12 的倍数；OUT_W = IN_W×5/12 是 16 的倍数（每行整数个字）。
// =============================================================================
module mc_scale #(
    parameter IN_W  = 1920,
    parameter IN_H  = 1080,
    parameter OUT_H = 448
)(
    input  wire         I_clk,
    input  wire         I_rst_n,

    input  wire         I_fs,           // 帧开始（单拍）
    input  wire         I_valid,
    input  wire [95:0]  I_data,

    output reg          O_fs,           // 帧开始（晚 1 拍）
    output reg          O_valid,
    output reg  [127:0] O_data          // 16 字节，第一个字节在 [127:120]
);

localparam BPL = IN_W / 4;              // 每行拍数
localparam NG  = IN_W / 12;             // 每行组数（一组 = 3 拍 = 12 个输入像素 = 5 个输出像素）

// ---------------------------------------------------------------------------
// 计数：拍 / 组 / 行相位 / 输出行
// ---------------------------------------------------------------------------
reg [10:0] S_bx;                        // 行内第几拍
reg [1:0]  S_hb;                        // 组内第几拍
reg [7:0]  S_gx;                        // 行内第几组
reg [3:0]  S_pr;                        // 行相位 0~11
reg [10:0] S_jb;                        // 这 12 行对应的第一个输出行号
reg [95:0] S_r0, S_r1;                  // 组里前两拍

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        S_bx <= 11'd0; S_hb <= 2'd0; S_gx <= 8'd0; S_pr <= 4'd0; S_jb <= 11'd0;
        S_r0 <= 96'd0; S_r1 <= 96'd0;
    end else if (I_fs) begin
        S_bx <= 11'd0; S_hb <= 2'd0; S_gx <= 8'd0; S_pr <= 4'd0; S_jb <= 11'd0;
    end else if (I_valid) begin
        if (S_hb == 2'd0) S_r0 <= I_data;
        if (S_hb == 2'd1) S_r1 <= I_data;
        S_hb <= (S_hb == 2'd2) ? 2'd0 : S_hb + 2'd1;
        if (S_hb == 2'd2) S_gx <= (S_gx == NG - 1) ? 8'd0 : S_gx + 8'd1;
        if (S_bx == BPL - 1) begin
            S_bx <= 11'd0;
            S_pr <= (S_pr == 4'd11) ? 4'd0 : S_pr + 4'd1;
            if (S_pr == 4'd11) S_jb <= S_jb + 11'd5;
        end else begin
            S_bx <= S_bx + 11'd1;
        end
    end
end

// ---------------------------------------------------------------------------
// ① 横向：第 3 拍到来时算 5 个横向和（3 通道），打一拍
// ---------------------------------------------------------------------------
wire [287:0] S_px = {S_r0, S_r1, I_data};           // 12 个像素 × 24 位，p0 在最高位
function [7:0] P;                                   // 第 i 个像素的第 c 个通道（0 = R，1 = G，2 = B）
    input [287:0] px;
    input integer i, c;
    P = px[287 - 24*i - 8*c -: 8];
endfunction

wire S_grp = I_valid && !I_fs && (S_hb == 2'd2);    // 一组凑齐

// 乘小常数全部用移位相加写（写成 * 的话 TD 会用 DSP 乘法器，40 个不够用）
function [11:0] m7; input [7:0] p; m7 = {1'b0, p, 3'b0} - {4'd0, p};       endfunction
function [11:0] m5; input [7:0] p; m5 = {2'b0, p, 2'b0} + {4'd0, p};       endfunction
function [11:0] m4; input [7:0] p; m4 = {2'b0, p, 2'b0};                   endfunction
function [11:0] m2; input [7:0] p; m2 = {3'b0, p, 1'b0};                   endfunction
function [11:0] m1; input [7:0] p; m1 = {4'd0, p};                         endfunction
function [15:0] mulw;                                  // x × w（w = 0~7）
    input [11:0] x;
    input [2:0]  w;
    mulw = (w[0] ? {4'd0, x} : 16'd0) + (w[1] ? {3'd0, x, 1'b0} : 16'd0) + (w[2] ? {2'd0, x, 2'b0} : 16'd0);
endfunction

reg  [11:0] S_h [0:14];                             // [k*3 + c]：输出像素 k、通道 c 的横向和
reg         S_h_v;
reg  [7:0]  S_h_gx;
reg  [3:0]  S_h_pr;
reg  [10:0] S_h_j;                                  // 这一行对应的"当前输出行"号

function [3:0] cur_of;                              // 行相位 → 当前输出行在这 5 行里的序号
    input [3:0] pr;
    case (pr)
        4'd0, 4'd1, 4'd2: cur_of = 4'd0;
        4'd3, 4'd4:       cur_of = 4'd1;
        4'd5, 4'd6, 4'd7: cur_of = 4'd2;
        4'd8, 4'd9:       cur_of = 4'd3;
        default:          cur_of = 4'd4;
    endcase
endfunction

integer c;
always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        S_h_v  <= 1'b0;
        S_h_gx <= 8'd0;
        S_h_pr <= 4'd0;
        S_h_j  <= 11'd0;
        for (c = 0; c < 15; c = c + 1) S_h[c] <= 12'd0;
    end else begin
        S_h_v <= S_grp;
        if (S_grp) begin
            S_h_gx <= S_gx;
            S_h_pr <= S_pr;
            S_h_j  <= S_jb + cur_of(S_pr);
            for (c = 0; c < 3; c = c + 1) begin
                S_h[0*3+c] <= m7(P(S_px,0,c)) + m7(P(S_px,1,c))  + m2(P(S_px,2,c));
                S_h[1*3+c] <= m4(P(S_px,2,c)) + m7(P(S_px,3,c))  + m5(P(S_px,4,c));
                S_h[2*3+c] <= m1(P(S_px,4,c)) + m7(P(S_px,5,c))  + m7(P(S_px,6,c)) + m1(P(S_px,7,c));
                S_h[3*3+c] <= m5(P(S_px,7,c)) + m7(P(S_px,8,c))  + m4(P(S_px,9,c));
                S_h[4*3+c] <= m2(P(S_px,9,c)) + m7(P(S_px,10,c)) + m7(P(S_px,11,c));
            end
        end
    end
end

// ---------------------------------------------------------------------------
// ② 纵向：累加器 RAM（每组一个地址，5 像素 × 3 通道 × 16 位 = 240 位）
//    读：组凑齐的那一拍给地址，下一拍（和横向和同时）出数据；写：再下一拍
// ---------------------------------------------------------------------------
reg  [239:0] S_mem [0:NG-1];
reg  [239:0] S_rd;
reg          S_w_v;
reg  [7:0]   S_w_addr;
reg  [239:0] S_w_data;

always @(posedge I_clk) begin
    S_rd <= S_mem[S_gx];
    if (S_w_v) S_mem[S_w_addr] <= S_w_data;
end

reg [2:0] S_wa, S_wb;                               // 行相位表
reg       S_fin;
always @(*) begin
    case (S_h_pr)
        4'd0:  begin S_wa = 3'd7; S_fin = 1'b0; S_wb = 3'd0; end
        4'd1:  begin S_wa = 3'd7; S_fin = 1'b0; S_wb = 3'd0; end
        4'd2:  begin S_wa = 3'd2; S_fin = 1'b1; S_wb = 3'd4; end
        4'd3:  begin S_wa = 3'd7; S_fin = 1'b0; S_wb = 3'd0; end
        4'd4:  begin S_wa = 3'd5; S_fin = 1'b1; S_wb = 3'd1; end
        4'd5:  begin S_wa = 3'd7; S_fin = 1'b0; S_wb = 3'd0; end
        4'd6:  begin S_wa = 3'd7; S_fin = 1'b0; S_wb = 3'd0; end
        4'd7:  begin S_wa = 3'd1; S_fin = 1'b1; S_wb = 3'd5; end
        4'd8:  begin S_wa = 3'd7; S_fin = 1'b0; S_wb = 3'd0; end
        4'd9:  begin S_wa = 3'd4; S_fin = 1'b1; S_wb = 3'd2; end
        4'd10: begin S_wa = 3'd7; S_fin = 1'b0; S_wb = 3'd0; end
        default: begin S_wa = 3'd7; S_fin = 1'b1; S_wb = 3'd0; end
    endcase
end

reg          S_o_v;                                 // 5 个输出像素有效
reg  [119:0] S_o_px;                                // 5 个像素 {R,G,B}，第一个在最高位
integer      L;
reg  [15:0]  S_old, S_t;
reg  [15:0]  S_rnd;

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        S_w_v    <= 1'b0;
        S_w_addr <= 8'd0;
        S_w_data <= 240'd0;
        S_o_v    <= 1'b0;
        S_o_px   <= 120'd0;
    end else begin
        S_w_v <= S_h_v;
        S_o_v <= S_h_v && S_fin && (S_h_j < OUT_H);
        if (S_h_v) begin
            S_w_addr <= S_h_gx;
            for (L = 0; L < 15; L = L + 1) begin
                S_old = (S_h_pr == 4'd0) ? 16'd0 : S_rd[239 - 16*L -: 16];
                S_t   = S_old + mulw(S_h[L], S_wa);
                S_rnd = S_t + 16'd128;
                S_w_data[239 - 16*L -: 16] <= S_fin ? mulw(S_h[L], S_wb) : S_t;
                S_o_px[119 - 8*L -: 8]     <= S_rnd[15:8];
            end
        end
    end
end

// ---------------------------------------------------------------------------
// ③ 打包：15 字节一组 → 16 字节一字
//    S_n = 上一组还有几个字节没送出（它们是上一组的最后 S_n 个字节）。来一组：
//    S_n = 0 → 全部留着（S_n = 15）；否则 送出"上一组最后 S_n 字节 + 这一组前 16 − S_n 字节"，留下 S_n − 1 个
// ---------------------------------------------------------------------------
reg  [119:0] S_prev;
reg  [3:0]   S_n;
wire [239:0] S_pc = {S_prev, S_o_px};

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        S_prev  <= 120'd0;
        S_n     <= 4'd0;
        O_fs    <= 1'b0;
        O_valid <= 1'b0;
        O_data  <= 128'd0;
    end else begin
        O_fs    <= I_fs;
        O_valid <= 1'b0;
        if (I_fs) begin
            S_n <= 4'd0;
        end else if (S_o_v) begin
            S_prev <= S_o_px;
            if (S_n == 4'd0) begin
                S_n <= 4'd15;
            end else begin
                S_n     <= S_n - 4'd1;
                O_valid <= 1'b1;
                O_data  <= S_pc[(119 + 8*S_n) -: 128];
            end
        end
    end
end

endmodule
