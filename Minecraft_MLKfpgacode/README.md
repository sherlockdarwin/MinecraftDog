# MinecraftDog：基于安路 PH1P35 的跟随避障机器狗

> 2026 嵌入式芯片与系统设计竞赛 · FPGA 赛道（安路选题二）｜TD 6.2.1 + Verilog｜更新 2026-10-23

---

## 0. AI 交接（新会话先读这一节）

**当前状态**：TD 工程 `mcproject_code/MinecraftDog_FPGA.al`（PH1P35MDG324-3，顶层 `mctop`）。上板情况（2026-10-05 ~ 23）：

| 部分 | 上板结果 | 处理 |
| --- | --- | --- |
| 屏幕 + 相机 | 稳定出图（第一次花屏 = 水平消隐不够 + 排线接触不良） | — |
| 相机画面 | 完整视场、颜色正常、亮度合适、无条纹（10-06 确认） | — |
| 避障画面 | 真实地面上误判不多（用户 10-21 确认） | — |
| 跟随 + 避障决策 | 10-23：FPGA → STM32 通（STM32 屏幕 `FPGA STOP`），**STM32 → FPGA 一个有效帧都没收到**（屏幕 `UWB LOST +00deg 000cm`）。STM32 发的帧格式、FPGA 的管脚和接收都核对过没问题，最可能是 PB10 → CEP 脚 4 这根线 | 屏幕第 5 行加了 `NOLK`（300 ms 一个字节都没收到）和 `LOST`（有字节但没有有效帧）的区分，排查步骤在 `obstacle.md` §5；决策本身（`obstacle.md` §6）**未上车** |
| 霍尔 | 10-23 正常；10-24 重新接线后 `HALL` 一直 0、模块的灯接上就不亮 = D0 接到了 FPGA 的输出脚（最可能是脚 15） | D0 改接 CEP **脚 17**（`hmi_tail.md` §3 末尾有自查办法） |
| 尾巴 | 正常（10-23 用户确认，FPGA 驱动） | — |
| 音频 | 10-23：没声音，喇叭只有一点电流声；屏幕 `SD NO FAT`（卡不是 FAT32，背景音乐根本没打开） | 卡要格式化成 FAT32；`source/Audio/` 的素材是 24 位的（FPGA 只放 16 位），转好的在 `source/Audio_TF/`（`tools/wav_to_tf.pl`）；屏幕把挂载失败细分成 `NO FAT` / `BADFAT` / `RD ERR`（`audio.md` §9） |

**已完成**（文件、接线、用法、排错在对应文档）：

| 模块 | 内容 | 文档 |
| --- | --- | --- |
| 视频通路 | IMX415 → MIPI 4 lane → 1920×1080 → 黑电平 + 伽马 → 去马赛克（RGGB）+ 白平衡 → 等比缩小成 800×448（完整视场）→ DDR2 四缓冲 → 10.1" 800×1280 DSI 竖屏：**上面相机 / 状态带（8 个方块 + 4 行字）/ 下面避障画面**；**自动曝光**（曝光时间 + 增益）；3 个 LED 指示初始化 | `src/doc/video_pipeline.md` |
| 避障 | 白平衡后并联：160×90 小图 → 按车前参考区学地面颜色 → 每格判地面 / 障碍 → 去噪 → 每列最近的障碍 → 16 个方向的距离 → 红框 + 按车宽（20 cm + 两边 5 cm）选方向（最远的，太近 STOP）；屏幕下半部分显示处理画面，文字第 4 行显示结果 | `src/doc/obstacle.md` |
| 跟随 + 避障决策 | STM32 串口送来主人的角度 / 距离（`$l12350&`）→ 每 20 ms 决策：停（LOST / NCAM / HERE / BLK）、原地转向主人（TURN）、跟随（GO，= STM32 `follow.c`）、绕行（AVD）、太近原地转（SPIN）→ 两轮 PWM 送回（`#+3000-0500*` / `#S*`）；文字第 5 行 | 同上 §5 §6 |
| 人机 | SW2 / SW3 短按 = 画面亮度档 ±1（EV−4~+4）；SW1 按住 2 秒整机复位 | `src/doc/hmi_tail.md` |
| 尾巴 | ZDT X42S 步进（UART 只发）：上电约 1 秒单圈就近回零，喂食时摇摆（左右 45°、10 RPM，和 STM32 `tail.h` 一样） | 同上 |
| 霍尔 + 行为层 | 磁铁靠近 = 喂食：尾巴摇一个来回（磁铁还在就继续）+ 进食音效一遍 | 同上 |
| 音频 | TF 卡 WAV → ES8388：`1.wav` 背景音乐循环（J12 左）、`2.wav` 进食音效（J11 右）、`3.wav` 狗叫（预留）；音量最大；8~48.8 kHz 自动重采样 | `src/doc/audio.md` |
| 接线 | 步进 TX、霍尔（3.3 V，低有效）、STM32 串口（CEP 脚 3 / 4） | `src/doc/pinout.md` |

