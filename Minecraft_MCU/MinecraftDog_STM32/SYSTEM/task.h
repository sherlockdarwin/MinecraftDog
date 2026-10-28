#ifndef __TASK_H
#define __TASK_H

#include <stdint.h>

#define TASK_UWB_POLL_PERIOD_MS  (5U)
#define TASK_FPGA_RX_PERIOD_MS   (5U)    /* FPGA 帧解包, 不要调大(环形缓冲余量) */
#define TASK_MOTOR_PERIOD_MS     (5U)    /* 按 FPGA 命令驱动电机 + 停车保护 */
#define TASK_FPGA_TX_PERIOD_MS   (20U)   /* UWB -> FPGA, 有新 UWB 数据才发 */
#define TASK_KEY_SCAN_PERIOD_MS  (10U)
#define TASK_FOLLOW_PERIOD_MS    (20U)   /* 【跟随测试模式】长按 KEY1 进入, 长按 KEY2 退出 */
#define TASK_LED_PERIOD_MS       (20U)   /* PA8 板载 LED 指示信标在左还是在右 */
#define TASK_LCD_PERIOD_MS       (1000U) /* 屏幕刷新 (1.44 寸 LCD, 放在任务表最后) */
#define TASK_TAIL_PERIOD_MS      (10U)   /* 步进电机 (尾巴): 上电回零 + 主人 3 m 以内摇 + 短按 KEY2 摇摆 */

/* 按键试电机方向 (不需要 FPGA): 短按 KEY1 = 两轮 ±3000 走 3 秒, 第一次前进、下一次后退,
 * 轮流来; 测试中再按 KEY1 立即停。测试期间不理 FPGA 的命令。 */
#define TASK_MOTOR_TEST_PWM      (3000)
#define TASK_MOTOR_TEST_MS       (3000U)

/* 板载 LED (PA8): 信标在左边或正前方 (车体角 ≤ +TASK_LED_FRONT_DEG) 亮, 在右边灭,
 * 收不到 UWB 快闪 (每 TASK_LED_LOST_TOGGLE_MS 变一次)。
 * 亮灭反了 (右边亮、左边灭) 就把 TASK_LED_ON_LEVEL 改成 GPIO_PIN_SET。 */
#define TASK_LED_FRONT_DEG       (5)     /* 和跟随的死区一样: ±5° 算正前方 */
#define TASK_LED_LOST_TOGGLE_MS  (100U)
#define TASK_LED_ON_LEVEL        GPIO_PIN_RESET   /* 板载 LED 一般是低电平亮 */

/* 尾巴 (步进电机, 只归 STM32 管): 主人 (信标) 走近就摇。
 * UWB 距离 < TASK_TAIL_NEAR_CM 并且一直保持 TASK_TAIL_NEAR_CONFIRM_MS (偶尔跳一帧近的不算) = 主人在身边,
 * 一个来回接一个来回地摇; 走远到 ≥ TASK_TAIL_FAR_CM 或收不到 UWB, 把当前这个来回摇完 (停在正中) 就停。
 * 3 m ~ 3.2 m 之间保持原状 (回差, 站在 3 m 附近、读数上下抖也不会一会儿摇一会儿停)。 */
#define TASK_TAIL_NEAR_CM          (300U)
#define TASK_TAIL_FAR_CM           (320U)
#define TASK_TAIL_NEAR_CONFIRM_MS  (300U)

typedef struct {
    uint32_t interval;
    uint32_t last_call;
    void (*task)(void);
} Task;

void Scheduler_Run(void);
uint32_t Get_Time(void);
void Task_UWB_Poll(void);
void Task_FPGA_Rx(void);
void Task_Motor_Drive(void);
void Task_FPGA_Tx(void);
void Task_Key_Scan(void);
void Task_Follow_Mode(void);       /* 【跟随测试模式】 */
void Task_LED(void);
void Task_UWB_Display(void);
void Task_Tail(void);

#endif
