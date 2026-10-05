`timescale 1ns / 1ps
// 测试 mc_uart_tx（8N1，LSB 先发）：发一串字节，用测试台自己的解码器从线上收回来核对内容；
// 检查起始位 / 停止位、每一位的宽度（= CLK_HZ / BAUD 个时钟）、一个字节占 10 位时间、发送期间 O_ready = 0、
// 空闲时线是高电平，以及"valid 在忙的时候来"不会被收下（握手规则）。
module tb_uart;

localparam CLK_HZ = 100_000_000;
localparam BAUD   = 115200;
localparam DIV    = CLK_HZ / BAUD;                  // 868 个时钟 / 位
localparam BIT_NS = DIV * 10;                       // 8680 ns（时钟 10 ns）

reg        clk = 0;
reg        rst_n = 0;
reg  [7:0] tx_data = 0;
reg        tx_valid = 0;
wire       tx_ready;
wire       tx_line;

always #5 clk = ~clk;

mc_uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_tx (
    .I_clk(clk), .I_rst_n(rst_n), .I_data(tx_data), .I_valid(tx_valid), .O_ready(tx_ready), .O_tx(tx_line)
);

integer errors = 0;

// 发一个字节（遵守 ready/valid 握手）
task send;
    input [7:0] b;
    begin
        wait (tx_ready);
        @(posedge clk); tx_data <= b; tx_valid <= 1'b1;
        @(posedge clk); tx_valid <= 1'b0;
        @(posedge clk);
    end
endtask

// 线上解码（独立实现）：每个下降沿 = 起始位，在每位中间采样
reg [7:0] mon_b;
integer   mon_n = 0;
integer   mon_bad = 0;
reg [7:0] mon [0:63];
real      t_start [0:63];
initial begin
    forever begin
        @(negedge tx_line);
        t_start[mon_n] = $realtime;
        t_fall = $realtime;
        #(BIT_NS / 2);
        if (tx_line !== 1'b0) mon_bad = mon_bad + 1;
        begin : mon_bits
            integer i;
            for (i = 0; i < 8; i = i + 1) begin
                #(BIT_NS);
                mon_b[i] = tx_line;
            end
            #(BIT_NS);
            if (tx_line !== 1'b1) mon_bad = mon_bad + 1;        // 停止位
        end
        mon[mon_n] = mon_b; mon_n = mon_n + 1;
    end
end

// 每次线电平变化都必须落在"起始沿 + 整数个位时间"上（精确到 1 个时钟）
real    t_fall = -1.0e9;                         // 当前字节起始位的下降沿（只在解码器认出起始位时更新，数据位的下降沿不算）
integer edge_bad = 0;
always @(tx_line) begin : wchk
    real d;
    integer q;
    d = $realtime - t_fall;
    if (d > 0.0 && d < 9.5 * BIT_NS) begin
        q = d / BIT_NS;                                 // real → integer 是四舍五入
        if (d - q * BIT_NS > 10.0 || q * BIT_NS - d > 10.0) edge_bad = edge_bad + 1;
    end
end

// 发送期间 O_ready 必须为 0；空闲（ready = 1）时线必须为高
integer ready_bad = 0;
always @(posedge clk) if (rst_n && tx_ready && tx_line !== 1'b1) ready_bad = ready_bad + 1;

integer i, n0;
real    dt;
reg [7:0] pat [0:7];
initial begin
    pat[0] = 8'h55; pat[1] = 8'hAA; pat[2] = 8'h00; pat[3] = 8'hFF;
    pat[4] = 8'h6B; pat[5] = 8'hF3; pat[6] = 8'h01; pat[7] = 8'h80;

    repeat (10) @(posedge clk);
    if (tx_line !== 1'b1) begin $display("FAIL line not idle-high in reset"); errors = errors + 1; end
    rst_n = 1; repeat (10) @(posedge clk);

    for (i = 0; i < 8; i = i + 1) send(pat[i]);
    wait (tx_ready);
    repeat (2 * DIV) @(posedge clk);

    if (mon_n !== 8) begin $display("FAIL wire count %0d expected 8", mon_n); errors = errors + 1; end
    for (i = 0; i < 8; i = i + 1)
        if (mon[i] !== pat[i]) begin $display("FAIL tx wire[%0d]=%h expected %h", i, mon[i], pat[i]); errors = errors + 1; end
    // 背靠背：下一字节的起始沿 = 上一字节起始沿 + 10 位 + 握手的几个时钟（send 里 3 个时钟以内）
    for (i = 1; i < 8; i = i + 1) begin
        dt = t_start[i] - t_start[i-1];
        if (dt < 10.0 * BIT_NS || dt > 10.0 * BIT_NS + 60.0) begin
            $display("FAIL byte %0d spacing %0f ns (expected 10 bits)", i, dt); errors = errors + 1;
        end
    end
    if (mon_bad !== 0)   begin $display("FAIL tx waveform: %0d bad start/stop bits", mon_bad); errors = errors + 1; end
    if (edge_bad !== 0)  begin $display("FAIL tx bit width: %0d edges off the bit grid", edge_bad); errors = errors + 1; end
    if (ready_bad !== 0) begin $display("FAIL line low while ready (%0d)", ready_bad); errors = errors + 1; end

    // 忙的时候来的 valid 不能被收下：发 0x3C 的同时（下一拍）再给 valid + 0xC3，应只发出 0x3C
    n0 = mon_n;
    wait (tx_ready);
    @(posedge clk); tx_data <= 8'h3C; tx_valid <= 1'b1;
    @(posedge clk); tx_data <= 8'hC3;                     // valid 继续为 1，此时已经忙
    repeat (DIV) @(posedge clk); tx_valid <= 1'b0;
    wait (tx_ready); repeat (2 * DIV) @(posedge clk);
    if (mon_n !== n0 + 1 || mon[n0] !== 8'h3C) begin
        $display("FAIL busy-time valid accepted (bytes %0d, first %h)", mon_n - n0, mon[n0]); errors = errors + 1;
    end

    if (errors == 0) $display("PASS  tb_uart");
    else             $display("FAIL  tb_uart: %0d errors", errors);
    $finish;
end

initial begin #50_000_000; $display("FAIL  tb_uart: timeout"); $finish; end

endmodule
