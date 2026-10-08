#include "motor.h"
#include "delay.h"
#include "tim.h"

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

/* TIM3: 72 MHz / (7999 + 1) = 9 kHz; 比较值 0 ~ 8000 = 占空比 0 ~ 100% */
static void Motor_Set_PWM(uint16_t motor_speed, uint32_t channel)
{
    __HAL_TIM_SET_COMPARE(&htim3, channel, Motor_Limit_PWM(motor_speed));
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
    HAL_TIM_PWM_Start(&htim3, MOTOR_L_PWM_CHANNEL);
    HAL_TIM_PWM_Start(&htim3, MOTOR_R_PWM_CHANNEL);
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
        HAL_GPIO_WritePin(AIN1_GPIO_Port, AIN1_Pin, GPIO_PIN_RESET);
        HAL_GPIO_WritePin(AIN2_GPIO_Port, AIN2_Pin, GPIO_PIN_RESET);
        Motor_Set_PWM(0, MOTOR_L_PWM_CHANNEL);
        return;
    }

    if (dir == MOTOR_DIR_BACK) {
        HAL_GPIO_WritePin(AIN1_GPIO_Port, AIN1_Pin, GPIO_PIN_SET);
        HAL_GPIO_WritePin(AIN2_GPIO_Port, AIN2_Pin, GPIO_PIN_RESET);
    } else {
        HAL_GPIO_WritePin(AIN1_GPIO_Port, AIN1_Pin, GPIO_PIN_RESET);
        HAL_GPIO_WritePin(AIN2_GPIO_Port, AIN2_Pin, GPIO_PIN_SET);
    }

    Motor_Set_PWM(motor_speed, MOTOR_L_PWM_CHANNEL);
}

void R_control(uint16_t motor_speed, uint8_t dir)
{
#if MOTOR_R_DIR_INVERT
    dir = (dir == MOTOR_DIR_FORWARD) ? MOTOR_DIR_BACK : MOTOR_DIR_FORWARD;
#endif
    motor_speed = Motor_Limit_PWM(motor_speed);

    if (motor_speed == 0) {
        HAL_GPIO_WritePin(BIN1_GPIO_Port, BIN1_Pin, GPIO_PIN_RESET);
        HAL_GPIO_WritePin(BIN2_GPIO_Port, BIN2_Pin, GPIO_PIN_RESET);
        Motor_Set_PWM(0, MOTOR_R_PWM_CHANNEL);
        return;
    }

    if (dir == MOTOR_DIR_BACK) {
        HAL_GPIO_WritePin(BIN1_GPIO_Port, BIN1_Pin, GPIO_PIN_SET);
        HAL_GPIO_WritePin(BIN2_GPIO_Port, BIN2_Pin, GPIO_PIN_RESET);
    } else {
        HAL_GPIO_WritePin(BIN1_GPIO_Port, BIN1_Pin, GPIO_PIN_RESET);
        HAL_GPIO_WritePin(BIN2_GPIO_Port, BIN2_Pin, GPIO_PIN_SET);
    }

    Motor_Set_PWM(motor_speed, MOTOR_R_PWM_CHANNEL);
}

void Motor_Stop(uint8_t brake)
{
    if (brake) {
        HAL_GPIO_WritePin(AIN1_GPIO_Port, AIN1_Pin, GPIO_PIN_SET);
        HAL_GPIO_WritePin(AIN2_GPIO_Port, AIN2_Pin, GPIO_PIN_SET);
        HAL_GPIO_WritePin(BIN1_GPIO_Port, BIN1_Pin, GPIO_PIN_SET);
        HAL_GPIO_WritePin(BIN2_GPIO_Port, BIN2_Pin, GPIO_PIN_SET);
        Motor_Set_PWM(MAX_SPEED, MOTOR_L_PWM_CHANNEL);
        Motor_Set_PWM(MAX_SPEED, MOTOR_R_PWM_CHANNEL);
    } else {
        Motor_Set_PWM(0, MOTOR_L_PWM_CHANNEL);
        Motor_Set_PWM(0, MOTOR_R_PWM_CHANNEL);
        HAL_GPIO_WritePin(AIN1_GPIO_Port, AIN1_Pin, GPIO_PIN_RESET);
        HAL_GPIO_WritePin(AIN2_GPIO_Port, AIN2_Pin, GPIO_PIN_RESET);
        HAL_GPIO_WritePin(BIN1_GPIO_Port, BIN1_Pin, GPIO_PIN_RESET);
        HAL_GPIO_WritePin(BIN2_GPIO_Port, BIN2_Pin, GPIO_PIN_RESET);
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
