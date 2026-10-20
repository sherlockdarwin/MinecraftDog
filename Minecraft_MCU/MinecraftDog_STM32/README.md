## MinecraftDog STM32F103RCT6

### 功能

跟随 + 避障的决策全在 FPGA, STM32 只做传感器和执行器:

1. **UWB 定位**: 三个基站 (左 / 前 / 右) 各接一个串口, 中断收字节, 解 0x2001 定位帧 (37 字节, XOR 校验)。
   取角度最靠近自己正前方的那个基站, 换算成车体坐标 (左负右正) 的角度 + 距离; 500 ms 没新数据 = 收不到 UWB。
2. **发给 FPGA**: 有新 UWB 数据就用 DMA 发主人的角度、距离; 收不到 UWB 就发"丢失"。
3. **收 FPGA 的命令**: DMA 环形缓冲收两个轮子的 PWM, 解包后驱动电机。
4. **停车保护**: 收不到 UWB / 200 ms 没收到完整的 FPGA 帧 / FPGA 发来停车, 任何一条成立就关电机锁停车。
5. **电机驱动**: 两路 PWM (9 kHz, 0~8000) + 4 个方向脚, 带死区补偿和方向极性开关。
6. **编码器**: TIM8 / TIM2 硬件计数, 速度和里程函数都在 `encoder.c`, 现在控制里没用到。
7. **按键试电机**: 短按 KEY1 两轮走 3 秒, 第一次前进、下一次后退, 轮流来; 不用接 FPGA。
8. **LED**: 和 FPGA 通 = 1 秒闪一次, 不通 = 快闪; 跟随测试模式 = 2 秒变一次。
9. **跟随测试模式**: 长按 KEY1 (1 秒) 进入, 不经过 FPGA, 只用 UWB 跟随 (`follow.c`); 长按 KEY2 (1 秒) 退出。
10. **屏幕** (1.44 寸 128x128 彩色 LCD, ST7735S, 软件 SPI): 显示 UWB 方向 / 角度 / 距离和 FPGA 的轮子命令, 1 秒刷新一次。
11. **步进电机** (尾巴, ZDT X42S): 上电 / 复位 1 秒后自动回到初始位置; 短按 KEY2 摇一个来回 (左 45° → 中 → 右 45° → 中)。

### 目录

| 位置 | 内容 |
| --- | --- |
| `Core/` `Drivers/` | CubeMX 生成。`main.c` 只在 USER CODE 里调 `bsp_init()` / `Scheduler_Run()` |
| `SYSTEM/` | `AllHeader.h`、`bsp.c` (模块初始化)、`delay.c` (SysTick 微秒延时 + 秒表)、`task.c` (协作式调度表, 1 ms 时基 = `HAL_GetTick()`) |
| `HARDWARE/MLK/` | FPGA 串口 (USART3, DMA 收发), 解包变量在 `fpgamlk.c` 顶部 |
| `HARDWARE/UWB/` | 三个 UWB 基站 (USART2 / UART4 / UART5, 接收中断) |
| `HARDWARE/MOTOR/` | 电机 PWM + 方向、编码器 |
| `HARDWARE/STEPPER/` | `stepper.c` ZDT X42S 串口协议 (USART1); `tail.c` 上电回零 + 摇摆的动作表 |
| `HARDWARE/LCD/` | 1.44 寸 ST7735S 彩屏, 软件 SPI (PB4~PB9) |
| `HARDWARE/KEY/` | KEY1 / KEY2 |
| `ALGORITHM/` | `follow.c` UWB 跟随算法; `follow_mode.c` 跟随测试模式 (长按 KEY1 / KEY2 进出) |

### 引脚

