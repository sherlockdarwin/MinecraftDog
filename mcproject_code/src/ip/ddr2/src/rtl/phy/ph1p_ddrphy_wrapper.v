`timescale 1ps/1ps

module ph1p_ddrphy_wrapper #(
    parameter tCK        = 1250,
    parameter BK_NUM     = 2 ,
    parameter AC_NUM     = 4 ,
    parameter DX_NUM     = 4 ,

    parameter CK_WIDTH   = 1 ,
    parameter CS_WIDTH   = 1 ,
    parameter CKE_WIDTH  = 1 ,
    parameter ODT_WIDTH  = 1 ,
    parameter BG_WIDTH   = 1 ,
    parameter BA_WIDTH   = 3 ,
    parameter COL_WIDTH  = 10,
    parameter ROW_WIDTH  = 14,
    parameter ADR_WIDTH  = 14,
    parameter PAR_WIDTH  = 0,

    parameter HOST_AC_DRV = "48",
    parameter HOST_DX_DRV = "48",
    parameter HOST_DX_ODT = "60",
    parameter DRAM_DRV    = "RZQ/5", // for ddr3/4
                                     // ddr3 = "RZQ/6"/"RZQ/7"
                                     // ddr4 = "RZQ/5"/"RZQ/7"
    parameter DRAM_ODT    = "RZQ/4", // ddr2 = "50"/"75"/"150"/"DISABLE",
                                     // ddr3 = "RZQ/2"/"RZQ/4"/"RZQ/6"/"DISABLE"
                                     // ddr4 = "RZQ/1"/.../"RZQ/7"/"DISABLE"


    parameter CWL        = 5 ,
    parameter CL         = 6 ,

    parameter PLL0_REFCLK_FREQ = "100",
    parameter PLL0_REFCLK_DIV  =  1   ,
    parameter PLL0_FBKCLK_DIV  =  12  ,
    parameter PLL0_CLK2_DIV    =  3   ,
    parameter PLL0_CLK3_DIV    =  24  ,
    parameter PLL0_FRAC        = "DISABLE",
    parameter PLL0_FRAC_SDM    =  0   ,
    parameter PLL1_REFCLK_FREQ = "100",
    parameter PLL1_REFCLK_DIV  =  1   ,
    parameter PLL1_CLK0_DIV    =  12
)(
    // clock & reset
    input                       ref_clk       ,
    input                       sys_rst_n     ,

    output                      cfg_clk       ,
    output                      cfg_rst_n     ,

    output                      dhi_clk       ,
    output                      ddrphy_rst_n  ,
    output  reg                 cal_done      ,

    // ddrphy host interface
    input   [         4-1 : 0]  dhi_cmd_vld     ,
    input   [      32*4-1 : 0]  dhi_cmd_code    ,

    output                      dhi_cmd_err     ,

`ifndef DHI_DATA_FORMAT_PHASE 
    output                      dhi_wdata_en    ,
    input   [DX_NUM *64-1 : 0]  dhi_wdata       ,
    input   [DX_NUM * 8-1 : 0]  dhi_wmask       ,
    output  [DX_NUM    -1 : 0]  dhi_rdata_vld   ,
    output  [DX_NUM *64-1 : 0]  dhi_rdata       ,
`else
    output                      dhi_wdata_en_p  ,
    input   [DX_NUM *64-1 : 0]  dhi_wdata_p     ,
    input   [DX_NUM * 8-1 : 0]  dhi_wmask_p     ,
    output  [DX_NUM    -1 : 0]  dhi_rdata_vld_p ,
    output  [DX_NUM *64-1 : 0]  dhi_rdata_p     ,
`endif

    // APB
    input                       apb_pclk      ,
    input                       apb_prst_n    ,
    input                       apb_psel      ,
    input                       apb_penable   ,
    input                       apb_pwrite    ,
    input   [           7 : 0]  apb_paddr     ,
    input   [          31 : 0]  apb_pwdata    ,
    output                      apb_pready    ,
    output  [          31 : 0]  apb_prdata    ,

    // ddrio
