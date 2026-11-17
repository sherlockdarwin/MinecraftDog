// =============================================================================
// t07 移位寄存器 / 输入缓冲
//   digit_buf4  最多存 4 个数字：push 存一位（满了忽略）、pop 删最后一位（空了忽略）、clear 清空
//               密码锁那类"输入 + 退格 + 确认"就用它
//   sipo        串入并出：每拍移进 1 位
//   piso        并入串出：load 装入，之后每拍从最高位移出 1 位
// =============================================================================

module digit_buf4 (
    input             clk,
    input             rst_n,
    input             push,
    input      [3:0]  din,
    input             pop,
    input             clear,
    output reg [2:0]  len,         // 0~4
    output reg [15:0] data         // 右对齐：先输入的在高位。输入 1、2 → 16'h0012；输入 1~4 → 16'h1234
);
// 同一拍来多个命令时的优先级：clear > pop > push

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        len  <= 3'd0;
        data <= 16'h0000;
    end else if (clear) begin
        len  <= 3'd0;
        data <= 16'h0000;
    end else if (pop) begin
        if (len != 3'd0) begin
            len  <= len - 3'd1;
            data <= {4'h0, data[15:4]};        // 右移 4 位，丢掉最后输入的那位
        end
    end else if (push) begin
        if (len != 3'd4) begin
            len  <= len + 3'd1;
            data <= {data[11:0], din};          // 左移 4 位，新数字放最低 4 位
        end
    end
end

// 判断密码：wire ok = (len == 3'd4) && (data == 16'h1234);

endmodule


module sipo #(
    parameter W = 8
)(
    input              clk,
    input              rst_n,
    input              en,
    input              din,
    output reg [W-1:0] q           // 先进来的位在高位
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)  q <= 0;
    else if (en) q <= {q[W-2:0], din};
end

endmodule


module piso #(
    parameter W = 8
)(
    input          clk,
    input          rst_n,
    input          load,
    input  [W-1:0] din,
    output         dout            // 高位先出
);

reg [W-1:0] sh;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)    sh <= 0;
    else if (load) sh <= din;
    else           sh <= {sh[W-2:0], 1'b0};
end
assign dout = sh[W-1];

endmodule
