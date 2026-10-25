`timescale 1ns / 1ps
// 测试 mc_m0_link（和 MSPM0 的串口帧）+ mc_uart_rx。真实参数：100 MHz、115200、超时 300 个毫秒节拍（节拍由测试台加速给）。
//   收：测试台按位发字节（位宽可以偏 ±2%，可以故意把停止位发成 0、发短毛刺），字节之间留空闲或紧挨着（STM32 DMA），核对 O_tgt_ok / O_tgt_deg / O_tgt_cm：
//       $l12350& / $r05007& / 大写 / $S& 都要对；格式不对的整帧丢掉（错字符、少一位、多一位、方向错、$S 后面不是 &、
//       停止位错的字节、毛刺、冒号 / 斜杠（紧挨着数字的字符）），中途来 '$' 重新开始；停止位错以后线多低一个位，后面的帧照样收对；超时：最后一个有效帧之后第 300 个节拍才算丢，299 个节拍时还在。
//       O_rx_alive：复位后 0；任何完整字节（包括垃圾、$S&）都算，停止位错的字节和毛刺不算；最后一个字节之后第 300 个节拍变 0。
//   发：给 I_cmd_*，测试台自己的串口解码器（在位中间取样、核对停止位）收字符串，逐字符核对：
//       停 → "#S*"；各种正负、补零、最大值；发的时候再来命令不理；两帧之间线是高的。
module tb_m0_link;

reg clk = 0;
always #5 clk = ~clk;
reg rst_n = 0;
reg tick = 0;
reg rx = 1;
wire tx;
wire tgt_ok;
wire rx_alive;
wire signed [7:0] tgt_deg;
wire [9:0] tgt_cm;
reg cmd_valid = 0, cmd_stop = 0;
reg signed [13:0] cmd_l = 0, cmd_r = 0;

mc_m0_link dut (.I_clk(clk), .I_rst_n(rst_n), .I_tick_1ms(tick), .I_rx(rx), .O_tx(tx),
                .O_tgt_ok(tgt_ok), .O_tgt_deg(tgt_deg), .O_tgt_cm(tgt_cm), .O_rx_alive(rx_alive),
                .I_cmd_valid(cmd_valid), .I_cmd_stop(cmd_stop), .I_cmd_l(cmd_l), .I_cmd_r(cmd_r));

integer errors = 0;
always @(errors) if (errors > 20) begin #1; $display("FAIL  tb_m0_link: too many errors"); $finish; end

localparam real BIT_NS = 1.0e9 / 115200.0;
integer bk;
reg nogap = 0;                             // 1：字节之间不留空闲（STM32 的 DMA 发送就是这样：停止位一完就是下一个起始位）

// ---------------- 发字节（到 FPGA）----------------
task send_byte;
    input [7:0] b;
    input real scale;                      // 位宽倍数（1.0 = 准）
    input       bad_stop;                  // 1：停止位发 0
    integer k;
    begin
        rx = 0; #(BIT_NS * scale);
        for (k = 0; k < 8; k = k + 1) begin rx = b[k]; #(BIT_NS * scale); end
        rx = bad_stop ? 1'b0 : 1'b1; #(BIT_NS * scale);
        if (!nogap) begin rx = 1; #(BIT_NS * scale); end   // 一个位的空闲
    end
endtask
task send_str;                             // 字符串（最多 16 个字符，左对齐，空字符结束）
    input [8*16-1:0] s;
    input real scale;
    integer k;
    reg [7:0] c;
    begin
        for (k = 15; k >= 0; k = k - 1) begin
            c = s[8*k +: 8];
            if (c != 8'd0) send_byte(c, scale, 1'b0);
        end
    end
endtask
task expect_tgt;
    input ok;
    input integer deg, cm;
    input [8*40-1:0] what;
    begin
        repeat (20) @(posedge clk);
        if (tgt_ok !== ok || (ok && (tgt_deg !== deg || tgt_cm !== cm))) begin
            $display("FAIL rx %0s: ok %b deg %0d cm %0d, expected %b %0d %0d", what, tgt_ok, tgt_deg, tgt_cm, ok, deg, cm);
            errors = errors + 1;
        end
    end
endtask
task expect_link;                          // O_rx_alive（300 个节拍内收到过字节）
    input v;
    input [8*40-1:0] what;
    begin
        repeat (20) @(posedge clk);
        if (rx_alive !== v) begin $display("FAIL link %0s: rx_alive %b, expected %b", what, rx_alive, v); errors = errors + 1; end
    end
endtask
task ticks;
    input integer n;
    integer k;
    for (k = 0; k < n; k = k + 1) begin @(posedge clk) tick <= 1'b1; @(posedge clk) tick <= 1'b0; repeat (3) @(posedge clk); end
endtask

// ---------------- 收 FPGA 发出的字符 ----------------
reg [8*16-1:0] rxs;                        // 收到的字符串（新字符从低位进）
integer        nrx = 0, bad_frame = 0;
initial begin : decoder
    integer k;
    reg [7:0] c;
    forever begin
        @(negedge tx);
        #(BIT_NS / 2.0);
        if (tx !== 1'b0) begin $display("FAIL tx: start bit not low in the middle"); errors = errors + 1; end
        for (k = 0; k < 8; k = k + 1) begin #(BIT_NS); c[k] = tx; end
        #(BIT_NS);
        if (tx !== 1'b1) begin $display("FAIL tx: stop bit not high"); bad_frame = bad_frame + 1; errors = errors + 1; end
        rxs = {rxs[8*15-1:0], c}; nrx = nrx + 1;
    end
end
task send_cmd;
    input stop;
    input integer l, r;
    begin
        rxs = 0; nrx = 0;
        @(posedge clk); cmd_valid <= 1'b1; cmd_stop <= stop; cmd_l <= l; cmd_r <= r;
        @(posedge clk); cmd_valid <= 1'b0; cmd_l <= 14'sd1111; cmd_r <= -14'sd2222;   // 发的时候输入变了也不影响
    end
endtask
task expect_tx;                            // 等这一帧发完，核对字符串
    input [8*16-1:0] s;
    input integer n;
    integer t;
    begin
        t = 0;
        while (nrx < n && t < 2_000_000) begin @(posedge clk); t = t + 1; end
        #(BIT_NS * 3.0);
        if (nrx != n || rxs !== s) begin                  // 发之前清零：高位必须还是 0
            $display("FAIL tx: got %0d chars \"%0s\", expected \"%0s\"", nrx, rxs, s);
            errors = errors + 1;
        end
    end
endtask

initial begin
    repeat (10) @(posedge clk); rst_n = 1;
    repeat (100) @(posedge clk);
    if (tgt_ok !== 1'b0) begin $display("FAIL target valid after reset"); errors = errors + 1; end
    if (rx_alive !== 1'b0) begin $display("FAIL link alive after reset"); errors = errors + 1; end
    if (tx !== 1'b1) begin $display("FAIL tx not idle-high after reset"); errors = errors + 1; end

    // ---- 收 ----
    send_str("$l12350&", 1.0);  expect_tgt(1, -12, 350, "$l12350&");
    expect_link(1, "first frame");
    // STM32 的 DMA 发送：8 个字节紧挨着，两帧也可以紧挨着（位宽偏 ±2% 也要收对）
    nogap = 1;
    send_str("$r33444&", 1.0);          expect_tgt(1, 33, 444, "back-to-back bytes");
    send_str("$l01002&$r55666&", 1.02); expect_tgt(1, 55, 666, "two frames back-to-back, bits 2% long");
    send_str("$l77888&", 0.98);         expect_tgt(1, -77, 888, "back-to-back, bits 2% short");
    nogap = 0;
    send_str("$r05007&", 1.0);  expect_tgt(1, 5, 7, "$r05007&");
    send_str("$L99999&", 1.02); expect_tgt(1, -99, 999, "$L99999& (bits 2% long)");
    send_str("$R00000&", 0.98); expect_tgt(1, 0, 0, "$R00000& (bits 2% short)");
    send_str("$S&", 1.0);       expect_tgt(0, 0, 0, "$S&");
    send_str("$r40123&", 1.0);  expect_tgt(1, 40, 123, "$r40123&");
    send_str("$s&", 1.0);       expect_tgt(0, 0, 0, "$s&");
    send_str("$r40123&", 1.0);  expect_tgt(1, 40, 123, "again");
    // 格式不对：整帧丢掉（目标保持上一个）
    send_str("$l1x350&", 1.0);  expect_tgt(1, 40, 123, "bad digit");
    send_str("$l1:350&", 1.0);  expect_tgt(1, 40, 123, "colon is not a digit");
    send_str("$r40/23&", 1.0); expect_tgt(1, 40, 123, "slash is not a digit");
    send_str("$l1235&", 1.0);   expect_tgt(1, 40, 123, "too few digits");
    send_str("$l123500&", 1.0); expect_tgt(1, 40, 123, "too many digits");
    send_str("$x12350&", 1.0);  expect_tgt(1, 40, 123, "bad direction");
    send_str("$S0&", 1.0);      expect_tgt(1, 40, 123, "$S0&");
    send_str("l12350&", 1.0);   expect_tgt(1, 40, 123, "no $");
    send_str("$l12", 1.0); send_str("$r03100&", 1.0); expect_tgt(1, 3, 100, "restart on $");
    send_byte("$", 1.0, 0); send_byte("l", 1.0, 0); send_byte("1", 1.0, 0); send_byte("2", 1.0, 1);    // 停止位错的字节被丢掉
    send_str("350&", 1.0);      expect_tgt(1, 3, 100, "framing error");
    // 停止位是 0、线又多低了一个位（线回高之前不能把这段低电平当成新的起始位），之后的帧要收对
    rx = 0; #(BIT_NS); for (bk = 0; bk < 8; bk = bk + 1) begin rx = bk[0]; #(BIT_NS); end   // 起始位 + 一个字节
    rx = 0; #(BIT_NS * 2.0); rx = 1; #(BIT_NS * 2.0);                                        // 停止位是 0，紧接着又低一个位；然后空闲
    send_str("$r22123&", 1.0); expect_tgt(1, 22, 123, "frame after a long break");
    rx = 0; #(BIT_NS / 3.0); rx = 1; #(BIT_NS * 3.0);                                                 // 毛刺：不算起始位
    send_str("$l07042&", 1.0);  expect_tgt(1, -7, 42, "after a glitch");
    // 超时：299 个节拍还在，第 300 个没了；中途来帧重新计时
    ticks(299); expect_tgt(1, -7, 42, "299 ticks"); expect_link(1, "299 ticks");
    ticks(1);   expect_tgt(0, 0, 0, "300 ticks");   expect_link(0, "300 ticks");
    // 线是通的但没有有效帧（屏幕 LOST）：任何完整的字节都算；停止位错的字节、毛刺不算（屏幕 NOLK）
    rx = 0; #(BIT_NS / 3.0); rx = 1; #(BIT_NS * 3.0);                       expect_link(0, "glitch is not a byte");
    send_byte("z", 1.0, 1);                                                  expect_link(0, "byte with a bad stop bit");
    send_str("xyz", 1.0);  expect_tgt(0, 0, 0, "garbage");                  expect_link(1, "garbage bytes");
    ticks(250); send_str("$S&", 1.0); expect_tgt(0, 0, 0, "$S& keeps the link"); ticks(299); expect_link(1, "link timer restarted");
    ticks(1);                                                                expect_link(0, "link timed out");
    send_str("$r10200&", 1.0); ticks(250); send_str("$r11201&", 1.0); ticks(299); expect_tgt(1, 11, 201, "timer restarted");
    ticks(1); expect_tgt(0, 0, 0, "timed out again");
    expect_link(0, "link timed out with the target");

    // ---- 发 ----
    send_cmd(1, 0, 0);          expect_tx("#S*", 3);
    send_cmd(0, 3000, -500);    expect_tx("#+3000-0500*", 12);
    send_cmd(0, 0, 0);          expect_tx("#+0000+0000*", 12);
    send_cmd(0, -6500, 6500);   expect_tx("#-6500+6500*", 12);
    send_cmd(0, 9, -10);        expect_tx("#+0009-0010*", 12);
    send_cmd(0, 8191, -8192);   expect_tx("#+8191-8192*", 12);
    send_cmd(0, -1, 1234);      expect_tx("#-0001+1234*", 12);
    send_cmd(0, 4567, 9);
    repeat (50_000) @(posedge clk);                         // 发的时候来的命令不理
    @(posedge clk); cmd_valid <= 1'b1; cmd_stop <= 1'b1; @(posedge clk); cmd_valid <= 1'b0;
    expect_tx("#+4567+0009*", 12);
    repeat (300_000) @(posedge clk);
    if (nrx != 12) begin $display("FAIL tx: a command during sending was sent too (%0d chars)", nrx); errors = errors + 1; end
    send_cmd(1, 0, 0);          expect_tx("#S*", 3);

    if (errors == 0) $display("PASS  tb_m0_link");
    else             $display("FAIL  tb_m0_link: %0d error(s)", errors);
    $finish;
end

initial begin #200_000_000; $display("FAIL  tb_m0_link: timeout"); $finish; end

endmodule
