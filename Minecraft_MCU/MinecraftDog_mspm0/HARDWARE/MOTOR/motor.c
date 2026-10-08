#include "motor.h"
#include "delay.h"

#ifndef AIN_AIN1_PORT
#define AIN_AIN1_PORT  AIN_PORT
#endif

#ifndef AIN_AIN2_PORT
#define AIN_AIN2_PORT  AIN_PORT
#endif

#ifndef BIN_BIN1_PORT
#define BIN_BIN1_PORT  BIN_PORT
#endif

#ifndef BIN_BIN2_PORT
#define BIN_BIN2_PORT  BIN_PORT
#endif

/* 电机锁: 0=关(默认, 强制停机), 1=开(允许 PWM_Control_Car 驱动) */
static uint8_t g_motor_lock = 0U;

static uint16_t Motor_Limit_PWM(uint16_t motor_speed)
{
    if (motor_speed > MAX_SPEED) {
        return MAX_SPEED;
    }

    return motor_speed;
}

static int16_t Motor_Ignore_Dead_Zone(int16_t speed)
{
    if (speed > 0) {
        return speed_limit(speed + MOTOR_DEAD_ZONE, -MAX_SPEED, MAX_SPEED);
    }

    if (speed < 0) {
        return speed_limit(speed - MOTOR_DEAD_ZONE, -MAX_SPEED, MAX_SPEED);
    }

    return 0;
}

static uint16_t Motor_Float_To_PWM(float speed)
{
    if (speed <= 0.0f) {
        return 0;
    }

    if (speed >= (float) MAX_SPEED) {
        return MAX_SPEED;
    }

    return (uint16_t) speed;
}

static void Motor_Set_PWM(uint16_t motor_speed, DL_TIMER_CC_INDEX cc_index)
{
    DL_TimerG_setCaptureCompareValue(PWM_0_INST, Motor_Limit_PWM(motor_speed),
        cc_index);
}

int myabs(int a)
{
    if (a < 0) {
        return -a;
    }

    return a;
}

int16_t speed_limit(int16_t speed, int16_t min, int16_t max)
{
    int16_t temp;

    if (min > max) {
        temp = min;
        min  = max;
        max  = temp;
    }

    if (speed == 0) {
        return 0;
    }

    if (speed < min) {
        return min;
    }

    if (speed > max) {
        return max;
    }

    return speed;
}

void Init_Motor_PWM(void)
{
    Motor_Stop(0);
    DL_TimerG_startCounter(PWM_0_INST);
}

void PWM_Control_Car(int16_t L_motor_speed, int16_t R_motor_speed)
{
    int16_t sl;
    int16_t sr;

    if (!g_motor_lock) {                    /* 电机锁关: 忽略请求速度, 强制停机 */
        L_control(0, MOTOR_DIR_FORWARD);
        R_control(0, MOTOR_DIR_FORWARD);
        return;
    }

    sl = speed_limit(L_motor_speed, -MAX_SPEED, MAX_SPEED);
    sr = speed_limit(R_motor_speed, -MAX_SPEED, MAX_SPEED);

    sl = Motor_Ignore_Dead_Zone(sl);
    sr = Motor_Ignore_Dead_Zone(sr);

    if (sl < 0) {
        L_control((uint16_t) myabs(sl), MOTOR_DIR_BACK);
    } else {
        L_control((uint16_t) sl, MOTOR_DIR_FORWARD);
    }

    if (sr < 0) {
        R_control((uint16_t) myabs(sr), MOTOR_DIR_BACK);
    } else {
        R_control((uint16_t) sr, MOTOR_DIR_FORWARD);
    }
}

void L_control(uint16_t motor_speed, uint8_t dir)
{
#if MOTOR_L_DIR_INVERT
    dir = (dir == MOTOR_DIR_FORWARD) ? MOTOR_DIR_BACK : MOTOR_DIR_FORWARD;
#endif
    motor_speed = Motor_Limit_PWM(motor_speed);

    if (motor_speed == 0) {
        DL_GPIO_clearPins(AIN_AIN1_PORT, AIN_AIN1_PIN);
        DL_GPIO_clearPins(AIN_AIN2_PORT, AIN_AIN2_PIN);
        Motor_Set_PWM(0, GPIO_PWM_0_C0_IDX);
        return;
    }

    if (dir == MOTOR_DIR_BACK) {
        DL_GPIO_setPins(AIN_AIN1_PORT, AIN_AIN1_PIN);
        DL_GPIO_clearPins(AIN_AIN2_PORT, AIN_AIN2_PIN);
    } else {
        DL_GPIO_clearPins(AIN_AIN1_PORT, AIN_AIN1_PIN);
        DL_GPIO_setPins(AIN_AIN2_PORT, AIN_AIN2_PIN);
    }

    Motor_Set_PWM(motor_speed, GPIO_PWM_0_C0_IDX);
}

