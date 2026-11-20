// =============================================================================
// t17 排序：4 个无符号数，从小到大排列（组合逻辑）
// 输入 in0~in3 同时给出；输出 out0 最小、out3 最大；相等的数据也保留。
// 没有 clk：输入变化后组合逻辑重新计算，不需要等时钟；本例不是串行逐拍输入。
// 方法：类似冒泡排序，相邻两个数比较，大的放右边。一共比较 3+2+1 次。
// W=8 时每个数 0~255；这是无符号比较，负数需要另行使用 signed。
// =============================================================================
module sort4 #(
    parameter W = 8
)(
    input      [W-1:0] in0, in1, in2, in3,
    output reg [W-1:0] out0, out1, out2, out3
);

reg [W-1:0] temp;  // 交换时暂存一个数

always @(*) begin
    // 先复制输入，下面只交换输出中的值；组合块用阻塞赋值 =。
    out0 = in0; out1 = in1; out2 = in2; out3 = in3;
    temp = {W{1'b0}};

    // 第 1 轮：最大的数被交换到最右侧。
    if (out0 > out1) begin temp = out0; out0 = out1; out1 = temp; end
    if (out1 > out2) begin temp = out1; out1 = out2; out2 = temp; end
    if (out2 > out3) begin temp = out2; out2 = out3; out3 = temp; end

    // 第 2 轮：在前 3 个数中，最大的数放到 out2。
    if (out0 > out1) begin temp = out0; out0 = out1; out1 = temp; end
    if (out1 > out2) begin temp = out1; out1 = out2; out2 = temp; end

    // 第 3 轮：排好前两个数。
    if (out0 > out1) begin temp = out0; out0 = out1; out1 = temp; end
end
endmodule
