#include "uwb.h"

#include <string.h>

#include "main.h"
#include "usart.h"

#define UWB_FRAME_MAX_LENGTH  (64U)
#define UWB_RX_RING_SIZE      (512U)   /* 每路 1.5 KB/s, 刷屏阻塞 100 ms 也不会溢出 */
#define UWB_RX_RING_MASK      (UWB_RX_RING_SIZE - 1U)

#if ((UWB_RX_RING_SIZE & UWB_RX_RING_MASK) != 0U)
#error "UWB_RX_RING_SIZE must be a power of two"
#endif

typedef struct {
    uint8_t bytes[UWB_FRAME_MAX_LENGTH];
    uint16_t index;
    uint16_t expected_length;
} UWB_Parser;

typedef struct {
    volatile uint16_t rx_head;
    volatile uint16_t rx_tail;
    uint8_t rx_ring[UWB_RX_RING_SIZE];
    volatile uint32_t rx_byte_count;     /* 串口收到的字节总数 (排查接线用) */
    volatile uint32_t rx_overflow_count;
    volatile uint32_t uart_error_count;
    uint32_t checksum_error_count;
    uint16_t last_length;                /* 最近一个定位帧的长度字段 / 版本号 / 校验 (排查用) */
    uint16_t last_version;
    uint8_t last_xor_rx;
    uint8_t last_xor_calc;
    UWB_Parser parser;
    UWB_Measurement latest;
} UWB_Channel;

static UWB_Channel g_uwb_channels[UWB_ANCHOR_COUNT];

/* 信标在车的哪一边: -1 左, +1 右, 0 还不知道。只由前基站定, 全部基站都收不到时清零。 */
static int8_t   g_uwb_side       = 0;
static int8_t   g_uwb_side_votes = 0;    /* 前基站连续几帧在 ±60° 以内: 正 = 右, 负 = 左 */
static uint32_t g_uwb_side_frame = 0U;   /* 已经数过的前基站帧号 (UWB_GetTarget 一帧会被调好几次) */

/* 左 = USART2 (PA3 收), 前 = UART4 (PC11 收), 右 = UART5 (PD2 收) */
static UART_HandleTypeDef *const g_uwb_uart[UWB_ANCHOR_COUNT] = {
    &huart2,
    &huart4,
    &huart5,
};

static const int16_t g_mount_offset_deg[UWB_ANCHOR_COUNT] = {
    UWB_LEFT_MOUNT_OFFSET_DEG,
    UWB_FORWARD_MOUNT_OFFSET_DEG,
    UWB_RIGHT_MOUNT_OFFSET_DEG,
};

static const int8_t g_angle_sign[UWB_ANCHOR_COUNT] = {
    UWB_LEFT_ANGLE_SIGN,
    UWB_FORWARD_ANGLE_SIGN,
    UWB_RIGHT_ANGLE_SIGN,
};

static uint16_t UWB_ReadBE16(const uint8_t *data)
{
    return (uint16_t) (((uint16_t) data[0] << 8U) | data[1]);
}

static uint32_t UWB_ReadBE32(const uint8_t *data)
{
    return ((uint32_t) data[0] << 24U) |
           ((uint32_t) data[1] << 16U) |
           ((uint32_t) data[2] << 8U) |
           (uint32_t) data[3];
}

static uint16_t UWB_AbsAngle(int16_t angle)
{
    if (angle < 0) {
        return (uint16_t) (-(int32_t) angle);
    }

    return (uint16_t) angle;
}

static int16_t UWB_NormalizeAngle(int32_t angle)
{
    while (angle > 180) {
        angle -= 360;
    }

    while (angle < -180) {
        angle += 360;
    }

    return (int16_t) angle;
}

static void UWB_ResetParser(UWB_Parser *parser)
{
    parser->index           = 0U;
    parser->expected_length = 0U;
}