| 功能 | 引脚 | 外设 |
| --- | --- | --- |
| FPGA | PB10 TX -> FPGA CEP 脚 4; PB11 RX <- CEP 脚 3; GND 接 CEP 脚 2 | USART3, RX DMA1 CH3 (Circular), TX DMA1 CH2 |
| UWB 左 / 前 / 右 | PA3 / PC11 / PD2 收 (PA2 / PC10 / PC12 发, 预留) | USART2 / UART4 / UART5, 接收中断 |
| 步进电机 | PA9 TX -> 驱动器 R/A/H; PA10 RX <- 驱动器 TX (可不接); GND 共地 | USART1, 115200, 发送阻塞, 接收中断 (只看应答) |
| 左 / 右轮 PWM | PA6 / PA7 | TIM3 CH1 / CH2, 9 kHz, 0~8000 |
| AIN1 AIN2 BIN1 BIN2 | PB12 PB13 PB14 PB15 | GPIO 输出 |
| 左编码器 A / B | PC6 / PC7 | TIM8 编码器 |
| 右编码器 A / B | PA15 / PB3 | TIM2 编码器 (部分重映射, 要 SYS = Serial Wire) |
| LCD (板子顶上 LCD 排针) | SC PB8 = SCL, DI PB9 = SDA, CS PB7, RST PB6 = RES, RS PB5 = DC, BLK PB4 | GPIO 输出, 软件 SPI |
| KEY1 / KEY2 | PC9 / PC8 | 输入, 按下 = 低 |
| LED | PA8 | GPIO 输出 |
| SWD | PA13 / PA14 | |

### CubeMX 里每个引脚的设置 (上拉 / 下拉)

| 引脚 | 模式 | 上下拉 | 为什么 |
| --- | --- | --- | --- |
| 串口收 PA3 / PC11 / PD2 / PB11 / PA10 | 串口 RX | **上拉** | 线没接或模块没上电时不乱收字节 |
| 串口发 PA2 / PC10 / PC12 / PB10 / PA9 | 串口 TX | 不用 (F1 的复用输出不能设) | 推挽输出, 自己就能出高低电平 |
| PB12~PB15 (AIN / BIN) | GPIO_Output 推挽, 初始 Low | 不用 | 推挽输出自己就能出高低电平; 初始 Low = 电机不转 |
| PB4~PB9 (LCD) | GPIO_Output 推挽, 初始 Low | 不用 | 同上; 初始 Low 让背光 (BLK) 先灭, 清好屏再亮; SCL / SDA 的输出速度代码里会改成 High, CubeMX 里不用管 |
| PA8 (LED) | GPIO_Output 推挽 | 不用 | |
| PC8 / PC9 (KEY) | GPIO_Input | **上拉** | 按键按下接地; 按了没反应就改下拉, 同时改 `key.h` 的 `KEY_PRESSED_LEVEL` |
| PC6 / PC7 / PA15 / PB3 (编码器) | 定时器编码器输入 | 不用 | 编码器自己是推挽输出; 手转轮子计数不变 (开漏输出的编码器) 再改上拉 |
| PA6 / PA7 (PWM) | 定时器 PWM 输出 | 不用 | |

**建议把 PA6 / PA7 钉住**: 芯片图上在 PA6 上点右键 → Signal Pinning (出现小图钉), PA7 也一样。
不钉的话, 以后打开别的外设 (比如 SPI1) CubeMX 可能自己把电机 PWM 挪到别的脚上。

### 任务

| 任务 | 周期 | 做什么 |
| --- | --- | --- |
| `Task_UWB_Poll` | 5 ms | 解析 UWB 帧 |
| `Task_FPGA_Rx` | 5 ms | 解 FPGA 帧 (`#+3000-0500*` / `#S*`); 串口出错时重启接收 DMA |
| `Task_Motor_Drive` | 5 ms | 按 FPGA 命令驱动电机; UWB 丢 / 200 ms 没帧 / `#S*` 立即停车; 按键试电机 |
| `Task_FPGA_Tx` | 20 ms | 新 UWB 数据发 `$l12350&`, 收不到 UWB 发 `$S&` (100 ms 重发) |
| `Task_Key_Scan` | 10 ms | 按键消抖 (长按 = 1 秒) |
| `Task_Follow_Mode` | 20 ms | 跟随测试模式: 长按进出, 模式里跑 `Follow_Process()` |
| `Task_Tail` | 10 ms | 步进电机: 上电回零; 短按 KEY2 摇一个来回 |
| `Task_LED` | 100 ms | 和 FPGA 链路通 = 1 秒闪一次, 不通 = 快闪 |
| `Task_UWB_Display` | 1000 ms | 刷屏 (软件 SPI, 约 20 ms, 放在任务表最后) |

