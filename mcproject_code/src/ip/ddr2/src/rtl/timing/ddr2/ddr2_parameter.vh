
// DDR2_256M
// DDR2_512M
// DDR2_1G
// DDR2_2G
// DDR2_4G

// DDR2_X4
// DDR2_X8
// DDR2_X16

// DDR2_400B
// DDR2_400C
// DDR2_533B
// DDR2_533C
// DDR2_667C
// DDR2_667D
// DDR2_800C
// DDR2_800D
// DDR2_800E
// DDR2_1066
// DDR2_1333

///////////////////////////////////////////////////////////////////////////////////////////////////

localparam tREFI = 7_800_000;
localparam tRTP  = 7_500;
localparam tWR   = 15_000;
///////////////////////////////////////////////////////////////////////////////////////////////////
`ifdef DDR2_256M
   localparam tRFC = 75_000;
`endif

`ifdef DDR2_512M
   localparam tRFC = 105_000;
`endif

`ifdef DDR2_1G
   localparam tRFC = 127_500;
`endif

`ifdef DDR2_2G
   localparam tRFC = 195_000;
`endif

`ifdef DDR2_4G
   localparam tRFC = 327_500;
`endif

///////////////////////////////////////////////////////////////////////////////////////////////////

`ifdef DDR2_400B
   localparam CL   = 3;
   localparam tRAS = 40_000;
   localparam tRC  = 55_000;
   `include "ddr2_400.vh"
`endif

`ifdef DDR2_400C
   localparam CL   = 4;
   localparam tRAS = 45_000;
   localparam tRC  = 65_000;
   `include "ddr2_400.vh"
`endif

`ifdef DDR2_533B
   localparam CL   = 3;
   localparam tRAS = 45_000;
   localparam tRC  = 56_250;
   `include "ddr2_533.vh"
`endif

`ifdef DDR2_533C
   localparam CL   = 4;
   localparam tRAS = 45_000;
   localparam tRC  = 60_000;
   `include "ddr2_533.vh"
`endif

`ifdef DDR2_667C
   localparam CL   = 4;
   localparam tRAS = 45_000;
   localparam tRC  = 57_000;
   `include "ddr2_667.vh"
`endif

`ifdef DDR2_667D
   localparam CL   = 5;
   localparam tRAS = 45_000;
   localparam tRC  = 60_000;
   `include "ddr2_667.vh"
`endif

`ifdef DDR2_800C
   localparam CL   = 4;
   localparam tRAS = 45_000;
   localparam tRC  = 55_000;
   `include "ddr2_800.vh"
`endif

`ifdef DDR2_800D
   localparam CL   = 5;
   localparam tRAS = 45_000;
   localparam tRC  = 57_500;
   `include "ddr2_800.vh"
`endif

`ifdef DDR2_800E
   localparam CL   = 6;
   localparam tRAS = 45_000;
   localparam tRC  = 60_000;
   `include "ddr2_800.vh"
`endif

`ifdef DDR2_1066
   localparam CL   = 7;
   localparam tRAS = 45_000;
   localparam tRC  = 58_125;
   `include "ddr2_1066.vh"
`endif

`ifdef DDR2_1333
   localparam CL   = 9;
   localparam tRAS = 45_000;
   localparam tRC  = 58_500;
   `include "ddr2_1333.vh"
`endif

`ifdef DDR2_1333_8
   localparam CL   = 8;
   localparam tRAS = 45_000;
   localparam tRC  = 58_500;
   `include "ddr2_1333.vh"
`endif

`ifdef DDR2_1333_9
   localparam CL   = 9;
   localparam tRAS = 45_000;
   localparam tRC  = 58_500;
   `include "ddr2_1333.vh"
`endif

///////////////////////////////////////////////////////////////////////////////////////////////////
localparam nRCD            = CL;
localparam nRP             = CL;
localparam integer nREFI   = tREFI/tCK;
localparam integer nFAW    = tFAW/tCK;
localparam integer nRAS    = tRAS/tCK;
localparam integer nRFC    = tRFC/tCK;
localparam integer nRRD    = tRRD/tCK;
localparam integer nWR     = tWR/tCK;
