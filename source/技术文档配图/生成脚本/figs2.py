import sys, os, math
sys.path.insert(0, os.path.dirname(__file__))
from dg import *
import numpy as np

OUT = sys.argv[1]


# ---------------------------------------------------------------- FPGA 内部架构 / 时钟域
def fig_clk():
    W, H = 20.2, 10.6
    fig, ax = canvas(W, H)

    def dom(x, y, w, h, title, fc):
        box(ax, x, y, w, h, '', fc=fc, ec='#90A4AE', ls='--', lw=1.2, r=0.2, z=1)
        label(ax, x + 0.2, y + h - 0.28, title, fs=9.5, ha='left', bold=True, color='#37474F')

    # PLL
    box(ax, 0.3, 8.4, 3.4, 1.7, 'mcsys_pll\n25 MHz 晶振 →\n100 / 24 / 52.17 / 10 MHz', fc=C['gray'], fs=8.5)
    box(ax, 0.3, 6.3, 3.4, 1.7, '复位 / 节拍\nmc_hold_reset（SW1 2 s）\nmc_rst_sync · mc_tick', fc=C['gray'], fs=8.5)
    # MIPI RX domain
    dom(4.2, 6.0, 7.4, 4.3, 'MIPI RX 字节时钟 111.4 MHz（像素域）', '#FFF8E1')
    box(ax, 4.45, 8.25, 3.3, 1.3, 'mc_cam_if\nD-PHY RX · CSI-2 / RAW10 解包\nmc_crop · mc_gamma', fc=C['fpga'], fs=8.3)
    box(ax, 8.05, 8.25, 3.3, 1.3, 'isp_top（去马赛克 + awb）\nmc_scale（2.4× + 128 位打包）', fc=C['fpga'], fs=8.3)
    box(ax, 6.2, 6.3, 3.6, 1.3, 'mc_obs 单目避障\nobs_down · class · morph · scan', fc=C['fpga'], fs=8.3)
    arrow(ax, (7.75, 8.9), (8.05, 8.9))
    arrow(ax, (9.2, 8.25), (8.6, 7.6))
    # DDR domain
    dom(12.1, 7.4, 3.6, 2.9, 'DDR 用户时钟 132.8 MHz', '#E8F5E9')
    box(ax, 12.35, 7.7, 3.1, 1.6, 'mc_framebuf\nvideo_in / video_out\nDDR2 控制器（四缓冲）', fc=C['act'], fs=8.3)
    # DSI domain
    dom(16.2, 4.3, 3.8, 6.0, 'DSI 字节时钟 68.49 MHz', '#E3F2FD')
    box(ax, 16.45, 7.5, 3.3, 1.9, 'mc_disp_if\nvideo_tpg · mc_mixer\nmc_osd_text · mc_obs_view\nDSI 打包 · D-PHY TX', fc=C['sens'], fs=8.3)
    box(ax, 16.45, 4.6, 3.3, 1.4, '10 MHz：mc_panel_ctrl\n屏幕 LP 初始化脚本（ROM）', fc=C['gray'], fs=8.3)
    arrow(ax, (18.1, 6.0), (18.1, 7.5))
    # 24 MHz domain
    dom(0.3, 3.4, 3.4, 2.5, '24 MHz', '#F3E5F5')
    box(ax, 0.5, 3.6, 3.0, 1.6, 'mc_ae 自动曝光\nuicfgimx415 + uii2c\n（I2C 写传感器）', fc=C['mcu'], fs=8.3)
    # 100 MHz domain
    dom(4.2, 0.3, 11.5, 5.2, '系统时钟 100 MHz（控制域）', '#ECEFF1')
    mods = [('mc_follow\n跟随 + 避障决策', 4.45, 3.2), ('mc_m0_link\nmc_uart_rx / tx', 8.25, 3.2),
            ('mc_osd_dash\n5 行状态文字', 12.05, 3.2),
            ('mc_behavior\n行为层', 4.45, 1.55), ('mc_tail\nmc_stepper_emm', 8.25, 1.55),
            ('mc_audio\nSD · FAT32 · WAV · I2S', 12.05, 1.55)]
    for t, x, y in mods:
        box(ax, x, y, 3.4, 1.25, t, fc='#FFFFFF', fs=8.3)
    label(ax, 9.95, 0.6, 'mc_hall · mc_key · mc_bench · mc_activity_mon 同在本域，1 ms / 10 ms / 100 ms 节拍做使能', fs=8,
          color='#546E7A')
    # CDC arrows
    arrow(ax, (11.35, 8.9), (12.35, 8.9), text='异步 FIFO\n128 bit', fs=7.5, toff=(0, 0.05))
    arrow(ax, (15.45, 8.5), (16.45, 8.5), text='异步 FIFO', fs=7.5)
    poly(ax, [(9.8, 6.75), (16.45, 6.75), (16.45, 7.5)], text='写总线 + 双缓冲 bank 握手', fs=7.5, tpos=(13.4, 6.75))
    arrow(ax, (7.2, 6.3), (6.2, 4.45), text='结果翻转信号同步', fs=7.5, toff=(-1.3, 0.3))
    poly(ax, [(15.45, 3.85), (15.95, 3.85), (15.95, 7.9), (16.45, 7.9)], text='OSD 写总线\n双口字符 RAM', fs=7.5,
         tpos=(15.25, 5.3), tha='center')
    poly(ax, [(4.45, 8.6), (3.95, 8.6), (3.95, 5.2), (3.5, 5.2)])
    label(ax, 4.1, 7.0, '平均亮度（翻转同步）', fs=7.5, rotation=90, ha='left')
    save(fig, f'{OUT}/fig_clk.png')