**验证**：29 个测试台全部通过（10-23 加了：串口字节紧挨着 / 线通不通、坏卡的挂载原因、新的文字）；自写 / 重写的模块都做过突变检查，没抓到的等价突变记在 `hmi_tail.md` §7。TD 完整流程（10-24，音量 18）：slice 81.1%（LUT 75%）、DSP 21/40、ERAM 67/108；SWNS +0.107 ns、HWNS +0.020 ns，0 违例；bit 在 `src/boot/MinecraftDog_FPGA.bit`。

**TD 里编译和下载**（改了代码以后）：
1. 双击 `mcproject_code/MinecraftDog_FPGA.al` 打开工程（搬家以后的新位置）。
2. 工具栏绿色 ▶（一键编译：综合 + 布局布线 + 生成 bit，约 10 分钟）；下面 Console 里 `phy_1` 那一行显示 `bitgen complete` 就好了。
3. bit 在 `mcproject_code/MinecraftDog_FPGA_Runs/phy_1/MinecraftDog_FPGA.bit`，同时复制一份到 `MinecraftDog_FPGA_Runs/best_result/`（两个一样）。
4. 工具栏最右边绿色下载按钮（或 Tools → Download）→ Add 选上面的 bit → Mode：`JTAG` 是下到 FPGA 里、断电就没了；要断电保留就选烧 FLASH 的那一项 → Run。

`src/boot/MinecraftDog_FPGA.bit` 是 Claude 在命令行编译出来的（在临时目录跑，不动 TD 的 `_Runs` 文件夹，TD 开着也能编），源文件和 TD 编的一样；**下载时用哪个都行，用最新的那个**。

**已删除（记录）**：轮子电机 + 编码器 + 底盘页（轮子归单片机，旧版 git `a8d9f01`）；台架音频页和 `mc_audio` 的测试音 / 开关口；步进串口接收（`mc_uart_rx`）和尾巴的复位 / 标定 / 停止口；白平衡的两个流水线除法器；`RB_SWAP`（屏幕色序已上板确认，相机红蓝问题在 Bayer 排列）；手动增益 `ae_set` / `key.v`（被自动曝光 `mc_ae` 替代）；厂商的 96→128 打包 `data_96bit_to_128bit`（打包挪进 `mc_scale`）。

**规则**

1. 仿真：Icarus Verilog（装在 `E:\FPGA\iverilog`，`tools/sim.sh` 自动找到；换机器装之前先问用户）。`bash tools/sim.sh` 默认跑 26 个（约 20 分钟），跳过慢的 `tb_top` / `tb_audio` / `tb_fb`；`ALL=1` 全跑；长仿真放后台，并行时各设 `SIM_OUT`。加密 / 硬核（MIPI 收发、DDR 控制器、DSI 打包核）没法仿真。
2. TD 开着（`mcproject_code/.lock.f` 存在）时不改 `.al`、不移动已加入工程的文件；只改文件内容可以。增删文件：关 TD → `bash tools/gen_al.sh` → `bash tools/td_build.sh`（临时目录跑，TD 开着也能用）。
3. **新 RTL 必须配测试台**（`src/sim/tb_*.v`，在 `tools/sim.sh` 的 `rtl_for` 登记）并做突变检查（改坏一处必须 FAIL；接线层也测；确认真的改到了；分清漏洞和等价突变）。
4. IP 放 `src/ip/<名>/`，厂商 IP 目录原样复制。屏幕初始化脚本改 `rtl/video/disp/panel/ili9881c_k101_init.txt` 后运行 `make_rom.ps1`。
5. 厂商模块尽量不改，改了记进 `video_pipeline.md` §9；自写模块 `mc_` 前缀，一个文件一个模块；命名 `I_` / `O_` / `IO_` / `S_` / `_n`。
6. 编码 UTF-8；厂商注释多为 GBK（`iconv -f GBK -t UTF-8`）；含中文的 PowerShell 5.1 脚本要带 BOM。
7. 时序逻辑只用 `<=`；异步复位同步释放（`mc_rst_sync`）；跨时钟域单比特 `mc_sync_bits`，多比特用 FIFO / 握手；周期任务用 `mc_tick` 节拍做使能，不造门控时钟。
8. TD 的坑：工作目录必须是 `mcproject_code/`（双击 `.al` 打开），否则 DDR2 IP 约束丢失报 `SYN-8534`；输入脚不能写 `DRIVESTRENGTH`；DDR 的 `ddr_cke / odt / cs_n / ck_p / ck_n` 要声明成 `[0:0]`；加密 DSI 核里藏着 `w32_d512_fifo`、`w8_d1024_fifo`。
9. 硬约束：`CROP_Y0` 奇数（和 `BAYER_MODE = RGGB` 配套）；ISP 固定处理 1920×1080、`mc_scale` 固定缩小 2.4 倍（宽 800）；`WIN_W×WIN_H` 是 1280 的倍数（所以高 448）；DSP 只有 40 个：小常数乘法写成移位相加；**DSI 水平消隐 24/136/160 不要压缩**（压过一次，花屏）。
10. 版面只在 `mctop.v` 配置区改（`video_pipeline.md` §4）。
11. 用词：Verilog 没有"函数调用"——功能 = 模块、用的地方 = 例化、"调用" = 给输入端口命令、"返回值" = 输出端口、`delay_ms` = 状态机数节拍。
12. 对用户：中文，STM32 类比，给 TD 菜单步骤；文档精简；写完代码讲清架构、文件、接线；上板测试只说预期现象，不写专用测试代码。

