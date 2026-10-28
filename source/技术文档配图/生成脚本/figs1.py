import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from dg import *

OUT = sys.argv[1]
os.makedirs(OUT, exist_ok=True)


# ---------------------------------------------------------------- 设计流程
def fig_flow():
    W, H = 13, 12.2
    fig, ax = canvas(W, H)
    steps = [
        ('赛题分析与需求定义', '选题二：MIPI 采集 + FPGA 图像处理 + OSD + 机电联动'),
        ('系统方案设计', '感知、决策、控制全部放在 FPGA；STM32 只作 UWB / 电机接口'),
        ('模块划分与接口定义', '时钟域、像素流格式、写总线、串口帧协议'),
        ('RTL 设计（Verilog）', '自写 mc_* 模块 + 厂商 MIPI / DDR2 / DSI IP'),
        ('测试台仿真 + 突变检查', 'Icarus Verilog，29 个自检测试台'),
        ('TD 综合、布局布线、时序收敛', '安路 TD 6.2.1，0 时序违例'),
        ('分模块上板调试', '屏幕状态带 / LED / ChipWatcher 定位问题'),
        ('整车联调与参数整定', '跟随参数先在 STM32 上车调好，再逐位移植到 FPGA'),
        ('性能测试与文档整理', ''),
    ]
    x0, w, h, gap = 0.6, 8.6, 0.92, 0.38
    ys = []
    for i, (t, s) in enumerate(steps):
        y = H - 0.5 - (i + 1) * h - i * gap
        ys.append(y)
        fc = C['fpga'] if 3 <= i <= 6 else C['sens']
        box(ax, x0, y, w, h, '', fc=fc)
        label(ax, x0 + 0.25, y + h / 2 + (0.17 if s else 0), f'{i + 1}. {t}', fs=10.5, ha='left', bold=True)
        if s:
            label(ax, x0 + 0.25, y + h / 2 - 0.2, s, fs=8.5, ha='left', color='#546E7A')
        if i:
            arrow(ax, (x0 + w / 2, ys[i - 1]), (x0 + w / 2, y + h))
    # feedback loops on the right
    def back(i_from, i_to, xr, text):
        yf = ys[i_from] + h / 2
        yt = ys[i_to] + h / 2
        poly(ax, [(x0 + w, yf), (xr, yf), (xr, yt), (x0 + w, yt)], color=C['accent'], lw=1.1)
        label(ax, xr + 0.2, (yf + yt) / 2, text, fs=8.5, color=C['accent'], rotation=90)
    back(4, 3, 9.75, '仿真不过')
    back(5, 3, 10.55, '时序不收敛')
    back(6, 2, 11.35, '上板问题')
    back(7, 1, 12.15, '整车效果')
    save(fig, f'{OUT}/fig_flow.png')


