// Figures for the technical document (ported from figs1.py / figs2.py, updated to the 11-01 design).
const FIGS = {};
const rad = d => d * Math.PI / 180;

// ------------------------------------------------------------------ 图1-1 设计流程
FIGS.fig_flow = () => {
  const W = 13, H = 12.2; canvas(W, H);
  const steps = [
    ['赛题分析与需求定义', '自主命题：会跟人、会看路、会互动的方块机器狗'],
    ['系统方案设计', '感知、决策、控制全部放在 FPGA；STM32 只作 UWB / 电机接口'],
    ['模块划分与接口定义', '时钟域、像素流格式、写总线、串口 / 陀螺仪帧协议'],
    ['RTL 设计（Verilog）', '自写 mc_* 模块 + 厂商 MIPI / DDR2 / DSI IP'],
    ['测试台仿真 + 突变检查', 'Icarus Verilog，33 个自检测试台'],
    ['TD 综合、布局布线、时序收敛', '安路 TD 6.2.1，0 时序违例'],
    ['分模块上板调试', '屏幕状态方块 / 状态文字 / LED 定位问题'],
    ['整车联调与参数整定', '跟随先在 STM32 上调好再移植；实验照片重放比较地面识别'],
    ['性能测试与文档整理', ''],
  ];
  const x0 = 0.6, w = 8.6, h = 0.92, gap = 0.38, ys = [];
  steps.forEach(([t, s], i) => {
    const y = H - 0.5 - (i + 1) * h - i * gap; ys.push(y);
    box(x0, y, w, h, '', { fc: (i >= 3 && i <= 6) ? C.fpga : C.sens });
    label(x0 + 0.25, y + h / 2 + (s ? 0.17 : 0), `${i + 1}. ${t}`, { fs: 10.5, ha: 'left', bold: true, color: '#212121' });
    if (s) label(x0 + 0.25, y + h / 2 - 0.21, s, { fs: 8.5, ha: 'left', color: '#546E7A' });
    if (i) arrow([x0 + w / 2, ys[i - 1]], [x0 + w / 2, y + h]);
  });
  const back = (a, b, xr, t) => {
    const yf = ys[a] + h / 2, yt = ys[b] + h / 2;
    poly([[x0 + w, yf], [xr, yf], [xr, yt], [x0 + w, yt]], { color: C.accent, lw: 1.1 });
    label(xr + 0.22, (yf + yt) / 2, t, { fs: 8.5, color: C.accent, rotation: 90 });
  };
  back(4, 3, 9.75, '仿真不过'); back(5, 3, 10.55, '时序不收敛'); back(6, 2, 11.35, '上板问题'); back(7, 1, 12.15, '整车效果');
};

