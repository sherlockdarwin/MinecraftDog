/* 正常模式不用它: 跟随 + 避障决策在 FPGA 做 (obstacle.md 第 6 节)。
 * 只有长按 KEY1 进入的【跟随测试模式】(follow_mode.c) 会调 Follow_Process。 */
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
static bool s_follow_pivoting = false;   /* 正在原地转 (角度回差用) */
static bool s_follow_pivot_pending = false;   /* 角度已经超过 90°, 在等 0.3 秒确认 */
static uint32_t s_follow_pivot_since = 0U;
static bool s_follow_angle_valid = false;
static int32_t s_follow_turn = 0;        /* 现在的转向量 (慢慢变到目标值) */
static int32_t s_follow_angle_x16 = 0;   /* 平滑后的角度 × 16 (多留 4 位小数) */

/* 角度平滑: 每次只跟上新角度的 1 / FOLLOW_ANGLE_FILTER; 刚收到 / 刚找回目标时直接用新值。 */
static int32_t Follow_FilterAngle(int16_t raw_deg)
{
    int32_t raw_x16 = (int32_t) raw_deg * 16;

    if (!s_follow_angle_valid) {
        s_follow_angle_x16   = raw_x16;
        s_follow_angle_valid = true;
    } else {
        s_follow_angle_x16 += (raw_x16 - s_follow_angle_x16) / FOLLOW_ANGLE_FILTER;
    }

    return s_follow_angle_x16 / 16;
}
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
    s_follow_turn          = 0;
    Motor_Lock_Set(0U);
}

void Follow_Init(void)
{
    g_follow_enabled       = 0U;
    s_follow_pivoting      = false;
    s_follow_pivot_pending = false;
    s_follow_angle_valid   = false;
    s_follow_turn          = 0;
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
    int32_t per10k;
    int16_t left_target;
    int16_t right_target;

    if (!UWB_GetTarget(now_ms, &target)) {
        s_follow_angle_valid = false;
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
    angle = Follow_FilterAngle(target.azimuth_deg);   /* 停着的时候也一直更新 */

    if (target.distance_cm > FOLLOW_LOST_DISTANCE_CM) {
        s_follow_angle_valid = false;
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

    angle_abs = Follow_Abs32(angle);

    /* 主人在侧面 / 后面: 原地转过去。超过 90° 要保持 0.3 秒才转 (角度偶尔跳一下不算),
     * 转到 40° 以内再往前走 (进出有回差, 免得在边上来回切)。 */
    if (!s_follow_pivoting) {
        if (angle_abs <= FOLLOW_PIVOT_ENTER_DEG) {
            s_follow_pivot_pending = false;
        } else if (!s_follow_pivot_pending) {
            s_follow_pivot_pending = true;
            s_follow_pivot_since   = now_ms;
        } else if ((uint32_t) (now_ms - s_follow_pivot_since) >= FOLLOW_PIVOT_CONFIRM_MS) {
            s_follow_pivoting = true;
        }
    } else if (angle_abs < FOLLOW_PIVOT_EXIT_DEG) {
        s_follow_pivoting      = false;
        s_follow_pivot_pending = false;
    }

    if (s_follow_pivoting) {
        forward       = 0;
        turn          = (angle > 0) ? FOLLOW_PIVOT_PWM : -FOLLOW_PIVOT_PWM;
        s_follow_turn = 0;      /* 转完往前走时, 转向从 0 慢慢加 */
    } else {
        distance_error = target.distance_cm - FOLLOW_STOP_DISTANCE_CM;
        forward = FOLLOW_START_PWM + (int32_t) distance_error * FOLLOW_DISTANCE_KP_PWM_PER_CM;
        if (forward > FOLLOW_MAX_FORWARD_PWM) {
            forward = FOLLOW_MAX_FORWARD_PWM;
        }

        /* 死区以内不拐; 超出的部分按前进的万分比转, 最多 FOLLOW_TURN_MAX_PER10K */
        turn = 0;
        if (angle_abs > FOLLOW_ANGLE_DEADBAND_DEG) {
            per10k = (angle_abs - FOLLOW_ANGLE_DEADBAND_DEG) * FOLLOW_TURN_PER10K_PER_DEG;
            if (per10k > FOLLOW_TURN_MAX_PER10K) {
                per10k = FOLLOW_TURN_MAX_PER10K;
            }
            turn = forward * per10k / 10000;
            if (angle < 0) {
                turn = -turn;
            }
        }

        /* 方向盘慢慢打: 每 20 ms 最多变 FOLLOW_TURN_STEP_PWM */
        if (turn > s_follow_turn + FOLLOW_TURN_STEP_PWM) {
            turn = s_follow_turn + FOLLOW_TURN_STEP_PWM;
        } else if (turn < s_follow_turn - FOLLOW_TURN_STEP_PWM) {
            turn = s_follow_turn - FOLLOW_TURN_STEP_PWM;
        }
        s_follow_turn = turn;
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
