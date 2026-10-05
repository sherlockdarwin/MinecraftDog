# MinecraftDog：基于安路 PH1P35 的跟随避障机器狗

> 2026 嵌入式芯片与系统设计竞赛 · FPGA 赛道（安路选题二）｜TD 6.2.1 + Verilog｜更新 2026-10-05（晚）

---

## 0. AI 交接（新会话先读这一节）

**当前状态**：TD 工程 `mcproject_code/MinecraftDog_FPGA.al`（PH1P35MDG324-3，顶层 `mctop`）。2026-10-05 第一次接屏 + 相机 + 尾巴 + 霍尔上板：**屏幕花屏（竖条纹、字被压扁、整屏抖）、尾巴上电没回中、霍尔 = 1 尾巴也不动**。已按下面改完（仿真全部通过、TD 完整流程通过），**还没再上板**。

**已完成**（统一说明；每块的文件、接线、用法、排错在对应文档里）：

| 模块 | 内容 | 文档 |
| --- | --- | --- |
| 视频通路 | IMX415 → MIPI 4 lane → 取窗 800×560 → 去马赛克 + 白平衡（逐帧算增益）→ DDR2 四缓冲 → 10.1" 800×1280 DSI 屏；竖屏，**上半相机 / 中间状态带（8 个状态方块 + 3 行黑底白字）/ 下半留给避障**；DSI 水平消隐照抄厂商例程；3 个 LED 指示初始化进度 | `src/doc/video_pipeline.md` |
| 人机 | 三键：SW2 / SW3 短按 = 相机增益 ±1；SW1 按住 2 秒整机复位（没有翻页、没有音频页） | `src/doc/hmi_tail.md` |
| 尾巴 | ZDT X42S 步进电机（UART **只发不收**）：上电约 1 秒自动**单圈就近回零**（驱动器转到它存的零点 = 正中）、摇摆一个来回 | 同上 |
| 霍尔 + 行为层 | 霍尔传感器（磁铁靠近 = 1）判断喂食：尾巴摇一个来回，磁铁还在就再摇一个来回；同时进食音效播一遍（播放中不重复触发） | 同上 |
| 音频 | TF 卡 WAV → ES8388 → 喇叭口：`1.wav` 背景音乐上电自动循环（J12 左）、`2.wav` 进食音效（J11 右）、`3.wav` 狗叫（预留）；两路同时播；音量最大；8~48.8 kHz 自动重采样；没有按键操作 | `src/doc/audio.md` |
| 接线 | 步进 TX（只一根线）、霍尔输入接哪些脚，怎么改脚 | `src/doc/pinout.md` |

**验证状态**

- 仿真：20 个测试台（含最慢的 `tb_top` / `tb_audio` / `tb_fb`）在最终文件上全部通过（2026-10-05）。这次新写 / 重写的（白平衡、尾巴、文字面板、台架、串口）都做过突变检查（故意改坏 RTL，看测试台会不会报错），没抓到的都是等价突变，记在 `hmi_tail.md` §7。
- TD 完整流程（综合 + 布局布线 + bit）：**SWNS +1.105 ns、HWNS +0.020 ns，0 违例**；**slice 52%**（上一版 75%）、LUT 47%、寄存器 26%、ERAM 38%、DSP 20%；bit 在 `src/boot/MinecraftDog_FPGA.bit`。省下的 23 个百分点几乎全来自白平衡（原来每个像素都做两次流水线除法，改成每帧算一次）。
- **屏幕**：改的是最可疑的那处（水平消隐），**初始化脚本是否匹配这块屏仍没验证**；还花屏就要商家的初始化代码（`video_pipeline.md` §6）。

