#ifndef __FOLLOW_H_
#define __FOLLOW_H_

#include <stdbool.h>
#include <stdint.h>

/* Follow distance and validity limits. */
#define FOLLOW_STOP_DISTANCE_CM       (300U)
#define FOLLOW_LOST_DISTANCE_CM       (2000U)

/* 20 ms 一次, 数值都是轮子 PWM 命令 (满量程 8000), 按 1 kg 左右的车调:
 *   角度先平滑 (每次只跟上新角度的 1/FOLLOW_ANGLE_FILTER), 去掉 UWB 角度的抖动;
 *   前进 = 起步值 + (距离 - 停车距离) × 系数, 最多 FOLLOW_MAX_FORWARD_PWM;
 *   角度在 ±FOLLOW_ANGLE_DEADBAND_DEG 以内当正前方, 不拐 (人站在前面总会偏一点);
 *   超出的部分才转向, 转向按前进的万分比算 (弯的急缓和车速无关):
 *       转向 = 前进 × min((角度 - 死区) × FOLLOW_TURN_PER10K_PER_DEG, FOLLOW_TURN_MAX_PER10K) / 10000,
 *       而且每 20 ms 最多变 FOLLOW_TURN_STEP_PWM, 方向盘慢慢打、慢慢回;
 *   角度超过 FOLLOW_PIVOT_ENTER_DEG 并保持 FOLLOW_PIVOT_CONFIRM_MS 才原地转 (UWB 角度偶尔跳一下不会转),
 *   转到 FOLLOW_PIVOT_EXIT_DEG 以内再往前走。
 * 调参记录: MSPM0 原参数 (起步 600、转向 × 35) 推不动、原地打转 -> 10-20 起步 2200、转向 × 40、
 *   死区 5°: 能走了但拐弯太快、左右摆头 -> 10-21 死区 15°、转向最多 30%: 还是弯太急, 1 米宽走廊
 *   来不及回正就撞墙 -> 10-21 死区 15°、0.4%/度、最多 10%: 先直走, 偏到 15° 以外才猛打方向
 *   -> 10-21 早一点开始拐 (5°), 但拐得轻 (0.2%/度, 最多 6%), 方向盘打得更慢: 好多了, 但偶尔突然原地转
 *   -> 10-21 原地转 75° 改成 90°, 并且要保持 0.3 秒
 *   -> 10-21 修好 UWB 左右不分以后转向有点不灵敏: 0.25%/度、最多 8%, 起步 3000
 *   -> 10-21 (自己调) 距离系数 10、平滑 1/3、0.3%/度: 不大转弯了, 但有点过于谨慎
 *   -> 10-21 方向盘每 20 ms 最多变 15 (原来 10)、转向最多 10% (原来 8%): 摇摆明显、又有突变
 *   -> 10-21 取中间: 每 20 ms 最多变 12、最多 9%。 */
#define FOLLOW_START_PWM              (3000)   /* 起步: 600 推不动, 2500 能走 */
#define FOLLOW_DISTANCE_KP_PWM_PER_CM (10)     /* 每远 1 cm 多加多少 */
#define FOLLOW_MAX_FORWARD_PWM        (5000)
#define FOLLOW_ANGLE_FILTER           (3)      /* 角度平滑: 越大越稳、反应越慢 (3 ≈ 50 ms) */
#define FOLLOW_ANGLE_DEADBAND_DEG     (5)      /* ±5° 以内当正前方 (只滤掉 UWB 抖动) */
#define FOLLOW_TURN_PER10K_PER_DEG    (30)     /* 超出死区每 1°, 转向加前进的 0.3% (单位 0.01%) */
#define FOLLOW_TURN_MAX_PER10K        (900)    /* 转向最多 = 前进的 9% */
#define FOLLOW_TURN_STEP_PWM          (12)     /* 转向每 20 ms 最多变 12 (1 秒最多变 600) */
#define FOLLOW_PIVOT_ENTER_DEG        (90)     /* 偏超过 90° (人在侧面 / 后面) 才原地转 */
#define FOLLOW_PIVOT_CONFIRM_MS       (300U)   /* 而且要一直超过 0.3 秒 */
#define FOLLOW_PIVOT_EXIT_DEG         (40)
#define FOLLOW_PIVOT_PWM              (2200)   /* 原地转时两轮一正一反 */
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
