# MinecraftDog：基于安路 PH1P35 的跟随避障机器狗（FPGA 部分）

> 2026 嵌入式芯片与系统设计竞赛 · FPGA 赛道（安路选题二）｜TD 6.2.1 + Verilog｜更新 2026-10-30
> 截止 **2026-11-04 18:00**（报告 + 视频，www.socchina.net）；决赛 11-20 ~ 22 南京。OSD 必须带"安路"Logo（已做，`video_pipeline.md` §4）。

## 1. 现状

**基本任务完成（10-30 上车）：能完成基本跟随。** 接下来上车调参，按 `obstacle.md` §10 的顺序。

| 功能 | 状态 |
| --- | --- |
| 相机 → 屏幕 | 正常：上面相机，中间 8 个方块 + 6 行字 + 安路 Logo，下面避障处理画面 |
| 跟随 | 正常：UWB 给方向，陀螺仪角度环保持航向（`obstacle.md` §6）。超过 2 m 跟上、2 m 内停，起步 3300。10-31 转弯调快，上车验证过 |
| 避障 | 1 m 内绕、60 cm 内原地转；主人方向 2 m 内有东西提前绕；走不了就转着找出口（上车验证过），转一圈没有就停下狗叫。修撞墙：墙进车前 58 cm 不再学成地面，1 m 内亮度放宽 ±1 格。门限 24 时地板花纹变紫，10-31 晚改成 16，并让贴在地上的花纹照样学（没上车） |
| 陀螺仪 JY61P | 正常：上电自动配置，停稳后航向归零（屏幕第 6 行） |
| 霍尔 + 音频 | 正常：磁铁靠近放进食音效，背景音乐循环，喇叭音量 22 |
| 狗叫 | 上车验证过（10-31）：主人 10 m 外（STM32 发 999）或收不到 UWB 连续 1 秒、或者困住了 → 循环播 `3.wav`；STM32 线不通不叫 |
| 尾巴 | 上车验证过（10-31）：FPGA 驱动（CEP 脚 15），喂食或主人 3 m 内摇，中 → 左 → 右（中间不停）→ 中，约 3.6 秒一遍 |
| 供电 | 要稳压 5 V，不稳会整板挂掉 |

## 2. 硬件和接线

| 项 | 内容 |
| --- | --- |
| FPGA 板 | 米联客 MLKPAI-F02 + FC02（PH1P35MDG324，DSP 40 个）；CEP 排针 3.3 V，**不耐 5 V** |
| 相机 | MLK-CAM002-IMX415，接 CSI 座；**离地 174 mm、车头正中、竖直装**（距离表按上车实测生成，装法变了要重新量，`obstacle.md` §1） |
| 屏幕 | 10.1" 800×1280 MIPI DSI 竖屏，接 DSI 座 |
| STM32F103（`../Minecraft_MCU/MinecraftDog_STM32/`） | UWB 定位 + 电机驱动；UART 115200：CEP 脚 3 → PB11、PB10 → 脚 4、GND → 脚 2 |
| 陀螺仪 JY61P | 脚 5 → 模块 RX、模块 TX → 脚 6，VCC → 脚 1（3.3 V）、GND → 脚 2；平放、元件面朝上 |
| 霍尔 | D0 → CEP 脚 17，VCC → 脚 1，GND → 脚 2 |
| 尾巴步进驱动器 | R/A/H → CEP 脚 15，Gnd → 脚 2；电源用驱动器自己的，别从 FPGA 板取 |
| 音频 | TF 卡（FAT32，`1.wav` 背景音乐、`2.wav` 进食音效、`3.wav` 狗叫，16 位 PCM）→ ES8388 → 喇叭 J12 / J11 |
| 电源 | 稳压 5 V 3 A；**所有板子共地** |

接线细节 `src/doc/pinout.md`。CEP 看"脚号"（丝印），别看芯片管脚号。

## 3. 数据流

