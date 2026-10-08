## MinecraftDog STM32F103RCT6

### 功能

跟随 + 避障的决策全在 FPGA, STM32 只做传感器和电机驱动:

1. **UWB 定位**: 三个基站(左 / 前 / 右)各接一个串口, 中断收字节, 解 0x2001 定位帧(37 字节, XOR 校验)。
   取角度最靠近自己正前方的那个基站, 换算成车体坐标(左负右正)的角度 + 距离; 500 ms 没新数据 = 收不到 UWB。
2. **发给 FPGA**: 有新 UWB 数据就用 DMA 发主人的角度、距离; 收不到 UWB 就发"丢失"。
3. **收 FPGA 的命令**: DMA 环形缓冲收两个轮子的 PWM, 解包后驱动电机。
4. **停车保护**: 收不到 UWB / 200 ms 没收到完整的 FPGA 帧 / FPGA 发来停车, 任何一条成立就关电机锁停车。
5. **电机驱动**: 两路 PWM(9 kHz, 0~8000) + 4 个方向脚, 带死区补偿和方向极性开关。
6. **编码器**: TIM8 / TIM2 硬件计数, 速度和里程函数都在 `encoder.c`, 现在控制里没用到。
7. **按键试电机**: KEY1 前进 3 秒、KEY2 后退 3 秒, 不用接 FPGA。
8. **LED**: 和 FPGA 通 = 1 秒闪一次, 不通 = 快闪。

### 目录

| 位置                   | 内容                                                                                                                                  |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| `Core/` `Drivers/` | CubeMX 生成。`main.c` 只在 USER CODE 里调 `bsp_init()` / `Scheduler_Run()`                                                      |
| `SYSTEM/`            | `AllHeader.h`、`bsp.c`(模块初始化)、`delay.c`(SysTick 微秒延时 + 秒表)、`task.c`(协作式调度表, 1 ms 时基 = `HAL_GetTick()`) |
| `HARDWARE/MLK/`      | FPGA 串口 (USART3, DMA 收发), 解包变量在`fpgamlk.c` 顶部                                                                            |
| `HARDWARE/UWB/`      | 三个 UWB 基站 (USART2 / UART4 / UART5, 接收中断)                                                                                      |
| `HARDWARE/MOTOR/`    | 电机 PWM + 方向、编码器                                                                                                               |
| `HARDWARE/KEY/`      | KEY1 / KEY2                                                                                                                           |
| `ALGORITHM/`         | 本地跟随`follow.c`, 已停用, 保留备查                                                                                                |

OLED 没移植 (STM32 版没留 OLED 引脚)。

### 引脚

| 功能                | 引脚                                                           | 外设                                                                    |
| ------------------- | -------------------------------------------------------------- | ----------------------------------------------------------------------- |
| FPGA                | PB10 TX -> FPGA CEP 脚 4; PB11 RX <- CEP 脚 3; GND 接 CEP 脚 2 | USART3, RX DMA1 CH3 (Circular), TX DMA1 CH2                             |
| UWB 左 / 前 / 右    | PA3 / PC11 / PD2 收 (PA2 / PC10 / PC12 发, 预留)               | USART2 / UART4 / UART5, 接收中断                                        |
| 左 / 右轮 PWM       | PA6 / PA7                                                      | TIM3 CH1 / CH2, 9 kHz, 0~8000                                           |
| AIN1 AIN2 BIN1 BIN2 | PB12 PB13 PB14 PB15                                            | GPIO 输出                                                               |
| 左编码器 A / B      | PC6 / PC7                                                      | TIM8 编码器                                                             |
| 右编码器 A / B      | PA15 / PB3                                                     | TIM2 编码器 (部分重映射, 要 SYS = Serial Wire)                          |
| KEY1 / KEY2         | PC9 / PC8                                                      | 输入上拉, 按下 = 低                                                     |
| LED                 | PA8                                                            | GPIO_Output, Label =`LED` (没有这个 Label 时 `Task_LED` 什么也不做) |
| SWD                 | PA13 / PA14                                                    |                                                                         |

### 任务

| 任务                 | 周期   | 做什么                                                                   |
| -------------------- | ------ | ------------------------------------------------------------------------ |
| `Task_UWB_Poll`    | 5 ms   | 解析 UWB 帧                                                              |
| `Task_FPGA_Rx`     | 5 ms   | 解 FPGA 帧 (`#+3000-0500*` / `#S*`); 串口出错时重启接收 DMA          |
| `Task_Motor_Drive` | 5 ms   | 按 FPGA 命令驱动电机; UWB 丢 / 200 ms 没帧 /`#S*` 立即停车; 按键试电机 |
| `Task_FPGA_Tx`     | 20 ms  | 新 UWB 数据发`$l12350&`, 收不到 UWB 发 `$S&` (100 ms 重发)           |
| `Task_Key_Scan`    | 10 ms  | 按键消抖                                                                 |
| `Task_LED`         | 100 ms | 和 FPGA 链路通 = 1 秒闪一次, 不通 = 快闪                                 |

