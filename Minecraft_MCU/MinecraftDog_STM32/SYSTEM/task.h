#ifndef __TASK_H
#define __TASK_H

#include <stdint.h>

#define TASK_UWB_POLL_PERIOD_MS  (5U)
#define TASK_FPGA_RX_PERIOD_MS   (5U)    /* FPGA 帧解包, 不要调大(环形缓冲余量) */
#define TASK_MOTOR_PERIOD_MS     (5U)    /* 按 FPGA 命令驱动电机 + 停车保护 */
#define TASK_FPGA_TX_PERIOD_MS   (20U)   /* UWB -> FPGA, 有新 UWB 数据才发 */
#define TASK_KEY_SCAN_PERIOD_MS  (10U)
#define TASK_FOLLOW_PERIOD_MS    (20U)   /* 本地跟随, 已停用(决策在 FPGA) */
#define TASK_LED_PERIOD_MS       (100U)  /* PA8 板载 LED 指示 FPGA 链路 */

/* 按键试电机方向 (不需要 FPGA): KEY1 = 两轮 +3000 前进 3 秒, KEY2 = 两轮 -3000 后退 3 秒,
 * 测试中再按任一键立即停。测试期间不理 FPGA 的命令。 */
#define TASK_MOTOR_TEST_PWM      (3000)
#define TASK_MOTOR_TEST_MS       (3000U)

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
/* void Task_Follow_Control(void); */
void Task_LED(void);

#endif