**已删除（记录）**：
- 轮子电机：曾经做过 TB6612 双路电机驱动 + 双编码器测速 + 底盘动作命令 + 台架底盘页；轮子控制改放在另一块单片机上，已全部删除。旧版本在 git 提交 `a8d9f01`「有电机」。
- 台架音频页（2026-10-05）：翻页、选曲 / 播放 / 停止、2 秒测试音、背景音乐开关，以及屏幕上的音频页（错误码、缺数据次数、曲目号）。规则已定，不用在板上调；`mc_audio` 的 `I_bgm_en` / `I_sfx_stop` / `I_sfx_tone` 端口和播放器里的测试音一起删了。
- 步进驱动器的串口接收（2026-10-05）：只留 FPGA → 驱动器一根线，`mc_uart_rx` 和应答计数删了；尾巴的「复位 / 标定零点 / 停止」命令口也删了（只剩摇摆 + 上电自动回零）。
- 白平衡的两个流水线除法器（`divider` IP）：被「每帧算一次」的小除法器替代。

**待办**：见 §3。

**规则**

1. 工具：TD（综合、布局布线、下载、ChipWatcher），Verilog-2001（厂商 MIPI 封装用 SystemVerilog）。仿真用 Icarus Verilog（用户已同意安装：`winget install Icarus.Verilog`；换机器装之前先问）：`bash tools/sim.sh` 跑 `src/sim/` 的测试台，默认的 17 个约 25 分钟，跳过最慢的 `tb_top`（约 15 分钟）、`tb_audio`（约 30 分钟）、`tb_fb`（约 2 分钟）；`ALL=1` 全跑（顺序约 1.2 小时）；长仿真放后台，多个并行时各设 `SIM_OUT=<目录>`。厂商的 MIPI 收发、ISP、DDR 控制器没有仿真，靠复用已验证模块 + `tools/td_build.sh` + 上板后用 LED / 状态方块 / ChipWatcher。
2. TD 开着工程时（`mcproject_code/.lock.f` 存在）**不要改 `.al`，不要移动 / 重命名已加入工程的文件**，否则 TD 可能用内存里的版本覆盖；只改文件内容没问题。
3. 在 `src/` 下增删文件后：关 TD → `bash tools/gen_al.sh` → `bash tools/td_build.sh`（在临时目录跑，TD 开着也能用）。**新增 RTL 必须配测试台**（`src/sim/tb_*.v`，并在 `tools/sim.sh` 的 `rtl_for` 登记），而且要做**突变检查**：故意改坏一处，测试台必须 FAIL；接线层（顶层把模块连起来）也要测；确认突变真的改到了；分清"测试台漏洞"和"等价突变"；测试台超时设短（改坏的 RTL 常常卡死）。
4. IP 放 `src/ip/<名>/`（TD 的 Tools → IP Catalog 生成；厂商 IP 整个目录原样复制，目录名不能改）。唯一手改：`w8_d1024_rom` 的 `INIT_FILE` 指向我们的 mif；屏幕初始化脚本改 `rtl/video/disp/panel/ili9881c_k101_init.txt` 后运行 `make_rom.ps1`。
5. 厂商模块尽量不改，改了记进 `video_pipeline.md` §9；自写模块加 `mc_` 前缀，一个文件一个模块，文件名 = 模块名。
6. 编码：UTF-8；厂商源码注释多为 GBK（读之前 `iconv -f GBK -t UTF-8`）；含中文的 PowerShell 5.1 脚本必须带 UTF-8 BOM。
7. 命名沿用米联客：`I_` 输入、`O_` 输出、`IO_` 双向、`S_` 内部信号、`_n` 低有效。
8. 时序逻辑只用 `<=`。自己的模块用异步复位、同步释放（`mc_rst_sync`）；厂商模块直接接 PLL lock。跨时钟域：单比特 `mc_sync_bits` 打两拍，多比特用异步 FIFO 或握手。
9. 周期性任务（PID、串口解析、按键扫描）用 `mc_tick` 的节拍脉冲做使能，不要另写分频计数器，不要造门控时钟。
10. TD 的坑：**TD 的工作目录必须是工程目录 `mcproject_code/`**——双击 `MinecraftDog_FPGA.al` 打开，或先 `cd mcproject_code` 再 `td.exe MinecraftDog_FPGA.al`；从开始菜单启动再 File → Open 的话，TD 找不到 DDR2 IP 自带的约束（生成的 `settings.cfg` 里没有 `IpADCList`，命令行实测工作目录不对就是这样），综合报 `SYN-8534 Can not get the inst ... please add inst constraint`（`tools/td_build.sh` 不受影响）；输入脚的 adc 不能写 `DRIVESTRENGTH`；DDR 端口 `ddr_cke / ddr_odt / ddr_cs_n / ddr_ck_p / ddr_ck_n` 必须声明成 `[0:0]`；加密的 DSI 打包核里藏着 `w32_d512_fifo`、`w8_d1024_fifo` 两个 IP，漏了会报 "black box"；`.al` 里每个文件的 `CompileOrder` 不能重复。
11. 取窗硬约束：`CROP_Y0` 必须是奇数（Bayer 相位）；`WIN_W` 是 16 的倍数且 `WIN_W×WIN_H` 是 1280 的整数倍（帧缓存突发长度）。
12. **用词：Verilog 里没有"写函数然后调用"。** 功能写成**模块**，用的地方**例化**；"调用" = 给输入端口一个命令（电平，或脉冲 + `busy/done`），"返回值" = 读输出端口；`delay_ms` 式阻塞等待 = 状态机里数 `mc_tick` 节拍。接口速查：`hmi_tail.md` §5。
13. 按键：SW2 / SW3 短按 = 相机增益 ±1，**SW1 按住 2 秒整机复位**，其余没有功能（`hmi_tail.md` §4）。
14. 屏幕版面（上半相机窗口、中间状态带、下半避障区）只在 `mctop.v` 配置区定义（只做竖屏）。版面图：`video_pipeline.md` §4。**DSI 的水平消隐（24/136/160）和厂商例程一致，不要压缩**（压缩过一次，上板花屏）。
15. 对用户：用中文，概念用 STM32 类比，给 TD 的具体菜单步骤；文档精简；写完代码要讲清架构、每个文件做什么、怎么接线。

