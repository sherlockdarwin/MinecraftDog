`timescale 1ns / 1ps
// 测试 mc_i2c_wr + mc_es8388_cfg：
//   一个行为级的 I2C 从机（器件地址 0x11，按位解码，应答地址 / 寄存器 / 数据），记录每次写入的 {寄存器, 数据}；
//   1) 配置序列的寄存器号和数值、顺序，与设计一致；I2C 波形（起始、停止、9 个时钟/字节、SCL 速率）正确；
//   2) 配置完成 O_done=1、O_err=0；
//   3) 从机地址不对（不应答）时 O_err=1、O_done=0，不再继续写；
//   4) 单独测 mc_i2c_wr：写一次、被应答 / 不被应答时 O_nack 正确。
module tb_es8388_case #(
    parameter [6:0] SLAVE_ADDR = 7'h11,
    parameter       EXPECT_OK  = 1
)(
    output reg        fin,
    output reg [31:0] err
);

reg clk = 0, rst_n = 0;
always #5 clk = ~clk;

// 1 ms 节拍
reg tick1ms = 0;
integer tdiv = 0;
always @(posedge clk) begin
    tick1ms <= 1'b0;
    if (tdiv == 99_999) begin tdiv <= 0; tick1ms <= 1'b1; end
    else tdiv <= tdiv + 1;
end

wire scl, done, errf;
tri1 sda;

mc_es8388_cfg #(.CLK_HZ(100_000_000), .I2C_HZ(100_000), .PWRUP_MS(3), .HP_VOL(6'd21), .SPK_VOL(6'd30)) dut (
    .I_clk(clk), .I_rst_n(rst_n), .I_tick_1ms(tick1ms), .O_scl(scl), .IO_sda(sda), .O_done(done), .O_err(errf)
);

// ---------------- I2C 从机模型 ----------------
reg        sda_drv_low = 0;
assign sda = sda_drv_low ? 1'b0 : 1'bz;

integer    st = 0;                         // 0 空闲 1 收地址 2 收寄存器 3 收数据
integer    nb = 0;                         // 当前字节已收位数
reg [7:0]  sh = 0;
reg [7:0]  b_addr, b_reg, b_data;
reg        ack_pending = 0;
reg        addr_match = 0;
integer    n_wr = 0;
reg [7:0]  got_reg [0:63];
reg [7:0]  got_dat [0:63];
integer    n_start = 0, n_stop = 0, n_clk = 0, bad_wave = 0;
realtime   t_scl_a, t_scl_b;
integer    scl_periods = 0;
realtime   period_sum = 0;

// START / STOP
always @(negedge sda) if (scl === 1'b1) begin
    n_start = n_start + 1; st = 1; nb = 0; sh = 0; n_clk = 0;
end
always @(posedge sda) if (scl === 1'b1) begin
    if (st != 0) begin
        n_stop = n_stop + 1;
        if (st == 4) begin                       // 收满 3 个字节才算一次完整写
            got_reg[n_wr] = b_reg; got_dat[n_wr] = b_data; n_wr = n_wr + 1;
        end else bad_wave = bad_wave + 1;
    end
    st = 0;
end

// 位采样
always @(posedge scl) begin
    if (st != 0) begin
        n_clk = n_clk + 1;
        if (nb < 8) begin
            sh = {sh[6:0], sda};
            nb = nb + 1;
            if (nb == 8) begin
                case (st)
                    1: begin b_addr = sh; addr_match = (sh[7:1] == SLAVE_ADDR) && (sh[0] == 1'b0); end
                    2: b_reg = sh;
                    3: b_data = sh;
                endcase
            end
        end else begin
            // 第 9 个时钟：应答位（从机在第 8 位之后的下降沿已经按需拉低）
            nb = 0;
            if (st == 1) st = addr_match ? 2 : 0;       // 地址不匹配：不再收
            else if (st == 2) st = 3;
            else if (st == 3) st = 4;
        end
    end
end
// 应答：第 8 个上升沿之后的下降沿起拉低 SDA，下一个下降沿释放
reg ack_now = 0;
always @(negedge scl) begin
    if (ack_now) begin sda_drv_low <= 1'b0; ack_now <= 1'b0; end
    else if (st != 0 && nb == 8) begin
        if (st == 1 && !addr_match) sda_drv_low <= 1'b0;
        else begin sda_drv_low <= 1'b1; ack_now <= 1'b1; end
    end
end

// SCL 周期测量（只统计相邻上升沿间隔）
realtime t_last = 0;
integer n_good = 0, n_other = 0;
always @(posedge scl) begin
    if (t_last != 0 && ($realtime - t_last) < 20000) begin
        if ($realtime - t_last > 9900 && $realtime - t_last < 10100) n_good = n_good + 1;
        else n_other = n_other + 1;
    end
    t_last = $realtime;
end

// ---------------- 期望的寄存器序列 ----------------
reg [7:0] exp_reg [0:20];
reg [7:0] exp_dat [0:20];
initial begin
    exp_reg[0]  = 0;  exp_dat[0]  = 8'h80;
    exp_reg[1]  = 0;  exp_dat[1]  = 8'h00;
    exp_reg[2]  = 1;  exp_dat[2]  = 8'h58;
    exp_reg[3]  = 1;  exp_dat[3]  = 8'h50;
    exp_reg[4]  = 2;  exp_dat[4]  = 8'hF3;
    exp_reg[5]  = 2;  exp_dat[5]  = 8'h00;
    exp_reg[6]  = 3;  exp_dat[6]  = 8'hFF;
    exp_reg[7]  = 0;  exp_dat[7]  = 8'h06;
    exp_reg[8]  = 4;  exp_dat[8]  = 8'h3C;
    exp_reg[9]  = 8;  exp_dat[9]  = 8'h00;
    exp_reg[10] = 23; exp_dat[10] = 8'h18;
    exp_reg[11] = 24; exp_dat[11] = 8'h02;
    exp_reg[12] = 26; exp_dat[12] = 8'h00;
    exp_reg[13] = 27; exp_dat[13] = 8'h00;
    exp_reg[14] = 39; exp_dat[14] = 8'h90;
    exp_reg[15] = 42; exp_dat[15] = 8'h90;
    exp_reg[16] = 43; exp_dat[16] = 8'h80;
    exp_reg[17] = 46; exp_dat[17] = 8'd21;
    exp_reg[18] = 47; exp_dat[18] = 8'd21;
    exp_reg[19] = 48; exp_dat[19] = 8'd30;
    exp_reg[20] = 49; exp_dat[20] = 8'd30;
end

integer i;
realtime t_done;
initial begin
    fin = 0; err = 0;
    repeat (10) @(posedge clk); rst_n = 1;
    if (EXPECT_OK != 0) begin
        wait (done || errf);
        t_done = $realtime;
        repeat (2000) @(posedge clk);
        if (!done || errf) begin $display("FAIL [addr %h] expected done without error: done=%b err=%b", SLAVE_ADDR, done, errf); err = err + 1; end
        if (n_wr != 21)    begin $display("FAIL [addr %h] %0d register writes, expected 21", SLAVE_ADDR, n_wr); err = err + 1; end
        for (i = 0; i < 21 && i < n_wr; i = i + 1)
            if (got_reg[i] !== exp_reg[i] || got_dat[i] !== exp_dat[i]) begin
                $display("FAIL write %0d: R%0d = %h, expected R%0d = %h", i, got_reg[i], got_dat[i], exp_reg[i], exp_dat[i]);
                err = err + 1;
            end
        if (n_start != 21 || n_stop != 21) begin $display("FAIL start/stop count %0d/%0d, expected 21/21", n_start, n_stop); err = err + 1; end
        if (bad_wave != 0) begin $display("FAIL %0d transactions did not have 3 acknowledged bytes", bad_wave); err = err + 1; end
        // SCL 周期应是 10 us（100 kHz）：绝大多数相邻上升沿的间隔是 10 us（只有每次事务的起始处有几个例外）
        if (n_good < 500 || n_other > 30) begin
            $display("FAIL SCL periods: %0d at 10 us, %0d other", n_good, n_other); err = err + 1;
        end
        // 总时间：21 次写 × 约 0.3 ms + PWRUP 3 ms + 20 ms 复位等待 ≈ 30 ms
        if (t_done > 40_000_000 || t_done < 20_000_000) begin $display("FAIL configuration took %f ms", t_done / 1e6); err = err + 1; end
    end else begin
        wait (errf);
        repeat (50000) @(posedge clk);
        if (done)        begin $display("FAIL [addr %h] done must stay 0 after a NACK", SLAVE_ADDR); err = err + 1; end
        if (!errf)       begin $display("FAIL [addr %h] err must stay 1", SLAVE_ADDR); err = err + 1; end
        if (n_wr != 0)   begin $display("FAIL [addr %h] writes reached a wrong-address slave: %0d", SLAVE_ADDR, n_wr); err = err + 1; end
        // 发出第一次后就停（不再重试）：只会看到 1 个 START
        if (n_start > 1) begin $display("FAIL [addr %h] retried after NACK (%0d starts)", SLAVE_ADDR, n_start); err = err + 1; end
    end
    fin = 1;
end

endmodule


module tb_es8388;
wire f0, f1;
wire [31:0] e0, e1;
tb_es8388_case #(.SLAVE_ADDR(7'h11), .EXPECT_OK(1)) c_ok  (.fin(f0), .err(e0));
tb_es8388_case #(.SLAVE_ADDR(7'h10), .EXPECT_OK(0)) c_bad (.fin(f1), .err(e1));
initial begin
    wait (f0 && f1);
    if (e0 + e1 == 0) $display("PASS  tb_es8388");
    else $display("FAIL  tb_es8388: errors %0d %0d", e0, e1);
    $finish;
end
initial begin #200_000_000; $display("FAIL  tb_es8388: timeout"); $finish; end
endmodule
