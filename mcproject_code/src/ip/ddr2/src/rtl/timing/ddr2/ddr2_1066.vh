// min in tCK
localparam nCCD = 2;
localparam nRTP = 4;
localparam nWTR = 4;
// min in ps
localparam tWTR = 7_500;

`ifdef DDR2_256M
   localparam tRRD = 7500;
   localparam tFAW = 35_000;
`else // DDR2_512M DDR2_1G DDR2_2G DDR2_4G
   `ifdef DDR2_X16
      localparam tRRD = 10_000;
      localparam tFAW = 45_000;
   `else // DDR2_X4 DDR2_X8
      localparam tRRD = 7500;
      localparam tFAW = 35_000;
   `endif
`endif
