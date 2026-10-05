#ifndef	__DELAY_H__
#define __DELAY_H__

#include <stdint.h>



void delay_us(uint32_t us);
void delay_ms(uint32_t ms);
void delay_1us(uint32_t us);
void delay_1ms(uint32_t ms);
void get_clock_ms(unsigned long *ms);

#define mspm0_delay_ms      delay_ms
#define mspm0_get_clock_ms  get_clock_ms

/* ==========================================================================
 * 计时器(秒表) —— 赛题「按键启动时计时系统开始计时并显示时间」用
 *
 * 时基是本文件的 SysTick 1ms 计数(g_clock_ms), 与 task.c 的 g_time_ms 是两套
 * 独立的 1ms 节拍, 互不影响。注意别和 task.c 的 Timer_1ms_Init()(硬件 TIMG0
 * 节拍初始化) 搞混, 那个是系统心跳, 这里是给每道题计成绩用的秒表。
 *
 * 典型用法(每道题都这样):
 *     Timer_Reset();               // 进模式: 读数清 0
 *     ...
 *     Timer_Start();               // 起跑那一刻(mode_1 是解开电机锁的瞬间)
 *     ...
 *     Timer_Stop();                // 停车那一刻, 读数定格
 *     total = Timer_GetMs();       // 定格值, 停止后一直可读
 *
 * OLED 第 6 行由 task.c 的 Task_TimeShow -> OLED_ShowTime() 每 200ms 显示。
 * ========================================================================== */
void     Timer_Start(void);       /* 清零并开始计时 */
void     Timer_Stop(void);        /* 停止计时, 读数定格(重复调用无效) */
void     Timer_Reset(void);       /* 停止并清零 */
uint32_t Timer_GetMs(void);       /* 计时值(ms): 运行中=实时, 停止后=定格值 */
uint8_t  Timer_IsRunning(void);

/* ---- 模块计时器: 和比赛秒表【完全独立】的第二块表, 纯给调试看 ----
 * 起点 = 进模式; 终点 = ★球环停摆★(没球环的模式则是断电停车)。
 * 显示在 OLED 第 2 行, 把原来的 "run" 换成 "xx.x"。
 * 意义: 比赛秒表在判定那一刻就定格了, 而球环往往在车停下后还要再稳好几秒 ——
 *       那几秒恰恰最该盯, 却不在比赛秒表里。详见 delay.c。 */
void     ModeTimer_Start(void);
void     ModeTimer_Stop(void);      /* 幂等, 多处调用安全 */
uint32_t ModeTimer_GetMs(void);   /* 1 = 正在计时 */




#endif