# ---------------------------------------------------------------- 视频通路
def fig_isp():
    W, H = 20.2, 7.6
    fig, ax = canvas(W, H)
    r1 = [('IMX415\n2×2 binning', C['sens']), ('D-PHY RX\n4 lane 891 Mbps', C['fpga']), ('CSI-2 解包\n只收 RAW10 包', C['fpga']),
          ('RAW10 解包\n每拍 4 像素', C['fpga']), ('mc_crop 取窗\n1920×1080', C['fpga']), ('mc_gamma\n减黑电平 + 伽马查表', C['fpga'])]
    r2 = [('去马赛克\n双线性 3×3 · RGGB', C['fpga']), ('自动白平衡 awb\n灰度世界，每帧一次', C['fpga']),
          ('mc_scale\n12→5 二维加权缩放', C['fpga']), ('128 位打包\n每行 150 字', C['fpga']), ('DDR2 帧缓存\n四缓冲，读滞后 2 帧', C['act']),
          ('mc_mixer → DSI\n10.1" 屏', C['act'])]
    w, h, gap = 2.85, 1.25, 0.45
    y1, y2 = 5.3, 2.2
    for i, (t, fc) in enumerate(r1):
        x = 0.3 + i * (w + gap)
        box(ax, x, y1, w, h, t, fc=fc, fs=8.6)
        if i:
            arrow(ax, (x - gap, y1 + h / 2), (x, y1 + h / 2))
    fmt1 = ['', 'MIPI', '字节流', 'RAW10', '1920×1080', '']
    for i, t in enumerate(fmt1):
        if t:
            label(ax, 0.3 + i * (w + gap) - gap / 2, y1 + h + 0.2, t, fs=7.5, color='#78909C')
    xe = 0.3 + 5 * (w + gap) + w / 2
    poly(ax, [(xe, y1), (xe, 4.35), (0.3 + w / 2, 4.35), (0.3 + w / 2, y2 + h)], text='8 bit RAW', fs=7.5,
         tpos=(10.0, 4.35))
    for i, (t, fc) in enumerate(r2):
        x = 0.3 + i * (w + gap)
        box(ax, x, y2, w, h, t, fc=fc, fs=8.6)
        if i:
            arrow(ax, (x - gap, y2 + h / 2), (x, y2 + h / 2))
    fmt2 = ['', 'RGB888×4', 'RGB888×4', '800×448', '128 bit', '24 bit']
    for i, t in enumerate(fmt2):
        if t:
            label(ax, 0.3 + i * (w + gap) - gap / 2, y2 + h + 0.2, t, fs=7.5, color='#78909C')
    # AE loop
    xg = 0.3 + 5 * (w + gap)
    box(ax, xg + 0.1, 6.75, 2.65, 0.75, 'mc_ae 自动曝光', fc=C['mcu'], fs=8.6)
    arrow(ax, (xg + 1.4, y1 + h), (xg + 1.4, 6.75), text='', fs=7.5)
    label(ax, xg - 0.55, 6.72, '帧平均亮度', fs=7.5, color='#78909C')
    poly(ax, [(xg + 0.1, 7.12), (0.3 + w / 2, 7.12), (0.3 + w / 2, y1 + h)], text='I2C：SHR0 曝光 + 增益（REGHOLD 同帧生效）',
         fs=7.5, tpos=(7.5, 7.12))
    # obstacle branch
    xa = 0.3 + 1 * (w + gap) + w / 2
    poly(ax, [(xa, y2), (xa, 1.2), (xa + 1.2, 1.2)], fs=7.5)
    box(ax, xa + 1.2, 0.55, 5.2, 1.25, 'mc_obs 单目避障（并联支路）\n12×12 均值 → 160×90 → 地面 / 障碍 → 方向', fc=C['yellow'], fs=8.6)
    label(ax, xa + 9.9, 1.17, '不占 DDR 带宽，全部用行缓存 / 片内 RAM', fs=8, color='#546E7A')
    save(fig, f'{OUT}/fig_isp.png')


