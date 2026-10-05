`timescale 1ns / 1ps
// 测试整个音频子系统 mc_audio（ES8388 配置 + 两个读文件模块共用一个 SD 控制器 + 两个 WAV 播放器 + 重采样混音 + I2S），外围用行为模型：
//   · TF 卡：sd_card_model（卡里是 tools/mk_sd_test_image.pl 生成的 FAT32 镜像）；ES8388：一个什么都应答的 I2C 从机；
//   · 一个标准 I2S 接收器把 DSDIN 解出来，逐帧（左、右）存下来，和测试台里按同样算法算出来的期望序列核对。
// 两个喇叭各一路：背景音乐在左声道、音效在右声道，数据逐帧核对；两张卡各跑一遍（MBR 分区 + SDHC / 无分区 + SDSC；后一张故意很慢：ACMD41 重试 150 次，挂载在约 66 ms，晚于 ES8388 配置完成的约 45 ms，用来核对 O_ready 必须等卡挂载完成）。
// 覆盖：
//   1) 上电：ES8388 配置完成、两个读文件模块都挂载、找到 8 首；背景音乐（1.wav，16 kHz 单声道）自动开始，右声道（音效）静音；
//      第一遍的每一帧 = 期望的重采样序列（16 kHz → 48.83 kHz 保持采样）；背景音乐循环（重新打开文件再播）；
//   2) 音效和背景音乐同时播：音效 2.wav（48 kHz 立体声取平均）在右声道逐帧正确；左声道只有背景音乐的值（没有串音）；
//   3) 音效播放中收到的新播放命令被忽略：不打断、不重复，播完以后右声道安静；
//   4) 各种采样率的音效逐帧正确：3.wav（24 kHz + LIST 块）、4.wav（44.1 kHz）、5.wav（32 kHz 立体声，在目录第 2 个簇）、10.wav（12 kHz）；
//   5) 错误：6.wav（不存在）→ 错误 1、7.wav（头不对）→ 错误 2、8.wav（96 kHz）→ 错误 3；出错不影响背景音乐，之后还能正常播；
//   6) 白盒接线核对：两路各自的 读文件模块 / 播放器 / 混音器 / 仲裁器 之间的连线两端始终相等（功能测试看不出的接错在这里抓）。
module tb_audio_case #(
    parameter IMAGE = "sd_mbr",
    parameter SDHC  = 1,
    parameter V2    = 1,
    parameter TRIES = 3            // sd_card_model 的 ACMD41 "还在初始化"次数：越大卡越慢
)(
    output reg        fin,
    output reg [31:0] err
);

reg clk = 0, rst_n = 0;
always #5 clk = ~clk;

// 任何一项检查失败就马上结束（突变检查时省时间；全部通过时没有影响）
always @(err) if (err != 0) begin
    #1;
    $display("FAIL  tb_audio: [%0s] %0d error(s) so far, aborting early", IMAGE, err);
    $finish;
end

reg tick1ms = 0;
integer tdiv = 0;
always @(posedge clk) begin
    tick1ms <= 1'b0;
    if (tdiv == 99_999) begin tdiv <= 0; tick1ms <= 1'b1; end
    else tdiv <= tdiv + 1;
end

reg        sfx_play = 0;
reg  [6:0] sfx_clip = 0;
wire [2:0] sd_state;
wire [1:0] codec_state, bgm_state, sfx_state;
wire [7:0] nclips, bgm_err, bgm_ur, sfx_err, sfx_ur;
wire [6:0] sfx_cur;
wire       ready, sfx_busy;
wire       mclk, sclk, lrck, dsdin, cclk, spk;
tri1       sda;
wire       cs_n, sck, mosi, miso;

mc_audio dut (
    .I_clk(clk), .I_rst_n(rst_n), .I_tick_1ms(tick1ms),
    .I_sfx_play(sfx_play), .I_sfx_clip(sfx_clip),
    .O_sd_state(sd_state), .O_codec_state(codec_state), .O_nclips(nclips), .O_ready(ready),
    .O_bgm_state(bgm_state), .O_bgm_err(bgm_err), .O_bgm_ur(bgm_ur),
    .O_sfx_state(sfx_state), .O_sfx_cur(sfx_cur), .O_sfx_err(sfx_err), .O_sfx_ur(sfx_ur), .O_sfx_busy(sfx_busy),
    .O_aud_mclk(mclk), .O_aud_sclk(sclk), .O_aud_lrck(lrck), .O_aud_dsdin(dsdin),
    .O_aud_cclk(cclk), .IO_aud_cdata(sda), .O_spk_ctl(spk),
    .O_sd_cs_n(cs_n), .O_sd_sck(sck), .O_sd_mosi(mosi), .I_sd_miso(miso)
);

i2c_ack_slave u_codec (.scl(cclk), .sda(sda));

sd_card_model #(.IMAGE_FILE({IMAGE, ".hex"}), .SDHC(SDHC), .V2(V2), .ACMD41_TRIES(TRIES), .READ_DELAY(5)) u_card (
    .cs_n(cs_n), .sck(sck), .mosi(mosi), .miso(miso)
);

// ---------------- 标准 I2S 接收器：把每一帧（左、右）存下来 ----------------
reg        lrck_q = 1;
integer    cnt = 0;
reg [15:0] sh = 0, rx_l = 0;
reg        got_l = 0;
reg [15:0] fl [0:131071];
reg [15:0] fr [0:131071];
integer    nf = 0;
always @(posedge sclk) begin
    if (lrck !== lrck_q) cnt = 0; else cnt = cnt + 1;
    lrck_q = lrck;
    if (cnt >= 1 && cnt <= 16) sh = {sh[14:0], dsdin};
    if (cnt == 16) begin
        if (lrck == 1'b0) begin rx_l = sh; got_l = 1; end
        else if (got_l) begin fl[nf] = rx_l; fr[nf] = sh; nf = nf + 1; got_l = 0; end
    end
end

// LRCK 周期（固定 2048 个时钟）和播放状态的统计
integer lrck_per = 0, lrck_cnt = 0, lrck_bad = 0, lrck_chk = 0;
reg lrck_m = 0;
always @(posedge clk) begin
    lrck_m <= lrck;
    lrck_cnt <= lrck_cnt + 1;
    if (lrck && !lrck_m) begin
        if (lrck_cnt != 2048 && nf > 10 && lrck_chk < 100000) lrck_bad = lrck_bad + 1;
        lrck_chk = lrck_chk + 1;
        lrck_cnt <= 1;
    end
end
integer n_bgm_start = 0;
reg [1:0] bgm_state_d = 0;
always @(posedge clk) begin
    bgm_state_d <= bgm_state;
    if (bgm_state == 2'd2 && bgm_state_d != 2'd2) n_bgm_start = n_bgm_start + 1;
end

// ---------------- 期望序列 ----------------
localparam integer FS8 = 390625;
reg [7:0] filebytes [0:8191];
integer   fsize;
reg [8*64-1:0] fname;
task load_file;
    input integer num;
    integer fd, c, i;
    begin
        for (i = 0; i < 8192; i = i + 1) filebytes[i] = 8'h00;
        $sformat(fname, "%0s_clip%0d.hex", IMAGE, num);
        $readmemh(fname, filebytes);
        $sformat(fname, "%0s_clip%0d.size", IMAGE, num);
        fd = $fopen(fname, "r"); c = $fscanf(fd, "%d", fsize); $fclose(fd);
    end
endtask

function integer s16; input [15:0] v; begin s16 = (v >= 32768) ? (v - 65536) : v; end endfunction
function integer ashr1; input integer v; begin ashr1 = (v >= 0) ? (v / 2) : -(((-v) + 1) / 2); end endfunction

integer ex_l [0:16383];                      // 期望的输出帧：左 / 右 声道（立体声文件的两个声道原样；是否取平均在比对时做）
integer ex_r [0:16383];
integer ex_n;                                // 期望的帧数
// 根据曲目号、文件头长度、声道数、采样率生成期望的重采样序列（保持采样，相位累加，算法和 mc_audio_mix 一致）
task gen_expected;
    input integer num, off, ch, rate;
    integer ns, idx, ph, r8, k, j;
    reg [15:0] lo, hi;
    begin
        load_file(num);
        ns = {filebytes[off - 1], filebytes[off - 2], filebytes[off - 3], filebytes[off - 4]} / (2 * ch);   // 按数据块的大小算（4.wav 文件尾部补的零不算）
        r8 = (rate >= 47500) ? FS8 : rate * 8;
        ph = FS8; idx = -1; k = 0;                        // 和 mc_audio_mix 一样：开播后第一帧就取第一个采样
        while (idx < ns - 1) begin
            ph = ph + r8;
            if (ph >= FS8) begin ph = ph - FS8; idx = idx + 1; end
            j = off + idx * 2 * ch;
            lo = filebytes[j] | (filebytes[j + 1] << 8);
            ex_l[k] = s16(lo);
            if (ch == 2) begin
                hi = filebytes[j + 2] | (filebytes[j + 3] << 8);
                ex_r[k] = s16(hi);
            end else ex_r[k] = s16(lo);
            k = k + 1;
        end
        ex_n = k;
    end
endtask

// 找 ≥ from 的第一个非零帧（左 / 右）
function integer first_nz_l; input integer from; integer i; begin
    first_nz_l = -1;
    for (i = from; i < nf && first_nz_l < 0; i = i + 1) if (fl[i] !== 16'd0) first_nz_l = i;
end endfunction
function integer first_nz_r; input integer from; integer i; begin
    first_nz_r = -1;
    for (i = from; i < nf && first_nz_r < 0; i = i + 1) if (fr[i] !== 16'd0) first_nz_r = i;
end endfunction

// ---------------- 背景音乐采样值集合（1.wav 的所有可能取值 + 0）----------------
reg bgm_set [0:65535];
integer bi;
initial begin
    for (bi = 0; bi < 65536; bi = bi + 1) bgm_set[bi] = 1'b0;
end

// ---------------- 核对任务 ----------------
// 从第 k0 帧起，输出（stream = 0 背景音乐在左 / 1 音效在右）必须等于期望序列 ex_*[0 .. ex_n-1]（立体声文件取平均）
task check_stream;
    input [255:0] name;
    input integer k0;
    input integer stream;
    integer n, e, got, bad;
    begin
        bad = 0;
        for (n = 0; n < ex_n; n = n + 1) begin
            e   = ashr1(ex_l[n] + ex_r[n]);                                 // 立体声取平均（单声道文件两个声道一样，结果不变）
            got = s16((stream == 0) ? fl[k0 + n] : fr[k0 + n]);
            if (got !== e) begin
                if (bad < 3) $display("FAIL [%0s %0s] frame %0d (k=%0d): got %0d expected %0d", IMAGE, name, n, k0 + n, got, e);
                bad = bad + 1;
            end
        end
        if (bad != 0) err = err + 1;
    end
endtask

// 从第 k0 帧起 n 帧，某个声道全为 0
task check_silent;
    input [255:0] name;
    input integer k0, n, right;
    integer i, bad;
    begin
        bad = 0;
        for (i = k0; i < k0 + n && i < nf; i = i + 1)
            if ((right != 0 ? fr[i] : fl[i]) !== 16'd0) bad = bad + 1;
        if (bad != 0) begin $display("FAIL [%0s %0s] %0d non-zero frames in a channel that should be silent (frames %0d..%0d)", IMAGE, name, bad, k0, k0 + n - 1); err = err + 1; end
    end
endtask

task wait_frames; input integer n; integer t0; begin t0 = nf; while (nf < t0 + n) @(posedge sclk); end endtask
task cmd_sfx;  input integer c; begin @(posedge clk); sfx_clip <= c; sfx_play <= 1'b1; @(posedge clk); sfx_play <= 1'b0; end endtask
task wait_sfx_idle;                                  // 等音效播完（状态回 0 或 3），带超时
    integer t;
    begin
        t = 0;
        repeat (50) @(posedge clk);
        while (sfx_busy && t < 6_000_000) begin @(posedge clk); t = t + 1; end
        if (sfx_busy) begin $display("FAIL [%0s] sound effect never finished", IMAGE); err = err + 1; end
        repeat (200) @(posedge clk);
    end
endtask
task wait_bgm_playing;
    integer t;
    begin
        t = 0;
        while (bgm_state !== 2'd2 && t < 12_000_000) begin @(posedge clk); t = t + 1; end
        if (bgm_state !== 2'd2) begin $display("FAIL [%0s] background music never started (state %0d err %0d)", IMAGE, bgm_state, bgm_err); err = err + 1; end
    end
endtask

// ---------------- 接线核对（白盒）：两路各自的 读文件模块 / 播放器 / 混音器 / 仲裁器 之间的连线必须"各接各的" ----------------
// 例如音效那一路的读文件模块的"缓冲有空位"必须接自己的播放器：背景音乐文件很短时它恒为 1，接错了功能测试也看不出来，所以直接比较连线两端
integer wire_bad = 0;
reg     wire_en = 0;
task wchk;
    input [127:0] name;
    input [31:0]  a, b;
    begin
        if (a !== b) begin
            if (wire_bad < 6) $display("FAIL [%0s] wiring: %0s (%h vs %h, t=%0t)", IMAGE, name, a, b, $time);
            wire_bad = wire_bad + 1;
            if (wire_bad == 1) begin $display("FAIL  tb_audio: wiring mismatch, aborting"); $finish; end
        end
    end
endtask
// 行内比较：task 调用在 vvp 里很慢（每次新建线程），每个时钟 100 来对的核对用 task 会让仿真慢 5 倍；
// 用宏展开成行内的 if，只有不相等才调 wchk（它再比一次、打印名字和两端的值、结束仿真）
`define WCHK(n, a, b) if ((a) !== (b)) wchk(n, a, b);
always @(posedge clk) begin
    if (wire_en) begin
        // 读文件模块 <-> 仲裁器（0 = 背景音乐，1 = 音效；0 号读扇区口在挂载完成之前归"挂载 + 目录表"）
        `WCHK("arb.start0", dut.u_arb.I_start0, dut.u_fat.u_dir.O_mounted ? dut.u_fat.u_rd0.O_rd_start : dut.u_fat.u_dir.O_rd_start);
        `WCHK("arb.start1", dut.u_arb.I_start1, dut.u_fat.u_rd1.O_rd_start);
        `WCHK("arb.lba0",   dut.u_arb.I_lba0,   dut.u_fat.u_dir.O_mounted ? dut.u_fat.u_rd0.O_lba : dut.u_fat.u_dir.O_lba);
        `WCHK("arb.lba1",   dut.u_arb.I_lba1,   dut.u_fat.u_rd1.O_lba);
        `WCHK("dir.busy",   dut.u_fat.u_dir.I_rd_busy,    dut.u_arb.O_busy0);  `WCHK("rd0.busy",  dut.u_fat.u_rd0.I_rd_busy,    dut.u_arb.O_busy0);  `WCHK("rd1.busy",  dut.u_fat.u_rd1.I_rd_busy,    dut.u_arb.O_busy1);
        `WCHK("dir.valid",  dut.u_fat.u_dir.I_byte_valid, dut.u_arb.O_valid0); `WCHK("rd0.valid", dut.u_fat.u_rd0.I_byte_valid, dut.u_arb.O_valid0); `WCHK("rd1.valid", dut.u_fat.u_rd1.I_byte_valid, dut.u_arb.O_valid1);
        `WCHK("dir.byte",   dut.u_fat.u_dir.I_byte,       dut.u_arb.O_byte0);  `WCHK("rd0.byte",  dut.u_fat.u_rd0.I_byte,       dut.u_arb.O_byte0);  `WCHK("rd1.byte",  dut.u_fat.u_rd1.I_byte,       dut.u_arb.O_byte1);
        `WCHK("dir.idx",    dut.u_fat.u_dir.I_byte_idx,   dut.u_arb.O_idx0);   `WCHK("rd0.idx",   dut.u_fat.u_rd0.I_byte_idx,   dut.u_arb.O_idx0);   `WCHK("rd1.idx",   dut.u_fat.u_rd1.I_byte_idx,   dut.u_arb.O_idx1);
        `WCHK("dir.done",   dut.u_fat.u_dir.I_rd_done,    dut.u_arb.O_done0);  `WCHK("rd0.done",  dut.u_fat.u_rd0.I_rd_done,    dut.u_arb.O_done0);  `WCHK("rd1.done",  dut.u_fat.u_rd1.I_rd_done,    dut.u_arb.O_done1);
        `WCHK("dir.err",    dut.u_fat.u_dir.I_rd_err,     dut.u_arb.O_err0);   `WCHK("rd0.err",   dut.u_fat.u_rd0.I_rd_err,     dut.u_arb.O_err0);   `WCHK("rd1.err",   dut.u_fat.u_rd1.I_rd_err,     dut.u_arb.O_err1);
        `WCHK("dir.ready",  dut.u_fat.u_dir.I_sd_ready,   dut.u_sd.O_ready);   `WCHK("dir.fail",  dut.u_fat.u_dir.I_sd_fail,    dut.u_sd.O_fail);
        // 目录表 / 共用信息：挂载 + 目录表 → 两路读文件（各读各的读口）
        `WCHK("rd0.fatlba", dut.u_fat.u_rd0.I_fat_lba,  dut.u_fat.u_dir.O_fat_lba);   `WCHK("rd1.fatlba", dut.u_fat.u_rd1.I_fat_lba,  dut.u_fat.u_dir.O_fat_lba);
        `WCHK("rd0.datalba",dut.u_fat.u_rd0.I_data_lba, dut.u_fat.u_dir.O_data_lba);  `WCHK("rd1.datalba",dut.u_fat.u_rd1.I_data_lba, dut.u_fat.u_dir.O_data_lba);
        `WCHK("rd0.spc",    dut.u_fat.u_rd0.I_spc,      dut.u_fat.u_dir.O_spc);       `WCHK("rd1.spc",    dut.u_fat.u_rd1.I_spc,      dut.u_fat.u_dir.O_spc);
        `WCHK("rd0.spclog", dut.u_fat.u_rd0.I_spc_log,  dut.u_fat.u_dir.O_spc_log);   `WCHK("rd1.spclog", dut.u_fat.u_rd1.I_spc_log,  dut.u_fat.u_dir.O_spc_log);
        `WCHK("rd0.pres_l", dut.u_fat.u_rd0.I_present[31:0], dut.u_fat.u_dir.O_present[31:0]);  `WCHK("rd1.pres_l", dut.u_fat.u_rd1.I_present[31:0], dut.u_fat.u_dir.O_present[31:0]);
        `WCHK("rd0.pres_h", dut.u_fat.u_rd0.I_present[63:32], dut.u_fat.u_dir.O_present[63:32]); `WCHK("rd1.pres_h", dut.u_fat.u_rd1.I_present[63:32], dut.u_fat.u_dir.O_present[63:32]);
        `WCHK("q0.addr",    dut.u_fat.u_dir.I_q_addr0,  dut.u_fat.u_rd0.O_q_addr);    `WCHK("q1.addr",    dut.u_fat.u_dir.I_q_addr1,  dut.u_fat.u_rd1.O_q_addr);
        `WCHK("q0.cl",      dut.u_fat.u_rd0.I_q_cl,     dut.u_fat.u_dir.O_q_cl0);     `WCHK("q1.cl",      dut.u_fat.u_rd1.I_q_cl,     dut.u_fat.u_dir.O_q_cl1);
        `WCHK("q0.sz",      dut.u_fat.u_rd0.I_q_sz,     dut.u_fat.u_dir.O_q_sz0);     `WCHK("q1.sz",      dut.u_fat.u_rd1.I_q_sz,     dut.u_fat.u_dir.O_q_sz1);
        // 仲裁器 <-> SD 卡控制器
        `WCHK("sd.start", dut.u_sd.I_rd_start, dut.u_arb.O_start);        `WCHK("sd.lba",   dut.u_sd.I_lba,      dut.u_arb.O_lba);
        `WCHK("arb.busy", dut.u_arb.I_sd_busy, dut.u_sd.O_rd_busy);       `WCHK("arb.valid", dut.u_arb.I_valid,  dut.u_sd.O_byte_valid);
        `WCHK("arb.byte", dut.u_arb.I_byte,    dut.u_sd.O_byte);          `WCHK("arb.idx",   dut.u_arb.I_idx,    dut.u_sd.O_byte_idx);
        `WCHK("arb.done", dut.u_arb.I_done,    dut.u_sd.O_rd_done);       `WCHK("arb.err",   dut.u_arb.I_err,    dut.u_sd.O_rd_err);
        // 读文件模块 <-> 播放器
        `WCHK("p0.mounted", dut.u_p0.I_mounted,  dut.u_fat.u_dir.O_mounted);   `WCHK("p1.mounted", dut.u_p1.I_mounted,  dut.u_fat.u_dir.O_mounted);
        `WCHK("rd0.open",   dut.u_fat.u_rd0.I_open,   dut.u_p0.O_open);        `WCHK("rd1.open",   dut.u_fat.u_rd1.I_open,   dut.u_p1.O_open);
        `WCHK("rd0.clip",   dut.u_fat.u_rd0.I_clip,   dut.u_p0.O_open_clip);   `WCHK("rd1.clip",   dut.u_fat.u_rd1.I_clip,   dut.u_p1.O_open_clip);
        `WCHK("rd0.close",  dut.u_fat.u_rd0.I_close,  dut.u_p0.O_close);       `WCHK("rd1.close",  dut.u_fat.u_rd1.I_close,  dut.u_p1.O_close);
        `WCHK("p0.operr",   dut.u_p0.I_open_err, dut.u_fat.u_rd0.O_open_err);  `WCHK("p1.operr",   dut.u_p1.I_open_err, dut.u_fat.u_rd1.O_open_err);
        `WCHK("p0.ecode",   dut.u_p0.I_open_err_code, dut.u_fat.u_rd0.O_err_code); `WCHK("p1.ecode", dut.u_p1.I_open_err_code, dut.u_fat.u_rd1.O_err_code);
        `WCHK("p0.dvalid",  dut.u_p0.I_data_valid, dut.u_fat.u_rd0.O_data_valid); `WCHK("p1.dvalid", dut.u_p1.I_data_valid, dut.u_fat.u_rd1.O_data_valid);
        `WCHK("p0.data",    dut.u_p0.I_data,     dut.u_fat.u_rd0.O_data);      `WCHK("p1.data",    dut.u_p1.I_data,     dut.u_fat.u_rd1.O_data);
        `WCHK("rd0.space",  dut.u_fat.u_rd0.I_space_ok, dut.u_p0.O_space_ok);  `WCHK("rd1.space",  dut.u_fat.u_rd1.I_space_ok, dut.u_p1.O_space_ok);
        `WCHK("p0.eof",     dut.u_p0.I_eof,      dut.u_fat.u_rd0.O_eof);       `WCHK("p1.eof",     dut.u_p1.I_eof,      dut.u_fat.u_rd1.O_eof);
        `WCHK("p0.active",  dut.u_p0.I_fat_active, dut.u_fat.u_rd0.O_active);  `WCHK("p1.active",  dut.u_p1.I_fat_active, dut.u_fat.u_rd1.O_active);
        `WCHK("o.nclips",   nclips,  dut.u_fat.u_dir.O_nclips);                `WCHK("o.ready",    ready,   dut.u_cfg.O_done & dut.u_fat.u_dir.O_mounted);
        // 播放器 <-> 混音器
        `WCHK("mix.st0",   dut.u_mix.I_st0,   dut.u_p0.O_state);          `WCHK("mix.st1",   dut.u_mix.I_st1,   dut.u_p1.O_state);
        `WCHK("mix.v0",    dut.u_mix.I_v0,    dut.u_p0.O_i2s_valid);      `WCHK("mix.v1",    dut.u_mix.I_v1,    dut.u_p1.O_i2s_valid);
        `WCHK("mix.l0",    dut.u_mix.I_l0,    dut.u_p0.O_l);              `WCHK("mix.l1",    dut.u_mix.I_l1,    dut.u_p1.O_l);
        `WCHK("mix.r0",    dut.u_mix.I_r0,    dut.u_p0.O_r);              `WCHK("mix.r1",    dut.u_mix.I_r1,    dut.u_p1.O_r);
        `WCHK("mix.rate0", dut.u_mix.I_rate0, dut.u_p0.O_rate);           `WCHK("mix.rate1", dut.u_mix.I_rate1, dut.u_p1.O_rate);
        `WCHK("p0.ack",    dut.u_p0.I_ack,    dut.u_mix.O_ack0);          `WCHK("p1.ack",    dut.u_p1.I_ack,    dut.u_mix.O_ack1);
        `WCHK("p0.ur",     dut.u_p0.I_i2s_underrun, dut.u_mix.O_ur0);     `WCHK("p1.ur",     dut.u_p1.I_i2s_underrun, dut.u_mix.O_ur1);
        // 混音器 -> I2S；播放器 -> 对外状态口；命令口 -> 播放器
        `WCHK("i2s.valid", dut.u_i2s.I_valid, dut.u_mix.O_valid);         `WCHK("i2s.l",     dut.u_i2s.I_l,     dut.u_mix.O_l);
        `WCHK("i2s.r",     dut.u_i2s.I_r,     dut.u_mix.O_r);             `WCHK("mix.frame", dut.u_mix.I_frame, dut.u_i2s.O_ack);
        `WCHK("o.bgm_state", bgm_state, dut.u_p0.O_state);                `WCHK("o.sfx_state", sfx_state, dut.u_p1.O_state);
        `WCHK("o.bgm_err",   bgm_err,   dut.u_p0.O_err);                  `WCHK("o.sfx_err",   sfx_err,   dut.u_p1.O_err);
        `WCHK("o.bgm_ur",    bgm_ur,    dut.u_p0.O_underrun);             `WCHK("o.sfx_ur",    sfx_ur,    dut.u_p1.O_underrun);
        `WCHK("o.sfx_cur",   sfx_cur,   dut.u_p1.O_cur);                  `WCHK("o.sfx_busy",  sfx_busy,  dut.u_p1.O_busy);
        `WCHK("p1.clip",     dut.u_p1.I_clip, sfx_clip);
        `WCHK("p0.clip",     dut.u_p0.I_clip, 32'd1);                      `WCHK("p0.loop",     dut.u_p0.I_loop, 32'd1);
        `WCHK("p1.loop",     dut.u_p1.I_loop, 32'd0);
    end
end

// O_ready 不能早于"卡已挂载"：c0 的卡挂载（约 6 ms）比 ES8388 配置完成（约 45 ms）早，c1 的卡很慢（挂载在配置完成之后）；
// 后者才能看出 O_ready 少了"已挂载"这个条件
always @(posedge clk) if (wire_en && ready && sd_state !== 3'd1) begin
    $display("FAIL [%0s] O_ready is high before the card is mounted (sd_state=%0d)", IMAGE, sd_state);
    err = err + 1;
end

integer k0, kr0, n1, i, t, nb, nz, maxabs, v, bad, nz_before, nz_after, e_n_keep;
reg [15:0] bv16;
integer bgm_k0, sfx_k0;
integer left_bad;

// 欠载标志的接线：仿真里不会欠载，混音器给两个播放器的欠载标志一直是 0，接反看不出来。
// 播放器只在"播放中"才数欠载 → 两路都在播的时候做：先让 0 号路的标志来一个时钟（只有背景音乐的计数 +1），
// 再让 1 号路的来一个时钟（音效的计数 +1，背景音乐的不变）；整个窗口里两路必须一直在播（否则重来）；最后把计数恢复成原值。
task ur_wiring;
    reg [7:0] b0, s0;
    integer tries, done_ok, w;
    begin
        done_ok = 0;
        for (tries = 0; tries < 20 && done_ok == 0; tries = tries + 1) begin
            w = 0;
            while (!(bgm_state === 2'd2 && sfx_state === 2'd2) && w < 3_000_000) begin @(posedge clk); w = w + 1; end
            b0 = bgm_ur; s0 = sfx_ur;
            @(posedge clk); #1; force dut.S_ur0 = 1'b1; force dut.S_ur1 = 1'b0;
            @(posedge clk); #1; release dut.S_ur0; release dut.S_ur1;
            repeat (3) @(posedge clk);
            if (bgm_state === 2'd2 && sfx_state === 2'd2) begin
                if (bgm_ur !== b0 + 8'd1 || sfx_ur !== s0) begin
                    $display("FAIL [%0s] underrun wiring (mixer flag 0 only): bgm_ur %0d (expected %0d), sfx_ur %0d (expected %0d)", IMAGE, bgm_ur, b0 + 8'd1, sfx_ur, s0);
                    err = err + 1;
                end
                @(posedge clk); #1; force dut.S_ur0 = 1'b0; force dut.S_ur1 = 1'b1;
                @(posedge clk); #1; release dut.S_ur0; release dut.S_ur1;
                repeat (3) @(posedge clk);
                if (bgm_state === 2'd2 && sfx_state === 2'd2) begin
                    done_ok = 1;
                    if (bgm_ur !== b0 + 8'd1 || sfx_ur !== s0 + 8'd1) begin
                        $display("FAIL [%0s] underrun wiring (mixer flag 1 only): bgm_ur %0d (expected %0d), sfx_ur %0d (expected %0d)", IMAGE, bgm_ur, b0 + 8'd1, sfx_ur, s0 + 8'd1);
                        err = err + 1;
                    end
                end
            end
            // 把两个计数恢复成原值（force 过寄存器以后要先强制回原值再松开）
            force dut.u_p0.O_underrun = b0; force dut.u_p1.O_underrun = s0;
            @(posedge clk); #1; release dut.u_p0.O_underrun; release dut.u_p1.O_underrun;
            repeat (2) @(posedge clk);
        end
        if (done_ok == 0) begin $display("FAIL [%0s] underrun wiring check could not run (the two players were never both playing for the whole window)", IMAGE); err = err + 1; end
    end
endtask

// 播一个音效并逐帧核对右声道：曲目号、文件头长度、声道数、采样率
task play_check;
    input integer num, off, ch, rate;
    input [255:0] name;
    begin
        gen_expected(num, off, ch, rate); nz_before = nf; cmd_sfx(num); wait_sfx_idle; wait_frames(40);
        kr0 = first_nz_r(nz_before);
        if (kr0 < 0) begin $display("FAIL [%0s] no sound on the right channel: %0s", IMAGE, name); err = err + 1; end
        else check_stream(name, kr0, 1);
    end
endtask

initial begin
    fin = 0; err = 0;
    repeat (10) @(posedge clk); rst_n = 1;
    wire_en = 1;                                     // 复位一松开就核对连线（挂载和 ES8388 配置哪个先完成，连线都得对）

    // ---------- 1) 上电：准备好、背景音乐自动开始 ----------
    t = 0;
    while (!ready && t < 12_000_000) begin @(posedge clk); t = t + 1; end
    if (codec_state !== 2'd1) begin $display("FAIL [%0s] codec_state=%0d", IMAGE, codec_state); err = err + 1; end
    if (sd_state !== 3'd1)    begin $display("FAIL [%0s] sd_state=%0d", IMAGE, sd_state); err = err + 1; end
    if (nclips !== 8'd8)      begin $display("FAIL [%0s] nclips=%0d", IMAGE, nclips); err = err + 1; end
    if (!ready)               begin $display("FAIL [%0s] O_ready never became 1", IMAGE); err = err + 1; end
    if (spk !== 1'b1)         begin $display("FAIL [%0s] speaker amp enable not high", IMAGE); err = err + 1; end
    // 1.wav 的所有采样值（背景音乐的集合）
    load_file(1);
    for (bi = 0; bi < 400; bi = bi + 1) begin
        bv16 = filebytes[44 + 2*bi] | (filebytes[45 + 2*bi] << 8);
        bgm_set[bv16] = 1'b1;
    end
    bgm_set[0] = 1'b1;

    // <<AFTER-READY>>
    wait_bgm_playing;
    // <<ERRB>> 读错误的接线（端口 1）：仿真里 SD 卡从不出错，两个口的"读错误"一直是 0，接反 / 接常数看不出来。
    // 音效那一路此时空闲（空闲状态不理会读错误）：把端口 1 的读错误强制成 1、端口 0 的保持 0，核对各接收方只收到自己那一路的。
    force dut.S_f0_err = 1'b0; force dut.S_f1_err = 1'b1;
    repeat (3) @(posedge clk);
    wchk("err1.dir", dut.u_fat.u_dir.I_rd_err, 32'd0);
    wchk("err1.rd0", dut.u_fat.u_rd0.I_rd_err, 32'd0);
    wchk("err1.rd1", dut.u_fat.u_rd1.I_rd_err, 32'd1);
    release dut.S_f0_err; release dut.S_f1_err;
    repeat (3) @(posedge clk);
    // <<ERRB-END>>
    gen_expected(1, 44, 1, 16000);
    nb = ex_n;
    // 背景音乐第一遍：从第一个非零左帧开始逐帧核对；右声道（音效）整段静音
    wait_frames(nb + 200);
    k0 = first_nz_l(0);
    if (k0 < 0) begin $display("FAIL [%0s] no background music on the left channel", IMAGE); err = err + 1; end
    else begin
        bgm_k0 = k0;
        check_stream("BGM first pass (left)", k0, 0);
        check_silent("right channel silent while only the BGM plays", 0, k0 + nb, 1);
    end
    // 背景音乐循环：再等几遍，开始播放的次数 >= 3
    wait_frames(nb * 2 + 600);
    if (n_bgm_start < 3) begin $display("FAIL [%0s] background music did not loop (%0d starts)", IMAGE, n_bgm_start); err = err + 1; end
    if (bgm_ur !== 8'd0) begin $display("FAIL [%0s] background music underruns: %0d", IMAGE, bgm_ur); err = err + 1; end

    // ---------- 2) 音效 2.wav（48 kHz 立体声）和背景音乐同时播 ----------
    gen_expected(2, 44, 2, 48000);
    e_n_keep = ex_n;
    nz_before = nf;
    cmd_sfx(2);
    // 播放中再发新命令（播放 3.wav）应该被忽略
    wait_frames(150);
    ur_wiring;                                                      // 欠载标志的接线（两路都在播的时候）
    cmd_sfx(3);
    if (!sfx_busy) begin $display("FAIL [%0s] sound effect should be busy while playing", IMAGE); err = err + 1; end
    wait_frames(e_n_keep + 100);
    wait_sfx_idle;
    kr0 = first_nz_r(nz_before);
    if (kr0 < 0) begin $display("FAIL [%0s] no sound effect on the right channel", IMAGE); err = err + 1; end
    else begin
        check_stream("SFX 2.wav (48 kHz stereo -> right)", kr0, 1);
        check_silent("right channel after the effect ended (nothing replayed)", kr0 + ex_n, 150, 1);
        // 左声道只有背景音乐的值（或 0），没有串音
        left_bad = 0;
        for (i = kr0; i < kr0 + ex_n; i = i + 1) if (!bgm_set[fl[i]]) left_bad = left_bad + 1;
        if (left_bad != 0) begin $display("FAIL [%0s] %0d frames on the left channel are not background-music values (crosstalk)", IMAGE, left_bad); err = err + 1; end
    end

    // ---------- 3) 各种采样率的音效逐帧正确（右声道）----------
    play_check(3,  82, 1, 24000, "SFX 3.wav (24 kHz mono, LIST chunk)");
    play_check(4,  44, 1, 44100, "SFX 4.wav (44.1 kHz mono)");           // 目录里文件大小写成了 >= 16 MB
    play_check(5,  44, 2, 32000, "SFX 5.wav (32 kHz stereo)");           // 在目录的第 2 个簇里
    play_check(10, 44, 1, 12000, "SFX 10.wav (12 kHz mono)");

    // ---------- 4) 错误：不存在 / 头不对 / 采样率太高；出错不影响背景音乐，之后还能正常播 ----------
    nz = 0;
    cmd_sfx(6); wait_sfx_idle;
    if (sfx_state !== 2'd3 || sfx_err !== 8'd1) begin $display("FAIL [%0s] clip 6: state=%0d err=%0d, expected 3/1", IMAGE, sfx_state, sfx_err); err = err + 1; end
    cmd_sfx(7); wait_sfx_idle;
    if (sfx_state !== 2'd3 || sfx_err !== 8'd2) begin $display("FAIL [%0s] clip 7: state=%0d err=%0d, expected 3/2", IMAGE, sfx_state, sfx_err); err = err + 1; end
    cmd_sfx(8); wait_sfx_idle;
    if (sfx_state !== 2'd3 || sfx_err !== 8'd3) begin $display("FAIL [%0s] clip 8 (96 kHz): state=%0d err=%0d, expected 3/3", IMAGE, sfx_state, sfx_err); err = err + 1; end
    // 背景音乐一直在响
    nz_before = nf; wait_frames(1500);
    for (i = nz_before; i < nf; i = i + 1) if (fl[i] !== 16'd0) nz = nz + 1;
    if (nz < 800) begin $display("FAIL [%0s] background music stopped after SFX errors (%0d non-zero frames in 1500)", IMAGE, nz); err = err + 1; end
    if (bgm_err !== 8'd0) begin $display("FAIL [%0s] BGM error code %0d after SFX errors", IMAGE, bgm_err); err = err + 1; end
    // 出错以后还能正常播
    play_check(10, 44, 1, 12000, "SFX 10.wav after errors");
    if (sfx_err !== 8'd0) begin $display("FAIL [%0s] error code should be cleared by a new play (got %0d)", IMAGE, sfx_err); err = err + 1; end

    // <<ERRA>> 读错误的接线（端口 0）：放在最后做（背景音乐不能关，0 号口一直在读，强制读错误会打断背景音乐，所以之后不再核对播放）。
    //   强制端口 0 的读错误为 1、端口 1 的为 0，核对各接收方只收到自己那一路的。
    force dut.S_f0_err = 1'b1; force dut.S_f1_err = 1'b0;
    repeat (3) @(posedge clk);
    wchk("err0.dir", dut.u_fat.u_dir.I_rd_err, 32'd1);
    wchk("err0.rd0", dut.u_fat.u_rd0.I_rd_err, 32'd1);
    wchk("err0.rd1", dut.u_fat.u_rd1.I_rd_err, 32'd0);
    release dut.S_f0_err; release dut.S_f1_err;
    repeat (3) @(posedge clk);
    // <<ERRA-END>>

    if (lrck_bad != 0) begin $display("FAIL [%0s] LRCK period was not 2048 clocks in %0d frames", IMAGE, lrck_bad); err = err + 1; end
    if (wire_bad != 0) begin $display("FAIL [%0s] %0d wiring mismatches between the audio sub-blocks", IMAGE, wire_bad); err = err + 1; end
    fin = 1;
end

endmodule


module tb_audio;
wire f0, f1;
wire [31:0] e0, e1;
tb_audio_case #(.IMAGE("sd_mbr"),  .SDHC(1), .V2(1)) c0 (.fin(f0), .err(e0));
tb_audio_case #(.IMAGE("sd_flat"), .SDHC(0), .V2(0), .TRIES(150)) c1 (.fin(f1), .err(e1));   // 这张卡很慢：挂载在约 66 ms（每次 ACMD41 重试约 0.41 ms），比 ES8388 配置完成（约 45 ms）还晚
initial begin
    wait (f0 && f1);
    if (e0 + e1 == 0) $display("PASS  tb_audio");
    else              $display("FAIL  tb_audio: errors %0d %0d", e0, e1);
    $finish;
end
initial begin #4_000_000_000; $display("FAIL  tb_audio: timeout"); $finish; end
endmodule
