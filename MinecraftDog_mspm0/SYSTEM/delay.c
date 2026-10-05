#include "delay.h"
#include <stdbool.h>
#include "ti_msp_dl_config.h"

#ifndef CPUCLK_FREQ
#define CPUCLK_FREQ 80000000U
#endif

#define SYSTICK_MS_PERIOD  (CPUCLK_FREQ / 1000U)
#define SYSTICK_US_TICKS   (CPUCLK_FREQ / 1000000U)

static volatile uint32_t g_clock_ms;
static bool g_delay_initialized;

static void delay_init(void)
{
    if (!g_delay_initialized) {
        DL_SYSTICK_init(SYSTICK_MS_PERIOD);
        DL_SYSTICK_enableInterrupt();
        DL_SYSTICK_enable();
        g_delay_initialized = true;
    }
}

void SysTick_Handler(void)
{
    g_clock_ms++;
}

void delay_us(uint32_t us) 
{
    uint32_t ticks;
    uint32_t told, tnow, tcnt = 0;

    delay_init();

    ticks = us * SYSTICK_US_TICKS; 
    if (ticks == 0U) {
        return;
    }

    told = SysTick->VAL;

    while (1)
    {
        tnow = SysTick->VAL;

        if (tnow != told)
        {
            if (tnow < told)
                tcnt += told - tnow;
            else
                tcnt += SysTick->LOAD - tnow + told + 1U;

            told = tnow;

            if (tcnt >= ticks)
                break;
        }
    }
}

void delay_ms(uint32_t ms) 
{
	delay_us( ms * 1000 );
}

void delay_1us(uint32_t us){ delay_us(us); }
void delay_1ms(uint32_t ms){ delay_ms(ms); }

void get_clock_ms(unsigned long *ms)
{
    delay_init();

    if (ms != NULL) {
        *ms = g_clock_ms;
    }
}

/* ==========================================================================
 * 计时器(秒表) —— 见 delay.h 顶部说明。
 *   运行中读数 = 当前 SysTick 毫秒 - 启动时刻; 停止时把差值定格进 g_sw_elapsed_ms。
 *   减法用无符号回绕, 49 天翻转也不会出错。
 * ========================================================================== */
static volatile uint32_t g_sw_start_ms   = 0;   /* 启动时刻(SysTick ms) */
static volatile uint32_t g_sw_elapsed_ms = 0;   /* 停止后定格的读数(ms) */
static volatile uint8_t  g_sw_running    = 0;

void Timer_Start(void)
{
    delay_init();                       /* 保证 SysTick 已在跑 */
    g_sw_start_ms   = g_clock_ms;
    g_sw_elapsed_ms = 0;
    g_sw_running    = 1;
}

void Timer_Stop(void)
{
    if (g_sw_running) {
        g_sw_elapsed_ms = (uint32_t) (g_clock_ms - g_sw_start_ms);
        g_sw_running    = 0;
    }
}

void Timer_Reset(void)
{
    delay_init();
    g_sw_running    = 0;
    g_sw_elapsed_ms = 0;
    g_sw_start_ms   = g_clock_ms;
}

uint32_t Timer_GetMs(void)
{
    if (g_sw_running) {
        return (uint32_t) (g_clock_ms - g_sw_start_ms);
    }

    return g_sw_elapsed_ms;
}

uint8_t Timer_IsRunning(void)
{
    return g_sw_running;
}

/* ==========================================================================
 *  模块计时器 (ModeTimer) —— 和上面的比赛秒表【完全独立】的第二块表
 *
 *  比赛秒表 Timer_* 计的是【赛题定义的那段】(起跑到通过判定点), 各题不一样;
 *  本表计的是【这个模式从进来到彻底干完活】有多久, 纯给调试看:
 *      起点: 进模式(mode_enter_common)
 *      终点: ★球环停摆(ball_parked)★ —— 球真正稳住不动才算干完;
 *            没有球环的模式(1/6)则在断电停车那一刻停表
 *  显示在 OLED 第 2 行, 把原来的 "run" 换成 "xx.x"。
 *
 *  为什么单独一块表: 比赛秒表在判定那一刻就定格了(缓停/补跑都不算), 而球环往往
 *  在车停下之后还要再稳好几秒 —— 那几秒恰恰是最该盯的, 却不在比赛秒表里。
 * ========================================================================== */
static volatile uint32_t g_mt_start_ms   = 0;
static volatile uint32_t g_mt_elapsed_ms = 0;
static volatile uint8_t  g_mt_running    = 0;

void ModeTimer_Start(void)
{
    g_mt_start_ms   = g_clock_ms;
    g_mt_elapsed_ms = 0;
    g_mt_running    = 1;
}

/* 幂等: 已经停了就不再动, 所以多处调用都安全(谁先到算谁)。 */
void ModeTimer_Stop(void)
{
    if (g_mt_running) {
        g_mt_elapsed_ms = (uint32_t) (g_clock_ms - g_mt_start_ms);
        g_mt_running    = 0;
    }
}

uint32_t ModeTimer_GetMs(void)
{
    if (g_mt_running) {
        return (uint32_t) (g_clock_ms - g_mt_start_ms);
    }

    return g_mt_elapsed_ms;
}
