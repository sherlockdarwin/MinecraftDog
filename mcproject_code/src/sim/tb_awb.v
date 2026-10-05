`timescale 1ns / 1ps
// 测试 awb（逐帧算增益的自动白平衡）：用测试台自己的模型逐像素核对输出。
//   模型（按 awb.v 头部的规格独立写）：每帧只累加每拍第 0 个像素、R+G+B ≥ 720 的不算、和从 1 开始；
//   帧开始时：这一帧用的增益 = 上一帧算好的"下一帧增益"；用上一帧的和算 q = G和×65536 / R和（B 同理），
//   限幅到 0x3FFFF，平滑：下一帧增益 = 当前 + (q − 当前) >>> 2。输出 = min(255, (增益 × 像素) >> 16)，G 不变。
//   另外检查：O_tuser = I_tuser；帧开始到第一个输出像素至少 45 个时钟（下游 video_in 复位 FIFO 要这段间隔）；
//   每帧输出拍数 = 输入拍数；每帧 O_tlast 个数 = 行数。
//   场景：恒定偏色（增益逐帧收敛）、亮像素边界（720 不算、719 算）、各种像素值（含饱和）、R 很小（增益限幅）、
//         一帧全是亮像素（和 = 1 → 增益 1.0）、复位后的初始增益。
module tb_awb;

localparam W = 800, H = 4, BEATS = W / 4;

reg clk = 0, rst_n = 0;
always #5 clk = ~clk;

reg         tuser = 0, tvalid = 0;
reg  [95:0] tdata = 0;
wire        o_tlast, o_tuser, o_tvalid;
wire [95:0] o_tdata;

awb #(.IMG_HEIGHT(H), .IMG_WIDTH(W)) dut (
    .I_clk(clk), .I_rst_n(rst_n),
    .I_tlast(1'b0), .I_tuser(tuser), .I_tdata(tdata), .I_tvalid(tvalid), .I_tready(),
    .O_tlast(o_tlast), .O_tuser(o_tuser), .O_tdata(o_tdata), .O_tvalid(o_tvalid), .O_tready(1'b1)
);

integer errors = 0;
always @(errors) if (errors > 20) begin #1; $display("FAIL  tb_awb: too many errors"); $finish; end

// ---------------- 模型 ----------------
reg [63:0] m_sr, m_sg, m_sb;                   // 本帧累加（从 1 开始）
reg [63:0] p_sr, p_sg, p_sb;                   // 上一帧的和
integer    m_cur_r, m_cur_b, m_next_r, m_next_b;
integer    gain_r_of [0:63], gain_b_of [0:63];  // 第 f 帧用的增益
integer    frame = -1;

integer    n_clamp = 0;                        // 模型里真的发生限幅的次数
function integer qdiv;                         // (num << 16) / den，限幅
    input [63:0] num, den;
    reg [63:0] q;
    begin
        q = (num << 16) / den;
        if (q > 64'h3FFFF) n_clamp = n_clamp + 1;
        qdiv = (q > 64'h3FFFF) ? 32'h3FFFF : q[31:0];
    end
endfunction
function integer smooth;
    input integer cur, q;
    integer d;
    begin
        d = q - cur;
        smooth = cur + (d >>> 2);
    end
endfunction

task model_frame_start;
    integer qr, qb;
    begin
        frame = frame + 1;
        m_cur_r = m_next_r; m_cur_b = m_next_b;
        gain_r_of[frame] = m_cur_r; gain_b_of[frame] = m_cur_b;
        p_sr = m_sr; p_sg = m_sg; p_sb = m_sb;
        qr = qdiv(p_sg, p_sr); qb = qdiv(p_sg, p_sb);
        m_next_r = smooth(m_cur_r, qr);
        m_next_b = smooth(m_cur_b, qb);
        m_sr = 1; m_sg = 1; m_sb = 1;
    end
endtask

task model_accum;                              // 每拍第 0 个像素
    input [7:0] r, g, b;
    begin
        if (r + g + b < 720) begin m_sr = m_sr + r; m_sg = m_sg + g; m_sb = m_sb + b; end
    end
endtask

// ---------------- 输入队列（输出顺序 = 输入顺序）----------------
reg [95:0] q_data [0:16383];
integer    q_frm  [0:16383];
integer    q_wr = 0, q_rd = 0;                  // 环形队列（下标取模）

function [7:0] gx;                             // 增益 × 像素 >> 16，饱和
    input integer gain;
    input [7:0] p;
    reg [63:0] prod;
    begin
        prod = gain * p;
        gx = (prod >= 64'h1000000) ? 8'd255 : prod[23:16];
    end
endfunction

integer out_in_frame [0:63], tlast_in_frame [0:63];
integer cyc = 0, t_user = 0, first_seen = 1, out_beat_in_line = 0;
always @(posedge clk) cyc <= cyc + 1;

always @(posedge clk) if (rst_n) begin
    if (o_tuser !== tuser) begin $display("FAIL O_tuser != I_tuser at %0d", cyc); errors = errors + 1; end
    if (tuser) begin t_user = cyc; first_seen = 0; end
    if (o_tvalid) begin : chk_out
        integer f, k;
        reg [95:0] in, ex;
        if (!first_seen) begin
            first_seen = 1;
            if (cyc - t_user < 45) begin $display("FAIL first output only %0d clocks after frame start", cyc - t_user); errors = errors + 1; end
        end
        if (q_rd >= q_wr) begin $display("FAIL output beat without input"); errors = errors + 1; end
        else begin
            in = q_data[q_rd % 16384]; f = q_frm[q_rd % 16384]; q_rd = q_rd + 1;
            out_in_frame[f] = out_in_frame[f] + 1;
            for (k = 0; k < 4; k = k + 1) begin
                ex[k*24 + 16 +: 8] = gx(gain_r_of[f], in[k*24 + 16 +: 8]);
                ex[k*24 + 8  +: 8] = in[k*24 + 8 +: 8];
                ex[k*24      +: 8] = gx(gain_b_of[f], in[k*24 +: 8]);
            end
            if (o_tdata !== ex) begin
                $display("FAIL frame %0d beat %0d: out %h expected %h (in %h, gains %h/%h)", f, out_in_frame[f]-1, o_tdata, ex, in, gain_r_of[f], gain_b_of[f]);
                errors = errors + 1;
            end
        end
    end
    // O_tlast 必须和每行最后一个输出像素同一拍（不早不晚）
    if (o_tvalid) out_beat_in_line = out_beat_in_line + 1;
    if (o_tlast) begin
        if (frame >= 0) tlast_in_frame[frame] = tlast_in_frame[frame] + 1;
        if (!o_tvalid || out_beat_in_line != BEATS) begin $display("FAIL O_tlast not on the last beat of a line (valid %b, beat %0d)", o_tvalid, out_beat_in_line); errors = errors + 1; end
        out_beat_in_line = 0;
    end
end

// ---------------- 发一帧 ----------------
// 场景：0 恒定偏色 (r0,g0,b0)；第 0 个像素每 10 拍里：第 3 拍亮 (250,250,250) 不算、第 7 拍 (240,240,240)=720 不算、第 8 拍 (239,240,240)=719 算
//       mode 1：第 0 个像素全是亮的（和保持 1）
task send_frame;
    input [7:0] r0, g0, b0;
    input integer mode;
    integer l, b;
    reg [7:0] r, g, bb;
    reg [95:0] d;
    begin
        for (l = 0; l < H; l = l + 1) begin
            for (b = 0; b < BEATS; b = b + 1) begin
                if (mode == 1)            begin r = 8'd250; g = 8'd250; bb = 8'd250; end
                else if (b % 10 == 3)     begin r = 8'd250; g = 8'd250; bb = 8'd250; end
                else if (b % 10 == 7)     begin r = 8'd240; g = 8'd240; bb = 8'd240; end
                else if (b % 10 == 8)     begin r = 8'd239; g = 8'd240; bb = 8'd240; end
                else                      begin r = r0;     g = g0;     bb = b0; end
                d[23:0]  = {r, g, bb};                                    // 第 0 个像素（统计用）
                d[47:24] = {r0 + 8'd7, g0 ^ b[7:0], b0 + 8'd3};           // 第 1~3 个：各种值，不参与统计
                d[71:48] = {8'd255, 8'd128, 8'd255};                      // 会饱和
                d[95:72] = {b[7:0], l[7:0] * 8'd40, 8'd255 - b[7:0]};
                @(posedge clk);
                tuser <= (l == 0 && b == 0);
                tvalid <= 1'b1;
                tdata <= d;
                if (l == 0 && b == 0) model_frame_start;
                model_accum(r, g, bb);
                q_data[q_wr % 16384] = d; q_frm[q_wr % 16384] = frame; q_wr = q_wr + 1;
            end
            @(posedge clk); tuser <= 0; tvalid <= 0;
            repeat (60) @(posedge clk);                                   // 行间隔
        end
        repeat (400) @(posedge clk);                                      // 帧间隔
    end
endtask

integer f, i;
initial begin
    for (i = 0; i < 64; i = i + 1) begin out_in_frame[i] = 0; tlast_in_frame[i] = 0; end
    m_sr = 1; m_sg = 1; m_sb = 1; m_next_r = 32'h10000; m_next_b = 32'h10000;
    repeat (5) @(posedge clk); rst_n = 1; repeat (5) @(posedge clk);

    for (f = 0; f < 8; f = f + 1)  send_frame(8'd100, 8'd150, 8'd50, 0);   // 偏色：R 少 B 更少 → 增益逐帧收敛到 1.5 / 3.0
    send_frame(8'd1,   8'd200, 8'd60, 0);                                  // R 很小：G/R 超过 4 → 限幅
    send_frame(8'd1,   8'd200, 8'd60, 0);
    send_frame(8'd1,   8'd200, 8'd60, 0);
    send_frame(8'd80,  8'd80,  8'd80, 1);                                  // 全是亮像素：和 = 1 → q = 1.0
    send_frame(8'd80,  8'd80,  8'd80, 0);
    send_frame(8'd120, 8'd90,  8'd200, 0);                                 // R、B 比 G 大：增益 < 1
    for (f = 0; f < 12; f = f + 1) send_frame(8'd120, 8'd90, 8'd200, 0);
    repeat (2000) @(posedge clk);

    for (i = 0; i <= frame; i = i + 1) begin
        if (out_in_frame[i] != H * BEATS) begin $display("FAIL frame %0d: %0d output beats, expected %0d", i, out_in_frame[i], H * BEATS); errors = errors + 1; end
        if (tlast_in_frame[i] != H)       begin $display("FAIL frame %0d: %0d tlast, expected %0d", i, tlast_in_frame[i], H); errors = errors + 1; end
    end
    // 收敛和限幅真的发生了（不是一直 1.0）
    // 偏色场景的目标：R 1.374、B 2.186（含 719 的像素），8 帧后应该走过一大半
    if (gain_r_of[7] < 32'h14000 || gain_b_of[7] < 32'h1E000) begin $display("FAIL gains did not converge (%h %h)", gain_r_of[7], gain_b_of[7]); errors = errors + 1; end
    if (n_clamp < 2) begin $display("FAIL clamp never exercised (%0d)", n_clamp); errors = errors + 1; end
    if (gain_b_of[frame] >= 32'h10000 || gain_r_of[frame] >= 32'h10000) begin $display("FAIL gain < 1 case (%h %h)", gain_r_of[frame], gain_b_of[frame]); errors = errors + 1; end

    if (errors == 0) $display("PASS  tb_awb");
    else             $display("FAIL  tb_awb: %0d errors", errors);
    $finish;
end

initial begin #50_000_000; $display("FAIL  tb_awb: timeout"); $finish; end

endmodule