---

## 1. 比赛和硬件

| 项 | 内容 |
| --- | --- |
| 截止 | **2026-11-04 18:00** 线上提交作品报告 + 视频（www.socchina.net）；决赛 11-20 ~ 22，南京，现场有 FPGA 编程考核 |
| 选题 | 安路选题二：PH1P35 实时图像处理，结合移动平台，根据识别结果做外部控制 |
| 规则 | 不能用非安路 FPGA；主控和算法放 FPGA（片内 RISC-V 也可）；UWB、超声波等成品模块只当传感器 |
| 得分点 | MIPI 采集 + 实时显示、至少一种 FPGA 图像算法、OSD（**必须带"安路"Logo**）、长时间稳定运行；加分：目标跟踪 + 坐标叠加、运动检测、延迟可视化、AE/AWB、多算法切换 |

| 硬件 | 说明 |
| --- | --- |
| 板子 | 米联客 MLKPAI-F02 底板 + FC02 核心板：PH1P35MDG324（LUT4 38k、DFF 42k、DSP 40、ERAM 108×20 Kb）、合封 DDR2 512 Mb、MIPI D-PHY ×2（CSI 收 / DSI 发）、CEP 排针 36 个 3.3 V IO；没有 HDMI；Type-C 下载 / 供电 5V/3A |
| 摄像头 | MLK-CAM002-IMX415：MIPI CSI-2 4 lane RAW10；I2C 0x34；INCK 24 MHz；2×2 binning 1920×1080，每 lane 891 Mbps；M12 镜头 f 4.2 mm，视场 H72°/V56° |
| 屏幕 | 米联客 10.1" MIPI DSI：**800×1280 竖屏**，ILI9881C，4 lane |
| 尾巴 | ZDT X42S 第二代闭环步进电机（串口 TTL 版，Emm 固件，UART 115200 只发，地址 1，16 细分），摆幅 ±30°；上电单圈就近回零 |
| 轮子 | **不在 FPGA 里**：轮子的电机驱动、编码器和速度环都放在另一块单片机上 |
| 音频 | TF 卡 → 板载 ES8388 → 板载 TT8642 功放 → 喇叭口 J12（左）/ J11（右）或耳机口 J3 |
| 传感器 | 霍尔模块（喂食检测，磁铁放在食物模型上）；UWB 模组、超声波：**待资料，先不写** |
| 电源 | 2S 锂电池 → 5 V/3 A 降压给开发板；所有地连在一起（包括轮子单片机） |

