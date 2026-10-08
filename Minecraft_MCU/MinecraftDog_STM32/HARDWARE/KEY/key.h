#ifndef __KEY_H_
#define __KEY_H_

#include <stdbool.h>
#include <stdint.h>

#define KEY_DEBOUNCE_MS   (20U)
#define KEY_LONG_PRESS_MS (800U)

/* 按下时读到的电平 (按"按下接地"配的)。按了 KEY1/KEY2 没反应, 就改成 GPIO_PIN_SET,
 * 同时把 CubeMX 里 PC8/PC9 的上拉改成下拉。 */
#define KEY_PRESSED_LEVEL (GPIO_PIN_RESET)

typedef enum {
    KEY_ID_1 = 0,
    KEY_ID_2,
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
bool Key1_Long_Press(void);
bool Key2_Long_Press(void);

#endif
