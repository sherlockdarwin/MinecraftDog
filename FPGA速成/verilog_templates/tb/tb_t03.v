// t03 状态机的自检 tb：三段式、一段式两个模块，和"剩余时间倒计数"的参考模型逐拍比较
`timescale 1ns/1ns
module tb_t03;

reg clk = 1'b0, rst_n = 1'b0;
always #5 clk = ~clk;
integer errors = 0;
`define CHK(got, exp, name) if ((got) !== (exp)) begin errors = errors + 1; if (errors < 20) $display("[%0t] ERROR %0s: got %0d exp %0d", $time, name, got, exp); end

reg        skip = 1'b0;
wire [1:0] light3, light1;
wire       go3, go1;
fsm_timer      u3 (.clk(clk), .rst_n(rst_n), .skip(skip), .light(light3), .ped_go(go3));
fsm_timer_1seg u1 (.clk(clk), .rst_n(rst_n), .skip(skip), .light(light1), .ped_go(go1));

// 参考模型：st = 灯色，rem = 这个颜色还剩几拍
localparam G = 0, Y = 1, R = 2;
integer st = R, rem = 10, i, n_skip = 0, n_g = 0;
always @(posedge clk) if (rst_n) begin
    if (st == G && skip) begin
        st = Y; rem = 3; n_skip = n_skip + 1;
    end else begin
        rem = rem - 1;
        if (rem == 0) begin
            case (st)
                G: begin st = Y; rem = 3;  end
                Y: begin st = R; rem = 10; end
                R: begin st = G; rem = 10; n_g = n_g + 1; end
            endcase
        end
    end
end

initial begin
    repeat (2) @(negedge clk);
    rst_n = 1'b1;
    for (i = 0; i < 5000; i = i + 1) begin
        @(negedge clk);
        `CHK(light3, st, "light 3seg")
        `CHK(light1, st, "light 1seg")
        `CHK(go3, (st == R), "ped_go 3seg")
        `CHK(go1, (st == R), "ped_go 1seg")
        skip = (i < 600) ? 1'b0 : (($random & 15) == 0);   // 前 600 拍不打断，先看完整周期
    end
    $display("skip taken %0d times, green entered %0d times", n_skip, n_g);
    if (n_skip < 20) begin errors = errors + 1; $display("ERROR: too few skips exercised"); end
    if (errors == 0) $display("PASS tb_t03"); else $display("FAIL tb_t03: %0d errors", errors);
    $stop;
end

endmodule
