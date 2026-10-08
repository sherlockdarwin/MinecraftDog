#ifndef __FPGAMLK_H_
#define __FPGAMLK_H_

/*
 * fpgamlk —— 和 FPGA(米联客 PH1P35)的串口通讯, 协议见 obstacle.md 第 5 节。
 *
 * USART3, 115200 8N1:  PB11 = RX (接 CEP 脚 3, FPGA 发)
 *                      PB10 = TX (接 CEP 脚 4, FPGA 收), GND 接 CEP 脚 2
 * 收、发都走 DMA:
 *   收: DMA1 通道 3 (Circular) 把字节搬进 256 字节环形缓冲, FPGAMLK_Poll() 解包;
 *   发: DMA1 通道 2 (Normal) 一次搬一整帧。
 *
 * STM32 -> FPGA:  "$l12350&" = 主人在左 12°、350 cm ('l' 左 / 'r' 右, 角度 2 位, 距离 3 位)
 *                 "$S&"      = 收不到 UWB
 * FPGA -> STM32:  "#+3000-0500*" = 左轮 +3000、右轮 -500 (就是 PWM_Control_Car 的参数)
 *                 "#S*"          = 马上停车
 */

#include <stdbool.h>
#include <stdint.h>

#define FPGAMLK_LINK_TIMEOUT_MS  (200U)   /* 超过这么久没收到完整的 #...* 帧 = 链路断了, 停车 */
#define FPGAMLK_LOST_RESEND_MS   (100U)   /* UWB 丢失期间 "$S&" 的重发间隔 */
#define FPGAMLK_PWM_LIMIT        (8000)   /* 轮子命令满量程, 和 motor.h 的 MAX_SPEED 一致 */
#define FPGAMLK_ANGLE_MAX_DEG    (99U)    /* 协议里角度只有 2 位 */
#define FPGAMLK_DIST_MAX_CM      (999U)   /* 协议里距离只有 3 位 */

/* ---- FPGA -> STM32 解包结果 (定义和说明在 fpgamlk.c 顶部) ---- */
extern volatile int16_t  g_fpga_left_pwm;
extern volatile int16_t  g_fpga_right_pwm;
extern volatile uint8_t  g_fpga_stop;
extern volatile uint8_t  g_fpga_new_frame;
extern volatile uint32_t g_fpga_last_ms;
extern volatile uint32_t g_fpga_frame_count;
extern volatile uint32_t g_fpga_error_count;
extern volatile uint32_t g_fpga_uart_error_count;

/* ---- STM32 -> FPGA 最近发出去的内容 ---- */
extern volatile uint8_t  g_fpga_uwb_lost;
extern volatile int16_t  g_fpga_tx_angle_deg;
extern volatile uint16_t g_fpga_tx_distance_cm;
extern volatile uint32_t g_fpga_tx_count;

void FPGAMLK_Init(void);

/* 把 DMA 已经收进环形缓冲的字节解包, 更新上面的 g_fpga_* 变量。
 * 挂在 task.c 调度表上 5 ms 一次; 周期别调大(见 fpgamlk.c 的缓冲说明)。 */
void FPGAMLK_Poll(uint32_t now_ms);

/* 有新的完整帧(#...* 或 #S*)返回 true 并清 g_fpga_new_frame。 */
bool FPGAMLK_TakeUpdate(void);

/* 200 ms 内收到过完整帧返回 true。 */
bool FPGAMLK_LinkAlive(uint32_t now_ms);

/* 上一帧还在发(USART3 不是 READY)返回 true; 这时 Send 系列直接返回 false。 */
bool FPGAMLK_TxBusy(void);

/* 发 "$l12350&": azimuth_deg 左负右正(超过 99 发 99), distance_cm 超过 999 发 999。 */
bool FPGAMLK_SendTarget(int16_t azimuth_deg, uint32_t distance_cm);

/* 发 "$S&"。 */
bool FPGAMLK_SendLost(void);

#endif
