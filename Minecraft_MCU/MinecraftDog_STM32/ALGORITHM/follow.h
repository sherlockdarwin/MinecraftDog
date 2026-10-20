#ifndef __FOLLOW_H_
#define __FOLLOW_H_

#include <stdbool.h>
#include <stdint.h>

/* Follow distance and validity limits. */
#define FOLLOW_STOP_DISTANCE_CM       (300U)
#define FOLLOW_LOST_DISTANCE_CM       (2000U)

/* 20 ms 一次, 数值都是轮子 PWM 命令 (满量程 8000), 按 1 kg 左右的车调 (2026-10-20 上车后改):
 *   前进 = 起步值 + (距离 - 停车距离) × 系数, 最多 FOLLOW_MAX_FORWARD_PWM;
 *   转向 = 角度 × 系数, 但最多占前进的 FOLLOW_TURN_RATIO_PERCENT, 内侧轮不会停;
 *   角度在 ±FOLLOW_ANGLE_DEADBAND_DEG 以内当正前方 (UWB 角度会抖几度);
 *   角度超过 FOLLOW_PIVOT_ENTER_DEG 原地转, 转到 FOLLOW_PIVOT_EXIT_DEG 以内再往前走。
 * 原来的 MSPM0 参数 (起步 600、转向 × 35) 上车实测推不动、一直原地打转。 */
#define FOLLOW_START_PWM              (2200)   /* 起步: 试电机用的 3000 跑得顺, 600 推不动 */
#define FOLLOW_DISTANCE_KP_PWM_PER_CM (8)      /* 每远 1 cm 多加多少 */
#define FOLLOW_MAX_FORWARD_PWM        (5000)
#define FOLLOW_ANGLE_DEADBAND_DEG     (5)
#define FOLLOW_ANGLE_KP_PWM_PER_DEG   (40)
#define FOLLOW_TURN_RATIO_PERCENT     (50)     /* 转向最多 = 前进 × 50%: 内侧轮至少还有一半 */
#define FOLLOW_PIVOT_ENTER_DEG        (45)
#define FOLLOW_PIVOT_EXIT_DEG         (25)
#define FOLLOW_PIVOT_PWM              (2800)   /* 原地转时两轮一正一反 */
#define FOLLOW_MAX_WHEEL_PWM          (6500)
#define FOLLOW_ACCEL_STEP_PWM         (200)
#define FOLLOW_DECEL_STEP_PWM         (400)

typedef enum {
    FOLLOW_STATE_DISABLED = 0,
    FOLLOW_STATE_TARGET_LOST,
    FOLLOW_STATE_STOPPED,
    FOLLOW_STATE_RUNNING
} Follow_State;

/*
 * These two condition flags are intentionally public for later FPGA exchange:
 *   g_follow_stop_flag = 1: a valid target is at or inside 3 m.
 *   g_follow_lost_flag = 1: no fresh target exists, or distance is over 20 m.
 */
extern volatile uint8_t g_follow_stop_flag;
extern volatile uint8_t g_follow_lost_flag;

/* Runtime values are also public to make CCS watch/debug straightforward. */
extern volatile uint32_t g_follow_distance_cm;
extern volatile int16_t g_follow_azimuth_deg;
extern volatile int16_t g_follow_left_command;
extern volatile int16_t g_follow_right_command;

void Follow_Init(void);
void Follow_Enable(uint8_t enable);
bool Follow_IsEnabled(void);
Follow_State Follow_GetState(void);
void Follow_Process(uint32_t now_ms);

#endif