// ------------------------------------------------------------------ 图2-1 系统整体框图
FIGS.fig_system = () => {
  const W = 20.2, H = 11.25; canvas(W, H);
  box(3.55, 0.55, 12.9, 10.3, '', { fc: C.fpgabg, ec: C.accent, lw: 1.8, r: 0.25, z: 1 });
  label(10.0, 10.48, '安路 PH1P35MDG324 FPGA（感知 · 决策 · 控制 全部在 FPGA 内完成）', { fs: 11.5, bold: true, color: C.accent });
  const xs = [3.85, 6.4, 8.95, 11.5, 14.05], wt = 2.2, yt = 8.7, ht = 1.2;
  const names = ['MIPI CSI-2 接收\n解包 · 取窗', 'ISP\n伽马 · 去马赛克 · AWB', '2.4× 等比缩放\n800×448',
    'DDR2 帧缓存\n四缓冲轮换', '显示合成 · OSD\n安路 Logo · DSI 发送'];
  xs.forEach((x, i) => { box(x, yt, wt, ht, names[i], { fc: C.fpga, fs: 9 }); if (i) arrow([xs[i - 1] + wt, yt + ht / 2], [x, yt + ht / 2]); });
  box(3.85, 6.95, 2.2, 1.0, '自动曝光 AE\nmc_ae', { fc: C.fpga, fs: 9 });
  arrow([6.9, yt], [5.6, 7.95], { text: '帧平均亮度', fs: 8, toff: [0.6, -0.15] });
  box(6.4, 5.35, 3.0, 1.15, '单目避障 mc_obs\n160×90 地面 / 障碍分类', { fc: C.fpga, fs: 9 });
  arrow([7.5, yt], [7.5, 6.5], { text: '并联\n1920×1080', fs: 8, toff: [0, -0.35] });
  poly([[9.0, 6.5], [9.0, 7.45], [15.15, 7.45], [15.15, yt]], { text: '避障画面 · 红框 · 方向', fs: 8, tpos: [12.3, 7.45] });
  box(10.25, 5.35, 2.9, 1.15, '跟随 + 避障决策\nmc_follow（每 20 ms）\n目标航向 + 角度环', { fc: C.fpga, fs: 8.6 });
  arrow([9.4, 5.92], [10.25, 5.92], { text: '9 方向\n可行距离', fs: 7.5, toff: [0, 0.08] });
  box(13.95, 5.35, 2.3, 1.15, '串口链路\nmc_m0_link', { fc: C.fpga, fs: 9 });
  arrow([13.15, 6.15], [13.95, 6.15], { text: '两轮 PWM', fs: 7.5 });
  arrow([13.95, 5.7], [13.15, 5.7], { text: '主人方位', fs: 7.5, toff: [0, -0.42] });
  box(11.0, 3.85, 2.6, 0.9, '陀螺仪接口 mc_imu_jy61p\n自动配置 · 停稳归零', { fc: C.fpga, fs: 8.2 });
  arrow([12.3, 4.75], [12.3, 5.35], { text: '航向 / 角速度', fs: 7.5, toff: [0.95, -0.2] });
  // behaviour row
  box(3.85, 2.25, 2.5, 1.45, '霍尔去抖 mc_hall\n按键 mc_key', { fc: C.fpga, fs: 9 });
  box(7.2, 2.45, 3.6, 1.05, '行为层 mc_behavior\n摇尾巴 · 进食音效 · 狗叫', { fc: C.fpga, fs: 9 });
  arrow([6.35, 2.97], [7.2, 2.97], { text: '喂食', fs: 8 });
  arrow([10.45, 5.35], [10.45, 3.5], { text: '困住', fs: 7.5, toff: [-0.38, -0.25] });
  poly([[14.6, 5.35], [14.6, 3.62], [9.6, 3.62], [9.6, 3.5]], { text: '主人距离', fs: 7.5, tpos: [14.0, 3.62] });
  box(11.6, 2.25, 2.4, 1.05, '尾巴驱动 mc_tail\nEmm 协议 UART', { fc: C.fpga, fs: 9 });
  arrow([10.8, 2.77], [11.6, 2.77]);
  box(7.2, 0.8, 6.8, 1.15, '音频子系统 mc_audio\nSD-SPI · FAT32 · 双路 WAV · 重采样混音 · I2S · ES8388 配置', { fc: C.fpga, fs: 9 });
  arrow([8.7, 2.45], [8.7, 1.95], { text: '进食音效 / 狗叫', fs: 7.5, toff: [1.05, -0.3] });
  // inputs
  box(0.2, 8.6, 2.95, 1.4, 'IMX415 摄像头\n1920×1080 60 fps\nMIPI 4 lane RAW10', { fc: C.sens, fs: 8.5 });
  arrow([3.15, 9.3], [3.85, 9.3]);
  poly([[3.85, 7.45], [1.7, 7.45], [1.7, 8.6]], { text: 'I2C 曝光 / 增益', fs: 8, tpos: [2.6, 7.45] });
  box(0.2, 3.25, 2.95, 0.85, '霍尔传感器（喂食检测）', { fc: C.sens, fs: 8.5 });
  box(0.2, 2.2, 2.95, 0.85, '按键 SW1 ~ SW3', { fc: C.sens, fs: 8.5 });
  arrow([3.15, 3.67], [3.85, 3.3]); arrow([3.15, 2.62], [3.85, 2.75]);
  box(0.2, 0.8, 2.95, 1.0, 'TF 卡（FAT32）\nWAV 音频文件', { fc: C.sens, fs: 8.5 });
  arrow([3.15, 1.3], [7.2, 1.3], { text: 'SPI', fs: 8 });
  // outputs
  box(16.95, 8.6, 3.05, 1.4, '10.1 英寸 MIPI 屏\n800×1280 竖屏\n相机 / 状态 / 避障', { fc: C.act, fs: 8.5 });
  arrow([16.25, 9.3], [16.95, 9.3], { text: 'DSI', fs: 7.5 });
  box(16.95, 5.0, 3.05, 2.0, 'STM32F103 接口板\n← UWB 基站 ×4\n（主人方位 / 距离）\n→ TB6612 · 两轮电机', { fc: C.mcu, fs: 8.5 });
  arrow([16.25, 5.92], [16.95, 5.92], { style: '<|-|>', text: 'UART', fs: 7.5 });
  box(16.95, 3.75, 3.05, 1.0, '维特 JY61P 陀螺仪\n航向角 / 角速度', { fc: C.sens, fs: 8.5 });
  arrow([13.6, 4.3], [16.95, 4.3], { style: '<|-|>', text: 'UART（上电自动配置）', fs: 7.5, toff: [0.55, 0.12] });
  box(16.95, 2.2, 3.05, 1.15, 'ZDT X42S 闭环步进\n（尾巴）', { fc: C.act, fs: 8.5 });
  arrow([14.0, 2.77], [16.95, 2.77], { text: 'UART 115200', fs: 8 });
  box(16.95, 0.75, 3.05, 1.2, 'ES8388 + TT8642×2\n喇叭 J12 / J11', { fc: C.act, fs: 8.5 });
  arrow([14.0, 1.35], [16.95, 1.35], { text: 'I2S + I2C', fs: 8 });
  [[C.sens, '传感 / 输入'], [C.fpga, 'FPGA 逻辑模块'], [C.act, '执行 / 输出'], [C.mcu, '接口板']].forEach(([fc, t], i) => {
    box(4.0 + i * 2.6, 0.08, 0.4, 0.3, '', { fc, r: 0.05 });
    label(4.5 + i * 2.6, 0.23, t, { fs: 8, ha: 'left' });
  });
};

