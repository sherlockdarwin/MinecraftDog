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
    UWB_Measurement latest;              /* 最近一帧, 不管有没有效 (屏幕显示) */
    int16_t angle_samples[UWB_MEDIAN_SAMPLES];     /* 最近几帧有效数据, 融合用它们的中值 */
    int16_t distance_samples[UWB_MEDIAN_SAMPLES];
    uint8_t sample_count;
    uint8_t sample_index;
    uint32_t sample_time_ms;             /* 最近一个有效帧的时刻 */
    uint32_t invalid_count;
} UWB_Channel;

/* 融合时看到的一个基站 (UWB_BuildViews 每拍算一次) */
typedef struct {
    bool    fresh;          /* UWB_ANCHOR_STALE_MS 以内有有效帧 */
    bool    usable;         /* fresh, 而且距离和其余基站对得上 */
    int16_t angle_deg;      /* 中值 */
    int16_t angle_min;      /* 中值窗口里最小 / 最大的读数 */
    int16_t angle_max;
    int16_t distance_cm;    /* 中值 */
} UWB_AnchorView;

/* 带回差的二选一 (-1 / +1, 0 = 还不知道), 见 UWB_Propose */
typedef struct {
    int8_t   state;
    int8_t   pending;       /* 想换成什么, 0 = 没有 */
    uint32_t since_ms;      /* 从什么时候开始想换 */
} UWB_Latch;

static UWB_Channel g_uwb_channels[UWB_ANCHOR_COUNT];

/* 融合状态, 全部基站都收不到时清零 */
static UWB_Latch  g_uwb_side;                 /* 信标在车的哪一边: -1 左, +1 右 */
static UWB_Latch  g_uwb_front_rear;           /* 信标在前半圈 +1 / 后半圈 -1 */
static bool       g_uwb_fb_valid    = false;
static int32_t    g_uwb_fb_diff_x16 = 0;      /* 平滑后的前后基站距离差 × 16 (多留 4 位小数) */
static int16_t    g_uwb_front_score = 0;
static uint8_t    g_uwb_anchors_used = 0U;
static bool       g_uwb_jump_pending = false;
static uint32_t   g_uwb_jump_since_ms = 0U;
static UWB_Target g_uwb_target;               /* 融合结果 */
static uint32_t   g_uwb_last_fuse_ms = 0U;
static uint32_t   g_uwb_last_sample_ms = 0U;  /* 任何一个基站最近一个有效帧的时刻 */

static void UWB_ResetFusion(void);

/* 左 = USART2 (PA3 收), 前 = UART4 (PC11 收), 右 = UART5 (PD2 收), 后 = USART1 (PA9 收, 见 UWB_UseBackAnchorPA9) */
static UART_HandleTypeDef *const g_uwb_uart[UWB_ANCHOR_COUNT] = {
    &huart2,
    &huart4,
    &huart5,
    &huart1,
};

static const int16_t g_mount_offset_deg[UWB_ANCHOR_COUNT] = {
    UWB_LEFT_MOUNT_OFFSET_DEG,
    UWB_FORWARD_MOUNT_OFFSET_DEG,
    UWB_RIGHT_MOUNT_OFFSET_DEG,
    UWB_BACK_MOUNT_OFFSET_DEG,
};

