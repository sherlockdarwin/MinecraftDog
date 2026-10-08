#include "task.h"
#include "AllHeader.h"

void Task_UWB_Poll(void)
{
    UWB_Process(Get_Time());
}

void Task_Key_Scan(void)
{
    KEY_Scan(Get_Time());
}

/* 本地跟随已停用: 跟随 + 避障决策都在 FPGA (obstacle.md 第 6 节), STM32 只执行。
void Task_Follow_Control(void)
{
    Follow_Process(Get_Time());
}
*/

void Task_FPGA_Rx(void)
{
    FPGAMLK_Poll(Get_Time());
}

/* UWB -> FPGA: 有新的 UWB 数据就发 "$l12350&"; 收不到 UWB 就发 "$S&"
 * (刚丢的那一拍立刻发, 之后每 100 ms 重发)。 */
void Task_FPGA_Tx(void)
{
    static uint32_t last_uwb_count = 0U;
    static uint32_t last_lost_ms   = 0U;
    uint32_t now = Get_Time();
    uint32_t uwb_count = UWB_GetFrameCount();
    UWB_Target target;

    if (UWB_GetTarget(now, &target)) {
        if ((uwb_count != last_uwb_count) &&
            FPGAMLK_SendTarget(target.azimuth_deg, target.distance_cm)) {
            last_uwb_count = uwb_count;
        }
        return;
    }

    if ((!g_fpga_uwb_lost ||
         ((uint32_t) (now - last_lost_ms) >= FPGAMLK_LOST_RESEND_MS)) &&
        FPGAMLK_SendLost()) {
        last_lost_ms = now;
    }
}

/* 按键试电机方向: 返回 true = 正在测试, 这一拍电机归它管。 */
static bool Task_Motor_Test(uint32_t now)
{
    static int16_t  test_pwm      = 0;
    static uint32_t test_start_ms = 0U;
    bool key1 = Key1_Short_Press();
    bool key2 = Key2_Short_Press();

    if (test_pwm != 0) {
        if (key1 || key2 ||
            ((uint32_t) (now - test_start_ms) >= TASK_MOTOR_TEST_MS)) {
            test_pwm = 0;
            Motor_Lock_Set(0U);
            return false;
        }
        Motor_Lock_Set(1U);
        PWM_Control_Car(test_pwm, test_pwm);
        return true;
    }

    if (key1 || key2) {
        test_pwm      = key1 ? TASK_MOTOR_TEST_PWM : -TASK_MOTOR_TEST_PWM;
        test_start_ms = now;
        Motor_Lock_Set(1U);
        PWM_Control_Car(test_pwm, test_pwm);
        return true;
    }

    return false;
}

/* 按 FPGA 的命令驱动电机。下面三种情况立即关电机锁停车:
 *   UWB 收不到 / 200 ms 没收到完整的 FPGA 帧 / FPGA 发来 "#S*"。
 * 正常时每收到一帧新命令执行一次 (FPGA 每 20 ms 一帧, 斜坡已在 FPGA 里做)。 */
void Task_Motor_Drive(void)
{
    uint32_t now = Get_Time();
    bool fresh = FPGAMLK_TakeUpdate();
    UWB_Target target;

    if (Task_Motor_Test(now)) {
        return;
    }

    if (!UWB_GetTarget(now, &target) || !FPGAMLK_LinkAlive(now) ||
        g_fpga_stop) {
        if (Motor_Lock_Get()) {
            Motor_Lock_Set(0U);
        }
        return;
    }

    if (fresh) {
        Motor_Lock_Set(1U);
        PWM_Control_Car(g_fpga_left_pwm, g_fpga_right_pwm);
    }
}

/* 板载 LED (PA8): 和 FPGA 链路通 = 1 秒闪一次, 不通 = 快闪。
 * 要在 CubeMX 里把 PA8 设成 GPIO_Output、User Label 填 LED 才会生效;
 * 没配的话 main.h 里没有 LED_Pin, 这个任务什么也不做。 */
void Task_LED(void)
{
#ifdef LED_Pin
    static uint8_t ticks = 0U;
    uint8_t half_period = FPGAMLK_LinkAlive(Get_Time()) ? 5U : 1U;

    if (++ticks >= half_period) {
        ticks = 0U;
        HAL_GPIO_TogglePin(LED_GPIO_Port, LED_Pin);
    }
#endif
}

/* 按表顺序执行: 先收(UWB、FPGA) -> 再驱动电机 -> 再发。 */
static Task tasks[] = {
    {TASK_UWB_POLL_PERIOD_MS, 0U, Task_UWB_Poll},
    {TASK_FPGA_RX_PERIOD_MS,  0U, Task_FPGA_Rx},
    {TASK_MOTOR_PERIOD_MS,    0U, Task_Motor_Drive},
    {TASK_FPGA_TX_PERIOD_MS,  0U, Task_FPGA_Tx},
    {TASK_KEY_SCAN_PERIOD_MS, 0U, Task_Key_Scan},
    /* {TASK_FOLLOW_PERIOD_MS,   0U, Task_Follow_Control}, 本地跟随已停用 */
    {TASK_LED_PERIOD_MS,      0U, Task_LED},
};

/* 1 ms 时基 = HAL 的 SysTick (原来 MSPM0 是单独开的 TIMER_1ms)。 */
uint32_t Get_Time(void)
{
    return HAL_GetTick();
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
