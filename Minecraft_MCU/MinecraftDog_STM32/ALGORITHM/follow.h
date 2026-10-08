#ifndef __FOLLOW_H_
#define __FOLLOW_H_

#include <stdbool.h>
#include <stdint.h>

/* Follow distance and validity limits. */
#define FOLLOW_STOP_DISTANCE_CM       (300U)
#define FOLLOW_LOST_DISTANCE_CM       (2000U)

/* 20 ms control loop tuning. Values are motor PWM commands, not physical speed. */
#define FOLLOW_DISTANCE_KP_PWM_PER_CM (4)
#define FOLLOW_ANGLE_KP_PWM_PER_DEG   (35)
#define FOLLOW_MIN_FORWARD_PWM        (600)
#define FOLLOW_MAX_FORWARD_PWM        (6000)
#define FOLLOW_MAX_TURN_PWM           (3500)
#define FOLLOW_MAX_WHEEL_PWM          (6500)
#define FOLLOW_ACCEL_STEP_PWM         (200)
#define FOLLOW_DECEL_STEP_PWM         (400)
#define FOLLOW_PIVOT_ANGLE_DEG        (90)

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