### 按键

| 按键 | 短按 | 长按 1 秒 |
| --- | --- | --- |
| KEY1 (PC9) | 试电机: 两轮 ±3000 走 3 秒, 第一次前进、下一次后退; 测试中再按 = 停 | 进入跟随测试模式 |
| KEY2 (PC8) | 步进电机摇一个来回 | 退出跟随测试模式 |

哪个轮子转反了, 改 `motor.h` 的 `MOTOR_L_DIR_INVERT` / `MOTOR_R_DIR_INVERT`。

### UWB 接线和排查

基站 (规格书 V2.2): 带转接板的 4 针是 **TX RX 5V GND**, 5V 脚接 5 V; 裸模块 VCC 接 3.3 V。数据线都是 3.3 V。
三个基站电流大约按 1 A 留余量, 从车上 5 V 降压那路取电, 别从开发板的 3V3 / 电脑 USB 取。

| 基站 | 转接板 TX (Pin1) 接 | 转接板 RX (Pin2) 接 (可不接) |
| --- | --- | --- |
| 左 | PA3 | PA2 |
| 前 | PC11 | PC10 |
| 右 | PD2 | PC12 |

GND 一定要和 STM32 共地。基站的 **TX 接 STM32 的 RX**, 不是 TX 接 TX。

指示灯 (规格书 5.1 / 5.5): 基站红灯常亮 = 上电; **绿灯闪 (500 ms 翻转一次) = 信标在线**, 这时基站就在主动发定位帧 (约 40 次/秒),
不用做任何设置。手环信标要双击按键进跟随模式 (绿灯常亮)。

屏幕中间的小字 (左 / 前 / 右, 只显示后 4 位):

| 行 | 含义 |
| --- | --- |
| `rx` | 收到的字节数, 正常每路每秒约 1480 (40 帧 × 37 字节) |
| `ok` | 解出的定位帧, 正常每路每秒约 40 |
| `ck` | 校验 (异或) 不对的帧 |
| `F len .... ver ....` | 前基站最近一个定位帧的长度字段 / 版本号 (规格书写的是 0025 / 0100) |
| `F xor .. calc ..` | 前基站最近一个定位帧里的校验字节 / 程序算出来的异或, 两个一样才算 `ok` |

| 现象 | 原因 |
| --- | --- |
| `rx` 一直是 0 | 线上没数据: 基站 TX 没接到对应的 STM32 RX 脚 / TX 接成了 TX / 没共地 |
| `rx` 在涨, `ok` 和 `ck` 都不涨 | 一个 `FF FF FF FF` + `20 01` 的帧都没找到: 波特率不对或者线上全是乱码 |
| `rx` 在涨, `ck` 在涨 | 找到了帧但校验不对: 把 `F xor` 那两行拍给我 |
| `ok` 在涨, 屏上还是 `UWB no signal` | 不应该出现, 拍给我 |

解析按厂家例程 (`示例代码/STM32F1-Usart`) 的做法: 找 4 个 `FF` 帧头, 看第 9~10 字节的命令码, `0x2001` 就收 37 字节;
**长度字段和版本号不检查** (规格书里定位帧写版本 0x0100、心跳帧写 0x0101, 本身就对不上), 但保留了异或校验。
用规格书 6.2 节的两个例子帧验证过 (25 cm / 18°、98 cm / -39°), 也测过版本号 / 长度字段不一样、帧头前多一个 `FF` 的情况。

### 跟随测试模式 (试 UWB 跟随算法, 不接 FPGA 也能用)

- **长按 KEY1 1 秒** 进入: 电机只听 `follow.c` 的 `Follow_Process()`, FPGA 的命令不管;
  LED 每 2 秒变一次, 屏幕最下面一行显示 `UWB FOLLOW MODE`。模式里短按 KEY1 不起作用; 短按 KEY2 照样让步进电机摇摆。
