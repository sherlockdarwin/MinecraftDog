#ifndef __STEPPER_H_
#define __STEPPER_H_

#include <stdbool.h>
#include <stdint.h>

/*
 * ZDT X42S 第二代闭环步进 (Emm 固件) —— 串口协议层。
 * 移植自 TI2026_H 的 HARDWARE/MOTOR_STEP/stepper.c, 字节格式和 ZDT 官方 STM32 例程
 * Emm_V5.c、《ZDT_X42S 用户手册 V1.0.5》第 5 章逐字节一致。
 *
 * USART1, 115200 8N1:  PA9  (TX) -> 驱动器 R/A/H 脚 (驱动器的串口收)
 *                      PA10 (RX) <- 驱动器的串口发 (只用来看应答, 不接也能用); GND 共地
 * 驱动器用出厂设置: P_Serial = UART_FUN, UartBaud = 115200, ID_Addr = 1, Checksum = 0x6B,
 * 细分 16 (1.8° 电机一圈 3200 脉冲)。
 *
 * 发: 阻塞发送, 一帧最长 13 字节 ≈ 1.1 ms。
 * 收: stm32f1xx_it.c 的 USART1 中断直接调 Stepper_IRQHandler() (不走 HAL),
 *     最近一条应答放在 g_stepper_reply[]: 地址 + 功能码 + 状态 + 0x6B,
 *     状态 02 = 命令收到, 9F = 动作做完, 12/22 = 回零时本来就在零点, E2 = 条件不满足
 *     (没使能 / 堵转保护 / 欠压等), EE = 格式错。
 */

#define STEPPER_DEFAULT_ADDR            (1U)
#define STEPPER_BROADCAST_ADDR          (0U)
#define STEPPER_CHECK_BYTE              (0x6BU)
#define STEPPER_DEFAULT_PULSES_PER_REV  (3200L)
#define STEPPER_REPLY_MAX               (8U)

typedef enum {
    STEPPER_DIR_CW  = 0U,
    STEPPER_DIR_CCW = 1U
} Stepper_Dir_t;

typedef enum {
    STEPPER_POS_REL_LAST_TARGET = 0U,
    STEPPER_POS_ABSOLUTE        = 1U,   /* 相对"坐标零点"的绝对位置, 正负由方向决定 (CW 为正) */
    STEPPER_POS_REL_CURRENT     = 2U
} Stepper_PosMode_t;

typedef enum {
    STEPPER_ORIGIN_NEAREST   = 0U,      /* 单圈就近回零: 转到存好的"单圈回零零点", 最多转半圈 */
    STEPPER_ORIGIN_DIR       = 1U,      /* 单圈方向回零 */
    STEPPER_ORIGIN_SENSELESS = 2U,      /* 多圈无限位碰撞回零 */
    STEPPER_ORIGIN_ENDSTOP   = 3U,      /* 多圈限位开关回零 */
    STEPPER_ORIGIN_ABS_ZERO  = 4U       /* 回到坐标零点 */
} Stepper_OriginMode_t;

/* ---- 驱动器应答 (调试时在 Live Expressions 里看) ---- */
extern volatile uint8_t  g_stepper_reply[STEPPER_REPLY_MAX];  /* 最近一条完整应答 */
extern volatile uint8_t  g_stepper_reply_len;
extern volatile uint32_t g_stepper_reply_count;                /* 累计收到的应答条数 */
extern volatile uint32_t g_stepper_tx_count;                   /* 累计发出的命令条数 */

void Stepper_Init(void);
void Stepper_IRQHandler(void);

uint8_t Stepper_SendArray(const uint8_t *arr, uint16_t len);

uint8_t Stepper_EnableEx(uint8_t addr, uint8_t enable, uint8_t sync);
uint8_t Stepper_SpeedEx(uint8_t addr, Stepper_Dir_t dir, uint16_t rpm, uint8_t acc, uint8_t sync);
uint8_t Stepper_PositionEx(uint8_t addr, Stepper_Dir_t dir, uint16_t rpm, uint8_t acc,
                           uint32_t pulses, Stepper_PosMode_t mode, uint8_t sync);
uint8_t Stepper_StopEx(uint8_t addr, uint8_t sync);
uint8_t Stepper_ResetCurrentPosition(uint8_t addr);            /* 当前位置设为坐标零点 */
uint8_t Stepper_ClearProtection(uint8_t addr);                 /* 解除堵转/过热/过流保护 */
uint8_t Stepper_SetOrigin(uint8_t addr, uint8_t save);         /* 当前位置设为单圈回零零点 */
uint8_t Stepper_TriggerOrigin(uint8_t addr, Stepper_OriginMode_t mode, uint8_t sync);

#endif /* __STEPPER_H_ */
