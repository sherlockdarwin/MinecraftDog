// t08 定时 / 冷却的自检 tb：记"在第几拍开始"，按定义算 busy / accept
`timescale 1ns/1ns
module tb_t08;

reg clk = 1'b0, rst_n = 1'b0;
always #5 clk = ~clk;
integer errors = 0;
`define CHK(got, exp, name) if ((got) !== (exp)) begin errors = errors + 1; if (errors < 20) $display("[%0t] ERROR %0s: got %0d exp %0d", $time, name, got, exp); end

reg  start = 0, req = 0, cond = 0;
wire busy, done, accept;
hold_n   #(.N(10), .W(8)) u_hold (.clk(clk), .rst_n(rst_n), .start(start), .busy(busy), .done(done));
cooldown #(.N(18), .W(8)) u_cd   (.clk(clk), .rst_n(rst_n), .req(req), .cond(cond), .accept(accept));

// cyc = 当前是复位后的第几拍（每个上升沿 +1）
integer cyc = 0;
integer h_start = -1000;     // hold：最近一次被接受的 start 所在的拍
integer c_acc   = -1000;     // cooldown：最近一次 accept 所在的拍
integer n_hold = 0, n_acc = 0, n_blocked = 0, i;

function m_busy(input integer c); m_busy = (c > h_start) && (c <= h_start + 10); endfunction
function m_cool(input integer c); m_cool = (c > c_acc)   && (c <= c_acc + 18);  endfunction

always @(posedge clk) if (rst_n) begin
    // 这一拍（cyc）的输入在这个沿被采样
    if (start && !m_busy(cyc)) begin h_start = cyc; n_hold = n_hold + 1; end
    if (req && cond && !m_cool(cyc)) begin c_acc = cyc; n_acc = n_acc + 1; end
    else if (req && cond) n_blocked = n_blocked + 1;
    cyc = cyc + 1;
end

initial begin
    repeat (2) @(negedge clk);
    rst_n = 1'b1;
    for (i = 0; i < 5000; i = i + 1) begin
        @(negedge clk);
        `CHK(busy, m_busy(cyc), "busy")
        `CHK(done, (m_busy(cyc) && cyc == h_start + 10), "done")
        start = ($random & 7) == 0;
        req   = ($random & 7) == 0;
        cond  = ($random & 3) != 0;
        #1;
        `CHK(accept, (req && cond && !m_cool(cyc)), "accept")
    end
    $display("hold started %0d, cooldown accepted %0d, blocked %0d", n_hold, n_acc, n_blocked);
    if (n_hold < 50 || n_acc < 50 || n_blocked < 50) begin errors = errors + 1; $display("ERROR: weak coverage"); end
    if (errors == 0) $display("PASS tb_t08"); else $display("FAIL tb_t08: %0d errors", errors);
    $stop;
end

endmodule