- **长按 KEY2 1 秒** 退出: 立即停车, 回到正常的 FPGA 模式。
- 算法 (不避障, 按 1 kg 左右的车调过): 收不到 UWB 或距离 > 20 m 停车; 3 m 以内停车; 否则
  - 角度超过 45° 原地转 (两轮 ±2800), 转到 25° 以内再往前走;
  - 前进 = 2200 + (距离 - 300 cm) × 8, 最多 5000 (3.5 m 是 2600, 5 m 是 3800, 6.5 m 以外 5000);
  - 角度在 ±5° 以内当正前方; 转向 = 角度 × 40, 但最多是前进的一半 (内侧轮不会停, 不会原地打转);
  - 左 = 前进 + 转向, 右 = 前进 - 转向, 限 ±6500; 每 20 ms 最多加 200 / 减 400。
- 参数都在 `follow.h`: 走不动就加大 `FOLLOW_START_PWM`; 原地转不动就加大 `FOLLOW_PIVOT_PWM`;
  转弯太慢加大 `FOLLOW_ANGLE_KP_PWM_PER_DEG`, 来回摆头就减小它或加大 `FOLLOW_ANGLE_DEADBAND_DEG`;
  室内试觉得 3 m 太远就改 `FOLLOW_STOP_DISTANCE_CM`。
- 原来的 MSPM0 参数 (起步 600、转向 × 35) 上车实测: 5 m 以外才推得动, 一直原地打转。
  FPGA 的 `mc_follow` 用的还是这套老数值, 走 FPGA 模式会有一样的问题, 那边也要按这里的思路改。
- **不要了就删掉** (搜 `FollowMode` 能找全): `follow_mode.c/.h`、`AllHeader.h` 里 include 它的那一行、
  `task.c/.h` 里的 `Task_Follow_Mode` 和任务表那一行、`Task_Motor_Drive` / `Task_LED` 里的 `FollowMode_IsActive()` 判断。

### 步进电机 (尾巴, ZDT X42S 第二代闭环, Emm 固件)

做法和 FPGA 的 `mc_tail.v` 一样, 命令字节按《ZDT_X42S 用户手册 V1.0.5》第 5 章和官方例程 `Emm_V5.c` 核对过。
驱动器用出厂设置: `P_Serial = UART_FUN`、`UartBaud = 115200`、`ID_Addr = 1`、`Checksum = 0x6B`、细分 16 (一圈 3200 脉冲)。

- **上电 / 复位回零**: 上电 1 秒后 解除保护 `01 0E 52 6B` → 使能 `01 F3 AB 01 00 6B` → 单圈就近回零 `01 9A 00 00 6B`
  → 等 2 秒 → 设坐标零点 `01 0A 6D 6B`。之后"绝对位置 0" = 初始位置。
- **回零零点要先在驱动器上存一次** (掉电不丢): 驱动器断电, 用手把尾巴拧到初始位置, 上电后驱动器菜单 `O_Set` → `Set O`;
  或者在代码里调一次 `Stepper_SetOrigin(1, 1)` (`01 93 88 01 6B`)。没存过的话, 回零会转到出厂的零点。
- **摇摆** (短按 KEY2): 中 → 左 45° → 中 → 右 45° → 中, 绝对位置、10 RPM。每段 = 走完时间 + 停顿:
  走 45° 要 0.75 秒; 到了左 / 右两头只停 0.05 秒就往回摆, 回到中间停 0.5 秒。一个来回约 4.1 秒。
  回零没做完或者正在摇的时候按了不理。
- 参数在 `tail.h`:

| 参数 | 默认 | 作用 |
| --- | --- | --- |
| `TAIL_SWING_DEG` | 45 | 摆幅 (度), 45° = 400 脉冲 |
| `TAIL_RPM` | 10 | 摇摆转速; 走完时间 `TAIL_MOVE_MS` 按摆幅和转速自动算 |
| `TAIL_SIDE_PAUSE_MS` | 50 | 摆到左 / 右两头后停多久 |
| `TAIL_CENTER_PAUSE_MS` | 500 | 回到中间停多久 |
| `TAIL_LEFT_IS_CCW` | 1 | 向左 = 电机逆时针; 摆反了改成 0 |
| `TAIL_GEAR_X100` | 100 | 减速比 × 100 (尾巴直接装在电机轴上 = 100) |

