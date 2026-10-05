`timescale 1ns / 1ps
// 测试 mc_sd_spi + mc_fat32（挂载 + 目录表 + 读文件；这里只用 0 路，1 路见 tb_sdarb）（接一个行为级 SD 卡模型 sd_card_model，卡里是 tools/mk_sd_test_image.pl 生成的 FAT32 镜像）：
//   1) 卡初始化流程（CMD0 / CMD8 / ACMD41 / CMD58 / CMD16；V2 大容量卡、V1 字节寻址小卡两种）；
//   2) 挂载：带 MBR 分区表（分区从 LBA 2048 开始、每簇 2 扇区）和没有分区表（整盘一个卷、每簇 1 扇区）两种；
//   3) 根目录扫描：只认数字名的 .WAV（1、02、3、4、5、7、8、10），跳过已删除项 / 长文件名项 / 子目录 / 卷标 / NOTES.WAV / 99.WAV，
//      5.WAV 在根目录的第 2 个簇里（要沿目录的簇链找）→ O_nclips = 8；
//   4) 逐个打开曲目，送出来的字节流必须和文件内容逐字节一致（含碎片化的簇链、LIST 块等），字节数 = 文件大小，最后有 O_eof；
//      外面缓冲区"忙"的时候（I_space_ok 间歇为 0）不丢字节；
//   5) 打开不存在的编号 / 超范围的编号 → O_open_err（码 1）；中途 I_close → 停止送数据，之后还能重新打开；
//      打开后 1 ~ 6 拍就 I_close（落在查目录表的几拍里）也不能丢：不送数据、O_active 落下；
//   6) 没插卡 → 初始化失败（码 1）；卡里不是 FAT32（全零）→ 挂载失败（码 1）。
module tb_sdfat_case #(
    parameter IMAGE   = "sd_mbr",
    parameter SDHC    = 1,
    parameter V2      = 1,
    parameter MODE    = 0,              // 0 正常卡  1 没卡  2 全零的卡（没有文件系统）
    parameter FAILCODE = 0,             // 非 0：这张卡必须挂载失败，错误码 = FAILCODE（MODE 0 的卡，卡里的参数不合法）
    parameter QUICK   = 0,              // 1：只核对 1、2、5 号曲目（目录结构不同的卡，不用把所有曲目都读一遍）
    parameter WB      = 0,              // 1：最后再做白盒检查（每簇扇区数的合法性 / log2 查表逐值核对）
    parameter ERRN    = 0,              // 非 0：卡在第 ERRN 次读扇区时回错误（和 FAILCODE 配合：挂载期间的读错误 = 挂载失败码 4；挂载完成后的读错误 = 打开曲目 ERR_CLIP 时报码 4）
    parameter ERR_CLIP = 0,
    parameter EXPN    = 8,              // 这张卡上应该找到的曲目数
    parameter MOUNT_READS = 0,          // 非 0：挂载完成时卡一共被读了多少个扇区（按镜像的目录结构数出来的；多读 / 少读都不对：比如目录结束标记判断错了会一直扫到 255 个扇区的保险上限）
    parameter XCLIP   = 0               // 非 0：QUICK 模式下除了 1、2、5 以外再核对这一首（64.WAV = 最大的合法编号；4.WAV = 目录大小 >= 16 MB、簇链靠 FAT 项结束）
)(
    output reg        fin,
    output reg [31:0] err
);

reg clk = 0, rst_n = 0;
always #5 clk = ~clk;

reg tick1ms = 0;
integer tdiv = 0;
always @(posedge clk) begin
    tick1ms <= 1'b0;
    if (tdiv == 99_999) begin tdiv <= 0; tick1ms <= 1'b1; end
    else tdiv <= tdiv + 1;
end

wire cs_n, sck, mosi, miso_card;
wire miso = (MODE == 1) ? 1'b1 : miso_card;                    // 没卡：MISO 被上拉
wire sd_ready, sd_fail, sdhc;
wire [2:0] sd_fail_code;
wire rd_start, rd_busy, byte_valid, rd_done, rd_err;
wire [31:0] lba;
wire [7:0]  byte_d;
wire [8:0]  byte_idx;

mc_sd_spi sd (
    .I_clk(clk), .I_rst_n(rst_n), .I_tick_1ms(tick1ms),
    .O_cs_n(cs_n), .O_sck(sck), .O_mosi(mosi), .I_miso(miso),
    .I_init(1'b0), .O_ready(sd_ready), .O_fail(sd_fail), .O_fail_code(sd_fail_code), .O_sdhc(sdhc),
    .I_rd_start(rd_start), .I_lba(lba), .O_rd_busy(rd_busy),
    .O_byte_valid(byte_valid), .O_byte(byte_d), .O_byte_idx(byte_idx), .O_rd_done(rd_done), .O_rd_err(rd_err)
);

sd_card_model #(
    .IMAGE_FILE((MODE == 2) ? "blank_none.hex" : {IMAGE, ".hex"}), .SDHC(SDHC), .V2(V2), .ACMD41_TRIES(3), .READ_DELAY(5), .ERR_READ_N(ERRN)
) card (.cs_n(cs_n), .sck(sck), .mosi(mosi), .miso(miso_card));

wire mounted, mount_fail;
wire [2:0] mount_code;
wire [7:0] nclips;
reg        open_p = 0, close_p = 0;
reg  [6:0] clip = 0;
wire       open_err, data_valid, eof, active;
wire [2:0] err_code;
wire [7:0] data_b;
reg        space_ok = 1;

mc_fat32 fat (
    .I_clk(clk), .I_rst_n(rst_n),
    .I_sd_ready(sd_ready), .I_sd_fail(sd_fail),
    .O_rd_start0(rd_start), .O_lba0(lba), .I_rd_busy0(rd_busy),
    .I_byte_valid0(byte_valid), .I_byte0(byte_d), .I_byte_idx0(byte_idx), .I_rd_done0(rd_done), .I_rd_err0(rd_err),
    .O_rd_start1(), .O_lba1(), .I_rd_busy1(1'b0), .I_byte_valid1(1'b0), .I_byte1(8'd0), .I_byte_idx1(9'd0), .I_rd_done1(1'b0), .I_rd_err1(1'b0),
    .O_mounted(mounted), .O_mount_fail(mount_fail), .O_mount_code(mount_code), .O_nclips(nclips),
    .I_open0(open_p), .I_clip0(clip), .I_close0(close_p),
    .O_open_err0(open_err), .O_err_code0(err_code),
    .O_data_valid0(data_valid), .O_data0(data_b), .I_space_ok0(space_ok), .O_eof0(eof), .O_active0(active),
    .I_open1(1'b0), .I_clip1(7'd0), .I_close1(1'b0), .O_open_err1(), .O_err_code1(), .O_data_valid1(), .O_data1(), .I_space_ok1(1'b1), .O_eof1(), .O_active1()
);

// 外面缓冲区的"空位"：随机忙闲（50% 的时间忙）
integer rnd = 7;
always @(posedge clk) if (MODE == 0) space_ok <= (($random(rnd) & 32'h7FFF) % 100) < 55;

// ---------------- 收数据 ----------------
reg [7:0] got [0:8191];
integer   n_got = 0;
integer   n_eof = 0, n_operr = 0;
reg [2:0] last_operr_code = 0;
always @(posedge clk) begin
    if (data_valid) begin got[n_got] = data_b; n_got = n_got + 1; end
    if (eof) n_eof = n_eof + 1;
    if (open_err) begin n_operr = n_operr + 1; last_operr_code = err_code; end
end

reg [7:0] expd [0:8191];
integer sizes [0:127];
integer i;
reg [8*64-1:0] fname;
task load_expected;
    input integer num;
    integer fd, sz, c;
    begin
        for (i = 0; i < 8192; i = i + 1) expd[i] = 8'h00;
        $sformat(fname, "%0s_clip%0d.hex", IMAGE, num);
        $readmemh(fname, expd);
        $sformat(fname, "%0s_clip%0d.size", IMAGE, num);
        fd = $fopen(fname, "r");
        c = $fscanf(fd, "%d", sz);
        $fclose(fd);
        sizes[num] = sz;
    end
endtask

task open_clip;
    input integer num;
    begin
        n_got = 0; n_eof = 0; n_operr = 0;
        @(posedge clk); clip <= num; open_p <= 1'b1;
        @(posedge clk); open_p <= 1'b0;
    end
endtask

task wait_stream_end;                                            // 等 eof 或 open_err（带超时）
    integer t;
    begin
        t = 0;
        while (n_eof == 0 && n_operr == 0 && t < 3_000_000) begin @(posedge clk); t = t + 1; end
        if (t >= 3_000_000) begin $display("FAIL [%0s] stream timeout (got %0d bytes)", IMAGE, n_got); err = err + 1; end
        repeat (100) @(posedge clk);
    end
endtask

task check_clip;
    input integer num;
    integer k, bad;
    begin
        load_expected(num);
        open_clip(num);
        wait_stream_end;
        if (n_operr != 0) begin $display("FAIL [%0s] clip %0d: unexpected open error %0d", IMAGE, num, last_operr_code); err = err + 1; end
        if (n_eof != 1)   begin $display("FAIL [%0s] clip %0d: eof pulses %0d", IMAGE, num, n_eof); err = err + 1; end
        if (n_got != sizes[num]) begin $display("FAIL [%0s] clip %0d: got %0d bytes, expected %0d", IMAGE, num, n_got, sizes[num]); err = err + 1; end
        bad = 0;
        for (k = 0; k < n_got && k < sizes[num]; k = k + 1)
            if (got[k] !== expd[k]) begin
                if (bad < 3) $display("FAIL [%0s] clip %0d byte %0d: got %h expected %h", IMAGE, num, k, got[k], expd[k]);
                bad = bad + 1;
            end
        if (bad != 0) err = err + 1;
    end
endtask

integer t0, dly, v, lg, sv_spc, n17_b;
reg exp_ok;

// 白盒：读文件模块只在外面缓冲有空位（I_space_ok = 1）时才去读下一个数据扇区——进"读扇区"状态（ST_STR_RD = 5）的那一拍，前一拍的 space_ok 必须是 1
reg space_d = 1'b1;
integer n_space_bad = 0;
always @(posedge clk) begin
    space_d <= space_ok;
    if (fat.u_rd0.S_st == 4'd5 && !space_d) n_space_bad = n_space_bad + 1;
end
initial begin
    fin = 0; err = 0;
    repeat (10) @(posedge clk); rst_n = 1;

    if (MODE == 1) begin                                         // 没卡
        wait (sd_fail || mount_fail);
        repeat (1000) @(posedge clk);
        if (sd_fail_code !== 3'd1 || sd_ready) begin $display("FAIL no-card: fail=%b code=%0d ready=%b", sd_fail, sd_fail_code, sd_ready); err = err + 1; end
        if (mount_code !== 3'd4) begin $display("FAIL no-card: mount code %0d, expected 4 (read error)", mount_code); err = err + 1; end
        if (!mount_fail || mounted) begin $display("FAIL no-card: mount_fail=%b mounted=%b", mount_fail, mounted); err = err + 1; end
    end else if (MODE == 2) begin                                // 全零的卡
        wait (mount_fail || mounted);
        if (!mount_fail || mount_code !== 3'd1) begin $display("FAIL blank card: mount_fail=%b code=%0d", mount_fail, mount_code); err = err + 1; end
    end else if (FAILCODE != 0) begin                            // 卡里的参数不合法：必须挂载失败，并且错误码对
        wait (mount_fail || mounted || sd_fail);
        repeat (2000) @(posedge clk);
        if (!mount_fail || mounted || sd_fail || mount_code !== FAILCODE) begin
            $display("FAIL [%0s] expected mount failure code %0d: mount_fail=%b mounted=%b code=%0d sd_fail=%b", IMAGE, FAILCODE, mount_fail, mounted, mount_code, sd_fail);
            err = err + 1;
        end
    end else begin
        wait (mounted || mount_fail || sd_fail);
        if (!mounted || mount_fail || sd_fail) begin
            $display("FAIL [%0s] mount: mounted=%b mount_fail=%b code=%0d sd_fail=%b sd_code=%0d", IMAGE, mounted, mount_fail, mount_code, sd_fail, sd_fail_code);
            err = err + 1;
        end
        if (sdhc !== (SDHC != 0)) begin $display("FAIL [%0s] sdhc flag = %b", IMAGE, sdhc); err = err + 1; end
        if (nclips !== EXPN) begin $display("FAIL [%0s] nclips = %0d, expected %0d", IMAGE, nclips, EXPN); err = err + 1; end
        if (MOUNT_READS != 0 && card.n_cmd17 != MOUNT_READS) begin $display("FAIL [%0s] the card was read %0d times for the mount, expected %0d", IMAGE, card.n_cmd17, MOUNT_READS); err = err + 1; end
        $display("[%0s] mounted at %0t ns, nclips=%0d, CMD17 count so far %0d", IMAGE, $time, nclips, card.n_cmd17);

        if (ERRN != 0) begin                                      // 挂载完成以后的第 ERRN 次读扇区报错：读文件模块报"读卡错误"（码 4）、不送完整的文件、停下来；之后还能正常打开
            load_expected(ERR_CLIP);
            open_clip(ERR_CLIP);
            wait_stream_end;
            if (n_operr != 1 || last_operr_code !== 3'd4 || n_eof != 0) begin $display("FAIL [%0s] read error while streaming clip %0d: open_err pulses %0d code %0d eof pulses %0d (expected 1 / 4 / 0)", IMAGE, ERR_CLIP, n_operr, last_operr_code, n_eof); err = err + 1; end
            if (n_got >= sizes[ERR_CLIP]) begin $display("FAIL [%0s] the whole clip came out in spite of the read error", IMAGE); err = err + 1; end
            repeat (2000) @(posedge clk);
            if (active) begin $display("FAIL [%0s] still active after a read error", IMAGE); err = err + 1; end
            check_clip(1);
        end
        else if (QUICK != 0) begin check_clip(1); check_clip(2); check_clip(5); if (XCLIP != 0) check_clip(XCLIP); end
        else begin check_clip(1); check_clip(2); check_clip(3); check_clip(4); check_clip(5); check_clip(7); check_clip(8); check_clip(10); end

        if (QUICK == 0) begin
        // 不存在 / 超范围
        open_clip(6);  wait_stream_end;
        if (n_operr != 1 || last_operr_code !== 3'd1 || n_got != 0) begin $display("FAIL [%0s] clip 6 should give open_err 1", IMAGE); err = err + 1; end
        open_clip(99); wait_stream_end;
        if (n_operr != 1 || last_operr_code !== 3'd1) begin $display("FAIL [%0s] clip 99 should give open_err 1", IMAGE); err = err + 1; end
        open_clip(0);  wait_stream_end;
        if (n_operr != 1 || last_operr_code !== 3'd1) begin $display("FAIL [%0s] clip 0 should give open_err 1", IMAGE); err = err + 1; end

        // 中途关闭
        load_expected(2);
        open_clip(2);
        wait (n_got >= 700);
        @(posedge clk); close_p <= 1'b1; @(posedge clk); close_p <= 1'b0;
        repeat (200000) @(posedge clk);
        t0 = n_got;
        repeat (200000) @(posedge clk);
        if (n_got != t0) begin $display("FAIL [%0s] data kept flowing after close", IMAGE); err = err + 1; end
        if (active) begin $display("FAIL [%0s] still active after close", IMAGE); err = err + 1; end
        if (n_got >= sizes[2]) begin $display("FAIL [%0s] close came too late to test", IMAGE); err = err + 1; end
        check_clip(1);                                           // 关闭之后还能正常打开

        // 打开之后过 1 ~ 6 拍就关闭（落在查目录表 / 刚开始读的那几拍里）：关闭命令不能丢——不送数据、不报读完、不报错，O_active 落下；之后还能正常打开
        for (dly = 1; dly <= 6; dly = dly + 1) begin
            n_got = 0; n_eof = 0; n_operr = 0;
            n17_b = card.n_cmd17;
            @(posedge clk); clip <= 2; open_p <= 1'b1;
            @(posedge clk); open_p <= 1'b0;
            repeat (dly - 1) @(posedge clk);
            close_p <= 1'b1;
            @(posedge clk); close_p <= 1'b0;
            t0 = 0;
            while (active && t0 < 400_000) begin @(posedge clk); t0 = t0 + 1; end
            repeat (2000) @(posedge clk);
            if (active || n_got != 0 || n_eof != 0 || n_operr != 0) begin
                $display("FAIL [%0s] close %0d clocks after open: active=%b bytes=%0d eof=%0d operr=%0d", IMAGE, dly, active, n_got, n_eof, n_operr); err = err + 1;
            end
            if ((dly <= 2 && card.n_cmd17 != n17_b) || (card.n_cmd17 - n17_b > 1)) begin
                $display("FAIL [%0s] close %0d clocks after open: the card was read %0d times (a close before the first data sector must not start any read; later at most the one already started)", IMAGE, dly, card.n_cmd17 - n17_b); err = err + 1;
            end
        end
        check_clip(2);
        end                                                      // QUICK == 0

        if (WB != 0) begin
            // 白盒：每簇扇区数的合法性（S_spc_ok）和 log2 查表，逐值核对（镜像里只有 1 和 2 两种，其余的值靠这里直接查表）
            sv_spc = fat.u_dir.S_spc;
            for (v = 0; v < 256; v = v + 1) begin
                force fat.u_dir.S_spc = v;
                #1;
                exp_ok = (v == 1 || v == 2 || v == 4 || v == 8 || v == 16 || v == 32 || v == 64 || v == 128);
                if (fat.u_dir.S_spc_ok !== exp_ok) begin $display("FAIL [%0s] S_spc_ok for sectors-per-cluster %0d = %b, expected %b", IMAGE, v, fat.u_dir.S_spc_ok, exp_ok); err = err + 1; end
                if (exp_ok) begin
                    lg = 0; while ((1 << lg) < v) lg = lg + 1;
                    if (fat.u_dir.log2spc(v[7:0]) !== lg) begin $display("FAIL [%0s] log2(sectors-per-cluster %0d) = %0d, expected %0d", IMAGE, v, fat.u_dir.log2spc(v[7:0]), lg); err = err + 1; end
                end
            end
            release fat.u_dir.S_spc;
            fat.u_dir.S_spc = sv_spc;
        end
    end
    if (n_space_bad != 0) begin $display("FAIL [%0s] %0d data-sector reads started while the buffer had no space", IMAGE, n_space_bad); err = err + 1; end
    fin = 1;
end

endmodule


module tb_sdfat;
localparam N = 27;
wire [N-1:0] f;
wire [31:0] e [0:N-1];
// 正常的卡：MBR + SDHC、无分区表 + 字节寻址的小卡（WB：最后做白盒检查）
tb_sdfat_case #(.IMAGE("sd_mbr"),  .SDHC(1), .V2(1), .MODE(0), .WB(1), .MOUNT_READS(6)) c0 (.fin(f[0]), .err(e[0]));
tb_sdfat_case #(.IMAGE("sd_flat"), .SDHC(0), .V2(0), .MODE(0), .MOUNT_READS(4)) c1 (.fin(f[1]), .err(e[1]));
// 没卡 / 全零的卡
tb_sdfat_case #(.IMAGE("sd_mbr"),  .SDHC(1), .V2(1), .MODE(1)) c2 (.fin(f[2]), .err(e[2]));
tb_sdfat_case #(.IMAGE("sd_mbr"),  .SDHC(1), .V2(1), .MODE(2)) c3 (.fin(f[3]), .err(e[3]));
// 目录刚好填满它占的簇（没有 0x00 结尾项，靠 FAT 簇链的结尾标记知道目录到头）；只有 1 份 FAT（合法）
tb_sdfat_case #(.IMAGE("sd_full"),   .SDHC(1), .V2(1), .QUICK(1), .EXPN(9), .MOUNT_READS(8), .XCLIP(64)) c4 (.fin(f[4]), .err(e[4]));
tb_sdfat_case #(.IMAGE("sd_nfats1"), .SDHC(1), .V2(1), .QUICK(1), .MOUNT_READS(4)) c5 (.fin(f[5]), .err(e[5]));
// 挂载失败的各个出口：签名坏（没有分区表 → 1；分区的引导扇区 → 2；MBR → 1）、FAT 份数不对 / 每簇扇区数不是 2 的幂 / 根目录起始簇小于 2（→ 3）
tb_sdfat_case #(.IMAGE("sd_bsig_flat"), .SDHC(1), .V2(1), .FAILCODE(1)) c6  (.fin(f[6]),  .err(e[6]));
tb_sdfat_case #(.IMAGE("sd_bsig_vbr"),  .SDHC(1), .V2(1), .FAILCODE(2)) c7  (.fin(f[7]),  .err(e[7]));
tb_sdfat_case #(.IMAGE("sd_bsig_mbr"),  .SDHC(1), .V2(1), .FAILCODE(1)) c8  (.fin(f[8]),  .err(e[8]));
tb_sdfat_case #(.IMAGE("sd_nfats3"),    .SDHC(1), .V2(1), .FAILCODE(3)) c9  (.fin(f[9]),  .err(e[9]));
tb_sdfat_case #(.IMAGE("sd_spc3"),      .SDHC(1), .V2(1), .FAILCODE(3)) c10 (.fin(f[10]), .err(e[10]));
tb_sdfat_case #(.IMAGE("sd_root1"),     .SDHC(1), .V2(1), .FAILCODE(3)) c11 (.fin(f[11]), .err(e[11]));
// 读卡错误：第 N 次读扇区时卡回错误。挂载期间：第 1 次 = 第 0 扇区（MBR）、2 = 分区的引导扇区、3 = 根目录第 1 个扇区、5 = 目录簇链的 FAT 查询（都 = 挂载失败码 4）；
// 挂载完成以后（挂载用了 6 次读）：第 7 次 = 1 号曲目的第 1 个数据扇区、第 9 次 = 打开 2 号曲目（碎片化）时查 FAT 表（都 = 打开失败码 4）
tb_sdfat_case #(.IMAGE("sd_mbr"), .SDHC(1), .V2(1), .FAILCODE(4), .ERRN(1)) c12 (.fin(f[12]), .err(e[12]));
tb_sdfat_case #(.IMAGE("sd_mbr"), .SDHC(1), .V2(1), .FAILCODE(4), .ERRN(2)) c13 (.fin(f[13]), .err(e[13]));
tb_sdfat_case #(.IMAGE("sd_mbr"), .SDHC(1), .V2(1), .FAILCODE(4), .ERRN(3)) c14 (.fin(f[14]), .err(e[14]));
tb_sdfat_case #(.IMAGE("sd_mbr"), .SDHC(1), .V2(1), .FAILCODE(4), .ERRN(5)) c15 (.fin(f[15]), .err(e[15]));
tb_sdfat_case #(.IMAGE("sd_mbr"), .SDHC(1), .V2(1), .QUICK(1), .ERRN(7), .ERR_CLIP(1)) c16 (.fin(f[16]), .err(e[16]));
tb_sdfat_case #(.IMAGE("sd_mbr"), .SDHC(1), .V2(1), .QUICK(1), .ERRN(9), .ERR_CLIP(2)) c17 (.fin(f[17]), .err(e[17]));
// 各种"坏引导扇区"（签名第 1 字节坏 / 每扇区字节数不是 512 / FAT 大小为 0；无分区表的卷 f、分区里的卷 v、MBR m）：每个检查条件单独坏一次，必须挂载失败
tb_sdfat_case #(.IMAGE("sd_f_sig0"), .SDHC(1), .V2(1), .FAILCODE(1)) c18 (.fin(f[18]), .err(e[18]));
tb_sdfat_case #(.IMAGE("sd_v_sig0"), .SDHC(1), .V2(1), .FAILCODE(2)) c19 (.fin(f[19]), .err(e[19]));
tb_sdfat_case #(.IMAGE("sd_m_sig0"), .SDHC(1), .V2(1), .FAILCODE(1)) c20 (.fin(f[20]), .err(e[20]));
tb_sdfat_case #(.IMAGE("sd_f_bps"),  .SDHC(1), .V2(1), .FAILCODE(1)) c21 (.fin(f[21]), .err(e[21]));
tb_sdfat_case #(.IMAGE("sd_v_bps"),  .SDHC(1), .V2(1), .FAILCODE(2)) c22 (.fin(f[22]), .err(e[22]));
tb_sdfat_case #(.IMAGE("sd_f_fsz"),  .SDHC(1), .V2(1), .FAILCODE(1)) c23 (.fin(f[23]), .err(e[23]));
tb_sdfat_case #(.IMAGE("sd_v_fsz"),  .SDHC(1), .V2(1), .FAILCODE(2)) c24 (.fin(f[24]), .err(e[24]));
// 分区类型 0x0B（FAT32 CHS）也要认；损坏的卡：最后一个目录簇和 4.WAV 的簇链的 FAT 项是 1（保留簇号）：必须当作到头（不能跳到 1 号簇乱读）
tb_sdfat_case #(.IMAGE("sd_mbr0b"), .SDHC(1), .V2(1), .QUICK(1), .MOUNT_READS(6)) c25 (.fin(f[25]), .err(e[25]));
tb_sdfat_case #(.IMAGE("sd_free"),  .SDHC(1), .V2(1), .QUICK(1), .MOUNT_READS(8), .XCLIP(4)) c26 (.fin(f[26]), .err(e[26]));
integer ei, etot;
initial begin
    wait (&f);
    etot = 0;
    for (ei = 0; ei < N; ei = ei + 1) etot = etot + e[ei];
    if (etot == 0) $display("PASS  tb_sdfat");
    else           $display("FAIL  tb_sdfat: %0d errors", etot);
    $finish;
end
// 任何一个实例报错就马上结束（突变检查时省时间；全部通过时没有影响）
integer pi;
initial begin
    forever begin
        #20000;
        for (pi = 0; pi < N; pi = pi + 1) if (e[pi] != 0) begin $display("FAIL  tb_sdfat: instance %0d reported %0d errors, aborting early", pi, e[pi]); $finish; end
    end
end
initial begin #200_000_000; $display("FAIL  tb_sdfat: timeout"); $finish; end
endmodule
