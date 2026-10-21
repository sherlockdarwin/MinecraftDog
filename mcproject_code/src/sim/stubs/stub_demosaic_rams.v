`timescale 1ns / 1ps
// 仿真用替身：代替 TD 生成的 blk_mem_gen_demosaic / blk_mem_gen_zhenghe（里面是 ERAM 原语，Icarus 仿真不了）。
// 和 IP 的配置一致：A 口写、B 口读，读出不加输出寄存器（NOREG）= 读地址打一拍后出数据。
module blk_mem_gen_demosaic (
    input  [32:0] dia,
    input  [10:0] addra,
    input         wea,
    input         clka,
    input  [10:0] addrb,
    input         clkb,
    input  [32:0] dib,
    input         web,
    output [32:0] doa,
    output reg [32:0] dob
);
reg [32:0] mem [0:2047];
assign doa = 33'd0;
always @(posedge clka) if (wea) mem[addra] <= dia;
always @(posedge clkb) dob <= mem[addrb];
endmodule

module blk_mem_gen_zhenghe (
    input  [31:0] dia,
    input  [10:0] addra,
    input         wea,
    input         clka,
    input  [10:0] addrb,
    input         clkb,
    input  [31:0] dib,
    input         web,
    output [31:0] doa,
    output reg [31:0] dob
);
reg [31:0] mem [0:2047];
assign doa = 32'd0;
always @(posedge clka) if (wea) mem[addra] <= dia;
always @(posedge clkb) dob <= mem[addrb];
endmodule
