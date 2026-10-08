#ifndef __MOTOR_H_
#define __MOTOR_H_

#include <stdint.h>
#include "main.h"

#define MOTOR_DEAD_ZONE  (75)
#define MAX_SPEED        (8000)

/* 左轮 PWM = TIM3_CH1 (PA6) + AIN1/AIN2 (PB12/PB13)
 * 右轮 PWM = TIM3_CH2 (PA7) + BIN1/BIN2 (PB14/PB15) */
#define MOTOR_L_PWM_CHANNEL  (TIM_CHANNEL_1)
#define MOTOR_R_PWM_CHANNEL  (TIM_CHANNEL_2)

#define MOTOR_DIR_FORWARD  (0)
#define MOTOR_DIR_BACK     (1)

/* 方向极性: 上板发现"该前进却后退"就把对应宏翻一下(仅翻转方向脚, 不动上层逻辑)。
 * 两个 1 是 MSPM0 版本实测的值(左右都反了)。换到 STM32 后接线若有变化, 用 KEY1
 * (前进 3 秒) / KEY2 (后退 3 秒) 试一下, 哪边转反了改哪边 (见 task.c)。 */
#define MOTOR_L_DIR_INVERT  (1U)
#define MOTOR_R_DIR_INVERT  (1U)

int myabs(int a);
int16_t speed_limit(int16_t speed, int16_t min, int16_t max);
void Init_Motor_PWM(void);
void PWM_Control_Car(int16_t L_motor_speed, int16_t R_motor_speed);
void L_control(uint16_t motor_speed, uint8_t dir);
void R_control(uint16_t motor_speed, uint8_t dir);
void Motor_Stop(uint8_t brake);

void Motor_Lock_Set(uint8_t on);
uint8_t Motor_Lock_Get(void);

void Motor_Run(float x, float y);
void Motor_Right(float x, float y);
void Motor_Back(float x, float y);
void Motor_Left(float x, float y);

#endif
