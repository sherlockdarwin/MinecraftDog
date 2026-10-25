# ============================================================================
# 时序约束：告诉工具"每个时钟多快、哪些时钟互不相关"，布线后工具才能检查 建立/保持 时间是否满足
# ============================================================================

# ---- 1. 外部输入进来的时钟 ----
# 板载 25 MHz 晶振
create_clock -name {sys_clk_25m} -period 40.000 -waveform {0.000 20.000} [get_ports {I_sys_clk}]
# 摄像头 MIPI 时钟线（IMX415 每 lane 891 Mbps，DDR 时钟 = 445.5 MHz → 周期 2.245 ns）
create_clock -name {mipi_rx_ck_pad} -period 2.245 -waveform {0.000 1.1225} [get_nets {IO_rx_clk_pad_p}]

# ---- 2. 让工具自动推导 PLL 输出时钟、MIPI/DDR 硬核产生的时钟 ----
derive_clocks

# ---- 3. 给自动推导出来的时钟起好认的名字（路径 = 例化层次 + 内部原语名）----
rename_clock -name {pll_clk_100m} [get_clocks {u_sys_pll/ph1p_phy_pll_wrapper_9424f6f87a2a_Inst/u_PH1P_PHY_PLL.clkc[0]}]
rename_clock -name {pll_clk_24m}  [get_clocks {u_sys_pll/ph1p_phy_pll_wrapper_9424f6f87a2a_Inst/u_PH1P_PHY_PLL.clkc[1]}]
rename_clock -name {dpll_ref_clk} [get_clocks {u_sys_pll/ph1p_phy_pll_wrapper_9424f6f87a2a_Inst/u_PH1P_PHY_PLL.clkc[2]}]
rename_clock -name {pll_clk_10m}  [get_clocks {u_sys_pll/ph1p_phy_pll_wrapper_9424f6f87a2a_Inst/u_PH1P_PHY_PLL.clkc[3]}]

rename_clock -name {MIPI_RX_BYTE_CLK} [get_clocks {u_cam/u_mipi_rx/u_ph1p_mipiio_rx_wrapper/u_PH1P_LOGIC_DPHY_MIPI_RX.o_fabric_div4_8_clk}]
rename_clock -name {MIPI_TX_BYTE_CLK} [get_clocks {u_disp/u_mipi_tx/u_ph1p_mipiio_tx_wrapper/u_PH1P_LOGIC_DPHY_MIPI_TX.o_fabric_div4_8_clk}]

# ---- 4. 声明哪些时钟互相异步：不同组之间的路径不做时序检查 ----
# （跨组的信号都已经用 同步器 / 异步 FIFO 处理过；DDR2 IP 自己的约束在 ip/ddr2/src/sdc/ddr2.sdc）
set_clock_groups -name group -asynchronous \
    -group [get_clocks {MIPI_RX_BYTE_CLK}] \
    -group [get_clocks {MIPI_TX_BYTE_CLK}] \
    -group [get_clocks {mipi_rx_ck_pad}] \
    -group [get_clocks {dpll_ref_clk}] \
    -group [get_clocks {pll_clk_100m}] \
    -group [get_clocks {pll_clk_10m}] \
    -group [get_clocks {pll_clk_24m}] \
    -group [get_clocks {sys_clk_25m}] \
    -group [get_clocks {u_fb/u_ddr/u_ddr2/ddr_clk}] \
    -group [get_clocks {u_fb/u_ddr/u_ddr2/usr_clk}]