# ---------------------------------------------------------------- 系统整体框图
def fig_system():
    W, H = 20.2, 10.8
    fig, ax = canvas(W, H)
    # FPGA frame
    box(ax, 3.55, 0.6, 12.9, 9.9, '', fc=C['fpgabg'], ec=C['accent'], lw=1.8, r=0.25, z=1)
    label(ax, 10.0, 10.12, '安路 PH1P35MDG324 FPGA（感知 · 决策 · 控制 全部在 FPGA 内完成）', fs=11.5, bold=True,
          color=C['accent'])
    # top chain
    xs = [3.85, 6.4, 8.95, 11.5, 14.05]
    names = ['MIPI CSI-2 接收\n解包 · 取窗', 'ISP\n伽马 · 去马赛克 · AWB', '2.4× 等比缩放\n800×448',
             'DDR2 帧缓存\n四缓冲轮换', '显示合成 · OSD\nMIPI DSI 发送']
    yt, ht, wt = 8.3, 1.15, 2.2
    for i, (x, n) in enumerate(zip(xs, names)):
        box(ax, x, yt, wt, ht, n, fc=C['fpga'], fs=9)
        if i:
            arrow(ax, (xs[i - 1] + wt, yt + ht / 2), (x, yt + ht / 2))
    # AE
    box(ax, 3.85, 6.55, 2.2, 1.0, '自动曝光 AE\nmc_ae', fc=C['fpga'], fs=9)
    arrow(ax, (6.9, yt), (5.6, 7.55), text='帧平均亮度', fs=8, toff=(0.55, -0.15))
    # obstacle / follow / link
    box(ax, 6.4, 4.95, 3.0, 1.15, '单目避障 mc_obs\n160×90 地面 / 障碍分类', fc=C['fpga'], fs=9)
    arrow(ax, (7.5, yt), (7.5, 6.1), text='并联\n1920×1080', fs=8, toff=(0.0, -0.35))
    poly(ax, [(9.0, 6.1), (9.0, 7.05), (15.15, 7.05), (15.15, yt)], text='避障画面 · 红框 · 方向', fs=8,
         tpos=(12.3, 7.05))
    box(ax, 10.25, 4.95, 2.9, 1.15, '跟随 + 避障决策\nmc_follow（每 20 ms）', fc=C['fpga'], fs=9)
    arrow(ax, (9.4, 5.52), (10.25, 5.52), text='9 方向\n可行距离', fs=7.5, toff=(0.0, 0.08))
    box(ax, 13.95, 4.95, 2.3, 1.15, '串口链路\nmc_m0_link', fc=C['fpga'], fs=9)
    arrow(ax, (13.15, 5.75), (13.95, 5.75), text='两轮 PWM', fs=7.5)
    arrow(ax, (13.95, 5.3), (13.15, 5.3), text='主人方位', fs=7.5, toff=(0, -0.42))
    # behaviour row
    box(ax, 3.85, 2.75, 2.5, 1.45, '霍尔去抖 mc_hall\n按键 mc_key', fc=C['fpga'], fs=9)
    box(ax, 7.2, 2.95, 3.0, 1.05, '行为层 mc_behavior\n喂食 → 摇尾 + 音效', fc=C['fpga'], fs=9)
    arrow(ax, (6.35, 3.48), (7.2, 3.48), text='喂食', fs=8)
    box(ax, 11.3, 2.95, 2.5, 1.05, '尾巴驱动 mc_tail\nEmm 协议 UART', fc=C['fpga'], fs=9)
    arrow(ax, (10.2, 3.48), (11.3, 3.48), text='摇摆命令', fs=8)
    # audio
    box(ax, 7.2, 0.85, 6.6, 1.25, '音频子系统 mc_audio\nSD-SPI · FAT32 · 双路 WAV 解析 · 重采样混音 · I2S · ES8388 配置', fc=C['fpga'],
        fs=9)
    arrow(ax, (8.7, 2.95), (8.7, 2.1), text='进食音效', fs=8, toff=(0.65, -0.15))
    # inputs
    box(ax, 0.2, 8.2, 2.95, 1.35, 'IMX415 摄像头\n1920×1080 60 fps\nMIPI 4 lane RAW10', fc=C['sens'], fs=8.5)
    arrow(ax, (3.15, 8.87), (3.85, 8.87))
    poly(ax, [(3.85, 7.05), (1.7, 7.05), (1.7, 8.2)], text='I2C 曝光 / 增益', fs=8, tpos=(2.6, 7.05))
    box(ax, 0.2, 3.55, 2.95, 0.9, '霍尔传感器（喂食检测）', fc=C['sens'], fs=8.5)
    box(ax, 0.2, 2.45, 2.95, 0.9, '按键 SW1 ~ SW3', fc=C['sens'], fs=8.5)
    arrow(ax, (3.15, 4.0), (3.85, 3.75))
    arrow(ax, (3.15, 2.9), (3.85, 3.15))
    box(ax, 0.2, 0.9, 2.95, 1.0, 'TF 卡（FAT32）\nWAV 音频文件', fc=C['sens'], fs=8.5)
    arrow(ax, (3.15, 1.4), (7.2, 1.4), text='SPI', fs=8)
    # outputs
    box(ax, 16.95, 8.2, 3.05, 1.35, '10.1 英寸 MIPI 屏\n800×1280 竖屏\n相机 / 状态 / 避障', fc=C['act'], fs=8.5)
    arrow(ax, (16.25, 8.87), (16.95, 8.87), text='DSI', fs=7.5)
    box(ax, 16.95, 4.55, 3.05, 1.95, 'STM32F103 接口板\n← UWB 基站 ×3\n（主人方位 / 距离）\n→ 电机驱动 · 两轮', fc=C['mcu'],
        fs=8.5)
    arrow(ax, (16.25, 5.52), (16.95, 5.52), style='<|-|>', text='UART', fs=7.5)
    box(ax, 16.95, 2.9, 3.05, 1.15, 'ZDT X42S 闭环步进\n（尾巴）', fc=C['act'], fs=8.5)
    arrow(ax, (13.8, 3.48), (16.95, 3.48), text='UART 115200', fs=8)
    box(ax, 16.95, 0.85, 3.05, 1.25, 'ES8388 + TT8642×2\n扬声器 J12 / J11', fc=C['act'], fs=8.5)
    arrow(ax, (13.8, 1.47), (16.95, 1.47), text='I2S + I2C', fs=8)
    # legend
    for i, (fc, t) in enumerate([(C['sens'], '传感 / 输入'), (C['fpga'], 'FPGA 逻辑模块'), (C['act'], '执行 / 输出'),
                                 (C['mcu'], '接口板')]):
        box(ax, 4.0 + i * 2.6, 0.08, 0.4, 0.3, '', fc=fc, r=0.05)
        label(ax, 4.5 + i * 2.6, 0.23, t, fs=8, ha='left')
    save(fig, f'{OUT}/fig_system.png')


