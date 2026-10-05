`timescale 1ns / 1ps
// 测试文字层：mc_osd_clear + 直接往写总线上写字符 → mc_osd_text（字符 RAM + 渲染）
//   1) 字符 RAM 里的内容是否与期望一致（清屏、写入、覆盖、最后一个格子、越界的写请求被忽略、复位后整框重清）；
//   2) 对整个文字框做一遍光栅扫描，逐像素与"期望的字符 + 字库"算出来的像素比较（检查延迟对齐、放大、坐标换算）；
//   3) 把前几行文字用 ASCII 字符画打印出来，肉眼确认字形没有镜像/倒置。
module tb_osd;

localparam X0 = 40, Y0 = 640, COLS = 45, ROWS = 8, SH = 1;

reg  pclk = 0, sclk = 0, rst_n = 0;
always #7.5 pclk = ~pclk;               // ≈ 66.7 MHz 像素时钟
always #5   sclk = ~sclk;               // 100 MHz 系统时钟

reg  [10:0] x = 0, y = 0;
wire        hit, on;
wire [19:0] b0, b7;

mc_osd_clear #(.ROWS(ROWS), .COLS(COLS)) u_clr (.I_clk(sclk), .I_rst_n(rst_n), .I_bus(20'd0), .O_bus(b0));

// 写总线：清屏在写时让它先过，否则轮到测试台的写请求；格式 {we, row[3:0], col[6:0], char[7:0]}
reg  [19:0] wr_bus = 20'd0;
assign b7 = b0[19] ? b0 : wr_bus;

task wr;                                     // 往第 row 行第 col 列写一个字符（一个时钟）
    input integer row, col;
    input [7:0] ch;
    begin
        @(posedge sclk); wr_bus <= {1'b1, row[3:0], col[6:0], ch};
        @(posedge sclk); wr_bus <= 20'd0;
    end
endtask
task wr_str;                                 // 写一个字符串
    input integer row, col;
    input [8*16-1:0] s;
    input integer len;
    integer k;
    begin
        for (k = 0; k < len; k = k + 1) wr(row, col + k, s[(len-1-k)*8 +: 8]);
    end
endtask

mc_osd_text #(.X0(X0), .Y0(Y0), .COLS(COLS), .ROWS(ROWS), .SCALE_SH(SH)) dut (
    .I_pclk(pclk), .I_x(x), .I_y(y), .O_hit(hit), .O_on(on), .I_wclk(sclk), .I_wbus(b7)
);

integer errors = 0;

// ---- 期望的字符内容 ----
reg [7:0] exp_ch [0:ROWS*COLS-1];
integer i;
task exp_clear; begin for (i = 0; i < ROWS*COLS; i = i + 1) exp_ch[i] = 8'h20; end endtask
task exp_put;
    input integer row, col;
    input [8*16-1:0] s;
    input integer len;
    integer k;
    begin
        for (k = 0; k < len; k = k + 1) exp_ch[row*COLS + col + k] = s[(len-1-k)*8 +: 8];
    end
endtask

task check_ram;
    input [255:0] name;
    integer r, c, bad;
    begin
        bad = 0;
        for (r = 0; r < ROWS; r = r + 1)
            for (c = 0; c < COLS; c = c + 1)
                if (dut.S_mem[r*COLS + c] !== exp_ch[r*COLS + c]) begin
                    if (bad < 8) $display("FAIL [%0s] ram[%0d,%0d] = %h ('%c'), expected %h ('%c')", name, r, c,
                                          dut.S_mem[r*COLS+c], dut.S_mem[r*COLS+c], exp_ch[r*COLS+c], exp_ch[r*COLS+c]);
                    bad = bad + 1;
                end
        if (bad != 0) begin errors = errors + bad; end
    end
endtask

// ---- 字库（TB 里另起一个 ROM 实例，预读成数组）----
reg  [10:0] f_addr = 0;
wire [7:0]  f_data;
reg  fclk = 0;
mc_font8x16 u_font_tb (.I_clk(fclk), .I_addr(f_addr), .O_data(f_data));
reg [7:0] font_tb [0:2047];
initial begin : load_font
    integer a;
    for (a = 0; a < 2048; a = a + 1) begin
        f_addr = a; #1 fclk = 1; #1 fclk = 0; #1;
        font_tb[a] = f_data;
    end
end

// ---- 期望像素 ----
function exp_hit_f; input integer px, py;
    begin exp_hit_f = (px >= X0) && (px < X0 + COLS*8*(1<<SH)) && (py >= Y0) && (py < Y0 + ROWS*16*(1<<SH)); end
endfunction
function exp_on_f; input integer px, py;
    integer dx, dy, col, row, bx, ly;
    reg [7:0] ch, bits;
    begin
        if (!exp_hit_f(px, py)) exp_on_f = 1'b0;
        else begin
            dx = px - X0; dy = py - Y0;
            col = dx / (8 << SH); row = dy / (16 << SH);
            bx = (dx / (1 << SH)) % 8; ly = (dy / (1 << SH)) % 16;
            ch = exp_ch[row*COLS + col];
            bits = font_tb[{ch[6:0], ly[3:0]}];
            exp_on_f = bits[7 - bx];
        end
    end
endfunction

// 4 拍延迟的期望值流水
reg [4:0] hit_pipe, on_pipe;
integer pix_bad = 0;
integer pix_cnt = 0;
reg     scanning = 0;
always @(posedge pclk) begin
    hit_pipe <= {hit_pipe[3:0], exp_hit_f(x, y)};
    on_pipe  <= {on_pipe[3:0],  exp_on_f(x, y)};
    if (scanning) begin
        pix_cnt <= pix_cnt + 1;
        if (pix_cnt > 8 && (hit !== hit_pipe[3] || on !== on_pipe[3])) pix_bad <= pix_bad + 1;
    end
end

// 字符画：记录 on 到 art[row][ln][col*8+px]
reg art [0:ROWS*16*COLS*8-1];
reg [10:0] xh [0:4];
reg [10:0] yh [0:4];
always @(posedge pclk) begin
    xh[4] <= xh[3]; xh[3] <= xh[2]; xh[2] <= xh[1]; xh[1] <= xh[0]; xh[0] <= x;
    yh[4] <= yh[3]; yh[3] <= yh[2]; yh[2] <= yh[1]; yh[1] <= yh[0]; yh[0] <= y;
end
always @(posedge pclk) begin : capture
    integer dx, dy;
    if (scanning && hit) begin
        dx = xh[3] - X0; dy = yh[3] - Y0;
        if (dx % (1 << SH) == 0 && dy % (1 << SH) == 0)
            art[((dy >> SH) * COLS * 8) + (dx >> SH)] = on;
    end
end

task raster;
    integer yy, xx;
    begin
        scanning = 1; pix_cnt = 0; pix_bad = 0;
        for (yy = Y0 - 6; yy < Y0 + ROWS*16*(1<<SH) + 6; yy = yy + 1)
            for (xx = X0 - 6; xx < X0 + COLS*8*(1<<SH) + 6; xx = xx + 1) begin
                @(posedge pclk); x <= xx; y <= yy;
            end
        repeat (10) @(posedge pclk);
        scanning = 0;
        if (pix_bad != 0) begin $display("FAIL raster: %0d of %0d pixels differ from expectation", pix_bad, pix_cnt); errors = errors + 1; end
    end
endtask

task print_art;
    input integer row;
    input integer ncols;
    integer ln, c;
    reg [8*400-1:0] line;
    begin
        for (ln = 0; ln < 16; ln = ln + 1) begin
            $write("   |");
            for (c = 0; c < ncols*8; c = c + 1) $write("%s", art[(row*16 + ln) * COLS * 8 + c] ? "#" : ".");
            $write("|\n");
        end
    end
endtask

initial begin
    exp_clear;
    #100 rst_n = 1;
    repeat (3000) @(posedge sclk);                       // 复位后清屏 360 个字符（约 400 个时钟）
    check_ram("cleared after reset");

    // ---------- 第一轮：写字符串、数字、最后一个格子 ----------
    wr_str(0, 0, "Hello FPGA", 10);
    wr_str(1, 2, "MinecraftDog v1", 15);
    wr_str(2, 0, "-0042", 5);
    wr_str(2, 10, "   123", 6);
    wr_str(3, 0, "BEEF", 4);
    wr_str(4, 0, "ABCD", 4);
    wr(7, 44, "Z");                                       // 最后一行最后一列
    wr(0, 44, "Y");                                       // 第一行最后一列（下一个地址是第 1 行第 0 列）
    wr(5, 0, "A");                                        // 第 5 行第一列
    exp_put(0, 0, "Hello FPGA", 10);
    exp_put(1, 2, "MinecraftDog v1", 15);
    exp_put(2, 0, "-0042", 5);
    exp_put(2, 10, "   123", 6);
    exp_put(3, 0, "BEEF", 4);
    exp_put(4, 0, "ABCD", 4);
    exp_put(7, 44, "Z", 1);
    exp_put(0, 44, "Y", 1);
    exp_put(5, 0, "A", 1);
    repeat (50) @(posedge sclk);
    check_ram("round1");

    // ---------- 越界的写请求必须被忽略（不能折回到别的格子）----------
    wr(0, 45, "X");                                       // 列 45 = 刚好越界（地址会落到下一行第 0 列）
    wr(0, 127, "X");
    wr(8, 0, "X");                                        // 行 8 = 刚好越界
    wr(15, 44, "X");
    wr(15, 127, "X");
    repeat (50) @(posedge sclk);
    check_ram("out-of-range writes ignored");

    raster;
    $display("---- 第 0 行（前 12 个字符）----"); print_art(0, 12);
    $display("---- 第 2 行（前 16 个字符）----"); print_art(2, 16);

    // ---------- 第二轮：覆盖 ----------
    wr_str(2, 0, "+9999", 5);
    wr_str(2, 10, "     7", 6);
    wr_str(4, 0, "WXYZ", 4);
    exp_put(2, 0, "+9999", 5);
    exp_put(2, 10, "     7", 6);
    exp_put(4, 0, "WXYZ", 4);
    repeat (50) @(posedge sclk);
    check_ram("round2 overwrite");
    raster;

    // ---------- 复位（整机复位）以后整个文字框重新清一遍（包括第 0 行）----------
    @(posedge sclk); rst_n <= 0; repeat (5) @(posedge sclk); rst_n <= 1;
    repeat (3000) @(posedge sclk);
    for (i = 0; i < ROWS*COLS; i = i + 1) exp_ch[i] = 8'h20;
    check_ram("reset clears the whole box");

    // ---------- 清完以后又能写（写请求没有被清屏吞掉）----------
    wr_str(1, 2, "MinecraftDog v1", 15);
    wr(7, 44, "Z");
    exp_put(1, 2, "MinecraftDog v1", 15);
    exp_put(7, 44, "Z", 1);
    repeat (50) @(posedge sclk);
    check_ram("write after reset-clear");
    raster;

    if (errors == 0) $display("PASS  tb_osd");
    else             $display("FAIL  tb_osd: %0d errors", errors);
    $finish;
end

initial begin #2_000_000_000; $display("FAIL  tb_osd: timeout"); $finish; end

endmodule
