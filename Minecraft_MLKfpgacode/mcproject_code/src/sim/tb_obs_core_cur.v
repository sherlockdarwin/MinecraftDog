// tb_obs_core 的变体：同一个测试台，换成车上现在的参数：学地面时亮度往两边放宽 2 格（OBS_YSPREAD = 2）、
// 只判断第 53 行以下（OBS_ROW_MIN = 53，约 2.36 m 以内）、最好的方向不到 60 cm 就停（OBS_D_STOP = 60）、车上的几何表 mc_obs_lut.v（镜头竖直装，按"第 60 行看到 135 cm、左右宽 170 cm"反推的倾角和焦距）。
// 测试台本身见 tb_obs_core.v；这个文件只换参数。
`define TB_OBS_YS 2
`define TB_OBS_RM 53
`define TB_OBS_REAL 1
`define TB_OBS_DSTOP 60
`include "tb_obs_core.v"
