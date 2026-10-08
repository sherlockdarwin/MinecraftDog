#ifndef __UWB_H_
#define __UWB_H_

#include <stdbool.h>
#include <stdint.h>

#define UWB_LOCATION_COMMAND          (0x2001U)
#define UWB_LOCATION_FRAME_LENGTH     (37U)
#define UWB_DATA_TIMEOUT_MS           (500U)

/* Installation reference: vehicle forward is 0 degrees, left is negative and
 * right is positive. Change these three offsets if the physical antenna
 * boresights are mounted at different angles. */
#ifndef UWB_LEFT_MOUNT_OFFSET_DEG
#define UWB_LEFT_MOUNT_OFFSET_DEG     (-90)
#endif

#ifndef UWB_FORWARD_MOUNT_OFFSET_DEG
#define UWB_FORWARD_MOUNT_OFFSET_DEG  (0)
#endif

#ifndef UWB_RIGHT_MOUNT_OFFSET_DEG
#define UWB_RIGHT_MOUNT_OFFSET_DEG    (90)
#endif

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

#endif