# ---------------------------------------------------------------- 屏幕版面
def fig_layout():
    s = 1 / 100.0
    W, H = 17.0, 13.6
    fig, ax = canvas(W, H, scale=0.6)
    ox, oy = 0.5, 0.4

    def R(u0, v0, u1, v1, fc, ec='none', lw=0, z=2):
        ax.add_patch(Rectangle((ox + u0 * s, oy + (1280 - v1) * s), (u1 - u0) * s, (v1 - v0) * s, fc=fc, ec=ec, lw=lw,
                               zorder=z))

    R(0, 0, 800, 1280, '#111111', ec='#263238', lw=1.5, z=1)
    # camera window: gradient-like "scene"
    R(0, 0, 800, 448, '#90CAF9')
    R(0, 300, 800, 448, '#A1887F')
    R(0, 120, 800, 300, '#B0BEC5')
    ax.text(ox + 4.0, oy + (1280 - 200) * s, '相机窗口 800×448\n传感器完整视场（等比缩小 2.4 倍）', ha='center', va='center',
            fontsize=9, color='#0D47A1', zorder=5)
    # status squares
    cols = ['#43A047'] * 8
    cols[0] = '#E53935'
    for k in range(8):
        R(40 + 90 * k, 456, 120 + 90 * k, 496, cols[k])
    # OSD text
    lines = ['GAIN 050  HALL 0  TAIL IDLE KEY 000 UP 00123s', 'SD READY  CODEC OK    BGM PLAY  SFX IDLE EV+0',
             'K3 SHORT  SW2/3 EV+/- SW1 2s reset EXP 2275', 'NEAR 045cm -12deg  GO   +05deg 150cm',
             'UWB OK   -12deg 350cm  CMD GO   L+3000 R+2100']
    for i, t in enumerate(lines):
        ax.text(ox + 40 * s, oy + (1280 - 504 - 32 * i - 16) * s, t, ha='left', va='center', fontsize=5.6,
                color='white', family='monospace', zorder=5)
    ax.text(ox + 4.0, oy + (1280 - 742) * s, '（预留：安路 Logo / 说明）', ha='center', va='center', fontsize=8.5,
            color='#9E9E9E', zorder=5)
    # direction bar
    R(330, 820, 470, 828, '#00E676')
    # obstacle view
    R(0, 830, 800, 1280, '#7E57C2')
    R(0, 830, 800, 960, '#757575')
    for (u0, u1, vtop) in [(0, 180, 1010), (600, 800, 1060)]:
        pass
    ax.add_patch(Polygon([(ox + 130 * s, oy + 0), (ox + 300 * s, oy + (1280 - 960) * s), (ox + 520 * s, oy + (1280 - 960) * s),
                          (ox + 700 * s, oy + 0)], fc='#66BB6A', zorder=3))
    R(250, 1010, 370, 1150, 'none', ec='#FF1744', lw=2, z=4)
    R(280, 1240, 520, 1280, 'none', ec='#FFEB3B', lw=2, z=4)
    ax.text(ox + 4.0, oy + (1280 - 880) * s, '避障画面 800×450（160×90 格 × 5）', ha='center', va='center', fontsize=9,
            color='white', zorder=5)
    # annotations
    xa = ox + 8.0 + 0.4
    notes = [(224, 'v 0 ~ 447：相机实时画面（自动曝光 + 白平衡）'),
             (476, 'v 456 ~ 495：8 个状态方块（心跳 / DDR2 / 屏幕 / 相机 /\n     MIPI 帧 / 帧缓存 / 通道无错 / 色序参考）'),
             (584, 'v 504 ~ 663：5 行文字（45 列，16×32 字符）\n     AE · 霍尔 · 尾巴 · 按键 · 音频 · 避障 · 跟随'),
             (742, 'v 664 ~ 819：预留区'),
             (824, 'v 820 ~ 827：建议方向绿条（STOP 时不显示）'),
             (1055, 'v 830 ~ 1279：避障处理画面\n     绿 = 地面  紫 = 障碍  灰 = 1.5 m 外\n     红框 = 障碍框  黄框 = 地面参考区')]
    for v, t in notes:
        y = oy + (1280 - v) * s
        ax.plot([ox + 8.0, xa], [y, y], color='#90A4AE', lw=0.8, zorder=5)
        ax.text(xa + 0.1, y, t, ha='left', va='center', fontsize=8.6, color='#37474F', zorder=5, linespacing=1.35)
    ax.text(ox + 4.0, oy + 12.8 + 0.25, '800 像素', ha='center', fontsize=8.5, color='#546E7A')
    save(fig, f'{OUT}/fig_layout.png')