`ifdef DRAM_DDR4
    output  [CK_WIDTH  -1 : 0]  ddr_ck_t      ,
    output  [CK_WIDTH  -1 : 0]  ddr_ck_c      ,
    output  [        1 -1 : 0]  ddr_reset_n   ,
    output  [CKE_WIDTH -1 : 0]  ddr_cke       ,
    output  [ODT_WIDTH -1 : 0]  ddr_odt       ,
    output  [CS_WIDTH  -1 : 0]  ddr_cs_n      ,
    output  [        1 -1 : 0]  ddr_act_n     ,
    output  [BG_WIDTH  -1 : 0]  ddr_bg        ,
    output  [BA_WIDTH  -1 : 0]  ddr_ba        ,
    output  [ADR_WIDTH -1 : 0]  ddr_addr      ,
    inout   [DX_NUM    -1 : 0]  ddr_dqs_t     ,
    inout   [DX_NUM    -1 : 0]  ddr_dqs_c     ,
    inout   [DX_NUM  *8-1 : 0]  ddr_dq        ,
    inout   [DX_NUM    -1 : 0]  ddr_dm_n      ,

    output                      ddr_parity    ,
    input                       ddr_alert_n

`else
    output  [CK_WIDTH  -1 : 0]  ddr_ck_p      ,
    output  [CK_WIDTH  -1 : 0]  ddr_ck_n      ,
`ifdef DRAM_DDR3
    output  [        1 -1 : 0]  ddr_reset_n   ,
`endif
    output  [CKE_WIDTH -1 : 0]  ddr_cke       ,
    output  [ODT_WIDTH -1 : 0]  ddr_odt       ,
    output  [CS_WIDTH  -1 : 0]  ddr_cs_n      ,
    output  [        1 -1 : 0]  ddr_ras_n     ,
    output  [        1 -1 : 0]  ddr_cas_n     ,
    output  [        1 -1 : 0]  ddr_we_n      ,
    output  [BA_WIDTH  -1 : 0]  ddr_ba        ,
    output  [ROW_WIDTH -1 : 0]  ddr_addr      ,
    inout   [DX_NUM    -1 : 0]  ddr_dqs_p     ,
    inout   [DX_NUM    -1 : 0]  ddr_dqs_n     ,
    inout   [DX_NUM  *8-1 : 0]  ddr_dq        ,
    inout   [DX_NUM    -1 : 0]  ddr_dm
`endif

);

//*****************************************************************************************************************************
//    Local Parameter
//*****************************************************************************************************************************
`ifdef PH1P_DDRPHY_SIM
localparam integer nDLY = 400_000/tCK/4;
`else
localparam integer nDLY = 400_000_000/tCK/4;
`endif

localparam DQ_WIDTH = DX_NUM*8;
localparam DM_WIDTH = DX_NUM;

//*****************************************************************************************************************************
//    Internal Signals
//*****************************************************************************************************************************
`ifdef DHI_DATA_FORMAT_PHASE 
wire                      dhi_wdata_en ;
wire  [DX_NUM *64-1 : 0]  dhi_wdata    ;
wire  [DX_NUM * 8-1 : 0]  dhi_wmask    ;
wire  [DX_NUM    -1 : 0]  dhi_rdata_vld;
wire  [DX_NUM *64-1 : 0]  dhi_rdata    ;
`endif

wire                     ddrphy_rdy    ;
wire  [DX_NUM *1-1 : 0]  dx_fifo_rst_n ;
wire  [DX_NUM *1-1 : 0]  wrlvl_en      ;
wire  [DX_NUM *4-1 : 0]  wsl_i         ;
wire  [DX_NUM *4-1 : 0]  rsl_i         ;
wire  [DX_NUM *4-1 : 0]  wsl_o         ;
wire  [DX_NUM *4-1 : 0]  rsl_o         ;


// DelayLine Configuration Port
wire  [DX_NUM* 1-1 : 0]  dcp_vld      ;
wire  [DX_NUM* 1-1 : 0]  dcp_inc      ;
wire  [DX_NUM* 4-1 : 0]  dcp_type     ;
wire  [DX_NUM* 9-1 : 0]  dcp_code     ;
wire  [DX_NUM* 1-1 : 0]  dcp_rdy      ;

// misc - mdl
wire  [DX_NUM* 9-1 : 0]  mdl_tck      ;
wire  [DX_NUM* 9-1 : 0]  mdl_ui       ;

// misc
wire                     dqs_pupd_en     ;
wire  [DX_NUM* 2-1 : 0]  dqs_gate_status ;
wire  [DX_NUM* 8-1 : 0]  dx_indd         ;
wire  [DX_NUM*16-1 : 0]  dx_debug        ;