void R_control(uint16_t motor_speed, uint8_t dir)
{
#if MOTOR_R_DIR_INVERT
    dir = (dir == MOTOR_DIR_FORWARD) ? MOTOR_DIR_BACK : MOTOR_DIR_FORWARD;
#endif
    motor_speed = Motor_Limit_PWM(motor_speed);

    if (motor_speed == 0) {
        DL_GPIO_clearPins(BIN_BIN1_PORT, BIN_BIN1_PIN);
        DL_GPIO_clearPins(BIN_BIN2_PORT, BIN_BIN2_PIN);
        Motor_Set_PWM(0, GPIO_PWM_0_C1_IDX);
        return;
    }

    if (dir == MOTOR_DIR_BACK) {
        DL_GPIO_setPins(BIN_BIN1_PORT, BIN_BIN1_PIN);
        DL_GPIO_clearPins(BIN_BIN2_PORT, BIN_BIN2_PIN);
    } else {
        DL_GPIO_clearPins(BIN_BIN1_PORT, BIN_BIN1_PIN);
        DL_GPIO_setPins(BIN_BIN2_PORT, BIN_BIN2_PIN);
    }

    Motor_Set_PWM(motor_speed, GPIO_PWM_0_C1_IDX);
}

void Motor_Stop(uint8_t brake)
{
    if (brake) {
        DL_GPIO_setPins(AIN_AIN1_PORT, AIN_AIN1_PIN);
        DL_GPIO_setPins(AIN_AIN2_PORT, AIN_AIN2_PIN);
        DL_GPIO_setPins(BIN_BIN1_PORT, BIN_BIN1_PIN);
        DL_GPIO_setPins(BIN_BIN2_PORT, BIN_BIN2_PIN);
        Motor_Set_PWM(MAX_SPEED, GPIO_PWM_0_C0_IDX);
        Motor_Set_PWM(MAX_SPEED, GPIO_PWM_0_C1_IDX);
    } else {
        Motor_Set_PWM(0, GPIO_PWM_0_C0_IDX);
        Motor_Set_PWM(0, GPIO_PWM_0_C1_IDX);
        DL_GPIO_clearPins(AIN_AIN1_PORT, AIN_AIN1_PIN);
        DL_GPIO_clearPins(AIN_AIN2_PORT, AIN_AIN2_PIN);
        DL_GPIO_clearPins(BIN_BIN1_PORT, BIN_BIN1_PIN);
        DL_GPIO_clearPins(BIN_BIN2_PORT, BIN_BIN2_PIN);
    }
}

void Motor_Lock_Set(uint8_t on)
{
    g_motor_lock = on ? 1U : 0U;
    if (!g_motor_lock) {
        Motor_Stop(0);      /* 关锁立即滑行停车 */
    }
}

uint8_t Motor_Lock_Get(void)
{
    return g_motor_lock;
}

void Motor_Run(float x, float y)
{
    L_control(Motor_Float_To_PWM(x), MOTOR_DIR_FORWARD);
    R_control(Motor_Float_To_PWM(y), MOTOR_DIR_FORWARD);
}

void Motor_Back(float x, float y)
{
    L_control(Motor_Float_To_PWM(x), MOTOR_DIR_BACK);
    R_control(Motor_Float_To_PWM(y), MOTOR_DIR_BACK);
}

void Motor_Left(float x, float y)
{
    L_control(Motor_Float_To_PWM(x), MOTOR_DIR_BACK);
    R_control(Motor_Float_To_PWM(y), MOTOR_DIR_FORWARD);
    delay_ms(500);
    Motor_Stop(1);
}

void Motor_Right(float x, float y)
{
    L_control(Motor_Float_To_PWM(x), MOTOR_DIR_FORWARD);
    R_control(Motor_Float_To_PWM(y), MOTOR_DIR_BACK);
    delay_ms(500);
    Motor_Stop(1);
}
