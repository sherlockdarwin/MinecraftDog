/* 已停用: 跟随 + 避障决策改在 FPGA 做 (obstacle.md 第 6 节), task.c 不再调度
 * Follow_Process, bsp.c 不再调用 Follow_Init。代码保留备查。 */
#include "follow.h"

#include "motor.h"
#include "uwb.h"

volatile uint8_t g_follow_stop_flag = 0U;
volatile uint8_t g_follow_lost_flag = 1U;
volatile uint32_t g_follow_distance_cm = 0U;
volatile int16_t g_follow_azimuth_deg = 0;
volatile int16_t g_follow_left_command = 0;
volatile int16_t g_follow_right_command = 0;

static uint8_t g_follow_enabled = 0U;
static Follow_State g_follow_state = FOLLOW_STATE_DISABLED;

static int32_t Follow_Abs32(int32_t value)
{
    return (value < 0) ? -value : value;
}

static int16_t Follow_ClampCommand(int32_t command)
{
    if (command > FOLLOW_MAX_WHEEL_PWM) {
        return FOLLOW_MAX_WHEEL_PWM;
    }
    if (command < -FOLLOW_MAX_WHEEL_PWM) {
        return -FOLLOW_MAX_WHEEL_PWM;
    }
    return (int16_t) command;
}

static int16_t Follow_RampCommand(int16_t current, int16_t target)
{
    int32_t difference = (int32_t) target - current;
    int32_t step;

    if (difference == 0) {
        return target;
    }

    /* Reducing command magnitude may be faster than accelerating. */
    if (Follow_Abs32(target) < Follow_Abs32(current)) {
        step = FOLLOW_DECEL_STEP_PWM;
    } else {
        step = FOLLOW_ACCEL_STEP_PWM;
    }

    if (difference > step) {
        return (int16_t) (current + step);
    }
    if (difference < -step) {
        return (int16_t) (current - step);
    }
    return target;
}

static void Follow_StopImmediately(void)
{
    g_follow_left_command  = 0;
    g_follow_right_command = 0;
    Motor_Lock_Set(0U);
}

void Follow_Init(void)
{
    g_follow_enabled       = 0U;
    g_follow_state         = FOLLOW_STATE_DISABLED;
    g_follow_stop_flag     = 0U;
    g_follow_lost_flag     = 1U;
    g_follow_distance_cm   = 0U;
    g_follow_azimuth_deg   = 0;
    Follow_StopImmediately();
}

void Follow_Enable(uint8_t enable)
{
    g_follow_enabled = enable ? 1U : 0U;
    if (!g_follow_enabled) {
        g_follow_state = FOLLOW_STATE_DISABLED;
        Follow_StopImmediately();
    }
}

bool Follow_IsEnabled(void)
{
    return (g_follow_enabled != 0U);
}

Follow_State Follow_GetState(void)
{
    return g_follow_state;
}

void Follow_Process(uint32_t now_ms)
{
    UWB_Target target;
    uint32_t distance_error;
    int32_t angle;
    int32_t angle_abs;
    int32_t forward;
    int32_t turn;
    int16_t left_target;
    int16_t right_target;

    if (!UWB_GetTarget(now_ms, &target)) {
        g_follow_stop_flag   = 0U;
        g_follow_lost_flag   = 1U;
        g_follow_distance_cm = 0U;
        g_follow_azimuth_deg = 0;
        if (g_follow_enabled) {
            g_follow_state = FOLLOW_STATE_TARGET_LOST;
            Follow_StopImmediately();
        } else {
            g_follow_state = FOLLOW_STATE_DISABLED;
        }
        return;
    }

    g_follow_distance_cm = target.distance_cm;
    g_follow_azimuth_deg = target.azimuth_deg;

    if (target.distance_cm > FOLLOW_LOST_DISTANCE_CM) {
        g_follow_stop_flag = 0U;
        g_follow_lost_flag = 1U;
        if (g_follow_enabled) {
            g_follow_state = FOLLOW_STATE_TARGET_LOST;
            Follow_StopImmediately();
        } else {
            g_follow_state = FOLLOW_STATE_DISABLED;
        }
        return;
    }

    g_follow_lost_flag = 0U;

    if (target.distance_cm <= FOLLOW_STOP_DISTANCE_CM) {
        g_follow_stop_flag = 1U;
        if (g_follow_enabled) {
            g_follow_state = FOLLOW_STATE_STOPPED;
            Follow_StopImmediately();
        } else {
            g_follow_state = FOLLOW_STATE_DISABLED;
        }
        return;
    }

    g_follow_stop_flag = 0U;

    if (!g_follow_enabled) {
        g_follow_state = FOLLOW_STATE_DISABLED;
        return;
    }

    distance_error = target.distance_cm - FOLLOW_STOP_DISTANCE_CM;
    forward = (int32_t) distance_error * FOLLOW_DISTANCE_KP_PWM_PER_CM;
    if (forward < FOLLOW_MIN_FORWARD_PWM) {
        forward = FOLLOW_MIN_FORWARD_PWM;
    }
    if (forward > FOLLOW_MAX_FORWARD_PWM) {
        forward = FOLLOW_MAX_FORWARD_PWM;
    }

    angle = target.azimuth_deg;
    angle_abs = Follow_Abs32(angle);
    if (angle_abs > FOLLOW_PIVOT_ANGLE_DEG) {
        angle_abs = FOLLOW_PIVOT_ANGLE_DEG;
    }

    /* Slow the forward component as heading error grows; pivot at 90 degrees. */
    forward = (forward * (FOLLOW_PIVOT_ANGLE_DEG - angle_abs)) /
              FOLLOW_PIVOT_ANGLE_DEG;
    turn = angle * FOLLOW_ANGLE_KP_PWM_PER_DEG;
    if (turn > FOLLOW_MAX_TURN_PWM) {
        turn = FOLLOW_MAX_TURN_PWM;
    } else if (turn < -FOLLOW_MAX_TURN_PWM) {
        turn = -FOLLOW_MAX_TURN_PWM;
    }

    /* Positive azimuth means right: speed up left wheel and slow right wheel. */
    left_target  = Follow_ClampCommand(forward + turn);
    right_target = Follow_ClampCommand(forward - turn);

    g_follow_left_command = Follow_RampCommand(g_follow_left_command,
                                               left_target);
    g_follow_right_command = Follow_RampCommand(g_follow_right_command,
                                                right_target);

    g_follow_state = FOLLOW_STATE_RUNNING;
    Motor_Lock_Set(1U);
    PWM_Control_Car(g_follow_left_command, g_follow_right_command);
}