---

## 1. 比赛和硬件

| 项 | 内容 |
| --- | --- |
| 截止 | **2026-11-04 18:00** 线上提交报告 + 视频（www.socchina.net）；决赛 11-20 ~ 22 南京，现场 FPGA 编程考核 |
| 选题 | 安路选题二：PH1P35 实时图像处理 + 移动平台，按识别结果做外部控制 |
| 规则 | 只能用安路 FPGA；主控和算法在 FPGA（片内 RISC-V 也可）；UWB、超声波等只当传感器 |
| 得分点 | MIPI 采集 + 实时显示、至少一种 FPGA 图像算法、OSD（**必须带"安路"Logo**）、长时间稳定；加分：目标跟踪 + 坐标叠加、运动检测、延迟可视化、AE/AWB、多算法切换 |

| 硬件 | 说明 |
| --- | --- |
| 板子 | 米联客 MLKPAI-F02 + FC02：PH1P35MDG324（LUT4 38k、DFF 42k、DSP 40、ERAM 108×20 Kb）、DDR2 512 Mb、MIPI CSI 收 / DSI 发、CEP 排针 36 个 3.3 V IO（**不耐 5 V**） |
| 摄像头 | MLK-CAM002-IMX415：4 lane RAW10，2×2 binning 1920×1080，镜头 f 4.2 mm、视场 H72° / V56°；屏幕上显示完整视场（800×448） |
| 摄像头安装 | **镜头离地 174 mm，车头正中，向下倾 15°**：画面最下沿 ≈ 车前 23 cm，地平线在画面上方约 1/6 处。装好后固定，"行号 → 距离"表按它算（改了要重新生成，`obstacle.md` §1） |
| 屏幕 | 米联客 10.1" MIPI DSI，800×1280 竖屏，ILI9881C |
| 尾巴 | ZDT X42S 第二代闭环步进（TTL 串口版，Emm 固件，115200，地址 1），摆幅 ±45°，接 FPGA CEP 脚 15 |
| 轮子 + UWB | **STM32F103RCT6**（工程 `../Minecraft_MCU/MinecraftDog_STM32/`）：三个 UWB 基站合成主人的方位 / 距离发给 FPGA，按 FPGA 的两轮命令驱动电机（只当传感器 + 电机驱动） |
| FPGA ↔ STM32 | **UART 115200 8N1，两根线 + 共地**：CEP 脚 3 → PB11（USART3 RX）、PB10 → CEP 脚 4。ASCII 帧（`obstacle.md` §5），20 ms 一帧，只占 115200 的约 5% |
| 音频 | TF 卡 → ES8388 → 板载 TT8642 功放 → J12（左）/ J11（右），或耳机口 J3 |
| 电源 | 2S 锂电池 → 5 V/3 A 降压；**所有板子的地连在一起** |

