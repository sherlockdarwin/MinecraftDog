// tb_obs_core 的变体：同一个测试台，学地面时亮度往两边放宽 4 格（YSPREAD = 4，mctop.v 的 OBS_YSPREAD 10-29 用过的值；C_L 那个颜色只在 4 格时算地面）。
// 测试台本身见 tb_obs_core.v（模型里的亮度邻格也跟着 YS 走）；这个文件只换参数。
`define TB_OBS_YS 4
`include "tb_obs_core.v"