// ------------------------------------------------------------------ 图2-3 硬件连接
FIGS.fig_hw = () => {
  const W = 20.2, H = 11.2; canvas(W, H);
  box(6.4, 3.1, 6.9, 4.4, '', { fc: C.fpga, ec: C.accent, lw: 1.8, r: 0.2 });
  label(9.85, 6.95, '米联客 MLKPAI-F02 开发平台', { fs: 11.5, bold: true, color: C.accent });
  label(9.85, 6.4, 'FC02 核心板：安路 PH1P35MDG324（合封 DDR2 512 Mb）', { fs: 9.5 });
  label(9.85, 5.35, '板载：ES8388 音频编解码 · TT8642 D 类功放 ×2\nTF 卡座（SPI 模式） · SW1~SW3 · LED1~LED3\n25 MHz 晶振 · Type-C（JTAG / 5 V）', { fs: 8.8, color: '#455A64' });
  label(9.85, 3.75, 'CEP 排针 2×20（3.3 V，不耐 5 V）\nCSI / DSI 40P FPC 连接器', { fs: 8.8, color: '#455A64' });
  box(5.6, 9.1, 4.0, 1.5, 'MLK-CAM002 摄像头\nSony IMX415 · f 4.2 mm\n离地 174 mm，竖直安装', { fc: C.sens, fs: 8.8 });
  arrow([7.6, 9.1], [7.6, 7.5], { text: 'CSI 口：MIPI 4 lane\n891 Mbps/lane + I2C', fs: 8, toff: [-1.4, -0.4] });
  box(10.3, 9.1, 4.0, 1.5, '10.1 英寸 MIPI DSI 屏\nILI9881C · 800×1280', { fc: C.act, fs: 8.8 });
  arrow([12.3, 7.5], [12.3, 9.1], { text: 'DSI 口：MIPI 4 lane\n548 Mbps/lane', fs: 8, toff: [1.35, -0.4] });
  // left
  box(0.3, 6.3, 4.1, 1.15, '维特 JY61P 陀螺仪\n3.3 V，平放在车身中部', { fc: C.sens, fs: 8.5 });
  arrow([4.4, 6.87], [6.4, 6.87], { style: '<|-|>', text: 'CEP 脚5 / 脚6', fs: 8 });
  box(0.3, 4.95, 4.1, 1.05, '霍尔传感器模块\n3.3 V 供电，磁铁靠近输出低', { fc: C.sens, fs: 8.5 });
  arrow([4.4, 5.47], [6.4, 5.47], { text: 'CEP 脚17（B17）', fs: 8 });
  box(0.3, 3.2, 4.1, 1.35, 'ZDT X42S 闭环步进（尾巴）\nEmm 固件 · TTL 串口\n独立电源 10~29 V', { fc: C.act, fs: 8.5 });
  arrow([6.4, 3.87], [4.4, 3.87], { text: 'CEP 脚15（E17）\nUART TX 115200', fs: 8, toff: [0, -0.05] });
  box(0.3, 0.45, 4.1, 2.25, '12 V 锂电池组 ×2\n（10.8 V，2550 mAh）\n→ 稳压 5 V / 3 A\n→ 开发板 / STM32 / 基站\n所有 GND 共地', { fc: C.gray, fs: 8.5 });
  poly([[4.4, 1.6], [5.6, 1.6], [5.6, 3.3], [6.4, 3.3]], { ls: '--', color: '#78909C', text: '5 V', fs: 8, tpos: [5.6, 2.45] });
  box(7.2, 0.45, 5.3, 1.45, '3020 腔体喇叭 ×2（4 Ω 3 W）\nJ12 左：背景音乐 / J11 右：音效 · 狗叫', { fc: C.act, fs: 8.5 });
  arrow([9.85, 3.1], [9.85, 1.9], { text: 'BTL 差分输出', fs: 8, toff: [1.0, -0.1] });
  // right
  box(15.3, 4.4, 4.6, 2.5, 'STM32F103RCT6 接口板\n四基站 UWB 融合 · 电机 PWM\n1.44 寸 LCD 调试屏\n（不参与跟随 / 避障决策）', { fc: C.mcu, fs: 8.5 });
  arrow([13.3, 6.0], [15.3, 6.0], { text: 'CEP 脚3（L15）→ PB11', fs: 7.8 });
  arrow([15.3, 5.25], [13.3, 5.25], { text: 'PB10 → CEP 脚4（L16）', fs: 7.8, toff: [0, -0.45] });
  label(14.3, 4.55, 'UART 115200 8N1', { fs: 7.8, color: C.purple });
  box(15.3, 8.45, 4.6, 1.95, '爱蓝信 ALX-G100A 基站 ×4\n左 / 前 / 右 / 后\n主人手持 U68 标签（小麦信标）', { fc: C.sens, fs: 8.5 });
  arrow([17.6, 8.45], [17.6, 6.9], { text: 'USART2 / UART4 / UART5 / USART1', fs: 7.5, toff: [0, -0.1] });
  box(15.3, 0.45, 4.6, 2.25, '直流减速电机 ×2（后轮差速）\nTB6612 驱动模块（D153C）', { fc: C.act, fs: 8.5 });
  arrow([17.6, 4.4], [17.6, 2.7], { text: 'TIM3 PWM 9 kHz + 方向', fs: 7.8, toff: [0, -0.1] });
};

// ------------------------------------------------------------------ 图2-9 时钟域
FIGS.fig_clk = () => {
  const W = 20.2, H = 10.6; canvas(W, H);
  const dom = (x, y, w, h, t, fc) => { box(x, y, w, h, '', { fc, ec: '#90A4AE', ls: '--', lw: 1.2, r: 0.2, z: 1 }); label(x + 0.2, y + h - 0.28, t, { fs: 9.5, ha: 'left', bold: true }); };
  box(0.3, 8.4, 3.4, 1.7, 'mcsys_pll\n25 MHz 晶振 →\n100 / 24 / 52.17 / 10 MHz', { fc: C.gray, fs: 8.5 });
  box(0.3, 6.3, 3.4, 1.7, '复位 / 节拍\nmc_hold_reset（SW1 2 s）\nmc_rst_sync · mc_tick', { fc: C.gray, fs: 8.5 });
  dom(4.2, 6.0, 7.4, 4.3, 'MIPI RX 字节时钟 111.4 MHz（像素域）', '#FFF8E1');
  box(4.45, 8.25, 3.3, 1.3, 'mc_cam_if\nD-PHY RX · CSI-2 / RAW10 解包\nmc_crop · mc_gamma', { fc: C.fpga, fs: 8.3 });
  box(8.05, 8.25, 3.3, 1.3, 'isp_top（去马赛克 + awb）\nmc_scale（2.4× + 128 位打包）', { fc: C.fpga, fs: 8.3 });
  box(6.2, 6.3, 3.6, 1.3, 'mc_obs 单目避障\nobs_down · class · morph · scan', { fc: C.fpga, fs: 8.3 });
  arrow([7.75, 8.9], [8.05, 8.9]); arrow([9.2, 8.25], [8.6, 7.6]);
  dom(12.1, 7.4, 3.6, 2.9, 'DDR 用户时钟 132.8 MHz', '#E8F5E9');
  box(12.35, 7.7, 3.1, 1.6, 'mc_framebuf\nvideo_in / video_out\nDDR2 控制器（四缓冲）', { fc: C.act, fs: 8.3 });
  dom(16.2, 4.3, 3.8, 6.0, 'DSI 字节时钟 68.49 MHz', '#E3F2FD');
  box(16.45, 7.3, 3.3, 2.1, 'mc_disp_if\nvideo_tpg · mc_mixer\nmc_osd_text · mc_osd_logo\nmc_obs_view\nDSI 打包 · D-PHY TX', { fc: C.sens, fs: 8.1 });
  box(16.45, 4.6, 3.3, 1.4, '10 MHz：mc_panel_ctrl\n屏幕 LP 初始化脚本（ROM）', { fc: C.gray, fs: 8.3 });
  arrow([18.1, 6.0], [18.1, 7.3]);
  dom(0.3, 3.4, 3.4, 2.5, '24 MHz', '#F3E5F5');
  box(0.5, 3.6, 3.0, 1.6, 'mc_ae 自动曝光\nuicfgimx415 + uii2c\n（I2C 写传感器）', { fc: C.mcu, fs: 8.3 });
  dom(4.2, 0.3, 11.5, 5.2, '系统时钟 100 MHz（控制域）', '#ECEFF1');
  const xs = [4.4, 7.25, 10.1, 12.95];
  [['mc_follow\n决策 + 角度环', 0, 3.2], ['mc_m0_link\nmc_uart_rx / tx', 1, 3.2], ['mc_imu_jy61p\n陀螺仪接口', 2, 3.2], ['mc_osd_dash\n6 行状态文字', 3, 3.2],
   ['mc_behavior\n行为层', 0, 1.55], ['mc_tail\nmc_stepper_emm', 1, 1.55], ['mc_audio\nSD · FAT32 · WAV · I2S', 2, 1.55], ['mc_hall · mc_key\nmc_bench', 3, 1.55]]
    .forEach(([t, i, y]) => box(xs[i], y, 2.6, 1.25, t, { fc: '#FFFFFF', fs: 8.3 }));
  label(9.95, 0.68, '全部用 1 ms / 10 ms / 100 ms 节拍做使能，不产生门控时钟', { fs: 8, color: '#546E7A' });
  arrow([11.35, 8.9], [12.35, 8.9], { text: '异步 FIFO\n128 bit', fs: 7.5, toff: [0, 0.05] });
  arrow([15.45, 8.5], [16.45, 8.5], { text: '异步 FIFO', fs: 7.5 });
  poly([[9.8, 6.75], [16.45, 6.75], [16.45, 7.3]], { text: '写总线 + 双缓冲 bank 握手', fs: 7.5, tpos: [13.4, 6.75] });
  arrow([7.2, 6.3], [5.7, 4.45], { text: '结果翻转信号同步', fs: 7.5, toff: [-1.25, 0.3] });
  poly([[15.55, 3.85], [15.95, 3.85], [15.95, 7.75], [16.45, 7.75]], { text: 'OSD 写总线\n双口字符 RAM', fs: 7.5, tpos: [15.25, 5.3] });
  poly([[4.45, 8.6], [3.95, 8.6], [3.95, 5.2], [3.5, 5.2]]);
  label(4.1, 7.0, '平均亮度（翻转同步）', { fs: 7.5, rotation: 90 });
};