时钟：PLL 25 MHz 输入 → 100 MHz（主逻辑）/ 24 MHz（相机）/ 52.17 MHz（DSI 参考）/ 10 MHz（面板配置），各时钟域异步（`mc_timing.sdc`）。

## 2. 数据流

```
IMX415 ─MIPI─► 1920×1080 → 伽马 → 去马赛克 → AWB → 缩小 800×448 ─► DDR2 ─► mc_mixer（相机 + 状态带）─► DSI ─► 屏幕   ◄ 已完成
   └─ 平均亮度 ─► 自动曝光 mc_ae ─I2C─► 传感器（曝光 / 增益）                                                   ◄ 已完成
                 AWB 之后并联：12×12 均值 → 160×90 → 地面 / 障碍 → 16 个方向的距离 → 屏幕下面画框 + 选方向       ◄ 已完成（未上板）
STM32（UWB：主人在哪）─UART─► mc_m0_link ─► mc_follow（+ 避障结果）─► 两个轮子的 PWM ─UART─► STM32（电机）         ◄ 已完成（未上车）
霍尔 ─► mc_hall ─► mc_behavior ─┬─► mc_tail（尾巴，UART 只发）  ◄ 已完成
                                └─► mc_audio（进食音效）         ◄ 已完成
UWB 距离 ─► 行为层（狗叫、摇尾巴：mc_behavior 的 I_near / I_bark）   ◄ 待办
```

## 3. 待办

1. **上板**：STM32 → FPGA 的线（屏幕第 5 行 `NOLK` / `LOST` / `OK`，`obstacle.md` §5）→ 音频（TF 卡格式化成 FAT32，拷 `source/Audio_TF/` 的文件；破音就把 `AUD_SPK_VOL` 改回 30）→ 装摄像头（§1）。
2. **避障调参**：上板看误判调 `OBS_TC` / `OBS_TY`；车宽 / 余量在 `tools/gen_obs_lut.pl`；跟随的系数 `mctop.v` 的 `FOLLOW_*` = STM32 `follow.h`（要改就先在 STM32 跟随测试模式里调好再抄过来，两边保持一样）；OSD 带安路 Logo（v 632~819 空着）。
3. **上车**：同一个地方先试 STM32 的跟随测试模式，再试 FPGA 模式（没有障碍时两者的两轮命令应该基本一样），再放障碍试绕行，按 `obstacle.md` §6 的表调 `AVOID_*`。
4. UWB 距离接到行为层：`mc_behavior` 已留 `I_near`（摇尾巴）、`I_bark`（狗叫），接上以后 `tb_top` 补狗叫循环的用例。
5. 有余力：重采样改线性插值；背景音乐循环衔接的短停顿；DSI 提到约 60 Hz。
6. 资源：slice 用了 81.2%（避障约 9 个百分点、跟随 + 串口约 5 个），DSP 21/40；小常数乘法写成移位相加（`*` 会被推断成 DSP）。

## 4. 避障 + 跟随（已完成，详见 `src/doc/obstacle.md`）

单目"地面外观 + 列扫描"（Ulrich & Nourbakhsh 2000），全是行缓存流水线，不占 DDR。前提：地面大致平、颜色和障碍不同；上电时车前参考区是空地。
1920×1080 → 12×12 均值 → 160×90 → Y / Cb / Cr → 地面直方图（车前 48×8 格参考区，每帧留 3/4 + 新计数）判地面 / 障碍 → 3×3 多数表决 → 每列最近障碍（1.5 m 以内）→ 16 个扇区距离（查表，和上一帧取近）→ 相邻扇区合框 → 9 个方向（±19°）按车宽算各能走多远，选最远的（< 35 cm 停）。
跟随（每 20 ms，`obstacle.md` §6）：收不到 UWB / 相机没图 / 到了主人 3 m 内 / 哪个方向都不到 60 cm → 停；主人在 90° 外保持 0.3 秒 → 原地转；不挡路就照 STM32 `follow.c` 跟；挡路就在 9 个方向里按代价（离主人近、不换边）挑一个绕，太近原地转。
没做边缘检测（Sobel）：省资源；和地面同色的障碍判不出来。

## 5. 参考

