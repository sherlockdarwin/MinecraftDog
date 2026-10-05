`timescale 1ns / 1ps
// 仿真用替身：代替 TD 生成的 blk_mem_gen_awb_delay_signal（里面是 PH1P_LOGIC_ERAM 原语，Icarus 仿真不了）。
// 和 IP 的配置一致：简单双口，A 口写、B 口读，读出不加输出寄存器（NOREG）= 读地址打一拍后出数据。
module blk_mem_gen_awb_delay_signal (
    output [95:0] doa,
    input  [95:0] dia,
    input  [10:0] addra,
    input         wea,
    input         clka,
    output reg [95:0] dob,
    input  [10:0] addrb,
    input         clkb,
    input  [95:0] dib,
    input         web
);
reg [95:0] mem [0:2047];
assign doa = 96'd0;
always @(posedge clka) if (wea) mem[addra] <= dia;
always @(posedge clkb) dob <= mem[addrb];
endmodule
