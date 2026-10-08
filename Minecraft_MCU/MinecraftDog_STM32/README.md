## MinecraftDog STM32F103RCT6

MSPM0G3507 工程 (`../MinecraftDog_mspm0`) 移植到 STM32F103RCT6 (绿深 LVSN 板, 8 MHz 晶振, 72 MHz)。
跟随 + 避障决策都在 FPGA; STM32 只当传感器 (UWB) 和电机驱动。协议见 `obstacle.md` 第 5 节。

### 目录 (和 MSPM0 版一样, 只是 task.c / task.h 挪进了 SYSTEM, 原因见最后一节)

| 位置 | 内容 |
| --- | --- |
| `Core/` `Drivers/` | CubeMX 生成。`main.c` 只在 USER CODE 里调 `bsp_init()` / `Scheduler_Run()` |
| `SYSTEM/` | `AllHeader.h`、`bsp.c`(模块初始化)、`delay.c`(SysTick 微秒延时 + 秒表)、`task.c`(协作式调度表, 1 ms 时基 = `HAL_GetTick()`) |
| `HARDWARE/MLK/` | FPGA 串口 (USART3, DMA 收发), 解包变量在 `fpgamlk.c` 顶部 |
| `HARDWARE/UWB/` | 三个 UWB 基站 (USART2 / UART4 / UART5, 接收中断) |
| `HARDWARE/MOTOR/` | 电机 PWM + 方向、编码器 |
| `HARDWARE/KEY/` | KEY1 / KEY2 |
| `ALGORITHM/` | 本地跟随 `follow.c`, 已停用, 保留备查 |

OLED 没移植 (STM32 版没留 OLED 引脚)。

### 引脚

| 功能 | 引脚 | 外设 |
| --- | --- | --- |
| FPGA | PB10 TX -> FPGA CEP 脚 4; PB11 RX <- CEP 脚 3; GND 接 CEP 脚 2 | USART3, RX DMA1 CH3 (Circular), TX DMA1 CH2 |
| UWB 左 / 前 / 右 | PA3 / PC11 / PD2 收 (PA2 / PC10 / PC12 发, 预留) | USART2 / UART4 / UART5, 接收中断 |
| 左 / 右轮 PWM | PA6 / PA7 | TIM3 CH1 / CH2, 9 kHz, 0~8000 |
| AIN1 AIN2 BIN1 BIN2 | PB12 PB13 PB14 PB15 | GPIO 输出 |
| 左编码器 A / B | PC6 / PC7 | TIM8 编码器 |
| 右编码器 A / B | PA15 / PB3 | TIM2 编码器 (部分重映射, 要 SYS = Serial Wire) |
| KEY1 / KEY2 | PC9 / PC8 | 输入上拉, 按下 = 低 |
| LED | PA8 | GPIO_Output, Label = `LED` (没有这个 Label 时 `Task_LED` 什么也不做) |
| SWD | PA13 / PA14 | |

### 任务

| 任务 | 周期 | 做什么 |
| --- | --- | --- |
| `Task_UWB_Poll` | 5 ms | 解析 UWB 帧 |
| `Task_FPGA_Rx` | 5 ms | 解 FPGA 帧 (`#+3000-0500*` / `#S*`); 串口出错时重启接收 DMA |
| `Task_Motor_Drive` | 5 ms | 按 FPGA 命令驱动电机; UWB 丢 / 200 ms 没帧 / `#S*` 立即停车; 按键试电机 |
| `Task_FPGA_Tx` | 20 ms | 新 UWB 数据发 `$l12350&`, 收不到 UWB 发 `$S&` (100 ms 重发) |
| `Task_Key_Scan` | 10 ms | 按键消抖 |
| `Task_LED` | 100 ms | 和 FPGA 链路通 = 1 秒闪一次, 不通 = 快闪 |

**试电机方向** (不用接 FPGA): KEY1 = 两轮 +3000 前进 3 秒, KEY2 = 两轮 -3000 后退 3 秒, 测试中再按任一键停。
哪个轮子转反了, 改 `motor.h` 的 `MOTOR_L_DIR_INVERT` / `MOTOR_R_DIR_INVERT`。

### CubeMX 里不能改掉的设置 (改了不报错, 只会静默不工作)

- USART3_RX DMA Mode = **Circular**; USART3 global interrupt **打开** (DMA 发送靠它结束, 串口出错也靠它报告)。
- USART2 / UART4 / UART5 global interrupt 打开。它们的中断在 `stm32f1xx_it.c` 的 USER CODE 0 里直接调
  `UWB_IRQHandler()` 后 `return`, 不走 HAL。
- TIM3 Period = 7999 (PWM 满量程 8000, 和 FPGA 发来的命令同一个刻度)。
- 重新生成代码时 Project Manager 里要保持 "Keep User Code when re-generating"。

### 工程设置 (CubeMX 重新生成后还在, 已实测)

- `.cproject` 的源码目录: `Core` `Drivers` (CubeMX 自带) + `ALGORITHM` `HARDWARE` `SYSTEM`。
- include 路径: `../` `../SYSTEM` `../HARDWARE` `../HARDWARE/MOTOR` `../HARDWARE/UWB`。
- CubeMX 重新生成时会把"整个工程根目录当源码"这种设置删掉, 只保留按文件夹加的源码目录,
  所以 **新建 .c 文件要放进这几个文件夹里**, 别放工程根目录 (放了不会被编译)。
- 新建文件夹要编译: Properties -> C/C++ General -> Paths and Symbols -> Source Location -> Add Folder。
- 重新生成前先关掉编辑器里打开的 `main.c` 等 CubeMX 文件, 生成完在工程上按 F5 刷新;
  不然编辑器里的旧内容一保存, 就会把 USER CODE 里的 `bsp_init()` / `Scheduler_Run()` 盖掉。
