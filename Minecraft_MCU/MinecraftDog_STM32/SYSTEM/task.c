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

/* 【跟随测试模式】长按 KEY1 进入、长按 KEY2 退出, 不经过 FPGA 单独跑 follow.c 的
 * UWB 跟随。不要了就删掉这个函数和任务表里那一行, 其余见 ALGORITHM/follow_mode.h。 */
void Task_Follow_Mode(void)
{
    FollowMode_Process(Get_Time());
}

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

static int16_t s_motor_test_pwm = 0;

/* 按键试电机方向 (短按 KEY1, 第一次前进、下一次后退, 轮流来): 返回 true = 正在测试,
 * 这一拍电机归它管。短按 KEY2 现在给步进电机摇摆测试用 (Task_Tail)。 */
static bool Task_Motor_Test(uint32_t now)
{
    static uint32_t test_start_ms = 0U;
    static int16_t  next_pwm      = TASK_MOTOR_TEST_PWM;
    bool key1 = Key1_Short_Press();

    if (s_motor_test_pwm != 0) {
        if (key1 ||
            ((uint32_t) (now - test_start_ms) >= TASK_MOTOR_TEST_MS)) {
            s_motor_test_pwm = 0;
            Motor_Lock_Set(0U);
            return false;
        }
        Motor_Lock_Set(1U);
        PWM_Control_Car(s_motor_test_pwm, s_motor_test_pwm);
        return true;
    }

    if (key1) {
        s_motor_test_pwm = next_pwm;
        next_pwm         = (int16_t) -next_pwm;
        test_start_ms    = now;
        Motor_Lock_Set(1U);
        PWM_Control_Car(s_motor_test_pwm, s_motor_test_pwm);
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

    if (FollowMode_IsActive()) {    /* 【跟随测试模式】电机归 follow.c 管, 试电机也取消 */
        s_motor_test_pwm = 0;
        return;
    }

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

/* 板载 LED (PA8), 20 ms 看一次 (远处看, 比屏幕 1 秒一刷及时): 信标在左边或正前方亮, 在右边灭,
 * 收不到 UWB 快闪。用的是和发给 FPGA / 跟随同一个 UWB_GetTarget() 结果, 正常模式和跟随测试模式都一样。
 * 要在 CubeMX 里把 PA8 设成 GPIO_Output、User Label 填 LED 才会生效;
 * 没配的话 main.h 里没有 LED_Pin, 这个任务什么也不做。 */
void Task_LED(void)
{
#ifdef LED_Pin
    static uint32_t last_toggle_ms = 0U;
    uint32_t now = Get_Time();
    GPIO_PinState off_level = (TASK_LED_ON_LEVEL == GPIO_PIN_SET) ? GPIO_PIN_RESET : GPIO_PIN_SET;
    UWB_Target target;

    if (!UWB_GetTarget(now, &target)) {
        if ((uint32_t) (now - last_toggle_ms) >= TASK_LED_LOST_TOGGLE_MS) {
            last_toggle_ms = now;
            HAL_GPIO_TogglePin(LED_GPIO_Port, LED_Pin);
        }
        return;
    }

    HAL_GPIO_WritePin(LED_GPIO_Port, LED_Pin,
                      (target.azimuth_deg <= TASK_LED_FRONT_DEG) ? TASK_LED_ON_LEVEL : off_level);
#endif
}

static bool s_tail_owner_near = false;   /* 主人在 3 m 以内 (屏幕上显示) */

/* 主人在不在身边 (参数和回差见 task.h 的 TASK_TAIL_*):
 *   距离 < 3 m 一直保持 0.3 秒 -> 在; 距离 ≥ 3.2 m 或收不到 UWB -> 马上不在; 中间保持原状。
 * 用的是和发给 FPGA 同一个 UWB_GetTarget() 的距离。 */
static bool Task_Tail_OwnerNear(uint32_t now)
{
    static bool     near         = false;
    static bool     near_pending = false;   /* 已经 < 3 m, 在等 0.3 秒确认 */
    static uint32_t near_since   = 0U;
    UWB_Target target;

    if (!UWB_GetTarget(now, &target) || (target.distance_cm >= TASK_TAIL_FAR_CM)) {
        near         = false;
        near_pending = false;
        return false;
    }

    if (target.distance_cm >= TASK_TAIL_NEAR_CM) {
        near_pending = false;               /* 3 m ~ 3.2 m: 保持原状, 确认要重新数 */
        return near;
    }

    if (!near) {
        if (!near_pending) {
            near_pending = true;
            near_since   = now;
        } else if ((uint32_t) (now - near_since) >= TASK_TAIL_NEAR_CONFIRM_MS) {
            near = true;
        }
    }

    return near;
}

/* 步进电机 (尾巴, 只归 STM32 管, FPGA 不再接驱动器): 上电 / 复位 1 秒后自动回零;
 * 主人在 3 m 以内就一个来回接一个来回地摇 (中 -> 左 45° -> 中 -> 右 45° -> 中), 走远了摇完当前来回停在正中;
 * 短按 KEY2 也摇一个来回。见 HARDWARE/STEPPER/tail.h。 */
void Task_Tail(void)
{
    uint32_t now = Get_Time();

    s_tail_owner_near = Task_Tail_OwnerNear(now);

    if (Key2_Short_Press() || s_tail_owner_near) {
        (void) Tail_Wag();      /* 回零没做完或者正在摇, 这次不理 (主人还在身边的话下一拍再试) */
    }

    Tail_Process(now);
}

/* "+3000" 写进 text[0..4] */
static void Task_FormatWheel(char *text, int16_t value)
{
    uint16_t magnitude = (uint16_t) ((value < 0) ? -(int32_t) value : value);

    text[0] = (value < 0) ? '-' : '+';
    text[1] = (char) ('0' + ((magnitude / 1000U) % 10U));
    text[2] = (char) ('0' + ((magnitude / 100U) % 10U));
    text[3] = (char) ('0' + ((magnitude / 10U) % 10U));
    text[4] = (char) ('0' + (magnitude % 10U));
}

/* 屏幕 (1.44 寸 128x128 LCD, 8x16 字, 一行 16 个字):
 *     y =   0  UWB 方向 + 角度      "left   45 deg"   / "UWB no signal"
 *     y =  16  距离                 "dist   3.50 m"   / "waiting..."
 *     y =  32  尾巴 (小字 6x8)      "tail WAG   near" / "tail IDLE  far", 见 Task_Tail_Display
 *     y =  40  FPGA 状态           "FPGA RUN" / "FPGA STOP" / "FPGA no link"
 *     y =  56  FPGA 的轮子命令      "L+3000 R-0500"   (RUN 时才有)
 *     y =  72 ~ 103  UWB 排查 (小字 6x8): 收到的字节 + 三个基站各自的角度 / 距离, 见 Task_UWB_StatsDisplay
 *     y = 112  跟随测试模式         由 follow_mode.c 写
 * 每行都补空格写满 16 个字, 把上一次的字盖掉。 */
#define DISP_LINE_LEN  (16U)

static void Task_ShowLine(uint16_t y, const char *text, uint16_t color)
{
    char line[DISP_LINE_LEN + 1U];
    uint8_t i = 0U;

    while ((i < DISP_LINE_LEN) && (text[i] != '\0')) {
        line[i] = text[i];
        i++;
    }
    while (i < DISP_LINE_LEN) {
        line[i++] = ' ';
    }
    line[DISP_LINE_LEN] = '\0';

    LCD_ShowString(0U, y, line, color, LCD_BLACK, 16U);
}

/* value 右对齐写进 text[0 .. width-1], 前面补空格 */
static void Task_FormatUint(char *text, uint32_t value, uint8_t width)
{
    while (width-- > 0U) {
        text[width] = (char) ('0' + (value % 10U));
        value /= 10U;
        if (value == 0U) {
            while (width-- > 0U) {
                text[width] = ' ';
            }
            return;
        }
    }
}

static void Task_FPGA_Display(void)
{
    char wheels[] = "L+0000 R+0000";

    if (!FPGAMLK_LinkAlive(Get_Time())) {
        Task_ShowLine(40U, "FPGA no link", LCD_WHITE);
        Task_ShowLine(56U, "", LCD_WHITE);
        return;
    }

    if (g_fpga_stop) {
        Task_ShowLine(40U, "FPGA STOP", LCD_YELLOW);
        Task_ShowLine(56U, "", LCD_WHITE);
        return;
    }

    Task_FormatWheel(&wheels[1], g_fpga_left_pwm);
    Task_FormatWheel(&wheels[8], g_fpga_right_pwm);
    Task_ShowLine(40U, "FPGA RUN", LCD_GREEN);
    Task_ShowLine(56U, wheels, LCD_WHITE);
}

/* 小字 (6x8) 一行 21 个字, 补空格写满 */
#define DISP_SMALL_LEN  (21U)

static void Task_ShowSmallLine(uint16_t y, const char *text, uint16_t color)
{
    char line[DISP_SMALL_LEN + 1U];
    uint8_t i = 0U;

    while ((i < DISP_SMALL_LEN) && (text[i] != '\0')) {
        line[i] = text[i];
        i++;
    }
    while (i < DISP_SMALL_LEN) {
        line[i++] = ' ';
    }
    line[DISP_SMALL_LEN] = '\0';

    LCD_ShowString(0U, y, line, color, LCD_BLACK, 8U);
}

/* 带符号的 value 右对齐写进 text[0 .. width-1], 符号紧挨着数字 ("  -5", " +45", "-123", "   0") */
static void Task_FormatInt(char *text, int32_t value, uint8_t width)
{
    uint32_t magnitude = (uint32_t) ((value < 0) ? -value : value);
    uint8_t i = 0U;

    Task_FormatUint(&text[1], magnitude, (uint8_t) (width - 1U));
    text[0] = ' ';
    while (((i + 1U) < width) && (text[i + 1U] == ' ')) {
        i++;
    }
    text[i] = (value < 0) ? '-' : ((value > 0) ? '+' : ' ');
}

/* 排查 UWB (小字):
 *     y =  72  "rx L1480 F1480 R1480"   每个基站收到的字节 (后 4 位, 正常每秒涨约 1480)
 *     y =  80  "L  -23deg   3.50 m"      左 / 前 / 右基站自己最近一帧解出来的角度和距离, 不经过合成:
 *     y =  88  "F   +5deg   3.42 m"        角度 = 基站自己的本地角 (它自己看: 左负右正, 0 = 它正对的方向;
 *                                            已经按 uwb.h 的 UWB_*_ANGLE_SIGN 换过正负号)
 *     y =  96  "R  +88deg   3.47 m"        绿字 = 最上面一行用的是这个基站; 灰字 "no data" = 500 ms 没新帧
 * 三个基站装在同一辆车上, 距离应该差不多; 哪个和另外两个总差很多, 或者角度不对, 就是它的问题。 */
static void Task_UWB_StatsDisplay(void)
{
    static const char anchor_name[UWB_ANCHOR_COUNT] = {'L', 'F', 'R'};
    static const uint16_t anchor_y[UWB_ANCHOR_COUNT] = {80U, 88U, 96U};
    char rx_line[] = "rx L     F     R    ";
    uint32_t now = Get_Time();
    UWB_Target target;
    bool have_target = UWB_GetTarget(now, &target);
    UWB_Stats stats;
    uint32_t source;

    for (source = 0U; source < (uint32_t) UWB_ANCHOR_COUNT; source++) {
        char line[] = "?    0deg   0.00 m";
        UWB_Measurement m;
        uint32_t cm;
        int32_t angle;

        UWB_GetStats((UWB_Anchor) source, &stats);
        Task_FormatUint(&rx_line[4U + source * 6U], stats.rx_bytes % 10000U, 4U);

        line[0] = anchor_name[source];
        if (!UWB_GetMeasurement((UWB_Anchor) source, &m) ||
            ((uint32_t) (now - m.update_time_ms) > UWB_DATA_TIMEOUT_MS)) {
            memcpy(&line[1], "  no data", 10U);     /* 连 '\0' 一起拷 */
            Task_ShowSmallLine(anchor_y[source], line, LCD_GRAY);
            continue;
        }

        angle = m.azimuth_deg;
        if (angle > 999) {
            angle = 999;
        } else if (angle < -999) {
            angle = -999;
        }
        cm = (m.distance_cm > 9999U) ? 9999U : m.distance_cm;

        Task_FormatInt(&line[2], angle, 4U);
        Task_FormatUint(&line[11], cm / 100U, 2U);
        line[14] = (char) ('0' + ((cm % 100U) / 10U));
        line[15] = (char) ('0' + (cm % 10U));

        Task_ShowSmallLine(anchor_y[source], line,
                           (have_target && (target.source == (UWB_Anchor) source)) ?
                           LCD_GREEN : LCD_WHITE);
    }

    Task_ShowSmallLine(72U, rx_line, LCD_CYAN);
    Task_ShowSmallLine(104U, "", LCD_WHITE);
}

/* 尾巴 (小字): 状态 BOOT 等驱动器上电 / HOME 回零 / IDLE 空闲 / WAG 摇摆, 后面 near = 主人在 3 m 以内。
 * 主人走近了却一直不是 near = 看距离那一行; near 了却一直不是 WAG = 回零没做完, 或者驱动器没接 PA9。 */
static void Task_Tail_Display(void)
{
    static const char state_name[][5] = {"BOOT", "HOME", "IDLE", "WAG "};
    char line[] = "tail ????  far ";
    Tail_State state = g_tail_state;

    if ((uint32_t) state < (sizeof(state_name) / sizeof(state_name[0]))) {
        memcpy(&line[5], state_name[state], 4U);
    }
    if (s_tail_owner_near) {
        memcpy(&line[11], "near", 4U);
    }

    Task_ShowSmallLine(32U, line, s_tail_owner_near ? LCD_GREEN : LCD_WHITE);
}

/* 1 秒刷新一次屏幕: UWB 方向 / 角度 / 距离 + 尾巴 + FPGA 命令 + UWB 收数统计。没接屏幕时什么也不做。 */
void Task_UWB_Display(void)
{
    char dir_line[]  = "front   0 deg";
    char dist_line[] = "dist    0.00 m";
    UWB_Target target;
    uint16_t angle;

    Task_Tail_Display();
    Task_FPGA_Display();
    Task_UWB_StatsDisplay();

    if (!UWB_GetTarget(Get_Time(), &target)) {
        Task_ShowLine(0U, "UWB no signal", LCD_WHITE);
        Task_ShowLine(16U, "waiting...", LCD_WHITE);
        return;
    }

    angle = (uint16_t) ((target.azimuth_deg < 0) ?
                        -(int32_t) target.azimuth_deg : target.azimuth_deg);
    if (target.azimuth_deg < 0) {
        dir_line[0] = 'l'; dir_line[1] = 'e'; dir_line[2] = 'f'; dir_line[3] = 't'; dir_line[4] = ' ';
    } else if (target.azimuth_deg > 0) {
        dir_line[0] = 'r'; dir_line[1] = 'i'; dir_line[2] = 'g'; dir_line[3] = 'h'; dir_line[4] = 't';
    }
    Task_FormatUint(&dir_line[6], angle, 3U);

    Task_FormatUint(&dist_line[5], target.distance_cm / 100U, 4U);
    dist_line[10] = (char) ('0' + ((target.distance_cm % 100U) / 10U));
    dist_line[11] = (char) ('0' + (target.distance_cm % 10U));

    Task_ShowLine(0U, dir_line, LCD_WHITE);
    Task_ShowLine(16U, dist_line, LCD_WHITE);
}

/* 按表顺序执行: 先收(UWB、FPGA) -> 再驱动电机 -> 再发 -> 最后是刷屏 (软件 SPI, 约 20 ms)。 */
static Task tasks[] = {
    {TASK_UWB_POLL_PERIOD_MS, 0U, Task_UWB_Poll},
    {TASK_FPGA_RX_PERIOD_MS,  0U, Task_FPGA_Rx},
    {TASK_MOTOR_PERIOD_MS,    0U, Task_Motor_Drive},
    {TASK_FPGA_TX_PERIOD_MS,  0U, Task_FPGA_Tx},
    {TASK_KEY_SCAN_PERIOD_MS, 0U, Task_Key_Scan},
    {TASK_FOLLOW_PERIOD_MS,   0U, Task_Follow_Mode},   /* 【跟随测试模式】不要了删这一行 */
    {TASK_TAIL_PERIOD_MS,     0U, Task_Tail},
    {TASK_LED_PERIOD_MS,      0U, Task_LED},
    {TASK_LCD_PERIOD_MS,      0U, Task_UWB_Display},
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
