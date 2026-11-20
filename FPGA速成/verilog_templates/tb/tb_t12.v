// t12 RAM / FIFO 的自检 tb：RAM 用数组模型，FIFO 用"队列"模型（头尾两个整数）
`timescale 1ns/1ns
module tb_t12;

reg clk = 1'b0, rst_n = 1'b0;
always #5 clk = ~clk;
integer errors = 0;
`define CHK(got, exp, name) if ((got) !== (exp)) begin errors = errors + 1; if (errors < 20) $display("[%0t] ERROR %0s: got %0d exp %0d", $time, name, got, exp); end

// ---- RAM ----
reg        we = 0;
reg  [3:0] addr = 0;
reg  [7:0] din = 0;
wire [7:0] dout;
ram_sp #(.AW(4), .DW(8)) u_ram (.clk(clk), .we(we), .addr(addr), .din(din), .dout(dout));

reg [7:0] m_mem [0:15];
reg [7:0] m_dout;
integer   ram_ready = 0;          // 先把 16 个地址都写一遍，之后读出来才有确定值
always @(posedge clk) begin
    m_dout = m_mem[addr];          // 读到的是写之前的值
    if (we) m_mem[addr] = din;
end

// ---- FIFO（深度 8）----
reg        wr = 0, rd = 0;
reg  [7:0] fdin = 0;
wire [7:0] fdout;
wire       full, empty;
wire [3:0] count;
fifo_sync #(.AW(3), .DW(8)) u_fifo (.clk(clk), .rst_n(rst_n), .wr_en(wr), .din(fdin), .rd_en(rd),
                                     .dout(fdout), .full(full), .empty(empty), .count(count));

reg [7:0] q [0:1023];
integer   head = 0, tail = 0, n_full = 0, n_empty_rd = 0, n_both = 0, i;
always @(posedge clk) if (rst_n) begin
    if (rd && (tail - head) > 0) head = head + 1;           // 先按"沿之前"的个数判断能不能读
    if (wr && (tail - (head - ((rd && (tail - head) > 0) ? 1 : 0))) < 8) begin
        q[tail % 1024] = fdin; tail = tail + 1;
    end
    if (wr && rd) n_both = n_both + 1;
end

initial begin
    repeat (2) @(negedge clk);
    rst_n = 1'b1;
    for (i = 0; i < 6000; i = i + 1) begin
        @(negedge clk);
        if (i > 17) `CHK(dout, m_dout, "ram dout")
        `CHK(count, (tail - head), "fifo count")
        `CHK(full,  ((tail - head) == 8), "fifo full")
        `CHK(empty, ((tail - head) == 0), "fifo empty")
        if (tail - head > 0) `CHK(fdout, q[head % 1024], "fifo dout")
        if (tail - head == 8) n_full = n_full + 1;
        // RAM：前 16 拍按地址顺序写满，之后随机读写
        we   = (i < 16) ? 1'b1 : $random;
        addr = (i < 16) ? i : $random;
        din  = $random;
        // FIFO：分段改变读写比例，让它满、空都出现
        wr   = (i % 400 < 200) ? (($random & 3) != 0) : (($random & 3) == 0);
        rd   = (i % 400 < 200) ? (($random & 3) == 0) : (($random & 3) != 0);
        if (rd && tail == head) n_empty_rd = n_empty_rd + 1;
        fdin = $random;
    end
    $display("fifo full %0d cycles, read while empty %0d, read+write same cycle %0d", n_full, n_empty_rd, n_both);
    if (n_full < 50 || n_empty_rd < 50 || n_both < 200) begin errors = errors + 1; $display("ERROR: weak coverage"); end
    if (errors == 0) $display("PASS tb_t12"); else $display("FAIL tb_t12: %0d errors", errors);
    $stop;
end

endmodule
