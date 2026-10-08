#include "fpgamlk.h"

#include "main.h"
#include "usart.h"

/* ==========================================================================
 *  FPGA -> STM32 解包结果。只在主循环(FPGAMLK_Poll)里写, 别的文件直接读。
 * ========================================================================== */
volatile int16_t  g_fpga_left_pwm    = 0;   /* 左轮命令, 正=前进, -8000 ~ +8000 */
volatile int16_t  g_fpga_right_pwm   = 0;   /* 右轮命令, 同上 */
volatile uint8_t  g_fpga_stop        = 1U;  /* 1 = 最近一帧是 "#S*"; 上电还没收到帧也算停 */
volatile uint8_t  g_fpga_new_frame   = 0U;  /* 收到完整帧置 1, FPGAMLK_TakeUpdate() 清 0 */
volatile uint32_t g_fpga_last_ms     = 0U;  /* 最近一个完整帧的时刻(Get_Time) */
volatile uint32_t g_fpga_frame_count = 0U;  /* 累计完整帧数 */
volatile uint32_t g_fpga_error_count = 0U;  /* 格式不对、整帧丢掉的次数 */
volatile uint32_t g_fpga_uart_error_count = 0U; /* 串口硬件错误(帧错/噪声/溢出)次数, 每次都会重启接收 DMA */

/* ==========================================================================
 *  STM32 -> FPGA 最近发出去的内容(调试看)。
 * ========================================================================== */
volatile uint8_t  g_fpga_uwb_lost       = 1U;  /* 1 = 最近发的是 "$S&" (收不到 UWB) */
volatile int16_t  g_fpga_tx_angle_deg   = 0;   /* 最近发出的角度, 左负右正, ±99 */
volatile uint16_t g_fpga_tx_distance_cm = 0U;  /* 最近发出的距离, 0 ~ 999 */
volatile uint32_t g_fpga_tx_count       = 0U;  /* 累计发出的帧数(含 "$S&") */

/* ---- 收: DMA 环形缓冲 ----
 * USART3_RX 的 DMA (DMA1 通道 3) 在 CubeMX 里是 Circular 模式: 每来一个字节搬一个,
 * CNDTR 减到 0 时硬件自动重装, 通道不停 —— 缓冲就成了硬件维护的环,
 *     写指针 wr = SIZE - __HAL_DMA_GET_COUNTER()
 * CPU 在 FPGAMLK_Poll() 里把读指针追到 wr。
 * FPGA 每 20 ms 发 12 字节, 256 字节约 400 ms 的量; 就算 115200 满速灌也要 22 ms 才
 * 绕一圈, 5 ms 读一次留了 4 倍余量。环形缓冲分不出"空"和"正好绕满一圈", 所以别把
 * Poll 周期调大。
 * 依赖 CubeMX 的两个设置(改了不报错, 只会静默收不到):
 *   USART3_RX DMA Mode = Circular    (否则搬满一圈 DMA 就停了)
 *   USART3 global interrupt 打开     (HAL 的 DMA 发送靠它结束; 串口出错也靠它报告)
 *
 * 串口出错(FPGA 上下电时的毛刺 = 帧错 / 噪声)时, HAL 会把接收 DMA 停掉再调
 * HAL_UART_ErrorCallback()。那里只置标志, FPGAMLK_Poll() 看到标志就重启接收。 */
#define FPGAMLK_RX_BUF_SIZE  (256U)

/* "#" 和 "*" 之间最多 10 个字符: "+3000-0500" */
#define FPGAMLK_FRAME_MAX    (10U)

/* "$l12350&" 8 字节, 留点余量 */
#define FPGAMLK_TX_BUF_SIZE  (16U)

static volatile uint8_t s_rx_dma_buf[FPGAMLK_RX_BUF_SIZE];
static uint16_t s_rx_rd = 0U;
static volatile uint8_t s_rx_restart = 0U;

static uint8_t s_frame[FPGAMLK_FRAME_MAX];
static uint8_t s_frame_len = 0U;
static uint8_t s_in_frame  = 0U;

/* 发送缓冲: DMA 发的时候在读它, 所以只在上一帧发完(串口 READY)时才能改。 */
static uint8_t s_tx_buf[FPGAMLK_TX_BUF_SIZE];

