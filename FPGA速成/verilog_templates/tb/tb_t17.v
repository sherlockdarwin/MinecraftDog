`timescale 1ns/1ns
module tb_t17;
reg  [7:0] in0, in1, in2, in3;
wire [7:0] out0, out1, out2, out3;
integer errors = 0;

sort4 dut(.in0(in0), .in1(in1), .in2(in2), .in3(in3),
          .out0(out0), .out1(out1), .out2(out2), .out3(out3));

// 每次改变输入后等 1 ns 再检查；波形里把输入和输出设置为 Unsigned。
initial begin
    // 一般乱序：7、2、9、4 → 2、4、7、9
    in0=7; in1=2; in2=9; in3=4;
    #1; if ({out0,out1,out2,out3} !== {8'd2,8'd4,8'd7,8'd9}) begin $display("FAIL case 1"); errors=errors+1; end

    // 倒序：9、7、4、2 → 2、4、7、9
    #9; in0=9; in1=7; in2=4; in3=2;
    #1; if ({out0,out1,out2,out3} !== {8'd2,8'd4,8'd7,8'd9}) begin $display("FAIL case 2"); errors=errors+1; end

    // 有重复值：5、5、2、5 → 2、5、5、5
    #9; in0=5; in1=5; in2=2; in3=5;
    #1; if ({out0,out1,out2,out3} !== {8'd2,8'd5,8'd5,8'd5}) begin $display("FAIL case 3"); errors=errors+1; end

    // 8 位边界值：255、0、128、1 → 0、1、128、255
    #9; in0=255; in1=0; in2=128; in3=1;
    #1; if ({out0,out1,out2,out3} !== {8'd0,8'd1,8'd128,8'd255}) begin $display("FAIL case 4"); errors=errors+1; end

    // 全部相等。
    #9; in0=4; in1=4; in2=4; in3=4;
    #1; if ({out0,out1,out2,out3} !== {8'd4,8'd4,8'd4,8'd4}) begin $display("FAIL case 5"); errors=errors+1; end

    if (errors == 0) $display("PASS tb_t17");
    else             $display("FAIL tb_t17 errors=%0d", errors);
    #9; $stop;
end
endmodule