管脚、接线、改脚：`pinout.md`；时钟：PLL `mcsys_pll` 输入 25 MHz，输出 100 MHz（主逻辑）/ 24 MHz（相机）/ 52.173913 MHz（DSI 参考）/ 10 MHz（面板 LP 配置），各时钟域之间按异步处理（`mc_timing.sdc` 的 `set_clock_groups`）。

和 C 工程（TI2026H）的对应：`main()` + SysConfig → `mctop.v` + `pin/mc_pin.adc`；定时器 + 任务表 → `mc_tick` 脉冲 + 各自用 tick 做使能的 always 块（并行，互不阻塞）；`Key()` → `mc_key`；`OLED_Show*` → `mc_osd_dash`（版面由 `tools/gen_osd_dash.pl` 生成）；`Stepper_*` → `mc_tail`（只发不收）。

## 2. 数据流

```
IMX415 ─MIPI─► 取窗 → 去马赛克 → AWB ─► DDR2 四缓冲 ─► mc_mixer（上半相机 + 状态带）─► DSI ─► 屏幕             ◄ 已完成
                └─► 避障分析（并联一路抽取，160×90 流水线）→ 16 个扇区的可通行深度 → 屏幕下半：处理画面 + 画框   ◄ 待办
霍尔 ─► mc_hall ─► mc_behavior ─┬─► mc_tail（尾巴，UART 只发）◄ 已完成
                                └─► mc_audio（进食音效）       ◄ 已完成
UWB / 超声波 ─► （距离、方位）─► mc_behavior / 决策 ─► 速度 / 方向命令 ─► 轮子单片机（接口待定）                ◄ 待办
```

## 3. 待办

1. **上板验证**（按顺序）：屏幕（这次改了水平消隐；还花屏就要商家这块屏的初始化代码，`video_pipeline.md` §6）→ 相机出图（稳定、不卡顿）→ 尾巴（先在驱动器菜单设回零零点，`hmi_tail.md` §3；方向与摆幅 `TAIL_LEFT_CCW`、`TAIL_GEAR_X100`）→ 霍尔 → 音频（音量最大，破音就把 `AUD_SPK_VOL` 改回 30）→ 摄像头安装高度和俯角。
2. **避障模型 + 画框（屏幕和相机稳定以后再做，还没开始）**：只做避障必需的图像运算（§4），处理后的画面 + 可通行框画在**屏幕下半部分**（v 720~1279，800×560，和相机窗口一样大；`mc_mixer` 叠加）；OSD 要带安路 Logo。
3. **UWB（等资料齐了再写）**：串口解析出距离 / 方位；接 `mc_behavior`：距离 < 5 m 时摇尾巴（`I_near`）；检测不到 / 太远时播 `3.wav` 狗叫（`I_bark`）；跟随控制。
4. 超声波近距兜底。
5. 决策状态机（安全 > 避障 > 跟随 > 报警），输出方向 / 速度命令给轮子单片机（接口待定，串口最简单；速度环 PID 在那块单片机上）。
6. 小改进（有余力再做）：重采样改线性插值；背景音乐循环衔接处的短停顿；屏幕稳定以后把 DSI 提到约 60 Hz（`video_pipeline.md` §7）。
7. **资源**：slice 用了 52%，还剩约 48%（约 10000 个 slice）给避障流水线。大头（综合后 LUT + 进位）：相机接口 `mc_cam_if`（去马赛克 + 白平衡 + MIPI 收）、帧缓存 + DDR2 控制器、音频约 2500（`mc_fat32` 约 1100、两个播放器约 700）、显示接口约 800、文字面板约 250。

## 4. 避障需要的图像运算（只做必要的，其余不管）