| 项目 / 论文 | 借鉴什么 |
| --- | --- |
| [maojinxiang/FPGA-ANLU-National-First-Prize](https://github.com/maojinxiang/FPGA-ANLU-National-First-Prize) | 灰度、二值化、Sobel、腐蚀、膨胀共用 3×3 窗口的结构（EG4 工程，不能直接搬） |
| Ulrich & Nourbakhsh, *Appearance-Based Obstacle Detection with Monocular Color Vision*（AAAI 2000，[摘要](https://mlanthology.org/aaai/2000/ulrich2000aaai-appearance)） | 本方案原型：按颜色把像素分成地面 / 障碍，前方地面作参考区 |
| [AngeloJacobo/FPGA_RealTime_and_Static_Sobel_Edge_Detection](https://github.com/AngeloJacobo/FPGA_RealTime_and_Static_Sobel_Edge_Detection) | 行缓存 + 3×3 窗口 + 阈值的 Sobel 写法 |
| *A Monocular Vision Sensor-Based Obstacle Detection Algorithm…*（Sensors 16(3):311，[全文](https://www.mdpi.com/1424-8220/16/3/311)） | 逆透视 + 地面模型 → "行号 → 距离" |
| Linux [`panel-ilitek-ili9881c.c`](https://github.com/torvalds/linux/blob/master/drivers/gpu/drm/panel/panel-ilitek-ili9881c.c) | ILI9881C 初始化序列（本工程用 K101-IM2BYL02 那份，已上板可用） |
| 安路官方样例 https://pan.baidu.com/s/12hjB7BiAxT3CIVqzh4Amnw（Q614） | PH1P35 的 MIPI、边缘检测、OSD 样例 |

## 6. 目录

```
MinecraftDog/
├── Minecraft_MCU/            单片机工程：MinecraftDog_STM32/（现在用的：UWB、电机、和 FPGA 的串口，README 里有协议和跟随调参记录）、MinecraftDog_mspm0/（旧的，不用了）
├── Minecraft_MLKfpgacode/    FPGA（2026-10-23 从根目录搬进来）
│   ├── README.md             本文件
│   ├── tools/                td_build.sh（命令行跑 TD）、gen_al.sh（重新生成 .al，TD 要关）、sim.sh（跑测试台）、gen_osd_dash.pl（生成文字面板）、gen_gamma.pl（生成伽马表）、gen_obs_lut.pl（避障几何表）、
│   │                         mk_sd_test_image.pl（测试用 FAT32 镜像）、wav_to_tf.pl（WAV 转 16 位 48 kHz）、render_pdf.ps1（PDF 页转 PNG）、gen_font.sh（字库）
│   └── mcproject_code/       TD 工程根目录（MinecraftDog_FPGA.al）
│       └── src/
│           ├── rtl/  mctop.v（顶层 + 配置区）、system/、hmi/、comm/、tail/、sensor/、app/、audio/、video/（cam、rx、isp、fb、disp、osd、obs）
│           ├── ip/   TD 生成的 IP
│           ├── pin/  mc_pin.adc（管脚）、mc_timing.sdc（时序）
│           ├── sim/  27 个测试台 + stubs/（视频替身、ISP 里的 RAM 替身）+ models/（TF 卡、I2C 从机、会记录写入的 I2C 从机）
│           ├── boot/ 当前的 .bit
│           └── doc/  pinout.md 接线｜video_pipeline.md 视频 + 版面｜obstacle.md 避障 + 跟随决策 + STM32 串口｜hmi_tail.md 按键 / 尾巴 / 霍尔 / LED｜audio.md 音频
├── source/                   比赛材料（技术文档、授权书）、Audio/（音频素材原件，24 位）、Audio_TF/（转好的，直接拷进 TF 卡根目录）
└── 3Dmodel/                  外壳 STL
```

命令都在 `Minecraft_MLKfpgacode/` 下运行（`bash tools/sim.sh`、`bash tools/td_build.sh`）；TD 双击 `mcproject_code/MinecraftDog_FPGA.al` 打开。

参考资料（相对 `FPGA/reference/`）：`02_F02_FC02_PH1P35/…/08_csi_dsi_cs500_7cun/`（视频通路底座）；`07_ddr_test`、`09_aud8388_loop`；`02_hardware/…/MLKPAI-F02开发平台硬件使用手册.pdf`、`…/MLKPAI-F02底板.pdf`（看某页：`powershell -File tools/render_pdf.ps1 -Pdf <pdf> -Page <页> -Out <png>`）；`06_MLK-CAM002-IMX415/`；`ZDT_XS系列第二代闭环步进电机资料/`（手册 + MSPM0 例程）；`TI2026H题code/`（旧 C 工程）。不用看 Xilinx 工程（`XILINX/`、`F20_CM02_3EG_1_1/`、`soc_prj/`）。