// ------------------------------------------------------------------ 图2-11 屏幕版面
FIGS.fig_layout = () => {
  const s = 1 / 100, W = 17.0, H = 13.6; canvas(W, H);
  const ox = 0.5, oy = 0.4;
  const R = (u0, v0, u1, v1, fc, ec = 'none', lw = 0, z = 2) => rect(ox + u0 * s, oy + (1280 - v1) * s, (u1 - u0) * s, (v1 - v0) * s, { fc, ec, lw, z });
  R(0, 0, 800, 1280, '#111111', '#263238', 1.5, 1);
  R(0, 0, 800, 448, '#90CAF9'); R(0, 300, 800, 448, '#A1887F'); R(0, 120, 800, 300, '#B0BEC5');
  label(ox + 4.0, oy + (1280 - 200) * s, '相机窗口 800×448\n传感器完整视场（等比缩小 2.4 倍）', { fs: 9, color: '#0D47A1' });
  for (let k = 0; k < 8; k++) R(40 + 90 * k, 452, 120 + 90 * k, 492, k === 0 ? '#E53935' : '#43A047');
  const lines = ['GAIN 050  HALL 0            KEY 000 UP 00123s', 'SD READY  CODEC OK    BGM PLAY  SFX IDLE EV+0',
    'K3 SHORT  SW2/3 EV+/- SW1 2s reset EXP 2275', 'NEAR 045cm -12deg  GO   +05deg 150cm',
    'UWB OK   -12deg 350cm  CMD GO   L+3000 R+2100', 'IMU OK   YAW +012deg  TGT +015deg  GZ -003d/s'];
  lines.forEach((t, i) => label(ox + 40 * s, oy + (1280 - 496 - 32 * i - 16) * s, t, { fs: 5.4, color: '#FFFFFF', ha: 'left', family: 'Consolas,monospace' }));
  R(160, 690, 640, 818, '#FFFFFF');
  image('logo_preview.png', ox + 160 * s, oy + (1280 - 818) * s, 480 * s, 128 * s, 3);
  R(330, 820, 470, 828, '#00E676');
  R(0, 830, 800, 1280, '#7E57C2'); R(0, 830, 800, 1095, '#757575');
  polygon([[ox + 120 * s, oy], [ox + 300 * s, oy + (1280 - 1095) * s], [ox + 520 * s, oy + (1280 - 1095) * s], [ox + 710 * s, oy]], { fc: '#66BB6A', z: 3 });
  R(250, 1120, 360, 1210, 'none', '#FF1744', 2, 4);
  R(280, 1240, 520, 1280, 'none', '#FFEB3B', 2, 4);
  label(ox + 4.0, oy + (1280 - 900) * s, '避障画面 800×450（160×90 格 × 5）', { fs: 9, color: '#FFFFFF' });
  const xa = ox + 8.0 + 0.4;
  [[224, 'v 0 ~ 447：相机实时画面（自动曝光 + 白平衡）'],
   [472, 'v 452 ~ 491：8 个状态方块（心跳 / DDR2 / 屏幕 / 相机 /\n     MIPI 帧 / 帧缓存 / 通道无错 / 色序参考）'],
   [592, 'v 496 ~ 687：6 行状态文字（45 列，16×32 字符）\n     曝光 · 霍尔 · 按键 · 音频 · 避障 · 跟随 · 陀螺仪'],
   [754, 'v 690 ~ 817：安路 Logo（480×128，存于 ERAM）'],
   [824, 'v 820 ~ 827：建议方向绿条（STOP 时不显示）'],
   [1070, 'v 830 ~ 1279：避障处理画面\n     绿 = 地面  紫 = 障碍  灰 = 约 2.36 m 以外\n     红框 = 障碍框  黄框 = 地面参考区']].forEach(([v, t]) => {
    const y = oy + (1280 - v) * s;
    line([[ox + 8.0, y], [xa, y]], { color: '#90A4AE', lw: 0.8, z: 5 });
    label(xa + 0.1, y, t, { fs: 8.6, ha: 'left' });
  });
  label(ox + 4.0, oy + 12.8 + 0.25, '800 像素', { fs: 8.5, color: '#546E7A' });
};