/* 一帧收齐以后: 记下帧头 (排查用), 只认 0x2001 定位帧, 校验 = 前面所有字节异或。
 * 长度字段和版本号不检查: 规格书里定位帧写版本 0x0100、心跳帧写 0x0101, 本身就对不上,
 * 厂家自己的 STM32 例程 (示例代码/STM32F1-Usart) 也只看帧头 + 命令码。 */
static void UWB_DecodeFrame(
    UWB_Anchor source, const uint8_t *frame, uint16_t length, uint32_t now_ms)
{
    UWB_Channel *channel = &g_uwb_channels[source];
    UWB_Measurement *measurement = &channel->latest;
    uint8_t checksum = 0U;
    uint16_t i;

    if (UWB_ReadBE16(&frame[8]) != UWB_LOCATION_COMMAND) {
        return;     /* 0x2002 心跳帧 (信标不在线时 2 秒一次) */
    }

    for (i = 0U; i < (length - 1U); i++) {
        checksum ^= frame[i];
    }

    channel->last_length   = UWB_ReadBE16(&frame[4]);
    channel->last_version  = UWB_ReadBE16(&frame[10]);
    channel->last_xor_rx   = frame[length - 1U];
    channel->last_xor_calc = checksum;

    if (checksum != frame[length - 1U]) {
        channel->checksum_error_count++;
        return;
    }

    measurement->source         = source;
    measurement->sequence_id    = UWB_ReadBE16(&frame[6]);
    measurement->anchor_id      = UWB_ReadBE32(&frame[12]);
    measurement->tag_id         = UWB_ReadBE32(&frame[16]);
    measurement->distance_cm    = UWB_ReadBE32(&frame[20]);
    measurement->azimuth_deg    = (int16_t) (g_angle_sign[source] *
                                             (int16_t) UWB_ReadBE16(&frame[24]));   /* 正负号见 uwb.h */
    measurement->tag_status     = UWB_ReadBE16(&frame[28]);
    measurement->update_time_ms = now_ms;
    measurement->frame_count++;
    measurement->valid          = true;
}

/* 逐字节找帧: 4 个 0xFF 开头; 收到第 10 个字节 (命令码齐了) 时按命令码定帧长 (和厂家例程一样,
 * 不信长度字段): 0x2001 定位帧 37 字节, 0x2002 心跳帧 16 字节, 别的命令码丢掉重新找帧头。 */
static void UWB_ParseByte(UWB_Anchor source, uint8_t data, uint32_t now_ms)
{
    UWB_Parser *parser = &g_uwb_channels[source].parser;
    uint16_t command;

    if (parser->index < 4U) {
        if (data == 0xFFU) {
            parser->bytes[parser->index++] = data;
        } else {
            UWB_ResetParser(parser);
        }
        return;
    }

    /* 帧头前面多了个 0xFF (比如上一帧的校验字节正好是 FF): 长度高字节不会是 FF, 往后错一位 */
    if ((parser->index == 4U) && (data == 0xFFU)) {
        return;
    }

    parser->bytes[parser->index++] = data;

    if (parser->index == 10U) {
        command = UWB_ReadBE16(&parser->bytes[8]);

        if (command == UWB_LOCATION_COMMAND) {
            parser->expected_length = UWB_LOCATION_FRAME_LENGTH;
        } else if (command == UWB_HEARTBEAT_COMMAND) {
            parser->expected_length = UWB_HEARTBEAT_FRAME_LENGTH;
        } else {
            UWB_ResetParser(parser);
            return;
        }
    }

    if ((parser->expected_length != 0U) &&
        (parser->index == parser->expected_length)) {
        UWB_DecodeFrame(source, parser->bytes, parser->expected_length, now_ms);
        UWB_ResetParser(parser);
    }
}