```
IMX415 ─MIPI─► ISP（伽马、去马赛克、白平衡）→ 缩小 800×448 ─► DDR2 ─► 屏幕合成 ─DSI─► 屏幕
   └─ 自动曝光 ─I2C─► 相机
   └─ 避障：160×90 → 地面 / 障碍 → 9 个方向各能走多远 ─┐
STM32（UWB：主人在哪）─UART─► mc_m0_link ─► mc_follow（每 20 ms：决策 → 目标航向 → 角度环）─► 两轮 PWM ─UART─► STM32
JY61P 陀螺仪 ─UART─► mc_imu_jy61p（自动配置、归零）─► 车头航向 / 角速度 ─┘
霍尔 ─► mc_hall ─► mc_behavior ─► mc_audio（进食音效）；背景音乐上电自动循环
```

## 4. 编译、下载、仿真

**TD 里编译和下载**（改了代码以后）：
1. 双击 `mcproject_code/MinecraftDog_FPGA.al` 打开工程。
2. 工具栏绿色 ▶（一键编译，约 10 分钟）；Console 里 `phy_1` 显示 `bitgen complete` 就好了。
3. 工具栏最右边绿色下载按钮（Tools → Download）→ Add 选 `mcproject_code/MinecraftDog_FPGA_Runs/best_result/MinecraftDog_FPGA.bit` → Mode 选烧 FLASH（断电保留；`JTAG` 断电就没了）→ Run。

`src/boot/MinecraftDog_FPGA.bit` 是 Claude 在命令行编的（`bash tools/td_build.sh`，临时目录跑，不动 TD 的文件夹），和 TD 编的一样，**用最新的那个**。

**仿真**（Git Bash，在本目录下）：`bash tools/sim.sh` 跑默认测试台（约 20 分钟，跳过慢的 `tb_top` / `tb_audio` / `tb_fb`）；`ALL=1 bash tools/sim.sh` 全跑；`bash tools/sim.sh tb_xxx` 跑一个。仿真器 Icarus 装在 `E:\FPGA\iverilog`。

## 5. 常调的参数（`mctop.v` 配置区）

| 参数 | 现在 | 作用 |
| --- | --- | --- |
| `AUD_SPK_VOL` | 22 | 喇叭音量（0~33，33 太响会拉垮电源） |
| `OBS_ROW_MIN` | 53 | 判断障碍从处理画面第几行起：53 ≈ 2.36 m（别再小）、60 ≈ 1.35 m、70 ≈ 84 cm |
| `OBS_YSPREAD` / `OBS_YS_NEAR` | 2 / 1 | 地面亮度宽容度（远处 / 1 m 内）：地板发紫 → 加大；墙判成地面 → 减小 |
| `OBS_TC` / `OBS_TY` | 16 / 16 | 地面门限：地板花纹发紫 → 调小（12 是最早的值）；障碍判不出来 → 调大（24 太高） |
| `FOLLOW_STOP_CM` / `FOLLOW_START_PWM` | 200 / 3300 | 离主人多近停 / 起步快慢（前进 = 起步 + (距离 − 200) × 10，最多 5000） |
| `HEAD_KP` / `HEAD_KI` / `HEAD_KD` | 70 / 20 / 10 | 角度环：左右摆 → 减 KP 或加 KD；转得慢 → 加 KP（KD 跟着加）；走直线一直偏 → 加 KI |
| `FOLLOW_DEADBAND` / `FOLLOW_TURN_SLEW` / `HEAD_TURN_MAX` | 4° / 800 / 1500 | 主人偏多少才改目标航向 / 转向变化快慢 / 转向上限（大角度转弯快不快看它） |
| `AVOID_CM` / `AVOID_SPIN_CM` | 100 / 60 | 多近开始绕 / 多近原地转 |
| `AVOID_FAR_CM` / `AVOID_OWNER_GAP_CM` | 200 / 60 | 主人方向多远以内的东西提前绕（≤ 100 = 不提前绕）/ 只算比主人近这么多的（再远的是主人的腿） |
| `AVOID_HOLD_CM` | 50 | 绕完先直走多远再拐回主人 |
| `AVOID_SCAN_DEG` / `AVOID_SCAN_PAUSE_MS` | 20 / 200 | 找出口每步转多少度 / 停多久看 |
| `BARK_CM` / `BARK_MS` | 999 / 1000 | 主人多远叫（999 = 10 m 以上）/ 太远或丢了要持续多久 |

现象 → 改什么：`obstacle.md` §6 的表；调试顺序：`obstacle.md` §10。改完在 TD 里重新编译、下载（§4）。

## 6. 待办

