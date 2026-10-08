#include "uwb.h"

#include <string.h>

#include "ti_msp_dl_config.h"

#define UWB_FRAME_MAX_LENGTH  (64U)
#define UWB_RX_RING_SIZE      (128U)
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
    volatile uint32_t rx_overflow_count;
    volatile uint32_t uart_error_count;
    uint32_t checksum_error_count;
    UWB_Parser parser;
    UWB_Measurement latest;
} UWB_Channel;

static UWB_Channel g_uwb_channels[UWB_ANCHOR_COUNT];

static const int16_t g_mount_offset_deg[UWB_ANCHOR_COUNT] = {
    UWB_LEFT_MOUNT_OFFSET_DEG,
    UWB_FORWARD_MOUNT_OFFSET_DEG,
    UWB_RIGHT_MOUNT_OFFSET_DEG,
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

static void UWB_DecodeFrame(
    UWB_Anchor source, const uint8_t *frame, uint16_t length, uint32_t now_ms)
{
    UWB_Channel *channel = &g_uwb_channels[source];
    UWB_Measurement *measurement = &channel->latest;
    uint8_t checksum = 0U;
    uint16_t i;

    if ((length != UWB_LOCATION_FRAME_LENGTH) ||
        (UWB_ReadBE16(&frame[8]) != UWB_LOCATION_COMMAND) ||
        (UWB_ReadBE16(&frame[10]) != 0x0100U)) {
        return;
    }

    for (i = 0U; i < (length - 1U); i++) {
        checksum ^= frame[i];
    }

    if (checksum != frame[length - 1U]) {
        channel->checksum_error_count++;
        return;
    }

    measurement->source         = source;
    measurement->sequence_id    = UWB_ReadBE16(&frame[6]);
    measurement->anchor_id      = UWB_ReadBE32(&frame[12]);
    measurement->tag_id         = UWB_ReadBE32(&frame[16]);
    measurement->distance_cm    = UWB_ReadBE32(&frame[20]);
    measurement->azimuth_deg    = (int16_t) UWB_ReadBE16(&frame[24]);
    measurement->tag_status     = UWB_ReadBE16(&frame[28]);
    measurement->update_time_ms = now_ms;
    measurement->frame_count++;
    measurement->valid          = true;
}

static void UWB_ParseByte(UWB_Anchor source, uint8_t data, uint32_t now_ms)
{
    UWB_Parser *parser = &g_uwb_channels[source].parser;

    if (parser->index < 4U) {
        if (data == 0xFFU) {
            parser->bytes[parser->index++] = data;
        } else {
            UWB_ResetParser(parser);
        }
        return;
    }

    parser->bytes[parser->index++] = data;

    if (parser->index == 6U) {
        parser->expected_length = UWB_ReadBE16(&parser->bytes[4]);
        if ((parser->expected_length < 12U) ||
            (parser->expected_length > UWB_FRAME_MAX_LENGTH)) {
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

static void UWB_DrainUART(UWB_Anchor source, UART_Regs *uart)
{
    uint8_t data;

    while (DL_UART_Main_receiveDataCheck(uart, &data)) {
        UWB_PushRxByte(source, data);
    }
}

static void UWB_UART_IRQHandler(UWB_Anchor source, UART_Regs *uart)
{
    uint32_t interrupt_index;

    while (true) {
        interrupt_index = (uint32_t) DL_UART_Main_getPendingInterrupt(uart);

        switch (interrupt_index) {
            case DL_UART_MAIN_IIDX_RX:
                UWB_DrainUART(source, uart);
                break;

            case DL_UART_MAIN_IIDX_OVERRUN_ERROR:
            case DL_UART_MAIN_IIDX_FRAMING_ERROR:
            case DL_UART_MAIN_IIDX_NOISE_ERROR:
                g_uwb_channels[source].uart_error_count++;
                UWB_DrainUART(source, uart);
                break;

            default:
                return;
        }
    }
}

void UWB_Init(void)
{
    uint8_t discarded;

    memset(g_uwb_channels, 0, sizeof(g_uwb_channels));

    while (DL_UART_Main_receiveDataCheck(UART_left_INST, &discarded)) {
    }
    while (DL_UART_Main_receiveDataCheck(UART_forward_INST, &discarded)) {
    }
    while (DL_UART_Main_receiveDataCheck(UART_right_INST, &discarded)) {
    }

    NVIC_ClearPendingIRQ(UART_left_INST_INT_IRQN);
    NVIC_ClearPendingIRQ(UART_forward_INST_INT_IRQN);
    NVIC_ClearPendingIRQ(UART_right_INST_INT_IRQN);
    NVIC_EnableIRQ(UART_left_INST_INT_IRQN);
    NVIC_EnableIRQ(UART_forward_INST_INT_IRQN);
    NVIC_EnableIRQ(UART_right_INST_INT_IRQN);
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

bool UWB_GetTarget(uint32_t now_ms, UWB_Target *target)
{
    uint32_t source;
    uint16_t best_boresight_error = UINT16_MAX;
    uint32_t best_age = UINT32_MAX;
    const UWB_Measurement *best = NULL;

    if (target == NULL) {
        return false;
    }

    memset(target, 0, sizeof(*target));

    for (source = 0U; source < (uint32_t) UWB_ANCHOR_COUNT; source++) {
        const UWB_Measurement *candidate = &g_uwb_channels[source].latest;
        uint32_t age;
        uint16_t boresight_error;

        if (!candidate->valid) {
            continue;
        }

        age = (uint32_t) (now_ms - candidate->update_time_ms);
        if (age > UWB_DATA_TIMEOUT_MS) {
            continue;
        }

        boresight_error = UWB_AbsAngle(candidate->azimuth_deg);
        if ((best == NULL) || (boresight_error < best_boresight_error) ||
            ((boresight_error == best_boresight_error) && (age < best_age))) {
            best                 = candidate;
            best_boresight_error = boresight_error;
            best_age             = age;
        }
    }

    if (best == NULL) {
        return false;
    }

    target->valid                = true;
    target->source               = best->source;
    target->anchor_id            = best->anchor_id;
    target->tag_id               = best->tag_id;
    target->distance_cm          = best->distance_cm;
    target->source_azimuth_deg   = best->azimuth_deg;
    target->azimuth_deg          = UWB_NormalizeAngle(
        (int32_t) best->azimuth_deg + g_mount_offset_deg[best->source]);
    target->update_time_ms       = best->update_time_ms;

    return true;
}

void UART_left_INST_IRQHandler(void)
{
    UWB_UART_IRQHandler(UWB_ANCHOR_LEFT, UART_left_INST);
}

void UART_forward_INST_IRQHandler(void)
{
    UWB_UART_IRQHandler(UWB_ANCHOR_FORWARD, UART_forward_INST);
}

void UART_right_INST_IRQHandler(void)
{
    UWB_UART_IRQHandler(UWB_ANCHOR_RIGHT, UART_right_INST);
}