// ------------------------------------------------------------------ 图2-12 避障算法流程
FIGS.fig_obs = () => {
  const W = 16.5, H = 13.8; canvas(W, H);
  const steps = [
    ['① 12×12 均值下采样', '1920×1080 → 160×90，四舍五入；平均掉噪声和地面纹理', 'mc_obs_down'],
    ['② 颜色空间变换', 'Y = (R+2G+B)/4，Cb = B−Y，Cr = R−Y（只用移位加减）', 'mc_obs_class'],
    ['③ 地面模型查询', '色度 16×16 格 + 亮度 16 格；两个直方图计数都 ≥ 15 → 地面', 'mc_obs_class'],
    ['④ 地面模型在线更新', '车前参考区 48×8 格（约 49~58 cm）：旧直方图 × 3/4 + 本帧计数', 'mc_obs_class'],
    ['⑤ 3×3 多数表决去噪', '9 格中 ≥ 5 格为障碍才算障碍', 'mc_obs_morph'],
    ['⑥ 列扫描', '每列自第 53 行（约 2.36 m）向下找最靠下的连续 ≥ 2 格障碍（接地点）', 'mc_obs_scan'],
    ['⑦ 扇区距离', '每 10 列一个扇区（约 4.5°）→ 查几何表得地面距离，与上一帧取近', 'mc_obs_scan / lut'],
    ['⑧ 障碍框合并', '相邻扇区都有障碍且上下范围重叠 → 合成一个红框', 'mc_obs_scan'],
    ['⑨ 车宽走廊选方向', '9 个方向（±17°）× 30 cm 走廊 → 可行距离；取最远，< 60 cm 则 STOP', 'mc_obs_scan']];
  const x0 = 0.4, w = 11.2, h = 1.0, gap = 0.32, ys = [];
  steps.forEach(([t, d, m], i) => {
    const y = H - 0.4 - (i + 1) * h - i * gap; ys.push(y);
    box(x0, y, w, h, '', { fc: i === 3 ? C.yellow : C.fpga });
    label(x0 + 0.25, y + h / 2 + 0.18, t, { fs: 10, ha: 'left', bold: true, color: '#212121' });
    label(x0 + 0.25, y + h / 2 - 0.2, d, { fs: 8.5, ha: 'left', color: '#455A64' });
    label(x0 + w + 0.2, y + h / 2, m, { fs: 8.5, ha: 'left', color: C.blued });
    if (i) arrow([x0 + 3.0, ys[i - 1]], [x0 + 3.0, y + h]);
  });
  poly([[x0 + 8.5, ys[3] + h], [x0 + 8.5, ys[2]]], { color: C.accent });
  label(x0 + 9.2, (ys[3] + h + ys[2]) / 2, '每帧更新模型', { fs: 8, color: C.accent });
  const yo = ys[8] - 1.25;
  ['显示端 mc_obs_view\n（屏幕下半部分）', '跟随决策 mc_follow\n（9 方向可行距离）', '文字第 4 行\n（最近障碍 / 建议方向）'].forEach((t, j) => {
    const xb = x0 + j * 3.85;
    box(xb, yo - 0.05, 3.5, 1.0, t, { fc: C.act, fs: 8.5 });
    arrow([x0 + 3.0, ys[8]], [xb + 1.75, yo + 0.95], { lw: 1.0 });
  });
};

// ------------------------------------------------------------------ 图2-13 车宽走廊（俯视）
FIGS.fig_corridor = () => {
  const W = 15.0, H = 12.6; canvas(W, H);
  const sc = 0.042, cx = 7.5, cy = 2.4;
  const P = (x, y) => [cx + x * sc, cy + y * sc];
  const arc = (r, a0, a1) => { const pts = []; for (let i = 0; i <= 60; i++) { const a = rad(a0 + (a1 - a0) * i / 60); pts.push(P(r * Math.sin(a), r * Math.cos(a))); } return pts; };
  // blind zone
  polygon([P(0, 0), ...arc(49, -32, 32)], { fc: '#ECEFF1', z: 1 });
  label(...P(-30, 16), '49 cm 内看不到地面', { fs: 7.5, color: '#78909C', ha: 'right' });
  for (const a of [-32, 32]) line([P(0, 0), P(245 * Math.sin(rad(a)), 245 * Math.cos(rad(a)))], { color: '#B0BEC5', lw: 1, ls: ':' });
  for (const [r, t] of [[49, '49 cm（画面下沿）'], [100, '100 cm（进入即算挡路）'], [150, '150 cm（选方向最远计到）'], [236, '236 cm（第 53 行，判断区上沿）']]) {
    line(arc(r, -32, 32), { color: '#90A4AE', lw: 1, ls: '--' });
    if (r > 200) label(...P(-r * Math.sin(rad(32)) - 4, r * Math.cos(rad(32))), t, { fs: 8, ha: "right" }); else label(...P(r * Math.sin(rad(32)) + 4, r * Math.cos(rad(32))), t, { fs: 8, ha: "left" });
  }
  for (const a of [-17, -13, -9, -4, 0, 4, 9, 13, 17]) {
    line([P(0, 0), P(150 * Math.sin(rad(a)), 150 * Math.cos(rad(a)))], { color: '#78909C', lw: 0.8 });
    label(...P(160 * Math.sin(rad(a)), 160 * Math.cos(rad(a))), `${a > 0 ? '+' : ''}${a}°`, { fs: 7.5 });
  }
  const a = rad(9), ux = Math.sin(a), uy = Math.cos(a), nx = Math.cos(a), ny = -Math.sin(a), L = 150;
  polygon([[-15 * nx, -15 * ny], [15 * nx, 15 * ny], [15 * nx + L * ux, 15 * ny + L * uy], [-15 * nx + L * ux, -15 * ny + L * uy]].map(c => P(...c)), { fc: '#A5D6A7', ec: '#2E7D32', alpha: 0.55, lw: 1.2, z: 2 });
  label(...P(40, 112), '选中方向 +9°\n30 cm 走廊（车宽 20 + 两侧各 5）', { fs: 8.5, color: C.green, ha: 'left' });
  polygon([[-15, 0], [15, 0], [15, L], [-15, L]].map(c => P(...c)), { ec: '#E53935', ls: '--', lw: 1.2, z: 2 });
  circle(...P(-9, 82), 8 * sc, { fc: '#7E57C2', ec: '#4527A0' });
  circle(...P(-52, 125), 10 * sc, { fc: '#7E57C2', ec: '#4527A0' });
  label(...P(-34, 82), '障碍：挡住\n正前方走廊', { fs: 8, color: '#4527A0' });
  label(...P(-82, 112), '障碍：离 +9° 走廊 > 15 cm\n不挡这个方向', { fs: 8, color: '#4527A0', ha: 'right' });
  rect(...P(-10, -50), 20 * sc, 50 * sc, { fc: '#FFCC80', ec: '#E65100', lw: 1.4, z: 4 });
  label(...P(0, -30), '车身\n宽 20 cm', { fs: 8 });
  circle(...P(0, -37), 0.06, { fc: '#212121', ec: '#212121' });
  label(...P(13, -37), '后轴中点（原地转中心）', { fs: 7.5, ha: 'left', color: '#546E7A' });
  circle(cx, cy, 0.08, { fc: '#212121', ec: '#212121' });
  label(cx + 1.2, cy - 0.35, '摄像头：车头正中，离地 174 mm，竖直安装', { fs: 8, ha: 'left', color: '#546E7A' });
};

