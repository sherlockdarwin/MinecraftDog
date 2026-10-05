`timescale 1ns / 1ps
// 测试帧缓存 mc_framebuf（真实的 video_in / video_out / mc_to_user_interface / 厂商软 FIFO，只有 DDR 控制器换成
//   行为级替身 stub_ddr_wrapper）：
//   相机桩每隔一段时间写一帧（像素 = {帧号, 行, 列}），显示端按竖屏顺序读帧；每显示一帧就逐像素核对：
//   整帧必须来自同一个相机帧（不撕裂、不错行），帧号不倒退，显示的必须是"开始写的最新相机帧往前数第 2 帧"。
//   画面缩小成 64×40（每帧 480 个字 = 2 次 240 字突发，满足厂商模块的长度约束）。
//   两个用例：慢相机（逐像素核对）、压力（相机高速连续写，写入突发和读出频繁撞时间，只查总线互斥 + 不死锁）。
module tb_fb_case #(
    parameter STRESS = 0                       // 1 = 压力用例：不核对像素（相机比显示快时厂商四缓冲本来就会撕裂）
)(
    output reg        fin,
    output reg [31:0] err
);

localparam SRC_W = 64;
localparam SRC_H = 40;
localparam ROW_WORDS = SRC_W * 3 / 16;     // 12

reg cam_clk = 0, dsi_clk = 0, sys_clk = 0;
always #4.5  cam_clk = ~cam_clk;           // 111 MHz
always #7.3  dsi_clk = ~dsi_clk;           // 68.5 MHz
always #20   sys_clk = ~sys_clk;           // 25 MHz

reg rst_n = 0;
reg cam_fs = 0, cam_valid = 0;
reg [127:0] cam_data = 0;
reg dsi_vsync = 0, rd_en = 0;
wire [23:0] dsi_data;
wire        ddr_ready;

wire [12:0] ddr_addr; wire [1:0] ddr_ba; wire [0:0] ddr_cke, ddr_odt, ddr_cs_n, ddr_ck_p, ddr_ck_n;
wire ddr_ras_n, ddr_cas_n, ddr_we_n;
wire [1:0] ddr_dm, ddr_dqs_p, ddr_dqs_n; wire [15:0] ddr_dq;

mc_framebuf dut (
    .I_rst_n(rst_n), .I_clk_sys(sys_clk),
    .I_cam_clk(cam_clk), .I_cam_frame_start(cam_fs), .I_cam_valid(cam_valid), .I_cam_data(cam_data),
    .I_dsi_clk(dsi_clk), .I_dsi_vsync(dsi_vsync), .I_dsi_rd_en(rd_en), .O_dsi_data(dsi_data),
    .O_ddr_ready(ddr_ready),
    .ddr_addr(ddr_addr), .ddr_ba(ddr_ba), .ddr_cke(ddr_cke), .ddr_odt(ddr_odt), .ddr_cs_n(ddr_cs_n),
    .ddr_ras_n(ddr_ras_n), .ddr_cas_n(ddr_cas_n), .ddr_we_n(ddr_we_n), .ddr_ck_p(ddr_ck_p), .ddr_ck_n(ddr_ck_n),
    .ddr_dm(ddr_dm), .ddr_dq(ddr_dq), .ddr_dqs_p(ddr_dqs_p), .ddr_dqs_n(ddr_dqs_n)
);

// ---------------- 相机桩 ----------------
integer cam_frames = 0;
integer cam_started = 0;                                      // 已经开始写的相机帧数（每发一个帧起始脉冲加一）
reg [1535:0] rowbits;
integer cr, cc, cw_i, k_i;
task cam_frame;
    input integer k;
    begin
        @(posedge cam_clk); cam_fs <= 1'b1;
        cam_started = cam_started + 1;
        @(posedge cam_clk); cam_fs <= 1'b0;
        repeat (60) @(posedge cam_clk);                       // 帧起始到第一行数据之间的空闲（FIFO 复位要时间）
        for (cr = 0; cr < SRC_H; cr = cr + 1) begin
            for (cc = 0; cc < SRC_W; cc = cc + 1)
                rowbits[1535 - 24 * cc -: 24] = {k[7:0], cr[7:0], cc[7:0]};
            for (cw_i = 0; cw_i < ROW_WORDS; cw_i = cw_i + 1) begin
                cam_valid <= 1'b1;
                cam_data  <= rowbits[1535 - 128 * cw_i -: 128];
                @(posedge cam_clk);
            end
            cam_valid <= 1'b0;
            if (STRESS == 0) repeat (40) @(posedge cam_clk);     // 行间隙（压力用例没有）
        end
        cam_frames = cam_frames + 1;
    end
endtask

integer ck;
initial begin
    wait (rst_n);
    ck = 1;
    forever begin
        cam_frame(ck);
        ck = ck + 1;
        if (STRESS == 0) repeat (34000) @(posedge cam_clk);  // 帧间隙：整帧周期 ≈ 330 us（比显示帧 219 us 长，和真实的 30 fps 相机 vs 52 Hz 屏幕同方向）
        else             repeat (1500)  @(posedge cam_clk);  // 压力用例：整帧周期 ≈ 18 us，一个显示帧里约 12 个相机帧、24 次写突发
    end
end

// ---------------- 显示端 ----------------
localparam LINE_T = 100;
localparam PRE    = 40;
localparam FRAME_LINES = 150;

reg [23:0] cap [0:4095];
integer cur_li, cur_pc;
integer disp_ref = 0;                                          // 本显示帧开始时，相机已经开始写到第几帧
reg        v1, v2;
integer    li1, li2, pc1, pc2;
reg        cap_on = 0;

always @(posedge dsi_clk) begin
    v1 <= rd_en;  v2 <= v1;
    li1 <= cur_li; li2 <= li1;
    pc1 <= cur_pc; pc2 <= pc1;
    if (v2 && cap_on) cap[li2 * 64 + pc2] <= dsi_data;
end

task idle_frame;                                              // 只有 vsync 和空行，没有图像读
    begin
        @(posedge dsi_clk);
        dsi_vsync <= 1'b1;
        repeat (LINE_T * 3) @(posedge dsi_clk);
        dsi_vsync <= 1'b0;
        repeat (LINE_T * (FRAME_LINES - 3)) @(posedge dsi_clk);
    end
endtask

task show_frame;                                              // 一整帧显示时序
    integer li, pc;
    begin
        @(posedge dsi_clk);
        disp_ref = cam_started;
        dsi_vsync <= 1'b1;
        repeat (LINE_T * 3) @(posedge dsi_clk);
        dsi_vsync <= 1'b0;
        repeat (LINE_T * (PRE - 3)) @(posedge dsi_clk);
        cap_on = 1;
        for (li = 0; li < SRC_H; li = li + 1) begin
            repeat (20) @(posedge dsi_clk);
            cur_li <= li;
            for (pc = 0; pc < SRC_W; pc = pc + 1) begin
                cur_pc <= pc;
                rd_en <= 1'b1;
                @(posedge dsi_clk);
            end
            rd_en <= 1'b0;
            repeat (LINE_T - 20 - SRC_W) @(posedge dsi_clk);
        end
        repeat (4) @(posedge dsi_clk);
        cap_on = 0;
        repeat (LINE_T * (FRAME_LINES - PRE - SRC_H)) @(posedge dsi_clk);
    end
endtask

// ---------------- 总线互斥监视：写突发和读突发不能同时占用 DDR 用户口 ----------------
integer mon_cnt = 0;
task mon_fail;
    input [8*60-1:0] msg;
    begin
        if (mon_cnt < 3) $display("FAIL [S%0d] %0s", STRESS, msg);
        mon_cnt = mon_cnt + 1;
        if (mon_cnt == 1) err = err + 1;
    end
endtask
always @(posedge dut.S_ddr_clk) begin
    if (dut.S_vi_ddr_wr_en && dut.S_vo_ddr_rd_en) mon_fail("video_out reads during video_in write");
end

// 压力够不够的统计（压力用例要求这个数足够大，否则互斥监视没有意义）：
//   n_vi_wait ：video_in 已攒够 240 字想写，但 video_out 占着总线，被迫等待的时钟数
integer n_vi_wait = 0;
always @(posedge dut.S_ddr_clk) begin
    if (dut.u_video_in.S_fifo_rd_num >= 9'd240 && !dut.S_video_in_wr_busy && dut.S_video_out_rd_busy) n_vi_wait = n_vi_wait + 1;
end

// ---------------- 核对 ----------------
integer last_k = 0;
integer n_ok = 0;
integer n_bad_frames = 0;
task verify;
    input integer check_it;
    integer li, pc, k, bad, lag;
    reg [23:0] e;
    begin
        k = cap[0][23:16];
        bad = 0;
        if (check_it != 0) begin
            for (li = 0; li < SRC_H; li = li + 1)
                for (pc = 0; pc < SRC_W; pc = pc + 1) begin
                    e = {k[7:0], li[7:0], pc[7:0]};
                    if (cap[li * 64 + pc] !== e) begin
                        if (bad < 3) $display("FAIL frame k=%0d line %0d px %0d: got %h expected %h", k, li, pc, cap[li * 64 + pc], e);
                        bad = bad + 1;
                    end
                end
            if (bad != 0) begin err = err + 1; n_bad_frames = n_bad_frames + 1; end
            else n_ok = n_ok + 1;
            $display("frame f=%0d k=%0d bad=%0d t=%0t", f, k, bad, $time);
            if (k < last_k) begin $display("FAIL frame number went backwards %0d -> %0d", last_k, k); err = err + 1; end
            // 显示的必须是"开始写的最新相机帧往前数第 2 帧"（video_in 的读指针 = 写指针 + 2）。显示帧开始的瞬间刚好有相机帧起始时可能落后 3。
            lag = (disp_ref - k) & 255;
            if (lag != 2 && lag != 3) begin $display("FAIL displayed camera frame %0d while camera had started frame %0d (lag %0d, expected 2 or 3)", k, disp_ref, lag); err = err + 1; end
            last_k = k;
        end
    end
endtask

integer f;
initial begin
    fin = 0; err = 0;

    repeat (20) @(posedge sys_clk);
    rst_n = 1;
    while (cam_frames < 5) idle_frame;                        // 真实的显示时序从上电就一直在跑（先让厂商 video_out 的 FIFO 复位一次）；等四个缓冲区都写过再开始核对
    for (f = 0; f < 20; f = f + 1) begin
        show_frame;
        verify((STRESS == 0) ? 1 : 0);                        // 压力用例不核对像素
    end
    if (STRESS == 0 && n_ok < 16) begin $display("FAIL only %0d frames verified", n_ok); err = err + 1; end
    $display("[S%0d] contention: video_in waited %0d clk for video_out, camera frames %0d, bus collisions %0d", STRESS, n_vi_wait, cam_frames, mon_cnt);
    $display("[S%0d] verified frames %0d, bad %0d, last frame no %0d", STRESS, n_ok, n_bad_frames, last_k);
    fin = 1;
end

endmodule


module tb_fb;

wire f0, f1;
wire [31:0] e0, e1;

tb_fb_case #(.STRESS(0)) c0 (.fin(f0), .err(e0));      // 慢相机：核对每个像素
tb_fb_case #(.STRESS(1)) c1 (.fin(f1), .err(e1));      // 压力：相机高速写，只查总线互斥

initial begin
    wait (f0 && f1);
    if (e0 + e1 == 0) $display("PASS  tb_fb");
    else $display("FAIL  tb_fb: errors %0d %0d", e0, e1);
    $finish;
end

initial begin #12_000_000; $display("FAIL  tb_fb: timeout"); $finish; end

endmodule
