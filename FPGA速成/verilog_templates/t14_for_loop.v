// =============================================================================
// t14 for 循环
// 写法：integer i;  for (i = 0; i < 8; i = i + 1) begin ... end
//   · 循环变量用 integer；没有 i++，要写 i = i + 1
//   · 设计文件里：for 只能放在 always 里，次数必须是常数。它不是"一圈一圈执行"，
//     而是把循环体复制 8 份电路，同时工作。所以一般放在 always @(*) 里做组合逻辑，用 =
//   · tb 里：for 就是普通循环，可以配合 @(posedge clk)、#延时 一拍一拍地给输入
//   pop8   数 8 位里有几个 1
//   rev8   8 位倒序（a[0] ↔ a[7]）
// =============================================================================

module pop8 (
    input      [7:0] a,
    output reg [3:0] ones
);
integer i;
always @(*) begin
    ones = 4'd0;                   // 先清零，再逐位累加
    for (i = 0; i < 8; i = i + 1)
        ones = ones + a[i];
end
endmodule


module rev8 (
    input      [7:0] a,
    output reg [7:0] y
);
integer i;
always @(*) begin
    for (i = 0; i < 8; i = i + 1)
        y[i] = a[7 - i];
end
endmodule

// tb 里的 for：把 0~9 依次送进去，每拍一个
//   integer k;
//   initial begin
//       for (k = 0; k < 10; k = k + 1) begin
//           @(negedge clk);
//           din = k;
//       end
//   end