// ------------------------------------------------------------------ 图2-14 跟随与避障决策
FIGS.fig_follow = () => {
  const W = 22.0, H = 17.6; canvas(W, H);
  const xa = 3.3;
  box(xa - 3.0, 16.3, 6.0, 1.0, '每 20 ms：取 UWB 目标、最近一帧\n避障结果、陀螺仪航向 ψ', { fc: C.sens, fs: 8.8 });
  box(xa - 3.0, 14.85, 6.0, 1.0, '主人方向 θ = ψ + UWB 角度（平滑 1/3）\n相对角 a = θ − ψ', { fs: 8.6 });
  arrow([xa, 16.3], [xa, 15.85]);
  const ds = [['300 ms 内收到\nUWB 有效帧？', 'LOST 停车', '否'], ['陀螺仪就绪？\n（配置完、已归零）', 'NIMU 停车', '否'],
    ['100 ms 内有\n避障结果？', 'NCAM 停车', '否'], ['距离 > 200 cm？', 'HERE 停车（到了）', '否']];
  const ys = [13.45, 11.55, 9.65, 7.75];
  let prev = 14.85;
  ds.forEach(([q, act, br], i) => {
    const y = ys[i];
    arrow([xa, prev], [xa, y + 0.7]);
    diamond(xa, y, 4.4, 1.4, q, { fs: 8.5 });
    box(6.3, y - 0.42, 2.9, 0.84, act, { fc: C.red, fs: 8.5 });
    arrow([xa + 2.2, y], [6.3, y], { text: br, fs: 8, toff: [0, 0.04] });
    label(xa + 0.22, y - 0.92, '是', { fs: 8, ha: 'left' });
    line([[9.2, y], [9.7, y]], { color: '#E57373', ls: '--', lw: 1.3 });
    prev = y - 0.7;
  });
  label(9.45, 10.6, '停车：两轮直接归 0，发 #S*', { fs: 8, color: '#C62828', rotation: 90 });
  line([[9.7, ys[0]], [9.7, ys[3]]], { color: '#E57373', ls: '--', lw: 1.3 });
  const yt = 5.75;
  arrow([xa, prev], [xa, yt + 0.75]);
  diamond(xa, yt, 4.8, 1.5, '|a| > 90° 且保持 0.3 s？\n（直走锁定 / 找出口时暂缓）', { fs: 8.2 });
  box(6.3, yt - 0.55, 3.2, 1.1, 'TURN 原地转向主人\n两轮 ±2200\n|a| < 40° 退出', { fc: C.mcu, fs: 8.2 });
  arrow([xa + 2.4, yt], [6.3, yt], { text: '是', fs: 8, toff: [0, 0.04] });
  label(xa + 0.22, yt - 0.98, '否', { fs: 8, ha: 'left' });
  box(xa - 3.0, 3.1, 6.0, 1.05, '前进量 f = 3300 + (d − 200) × 10\n（上限 5000）', { fs: 8.8 });
  arrow([xa, yt - 0.75], [xa, 4.15]);
  arrow([xa, 3.1], [xa, 2.45]);
  connector(xa, 2.15, 'A');
  // blocked chain (middle) — side boxes on its left, "not blocked" summary box on the right
  const xm = 15.4;
  connector(xm, 16.9, 'A');
  arrow([xm, 16.6], [xm, 16.2]);
  diamond(xm, 15.4, 5.0, 1.6, '挡路？正前方或主人方向\n可行距离 < 100 cm', { fs: 8.4 });
  box(12.8, 12.25, 5.2, 1.45, '选绕行方向 h（9 个候选，±17°）\n代价 = 2|h − a| + |h − h_prev|\n先挑 ≥ 100 cm，没有再挑 ≥ 60 cm', { fs: 8.2 });
  arrow([xm, 14.6], [xm, 13.7], { text: '是', fs: 8, toff: [0.3, -0.25] });
  diamond(xm, 10.65, 3.8, 1.25, '有可选方向？', { fs: 8.5 });
  arrow([xm, 12.25], [xm, 11.28]);
  box(10.05, 9.5, 3.1, 2.3, '找出口（BLK / SPIN 交替）\n停 0.2 s 看 → 转 20° → 再看\n转满 360° 仍无出口\n→ 困住：停车并狗叫', { fc: C.red, fs: 7.8 });
  arrow([xm - 1.9, 10.65], [13.15, 10.65], { text: '否', fs: 8, toff: [0, 0.04] });
  diamond(xm, 8.55, 3.8, 1.25, '正前方 < 60 cm？', { fs: 8.5 });
  arrow([xm, 10.03], [xm, 9.18], { text: '是', fs: 8, toff: [0.3, -0.25] });
  box(11.5, 8.1, 1.65, 0.9, 'SPIN 原地\n转向 h', { fc: C.mcu, fs: 8 });
  arrow([xm - 1.9, 8.55], [13.15, 8.55], { text: '是', fs: 8, toff: [0, 0.04] });
  box(xm - 2.2, 6.5, 4.4, 0.9, 'AVD：目标航向 = ψ + h\n（回差 4°，不左右换边）', { fc: C.act, fs: 8.2 });
  arrow([xm, 7.92], [xm, 7.4], { text: '否', fs: 8, toff: [0.3, -0.25] });
  poly([[xm + 2.5, 15.4], [20.1, 15.4], [20.1, 14.85]], { text: '否', fs: 8, tpos: [18.7, 15.4] });
  box(18.3, 11.6, 3.55, 3.25, '不挡路（依次判断）：\n① 刚绕完、直走未满 50 cm\n    → AVD：保持绕行航向\n② 主人方向远处挡路\n    可行 < min(200, d − 60) cm\n    → AVD：提前绕\n③ 否则 GO：目标航向 = θ\n    （回差 4°）', { fc: C.act, fs: 7.9, ha: 'left' });
  // output column
  const xo = 13.0, wo = 8.85;
  box(xo, 5.15, wo, 0.85, '限速：f ≤ 3300 + (前方可行距离 − 60) × 20', { fs: 8.5 });
  box(xo, 3.35, wo, 1.35, '角度环（GO / AVD）：e = 目标航向 − ψ\nt = 70·e + I − 10·ω，|e| ≤ 10° 才积分（I ≤ ±400）\n|t| ≤ 1500，每 20 ms 变化 ≤ 800', { fc: C.yellow, fs: 8.2 });
  box(10.0, 1.85, 11.85, 1.05, '两轮：L = f + t，R = f − t（原地转：f = 0，t = ±2200）\n限幅 ±6500；f 斜坡每 20 ms 最多 +200 / −400', { fs: 8.3 });
  box(10.0, 0.45, 11.85, 0.95, '经 mc_m0_link 发送 #±LLLL±RRRR* / #S* → STM32 驱动两轮', { fc: C.mcu, fs: 8.5 });
  arrow([xm, 6.5], [xm, 6.0]);
  arrow([20.1, 11.6], [20.1, 6.0]);
  arrow([xm, 5.15], [xm, 4.7]); arrow([xm, 3.35], [xm, 2.9]); arrow([xm, 1.85], [xm, 1.4]);
  arrow([11.0, 9.5], [11.0, 2.9]);
  arrow([12.3, 8.1], [12.3, 2.9]);
  poly([[9.5, yt], [10.6, yt], [10.6, 2.9]]);
  poly([[9.7, ys[3]], [9.7, 0.92], [10.0, 0.92]], { color: '#E57373', ls: '--' });
};

