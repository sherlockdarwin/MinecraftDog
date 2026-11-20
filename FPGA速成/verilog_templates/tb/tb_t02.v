// t02 BCD 的自检 tb：时钟按总秒数推算期望值；码制转换全部取值穷举
`timescale 1ns/1ns
module tb_t02;

reg clk = 1'b0, rst_n = 1'b0;
always #5 clk = ~clk;
integer errors = 0;
`define CHK(got, exp, name) if ((got) !== (exp)) begin errors = errors + 1; if (errors < 20) $display("[%0t] ERROR %0s: got %h exp %h", $time, name, got, exp); end

// ---- 时:分:秒 ----
reg        en = 1'b0;
wire [7:0] hh, mm, ss;
wire       pm;
clock_hms u_clk (.clk(clk), .rst_n(rst_n), .en(en), .hh(hh), .mm(mm), .ss(ss), .pm(pm));

// ---- 24 小时的一位 bcd2（随机使能） ----
reg        en24 = 1'b0;
wire [7:0] h24;
wire       co24;
bcd2 #(.MAX(8'h23)) u_h24 (.clk(clk), .rst_n(rst_n), .en(en24), .q(h24), .co(co24));

// 十进制数 → 两位 BCD（用减法数十位，和被测模块的写法不同）
function [7:0] to_bcd(input integer v);
    integer t;
    begin
        t = 0;
        while (v >= 10) begin v = v - 10; t = t + 1; end
        to_bcd = t * 16 + v;
    end
endfunction

integer secs = 0, m24 = 0, i;
always @(posedge clk) if (rst_n) begin
    if (en)   secs = secs + 1;
    if (en24) m24  = (m24 + 1) % 24;
end

// ---- 组合的转换模块 ----
reg  [6:0]  b99;
wire [7:0]  b99_bcd;
reg  [7:0]  bcd_in;
wire [6:0]  bcd_bin;
reg  [7:0]  b8;
wire [11:0] b8_bcd;
reg  [3:0]  sd;
wire [6:0]  seg, seg_ca;
bin2bcd99 u_b2b  (.bin(b99), .bcd(b99_bcd));
bcd2bin99 u_bb   (.bcd(bcd_in), .bin(bcd_bin));
bin2bcd8  u_b8   (.bin(b8), .bcd(b8_bcd));
seg7      u_seg  (.bcd(sd), .seg(seg));
seg7_ca   u_seg_ca (.bcd(sd), .seg(seg_ca));

// 七段码期望值：按"哪几段亮"的字母表拼出来
function [6:0] seg_exp(input [3:0] d);
    reg [8*7-1:0] s;
    integer k;
    begin
        case (d)
            0: s = "abcdef";  1: s = "bc";     2: s = "abdeg";  3: s = "abcdg";
            4: s = "bcfg";    5: s = "acdfg";  6: s = "acdefg"; 7: s = "abc";
            8: s = "abcdefg"; 9: s = "abcdfg"; default: s = "";
        endcase
        seg_exp = 7'd0;
        for (k = 0; k < 7; k = k + 1)
            if (s[k*8 +: 8] >= "a" && s[k*8 +: 8] <= "g")
                seg_exp[s[k*8 +: 8] - "a"] = 1'b1;
    end
endfunction

integer h, t, o;
initial begin
    // 组合模块：穷举
    for (i = 0; i < 100; i = i + 1) begin
        b99 = i; #1;
        `CHK(b99_bcd, to_bcd(i), "bin2bcd99")
        bcd_in = to_bcd(i); #1;
        `CHK(bcd_bin, i[6:0], "bcd2bin99")
    end
    for (i = 0; i < 256; i = i + 1) begin
        b8 = i; #1;
        h = i / 100; t = (i / 10) % 10; o = i % 10;
        `CHK(b8_bcd, (h * 256 + t * 16 + o), "bin2bcd8")
    end
    for (i = 0; i < 16; i = i + 1) begin
        sd = i; #1;
        `CHK(seg, seg_exp(i), "seg7")
        `CHK(seg_ca, ~seg_exp(i), "seg7_ca")
    end

    // 时钟：一直使能，跑过两次上下午切换；中间关一段使能
    @(negedge clk);
    rst_n = 1'b1;
    for (i = 0; i < 100000; i = i + 1) begin
        @(negedge clk);
        `CHK(ss, to_bcd(secs % 60), "ss")
        `CHK(mm, to_bcd((secs / 60) % 60), "mm")
        `CHK(hh, to_bcd((secs / 3600) % 12), "hh")
        `CHK(pm, (secs / 43200) % 2, "pm")
        `CHK(h24, to_bcd(m24), "h24")
        en   = !(i >= 50000 && i < 50100);
        en24 = $random;
    end
    if (errors == 0) $display("PASS tb_t02"); else $display("FAIL tb_t02: %0d errors", errors);
    $stop;
end

endmodule
