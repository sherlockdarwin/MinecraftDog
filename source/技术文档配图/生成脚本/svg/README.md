# 技术文档配图（SVG 版）

替代上一级的 matplotlib 脚本（那些图停在 10-29 的设计）。`dg.js` 是 `dg.py` 的 SVG 移植，`figs.js` 画框图，`wave.js` 画仿真波形和闭环曲线，数据在 `wavedata.js`（由 `vcd2js.pl` 从 VCD 转出，VCD 用 `dump_*.v` / `mon_follow.v` 和对应测试台一起编译得到）。

全部重画：

```bash
bash render.sh fig_flow 13 12.2 fig_system 20.2 11.25 fig_hw 20.2 11.2 fig_clk 20.2 10.6 fig_layout 17 13.6 fig_obs 16.5 13.8 fig_corridor 15 12.6 fig_follow 22 17.6 fig_behavior 20.2 8.4 fig_audio 20.2 7.4 wave_m0 20 8.6 wave_i2s 20 5.6 chart_follow 20 9.6
```
