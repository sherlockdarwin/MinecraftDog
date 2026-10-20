#include "stepper.h"

#include "main.h"
#include "usart.h"

#define STEPPER_TX_TIMEOUT_MS  (10U)

volatile uint8_t  g_stepper_reply[STEPPER_REPLY_MAX];
volatile uint8_t  g_stepper_reply_len   = 0U;
volatile uint32_t g_stepper_reply_count = 0U;
volatile uint32_t g_stepper_tx_count    = 0U;

/* 中断里攒的半条应答 */
static uint8_t s_rx_frame[STEPPER_REPLY_MAX];
static uint8_t s_rx_len = 0U;

void Stepper_Init(void)
{
    (void) USART1->SR;      /* 读 SR 再读 DR = 清掉上电时残留的字节和错误标志 */
    (void) USART1->DR;
    s_rx_len = 0U;
    __HAL_UART_ENABLE_IT(&huart1, UART_IT_RXNE);
}

/* 收到 0x6B 就算一条应答结束; 太长还没等到 0x6B 就丢掉重来。 */
void Stepper_IRQHandler(void)
{
    uint32_t status = USART1->SR;
    uint8_t data;
    uint8_t i;

    if ((status & (USART_SR_RXNE | USART_SR_ORE | USART_SR_NE |
                   USART_SR_FE | USART_SR_PE)) == 0U) {
        return;
    }

    data = (uint8_t) USART1->DR;
    if ((status & USART_SR_RXNE) == 0U) {
        return;
    }

    if (s_rx_len >= STEPPER_REPLY_MAX) {
        s_rx_len = 0U;
    }
    s_rx_frame[s_rx_len++] = data;

    if (data == STEPPER_CHECK_BYTE) {
        for (i = 0U; i < s_rx_len; i++) {
            g_stepper_reply[i] = s_rx_frame[i];
        }
        g_stepper_reply_len = s_rx_len;
        g_stepper_reply_count++;
        s_rx_len = 0U;
    }
}

uint8_t Stepper_SendArray(const uint8_t *arr, uint16_t len)
{
    if (arr == 0) {
        return 0U;
    }

    if (HAL_UART_Transmit(&huart1, (uint8_t *) arr, len, STEPPER_TX_TIMEOUT_MS) != HAL_OK) {
        return 0U;
    }

    g_stepper_tx_count++;
    return 1U;
}

uint8_t Stepper_EnableEx(uint8_t addr, uint8_t enable, uint8_t sync)
{
    uint8_t cmd[6];

    cmd[0] = addr;
    cmd[1] = 0xF3U;
    cmd[2] = 0xABU;
    cmd[3] = (enable != 0U) ? 1U : 0U;
    cmd[4] = (sync != 0U) ? 1U : 0U;
    cmd[5] = STEPPER_CHECK_BYTE;
    return Stepper_SendArray(cmd, sizeof(cmd));
}

uint8_t Stepper_SpeedEx(uint8_t addr, Stepper_Dir_t dir, uint16_t rpm, uint8_t acc, uint8_t sync)
{
    uint8_t cmd[8];

    cmd[0] = addr;
    cmd[1] = 0xF6U;
    cmd[2] = (uint8_t) dir;
    cmd[3] = (uint8_t) (rpm >> 8);
    cmd[4] = (uint8_t) rpm;
    cmd[5] = acc;
    cmd[6] = (sync != 0U) ? 1U : 0U;
    cmd[7] = STEPPER_CHECK_BYTE;
    return Stepper_SendArray(cmd, sizeof(cmd));
}

/* acc = 0: 不用曲线, 直接按 rpm 启动; acc != 0: 每 (256 - acc) × 50 us 加/减 1 RPM (手册 5.3.12)。 */
uint8_t Stepper_PositionEx(uint8_t addr, Stepper_Dir_t dir, uint16_t rpm, uint8_t acc,
                           uint32_t pulses, Stepper_PosMode_t mode, uint8_t sync)
{
    uint8_t cmd[13];

    cmd[0]  = addr;
    cmd[1]  = 0xFDU;
    cmd[2]  = (uint8_t) dir;
    cmd[3]  = (uint8_t) (rpm >> 8);
    cmd[4]  = (uint8_t) rpm;
    cmd[5]  = acc;
    cmd[6]  = (uint8_t) (pulses >> 24);
    cmd[7]  = (uint8_t) (pulses >> 16);
    cmd[8]  = (uint8_t) (pulses >> 8);
    cmd[9]  = (uint8_t) pulses;
    cmd[10] = (uint8_t) mode;
    cmd[11] = (sync != 0U) ? 1U : 0U;
    cmd[12] = STEPPER_CHECK_BYTE;
    return Stepper_SendArray(cmd, sizeof(cmd));
}

uint8_t Stepper_StopEx(uint8_t addr, uint8_t sync)
{
    uint8_t cmd[5];

    cmd[0] = addr;
    cmd[1] = 0xFEU;
    cmd[2] = 0x98U;
    cmd[3] = (sync != 0U) ? 1U : 0U;
    cmd[4] = STEPPER_CHECK_BYTE;
    return Stepper_SendArray(cmd, sizeof(cmd));
}

/* 把当前位置设为坐标零点 (手册 5.2.3: 01 0A 6D 6B, 正确返回 01 0A 02 6B)。 */
uint8_t Stepper_ResetCurrentPosition(uint8_t addr)
{
    uint8_t cmd[4];

    cmd[0] = addr;
    cmd[1] = 0x0AU;
    cmd[2] = 0x6DU;
    cmd[3] = STEPPER_CHECK_BYTE;
    return Stepper_SendArray(cmd, sizeof(cmd));
}

/* 解除堵转/过热/过流保护。出厂"堵转保护"是堵转后关闭电机, 不解除就一直松轴。
 * 和官方例程 Emm_V5_Reset_Clog_Pro() 逐字节一致: {addr, 0x0E, 0x52, 0x6B}。 */
uint8_t Stepper_ClearProtection(uint8_t addr)
{
    uint8_t cmd[4];

    cmd[0] = addr;
    cmd[1] = 0x0EU;
    cmd[2] = 0x52U;
    cmd[3] = STEPPER_CHECK_BYTE;
    return Stepper_SendArray(cmd, sizeof(cmd));
}

/* 把当前位置设为"单圈回零零点" (手册 5.4.1: 01 93 88 01 6B), save = 1 掉电不丢。 */
uint8_t Stepper_SetOrigin(uint8_t addr, uint8_t save)
{
    uint8_t cmd[5];

    cmd[0] = addr;
    cmd[1] = 0x93U;
    cmd[2] = 0x88U;
    cmd[3] = (save != 0U) ? 1U : 0U;
    cmd[4] = STEPPER_CHECK_BYTE;
    return Stepper_SendArray(cmd, sizeof(cmd));
}

/* 触发回零 (手册 5.4.2: 01 9A 00 00 6B = 单圈就近回零)。 */
uint8_t Stepper_TriggerOrigin(uint8_t addr, Stepper_OriginMode_t mode, uint8_t sync)
{
    uint8_t cmd[5];

    cmd[0] = addr;
    cmd[1] = 0x9AU;
    cmd[2] = (uint8_t) mode;
    cmd[3] = (sync != 0U) ? 1U : 0U;
    cmd[4] = STEPPER_CHECK_BYTE;
    return Stepper_SendArray(cmd, sizeof(cmd));
}
