module dump_m0;
reg seen = 0;
initial begin
    $dumpfile("m0.vcd");
    $dumpvars(1, tb_m0_link.rx, tb_m0_link.tx, tb_m0_link.tgt_ok, tb_m0_link.tgt_deg, tb_m0_link.tgt_cm, tb_m0_link.rx_alive,
              tb_m0_link.cmd_valid, tb_m0_link.cmd_l, tb_m0_link.cmd_r, tb_m0_link.cmd_stop, tb_m0_link.dut.S_rv, tb_m0_link.dut.S_rd);
    #900000000 $dumpoff;
end
always @(posedge tb_m0_link.cmd_valid) if (!seen && !tb_m0_link.cmd_stop) begin
    seen = 1; $display("TXWIN %0t", $time); $dumpon; #3500000000 $dumpoff;
end
endmodule