# ---------------------------------------------------------------- 避障算法流程
def fig_obs():
    W, H = 16.5, 13.8
    fig, ax = canvas(W, H)
    steps = [('① 12×12 均值下采样', '1920×1080 → 160×90，四舍五入；平均掉噪声和地面纹理', 'mc_obs_down'),
             ('② 颜色空间变换', 'Y = (R+2G+B)/4，Cb = B−Y，Cr = R−Y（只用移位加减）', 'mc_obs_class'),
             ('③ 地面模型查询', '色度 16×16 格 + 亮度 16 格；直方图计数 ≥ 12 → 地面', 'mc_obs_class'),
             ('④ 地面模型在线更新', '车前参考区 48×8 格：旧直方图 × 3/4 + 本帧计数', 'mc_obs_class'),
             ('⑤ 3×3 多数表决去噪', '9 格中 ≥ 5 格为障碍才算障碍', 'mc_obs_morph'),
             ('⑥ 列扫描', '每列自 1.5 m 线向下找最靠下的连续 ≥ 2 格障碍（接地点）', 'mc_obs_scan'),
             ('⑦ 扇区距离', '每 10 列一个扇区（≈4.5°）→ 查表得地面距离，与上帧取近', 'mc_obs_scan / lut'),
             ('⑧ 障碍框合并', '相邻扇区都有障碍且上下范围重叠 → 合成一个红框', 'mc_obs_scan'),
             ('⑨ 车宽走廊选方向', '9 个方向（±19°）× 30 cm 走廊 → 可行距离；取最远，< 35 cm 则 STOP', 'mc_obs_scan')]
    x0, w, h, gap = 0.4, 11.2, 1.0, 0.32
    ys = []
    for i, (t, d, m) in enumerate(steps):
        y = H - 0.4 - (i + 1) * h - i * gap
        ys.append(y)
        fc = C['yellow'] if i == 3 else C['fpga']
        box(ax, x0, y, w, h, '', fc=fc)
        label(ax, x0 + 0.25, y + h / 2 + 0.18, t, fs=10, ha='left', bold=True)
        label(ax, x0 + 0.25, y + h / 2 - 0.2, d, fs=8.5, ha='left', color='#455A64')
        label(ax, x0 + w + 0.2, y + h / 2, m, fs=8.5, ha='left', color=C['blued'])
        if i:
            arrow(ax, (x0 + 3.0, ys[i - 1]), (x0 + 3.0, y + h))
    # model loop 4 -> 3
    poly(ax, [(x0 + 8.5, ys[3] + h), (x0 + 8.5, ys[2])], color=C['accent'])
    label(ax, x0 + 9.2, (ys[3] + h + ys[2]) / 2, '更新模型', fs=8, color=C['accent'])
    # outputs
    yo = ys[-1] - 1.25
    for j, t in enumerate(['显示端 mc_obs_view\n（屏幕下半部分）', '跟随决策 mc_follow\n（9 方向可行距离）', '文字第 4 行\n（最近障碍 / 建议方向）']):
        xb = x0 + j * 3.85
        box(ax, xb, yo - 0.05, 3.5, 1.0, t, fc=C['act'], fs=8.5)
        arrow(ax, (x0 + 3.0, ys[-1]), (xb + 1.75, yo + 0.95), lw=1.0)
    save(fig, f'{OUT}/fig_obs.png')


