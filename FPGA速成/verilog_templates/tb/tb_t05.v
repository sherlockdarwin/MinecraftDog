// t05 分频的自检 tb：量输出的周期和高电平宽度（时钟周期 10 ns）
`timescale 1ns/1ns

// 量一个信号：每个上升沿之间应该隔 N*10 ns，高电平应该是 HIGH ns
module chk_div #(parameter N = 4, parameter HIGH = 20) (input sig);
    integer t_rise = -1, n_rise = 0, errors = 0;
    always @(posedge sig) begin
        if (t_rise >= 0 && ($time - t_rise) != N * 10) begin
            errors = errors + 1;
            if (errors < 5) $display("[%0t] ERROR %m period %0d exp %0d", $time, $time - t_rise, N * 10);
        end
        t_rise = $time;
        n_rise = n_rise + 1;
    end
    always @(negedge sig) begin
        if (t_rise >= 0 && ($time - t_rise) != HIGH) begin
            errors = errors + 1;
            if (errors < 5) $display("[%0t] ERROR %m high %0d exp %0d", $time, $time - t_rise, HIGH);
        end
    end
endmodule

module tb_t05;

reg clk = 1'b0, rst_n = 1'b0;
always #5 clk = ~clk;

wire e2, e4, e6, o3, o5, o7, tk;
div_even #(.N(2), .W(4)) u_e2 (.clk(clk), .rst_n(rst_n), .clk_out(e2));
div_even #(.N(4), .W(4)) u_e4 (.clk(clk), .rst_n(rst_n), .clk_out(e4));
div_even #(.N(6), .W(4)) u_e6 (.clk(clk), .rst_n(rst_n), .clk_out(e6));
div_odd  #(.N(3), .W(4)) u_o3 (.clk(clk), .rst_n(rst_n), .clk_out(o3));
div_odd  #(.N(5), .W(4)) u_o5 (.clk(clk), .rst_n(rst_n), .clk_out(o5));
div_odd  #(.N(7), .W(4)) u_o7 (.clk(clk), .rst_n(rst_n), .clk_out(o7));
tick_gen #(.N(5), .W(4)) u_tk (.clk(clk), .rst_n(rst_n), .tick(tk));

chk_div #(.N(2), .HIGH(10)) c_e2 (e2);
chk_div #(.N(4), .HIGH(20)) c_e4 (e4);
chk_div #(.N(6), .HIGH(30)) c_e6 (e6);
chk_div #(.N(3), .HIGH(15)) c_o3 (o3);
chk_div #(.N(5), .HIGH(25)) c_o5 (o5);
chk_div #(.N(7), .HIGH(35)) c_o7 (o7);
chk_div #(.N(5), .HIGH(10)) c_tk (tk);

integer errors;
initial begin
    repeat (2) @(negedge clk);
    rst_n = 1'b1;
    #5000;
    errors = c_e2.errors + c_e4.errors + c_e6.errors + c_o3.errors + c_o5.errors + c_o7.errors + c_tk.errors;
    if (c_o7.n_rise < 50 || c_tk.n_rise < 50) begin errors = errors + 1; $display("ERROR: too few edges"); end
    if (errors == 0) $display("PASS tb_t05"); else $display("FAIL tb_t05: %0d errors", errors);
    $stop;
end

endmodule
