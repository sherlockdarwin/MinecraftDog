#ifndef __MOTOR_H_
#define __MOTOR_H_

#include <stdint.h>
#include "main.h"

#define MOTOR_DEAD_ZONE  (75)
#define MAX_SPEED        (8000)

/* A 路 = TIM3_CH1 (PA6) + AIN1/AIN2 (PB12/PB13), L_control() 控制它
 * B 路 = TIM3_CH2 (PA7) + BIN1/BIN2 (PB14/PB15), R_control() 控制它 */
#define MOTOR_L_PWM_CHANNEL  (TIM_CHANNEL_1)
#define MOTOR_R_PWM_CHANNEL  (TIM_CHANNEL_2)

/* 左右轮接反了就设 1: PWM_Control_Car(左, 右) 会把左轮命令给 B 路、右轮命令给 A 路。
 * 2026-10-21 上车实测: 屏幕显示主人在右 (UWB 角度对), 跟随时车却往左拐 -> A 路接的是右轮, 设 1。
 * 试电机 (两轮同速) 看不出这个问题, 只有拐弯时才看得出来。FPGA 发来的左右轮命令也经过这里。 */
#define MOTOR_SWAP_LR  (1U)

#define MOTOR_DIR_FORWARD  (0)
#define MOTOR_DIR_BACK     (1)

/* 方向极性 (按 A 路 / B 路算): 上板发现"该前进却后退"就把对应宏翻一下(仅翻转方向脚, 不动上层逻辑)。
 * 两个 1 是实测的值 (STM32 上 KEY1 试电机前进 / 后退都对)。 */
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