// ------------------------------------------------------------------ 图2-15 行为层 + 尾巴
FIGS.fig_behavior = () => {
  const W = 20.2, H = 8.4; canvas(W, H);
  box(0.2, 6.3, 2.6, 1.1, '霍尔 D0（低有效）', { fc: C.sens, fs: 8.5 });
  box(3.3, 6.3, 2.9, 1.1, 'mc_hall\n两级同步 + 20 ms 去抖', { fc: C.fpga, fs: 8.3 });
  arrow([2.8, 6.85], [3.3, 6.85]);
  box(0.2, 4.55, 6.0, 1.2, 'mc_m0_link：UWB 链路 / 有效 / 主人距离', { fc: C.fpga, fs: 8.3 });
  box(0.2, 3.0, 6.0, 1.05, 'mc_follow：困住（转满一圈无出口）', { fc: C.fpga, fs: 8.3 });
  box(6.8, 2.2, 6.4, 5.85, '', { fc: '#FFF8E1', ec: '#BCAAA4', ls: '--', r: 0.15 });
  label(10.0, 7.75, 'mc_behavior 行为层', { fs: 9.5, bold: true });
  box(7.05, 5.75, 5.9, 1.6, '摇尾巴：喂食 或 主人在身边\n（距离 < 300 cm 保持 0.3 s；≥ 320 cm 或丢失即离开）\n→ 尾巴空闲时发一次摇摆，摇完条件仍在就再摇', { fc: '#FFFFFF', fs: 7.9 });
  box(7.05, 4.25, 5.9, 1.2, '进食音效：喂食上升沿 → 播 2.wav 一遍\n播放中不重复触发，拿开再靠近才重播', { fc: '#FFFFFF', fs: 7.9 });
  box(7.05, 2.45, 5.9, 1.5, '狗叫：链路通且（UWB 丢失或距离 ≥ 999 cm）\n持续 1 s，或者困住 → 循环播 3.wav\n（STM32 没接 / 没开时不叫）', { fc: '#FFFFFF', fs: 7.9 });
  arrow([6.2, 6.85], [7.05, 6.6], { text: '喂食', fs: 7.5, toff: [-0.1, 0.05] });
  arrow([6.2, 6.6], [7.05, 4.85]);
  arrow([6.2, 5.15], [7.05, 6.1]);
  arrow([6.2, 4.75], [7.05, 3.4]);
  arrow([6.2, 3.52], [7.05, 3.0]);
  box(13.8, 5.95, 2.3, 1.2, 'mc_tail\n动作序列', { fc: C.fpga, fs: 8.3 });
  box(13.8, 3.5, 2.3, 1.6, 'mc_audio\n音效通道\n（右声道 J11）', { fc: C.fpga, fs: 8.3 });
  arrow([12.95, 6.55], [13.8, 6.55]);
  arrow([12.95, 4.85], [13.8, 4.6]);
  arrow([12.95, 3.2], [13.8, 3.9]);
  const x0 = 16.55, y0 = 0.6;
  box(x0 - 0.15, y0 - 0.3, 3.75, 7.65, '', { fc: '#FAFAFA', ec: '#CFD8DC', r: 0.15 });
  label(x0 + 1.72, y0 + 7.0, '尾巴动作（mc_tail）', { fs: 9, bold: true });
  const seq = ['上电 1 s：解除保护 → 使能', '单圈就近回零\n01 9A 00 00 6B', '等 2 s → 设坐标零点\n01 0A 6D 6B', '空闲，等待摇摆命令',
    '中 → 左 45° → 右 45° → 中\n（左右之间不停）', '10 RPM；两头停 50 ms\n回中停 500 ms，一遍约 3.6 s'];
  seq.forEach((t, i) => {
    const yy = y0 + 6.2 - i * 1.07;
    box(x0, yy - 0.42, 3.45, 0.84, t, { fc: i < 3 ? C.mcu : C.act, fs: 7.6 });
    if (i && i !== 5) arrow([x0 + 1.72, yy + 0.65], [x0 + 1.72, yy + 0.42]);
  });
  arrow([16.1, 6.55], [x0, 6.55], { lw: 1.0 });
  label(0.3, 1.3, '尾巴命令帧按 ZDT Emm 固件手册逐字节生成，UART 115200 8N1 只发不收，按"走完时间 + 停顿"定时推进', { fs: 8.2, ha: 'left', color: '#546E7A' });
  label(0.3, 0.75, '行为层、尾巴、音频都在 100 MHz 域，与视频通路只共用时钟、复位和节拍', { fs: 8.2, ha: 'left', color: '#546E7A' });
};

