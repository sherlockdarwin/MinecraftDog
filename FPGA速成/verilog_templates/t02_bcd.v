// =============================================================================
// t02 BCD 计数 / 码制转换 / 数码管
//   bcd2       两位 BCD 计数：00 → MAX → 00。MAX 用 8'hXX 写：秒 8'h59、12 小时 8'h11、24 小时 8'h23
//   clock_hms  时:分:秒 + 上下午：三个 bcd2 例化后串起来（例化的写法看这里）
//   bin2bcd99  0~99 二进制 → 两位 BCD（/ 和 % 写法）
//   bcd2bin99  两位 BCD → 二进制
//   bin2bcd8   0~255 二进制 → 三位 BCD（加 3 移位法，经典考题）
//   seg7       一位 BCD → 七段码（共阴，1 = 亮）
//   seg7_ca    一位 BCD → 七段码（共阳，0 = 亮）
// BCD：每 4 位存一个十进制数字。[7:4] 十位，[3:0] 个位。波形里用十六进制看就是十进制读数
// =============================================================================

module bcd2 #(
    parameter [7:0] MAX = 8'h59
)(
    input            clk,
    input            rst_n,
    input            en,           // 本级走一格（接上一级的 co）
    output reg [7:0] q,
    output           co            // 本级在 MAX 且 en → 下一级走一格
);

assign co = en && (q == MAX);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)                q <= 8'h00;
    else if (en) begin
        if (q == MAX)          q <= 8'h00;                     // 到顶回 00
        else if (q[3:0] == 4'd9) q <= {q[7:4] + 4'd1, 4'd0};   // x9 → 十位 +1，个位 0
        else                   q <= q + 8'd1;                  // 个位 +1
    end
end

endmodule


module clock_hms (
    input        clk,
    input        rst_n,
    input        en,               // 1 拍 = 1 秒
    output [7:0] hh,
    output [7:0] mm,
    output [7:0] ss,
    output       pm                // 0 上午 1 下午
);

wire co_s, co_m, co_h;

// 例化：模块名 #(.参数(值)) 实例名 (.端口(连到的信号), ...);
bcd2 #(.MAX(8'h59)) u_sec  (.clk(clk), .rst_n(rst_n), .en(en),   .q(ss), .co(co_s));
bcd2 #(.MAX(8'h59)) u_min  (.clk(clk), .rst_n(rst_n), .en(co_s), .q(mm), .co(co_m));
bcd2 #(.MAX(8'h11)) u_hour (.clk(clk), .rst_n(rst_n), .en(co_m), .q(hh), .co(co_h));

reg pm_r;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)    pm_r <= 1'b0;
    else if (co_h) pm_r <= ~pm_r;   // 11:59:59 → 00:00:00 那一拍翻转
end
assign pm = pm_r;

endmodule


module bin2bcd99 (
    input  [6:0] bin,              // 0~99
    output [7:0] bcd
);
wire [6:0] tens = bin / 7'd10;
wire [6:0] ones = bin % 7'd10;
assign bcd = {tens[3:0], ones[3:0]};   // 先取低 4 位再拼，直接拼 {bin/10, bin%10} 会是 14 位
endmodule


module bcd2bin99 (
    input  [7:0] bcd,
    output [6:0] bin
);
assign bin = bcd[7:4] * 7'd10 + bcd[3:0];
endmodule


module bin2bcd8 (
    input      [7:0]  bin,         // 0~255
    output reg [11:0] bcd          // [11:8] 百  [7:4] 十  [3:0] 个
);
integer i;
always @(*) begin
    bcd = 12'd0;
    for (i = 7; i >= 0; i = i - 1) begin
        // 每一位 >= 5 先加 3，再整体左移一位、移进 bin 的下一位
        if (bcd[3:0]  >= 4'd5) bcd[3:0]  = bcd[3:0]  + 4'd3;
        if (bcd[7:4]  >= 4'd5) bcd[7:4]  = bcd[7:4]  + 4'd3;
        if (bcd[11:8] >= 4'd5) bcd[11:8] = bcd[11:8] + 4'd3;
        bcd = {bcd[10:0], bin[i]};
    end
end
endmodule


module seg7 (
    input      [3:0] bcd,
    output reg [6:0] seg           // {g,f,e,d,c,b,a}，1 = 亮（共阴）；共阳看下面的 seg7_ca
);
always @(*) begin
    case (bcd)
        4'd0: seg = 7'h3F;
        4'd1: seg = 7'h06;
        4'd2: seg = 7'h5B;
        4'd3: seg = 7'h4F;
        4'd4: seg = 7'h66;
        4'd5: seg = 7'h6D;
        4'd6: seg = 7'h7D;
        4'd7: seg = 7'h07;
        4'd8: seg = 7'h7F;
        4'd9: seg = 7'h6F;
        default: seg = 7'h00;      // 非法值全灭
    endcase
end
endmodule


// 共阳数码管：段接低电平才亮，所以每个值正好是上面共阴表按位取反（~）
// 两种写法任选：
//   ① 例化上面的 seg7，再取反：  seg7 u_seg (.bcd(d), .seg(seg_cc));  assign seg_ca = ~seg_cc;
//   ② 直接用下面这张共阳表
module seg7_ca (
    input      [3:0] bcd,
    output reg [6:0] seg           // {g,f,e,d,c,b,a}，0 = 亮（共阳）
);
always @(*) begin
    case (bcd)
        4'd0: seg = 7'h40;         // = ~7'h3F
        4'd1: seg = 7'h79;
        4'd2: seg = 7'h24;
        4'd3: seg = 7'h30;
        4'd4: seg = 7'h19;
        4'd5: seg = 7'h12;
        4'd6: seg = 7'h02;
        4'd7: seg = 7'h78;
        4'd8: seg = 7'h00;
        4'd9: seg = 7'h10;
        default: seg = 7'h7F;      // 非法值全灭（共阳全 1 = 全灭）
    endcase
end
endmodule
