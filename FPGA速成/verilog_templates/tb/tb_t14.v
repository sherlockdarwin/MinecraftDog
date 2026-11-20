// t14 for 循环的自检 tb：0~255 全部取值，期望值用移位一位一位数出来
`timescale 1ns/1ns
module tb_t14;

reg  [7:0] a;
wire [3:0] ones;
wire [7:0] y;
pop8 u_pop (.a(a), .ones(ones));
rev8 u_rev (.a(a), .y(y));

integer v, n, errors = 0;
reg [7:0] r, t;
initial begin
    for (v = 0; v < 256; v = v + 1) begin
        a = v;
        #1;
        n = 0; t = v; r = 8'd0;
        repeat (8) begin            // 每次看最低位，再右移
            n = n + t[0];
            r = {r[6:0], t[0]};     // 先拿到的最低位最后落在最高位
            t = t >> 1;
        end
        if (ones !== n) begin errors = errors + 1; $display("ERROR pop8(%b) = %0d, expect %0d", a, ones, n); end
        if (y !== r)    begin errors = errors + 1; $display("ERROR rev8(%b) = %b, expect %b", a, y, r); end
    end
    if (errors == 0) $display("PASS tb_t14"); else $display("FAIL tb_t14: %0d errors", errors);
    $stop;
end

endmodule