static void UWB_PushRxByte(UWB_Anchor source, uint8_t data)
{
    UWB_Channel *channel = &g_uwb_channels[source];
    uint16_t head = channel->rx_head;
    uint16_t next = (uint16_t) ((head + 1U) & UWB_RX_RING_MASK);

    if (next == channel->rx_tail) {
        channel->rx_overflow_count++;
        return;
    }

    channel->rx_ring[head] = data;
    channel->rx_head       = next;
}

/* 三个 UWB 串口不走 HAL 的中断流程: stm32f1xx_it.c 的 USART2 / UART4 / UART5 中断
 * 一进来就调 UWB_IRQHandler() 然后直接返回。这里只打开"收到字节"中断(RXNEIE),
 * 溢出(ORE)也会经它报上来。 */
void UWB_Init(void)
{
    uint32_t source;

    memset(g_uwb_channels, 0, sizeof(g_uwb_channels));

    for (source = 0U; source < (uint32_t) UWB_ANCHOR_COUNT; source++) {
        USART_TypeDef *uart = g_uwb_uart[source]->Instance;

        (void) uart->SR;    /* 读 SR 再读 DR = 清掉上电时残留的字节和错误标志 */
        (void) uart->DR;
        __HAL_UART_ENABLE_IT(g_uwb_uart[source], UART_IT_RXNE);
    }
}

void UWB_Process(uint32_t now_ms)
{
    uint32_t source;

    for (source = 0U; source < (uint32_t) UWB_ANCHOR_COUNT; source++) {
        UWB_Channel *channel = &g_uwb_channels[source];

        while (channel->rx_tail != channel->rx_head) {
            uint16_t tail = channel->rx_tail;
            uint8_t data  = channel->rx_ring[tail];

            channel->rx_tail = (uint16_t) ((tail + 1U) & UWB_RX_RING_MASK);
            UWB_ParseByte((UWB_Anchor) source, data, now_ms);
        }
    }
}

bool UWB_GetMeasurement(UWB_Anchor source, UWB_Measurement *measurement)
{
    if ((measurement == NULL) || (source < UWB_ANCHOR_LEFT) ||
        (source >= UWB_ANCHOR_COUNT)) {
        return false;
    }

    *measurement = g_uwb_channels[source].latest;
    return measurement->valid;
}

static const UWB_Measurement *UWB_FreshOrNull(UWB_Anchor source, uint32_t now_ms)
{
    const UWB_Measurement *measurement = &g_uwb_channels[source].latest;

    if (!measurement->valid ||
        ((uint32_t) (now_ms - measurement->update_time_ms) > UWB_DATA_TIMEOUT_MS)) {
        return NULL;
    }

    return measurement;
}

/* 三个基站合成一个方向 (车体角: 左负右正, 0 = 正前方)。
 *
 * 每个基站只有两根天线 (相位差测角), 分不清信号从它前面还是背后来: 背后来的会镜像到前面
 * (背后偏 30° 读成前面偏 30°), 规格书说的"约 180° 都能测到"里一半是镜像。于是:
 *   左、右基站: 背靠背装, 只测得出信标"偏离车头多少度", 分不出在左还是在右。
 *     信标在右前 60° 时, 左基站从背后收到, 镜像后换成车体角正好是"左前 60°", 和右基站的读数
 *     离各自正前方一样近 —— 以前"选离自己正前方最近的基站"会时不时选中它, 屏幕就显示 left。
 *   前基站: 分得出左右 (分不清前后)。
 * 所以:
 *   1. 左右 (正负号) 只听前基站: 连续 UWB_SIDE_CONFIRM_FRAMES 帧在 ±UWB_SIDE_TRUST_DEG 以内、
 *      同一边才换边; 再往外前基站在测角边缘, 读数可能跳到另一边, 沿用上一次的左右
 *      (信标要换边只能经过正前 / 正后, 那时前基站读数小, 一定会更新)。
 *   2. 偏多少度: 前基站和"信标那一侧"的侧基站 (正对着信标; 它没数据才用另一侧的镜像读数),
 *      谁的读数离自己正前方近就用谁 (天线正前方测角最准)。用前基站时角度就是它的读数。
 * 一开始就收不到前基站时没法分左右, 按以前的办法猜 (离正前方近的那个侧基站在哪边就算哪边)。
 * 正后方 135° 以外前基站读数最小、又分不清前后, 会被当成正前方 (两根天线的物理限制)。 */
