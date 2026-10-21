#ifndef __UWB_H_
#define __UWB_H_

#include <stdbool.h>
#include <stdint.h>

#define UWB_LOCATION_COMMAND          (0x2001U)
#define UWB_LOCATION_FRAME_LENGTH     (37U)
#define UWB_HEARTBEAT_COMMAND         (0x2002U)
#define UWB_HEARTBEAT_FRAME_LENGTH    (16U)
#define UWB_DATA_TIMEOUT_MS           (500U)

/* Actual installation reference:
 *   forward antenna boresight =   0 degrees
 *   left antenna boresight    = -90 degrees (90 degrees to vehicle left)
 *   right antenna boresight   = +90 degrees (90 degrees to vehicle right)
 * Vehicle coordinates keep left negative and right positive. */
#ifndef UWB_LEFT_MOUNT_OFFSET_DEG
#define UWB_LEFT_MOUNT_OFFSET_DEG     (-90)
#endif

#ifndef UWB_FORWARD_MOUNT_OFFSET_DEG
#define UWB_FORWARD_MOUNT_OFFSET_DEG  (0)
#endif

#ifndef UWB_RIGHT_MOUNT_OFFSET_DEG
#define UWB_RIGHT_MOUNT_OFFSET_DEG    (90)
#endif

/* 三基站合成 (UWB_GetTarget, 原理见 uwb.c): 左右只听前基站。前基站连续 UWB_SIDE_CONFIRM_FRAMES 帧
 * 都在 ±UWB_SIDE_TRUST_DEG 以内、而且是同一边, 才换边; 再往外 (信标在侧面, 前基站在测角边缘,
 * 偶尔会跳到另一边) 沿用上一次的左右。 */
#define UWB_SIDE_TRUST_DEG            (60)
#define UWB_SIDE_CONFIRM_FRAMES       (3)     /* 前基站每秒约 40 帧, 3 帧 = 75 ms */

typedef enum {
    UWB_ANCHOR_LEFT = 0,
    UWB_ANCHOR_FORWARD,
    UWB_ANCHOR_RIGHT,
    UWB_ANCHOR_COUNT
} UWB_Anchor;

typedef struct {
    bool valid;
    UWB_Anchor source;
    uint16_t sequence_id;
    uint16_t tag_status;
    uint32_t anchor_id;
    uint32_t tag_id;
    uint32_t distance_cm;
    int16_t azimuth_deg;
    uint32_t update_time_ms;
    uint32_t frame_count;
} UWB_Measurement;

typedef struct {
    bool valid;
    UWB_Anchor source;
    uint32_t anchor_id;
    uint32_t tag_id;
    uint32_t distance_cm;
    int16_t azimuth_deg;
    int16_t source_azimuth_deg;
    uint32_t update_time_ms;
} UWB_Target;

void UWB_Init(void);
void UWB_Process(uint32_t now_ms);
bool UWB_GetMeasurement(UWB_Anchor source, UWB_Measurement *measurement);
bool UWB_GetTarget(uint32_t now_ms, UWB_Target *target);

/* 排查接线用的计数 (每个基站一份):
 *   rx_bytes 一直是 0          -> 串口线上没数据: 查 基站 TX -> STM32 RX、共地
 *   rx_bytes 在涨, frames 是 0 -> 收到了但解不出: 看 checksum_errors 和 last_* (屏幕最下面一行) */
typedef struct {
    uint32_t rx_bytes;          /* 收到的字节总数 */
    uint32_t frames;            /* 校验通过的定位帧 (0x2001) */
    uint32_t checksum_errors;   /* 校验不对的帧 */
    uint32_t uart_errors;       /* 串口帧错 / 噪声 / 溢出 */
    uint32_t overflows;         /* 环形缓冲满了丢掉的字节 */
    uint16_t last_length;       /* 最近一个定位帧: 长度字段 */
    uint16_t last_version;      /*                 版本号 */
    uint8_t  last_xor_rx;       /*                 帧里的校验字节 */
    uint8_t  last_xor_calc;     /*                 算出来的异或 */
} UWB_Stats;

void UWB_GetStats(UWB_Anchor source, UWB_Stats *stats);

/* Total frames decoded on all anchors; changes whenever any anchor updates. */
uint32_t UWB_GetFrameCount(void);

/* Called from USART2 / UART4 / UART5 IRQ handlers in stm32f1xx_it.c. */
void UWB_IRQHandler(UWB_Anchor source);

#endif