/* "+3000" 这样的 5 个字符 -> 带符号整数, 超过满量程按满量程。格式不对返回 false。 */
static bool FPGAMLK_ParseWheel(const uint8_t *text, int16_t *value)
{
    int32_t magnitude = 0;
    uint8_t i;

    if ((text[0] != '+') && (text[0] != '-')) {
        return false;
    }

    for (i = 1U; i <= 4U; i++) {
        if ((text[i] < '0') || (text[i] > '9')) {
            return false;
        }
        magnitude = (magnitude * 10) + (int32_t) (text[i] - '0');
    }

    if (magnitude > FPGAMLK_PWM_LIMIT) {
        magnitude = FPGAMLK_PWM_LIMIT;
    }

    *value = (int16_t) ((text[0] == '-') ? -magnitude : magnitude);
    return true;
}

/* 收到 '*' 时检查 '#' 之后攒下的字符: "S" 或 "+dddd+dddd", 其它整帧丢掉。 */
static void FPGAMLK_DecodeFrame(uint32_t now_ms)
{
    int16_t left;
    int16_t right;

    if ((s_frame_len == 1U) && ((s_frame[0] == 'S') || (s_frame[0] == 's'))) {
        g_fpga_left_pwm  = 0;
        g_fpga_right_pwm = 0;
        g_fpga_stop      = 1U;
    } else if ((s_frame_len == FPGAMLK_FRAME_MAX) &&
               FPGAMLK_ParseWheel(&s_frame[0], &left) &&
               FPGAMLK_ParseWheel(&s_frame[5], &right)) {
        g_fpga_left_pwm  = left;
        g_fpga_right_pwm = right;
        g_fpga_stop      = 0U;
    } else {
        g_fpga_error_count++;
        return;
    }

    g_fpga_last_ms   = now_ms;
    g_fpga_new_frame = 1U;
    g_fpga_frame_count++;
}

/* 逐字节状态机: '#' 任何时候都重新开始一帧; 帧外的字节丢掉; 太长没等到 '*' 也丢掉。 */
static void FPGAMLK_ParseByte(uint8_t data, uint32_t now_ms)
{
    if (data == '#') {
        if (s_in_frame) {
            g_fpga_error_count++;   /* 上一帧没收完就来了新帧头 */
        }
        s_in_frame  = 1U;
        s_frame_len = 0U;
        return;
    }

    if (!s_in_frame) {
        return;
    }

    if (data == '*') {
        s_in_frame = 0U;
        FPGAMLK_DecodeFrame(now_ms);
        return;
    }

    if (s_frame_len >= FPGAMLK_FRAME_MAX) {
        s_in_frame = 0U;
        g_fpga_error_count++;
        return;
    }

    s_frame[s_frame_len++] = data;
}

/* (重新)开始环形接收: DMA 从缓冲开头写起, 读指针和半截帧一起清掉。 */
static void FPGAMLK_StartRxDMA(void)
{
    HAL_UART_AbortReceive(&huart3);

    s_rx_rd     = 0U;
    s_in_frame  = 0U;
    s_frame_len = 0U;

    HAL_UART_Receive_DMA(&huart3, (uint8_t *) s_rx_dma_buf, FPGAMLK_RX_BUF_SIZE);
}

/* 开 DMA 后 USART3 的发送请求立刻生效, 一个字节一个字节往 TDR 里搬; 搬完后
 * USART3 中断把串口状态改回 READY (FPGAMLK_TxBusy 看的就是它)。 */
static void FPGAMLK_StartTxDMA(uint16_t length)
{
    if (HAL_UART_Transmit_DMA(&huart3, s_tx_buf, length) == HAL_OK) {
        g_fpga_tx_count++;
    }
}

void FPGAMLK_Init(void)
{
    g_fpga_left_pwm    = 0;
    g_fpga_right_pwm   = 0;
    g_fpga_stop        = 1U;
    g_fpga_new_frame   = 0U;
    g_fpga_last_ms     = 0U;
    g_fpga_frame_count = 0U;
    g_fpga_error_count = 0U;
    g_fpga_uart_error_count = 0U;

    g_fpga_uwb_lost       = 1U;
    g_fpga_tx_angle_deg   = 0;
    g_fpga_tx_distance_cm = 0U;
    g_fpga_tx_count       = 0U;

    s_rx_restart = 0U;
    FPGAMLK_StartRxDMA();
}