- 停顿太短、电机还没走到下一条命令就来了, 会提前掉头 (摆幅变小一点), 那就把停顿加大一点。
- **看驱动器有没有收到** (Live Expressions): `g_stepper_tx_count` 发出的条数; `g_stepper_reply` 最近一条应答
  (`01 FD 02 6B` = 收到, `9F` = 动作做完, `E2` = 条件不满足, 比如堵转保护 / 没使能 / 欠压), `g_stepper_reply_count` 应答条数;
  `g_tail_state` 0 等上电 / 1 回零中 / 2 空闲 / 3 摇摆中。应答要接了 PA10 才看得到。
- 板子 USB 口要是 CH340 串口下载 (接在 PA9/PA10 上), 驱动器的 TX **不要**接 PA10 (两个输出会打架), 只接 PA9 → 驱动器就能用。
- FPGA 那边也有一路尾巴串口 (CEP 脚 15), 两个别同时接到驱动器上。

### 屏幕 (1.44 寸 128x128 彩色 LCD, ST7735S)

这块屏是 **SPI 接口的彩色 LCD**, 不是 OLED: 引脚上的 SCL / SDA 是 SPI 的时钟 / 数据, BLK 是背光。
只接电源和 SCL/SDA 时背光亮了但屏没初始化, 所以是全白。

**接线** (屏的引脚 -> 板子顶上 LCD 排针的丝印; 两边顺序不一样, 用杜邦线一根根对着接):

| 屏 | 排针丝印 | 引脚 |
| --- | --- | --- |
| GND | GND | |
| VCC | 3V3 | |
| SCL | SC | PB8 |
| SDA | DI | PB9 |
| RES | RST | PB6 |
| DC | RS | PB5 |
| CS | CS | PB7 |
| BLK | BLK | PB4 |

**CubeMX**: I2C1 的 Mode 改成 **Disable**; PB4~PB9 都设成 **GPIO_Output**, User Label 依次填
`LCD_BLK`(PB4) `LCD_DC`(PB5) `LCD_RES`(PB6) `LCD_CS`(PB7) `LCD_SCL`(PB8) `LCD_SDA`(PB9), 推挽、不上下拉, 初始电平 Low。

**为什么用软件 SPI, 不用 SPI1**: CubeMX 里 SPI1 没变红, 但它只有两组脚能用:

| SPI1 | SCK | MOSI | 占用 |
| --- | --- | --- | --- |
| 默认 | PA5 | **PA7** | PA7 = 右轮 PWM (TIM3_CH2) |
| 重映射 | **PB3** | PB5 | PB3 = 右编码器 B (TIM2_CH2) |

它没变红是因为 CubeMX 觉得可以把电机 PWM (TIM3) 挪到 PB4/PB5 给它让路, 那样电机要重新接线, 还和屏的 BLK / DC 撞了。
而且板子 LCD 排针的 SC / DI 是 PB8 / PB9, 这两个脚本来就没有 SPI 功能 (数据手册表 5), 板子设计时就是按软件 SPI 走的。
软件 SPI 每秒刷 5 行字约 20 ms, 够用。

- 没配这 6 个 Label 时屏的函数全是空操作, 工程照样编译。
- 初始化命令和显存偏移参考 Adafruit-ST7735-Library 的 1.44 寸 (green tab)。开机先把整块显存清黑再开背光, 不闪白屏。
- 显示: 第 1 行 UWB 方向 + 角度, 第 2 行距离, 第 3 / 4 行 FPGA 状态和轮子命令,
  中间 5 行小字是 UWB 排查 (见"UWB 接线和排查"), 最下面一行跟随测试模式。
- 不同厂家的屏偏一两个点: 改 `lcd.h` 的 `LCD_X_OFFSET` / `LCD_Y_OFFSET`; 字上下颠倒: `LCD_ROTATE_180` 改 1;
  红蓝颠倒: 改 `LCD_BGR`; 底色是白的 (颜色反了): 改 `LCD_INVERT`。

### 和 FPGA 的通讯协议

UART 115200 8N1, ASCII, **位数不够前面补 0**。
接线: FPGA CEP 脚 3 (FPGA 发) -> **PB11**; **PB10** -> CEP 脚 4 (FPGA 收); GND 接 CEP 脚 2。

