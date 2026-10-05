#include "task.h"
#include "AllHeader.h"

volatile uint32_t g_time_ms = 0;

static uint16_t Task_AbsAngle(int16_t angle)
{
    if (angle < 0) {
        return (uint16_t) (-(int32_t) angle);
    }

    return (uint16_t) angle;
}

void Task_UWB_Poll(void)
{
    UWB_Process(Get_Time());
}

void Task_Key_Scan(void)
{
    KEY_Scan(Get_Time());
}

void Task_Follow_Control(void)
{
    Follow_Process(Get_Time());
}

void Task_UWB_Display(void)
{
    UWB_Target target;
    uint32_t meters;
    uint32_t centimeters;
    uint16_t angle;

    if (!UWB_GetTarget(Get_Time(), &target)) {
        OLED_ShowString(0, 0, (uint8_t *) "UWB no signal        ", 8);
        OLED_ShowString(0, 2, (uint8_t *) "waiting...           ", 8);
        return;
    }

    OLED_ShowString(0, 0, (uint8_t *) "                     ", 8);
    angle = Task_AbsAngle(target.azimuth_deg);

    if (target.azimuth_deg < 0) {
        OLED_ShowString(0, 0, (uint8_t *) "left ", 8);
    } else if (target.azimuth_deg > 0) {
        OLED_ShowString(0, 0, (uint8_t *) "right", 8);
    } else {
        OLED_ShowString(0, 0, (uint8_t *) "front", 8);
    }

    OLED_ShowChar(36, 0, ' ', 8);
    OLED_ShowNum(42, 0, angle, 3, 8);
    OLED_ShowString(60, 0, (uint8_t *) " deg", 8);

    meters      = target.distance_cm / 100U;
    centimeters = target.distance_cm % 100U;

    OLED_ShowString(0, 2, (uint8_t *) "                     ", 8);
    OLED_ShowString(0, 2, (uint8_t *) "dist ", 8);
    OLED_ShowNum(30, 2, meters, 4, 8);
    OLED_ShowChar(54, 2, '.', 8);
    OLED_ShowChar(60, 2, (uint8_t) ('0' + (centimeters / 10U)), 8);
    OLED_ShowChar(66, 2, (uint8_t) ('0' + (centimeters % 10U)), 8);
    OLED_ShowChar(72, 2, 'm', 8);
}

static Task tasks[] = {
    {TASK_UWB_POLL_PERIOD_MS, 0U, Task_UWB_Poll},
    {TASK_KEY_SCAN_PERIOD_MS, 0U, Task_Key_Scan},
    {TASK_FOLLOW_PERIOD_MS,   0U, Task_Follow_Control},
    {TASK_OLED_PERIOD_MS,     0U, Task_UWB_Display},
};

void Timer_1ms_Init(void)
{
    NVIC_ClearPendingIRQ(TIMER_1ms_INST_INT_IRQN);
    NVIC_EnableIRQ(TIMER_1ms_INST_INT_IRQN);
    DL_TimerG_startCounter(TIMER_1ms_INST);
}

uint32_t Get_Time(void)
{
    return g_time_ms;
}

void Scheduler_Run(void)
{
    uint32_t now = Get_Time();

    for (uint32_t i = 0; i < (sizeof(tasks) / sizeof(tasks[0])); i++)
    {
        if ((uint32_t)(now - tasks[i].last_call) >= tasks[i].interval)
        {
            tasks[i].last_call = now;
            tasks[i].task();
        }
    }
}

void TIMER_1ms_INST_IRQHandler(void)
{
    switch (DL_TimerG_getPendingInterrupt(TIMER_1ms_INST))
    {
        case DL_TIMERG_IIDX_ZERO:
            g_time_ms++;
            break;

        default:
            break;
    }
}
