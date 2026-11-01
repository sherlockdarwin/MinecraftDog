#ifndef __UWB_H_
#define __UWB_H_

#include <stdbool.h>
#include <stdint.h>

#define UWB_LOCATION_COMMAND          (0x2001U)
#define UWB_LOCATION_FRAME_LENGTH     (37U)
#define UWB_HEARTBEAT_COMMAND         (0x2002U)
#define UWB_HEARTBEAT_FRAME_LENGTH    (16U)
#define UWB_DATA_TIMEOUT_MS           (500U)  /* 所有基站都这么久没有有效帧 = 收不到 (停车) */
#define UWB_ANCHOR_STALE_MS           (200U)  /* 单个基站这么久没有有效帧就不参与融合, 剩下的继续用 */

/* Actual installation reference:
 *   forward antenna boresight =   0 degrees
 *   left antenna boresight    = -90 degrees (90 degrees to vehicle left)
 *   right antenna boresight   = +90 degrees (90 degrees to vehicle right)
 *   back antenna boresight    = 180 degrees (faces the tail, back to back with forward)
 * Vehicle coordinates keep left negative and right positive.
 * 位置: 左右背靠背间距约 10 cm, 前基站在它们靠前边缘的中线上, 后基站在前基站正后方约 36 cm。 */
#ifndef UWB_LEFT_MOUNT_OFFSET_DEG
#define UWB_LEFT_MOUNT_OFFSET_DEG     (-90)
#endif

#ifndef UWB_FORWARD_MOUNT_OFFSET_DEG
#define UWB_FORWARD_MOUNT_OFFSET_DEG  (0)
#endif

#ifndef UWB_RIGHT_MOUNT_OFFSET_DEG
#define UWB_RIGHT_MOUNT_OFFSET_DEG    (90)
#endif

#ifndef UWB_BACK_MOUNT_OFFSET_DEG
#define UWB_BACK_MOUNT_OFFSET_DEG     (180)
#endif

/* 基站发来的角度乘这个数, 换成程序里用的"从基站往外看左负右正"。
 * 2026-10-29 屏幕上逐个看过: 三个基站发来的都是"左正右负" (和厂家例程相反, 可能是天线装法), 所以都是 -1。
 * 以后哪个基站换了装法、单独反了, 就只改它自己的。 */
#ifndef UWB_LEFT_ANGLE_SIGN
#define UWB_LEFT_ANGLE_SIGN           (-1)
#endif

#ifndef UWB_FORWARD_ANGLE_SIGN
#define UWB_FORWARD_ANGLE_SIGN        (-1)
#endif

#ifndef UWB_RIGHT_ANGLE_SIGN
#define UWB_RIGHT_ANGLE_SIGN          (-1)
#endif

/* 后基站按"和另外三个一样正着装"写 -1。2026-11-01 信标放在右后方约 30 cm 核对过一次: 读数为负, 对;
 * 还没在 2 ~ 3 m 处核对 (方法见 README 的上车标定)。 */
#ifndef UWB_BACK_ANGLE_SIGN
#define UWB_BACK_ANGLE_SIGN           (-1)
#endif

/* 四基站融合 (UWB_Fuse, 原理见 uwb.c)。下面的阈值怎么定也见 README 的上车标定。 */
#define UWB_FUSE_PERIOD_MS            (20U)   /* 融合周期, 和发给 FPGA 的周期一样 */
#define UWB_MEDIAN_SAMPLES            (5U)    /* 每个基站取最近 5 帧的中值 (125 ms 窗口, 滞后约 50 ms) */
#define UWB_ANGLE_VALID_DEG           (90)    /* 规格书: 最多测 ±90°, 超过的帧不用 */
#define UWB_RANGE_VALID_MAX_CM        (10000U)/* 规格书: 最远 100 m, 0 或超过的帧不用 */

/* 读数在 ±60° (规格书的 120° 准确区) 以内才信它的正负号; 再往外读数会在两边来回跳, 只信大小。 */
#define UWB_ANGLE_TRUST_DEG           (60)

/* 基站之间最远 36 cm, 所以同一时刻的距离也最多差 36 cm。和其余基站差得比这个还多 = 走了反射路径,
 * 这一拍不用它: 36 + 余量 24 (规格书 ±5 cm, 室内按 ±12 cm 算, 两个基站的差)。 */
#define UWB_RANGE_SPREAD_CM           (60)

/* 前后判别: 前基站距离 - 后基站距离 = -36 × cos(车体角)。
 * 分数 (-100 ~ +100, 正 = 前) = 距离差和左右基站读数的加权平均, 见 UWB_UpdateFrontRear。 */