# ---------------------------------------------------------------- 车宽走廊示意（俯视）
def fig_corridor():
    W, H = 15.0, 10.5
    fig, ax = canvas(W, H)
    sc = 0.055  # 1 cm -> units
    cx, cy = 7.5, 1.4

    def P(xcm, ycm):
        return (cx + xcm * sc, cy + ycm * sc)

    # camera FOV +-36 deg
    for a in (-36, 36):
        r = 165
        x, y = P(r * math.sin(math.radians(a)), r * math.cos(math.radians(a)))
        ax.plot([cx, x], [cy, y], color='#B0BEC5', lw=1, ls=':')
    # range arcs
    for r, t in ((23, '23 cm（画面下沿）'), (150, '150 cm（判断上限）')):
        th = np.linspace(math.radians(-36), math.radians(36), 60)
        pts = [P(r * math.sin(a), r * math.cos(a)) for a in th]
        ax.plot([p[0] for p in pts], [p[1] for p in pts], color='#90A4AE', lw=1, ls='--')
        label(ax, *P(r * math.sin(math.radians(36)) + 4, r * math.cos(math.radians(36))), t, fs=8, ha='left')
    # 9 headings
    heads = [-19, -15, -10, -5, 0, 5, 10, 15, 19]
    for a in heads:
        x, y = P(150 * math.sin(math.radians(a)), 150 * math.cos(math.radians(a)))
        ax.plot([cx, x], [cy, y], color='#78909C', lw=0.8)
        label(ax, *P(158 * math.sin(math.radians(a)), 158 * math.cos(math.radians(a))), f'{a:+d}°', fs=7.5)
    # chosen heading corridor (+10 deg)
    a = math.radians(10)
    ux, uy = math.sin(a), math.cos(a)
    nx, ny = math.cos(a), -math.sin(a)
    L = 150
    corners = [(-15 * nx, -15 * ny), (15 * nx, 15 * ny), (15 * nx + L * ux, 15 * ny + L * uy),
               (-15 * nx + L * ux, -15 * ny + L * uy)]
    ax.add_patch(Polygon([P(*c) for c in corners], fc='#A5D6A7', ec='#2E7D32', alpha=0.55, lw=1.2, zorder=2))
    label(ax, *P(42, 120), '选中方向 +10°\n30 cm 走廊（车宽 20 + 两侧各 5）', fs=8.5, color=C['green'])
    # forward corridor blocked
    corners0 = [(-15, 0), (15, 0), (15, L), (-15, L)]
    ax.add_patch(Polygon([P(*c) for c in corners0], fc='none', ec='#E53935', ls='--', lw=1.2, zorder=2))
    # obstacles
    for (x, y, r) in ((-12, 65, 7), (-48, 110, 10)):
        ax.add_patch(matplotlib.patches.Circle(P(x, y), r * sc, fc='#7E57C2', ec='#4527A0', zorder=3))
    label(ax, *P(-30, 66), '障碍：挡住\n正前方走廊', fs=8, color='#4527A0')
    label(ax, *P(-48, 126), '障碍：离走廊 > 15 cm\n不挡 +10° 方向', fs=8, color='#4527A0')
    # car
    ax.add_patch(Rectangle(P(-10, -22), 20 * sc, 22 * sc, fc='#FFCC80', ec='#E65100', lw=1.4, zorder=4))
    label(ax, *P(0, -11), '车 20 cm', fs=8)
    ax.add_patch(matplotlib.patches.Circle((cx, cy), 0.08, fc='#212121', zorder=5))
    label(ax, cx + 2.6, cy - 0.5, '摄像头：离地 174 mm，下倾 15°，H72°', fs=8, color='#546E7A')
    save(fig, f'{OUT}/fig_corridor.png')


