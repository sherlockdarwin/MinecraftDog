module dump_i2s;
initial begin
    $dumpfile("i2s.vcd");
    $dumpvars(1, tb_i2s.mclk, tb_i2s.sclk, tb_i2s.lrck, tb_i2s.dsdin, tb_i2s.l_in, tb_i2s.r_in, tb_i2s.ack, tb_i2s.valid, tb_i2s.rate_sel);
    #200000 $dumpoff;
end
endmodule
