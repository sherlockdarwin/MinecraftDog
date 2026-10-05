/************************************************************\
**	Copyright (c) 2012-2024 Anlogic Inc.
**	All Right Reserved.
\************************************************************/
/************************************************************\
**	Build time: Apr 21 2025 18:05:45
**	TD version	:	6.1.144582
************************************************************/
`timescale 1 ns / 1 ps
module w8_d1024_rom
(
  output  [7:0]                 doa,
  input   [9:0]                 addra,
  input                         clka
);

  rom_c370f19e17c7
  #(
      .DATA_WIDTH_A(8),
      .ADDR_WIDTH_A(10),
      .DATA_DEPTH_A(1024),
      .INIT_FILE("../../w8_d1024_rom/mc_ili9881c_k101.mif.dat"),
      .FILL_ALL("NONE")
  )rom_c370f19e17c7_Inst
  (
      .doa(doa),
      .addra(addra),
      .clka(clka)
  );
endmodule
