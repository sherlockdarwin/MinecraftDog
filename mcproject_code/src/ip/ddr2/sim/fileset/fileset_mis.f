+define+DDRPHY_ROM_INIT='"../../src/rtl/phy/ddrphy_cfg_rom.txt"'

+incdir+../../src/rtl/include
+incdir+../../src/rtl/phy/include
+incdir+../../src/rtl/timing/ddr2

# MIS TOP
../ddr2.v
../ph1p_ddrmc_wrapper_63f4ac254419.v

# Clock Gen
../../src/rtl/clk/ph1p_ddrphy_clk_top.v
../../src/rtl/clk/ph1p_ddrphy_pll0.v
../../src/rtl/clk/ph1p_ddrphy_pll1.v

#DDRPHY
../../src/rtl/phy/ph1p_ddrphy_wrapper.v
../../src/rtl/phy/ph1p_ddrphy_apb_bridge.v
../../src/rtl/phy/ph1p_ddrphy_bankref_cfg.v
../../src/rtl/phy/ph1p_ddrphy_init.v
../../src/rtl/phy/ph1p_ddrphy_mdl_cal.v
../../src/rtl/phy/ph1p_ddrphy_mdl_cal_wrapper.v
../../src/rtl/phy/ph1p_ddrphy_fast_init.v
../../src/rtl/phy/ph1p_ddrphy_fast_init_wrapper.v
../../src/rtl/phy/ph1p_ddrphy_dcu.v
../../src/rtl/phy/ph1p_ddrphy_dcu_wrapper.v
../../src/rtl/phy/ph1p_ddrphy_wphase_ctl.v
../../src/rtl/phy/ph1p_ddrphy_rphase_ctl.v
../../src/rtl/phy/ph1p_ddrphy_cmd_decode.v
../../src/rtl/phy/ph1p_ddrphy_cmd_execution.v
../../src/rtl/phy/ph1p_ddrphy_cmd_wrapper.v
../../src/rtl/phy/ph1p_ddrphy_byte_wrapper.v
../../src/rtl/phy/ph1p_ddrphy.v
../../src/rtl/phy/ph1p_ddrphy_top.v

#INIT
../../src/rtl/init/ph1p_ddrphy_dram_init_ddr2.v

#MISC
../../src/rtl/misc/ph1p_ddrphy_sync_rst_gen.v
../../src/rtl/misc/ph1p_ddr_fifo_dram_sync.v

#MC
../../src/rtl/mc/alc_phy2mc_fifo_ctrl.v
../../src/rtl/mc/alc_mc_top_all.enc.sv
