`timescale 1ns / 1ps
// 仿真用：会应答、并把每次写记下来的 I2C 从机（只支持"器件地址 + 2 字节寄存器地址 + 1 字节数据"的写）。
//   记录：n = 已记录的写次数；reg_log[i] = 寄存器地址，dat_log[i] = 数据，dev_log[i] = 器件地址字节，len_log[i] = 这次一共几个字节。
//   在 SCL 上升沿采样 SDA；每个字节第 8 位之后的下降沿拉低 SDA 应答，第 9 个时钟之后放开。
module i2c_rec_slave (
    input  wire scl,
    inout  wire sda
);
reg low = 1'b0;
assign sda = low ? 1'b0 : 1'bz;

reg        active = 1'b0;
integer    bitcnt = 0, nbytes = 0;
reg  [7:0] sh = 8'd0;
reg  [7:0] bytes [0:7];

integer    n = 0;
reg [15:0] reg_log [0:8191];
reg [7:0]  dat_log [0:8191];
reg [7:0]  dev_log [0:8191];
integer    len_log [0:8191];

always @(negedge sda) if (scl === 1'b1) begin active = 1'b1; bitcnt = 0; nbytes = 0; end     // START
always @(posedge sda) if (scl === 1'b1 && active) begin                                       // STOP
    reg_log[n] = {bytes[1], bytes[2]};
    dat_log[n] = bytes[3];
    dev_log[n] = bytes[0];
    len_log[n] = nbytes;
    n = n + 1;
    active = 1'b0;
end
always @(posedge scl) if (active) begin
    if (bitcnt < 8) sh = {sh[6:0], (sda === 1'b0) ? 1'b0 : 1'b1};
    bitcnt = bitcnt + 1;
end
always @(negedge scl) if (active) begin
    if (bitcnt == 8) begin
        low <= 1'b1;
        if (nbytes < 8) bytes[nbytes] = sh;
        nbytes = nbytes + 1;
    end else if (bitcnt == 9) begin
        low <= 1'b0;
        bitcnt = 0;
    end
end
endmodule