# ---------------------------------------------------------------- 跟随决策流程
def fig_follow():
    W, H = 22.0, 16.2
    fig, ax = canvas(W, H)
    xa = 3.2
    box(ax, xa - 2.8, 14.9, 5.6, 0.95, '每 20 ms：取 UWB 目标 + 最近一帧避障结果', fc=C['sens'], fs=8.8)
    box(ax, xa - 2.8, 13.55, 5.6, 0.85, '角度平滑：a += (新角度 − a) / 3', fc='#FFFFFF', fs=8.8)
    arrow(ax, (xa, 14.9), (xa, 14.4))
    ds = [('300 ms 内收到\nUWB 有效帧？', 'LOST 停车', '否', '是', C['red']),
          ('100 ms 内有\n避障结果？', 'NCAM 停车', '否', '是', C['red']),
          ('距离 > 300 cm？', 'HERE 停车（到了）', '否', '是', C['red']),
          ('|a| > 90° 且\n保持 0.3 s？', 'TURN 原地转向主人\n|a| < 40° 才退出', '是', '否', C['mcu'])]
    ys = [12.15, 10.15, 8.15, 6.15]
    prev = 13.55
    for (q, act, br, dn, fc), y in zip(ds, ys):
        arrow(ax, (xa, prev), (xa, y + 0.72))
        diamond(ax, xa, y, 4.4, 1.44, q, fs=8.5)
        box(ax, 6.2, y - 0.48, 3.3, 0.96, act, fc=fc, fs=8.5)
        arrow(ax, (xa + 2.2, y), (6.2, y), text=br, fs=8, toff=(0, 0.04))
        label(ax, xa + 0.22, y - 0.95, dn, fs=8, ha='left')
        prev = y - 0.72
    box(ax, xa - 2.8, 3.9, 5.6, 0.95, '前进量 f = 3000 + (d − 300) × 10\n（上限 5000）', fc='#FFFFFF', fs=8.8)
    arrow(ax, (xa, prev), (xa, 4.85))
    arrow(ax, (xa, 3.9), (xa, 3.25))
    ax.add_patch(matplotlib.patches.Circle((xa, 2.95), 0.3, fc='#FFFFFF', ec=C['edge'], lw=1.2, zorder=3))
    label(ax, xa, 2.95, 'A', fs=9, bold=True)
    # stop line (dashed) and TURN line
    for y in ys[:3]:
        ax.plot([9.5, 10.0], [y, y], color='#E57373', ls='--', lw=1.3, zorder=4)
    poly(ax, [(10.0, ys[0]), (10.0, 1.55), (12.3, 1.55)], color='#E57373', ls='--')
    label(ax, 9.75, 4.0, '停车：两轮直接归 0，发 #S*', fs=8, color='#C62828', rotation=90)
    poly(ax, [(9.5, ys[3]), (10.5, ys[3]), (10.5, 3.4), (12.3, 3.4)])
    # right column
    xc = 15.2
    ax.add_patch(matplotlib.patches.Circle((xc, 15.45), 0.3, fc='#FFFFFF', ec=C['edge'], lw=1.2, zorder=3))
    label(ax, xc, 15.45, 'A', fs=9, bold=True)
    arrow(ax, (xc, 15.15), (xc, 14.75))
    diamond(ax, xc, 13.95, 5.8, 1.6, '挡路？正前方或主人方向\n可行距离 < 100 cm', fs=8.5)
    box(ax, 18.4, 11.15, 3.4, 1.55, 'GO：转向对着主人\n死区 ±5°，0.3 %/°，≤ 9 %\n绕行后 0.5 s 内先直走', fc=C['act'], fs=8.2)
    poly(ax, [(xc + 2.9, 13.95), (20.1, 13.95), (20.1, 12.7)], text='否', fs=8, tpos=(19.2, 13.95))
    box(ax, xc - 2.8, 11.0, 5.6, 1.3, '选绕行方向（9 个候选）\n代价 = 2|h − a| + |h − h_prev|\n先挑 ≥ 100 cm，没有再挑 ≥ 60 cm', fc='#FFFFFF',
        fs=8.2)
    arrow(ax, (xc, 13.15), (xc, 12.3), text='是', fs=8, toff=(0.3, -0.2))
    diamond(ax, xc, 9.55, 4.2, 1.4, '有可选方向？', fs=8.5)
    arrow(ax, (xc, 11.0), (xc, 10.25))
    box(ax, 10.9, 9.1, 1.9, 0.9, 'BLK 停车', fc=C['red'], fs=8.5)
    arrow(ax, (xc - 2.1, 9.55), (12.8, 9.55), text='否', fs=8)
    poly(ax, [(11.85, 9.1), (11.85, 1.85), (12.3, 1.85)], color='#E57373', ls='--')
    diamond(ax, xc, 7.55, 4.2, 1.4, '正前方 < 45 cm？', fs=8.5)
    arrow(ax, (xc, 8.85), (xc, 8.25), text='是', fs=8, toff=(0.3, -0.2))
    box(ax, 18.1, 7.1, 2.9, 0.9, 'SPIN 原地转向\n选中方向', fc=C['mcu'], fs=8.3)
    arrow(ax, (xc + 2.1, 7.55), (18.1, 7.55), text='是', fs=8)
    box(ax, xc - 2.0, 5.55, 4.0, 0.95, 'AVD 边走边转向选中方向\n1.2 %/°，≤ 30 %，每次 ≤ 40', fc=C['act'], fs=8.2)
    arrow(ax, (xc, 6.85), (xc, 6.5), text='否', fs=8, toff=(0.3, -0.25))
    box(ax, 12.3, 4.25, 6.4, 0.85, '限速：f ≤ 3000 + (前方可行距离 − 60) × 20', fc='#FFFFFF', fs=8.6)
    arrow(ax, (xc, 5.55), (xc, 5.1))
    poly(ax, [(21.3, 11.15), (21.3, 4.68), (18.7, 4.68)])
    box(ax, 12.3, 2.75, 9.3, 1.0, '两轮：L = f + t，R = f − t（原地转：±2200）\n限幅 ±6500；斜坡每 20 ms 最多 +200 / −400', fc='#FFFFFF', fs=8.6)
    arrow(ax, (xc, 4.25), (xc, 3.75))
    poly(ax, [(19.55, 7.1), (19.55, 3.75)])
    box(ax, 12.3, 1.2, 9.3, 1.0, '经 mc_m0_link 发送 #±LLLL±RRRR* / #S* → STM32 驱动两轮', fc=C['mcu'], fs=8.6)
    arrow(ax, (xc, 2.75), (xc, 2.2))
    save(fig, f'{OUT}/fig_follow.png')


