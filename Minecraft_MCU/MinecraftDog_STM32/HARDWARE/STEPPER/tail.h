#ifndef __TAIL_H_
#define __TAIL_H_

/*
 * 尾巴 (ZDT X42S 步进) 动作层: 发哪几帧、中间等多久。和 FPGA 的 mc_tail.v 同一套做法。
 * 不读驱动器的"到位"应答, 每一步都按时间等。
 *
 * 上电 / 复位回零 (自动): 等 TAIL_INIT_MS (等驱动器自己上电) 后
 *     解除保护 -> 使能 -> 单圈就近回零 (驱动器转到它存的"单圈回零零点", 最多半圈)
 *     -> 等 TAIL_HOME_MS -> 把这里设为坐标零点。之后"绝对位置 0" = 初始位置。
 *     ★ 零点要先在驱动器上存一次 (掉电不丢): 驱动器断电, 用手把尾巴拧到初始位置,
 *       上电后驱动器菜单 O_Set -> Set O; 或者调一次 Stepper_SetOrigin(1, 1)。
 *
 * 摇摆测试 (Tail_Wag, 短按 KEY2): 中 -> 左 45° -> 中 -> 右 45° -> 中, 用绝对位置,
 *     摇多少次都不累积偏差。回零做完之前、或者正在动的时候, 再按不理。
 *
 * 摆幅换算: 脉冲数 = 3200 × 减速比 × 角度 / 360; 尾巴直接装在电机轴上, 45° = 400 脉冲。
 * 每一段等 "走完时间 + 停顿": 走完时间 TAIL_MOVE_MS 按摆幅和转速自动算
 *     (角度 / (RPM × 6) × 1000, 45°、10 RPM = 750 ms); 停顿: 左右两头 TAIL_SIDE_PAUSE_MS (很短,
 *     到了就往回摆), 回到中间 TAIL_CENTER_PAUSE_MS。停顿太短、电机还没走到时下一条命令就来了,
 *     会提前掉头 (摆幅变小一点), 那就把停顿加大一点。
 */

#include <stdbool.h>
#include <stdint.h>

#define TAIL_ADDR            (1U)      /* 驱动器地址 (出厂 1) */
#define TAIL_PULSES_PER_REV  (3200L)   /* 1.8° 电机 × 16 细分 */
#define TAIL_GEAR_X100       (100L)    /* 减速比 × 100: 直接装在电机轴上 = 100; 电机转 3 圈尾巴转 1 圈 = 300 */
#define TAIL_SWING_DEG       (45L)     /* 摆幅 (度) */
#define TAIL_LEFT_IS_CCW     (1U)      /* 1: 向左 = 电机逆时针 (CCW); 摆反了改成 0 */
#define TAIL_RPM             (10U)     /* 摇摆转速, 慢一点方便看 (FPGA 版是 80) */
#define TAIL_ACC             (0U)      /* 加速度档: 0 = 不用曲线, 直接按转速启动 */
#define TAIL_SIDE_PAUSE_MS   (50U)     /* 摆到左 / 右两头后停多久 (到了就往回摆) */
#define TAIL_CENTER_PAUSE_MS (500U)    /* 回到中间停多久 */
#define TAIL_INIT_MS         (1000U)   /* 上电 / 复位后等多久开始回零 (等驱动器上电) */
#define TAIL_HOME_MS         (2000U)   /* 发出回零后等多久再设坐标零点 (驱动器回零默认 30 RPM, 半圈 1 秒) */
#define TAIL_GAP_MS          (20U)     /* 两条命令之间的间隔 */

/* 摆幅脉冲数 (四舍五入) */
#define TAIL_SWING_PULSES \
    ((uint32_t) ((TAIL_PULSES_PER_REV * TAIL_GEAR_X100 * TAIL_SWING_DEG + 18000L) / 36000L))

/* 走完一段 (中 <-> 一边) 的时间, ms, 向上取整: 电机转的角度 / (RPM × 6 度每秒) */
#define TAIL_MOVE_MS \
    ((uint32_t) ((TAIL_SWING_DEG * TAIL_GEAR_X100 * 10L + (long) TAIL_RPM * 6L - 1L) / ((long) TAIL_RPM * 6L)))

typedef enum {
    TAIL_STATE_WAIT_BOOT = 0,   /* 上电后等驱动器 */
    TAIL_STATE_HOMING,          /* 正在回零 */
    TAIL_STATE_IDLE,            /* 回零做完, 空闲 */
    TAIL_STATE_WAGGING          /* 正在摇摆 */
} Tail_State;

extern volatile Tail_State g_tail_state;   /* 调试看 */

void Tail_Init(void);

/* 周期调用 (10 ms): 到点了就发下一条命令。 */
void Tail_Process(uint32_t now_ms);

/* 摇一个来回: 中 -> 左 -> 中 -> 右 -> 中。回零没做完 / 正在动时返回 false, 不排队。 */
bool Tail_Wag(void);

bool Tail_IsHomed(void);

#endif
