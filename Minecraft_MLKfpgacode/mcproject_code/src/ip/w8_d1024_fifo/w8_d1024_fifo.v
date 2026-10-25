`timescale 1 ns / 1 ps
module w8_d1024_fifo
(
  input                         rst,
  input                         clk,
  input                         we,
  input   [7:0]                 di,
  input                         re,
  output  [7:0]                 dout,
  output                        valid,
  output                        full_flag,
  output                        empty_flag,
  output                        afull,
  output                        aempty,
  output  [9:0]                 wrusedw,
  output  [9:0]                 rdusedw
);

  soft_fifo_al_fb5a119d9fb5
  #(
      .DATA_WIDTH_W(8),
      .DATA_WIDTH_R(8),
      .ADDR_WIDTH_W(10),
      .ADDR_WIDTH_R(10),
      .AL_FULL_NUM(253),
      .AL_EMPTY_NUM(2),
      .SHOW_AHEAD_EN(0),
      .OUTREG_EN("NOREG")
  )soft_fifo_al_fb5a119d9fb5_Inst
  (
      .rst(rst),
      .clk(clk),
      .we(we),
      .di(di),
      .re(re),
      .dout(dout),
      .valid(valid),
      .full_flag(full_flag),
      .empty_flag(empty_flag),
      .afull(afull),
      .aempty(aempty),
      .wrusedw(wrusedw),
      .rdusedw(rdusedw)
  );
endmodule
