// t07 缓冲 / 移位寄存器的自检 tb：用数组记住输入过的数字，和模块逐拍比较
`timescale 1ns/1ns
module tb_t07;

reg clk = 1'b0, rst_n = 1'b0;
always #5 clk = ~clk;
integer errors = 0;
`define CHK(got, exp, name) if ((got) !== (exp)) begin errors = errors + 1; if (errors < 20) $display("[%0t] ERROR %0s: got %h exp %h", $time, name, got, exp); end

// ---- digit_buf4 ----
reg        push = 0, pop = 0, clear = 0;
reg  [3:0] din = 0;
wire [2:0]  len;
wire [15:0] data;
digit_buf4 u_buf (.clk(clk), .rst_n(rst_n), .push(push), .din(din), .pop(pop), .clear(clear), .len(len), .data(data));

reg [3:0] dig [0:3];   // 模型：按输入顺序存的数字
integer   mlen = 0, k, full_hits = 0, pw_ok = 0;
reg [15:0] mdata;
always @(posedge clk) if (rst_n) begin
    if (clear)                     mlen = 0;
    else if (pop)  begin if (mlen > 0) mlen = mlen - 1; end
    else if (push) begin if (mlen < 4) begin dig[mlen] = din; mlen = mlen + 1; end
                         else full_hits = full_hits + 1; end
end
always @(*) begin
    mdata = 16'h0000;
    for (k = 0; k < mlen; k = k + 1) mdata = mdata * 16 + dig[k];
end

// ---- sipo / piso ----
reg        s_en = 0, s_din = 0, p_load = 0;
reg  [7:0] p_din = 0;
wire [7:0] s_q;
wire       p_out;
sipo #(.W(8)) u_sipo (.clk(clk), .rst_n(rst_n), .en(s_en), .din(s_din), .q(s_q));
piso #(.W(8)) u_piso (.clk(clk), .rst_n(rst_n), .load(p_load), .din(p_din), .dout(p_out));

reg [7:0] m_sipo = 0;
reg [7:0] m_word = 0;
integer   m_pos = 8;       // piso：装入后已经移出了几位（8 = 全是 0）
always @(posedge clk) if (rst_n) begin
    if (s_en) m_sipo = {m_sipo[6:0], s_din};
    if (p_load) begin m_word = p_din; m_pos = 0; end
    else if (m_pos < 8) m_pos = m_pos + 1;
end

integer i;
initial begin
    repeat (2) @(negedge clk);
    rst_n = 1'b1;
    for (i = 0; i < 4000; i = i + 1) begin
        @(negedge clk);
        `CHK(len,  mlen[2:0], "len")
        `CHK(data, mdata,     "data")
        if (mlen == 4 && mdata == 16'h1234) pw_ok = pw_ok + 1;
        `CHK(s_q,  m_sipo, "sipo")
        `CHK(p_out, (m_pos < 8) ? m_word[7 - m_pos] : 1'b0, "piso")
        // 前一半：多 push；后一半：几乎只输入 1、2、3、4 → 能凑出 1234
        push  = ($random & 3) != 0;
        pop   = ($random & 7) == 0;
        clear = ($random & 31) == 0;
        din   = (i < 2000) ? $random : (mlen + 1);
        s_en  = $random;  s_din = $random;
        p_load = ($random & 15) == 0;  p_din = $random;
    end
    $display("push while full %0d times, password 1234 seen %0d times", full_hits, pw_ok);
    if (full_hits < 20 || pw_ok < 5) begin errors = errors + 1; $display("ERROR: weak coverage"); end
    if (errors == 0) $display("PASS tb_t07"); else $display("FAIL tb_t07: %0d errors", errors);
    $stop;
end

endmodule