方案：单目"地面外观 + 列扫描"（Ulrich & Nourbakhsh 2000），整条链都是行缓存流水线，不占 DDR，PH1P35 放得下（Fast-SCNN 之类分割网络放不下）。前提：地面大致平坦且颜色和障碍不同；摄像头下俯 15° ~ 25°。

| # | 运算 | 干什么 |
| --- | --- | --- |
| 1 | 抽取 + 均值 | 完整视场（取窗之前）→ 2×2 抽取 → 6×6 均值 → 160×90 |
| 2 | RGB → YCbCr（移位加法） | Y 找边缘；Cb / Cr 判断地面颜色（对阴影不敏感） |
| 3 | Sobel 边缘（3×3 窗口，前面可加 3×3 平滑） | 地面和障碍颜色接近时靠边缘分开 |
| 4 | 地面颜色模型 | 画面底部中间梯形区域统计 Cb / Cr 均值 ± 余量；超声波说前方 50 cm 内没东西才更新 |
| 5 | 二值化 | 颜色不像地面 **或** 边缘强 → 障碍 = 1 |
| 6 | 腐蚀 → 膨胀（开运算） | 去掉地砖缝、木纹、噪点 |
| 7 | 列扫描 | 每列从下往上第一个障碍点 → 可通行高度；160 列合并成 16 个扇区取最小 |
| 8 | 行号 → 距离 | 查表（地上每隔 10 cm 做标记，记行号） |
| 9 | 时域平滑 | 和上一帧取最小 / 平均，防闪烁 |
| 10 | 画框 / 色条 / Logo | 每帧消隐期在 16 个扇区深度上找最大矩形（宽度要容得下车身）；`mc_mixer` 逐像素判断是否在框线上；窗口内坐标 = 传感器坐标 − 窗口左上角（`CROP_X0_GRP×4`、`CROP_Y0`）；框坐标从分析时钟域用握手 / 双缓冲交给像素时钟域 |

已有的：去马赛克、白平衡（`awb`）、手动增益（台架第 0 页）。每一步先写测试台（用静态图片作输入）。

## 5. 参考项目和论文

