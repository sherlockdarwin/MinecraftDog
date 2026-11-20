# MinecraftDog：基于安路 PH1P35 的跟随避障机器狗（FPGA 部分）

> 2026 嵌入式芯片与系统设计竞赛 · FPGA 赛道（安路选题五：自主命题，自备板卡）｜TD 6.2.1 + Verilog｜更新 2026-11-17
> 截止 **2026-11-04 18:00**（报告 + 视频，www.socchina.net）；决赛 11-20 ~ 22 南京。OSD 必须带"安路"Logo（已做，`video_pipeline.md` §4）。

## 1. 现状

**功能都上车验证过：跟随、绕障、找出口、狗叫、尾巴、喂食。** 11-17 加了激光测距 VL53-200（CEP 脚 7）：补视觉看不出的白墙，并在车前近处有东西时暂停学地面（`obstacle.md` §11）。上车两次（11-17、11-18）：模块有数据，但滤过的距离一直是 255，所以车照样撞墙；隔几秒闪一下 `NOLK`。原因是模块在量到的组之间夹"没有新数据"（`S255`），而且大约 300 ms 才出一次新测量，原来"300 ms 没有测量就掉线"把两次测量拆散了。已改：按状态号分类、900 ms 没有测量才算掉线；屏幕加了模块原始值和两次测量的间隔 `dt`，待再上车（`obstacle.md` §11.8）。没接激光时行为和以前一样。开发中的问题和技术文档要改的地方见 [`../FPGA开发记录.md`](../FPGA开发记录.md)。

| 功能 | 状态 |
| --- | --- |
| 相机 → 屏幕 | 正常：上面相机，中间 8 个方块 + 6 行字 + 安路 Logo，下面避障处理画面 |
| 跟随 | 正常：UWB 给方向，陀螺仪角度环保持航向（`obstacle.md` §6）。超过 2 m 跟上、2 m 内停；基础前进由 3300 调至 3100、原地转向由 2200 调至 2100，待上车验证。主人在背后时 STM32 发 99°，这边原地转 |
| 避障 | 正常：1 m 内绕、60 cm 内原地转；主人方向 2 m 内有东西提前绕；走不了就转着找出口，转一圈没有就停下狗叫。障碍物旁边不粘连。和地面太像的白墙、踢脚线靠颜色判不出来，东西进了黄框会学成地面（`obstacle.md` §8）；激光补正前方 ±9°、1.2 m 以内（还没验证） |
| 激光测距 VL53-200 | 上车两次：有数据、距离出不来（两处已改，待再上车）。正前方的距离和视觉取近的；≤ 80 cm 有东西就暂停学地面。屏幕第 3 行：`TOF` 状态 / 距离 / `REF` / 模块原始状态号和毫米（如 `S000 0452mm`）；第 4 行最后 `dt 300ms` = 两次测量隔多久；曝光行数挪到了第 1 行 |
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
| UWB | 爱蓝信 ALX-G100A 基站 × 4（左 / 前 / 右 / 后，接 STM32）+ OverAir U68 标签（小麦信标） |
| 轮子 | TB6612 双路驱动模块带稳压版（D153C，接 STM32）+ 直流减速电机 × 2 |
| 陀螺仪 JY61P | 脚 5 → 模块 RX、模块 TX → 脚 6，VCC → 脚 1（3.3 V）、GND → 脚 2；平放、元件面朝上 |
| 霍尔 | D0 → CEP 脚 17，VCC → 脚 1，GND → 脚 2 |
| 激光测距 | 维特 VL53-200：TXD → CEP 脚 7（FPGA 只收），VCC → 脚 1（**3.3 V，别接 5 V**），GND → 脚 2；装在车头最前面后面 10 cm（镜头在 5 cm，代码里读数减 5 cm），朝正前方 |
| 尾巴 | 张大头 ZDT Emm42（X42S）：R/A/H → CEP 脚 15，Gnd → 脚 2；电源用驱动器自己的，别从 FPGA 板取 |
| 音频 | TF 卡（FAT32，`1.wav` 背景音乐、`2.wav` 进食音效、`3.wav` 狗叫，16 位 PCM）→ ES8388 → 3020 腔体喇叭（4 Ω 3 W）J12 / J11 |
| 电源 | 稳压 5 V 3 A；**所有板子共地** |

接线细节 `src/doc/pinout.md`。CEP 看"脚号"（丝印），别看芯片管脚号。

## 3. 数据流

```
IMX415 ─MIPI─► ISP（伽马、去马赛克、白平衡）→ 缩小 800×448 ─► DDR2 ─► 屏幕合成 ─DSI─► 屏幕
   └─ 自动曝光 ─I2C─► 相机
   └─ 避障：160×90 → 地面 / 障碍 → 9 个方向各能走多远 ─┐
STM32（UWB：主人在哪）─UART─► mc_m0_link ─► mc_follow（每 20 ms：决策 → 目标航向 → 角度环）─► 两轮 PWM ─UART─► STM32
JY61P 陀螺仪 ─UART─► mc_imu_jy61p（自动配置、归零）─► 车头航向 / 角速度 ─┘
VL53-200 激光 ─UART─► mc_tof_vl53 ─► 正前方距离 ─► mc_follow（和视觉取近的）；≤ 80 cm ─► 避障暂停学地面
霍尔 ─► mc_hall ─► mc_behavior ─► mc_audio（进食音效）；背景音乐上电自动循环
```

## 4. 编译、下载、仿真