1. 上车调参（`obstacle.md` §10）：先核对距离表（盒子下沿碰灰线 ≈ 2.36 m、碰黄框上沿 ≈ 58 cm、刚出底边 ≈ 49 cm），再调地面识别、走直线、转弯、避障、找出口和狗叫（第 9 步）。
2. 比赛报告 + 视频。
3. 狗叫现在按 10 m 叫：要 20 m 得把串口距离改成 4 位（STM32 和 `mc_m0_link` 一起改，`obstacle.md` §5），再把 `BARK_CM` 改成 2000。
4. 避障：找到出口以后可能又回到同一个死角来回转；要彻底解决得做"沿墙绕、UWB 距离变近才离开"（`obstacle.md` §8）。
5. 有余力：屏幕背光调暗。

## 7. 目录

```
Minecraft_MLKfpgacode/
├── README.md
├── tools/   sim.sh（仿真）、td_build.sh（命令行编译）、gen_al.sh（重新生成 .al，TD 要关）、gen_osd_dash.pl（文字面板）、
│            gen_obs_lut.pl（避障几何表）、gen_logo.ps1（安路 Logo 位图）、gen_gamma.pl、gen_font.sh、mk_sd_test_image.pl、wav_to_tf.pl（WAV 转 16 位 48 kHz）、render_pdf.ps1
└── mcproject_code/   TD 工程（MinecraftDog_FPGA.al）
    └── src/
        ├── rtl/   mctop.v（顶层 + 配置区）、system/ hmi/ comm/ tail/ sensor/ app/ audio/ video/
        ├── pin/   mc_pin.adc（管脚）、mc_timing.sdc
        ├── ip/    TD 生成的 IP
        ├── sim/   测试台 + stubs/ + models/
        ├── boot/  命令行编出来的 .bit
        └── doc/   pinout.md 接线｜video_pipeline.md 视频 + 版面｜obstacle.md 避障 + 跟随 + 角度环 + 串口 / 陀螺仪协议｜hmi_tail.md 按键 / 文字 / 霍尔 / 尾巴｜audio.md 音频
```

## 8. 开发规则（给接手的人 / AI）

1. 新 RTL 必须配测试台（`src/sim/tb_*.v`，在 `tools/sim.sh` 的 `rtl_for` 登记），并做突变检查（故意改坏一处，测试台必须报错）；等价突变记在 `hmi_tail.md` §7。
2. TD 开着（`mcproject_code/.lock.f` 存在）时不改 `.al`；增删文件：关 TD → `bash tools/gen_al.sh`。
3. 自写模块 `mc_` 前缀、一个文件一个模块；端口 `I_` / `O_`，内部 `S_`；时序逻辑只用 `<=`；跨时钟域单比特用 `mc_sync_bits`。厂商模块尽量不改，改了记进 `video_pipeline.md` §9。
4. 硬约束：DSP 只有 40 个（小常数乘法写成移位相加）；DSI 水平消隐 24/136/160 不要压缩；`CROP_Y0` 奇数（RGGB）；TD 必须从 `mcproject_code/` 打开工程（否则 DDR2 约束丢失）。
5. 编码 UTF-8（厂商文件多为 GBK）。用词：Verilog 没有"函数调用"，说模块 / 例化 / 端口。
6. 对用户：中文，用 STM32 类比，给 TD 菜单步骤；上板测试只说预期现象。

已删除（记录）：轮子电机驱动（归单片机）、台架音频页和测试音、步进串口接收、白平衡除法器、`RB_SWAP`、手动增益、厂商 96→128 打包、耳机输出。

## 9. 参考

- Ulrich & Nourbakhsh, *Appearance-Based Obstacle Detection with Monocular Color Vision*（AAAI 2000）：避障原型（按颜色分地面 / 障碍）。
- VFH+、改进 Follow-the-Gap：绕行方向的代价函数（`obstacle.md` §6）。
- *A Monocular Vision Sensor-Based Obstacle Detection Algorithm…*（Sensors 16(3):311）：行号 → 距离。
- Linux `panel-ilitek-ili9881c.c`：屏幕初始化序列。
- 米联客 / 安路例程（`E:/FPGA/reference/`）：`08_csi_dsi_cs500_7cun`（视频通路底座）、`09_aud8388_loop`、硬件手册、TD 快速入门（第 46~49 页：编译和下载）。