bool UWB_GetTarget(uint32_t now_ms, UWB_Target *target)
{
    const UWB_Measurement *forward = UWB_FreshOrNull(UWB_ANCHOR_FORWARD, now_ms);
    const UWB_Measurement *left    = UWB_FreshOrNull(UWB_ANCHOR_LEFT, now_ms);
    const UWB_Measurement *right   = UWB_FreshOrNull(UWB_ANCHOR_RIGHT, now_ms);
    const UWB_Measurement *side_anchor;
    const UWB_Measurement *best;
    uint16_t forward_error = 0U;
    int8_t side;
    int16_t azimuth;

    if (target == NULL) {
        return false;
    }

    memset(target, 0, sizeof(*target));

    if ((forward == NULL) && (left == NULL) && (right == NULL)) {
        g_uwb_side       = 0;
        g_uwb_side_votes = 0;
        return false;
    }

    /* 1. 左右 */
    if (forward != NULL) {
        forward_error = UWB_AbsAngle(forward->azimuth_deg);
    }

    if ((forward != NULL) && (forward->frame_count != g_uwb_side_frame)) {
        int8_t sign = (forward->azimuth_deg < 0) ? -1 : 1;

        g_uwb_side_frame = forward->frame_count;

        if (forward_error > UWB_SIDE_TRUST_DEG) {
            g_uwb_side_votes = 0;                   /* 测角边缘, 这帧不算, 连续也断了 */
            if (g_uwb_side == 0) {
                g_uwb_side = sign;                  /* 一开始信标就在侧面: 先按它猜 */
            }
        } else if (forward->azimuth_deg != 0) {
            if ((g_uwb_side_votes * sign) <= 0) {
                g_uwb_side_votes = 0;               /* 换了一边, 重新数 */
            }
            if ((g_uwb_side_votes * sign) < UWB_SIDE_CONFIRM_FRAMES) {
                g_uwb_side_votes = (int8_t) (g_uwb_side_votes + sign);
            }
            if ((g_uwb_side == 0) ||
                ((g_uwb_side_votes * sign) >= UWB_SIDE_CONFIRM_FRAMES)) {
                g_uwb_side = sign;
            }
        }
    }

    side = g_uwb_side;
    if (side == 0) {
        side = ((right == NULL) ||
                ((left != NULL) &&
                 (UWB_AbsAngle(left->azimuth_deg) < UWB_AbsAngle(right->azimuth_deg)))) ? -1 : 1;
    }

    /* ── 曾经尝试(方案一：左右基站距离差判左右, 已撤回) ─────────────────────
     * 左右基站横向间距约 10 cm, 距离差远小于 UWB 测距误差, 效果不佳。
     * 代码留档于此, 不参与编译:
#if 0
    if ((left != NULL) && (right != NULL)) {
        int32_t dist_diff = (int32_t)left->distance_cm - (int32_t)right->distance_cm;
        if (dist_diff < -(int32_t)UWB_SIDE_DIST_MARGIN_CM)      { g_uwb_side = -1; }
        else if (dist_diff > (int32_t)UWB_SIDE_DIST_MARGIN_CM)  { g_uwb_side =  1; }
    } else if (left  != NULL) { g_uwb_side = -1; }
    else if (right != NULL) { g_uwb_side =  1; }
    else if ((forward != NULL) && (forward->azimuth_deg != 0) && (forward_error <= 60U)) {
        g_uwb_side = (forward->azimuth_deg < 0) ? -1 : 1;
    }
    side = g_uwb_side;
    if (side == 0) {
        side = ((right == NULL) ||
                ((left != NULL) &&
                 (UWB_AbsAngle(left->azimuth_deg) < UWB_AbsAngle(right->azimuth_deg)))) ? -1 : 1;
    }
#endif
     ──────────────────────────────────────────────────────────────────── */

    /* 2. 偏多少度 */
    if (side < 0) {
        side_anchor = (left != NULL) ? left : right;
    } else {
        side_anchor = (right != NULL) ? right : left;
    }

    if ((forward != NULL) &&
        ((side_anchor == NULL) || (forward_error <= UWB_AbsAngle(side_anchor->azimuth_deg)))) {
        best    = forward;
        azimuth = forward->azimuth_deg;
    } else {
        /* 侧基站: 读数 + 安装角的绝对值 = 偏离车头多少度 (镜像读数也对), 正负号用第 1 步的 */
        best    = side_anchor;
        azimuth = (int16_t) UWB_AbsAngle(UWB_NormalizeAngle(
            (int32_t) side_anchor->azimuth_deg + g_mount_offset_deg[side_anchor->source]));
        if (side < 0) {
            azimuth = (int16_t) -azimuth;
        }
    }

    target->valid                = true;
    target->source               = best->source;
    target->anchor_id            = best->anchor_id;
    target->tag_id               = best->tag_id;
    target->distance_cm          = best->distance_cm;
    target->source_azimuth_deg   = best->azimuth_deg;
    target->azimuth_deg          = azimuth;
    target->update_time_ms       = best->update_time_ms;

    return true;
}