void FPGAMLK_Poll(uint32_t now_ms)
{
    uint16_t wr;

    if (s_rx_restart) {
        s_rx_restart = 0U;
        FPGAMLK_StartRxDMA();
        return;
    }

    /* CNDTR 归零到硬件重装之间的一瞬读到 0, 算出 wr == SIZE = "刚好写满一圈",
     * 下一个字节落回 0, 所以夹成 0 正好对。 */
    wr = (uint16_t) (FPGAMLK_RX_BUF_SIZE - __HAL_DMA_GET_COUNTER(huart3.hdmarx));
    if (wr >= FPGAMLK_RX_BUF_SIZE) {
        wr = 0U;
    }

    while (s_rx_rd != wr) {
        FPGAMLK_ParseByte(s_rx_dma_buf[s_rx_rd], now_ms);
        s_rx_rd = (uint16_t) ((s_rx_rd + 1U) % FPGAMLK_RX_BUF_SIZE);
    }
}

bool FPGAMLK_TakeUpdate(void)
{
    if (g_fpga_new_frame == 0U) {
        return false;
    }

    g_fpga_new_frame = 0U;
    return true;
}

bool FPGAMLK_LinkAlive(uint32_t now_ms)
{
    return (g_fpga_frame_count != 0U) &&
           ((uint32_t) (now_ms - g_fpga_last_ms) <= FPGAMLK_LINK_TIMEOUT_MS);
}

bool FPGAMLK_TxBusy(void)
{
    return (huart3.gState != HAL_UART_STATE_READY);
}

bool FPGAMLK_SendTarget(int16_t azimuth_deg, uint32_t distance_cm)
{
    uint16_t angle;
    uint16_t distance;

    if (FPGAMLK_TxBusy()) {
        return false;
    }

    angle = (uint16_t) ((azimuth_deg < 0) ? -(int32_t) azimuth_deg : azimuth_deg);
    if (angle > FPGAMLK_ANGLE_MAX_DEG) {
        angle = FPGAMLK_ANGLE_MAX_DEG;
    }
    distance = (uint16_t) ((distance_cm > FPGAMLK_DIST_MAX_CM) ?
                           FPGAMLK_DIST_MAX_CM : distance_cm);

    s_tx_buf[0] = '$';
    s_tx_buf[1] = (azimuth_deg < 0) ? 'l' : 'r';
    s_tx_buf[2] = (uint8_t) ('0' + (angle / 10U));
    s_tx_buf[3] = (uint8_t) ('0' + (angle % 10U));
    s_tx_buf[4] = (uint8_t) ('0' + (distance / 100U));
    s_tx_buf[5] = (uint8_t) ('0' + ((distance / 10U) % 10U));
    s_tx_buf[6] = (uint8_t) ('0' + (distance % 10U));
    s_tx_buf[7] = '&';
    FPGAMLK_StartTxDMA(8U);

    g_fpga_uwb_lost       = 0U;
    g_fpga_tx_angle_deg   = (int16_t) ((azimuth_deg < 0) ? -(int16_t) angle : (int16_t) angle);
    g_fpga_tx_distance_cm = distance;
    return true;
}

bool FPGAMLK_SendLost(void)
{
    if (FPGAMLK_TxBusy()) {
        return false;
    }

    s_tx_buf[0] = '$';
    s_tx_buf[1] = 'S';
    s_tx_buf[2] = '&';
    FPGAMLK_StartTxDMA(3U);

    g_fpga_uwb_lost = 1U;
    return true;
}

/* HAL 的串口错误回调(全工程只有这一个)。UWB 的三个串口不走 HAL 中断(见 uwb.c),
 * 所以进到这里的只会是 USART3。HAL 已经把接收 DMA 停了, 这里只置标志,
 * 真正重启放在主循环的 FPGAMLK_Poll() 里, 免得和它抢读指针。 */
void HAL_UART_ErrorCallback(UART_HandleTypeDef *huart)
{
    if (huart->Instance == USART3) {
        g_fpga_uart_error_count++;
        s_rx_restart = 1U;
    }
}
