#include "tail.h"

#include "main.h"
#include "stepper.h"

/* 动作表里的一步: 发哪条命令, 发完等多久再走下一步 */
typedef enum {
    TAIL_STEP_CLRPROT = 0,  /* 解除保护 */
    TAIL_STEP_ENABLE,       /* 使能 */
    TAIL_STEP_HOME,         /* 单圈就近回零 */
    TAIL_STEP_ZERO,         /* 当前位置设为坐标零点 */
    TAIL_STEP_LEFT,         /* 绝对位置: 左 TAIL_SWING_DEG */
    TAIL_STEP_CENTER,       /* 绝对位置: 0 */
    TAIL_STEP_RIGHT,        /* 绝对位置: 右 TAIL_SWING_DEG */
    TAIL_STEP_END
} Tail_Step;

static const Tail_Step s_home_steps[] = {
    TAIL_STEP_CLRPROT, TAIL_STEP_ENABLE, TAIL_STEP_HOME, TAIL_STEP_ZERO, TAIL_STEP_END,
};

static const Tail_Step s_wag_steps[] = {
    TAIL_STEP_ENABLE, TAIL_STEP_LEFT, TAIL_STEP_CENTER, TAIL_STEP_RIGHT, TAIL_STEP_CENTER,
    TAIL_STEP_END,
};

volatile Tail_State g_tail_state = TAIL_STATE_WAIT_BOOT;

static const Tail_Step *s_steps     = 0;
static uint8_t          s_step_idx  = 0U;
static uint32_t         s_wait_from = 0U;     /* 上一步发出的时刻 */
static uint32_t         s_wait_ms   = 0U;     /* 上一步发完要等多久 */

static Stepper_Dir_t Tail_LeftDir(void)
{
    return TAIL_LEFT_IS_CCW ? STEPPER_DIR_CCW : STEPPER_DIR_CW;
}

static Stepper_Dir_t Tail_RightDir(void)
{
    return TAIL_LEFT_IS_CCW ? STEPPER_DIR_CW : STEPPER_DIR_CCW;
}

/* 发一步对应的命令, 返回这一步之后要等的毫秒数 */
static uint32_t Tail_DoStep(Tail_Step step)
{
    switch (step) {
    case TAIL_STEP_CLRPROT:
        Stepper_ClearProtection(TAIL_ADDR);
        return TAIL_GAP_MS;

    case TAIL_STEP_ENABLE:
        Stepper_EnableEx(TAIL_ADDR, 1U, 0U);
        return TAIL_GAP_MS;

    case TAIL_STEP_HOME:
        Stepper_TriggerOrigin(TAIL_ADDR, STEPPER_ORIGIN_NEAREST, 0U);
        return TAIL_HOME_MS;

    case TAIL_STEP_ZERO:
        Stepper_ResetCurrentPosition(TAIL_ADDR);
        return TAIL_GAP_MS;

    case TAIL_STEP_LEFT:
        Stepper_PositionEx(TAIL_ADDR, Tail_LeftDir(), TAIL_RPM, TAIL_ACC,
                           TAIL_SWING_PULSES, STEPPER_POS_ABSOLUTE, 0U);
        return TAIL_MOVE_MS + TAIL_SIDE_PAUSE_MS;

    case TAIL_STEP_CENTER:
        Stepper_PositionEx(TAIL_ADDR, STEPPER_DIR_CW, TAIL_RPM, TAIL_ACC,
                           0U, STEPPER_POS_ABSOLUTE, 0U);
        return TAIL_MOVE_MS + TAIL_CENTER_PAUSE_MS;

    case TAIL_STEP_RIGHT:
        Stepper_PositionEx(TAIL_ADDR, Tail_RightDir(), TAIL_RPM, TAIL_ACC,
                           TAIL_SWING_PULSES, STEPPER_POS_ABSOLUTE, 0U);
        return TAIL_MOVE_MS + TAIL_SIDE_PAUSE_MS;

    default:
        return 0U;
    }
}

static void Tail_StartSequence(const Tail_Step *steps, Tail_State state, uint32_t now_ms)
{
    s_steps      = steps;
    s_step_idx   = 0U;
    s_wait_from  = now_ms;
    s_wait_ms    = 0U;        /* 第一步马上发 */
    g_tail_state = state;
}

void Tail_Init(void)
{
    s_steps      = 0;
    s_step_idx   = 0U;
    s_wait_from  = HAL_GetTick();
    s_wait_ms    = TAIL_INIT_MS;
    g_tail_state = TAIL_STATE_WAIT_BOOT;
}

void Tail_Process(uint32_t now_ms)
{
    Tail_Step step;

    if ((uint32_t) (now_ms - s_wait_from) < s_wait_ms) {
        return;
    }

    if (g_tail_state == TAIL_STATE_WAIT_BOOT) {
        Tail_StartSequence(s_home_steps, TAIL_STATE_HOMING, now_ms);
    }

    if ((g_tail_state != TAIL_STATE_HOMING) && (g_tail_state != TAIL_STATE_WAGGING)) {
        return;
    }

    step = s_steps[s_step_idx];
    if (step == TAIL_STEP_END) {
        g_tail_state = TAIL_STATE_IDLE;
        s_wait_ms    = 0U;
        return;
    }

    s_wait_ms   = Tail_DoStep(step);
    s_wait_from = now_ms;
    s_step_idx++;
}

bool Tail_Wag(void)
{
    if (g_tail_state != TAIL_STATE_IDLE) {
        return false;
    }

    Tail_StartSequence(s_wag_steps, TAIL_STATE_WAGGING, HAL_GetTick());
    return true;
}

bool Tail_IsHomed(void)
{
    return (g_tail_state == TAIL_STATE_IDLE) || (g_tail_state == TAIL_STATE_WAGGING);
}
