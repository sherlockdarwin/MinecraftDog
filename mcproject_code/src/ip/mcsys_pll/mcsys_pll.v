/************************************************************\
**	Copyright (c) 2012-2025 Anlogic Inc.
**	All Right Reserved.
\************************************************************/
/************************************************************\
**	Build time: Oct 02 2026 19:36:15
**	TD version	:	6.2.175876
************************************************************/
///////////////////////////////////////////////////////////////////////////////
//	Input frequency:                25.000000000 MHz
//	Clock multiplication factor: 4
//	Clock division factor:       1
//	Clock information:
//		Clock name	| Frequency 	| Phase shift 
//		C0        	| 100.000000   MHz	    |  0.0000 DEG 
//		C1        	| 24.000000   MHz	    |  0.0000 DEG 
//		C2        	| 52.173913   MHz		|  0.0000 DEG 
//		C3        	| 10.000000   MHz		|  0.0000 DEG 
///////////////////////////////////////////////////////////////////////////////
`timescale 1 ns / 100 fs 

module mcsys_pll
(
  input                         refclk,
  output                        clk0_out,
  output                        clk1_out,
  output                        clk2_out,
  output                        clk3_out,
  output                        lock,
  input                         reset
);
  wire							  clk0_buf;
PH1P_LOGIC_BUFG bufg_feedback (
 .i(clk0_buf), 
 .o(clk0_out) 
 ); 

 
 
 




  ph1p_phy_pll_wrapper_9424f6f87a2a
  #(
      .FBKCLK("CLKC0_EXT"),
      .FBKCLK_INT("CLKC0_EXT"),
      .FIN("25.000000000"),
      .REFCLK_DIV(1),
      .FBCLK_DIV(4),
      .CLKC0_ENABLE("ENABLE"),
      .CLKC0_DIV(12),
      .CLKC0_CPHASE(11),
      .CLKC0_FPHASE(0),
      .CLKC0_FPHASE_RSTSEL(0),
      .CLKC0_DUTY50("ENABLE"),
      .CLKC0_DUTY_INT(6),
      .CLKC1_ENABLE("ENABLE"),
      .CLKC1_DIV(50),
      .CLKC1_CPHASE(49),
      .CLKC1_FPHASE(0),
      .CLKC1_FPHASE_RSTSEL(0),
      .CLKC1_DUTY50("ENABLE"),
      .CLKC1_DUTY_INT(25),
      .CLKC2_ENABLE("ENABLE"),
      .CLKC2_DIV(23),
      .CLKC2_CPHASE(22),
      .CLKC2_FPHASE(0),
      .CLKC2_FPHASE_RSTSEL(0),
      .CLKC2_DUTY50("ENABLE"),
      .CLKC2_DUTY_INT(12),
      .CLKC3_ENABLE("ENABLE"),
      .CLKC3_DIV(120),
      .CLKC3_CPHASE(119),
      .CLKC3_FPHASE(0),
      .CLKC3_FPHASE_RSTSEL(0),
      .CLKC3_DUTY50("ENABLE"),
      .CLKC3_DUTY_INT(60),
      .PLL_USR_RST("ENABLE"),
      .PLL_FEED_TYPE("EXTERNAL"),
      .PLL_FASTLOOP("DISABLE"),
      .LPF_RES(3),
      .LPF_CAP(0),
      .ICP_CUR(0),
      .PHASE_PATH_SEL(0),
      .DYN_PHASE_PATH_SEL("DISABLE"),
      .DYN_FPHASE_EN("DISABLE"),
      .PI_OUT_SEL("NORMAL"),
      .PI_FRAC_EN("DISABLE"),
      .CLKC0_PI_SHIFT_EN("DISABLE"),
      .FEEDBK_MODE("NORMAL"),
      .DYN_CPHASE_EN("DISABLE")
  )ph1p_phy_pll_wrapper_9424f6f87a2a_Inst
  (
      .clk4_en(1'b0),
      .clk4_out(),
      .clkb4_out(),
      .clk5_en(1'b0),
      .clk5_out(),
      .clkb5_out(),
      .clk6_en(1'b0),
      .clk6_out(),
      .clkb6_out(),
      .refclk(refclk),
      .drp_clk(1'b0),
      .drp_rstn(1'b1),
      .drp_sel(1'b0),
      .drp_rd(1'b0),
      .drp_wr(1'b0),
      .drp_addr(8'b00000000),
      .drp_wdata(8'b00000000),
      .drp_err(),
      .drp_rdy(),
      .drp_rdata(),
      .psclk(1'b0),
      .psclksel(3'b000),
      .psstep(1'b0),
      .psdown(1'b0),
      .cps_step(1'b0),
      .psdone(),
      .ssc_reset(1'b0),
	  .clkc_rst(2'b00),
      .pllpd(1'b0),
      .fbclk(clk0_out),
      .wakeup(1'b1),
      .refclk_rst(1'b0),
      .clk0_en(1'b1),
      .clkb0_out(),
      .clk0_out(clk0_buf),
      .clk1_en(1'b1),
      .clkb1_out(),
      .clk1_out(clk1_out),
      .clk2_en(1'b1),
      .clkb2_out(),
      .clk2_out(clk2_out),
      .clk3_en(1'b1),
      .clkb3_out(),
      .clk3_out(clk3_out),
      .lock(lock),
      .reset(reset)
  );
endmodule