// dram init
wire         init_start   ;
wire         init_done    ;
wire         init_cmd_vld ;
wire  [31:0] init_cmd_code;
wire  [12:0] init_mr1;

wire  [         4-1 : 0]  phy_dhi_cmd_vld   ;
wire  [      32*4-1 : 0]  phy_dhi_cmd_code  ;
wire                      phy_dhi_wdata_en  ;
wire  [DX_NUM *64-1 : 0]  phy_dhi_wdata     ;
wire  [DX_NUM * 8-1 : 0]  phy_dhi_wmask     ;
wire  [DX_NUM    -1 : 0]  phy_dhi_rdata_vld ;
wire  [DX_NUM *64-1 : 0]  phy_dhi_rdata     ;

//*****************************************************************************************************************************
//    DDRPHY HOST Interface MUX
//*****************************************************************************************************************************
assign phy_dhi_cmd_vld [0]          = (init_done == 1'b0) ? init_cmd_vld  : dhi_cmd_vld [0];
assign phy_dhi_cmd_code[0*32 +: 32] = (init_done == 1'b0) ? init_cmd_code : dhi_cmd_code[0*32 +: 32];

assign phy_dhi_cmd_vld [1]          = dhi_cmd_vld [1];
assign phy_dhi_cmd_code[1*32 +: 32] = dhi_cmd_code[1*32 +: 32];

assign phy_dhi_cmd_vld [2]          = dhi_cmd_vld [2];
assign phy_dhi_cmd_code[2*32 +: 32] = dhi_cmd_code[2*32 +: 32];

assign phy_dhi_cmd_vld [3]          = dhi_cmd_vld [3];
assign phy_dhi_cmd_code[3*32 +: 32] = dhi_cmd_code[3*32 +: 32];

// Data Format Reorder when using DHI_DATA_FORMAT_PHASE
genvar n, b, p;

`ifdef DHI_DATA_FORMAT_PHASE
assign dhi_wdata_en_p  = dhi_wdata_en;
assign dhi_rdata_vld_p = dhi_rdata_vld;

for (n = 0; n <= DX_NUM-1; n = n+1) begin
    for (p = 0; p <= 7; p = p+1) begin
        assign dhi_wdata  [n*64+p*8 +: 8] = dhi_wdata_p[p*DQ_WIDTH+n*8 +: 8];
        assign dhi_wmask  [n*8 +p]        = dhi_wmask_p[p*DM_WIDTH+n];
        assign dhi_rdata_p[p*DQ_WIDTH+n*8 +: 8] = dhi_rdata[n*64+p*8 +: 8];
    end
end
`endif

// DHI Internal MUX
assign phy_dhi_wdata = dhi_wdata;
assign phy_dhi_wmask = dhi_wmask;
assign dhi_wdata_en  = phy_dhi_wdata_en ;
assign dhi_rdata_vld = phy_dhi_rdata_vld;
assign dhi_rdata     = phy_dhi_rdata    ;

//*****************************************************************************************************************************
//    Instance : DRAM_INIT
//*****************************************************************************************************************************
reg  [31:0] init_dly_cnt;

ph1p_ddrphy_dram_init #(
    .tCK     ( tCK       ),
    .CL      ( CL        ),
    .CWL     ( CWL       ),
    .PAR     ( PAR_WIDTH ),
`ifdef DRAM_DDR2
    .RTT_NOM ( DRAM_ODT  )
`elsif DRAM_DDR3
    .DRV     ( DRAM_DRV  ),
    .RTT_NOM ( DRAM_ODT  )
`else
    .DRV     ( DRAM_DRV  ),
    .RTT_PK  ( DRAM_ODT  )
`endif
) u_ddrphy_dram_init (
    .clk          ( dhi_clk       ),
    .rst_n        ( ddrphy_rst_n  ),
    .start        ( init_start    ),
    .done         ( init_done     ),
    .phy_rst_n    (               ),
    .cmd_vld      ( init_cmd_vld  ),
    .cmd_code     ( init_cmd_code ),
    .mr1          ( init_mr1      )
);

always @ (posedge dhi_clk or negedge ddrphy_rst_n)
begin
    if (ddrphy_rst_n == 1'b0)
        init_dly_cnt <= 32'h0;
    else if (ddrphy_rdy == 1'b1)
        init_dly_cnt <= (init_dly_cnt == nDLY) ? init_dly_cnt : (init_dly_cnt + 1'b1);
end

assign init_start = (init_dly_cnt == nDLY);

//*****************************************************************************************************************************
//    Instance : RDQS Gating
//*****************************************************************************************************************************
assign dx_fifo_rst_n = {DX_NUM{1'b1}};
assign dqs_pupd_en   = 1'b0;

//*****************************************************************************************************************************
//    Instance : Write Leveling
//*****************************************************************************************************************************
assign wrlvl_en = {DX_NUM{1'b0}};

//*****************************************************************************************************************************
//    Instance : Write Latency Adjust
//*****************************************************************************************************************************



//*****************************************************************************************************************************
//    Function : cal_done
//*****************************************************************************************************************************
always @ (posedge dhi_clk or negedge ddrphy_rst_n)
begin
    if (ddrphy_rst_n == 1'b0)
        cal_done <= 1'b0;
    else
        cal_done <= (init_done == 1'b1) ? 1'b1 : 1'b0;
end

//*****************************************************************************************************************************
//    Instance : DDRPHY_TOP
//*****************************************************************************************************************************
ph1p_ddrphy_top #(
    .BK_NUM           ( BK_NUM           ),
    .AC_NUM           ( AC_NUM           ),
    .DX_NUM           ( DX_NUM           ),
    .CK_WIDTH         ( CK_WIDTH         ),
    .CS_WIDTH         ( CS_WIDTH         ),
    .CKE_WIDTH        ( CKE_WIDTH        ),
    .ODT_WIDTH        ( ODT_WIDTH        ),
    .BG_WIDTH         ( BG_WIDTH         ),
    .BA_WIDTH         ( BA_WIDTH         ),
    .COL_WIDTH        ( COL_WIDTH        ),
    .ROW_WIDTH        ( ROW_WIDTH        ),
    .ADR_WIDTH        ( ADR_WIDTH        ),
    .PAR_WIDTH        ( PAR_WIDTH        ),

    .MDL_MODE         ((tCK > 2500) ? "HALF" : "FULL"),

    .AC_DRV           ( HOST_AC_DRV      ),
    .DX_DRV           ( HOST_DX_DRV      ),
    .DX_ODT           ( HOST_DX_ODT      ),
    .CWL              ( CWL              ),
    .CL               ( CL               ),
    .PLL0_REFCLK_FREQ ( PLL0_REFCLK_FREQ ),
    .PLL0_REFCLK_DIV  ( PLL0_REFCLK_DIV  ),
    .PLL0_FBKCLK_DIV  ( PLL0_FBKCLK_DIV  ),
    .PLL0_FRAC        ( PLL0_FRAC        ),
    .PLL0_FRAC_SDM    ( PLL0_FRAC_SDM    ),
    .PLL0_CLK2_DIV    ( PLL0_CLK2_DIV    ),
    .PLL0_CLK3_DIV    ( PLL0_CLK3_DIV    ),
    .PLL1_REFCLK_FREQ ( PLL1_REFCLK_FREQ ),
    .PLL1_REFCLK_DIV  ( PLL1_REFCLK_DIV  ),
    .PLL1_CLK0_DIV    ( PLL1_CLK0_DIV    ),
    .DDRPHY_ROM_LEN   (`DDRPHY_ROM_LEN   ),
    .DDRPHY_ROM_INIT  (`DDRPHY_ROM_INIT  )
) u_ddrphy_top (
    // clock & reset
    .ref_clk         ( ref_clk         ),
    .dhi_clk         ( dhi_clk         ),
    .cfg_clk         ( cfg_clk         ),

    .sys_rst_n       ( sys_rst_n       ),
    .cfg_rst_n       ( cfg_rst_n       ),
    .ddrphy_rst_n    ( ddrphy_rst_n    ),
    .ddrphy_rdy      ( ddrphy_rdy      ),

    .dx_fifo_rst_n   ( dx_fifo_rst_n   ),

    // ddrphy host interface
    .dhi_cmd_vld     ( phy_dhi_cmd_vld   ),
    .dhi_cmd_code    ( phy_dhi_cmd_code  ),
    .dhi_wdata_en    ( phy_dhi_wdata_en  ),
    .dhi_wdata       ( phy_dhi_wdata     ),
    .dhi_wmask       ( phy_dhi_wmask     ),
    .dhi_rdata_vld   ( phy_dhi_rdata_vld ),
    .dhi_rdata       ( phy_dhi_rdata     ),

    .dhi_cmd_err     ( dhi_cmd_err       ),

    // DelayLine Configuration Port
    .dcp_vld         ( dcp_vld         ),
    .dcp_inc         ( dcp_inc         ),
    .dcp_type        ( dcp_type        ),
    .dcp_code        ( dcp_code        ),
    .dcp_rdy         ( dcp_rdy         ),

    // APB
    .apb_pclk        ( apb_pclk        ),
    .apb_prst_n      ( apb_prst_n      ),
    .apb_psel        ( apb_psel        ),
    .apb_penable     ( apb_penable     ),
    .apb_pwrite      ( apb_pwrite      ),
    .apb_paddr       ( apb_paddr       ),
    .apb_pwdata      ( apb_pwdata      ),
    .apb_pready      ( apb_pready      ),
    .apb_prdata      ( apb_prdata      ),


    // misc
    .dx_fifo_en      ({(DX_NUM){1'b0}} ),
    .wsl_i           ( wsl_o           ),
    .rsl_i           ( rsl_o           ),
    .wsl_o           ( wsl_i           ),
    .rsl_o           ( rsl_i           ),
    .cal_done        ( cal_done        ),
    .lb_enb          ( 1'b1            ),
    .wrlvl_en        ( wrlvl_en        ),
    .dqs_pupd_en     ( dqs_pupd_en     ),
    .dqs_gate_status ( dqs_gate_status ),
    .dx_indd         ( dx_indd         ),
    .dx_debug        ( dx_debug        ),

    // ddrio
`ifdef DRAM_DDR4
    .ddr_ck_t        ( ddr_ck_t        ),
    .ddr_ck_c        ( ddr_ck_c        ),
    .ddr_reset_n     ( ddr_reset_n     ),
    .ddr_cke         ( ddr_cke         ),
    .ddr_odt         ( ddr_odt         ),
    .ddr_cs_n        ( ddr_cs_n        ),
    .ddr_act_n       ( ddr_act_n       ),
    .ddr_bg          ( ddr_bg          ),
    .ddr_ba          ( ddr_ba          ),
    .ddr_addr        ( ddr_addr        ),
    .ddr_parity      ( ddr_parity      ),
    .ddr_alert_n     ( ddr_alert_n     ),
    .ddr_dqs_t       ( ddr_dqs_t       ),
    .ddr_dqs_c       ( ddr_dqs_c       ),
    .ddr_dq          ( ddr_dq          ),
    .ddr_dm_n        ( ddr_dm_n        ),
`else
    .ddr_ck_p        ( ddr_ck_p        ),
    .ddr_ck_n        ( ddr_ck_n        ),
`ifdef DRAM_DDR3
    .ddr_reset_n     ( ddr_reset_n     ),
`endif
    .ddr_cke         ( ddr_cke         ),
    .ddr_odt         ( ddr_odt         ),
    .ddr_cs_n        ( ddr_cs_n        ),
    .ddr_ras_n       ( ddr_ras_n       ),
    .ddr_cas_n       ( ddr_cas_n       ),
    .ddr_we_n        ( ddr_we_n        ),
    .ddr_ba          ( ddr_ba          ),
    .ddr_addr        ( ddr_addr        ),
    .ddr_dqs_p       ( ddr_dqs_p       ),
    .ddr_dqs_n       ( ddr_dqs_n       ),
    .ddr_dq          ( ddr_dq          ),
    .ddr_dm          ( ddr_dm          ),
`endif

    // misc - mdl
    .mdl_tck         ( mdl_tck         ),
    .mdl_ui          ( mdl_ui          )
);

//*******************************************************************************
// SIMULATION ONLY
//*******************************************************************************
//synthesis translate_off
`ifdef PH1P_DDRPHY_SIM
initial begin
    wait(u_ddrphy_top.cfg_done);
    $display("[INFO] : DDRPHY CFG Done!");
    wait(u_ddrphy_top.mdl_done);
    $display("[INFO] : DDRPHY MDL CAL Done!");
    wait(u_ddrphy_top.fiu_done);
    $display("[INFO] : DDRPHY Fast Init Done!");
end
`endif
//synthesis translate_on
//*******************************************************************************
//*******************************************************************************
endmodule