# ---------------------------------------------------------------- 硬件连接
def fig_hw():
    W, H = 20.2, 11.2
    fig, ax = canvas(W, H)
    box(ax, 6.4, 3.1, 6.9, 4.4, '', fc=C['fpga'], ec=C['accent'], lw=1.8, r=0.2)
    label(ax, 9.85, 6.95, '米联客 MLKPAI-F02 开发平台', fs=11.5, bold=True, color=C['accent'])
    label(ax, 9.85, 6.4, 'FC02 核心板：安路 PH1P35MDG324（内置 DDR2 512 Mb）', fs=9.5)
    label(ax, 9.85, 5.35,
          '板载：ES8388 音频编解码 · TT8642 D 类功放 ×2\nTF 卡座（SPI 模式） · SW1~SW3 · LED1~LED3\n25 MHz 晶振 · Type-C（JTAG / UART / 5 V）',
          fs=8.8, color='#455A64')
    label(ax, 9.85, 3.75, 'CEP 排针 2×20（3.3 V，不耐 5 V）\nCSI / DSI 40P FPC 连接器', fs=8.8, color='#455A64')
    # top: camera / screen
    box(ax, 5.6, 9.1, 4.0, 1.5, 'MLK-CAM002 摄像头\nSony IMX415 · f 4.2 mm\n视场 H72° / V56°', fc=C['sens'], fs=8.8)
    arrow(ax, (7.6, 9.1), (7.6, 7.5), text='CSI 口：MIPI 4 lane\n891 Mbps/lane + I2C', fs=8, toff=(-1.4, -0.4))
    box(ax, 10.3, 9.1, 4.0, 1.5, '10.1 英寸 MIPI DSI 屏\nILI9881C · 800×1280', fc=C['act'], fs=8.8)
    arrow(ax, (12.3, 7.5), (12.3, 9.1), text='DSI 口：MIPI 4 lane\n548 Mbps/lane', fs=8, toff=(1.35, -0.4))
    # left
    box(ax, 0.3, 6.0, 4.1, 1.1, '霍尔传感器模块\n3.3 V 供电，磁铁靠近输出低', fc=C['sens'], fs=8.5)
    arrow(ax, (4.4, 6.55), (6.4, 6.55), text='CEP 脚17（B17）', fs=8)
    box(ax, 0.3, 4.2, 4.1, 1.3, 'ZDT X42S 第二代闭环步进\nEmm 固件 · TTL 串口\n（尾巴，电源 10~29 V）', fc=C['act'], fs=8.5)
    arrow(ax, (6.4, 4.85), (4.4, 4.85), text='CEP 脚15（E17）\nUART TX 115200', fs=8, toff=(0, -0.05))
    box(ax, 0.3, 0.5, 4.1, 2.2, '2S 锂电池\n→ 5 V / 3 A 降压\n→ 开发板 / STM32 / UWB\n所有 GND 共地', fc=C['gray'], fs=8.5)
    poly(ax, [(4.4, 1.6), (5.6, 1.6), (5.6, 3.5), (6.4, 3.5)], ls='--', color='#78909C', text='5 V', fs=8,
         tpos=(5.6, 2.5))
    # bottom speakers
    box(ax, 7.6, 0.5, 4.5, 1.4, '扬声器 ×2（4~8 Ω）\nJ12 左：背景音乐 / J11 右：音效', fc=C['act'], fs=8.5)
    arrow(ax, (9.85, 3.1), (9.85, 1.9), text='BTL 差分输出', fs=8, toff=(1.0, -0.1))
    # right STM32 cluster
    box(ax, 15.3, 4.4, 4.6, 2.5, 'STM32F103RCT6 接口板\nUWB 方位合成 · 电机 PWM\n1.44 寸 LCD 调试屏\n（不参与决策）', fc=C['mcu'],
        fs=8.5)
    arrow(ax, (13.3, 6.0), (15.3, 6.0), text='CEP 脚3（L15）→ PB11', fs=7.8)
    arrow(ax, (15.3, 5.25), (13.3, 5.25), text='PB10 → CEP 脚4（L16）', fs=7.8, toff=(0, -0.45))
    label(ax, 14.3, 4.55, 'UART 115200 8N1', fs=7.8, color=C['purple'])
    box(ax, 15.3, 8.6, 4.6, 1.6, 'UWB 定向基站 ×3\n左 / 前 / 右（−90° / 0° / +90°）\n主人佩戴 UWB 标签', fc=C['sens'], fs=8.5)
    arrow(ax, (17.6, 8.6), (17.6, 6.9), text='USART2 / UART4 / UART5', fs=7.8, toff=(0, -0.1))
    box(ax, 15.3, 0.5, 4.6, 2.2, '直流减速电机 ×2（差速）\n+ 电机驱动\n【待补充：电机 / 驱动型号】', fc=C['act'], fs=8.5)
    arrow(ax, (17.6, 4.4), (17.6, 2.7), text='TIM3 PWM 9 kHz + 方向', fs=7.8, toff=(0, -0.1))
    save(fig, f'{OUT}/fig_hw.png')


if __name__ == '__main__':
    fig_flow()
    fig_system()
    fig_hw()
    print('ok')