**TD 里编译和下载**（改了代码以后）：
1. 双击 `mcproject_code/MinecraftDog_FPGA.al` 打开工程。
2. 工具栏绿色 ▶（一键编译，约 10 分钟）；Console 里 `phy_1` 显示 `bitgen complete` 就好了。
3. 工具栏最右边绿色下载按钮（Tools → Download）→ Add 选 `mcproject_code/MinecraftDog_FPGA_Runs/best_result/MinecraftDog_FPGA.bit` → Mode 选烧 FLASH（断电保留；`JTAG` 断电就没了）→ Run。

本次前进 3100、原地转向 2100 的 bit 已生成在工程根目录 `MinecraftDog_FPGA_3100_2100.bit`（TD 6.2.1，建立余量 +0.107 ns、保持余量 +0.020 ns；待上车验证）。`MinecraftDog_FPGA_3100.bit` 是前一版：原地转向 2200。`src/boot/MinecraftDog_FPGA.bit` 是 3300 的旧版，与 `bit_restore/MinecraftDog_FPGA_6.0_distance.bit` 逐字节一致。原工程内旧的 `best_result` 是更早的版本，只有在 TD 中成功重新编译后才用它；不要只凭文件时间判断。

**仿真**（Git Bash，在本目录下）：`bash tools/sim.sh` 跑默认测试台（约 20 分钟，跳过慢的 `tb_top` / `tb_audio` / `tb_fb`）；`ALL=1 bash tools/sim.sh` 全跑；`bash tools/sim.sh tb_xxx` 跑一个。仿真器 Icarus 装在 `E:\FPGA\iverilog`。

## 5. 常调的参数（`mctop.v` 配置区）

| 参数 | 现在 | 作用 |
| --- | --- | --- |
| `AUD_SPK_VOL` | 22 | 喇叭音量（0~33，33 太响会拉垮电源） |
| `OBS_ROW_MIN` | 53 | 判断障碍从处理画面第几行起：53 ≈ 2.36 m（别再小）、60 ≈ 1.35 m、70 ≈ 84 cm |
| `OBS_YSPREAD` | 2 | 地面亮度宽容度：大片地板发紫 → 加大；和地面一样灰的东西判不出来 → 减小（收太紧反光地面会粘连） |
| `OBS_TC` / `OBS_TY` | 15 / 15 | 地面门限：零星紫点 → 调小；障碍判不出来 → 调大（13~16 效果几乎一样，24 太高） |
| `FOLLOW_STOP_CM` / `FOLLOW_START_PWM` | 200 / 3100 | 离主人多近停 / 起步快慢（前进 = 起步 + (距离 − 200) × 10，最多 5000） |
| `FOLLOW_PIVOT_PWM` / `AVOID_SPIN_PWM` | 2100 / 2100 | 朝主人原地转 / 避障找出口原地转的力度；若转不动，先将对应值加回 2200 |
| `HEAD_KP` / `HEAD_KI` / `HEAD_KD` | 70 / 20 / 10 | 角度环：左右摆 → 减 KP 或加 KD；转得慢 → 加 KP（KD 跟着加）；走直线一直偏 → 加 KI |
| `FOLLOW_DEADBAND` / `FOLLOW_TURN_SLEW` / `HEAD_TURN_MAX` | 4° / 800 / 1500 | 主人偏多少才改目标航向 / 转向变化快慢 / 转向上限（大角度转弯快不快看它） |
| `AVOID_CM` / `AVOID_SPIN_CM` | 100 / 60 | 多近开始绕 / 多近原地转 |
| `AVOID_FAR_CM` / `AVOID_OWNER_GAP_CM` | 200 / 60 | 主人方向多远以内的东西提前绕（≤ 100 = 不提前绕）/ 只算比主人近这么多的（再远的是主人的腿） |
| `AVOID_HOLD_CM` | 50 | 绕完先直走多远再拐回主人 |
| `AVOID_SCAN_DEG` / `AVOID_SCAN_PAUSE_MS` | 20 / 200 | 找出口每步转多少度 / 停多久看 |
| `BARK_CM` / `BARK_MS` | 999 / 1000 | 主人多远叫（999 = 10 m 以上）/ 太远或丢了要持续多久 |
| `TOF_MAX_CM` / `TOF_FREEZE_CM` / `TOF_SIDE` | 120 / 80 / 2 | 激光多远以内才算（前面没东西却显示 080~120cm = 照到地面 → 模块往上仰）/ 多近暂停学地面（0 = 不暂停）/ 盖住正前方两边几个方向（2 = ±9°） |

现象 → 改什么：`obstacle.md` §6 的表；调试顺序：`obstacle.md` §10。改完在 TD 里重新编译、下载（§4）。

## 6. 待办

1. 上车验证激光（`obstacle.md` §10 第 10 步：先看距离出不出来、`dt` 是多少；`dt` 约 300 可以把模块改回一般模式，§11.8 有要发的字节；闪 `NOLK` 按 §11.8 查线、模块 RX、供电），标定四基站（STM32 README 的"UWB 上车标定"）。
2. 比赛报告 + 视频。
3. 换场地后调参（`obstacle.md` §10）：先核对距离表，再调地面识别、走直线、转弯、避障、找出口和狗叫。
4. 狗叫现在按 10 m 叫：要 20 m 得把串口距离改成 4 位（STM32 和 `mc_m0_link` 一起改，`obstacle.md` §5），再把 `BARK_CM` 改成 2000。
5. 避障：激光只看正前方 ±12.5°，斜着靠近的白墙、从侧面进黄框的东西还是靠颜色；找到出口后可能回到同一个死角，要做沿墙绕（`obstacle.md` §8）。

## 7. 目录

```
Minecraft_MLKfpgacode/
├── README.md
├── bit_restore/   存档的 bit（v1basicdone、v2addbark、v3、v4、v5），退路
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