# ---------------------------------------------------------------- 音频子系统
def fig_audio():
    W, H = 20.2, 7.4
    fig, ax = canvas(W, H)
    box(ax, 0.2, 2.9, 1.9, 1.4, 'TF 卡\nFAT32', fc=C['sens'], fs=9)
    box(ax, 2.6, 2.9, 2.3, 1.4, 'mc_sd_spi\nSPI 模式读扇区\n390 kHz → 12.5 MHz', fc=C['fpga'], fs=8.2)
    box(ax, 5.4, 2.9, 2.2, 1.4, 'mc_sd_arb\n两路轮询仲裁', fc=C['fpga'], fs=8.2)
    box(ax, 8.1, 1.2, 3.6, 4.9, '', fc='#FFF8E1', ec='#BCAAA4', ls='--', r=0.15)
    label(ax, 9.9, 5.8, 'mc_fat32', fs=9, bold=True)
    box(ax, 8.35, 4.2, 3.1, 1.2, 'mc_fat_dir\n挂载 + 根目录扫描\nN.WAV 目录表（64 项）', fc=C['fpga'], fs=8)
    box(ax, 8.35, 2.6, 3.1, 1.0, 'mc_fat_rd #0\n沿簇链读 1.wav', fc=C['fpga'], fs=8)
    box(ax, 8.35, 1.4, 3.1, 1.0, 'mc_fat_rd #1\n读音效文件', fc=C['fpga'], fs=8)
    box(ax, 12.2, 2.75, 2.5, 1.1, 'mc_wav_player #0\n背景音乐 循环', fc=C['fpga'], fs=8)
    box(ax, 12.2, 1.3, 2.5, 1.1, 'mc_wav_player #1\n音效 一次一遍', fc=C['fpga'], fs=8)
    box(ax, 15.2, 1.3, 2.3, 2.55, 'mc_audio_mix\n零阶保持重采样\n8 ~ 48.8 kHz\nL = 背景音乐\nR = 音效', fc=C['fpga'], fs=8)
    box(ax, 15.2, 4.4, 2.3, 1.1, 'mc_i2s_tx\nMCLK 12.5 MHz\nLRCK 48.828 kHz', fc=C['fpga'], fs=7.8)
    box(ax, 18.0, 3.6, 2.0, 2.0, 'ES8388\n→ TT8642 ×2\n→ J12 / J11', fc=C['act'], fs=8)
    box(ax, 12.2, 5.6, 5.3, 1.0, 'mc_es8388_cfg + mc_i2c_wr：21 条寄存器（I2C 0x11）', fc=C['fpga'], fs=8)
    box(ax, 12.2, 0.05, 2.5, 0.95, 'mc_behavior\n喂食 → 播 2.wav', fc=C['mcu'], fs=8)
    arrow(ax, (2.1, 3.6), (2.6, 3.6), style='<|-|>')
    arrow(ax, (4.9, 3.6), (5.4, 3.6), style='<|-|>')
    arrow(ax, (7.6, 3.8), (8.35, 4.6), style='<|-|>')
    arrow(ax, (7.6, 3.4), (8.35, 3.1), style='<|-|>')
    arrow(ax, (7.6, 3.1), (8.35, 1.9), style='<|-|>')
    arrow(ax, (11.45, 3.1), (12.2, 3.3))
    arrow(ax, (11.45, 1.9), (12.2, 1.85))
    arrow(ax, (14.7, 3.3), (15.2, 3.3))
    arrow(ax, (14.7, 1.85), (15.2, 1.85))
    arrow(ax, (16.35, 3.85), (16.35, 4.4))
    arrow(ax, (17.5, 4.95), (18.0, 4.95), text='I2S', fs=7.5)
    poly(ax, [(17.5, 6.1), (19.0, 6.1), (19.0, 5.6)], text='I2C', fs=7.5, tpos=(18.3, 6.1))
    arrow(ax, (13.45, 1.0), (13.45, 1.3), text='', fs=7.5)
    label(ax, 3.0, 0.7, '全部在 100 MHz 单时钟域；挂载 + 目录表只做一次，两路读文件共享', fs=8.5, color='#546E7A', ha='left')
    save(fig, f'{OUT}/fig_audio.png')