| 项目 / 论文 | 借鉴什么 |
| --- | --- |
| [maojinxiang/FPGA-ANLU-National-First-Prize](https://github.com/maojinxiang/FPGA-ANLU-National-First-Prize)（首奖项目：HX4S20C + OV5640 + 640×480 HDMI，核心 `Main/q3q4/import/udp_cam_ctrl.v`） | 16 种图像效果里**只有灰度、二值化、Sobel、腐蚀、膨胀**直接能用；所有效果放一个模块用选择信号切换、Sobel / 腐蚀 / 膨胀共用 3×3 窗口的结构。它是 EG4 工程，代码不能直接搬；没有地面模型、列扫描、距离换算 |
| Ulrich & Nourbakhsh，*Appearance-Based Obstacle Detection with Monocular Color Vision*（AAAI 2000，[摘要页](https://mlanthology.org/aaai/2000/ulrich2000aaai-appearance)） | 本方案的原型：按颜色外观把每个像素分成"地面 / 障碍"，前方一块地面作参考区、边走边更新 |
| Angelo Jacobo：[FPGA_RealTime_and_Static_Sobel_Edge_Detection](https://github.com/AngeloJacobo/FPGA_RealTime_and_Static_Sobel_Edge_Detection)（MIT） | Verilog 流水线 Sobel：行缓存 + 3×3 窗口 + 阈值的写法（Xilinx 的 PLL / SDRAM 文件不用管） |
| Machado 等，*Vision-based robotics using open FPGAs*（Microprocessors and Microsystems 103，2023，[条目页](https://burjcdigital.urjc.es/items/fd325d26-45aa-4980-aa14-6e47b91387c9/full)） | 开源 Verilog 视觉机器人模块库（图像处理块 + 反应式控制块），演示彩色目标跟随；条目页没给代码仓库链接，要自己再找；"按颜色跟随"可当 UWB 跟随的备份 |
| *A Monocular Vision Sensor-Based Obstacle Detection Algorithm for Autonomous Robots*（Sensors 16(3):311，2016，[全文](https://www.mdpi.com/1424-8220/16/3/311)） | 逆透视映射 + 地面外观模型：对应"行号 → 距离"查表和地面模型（后面的马尔可夫随机场太重，不用） |
| *Real-Time Freespace Segmentation on Autonomous Robots…*（[arXiv 1902.00842](https://arxiv.org/pdf/1902.00842)） | 目标和我们一样（可通行区域）但用神经网络，跑不动；只当"输出长什么样"的参考 |
| Linux 内核 [`panel-ilitek-ili9881c.c`](https://github.com/torvalds/linux/blob/master/drivers/gpu/drm/panel/panel-ilitek-ili9881c.c) | ILI9881C 初始化序列和显示时序的公开参考（本工程用 K101-IM2BYL02 那一份） |
| 安路官方样例 https://pan.baidu.com/s/12hjB7BiAxT3CIVqzh4Amnw（提取码 Q614） | HX1P35A 平台（也是 PH1P35MDG324）的 MIPI、边缘检测、OSD 样例；评分标准在 `../选题/` |

（后四项和 Machado 的条目是检索结果摘要，没有逐个读源码，用之前自己判断。）

## 6. 目录

```
MinecraftDog/
├── README.md
├── tools/        td_build.sh（命令行跑 TD 完整流程）、gen_al.sh（重新生成 .al，TD 要关）、sim.sh（跑测试台）、gen_osd_dash.pl（生成屏幕状态面板 mc_osd_dash.v）、mk_sd_test_image.pl（生成测试用 FAT32 卡镜像）、render_pdf.ps1（PDF 页转 PNG）、gen_font.sh（生成字库）
└── mcproject_code/               TD 工程根目录（MinecraftDog_FPGA.al 在这里）
    └── src/
        ├── rtl/      mctop.v（顶层 + 配置区）、system/（复位、节拍、同步器、长按复位）、hmi/（按键、台架）、comm/（串口发送）、tail/（尾巴）、
        │             sensor/（霍尔）、app/（行为层）、audio/（TF 卡 WAV → ES8388）、video/（cam 相机、rx MIPI 接收、isp、fb 帧缓存、disp 显示接口 + 合成器、osd 文字层）
        ├── ip/       TD 生成的 IP，一个 IP 一个子目录
        ├── pin/      mc_pin.adc（管脚）、mc_timing.sdc（时序）
        ├── sim/      20 个测试台 tb_*.v + stubs/（顶层集成测试用的视频替身、白平衡延迟线 RAM）+ models/（TF 卡、I2C 从机行为模型）
        ├── boot/     验证过的 .bit
        └── doc/      pinout.md 接线｜video_pipeline.md 视频通路 + 版面｜hmi_tail.md 按键 / 台架 / 尾巴 / 霍尔 / LED｜audio.md 音频
```

参考资料（路径相对 `FPGA/reference/`）：`02_F02_FC02_PH1P35/01_start/02_peripheral_demo/02_peripheral_demo/08_csi_dsi_cs500_7cun/`（视频通路底座：MIPI RX、ISP、DDR2、DSI；`td_project/*.sdc` 是多时钟约束范本）；`07_ddr_test`、`09_aud8388_loop`（DDR2 用法、ES8388 配置）；`02_hardware/…/MLKPAI-F02开发平台硬件使用手册.pdf`（管脚表）和 `…/02_原理图/MLKPAI-F02底板.pdf`（P05 AUDIO 页、TF 卡座；渲染某页：`powershell -File tools/render_pdf.ps1 -Pdf <pdf> -Page <页号> -Out <png>`）；`06_MLK-CAM002-IMX415/`（IMX415 配置、4-lane 解包、`摄像头调节心得.docx`）；`显示屏1~3.png`（10.1" 屏的 40P 管脚、尺寸）；`TI2026H题code/`（旧 C 工程：PID、任务调度，可参考参数；轮子单片机那边用得上）。不用看：`XILINX/`、`F20_CM02_3EG_1_1/`、`soc_prj/`（Xilinx 工程）。