void UWB_GetStats(UWB_Anchor source, UWB_Stats *stats)
{
    const UWB_Channel *channel;

    if ((stats == NULL) || ((uint32_t) source >= (uint32_t) UWB_ANCHOR_COUNT)) {
        return;
    }

    channel = &g_uwb_channels[source];
    stats->rx_bytes        = channel->rx_byte_count;
    stats->frames          = channel->latest.frame_count;
    stats->checksum_errors = channel->checksum_error_count;
    stats->uart_errors     = channel->uart_error_count;
    stats->overflows       = channel->rx_overflow_count;
    stats->last_length     = channel->last_length;
    stats->last_version    = channel->last_version;
    stats->last_xor_rx     = channel->last_xor_rx;
    stats->last_xor_calc   = channel->last_xor_calc;
}

uint32_t UWB_GetFrameCount(void)
{
    uint32_t source;
    uint32_t total = 0U;

    for (source = 0U; source < (uint32_t) UWB_ANCHOR_COUNT; source++) {
        total += g_uwb_channels[source].latest.frame_count;
    }

    return total;
}

/* 中断只把字节塞进环形缓冲, 解析在 Task_UWB_Poll 里做。
 * F1 的串口: 先读 SR 再读 DR 就把 RXNE 和 ORE/NE/FE/PE 一起清掉。 */
void UWB_IRQHandler(UWB_Anchor source)
{
    USART_TypeDef *uart;
    uint32_t status;
    uint8_t data;

    if ((uint32_t) source >= (uint32_t) UWB_ANCHOR_COUNT) {
        return;
    }

    uart   = g_uwb_uart[source]->Instance;
    status = uart->SR;

    if ((status & (USART_SR_RXNE | USART_SR_ORE | USART_SR_NE |
                   USART_SR_FE | USART_SR_PE)) == 0U) {
        return;
    }

    data = (uint8_t) uart->DR;

    if ((status & (USART_SR_ORE | USART_SR_NE | USART_SR_FE | USART_SR_PE)) != 0U) {
        g_uwb_channels[source].uart_error_count++;
    }

    if ((status & USART_SR_RXNE) != 0U) {
        g_uwb_channels[source].rx_byte_count++;
        UWB_PushRxByte(source, data);
    }
}