**试电机方向** (不用接 FPGA): KEY1 = 两轮 +3000 前进 3 秒, KEY2 = 两轮 -3000 后退 3 秒, 测试中再按任一键停。
哪个轮子转反了, 改 `motor.h` 的 `MOTOR_L_DIR_INVERT` / `MOTOR_R_DIR_INVERT`。

### 和 FPGA 的通讯协议

UART 115200 8N1, ASCII, **位数不够前面补 0**。
接线: FPGA CEP 脚 3 (FPGA 发) -> **PB11**; **PB10** -> CEP 脚 4 (FPGA 收); GND 接 CEP 脚 2。

| 方向          | 帧                                                                                                                                                                               | 含义                                                                                                                     | 什么时候发                       |
| ------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ | -------------------------------- |
| STM32 -> FPGA | `$` + `l`/`r` + 角度 2 位 + 距离 3 位 + `&` | 主人在左(`l`) / 右(`r`) 多少度、多远(cm)。例`$r00150&` = 正前方、150 cm。角度超过 99° 发 99, 距离超过 999 cm 发 999 | 每次有新 UWB 数据(最快 20 ms 一帧)                                                                                       |                                  |
| STM32 -> FPGA | `$S&`                                                                                                                                                                          | 收不到 UWB                                                                                                               | 刚丢时立刻发, 之后每 100 ms 一帧 |
| FPGA -> STM32 | `#` + 左轮(符号 + 4 位) + 右轮(符号 + 4 位) + `*`                                                                                                                            | 两个轮子的 PWM, 正 = 前进, 满量程 8000 (就是`PWM_Control_Car(左, 右)` 的参数)。例 `#+3000-0500*` = 左 +3000、右 -500 | FPGA 每 20 ms 一帧               |
| FPGA -> STM32 | `#S*`                                                                                                                                                                          | 马上停车                                                                                                                 | 停车期间每 20 ms 一帧            |

- 超时: FPGA 那边 300 ms 收不到 `$…&` 就当 UWB 丢了; STM32 这边 200 ms 收不到完整的 `#…*` 就停车。
- 解包规则 (`fpgamlk.c`): 收到 `#` 就重新开始一帧, 帧外的字节丢掉; `S` 大小写都行;
  格式不对的整帧丢掉 (计数在 `g_fpga_error_count`); 超过 ±8000 的按 ±8000 算。
- 解包结果 (`fpgamlk.c` 顶部, 调试时在 Live Expressions 里看):

- [ ] 变量含义`g_fpga_left_pwm` / `g_fpga_right_pwm`最近一帧的左 / 右轮命令`g_fpga_stop`1 = 最近一帧是`#S*` (上电还没收到帧时也是 1)`g_fpga_last_ms` / `g_fpga_frame_count`最近一帧的时刻 / 累计帧数`g_fpga_error_count` / `g_fpga_uart_error_count`格式错的帧数 / 串口硬件错误次数 (每次都会自动重启接收)`g_fpga_uwb_lost` / `g_fpga_tx_angle_deg` / `g_fpga_tx_distance_cm` / `g_fpga_tx_count`最近发给 FPGA 的内容和累计发出的帧数

### CubeMX 里不能改掉的设置

- USART3_RX DMA Mode = **Circular**; USART3 global interrupt **打开** (DMA 发送靠它结束, 串口出错也靠它报告)。
- USART2 / UART4 / UART5 global interrupt 打开。它们的中断在 `stm32f1xx_it.c` 的 USER CODE 0 里直接调
  `UWB_IRQHandler()` 后 `return`, 不走 HAL。
- TIM3 Period = 7999 (PWM 满量程 8000, 和 FPGA 发来的命令同一个刻度)。
- 重新生成代码时 Project Manager 里要保持 "Keep User Code when re-generating"。

### 工程设置 (CubeMX 重新生成后还在)

- `.cproject` 的源码目录: `Core` `Drivers` (CubeMX 自带) + `ALGORITHM` `HARDWARE` `SYSTEM`。
- include 路径: `../` `../SYSTEM` `../HARDWARE` `../HARDWARE/MOTOR` `../HARDWARE/UWB`。
- CubeMX 重新生成时会把"整个工程根目录当源码"这种设置删掉, 只保留按文件夹加的源码目录,
  所以 **新建 .c 文件要放进这几个文件夹里**, 别放工程根目录 (放了不会被编译)。
- 新建文件夹要编译: Properties -> C/C++ General -> Paths and Symbols -> Source Location -> Add Folder。
- 重新生成前先关掉编辑器里打开的 `main.c` 等 CubeMX 文件, 生成完在工程上按 F5 刷新;
  不然编辑器里的旧内容一保存, 就会把 USER CODE 里的 `bsp_init()` / `Scheduler_Run()` 盖掉。