# ---------------------------------------------------------------- 行为层 + 尾巴时序
def fig_behavior():
    W, H = 20.2, 7.2
    fig, ax = canvas(W, H)
    box(ax, 0.2, 4.6, 2.5, 1.2, '霍尔 D0\n（低有效）', fc=C['sens'], fs=8.5)
    box(ax, 3.2, 4.6, 2.8, 1.2, 'mc_hall\n两级同步 + 20 ms 去抖', fc=C['fpga'], fs=8.3)
    arrow(ax, (2.7, 5.2), (3.2, 5.2))
    box(ax, 6.6, 3.2, 3.8, 3.9, '', fc='#FFF8E1', ec='#BCAAA4', ls='--', r=0.15)
    label(ax, 8.5, 6.8, 'mc_behavior 行为层', fs=9, bold=True)
    box(ax, 6.85, 5.1, 3.3, 1.25, '摇尾：尾巴空闲且回零完成\n→ 发一次摇摆；摇完仍在喂食\n→ 再摇一个来回', fc='#FFFFFF', fs=7.8)
    box(ax, 6.85, 3.45, 3.3, 1.35, '音效：喂食上升沿且本次\n未触发 → 播 2.wav 一遍\n播放中不重复触发', fc='#FFFFFF', fs=7.8)
    arrow(ax, (6.0, 5.2), (6.85, 5.6), text='O_fed', fs=7.5, toff=(-0.1, 0.0))
    arrow(ax, (6.0, 5.0), (6.85, 4.1))
    box(ax, 0.2, 2.6, 5.8, 1.2, '预留：I_near（UWB 近 → 摇尾）· I_bark（丢失 → 狗叫 3.wav）', fc=C['gray'], fs=8, ls='--')
    arrow(ax, (6.0, 3.2), (6.85, 3.7), ls='--')
    box(ax, 10.9, 5.1, 2.4, 1.25, 'mc_tail\n动作序列', fc=C['fpga'], fs=8.3)
    box(ax, 10.9, 3.45, 2.4, 1.35, 'mc_audio\n音效通道', fc=C['fpga'], fs=8.3)
    arrow(ax, (10.15, 5.72), (10.9, 5.72))
    arrow(ax, (10.15, 4.12), (10.9, 4.12))
    # tail timeline
    x0, y0 = 13.9, 0.6
    box(ax, x0 - 0.15, y0 - 0.25, 6.4, 6.6, '', fc='#FAFAFA', ec='#CFD8DC', r=0.15)
    label(ax, x0 + 3.05, y0 + 5.95, '尾巴动作（mc_tail → mc_stepper_emm）', fs=9, bold=True)
    seq = ['上电 1 s：解除堵转保护 → 使能', '单圈就近回零  01 9A 00 00 6B', '等 2 s → 设坐标零点  01 0A 6D 6B',
           '空闲（IDLE），等待摇摆命令', '摇摆：中 → 左 45° → 中 → 右 45° → 中', '10 RPM；两头停 50 ms，中间停 500 ms']
    for i, t in enumerate(seq):
        yy = y0 + 5.2 - i * 0.88
        fc = C['mcu'] if i < 3 else C['act']
        box(ax, x0, yy - 0.33, 6.1, 0.66, t, fc=fc, fs=8)
        if i and i != 5:
            arrow(ax, (x0 + 3.05, yy + 0.55), (x0 + 3.05, yy + 0.33))
    arrow(ax, (13.3, 5.72), (x0, 5.72 - 0.95), lw=1.0)
    label(ax, 0.3, 1.2, '帧格式按 ZDT Emm 固件手册第 5 章逐字节生成；UART 115200 8N1，只发不收，按"走完时间 + 停顿"定时推进', fs=8.3,
          ha='left', color='#546E7A')
    save(fig, f'{OUT}/fig_behavior.png')


if __name__ == '__main__':
    import matplotlib
    for f in (fig_clk, fig_isp, fig_layout, fig_obs, fig_corridor, fig_follow, fig_audio, fig_behavior):
        f()
    print('ok')
