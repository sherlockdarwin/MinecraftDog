#include "encoder.h"

#include "tim.h"

/* 硬件计数: TIM8 = 左轮, TIM2 = 右轮 (CubeMX 里都是 Encoder Mode TI1 and TI2, 0~65535)。
 * 不再用中断数边沿, temp_count 也就用不上了; encoder_update() 用"这次读数 - 上次读数"
 * 算本周期计数, 按 int16_t 相减自动处理 65535 <-> 0 的回绕
 * (前提: 两次 encoder_update 之间单轮不超过 32767 个计数)。 */
#define ENCODER_LEFT_TIM   (&htim8)
#define ENCODER_RIGHT_TIM  (&htim2)

static ENCODER_RES motorL_encoder;
static ENCODER_RES motorR_encoder;

static uint16_t g_encoderL_last = 0U;
static uint16_t g_encoderR_last = 0U;

void encoder_init(void)
{
    motorL_encoder.temp_count = 0;
    motorL_encoder.count      = 0;
    motorL_encoder.dir        = FORWARD;
    motorL_encoder.ALLcount   = 0;

    motorR_encoder.temp_count = 0;
    motorR_encoder.count      = 0;
    motorR_encoder.dir        = FORWARD;
    motorR_encoder.ALLcount   = 0;

    HAL_TIM_Encoder_Start(ENCODER_LEFT_TIM, TIM_CHANNEL_ALL);
    HAL_TIM_Encoder_Start(ENCODER_RIGHT_TIM, TIM_CHANNEL_ALL);
    g_encoderL_last = (uint16_t) __HAL_TIM_GET_COUNTER(ENCODER_LEFT_TIM);
    g_encoderR_last = (uint16_t) __HAL_TIM_GET_COUNTER(ENCODER_RIGHT_TIM);
}

ENCODER_DIR get_encoderL_dir(void)
{
    return motorL_encoder.dir;
}

ENCODER_DIR get_encoderR_dir(void)
{
    return motorR_encoder.dir;
}

void Encoder_Get_ALL(int *Encoder_all)
{
    if (Encoder_all == 0) {
        return;
    }

    Encoder_all[0] = motorL_encoder.ALLcount;
    Encoder_all[1] = motorR_encoder.ALLcount;
}

void Encoder_Get_Temp(int *Encoder_temp)
{
    if (Encoder_temp == 0) {
        return;
    }

    Encoder_temp[0] = motorL_encoder.count;
    Encoder_temp[1] = motorR_encoder.count;
}

/* 里程计累计: 左右轮"本周期计数"之和(读数时再除以 2 取平均, 避免整数除法丢精度)。
 * 累加点放在 encoder_update() 内部, 这样不管周期调用者是谁(里程任务 / 速度环
 * MotorPID_Run), 里程都会自动跟着走, 不用两处各记一份。 */
static long g_odom_sum = 0;

void encoder_update(void)
{
    uint16_t left_now  = (uint16_t) __HAL_TIM_GET_COUNTER(ENCODER_LEFT_TIM);
    uint16_t right_now = (uint16_t) __HAL_TIM_GET_COUNTER(ENCODER_RIGHT_TIM);
    int16_t left_temp  = (int16_t) (left_now - g_encoderL_last);
    int16_t right_temp = (int16_t) (right_now - g_encoderR_last);

    g_encoderL_last = left_now;
    g_encoderR_last = right_now;

    motorL_encoder.count = (int) left_temp;
    motorR_encoder.count = (int) right_temp;

    motorL_encoder.ALLcount += motorL_encoder.count;
    motorR_encoder.ALLcount += motorR_encoder.count;

    motorL_encoder.dir = (motorL_encoder.count >= 0) ? FORWARD : REVERSAL;
    motorR_encoder.dir = (motorR_encoder.count >= 0) ? FORWARD : REVERSAL;

    /* ★★ 必须过一遍方向符号 ★★ (2026-07-31 修)
     * 左右编码器的正方向不一定相同 —— 本车 motor_pid_enc_sign_r 就是 -1, 即前进时
     * 右侧读【负】数。原来是把两个【原始】计数直接相加, 结果是 +N + (-N) ≈ 0:
     *     g_odom_sum 恒等于 0 -> Encoder_Odom_GetM() 恒等于 0
     *     -> mode_3 的"里程 >= 1.5m"判据【永远不会触发】
     *     -> 只能靠"转角 >= 12 度"兜底 -> 直道上画一下龙就停了(实测"没到 B 就停")
     * 方向符号现在由 encoder.h 的 ENCODER_*_FORWARD_SIGN 统一配置，后续速度环
     * 直接读取已经校正过的速度/里程即可，不再依赖尚未创建的算法文件。 */
    g_odom_sum += (long) (ENCODER_LEFT_FORWARD_SIGN * motorL_encoder.count)
                + (long) (ENCODER_RIGHT_FORWARD_SIGN * motorR_encoder.count);
}

/* ==========================================================================
 * 里程计 —— 见 encoder.h 顶部说明。★ encoder_counts_per_meter 必须上车标定 ★
 * ========================================================================== */
float encoder_counts_per_meter = 3800.0f;   /* 猜的起点值, 标定后改这里(含符号) */

void Encoder_Odom_Reset(void)
{
    encoder_update();       /* 先把上次残留的计数吃掉, 从干净的 0 开始 */
    g_odom_sum = 0;
}

void Encoder_Odom_Update(void)
{
    encoder_update();       /* 累加在 encoder_update() 内部完成 */
}

long Encoder_Odom_GetCount(void)
{
    return g_odom_sum / 2;  /* 左右平均计数, 标定时看这个数 */
}

float Encoder_Odom_GetM(void)
{
    if ((encoder_counts_per_meter > -1.0f) && (encoder_counts_per_meter < 1.0f)) {
        return 0.0f;        /* 未标定/非法, 返回 0 而不是除爆 */
    }

    return (float) g_odom_sum / (2.0f * encoder_counts_per_meter);
}

/* 最近一次采样的左右速度(编码器本周期计数, 带符号) */
volatile int g_speed_left  = 0;
volatile int g_speed_right = 0;

void Encoder_Speed_Sample(void)
{
    int temp[2];

    encoder_update();               /* 读并清零本周期计数 */
    Encoder_Get_Temp(temp);         /* [0]=左, [1]=右 */
    g_speed_left  = temp[0];
    g_speed_right = temp[1];
}
