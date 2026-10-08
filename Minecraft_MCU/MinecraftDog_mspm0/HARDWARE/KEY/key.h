#ifndef __KEY_H_
#define __KEY_H_

#include <stdbool.h>
#include <stdint.h>

#define KEY_DEBOUNCE_MS   (20U)
#define KEY_LONG_PRESS_MS (800U)

typedef enum {
    KEY_ID_1 = 0,
    KEY_ID_2,
    KEY_ID_3,
    KEY_ID_COUNT
} KEY_Id;

void KEY_Init(void);
void KEY_Scan(uint32_t now_ms);
bool KEY_IsPressed(KEY_Id key);
bool KEY_TakeShortPress(KEY_Id key);
bool KEY_TakeLongPress(KEY_Id key);

/* Convenience wrappers for application code. Each call consumes one event. */
bool Key1_Short_Press(void);
bool Key2_Short_Press(void);
bool Key3_Short_Press(void);
bool Key1_Long_Press(void);
bool Key2_Long_Press(void);
bool Key3_Long_Press(void);

#endif
