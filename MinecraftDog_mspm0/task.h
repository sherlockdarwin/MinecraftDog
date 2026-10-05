#ifndef __TASK_H
#define __TASK_H

#include <stdint.h>

#define TASK_TIMER_HZ            (1000U)
#define TASK_UWB_POLL_PERIOD_MS  (5U)
#define TASK_KEY_SCAN_PERIOD_MS  (10U)
#define TASK_FOLLOW_PERIOD_MS    (20U)
#define TASK_OLED_PERIOD_MS      (1000U)

typedef struct {
    uint32_t interval;
    uint32_t last_call;
    void (*task)(void);
} Task;

void Timer_1ms_Init(void);
void Scheduler_Run(void);
uint32_t Get_Time(void);
void Task_UWB_Poll(void);
void Task_Key_Scan(void);
void Task_Follow_Control(void);
void Task_UWB_Display(void);

#endif