static const int8_t g_angle_sign[UWB_ANCHOR_COUNT] = {
    UWB_LEFT_ANGLE_SIGN,
    UWB_FORWARD_ANGLE_SIGN,
    UWB_RIGHT_ANGLE_SIGN,
    UWB_BACK_ANGLE_SIGN,
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

/* 从小到大排序 (最多 5 个数, 插入排序就够了) */
static void UWB_Sort(int16_t *values, uint8_t count)
{
    uint8_t i;

    for (i = 1U; i < count; i++) {
        int16_t value = values[i];
        uint8_t j = i;

        while ((j > 0U) && (values[j - 1U] > value)) {
            values[j] = values[j - 1U];
            j--;
        }
        values[j] = value;
    }
}

/* sorted 放排好序的结果, 返回中值 */
static int16_t UWB_Median(const int16_t *values, uint8_t count, int16_t *sorted)
{
    memcpy(sorted, values, (size_t) count * sizeof(sorted[0]));
    UWB_Sort(sorted, count);
    return sorted[count / 2U];
}

/* 一帧校验通过后: 超范围的不进融合 (屏幕上照样显示读数, 方便看到底发来了什么); 断过的话旧样本作废。 */
static void UWB_PushSample(UWB_Channel *channel, uint32_t now_ms)
{
    const UWB_Measurement *measurement = &channel->latest;

    if ((UWB_AbsAngle(measurement->azimuth_deg) > UWB_ANGLE_VALID_DEG) ||
        (measurement->distance_cm == 0U) ||
        (measurement->distance_cm > UWB_RANGE_VALID_MAX_CM)) {
        channel->invalid_count++;
        return;
    }

    if ((uint32_t) (now_ms - channel->sample_time_ms) > UWB_ANCHOR_STALE_MS) {
        channel->sample_count = 0U;
        channel->sample_index = 0U;
    }

    channel->angle_samples[channel->sample_index]    = measurement->azimuth_deg;
    channel->distance_samples[channel->sample_index] = (int16_t) measurement->distance_cm;
    channel->sample_index = (uint8_t) ((channel->sample_index + 1U) % UWB_MEDIAN_SAMPLES);
    if (channel->sample_count < UWB_MEDIAN_SAMPLES) {
        channel->sample_count++;
    }
    channel->sample_time_ms = now_ms;
    g_uwb_last_sample_ms    = now_ms;
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
    measurement->azimuth_deg    = UWB_NormalizeAngle((int32_t) g_angle_sign[source] *
                                                     (int16_t) UWB_ReadBE16(&frame[24]));   /* 正负号见 uwb.h */
    measurement->tag_status     = UWB_ReadBE16(&frame[28]);
    measurement->update_time_ms = now_ms;
    measurement->frame_count++;
    measurement->valid          = true;

    UWB_PushSample(channel, now_ms);
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

/* 后基站接 PA9, 不接 PA10: 板子上有东西一直把 PA10 拉高 (2026-11-01 用 ST-Link 实测: 拔掉线、内部下拉
 * 也读到高), 基站 TX 压不过它, 一个字节都收不到。PA9 只是弱上拉, 基站拉得动。所以 USART1 用单线模式
 * (HDSEL): 接收走 TX 脚, 不发送。HDSEL 要在 UE = 0 时改; PA9 要放开成输入, 否则 TX 推挽输出会顶着基站。
 * CubeMX 里 USART1 还是 Asynchronous, 放在这里切, 重新生成代码不会被盖掉。 */
static void UWB_UseBackAnchorPA9(void)
{
    GPIO_InitTypeDef gpio = {0};

    gpio.Pin  = UWB_B_U1TX_Pin;
    gpio.Mode = GPIO_MODE_INPUT;
    gpio.Pull = GPIO_PULLUP;
    HAL_GPIO_Init(UWB_B_U1TX_GPIO_Port, &gpio);

    __HAL_UART_DISABLE(&huart1);
    CLEAR_BIT(USART1->CR1, USART_CR1_TE);
    SET_BIT(USART1->CR3, USART_CR3_HDSEL);
    __HAL_UART_ENABLE(&huart1);
}

/* 四个 UWB 串口不走 HAL 的中断流程: stm32f1xx_it.c 的 USART1 / USART2 / UART4 / UART5 中断
 * 一进来就调 UWB_IRQHandler() 然后直接返回。这里只打开"收到字节"中断(RXNEIE),
 * 溢出(ORE)也会经它报上来。 */
void UWB_Init(void)
{
    uint32_t source;

    memset(g_uwb_channels, 0, sizeof(g_uwb_channels));
    UWB_ResetFusion();
    UWB_UseBackAnchorPA9();

    for (source = 0U; source < (uint32_t) UWB_ANCHOR_COUNT; source++) {
        USART_TypeDef *uart = g_uwb_uart[source]->Instance;

        (void) uart->SR;    /* 读 SR 再读 DR = 清掉上电时残留的字节和错误标志 */
        (void) uart->DR;
        __HAL_UART_ENABLE_IT(g_uwb_uart[source], UART_IT_RXNE);
    }
}

/* 四个基站合成一个方向 (车体角: 左负右正, 0 = 正前方, ±180 = 正后方)。
 *
 * 每个基站靠相位差测角, 读数的 sin 是信标方向在它"天线轴"(和正对方向垂直)上的投影, 信标跑到基站
 * 背面也一样, 所以背后的信号会镜像到前面 (背后偏 30° 读成前面偏 30°)。设信标车体角为 θ:
 *     前基站  sin(读数) =  sin θ        后基站  sin(读数) = -sin θ
 *     左基站  sin(读数) =  cos θ        右基站  sin(读数) = -cos θ
 * 也就是说: 前、后基站的正负号管左右, 分不清前后 (θ 和 180° - θ 读数一样, 大小也一样);
 *           左、右基站的正负号管前后, 分不清左右 (θ 和 -θ 读数一样)。
 * 以前 3 个基站时正后方的信标在前基站上读数很小, "选读数最小的基站"就选中它, 当成正前方。现在:
 *   1. 前后 (UWB_UpdateFrontRear): 前后基站相距 36 cm, 距离差 = -36 × cos θ, 正好在 θ 接近 0° / 180°、
 *      左右基站到了测角边缘的时候最大; θ 接近 ±90° 时反过来, 距离差没用, 左右基站读数最准。两个
 *      合成一个分数, 超过 ±UWB_FR_ENTER_SCORE 保持 UWB_FR_CONFIRM_MS 才换。背对信标的基站信号绕着走,
 *      距离只会偏长, 所以这个距离差只会更大, 不会反号。10 cm 的左右距离差不用 (规格书 ±5 cm 测不准)。
 *   2. 左右 (UWB_UpdateSide): 听朝着信标的那个前 / 后基站的正负号, 读数在 ±60° 以内才算, 否则沿用
 *      上一次的左右 (信标要换边只能经过正前 / 正后, 那时读数最准)。
 *   3. 偏多少度 (UWB_SelectAnchor): 朝着信标的基站里 (第 1、2 步定的), 读数离它自己正前方最近的
 *      最准, 用它的读数算。朝着信标的基站没数据或者读数在测角边缘时才用背对信标的镜像读数, 这就是
 *      掉线降级: 丢任何一路都还有别的基站量同一个方向, 全丢 UWB_DATA_TIMEOUT_MS 才算收不到 (停车)。
 * 第 1、2 步都有回差, 输出还要过 UWB_AcceptAzimuth 的突变门限, 单帧镜像不会让狗突然掉头。 */

/* 想把 latch 换成 wanted: 要连续 confirm_ms 都这么想才换。还不知道的时候马上信。 */
static void UWB_Propose(UWB_Latch *latch, int8_t wanted, uint32_t confirm_ms, uint32_t now_ms)
{
    if (wanted == latch->state) {
        latch->pending = 0;
    } else if (latch->state == 0) {
        latch->state   = wanted;
        latch->pending = 0;
    } else if (wanted != latch->pending) {
        latch->pending  = wanted;
        latch->since_ms = now_ms;
    } else if ((uint32_t) (now_ms - latch->since_ms) >= confirm_ms) {
        latch->state   = wanted;
        latch->pending = 0;
    }
}

/* 取中值, 再做距离一致性检查: 和"偏小的中位数"差超过 UWB_RANGE_SPREAD_CM 的这一拍不用
 * (偏小的中位数: 反射只会让距离变长, 两个基站时就是小的那个)。返回有数据的基站数。 */
static uint8_t UWB_BuildViews(UWB_AnchorView *view, uint32_t now_ms)
{
    int16_t ranges[UWB_ANCHOR_COUNT];
    int16_t sorted[UWB_MEDIAN_SAMPLES];
    uint8_t count = 0U;
    uint32_t source;

    for (source = 0U; source < (uint32_t) UWB_ANCHOR_COUNT; source++) {
        const UWB_Channel *channel = &g_uwb_channels[source];

        view[source].usable = false;
        view[source].fresh  = (channel->sample_count != 0U) &&
                              ((uint32_t) (now_ms - channel->sample_time_ms) <= UWB_ANCHOR_STALE_MS);
        if (view[source].fresh) {
            view[source].angle_deg   = UWB_Median(channel->angle_samples, channel->sample_count, sorted);
            view[source].angle_min   = sorted[0];
            view[source].angle_max   = sorted[channel->sample_count - 1U];
            view[source].distance_cm = UWB_Median(channel->distance_samples, channel->sample_count, sorted);
            ranges[count++] = view[source].distance_cm;
        }
    }

    if (count == 0U) {
        return 0U;
    }

    UWB_Sort(ranges, count);
    for (source = 0U; source < (uint32_t) UWB_ANCHOR_COUNT; source++) {
        if (view[source].fresh) {
            view[source].usable = (UWB_AbsAngle((int16_t) (view[source].distance_cm -
                                   ranges[(count - 1U) / 2U])) <= UWB_RANGE_SPREAD_CM);
        }
    }

    return count;
}

/* 最近 UWB_MEDIAN_SAMPLES 帧全在 ±60° 以内 */
static bool UWB_WithinTrust(const UWB_AnchorView *anchor)
{
    return (UWB_AbsAngle(anchor->angle_min) <= UWB_ANGLE_TRUST_DEG) &&
           (UWB_AbsAngle(anchor->angle_max) <= UWB_ANGLE_TRUST_DEG);
}

/* 这几帧的正负号全一样 (0 不算) */
static bool UWB_SameSign(const UWB_AnchorView *anchor)
{
    return (anchor->angle_min > 0) || (anchor->angle_max < 0);
}

/* 前后: 距离差 (限幅 + 平滑) 算一个分数, 左右基站读数各算一个分数, 加权平均。
 * 左右基站的读数要 UWB_WithinTrust + UWB_SameSign 才算: 测角边缘翻号的帧和粗差混在一起时中值也
 * 可能落到另一边, 而信标在正前 / 正后方时它们再也给不出新证据, 判错了就改不回来。
 * 权重: 距离差 2, 朝着信标的侧基站 2, 背对的 1 (不知道左右时都算 1)。分数含义都是 cos θ × 100
 * (读数按 90° 线性换算, 只用来比门限, 够了)。 */
static void UWB_UpdateFrontRear(const UWB_AnchorView *view, uint32_t now_ms)
{
    const UWB_AnchorView *forward = &view[UWB_ANCHOR_FORWARD];
    const UWB_AnchorView *back    = &view[UWB_ANCHOR_BACK];
    const UWB_AnchorView *left    = &view[UWB_ANCHOR_LEFT];
    const UWB_AnchorView *right   = &view[UWB_ANCHOR_RIGHT];
    int32_t sum    = 0;
    int32_t weight = 0;

    if (forward->fresh && back->fresh) {
        int32_t diff = (int32_t) forward->distance_cm - back->distance_cm - UWB_FB_RANGE_BIAS_CM;
        int32_t score;

        if (diff > UWB_FB_DIFF_CLAMP_CM) {
            diff = UWB_FB_DIFF_CLAMP_CM;
        } else if (diff < -UWB_FB_DIFF_CLAMP_CM) {
            diff = -UWB_FB_DIFF_CLAMP_CM;
        }

        if (!g_uwb_fb_valid) {
            g_uwb_fb_diff_x16 = diff * 16;
            g_uwb_fb_valid    = true;
        } else {
            g_uwb_fb_diff_x16 += ((diff * 16) - g_uwb_fb_diff_x16) / UWB_FB_DIFF_FILTER;
        }

        score = -(g_uwb_fb_diff_x16 * 100) / (16 * UWB_FB_BASELINE_CM);
        if (score > 100) {
            score = 100;
        } else if (score < -100) {
            score = -100;
        }
        sum    += score * 2;
        weight += 2;
    } else {
        g_uwb_fb_valid = false;
    }

    if (left->usable && UWB_WithinTrust(left) && UWB_SameSign(left)) {
        int32_t w = (g_uwb_side.state < 0) ? 2 : 1;

        sum    += ((int32_t) left->angle_deg * 100 / 90) * w;
        weight += w;
    }

    if (right->usable && UWB_WithinTrust(right) && UWB_SameSign(right)) {
        int32_t w = (g_uwb_side.state > 0) ? 2 : 1;

        sum    -= ((int32_t) right->angle_deg * 100 / 90) * w;
        weight += w;
    }

    if (weight == 0) {
        g_uwb_front_rear.pending = 0;   /* 什么证据都没有: 保持 */
        return;
    }

    g_uwb_front_score = (int16_t) (sum / weight);

    if (g_uwb_front_score >= UWB_FR_ENTER_SCORE) {
        UWB_Propose(&g_uwb_front_rear, 1, UWB_FR_CONFIRM_MS, now_ms);
    } else if (g_uwb_front_score <= -UWB_FR_ENTER_SCORE) {
        UWB_Propose(&g_uwb_front_rear, -1, UWB_FR_CONFIRM_MS, now_ms);
    } else {
        g_uwb_front_rear.pending = 0;
    }
}

/* 左右: 听朝着信标的那个前 / 后基站, 它没数据才听背对的那个 (镜像不改正负号)。
 * 一票要 UWB_WithinTrust + UWB_SameSign, 道理同上: 人在侧面时没有新证据能改回来, 宁可不投。
 * 后半圈还要前基站的镜像读数不反对: 左右换错了掉头方向就反了, 狗会来回抽; 这里也兜住后基站
 * 正负号配反 (UWB_BACK_ANGLE_SIGN) 的情况, 那时只是换不了边, 不会抽。 */
static void UWB_UpdateSide(const UWB_AnchorView *view, uint32_t now_ms)
{
    bool rear = (g_uwb_front_rear.state < 0);
    UWB_Anchor source = rear ? UWB_ANCHOR_BACK : UWB_ANCHOR_FORWARD;
    int16_t reading;
    int8_t sign;
    uint16_t magnitude;
    bool mirror_objects;

    if (!view[source].usable) {
        source = rear ? UWB_ANCHOR_FORWARD : UWB_ANCHOR_BACK;
        if (!view[source].usable) {
            g_uwb_side.pending = 0;
            return;
        }
    }

    reading   = (source == UWB_ANCHOR_BACK) ? (int16_t) -view[source].angle_deg :
                                              view[source].angle_deg;
    magnitude = UWB_AbsAngle(reading);
    sign      = (reading < 0) ? -1 : 1;
    mirror_objects = (source == UWB_ANCHOR_BACK) && rear && view[UWB_ANCHOR_FORWARD].usable &&
                     (UWB_AbsAngle(view[UWB_ANCHOR_FORWARD].angle_deg) <= UWB_ANGLE_TRUST_DEG) &&
                     (((int32_t) view[UWB_ANCHOR_FORWARD].angle_deg * sign) < 0);

    if (!UWB_WithinTrust(&view[source])) {
        g_uwb_side.pending = 0;                 /* 测角边缘, 这帧不算, 连续也断了 */
        if (g_uwb_side.state == 0) {
            g_uwb_side.state = sign;            /* 一开始信标就在侧面: 先按它猜 */
        }
    } else if (!UWB_SameSign(&view[source]) || mirror_objects ||
               (magnitude < (rear ? UWB_SIDE_REAR_DEADBAND_DEG : 1))) {
        g_uwb_side.pending = 0;
    } else {
        UWB_Propose(&g_uwb_side, sign, UWB_SIDE_CONFIRM_MS, now_ms);
    }
}

/* 左右: 还不知道 (前后基站从一开始就没数据) 时只能猜一次, 猜完记住, 不能每拍重猜 (那样狗会抖):
 * 只有一个侧基站有数据就算那边, 两个都有就算距离近的那边 (10 cm 的差不准, 但别的什么都没有了)。
 * 前后基站一回来 UWB_UpdateSide 就会改对。 */
static int8_t UWB_SideOrGuess(const UWB_AnchorView *view)
{
    if (g_uwb_side.state == 0) {
        g_uwb_side.state = (!view[UWB_ANCHOR_RIGHT].usable ||
                            (view[UWB_ANCHOR_LEFT].usable &&
                             (view[UWB_ANCHOR_LEFT].distance_cm < view[UWB_ANCHOR_RIGHT].distance_cm))) ? -1 : 1;
    }

    return g_uwb_side.state;
}

static bool UWB_FacesTarget(UWB_Anchor source, int8_t side)
{
    switch (source) {
    case UWB_ANCHOR_FORWARD: return g_uwb_front_rear.state >= 0;
    case UWB_ANCHOR_BACK:    return g_uwb_front_rear.state < 0;
    case UWB_ANCHOR_LEFT:    return side < 0;
    default:                 return side > 0;
    }
}

/* 朝着信标、读数又在 ±60° 以内的基站里挑离自己正前方最近的 (现在用的那个让 UWB_SOURCE_HOLD_DEG,
 * 免得在 45° 附近来回换); 一个都没有就在所有基站里挑, 这时镜像读数也比测角边缘的读数准。
 * 总有一个 usable 的基站才会调这里。 */
static UWB_Anchor UWB_SelectAnchor(const UWB_AnchorView *view, int8_t side)
{
    UWB_Anchor best = UWB_ANCHOR_COUNT;
    int32_t best_error = INT32_MAX;
    uint32_t pass;
    uint32_t source;

    for (pass = 0U; (pass < 2U) && (best == UWB_ANCHOR_COUNT); pass++) {
        for (source = 0U; source < (uint32_t) UWB_ANCHOR_COUNT; source++) {
            int32_t error;

            if (!view[source].usable ||
                ((pass == 0U) && (!UWB_FacesTarget((UWB_Anchor) source, side) ||
                                  (UWB_AbsAngle(view[source].angle_deg) > UWB_ANGLE_TRUST_DEG)))) {
                continue;
            }

            error = (int32_t) UWB_AbsAngle(view[source].angle_deg);
            if (g_uwb_target.valid && (g_uwb_target.source == (UWB_Anchor) source)) {
                error -= UWB_SOURCE_HOLD_DEG;
            }
            if (error < best_error) {
                best_error = error;
                best       = (UWB_Anchor) source;
            }
        }
    }

    return best;
}

/* 这个基站的读数换成车体角。左右基站: 读数 + 安装角的绝对值 = 偏离车头多少度 (镜像读数也对), 正负号
 * 用 side。前后基站: 读数的大小在前半圈就是偏离车头多少度, 在后半圈要用 180° 减; 前半圈读数可信时
 * 正负号用它自己的 (最新, 而且过 0° 时连续), 否则用 side。 */
static int16_t UWB_AnchorAzimuth(UWB_Anchor source, int16_t angle, int8_t side)
{
    int16_t magnitude;

    if ((source == UWB_ANCHOR_FORWARD) || (source == UWB_ANCHOR_BACK)) {
        magnitude = (int16_t) UWB_AbsAngle(angle);
        if (g_uwb_front_rear.state < 0) {
            magnitude = (int16_t) (180 - magnitude);
        } else if (magnitude <= UWB_ANGLE_TRUST_DEG) {
            return (source == UWB_ANCHOR_FORWARD) ? angle : (int16_t) -angle;
        }
    } else {
        magnitude = (int16_t) UWB_AbsAngle(UWB_NormalizeAngle(
            (int32_t) angle + g_mount_offset_deg[source]));
    }

    return (side < 0) ? (int16_t) -magnitude : magnitude;
}

/* 突变门限: 一拍差 UWB_JUMP_DEG 以上先保持上一个值, 一直这样 UWB_JUMP_CONFIRM_MS 才认。
 * 刚收到信标时没有上一个值, 直接用。 */
static bool UWB_AcceptAzimuth(int16_t azimuth, uint32_t now_ms)
{
    if (!g_uwb_target.valid ||
        (UWB_AbsAngle(UWB_NormalizeAngle((int32_t) azimuth - g_uwb_target.azimuth_deg)) <= UWB_JUMP_DEG)) {
        g_uwb_jump_pending = false;
        return true;
    }

    if (!g_uwb_jump_pending) {
        g_uwb_jump_pending  = true;
        g_uwb_jump_since_ms = now_ms;
        return false;
    }

    if ((uint32_t) (now_ms - g_uwb_jump_since_ms) < UWB_JUMP_CONFIRM_MS) {
        return false;
    }

    g_uwb_jump_pending = false;
    return true;
}

static void UWB_ResetFusion(void)
{
    memset(&g_uwb_side, 0, sizeof(g_uwb_side));
    memset(&g_uwb_front_rear, 0, sizeof(g_uwb_front_rear));
    memset(&g_uwb_target, 0, sizeof(g_uwb_target));
    g_uwb_fb_valid     = false;
    g_uwb_fb_diff_x16  = 0;
    g_uwb_front_score  = 0;
    g_uwb_anchors_used = 0U;
    g_uwb_jump_pending = false;
}

/* 每 UWB_FUSE_PERIOD_MS 算一次。所有基站都超过 UWB_ANCHOR_STALE_MS 没数据时不更新, 保持上一次的结果,
 * 到 UWB_DATA_TIMEOUT_MS 由 UWB_GetTarget 报收不到。 */
static void UWB_Fuse(uint32_t now_ms)
{
    UWB_AnchorView view[UWB_ANCHOR_COUNT];
    UWB_Anchor source;
    int8_t side;
    int16_t azimuth;
    int32_t distance;

    g_uwb_anchors_used = UWB_BuildViews(view, now_ms);

    if ((uint32_t) (now_ms - g_uwb_last_sample_ms) > UWB_DATA_TIMEOUT_MS) {
        UWB_ResetFusion();
        return;
    }

    if (g_uwb_anchors_used == 0U) {
        return;
    }

    UWB_UpdateFrontRear(view, now_ms);
    UWB_UpdateSide(view, now_ms);

    side    = UWB_SideOrGuess(view);
    source  = UWB_SelectAnchor(view, side);
    azimuth = UWB_AnchorAzimuth(source, view[source].angle_deg, side);

    /* 前后基站都没数据 = 这一拍完全不知道左右, 只知道偏离车头多少度。人已经差不多在前面就别拐了:
     * side 猜错的话越拐越偏, 狗会一直往一边转下去。 */
    if (!view[UWB_ANCHOR_FORWARD].usable && !view[UWB_ANCHOR_BACK].usable &&
        (UWB_AbsAngle(azimuth) < UWB_BLIND_FRONT_DEG)) {
        azimuth = 0;
    }

    if (!UWB_AcceptAzimuth(azimuth, now_ms)) {
        return;
    }

    /* 距离都换算到前基站: 后基站比它远 36 × cos θ (按 90° 线性换算), 换基站时距离不跳 */
    distance = view[source].distance_cm;
    if (source == UWB_ANCHOR_BACK) {
        distance += (int32_t) UWB_FB_BASELINE_CM * ((int32_t) UWB_AbsAngle(azimuth) - 90) / 90;
        if (distance < 0) {
            distance = 0;
        }
    }

    g_uwb_target.valid              = true;
    g_uwb_target.source             = source;
    g_uwb_target.anchor_id          = g_uwb_channels[source].latest.anchor_id;
    g_uwb_target.tag_id             = g_uwb_channels[source].latest.tag_id;
    g_uwb_target.distance_cm        = (uint32_t) distance;
    g_uwb_target.source_azimuth_deg = view[source].angle_deg;
    g_uwb_target.azimuth_deg        = azimuth;
    g_uwb_target.update_time_ms     = g_uwb_channels[source].sample_time_ms;
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

    if ((uint32_t) (now_ms - g_uwb_last_fuse_ms) >= UWB_FUSE_PERIOD_MS) {
        g_uwb_last_fuse_ms = now_ms;
        UWB_Fuse(now_ms);
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

bool UWB_GetTarget(uint32_t now_ms, UWB_Target *target)
{
    if (target == NULL) {
        return false;
    }

    if (!g_uwb_target.valid ||
        ((uint32_t) (now_ms - g_uwb_last_sample_ms) > UWB_DATA_TIMEOUT_MS)) {
        memset(target, 0, sizeof(*target));
        return false;
    }

    *target = g_uwb_target;
    return true;
}

void UWB_GetFusionInfo(UWB_FusionInfo *info)
{
    if (info == NULL) {
        return;
    }

    info->fb_valid     = g_uwb_fb_valid;
    info->fb_diff_cm   = (int16_t) (g_uwb_fb_diff_x16 / 16);
    info->front_score  = g_uwb_front_score;
    info->front_rear   = g_uwb_front_rear.state;
    info->side         = g_uwb_side.state;
    info->anchors_used = g_uwb_anchors_used;
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
    stats->invalid_frames  = channel->invalid_count;
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
