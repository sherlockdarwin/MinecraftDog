#ifndef __ENCODER_H_
#define __ENCODER_H_

#include <stdint.h>
#include "main.h"

/* Raw encoder signs for forward travel. Calibrate these before closing a
 * speed loop; keeping them here makes the driver independent of any future
 * motor-control algorithm module. */
#ifndef ENCODER_LEFT_FORWARD_SIGN
#define ENCODER_LEFT_FORWARD_SIGN   (1)
#endif

#ifndef ENCODER_RIGHT_FORWARD_SIGN
#define ENCODER_RIGHT_FORWARD_SIGN  (-1)
#endif

/* 左轮 = TIM8 编码器 (E1A PC6 / E1B PC7), 右轮 = TIM2 编码器 (E2A PA15 / E2B PB3)。
 * 两路都是 TI1+TI2 四倍频, 和 MSPM0 版"A、B 两相双边沿中断"计数一样。 */

typedef enum {
    FORWARD,  // 正向
    REVERSAL  // 反向
} ENCODER_DIR;

typedef struct {
    volatile long long temp_count; //保存实时计数值
    int count;                     //根据定时器时间更新的计数值
    ENCODER_DIR dir;               //旋转方向
    int ALLcount;                  //开机到现在总的编码器计数
} ENCODER_RES;

void encoder_init(void);
ENCODER_DIR get_encoderL_dir(void);
ENCODER_DIR get_encoderR_dir(void);

void Encoder_Get_ALL(int *Encoder_all);
void Encoder_Get_Temp(int *Encoder_temp);
void encoder_update(void);

/* 速度采样: 调一次 = 采一次编码器"本采样周期计数"(= 车轮转速的度量, 带符号),
 * 存到 g_speed_left / g_speed_right。周期越长数值越大(count/周期)。
 * ⚠ 只能有一个周期调用者: 200ms 显示任务 或 速度环 MotorPID_Run(), 别同时两处调,
 *   否则各清走一半计数。 */
extern volatile int g_speed_left;
extern volatile int g_speed_right;
void Encoder_Speed_Sample(void);

/* ==========================================================================
 * 里程计 (mode_3 判"走满 1.5m 到 B 点"用)
 *
 * 累加动作藏在 encoder_update() 里, 所以只要有人在周期调用 encoder_update()
 * (Encoder_Odom_Update / Encoder_Speed_Sample / MotorPID_Run 都算), 里程就会走。
 * ⚠ 仍然只能有一个周期调用者, 否则各清走一半计数(和速度采样是同一个约束)。
 *
 * ★ 标定 encoder_counts_per_meter (必做, 默认 3800 是猜的) ★
 *   0. 【先】垫车定好 motor_pid_enc_sign_l/r —— 里程和速度环共用这两个符号,
 *      符号不对时里程会算错(左右符号相反时两边直接抵消, 里程恒为 0)。
 *   1. 上电后调 Encoder_Odom_Reset()
 *   2. 让车直线走整 1.000 米(手推也行, 但要保持两轮都转)
 *   3. 读 Encoder_Odom_GetCount(), 填进 encoder_counts_per_meter
 *   符号定对之后前进读数应当是【正】的; 若读出负数, 说明两个 enc_sign 一起反了,
 *   把它们都翻一下比在这里填负值更好(速度环也要靠它们)。
 * ========================================================================== */
extern float encoder_counts_per_meter;   /* 走 1 米对应的编码器计数(左右平均, 前进为正) */

void  Encoder_Odom_Reset(void);          /* 里程清零(起跑那一刻调) */
void  Encoder_Odom_Update(void);         /* 周期调用(建议 20ms), 采样并累积 */
long  Encoder_Odom_GetCount(void);       /* 原始累计计数(左右平均), 标定看这个 */
float Encoder_Odom_GetM(void);           /* 已走距离(米) */

#endif
