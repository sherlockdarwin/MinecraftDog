// 12 小时制电子钟（24 年能力测试 / 国赛测试1 题一）
// 1 拍 = 1 秒。i_rst 高有效、同步复位（tb 一开始 i_rst = 1），复位优先于使能
// o_hh / o_mm / o_ss 是两位 BCD：[7:4] 十位，[3:0] 个位。波形用十六进制看
module top(
    input          i_clk,
    input          i_rst,
    input          i_ena,
    output         o_pm,
    output [7 : 0] o_hh,
    output [7 : 0] o_mm,
    output [7 : 0] o_ss
);

reg [7:0] ss, mm, hh;
reg       pm;

wire ss_end = (ss == 8'h59);
wire mm_end = (mm == 8'h59);
wire hh_end = (hh == 8'h11);

// 秒：每拍走一格
always @(posedge i_clk) begin
    if (i_rst)                    ss <= 8'h00;
    else if (i_ena) begin
        if (ss_end)               ss <= 8'h00;
        else if (ss[3:0] == 4'd9) ss <= {ss[7:4] + 4'd1, 4'd0};
        else                      ss <= ss + 8'd1;
    end
end

// 分：秒 = 59 的那一拍走一格
always @(posedge i_clk) begin
    if (i_rst)                    mm <= 8'h00;
    else if (i_ena && ss_end) begin
        if (mm_end)               mm <= 8'h00;
        else if (mm[3:0] == 4'd9) mm <= {mm[7:4] + 4'd1, 4'd0};
        else                      mm <= mm + 8'd1;
    end
end

// 时：分、秒都是 59 的那一拍走一格，11 之后回 00
always @(posedge i_clk) begin
    if (i_rst)                    hh <= 8'h00;
    else if (i_ena && ss_end && mm_end) begin
        if (hh_end)               hh <= 8'h00;
        else if (hh[3:0] == 4'd9) hh <= {hh[7:4] + 4'd1, 4'd0};
        else                      hh <= hh + 8'd1;
    end
end

// 上午 / 下午：11:59:59 → 00:00:00 那一拍翻转
always @(posedge i_clk) begin
    if (i_rst)                                   pm <= 1'b0;
    else if (i_ena && ss_end && mm_end && hh_end) pm <= ~pm;
end

assign o_ss = ss;
assign o_mm = mm;
assign o_hh = hh;
assign o_pm = pm;

endmodule
