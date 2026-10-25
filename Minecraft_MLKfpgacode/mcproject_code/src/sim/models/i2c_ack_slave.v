`timescale 1ns / 1ps
// 仿真用：一个"什么都应答"的 I2C 从机（只数时钟：每个字节的第 9 个时钟拉低 SDA 给应答）。
module i2c_ack_slave (
    input  wire scl,
    inout  wire sda
);
reg low = 1'b0;
assign sda = low ? 1'b0 : 1'bz;
integer cnt = 0;
reg active = 1'b0;
always @(negedge sda) if (scl === 1'b1) begin active = 1'b1; cnt = -1; end      // START（随后主机把 SCL 拉低，算第 0 个下降沿）
always @(posedge sda) if (scl === 1'b1) begin active = 1'b0; end                // STOP
always @(negedge scl) begin
    if (active) begin
        if (low) begin low <= 1'b0; cnt = cnt + 1; end                          // 应答时钟结束：释放 SDA
        else begin
            cnt = cnt + 1;
            if ((cnt % 9) == 8) low <= 1'b1;                                    // 第 8 位结束：开始应答
        end
    end
end
endmodule