#define UWB_FB_BASELINE_CM            (36)    /* 前后基站实际间距, 上车量 */
#define UWB_FB_RANGE_BIAS_CM          (0)     /* 信标在正侧面时屏幕 fb 的读数 (两个基站的固定偏差) */
#define UWB_FB_DIFF_CLAMP_CM          (60)    /* 距离差限幅, 偶尔一下反射不把平滑值带跑 */
#define UWB_FB_DIFF_FILTER            (4)     /* 每 20 ms 跟上 1/4, 时间常数约 70 ms */
#define UWB_FR_ENTER_SCORE            (25)    /* 分数超过 ±25 才换前后 (约 ±75°/105°), 中间保持 */
#define UWB_FR_CONFIRM_MS             (100U)  /* 而且要保持这么久 */

/* 左右判别: 前后基站的读数正负。信标要换边只能经过正前 / 正后, 那时读数最准;
 * 人在侧面 (读数 > ±60°) 沿用上一次的左右。 */
#define UWB_SIDE_CONFIRM_MS           (80U)   /* 连续这么久都是另一边才换边 (约 3 帧) */
#define UWB_SIDE_REAR_DEADBAND_DEG    (12)    /* 后半圈读数这么小 = 人几乎在正后方, 不换边 (换一次掉头方向就反了) */

#define UWB_SOURCE_HOLD_DEG           (5)     /* 换基站的回差: 新基站要比现在的离正前方近这么多才换 */
#define UWB_BLIND_FRONT_DEG           (45)    /* 前后基站都没数据时, 偏离车头不到这么多度就按正前方走 */

/* 输出突变: 一拍之内差这么多度不可能是真的 (车原地转也就每 20 ms 几度), 保持上一个值;
 * 一直这样超过 UWB_JUMP_CONFIRM_MS 才认。 */
#define UWB_JUMP_DEG                  (60)
#define UWB_JUMP_CONFIRM_MS           (200U)

/* ── 曾经尝试(方案一：左右基站距离差判左右, 已撤回) ─────────────────────────
 * 左右基站横向间距约 10 cm, 前基站偏左 ~4 cm / 偏右 ~6 cm,
 * 距离差远小于 UWB 测距误差, 效果不佳。现在距离差只用 36 cm 的前后基线。
 * ─────────────────────────────────────────────────────────────────────── */

typedef enum {
    UWB_ANCHOR_LEFT = 0,
    UWB_ANCHOR_FORWARD,
    UWB_ANCHOR_RIGHT,
    UWB_ANCHOR_BACK,
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
 *   rx_bytes 在涨, frames 是 0 -> 收到了但解不出: 看 checksum_errors 和 last_*
 *   (屏幕上现在只显示 rx_bytes, 其余在 Debug 里调 UWB_GetStats 看) */
typedef struct {
    uint32_t rx_bytes;          /* 收到的字节总数 */
    uint32_t frames;            /* 校验通过的定位帧 (0x2001) */
    uint32_t checksum_errors;   /* 校验不对的帧 */
    uint32_t uart_errors;       /* 串口帧错 / 噪声 / 溢出 */
    uint32_t overflows;         /* 环形缓冲满了丢掉的字节 */
    uint32_t invalid_frames;    /* 校验对、但距离 / 角度超范围没用的帧 */
    uint16_t last_length;       /* 最近一个定位帧: 长度字段 */
    uint16_t last_version;      /*                 版本号 */
    uint8_t  last_xor_rx;       /*                 帧里的校验字节 */
    uint8_t  last_xor_calc;     /*                 算出来的异或 */
} UWB_Stats;

void UWB_GetStats(UWB_Anchor source, UWB_Stats *stats);

/* 融合过程 (屏幕排查 + 上车标定用) */
typedef struct {
    bool    fb_valid;       /* 前后基站都有数据 */
    int16_t fb_diff_cm;     /* 平滑后的 前基站距离 - 后基站距离: 信标在正前方约 -36, 正侧面约 0, 正后方约 +36 */
    int16_t front_score;    /* 前后分数 -100 ~ +100, 正 = 前 */
    int8_t  front_rear;     /* +1 前半圈, -1 后半圈, 0 还不知道 */
    int8_t  side;           /* -1 左, +1 右, 0 还不知道 */
    uint8_t anchors_used;   /* 这一拍有几个基站可用 */
} UWB_FusionInfo;

void UWB_GetFusionInfo(UWB_FusionInfo *info);

/* Total frames decoded on all anchors; changes whenever any anchor updates. */
uint32_t UWB_GetFrameCount(void);

/* Called from USART1 / USART2 / UART4 / UART5 IRQ handlers in stm32f1xx_it.c. */
void UWB_IRQHandler(UWB_Anchor source);

#endif