// ------------------------------------------------------------------ 图2-16 音频子系统
FIGS.fig_audio = () => {
  const W = 20.2, H = 7.4; canvas(W, H);
  box(0.2, 2.9, 1.9, 1.4, 'TF 卡\nFAT32', { fc: C.sens, fs: 9 });
  box(2.6, 2.9, 2.3, 1.4, 'mc_sd_spi\nSPI 模式读扇区\n390 kHz → 12.5 MHz', { fc: C.fpga, fs: 8.2 });
  box(5.4, 2.9, 2.2, 1.4, 'mc_sd_arb\n两路轮询仲裁', { fc: C.fpga, fs: 8.2 });
  box(8.1, 1.2, 3.6, 4.9, '', { fc: '#FFF8E1', ec: '#BCAAA4', ls: '--', r: 0.15 });
  label(9.9, 5.8, 'mc_fat32', { fs: 9, bold: true });
  box(8.35, 4.2, 3.1, 1.2, 'mc_fat_dir\n挂载 + 根目录扫描\nN.WAV 目录表（64 项）', { fc: C.fpga, fs: 8 });
  box(8.35, 2.6, 3.1, 1.0, 'mc_fat_rd #0\n沿簇链读 1.wav', { fc: C.fpga, fs: 8 });
  box(8.35, 1.4, 3.1, 1.0, 'mc_fat_rd #1\n读 2.wav / 3.wav', { fc: C.fpga, fs: 8 });
  box(12.2, 2.75, 2.5, 1.1, 'mc_wav_player #0\n背景音乐 循环', { fc: C.fpga, fs: 8 });
  box(12.2, 1.3, 2.5, 1.1, 'mc_wav_player #1\n音效 / 狗叫', { fc: C.fpga, fs: 8 });
  box(15.2, 1.3, 2.3, 2.55, 'mc_audio_mix\n零阶保持重采样\n8 ~ 48.8 kHz\nL = 背景音乐\nR = 音效 / 狗叫', { fc: C.fpga, fs: 8 });
  box(15.2, 4.4, 2.3, 1.1, 'mc_i2s_tx\nMCLK 12.5 MHz\nLRCK 48.828 kHz', { fc: C.fpga, fs: 7.8 });
  box(18.0, 3.6, 2.0, 2.0, 'ES8388\n→ TT8642 ×2\n→ J12 / J11', { fc: C.act, fs: 8 });
  box(12.2, 5.6, 5.3, 1.0, 'mc_es8388_cfg + mc_i2c_wr：21 条寄存器（I2C 0x11）', { fc: C.fpga, fs: 8 });
  box(12.2, 0.05, 3.4, 0.95, 'mc_behavior：喂食 → 2.wav\n太远 / 丢失 / 困住 → 3.wav 循环', { fc: C.mcu, fs: 7.6 });
  arrow([2.1, 3.6], [2.6, 3.6], { style: '<|-|>' });
  arrow([4.9, 3.6], [5.4, 3.6], { style: '<|-|>' });
  arrow([7.6, 3.8], [8.35, 4.6], { style: '<|-|>' });
  arrow([7.6, 3.4], [8.35, 3.1], { style: '<|-|>' });
  arrow([7.6, 3.1], [8.35, 1.9], { style: '<|-|>' });
  arrow([11.45, 3.1], [12.2, 3.3]); arrow([11.45, 1.9], [12.2, 1.85]);
  arrow([14.7, 3.3], [15.2, 3.3]); arrow([14.7, 1.85], [15.2, 1.85]);
  arrow([16.35, 3.85], [16.35, 4.4]);
  arrow([17.5, 4.95], [18.0, 4.95], { text: 'I2S', fs: 7.5 });
  poly([[17.5, 6.1], [19.0, 6.1], [19.0, 5.6]], { text: 'I2C', fs: 7.5, tpos: [18.3, 6.1] });
  arrow([13.45, 1.0], [13.45, 1.3]);
  label(3.0, 0.7, '全部在 100 MHz 单时钟域；挂载 + 目录表只做一次，两路读文件共享', { fs: 8.5, color: '#546E7A', ha: 'left' });
};

function run() {
  const name = location.hash.slice(1);
  FIGS[name]();
  document.title = `${W_ * UNIT}x${H_ * UNIT}`;
}