| 方向 | 帧 | 含义 | 什么时候发 |
| --- | --- | --- | --- |
| STM32 -> FPGA | `$` + `l`/`r` + 角度 2 位 + 距离 3 位 + `&` | 主人在左 (`l`) / 右 (`r`) 多少度、多远 (cm)。例 `$l12350&` = 左 12°、350 cm; `$r00150&` = 正前方、150 cm。角度超过 99° 发 99, 距离超过 999 cm 发 999 | 每次有新 UWB 数据 (最快 20 ms 一帧) |
| STM32 -> FPGA | `$S&` | 收不到 UWB | 刚丢时立刻发, 之后每 100 ms 一帧 |
| FPGA -> STM32 | `#` + 左轮 (符号 + 4 位) + 右轮 (符号 + 4 位) + `*` | 两个轮子的 PWM, 正 = 前进, 满量程 8000 (就是 `PWM_Control_Car(左, 右)` 的参数)。例 `#+3000-0500*` = 左 +3000、右 -500 | FPGA 每 20 ms 一帧 |
| FPGA -> STM32 | `#S*` | 马上停车 | 停车期间每 20 ms 一帧 |

- 超时: FPGA 那边 300 ms 收不到 `$…&` 就当 UWB 丢了; STM32 这边 200 ms 收不到完整的 `#…*` 就停车。
- 解包规则 (`fpgamlk.c`): 收到 `#` 就重新开始一帧, 帧外的字节丢掉; `S` 大小写都行;
  格式不对的整帧丢掉 (计数在 `g_fpga_error_count`); 超过 ±8000 的按 ±8000 算。
- 解包结果 (`fpgamlk.c` 顶部, 调试时在 Live Expressions 里看):

| 变量 | 含义 |
| --- | --- |
| `g_fpga_left_pwm` / `g_fpga_right_pwm` | 最近一帧的左 / 右轮命令 |
| `g_fpga_stop` | 1 = 最近一帧是 `#S*` (上电还没收到帧时也是 1) |
| `g_fpga_last_ms` / `g_fpga_frame_count` | 最近一帧的时刻 / 累计帧数 |
| `g_fpga_error_count` / `g_fpga_uart_error_count` | 格式错的帧数 / 串口硬件错误次数 (每次都会自动重启接收) |
| `g_fpga_uwb_lost` / `g_fpga_tx_angle_deg` / `g_fpga_tx_distance_cm` / `g_fpga_tx_count` | 最近发给 FPGA 的内容和累计发出的帧数 |

### CubeMX 里不能改掉的设置

- USART3_RX DMA Mode = **Circular**; USART3 global interrupt **打开** (DMA 发送靠它结束, 串口出错也靠它报告)。
- USART1 / USART2 / UART4 / UART5 global interrupt 打开。它们的中断在 `stm32f1xx_it.c` 的 USER CODE 0 里直接调
  `Stepper_IRQHandler()` / `UWB_IRQHandler()` 后 `return`, 不走 HAL。
- TIM3 Period = 7999 (PWM 满量程 8000, 和 FPGA 发来的命令同一个刻度)。
- I2C1 保持 Disable (PB6 / PB7 给屏用)。
- 重新生成代码时 Project Manager 里要保持 "Keep User Code when re-generating"。

### 工程设置 (CubeMX 重新生成后还在)

- `.cproject` 的源码目录: `Core` `Drivers` (CubeMX 自带) + `ALGORITHM` `HARDWARE` `SYSTEM`。
- include 路径: `../` `../SYSTEM` `../HARDWARE` `../HARDWARE/MOTOR` `../HARDWARE/UWB`。
- CubeMX 重新生成时会把"整个工程根目录当源码"这种设置删掉, 只保留按文件夹加的源码目录,
  所以 **新建 .c 文件要放进这几个文件夹里**, 别放工程根目录 (放了不会被编译)。
- 新建文件夹要编译: Properties -> C/C++ General -> Paths and Symbols -> Source Location -> Add Folder。
- 重新生成前先关掉编辑器里打开的 `main.c` 等 CubeMX 文件, 生成完在工程上按 F5 刷新;
  不然编辑器里的旧内容一保存, 就会把 USER CODE 里的 `bsp_init()` / `Scheduler_Run()` 盖掉。
