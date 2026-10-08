#include "key.h"

#include "main.h"

typedef struct {
    bool raw_pressed;
    bool stable_pressed;
    bool long_reported;
    uint32_t raw_change_time_ms;
    uint32_t press_time_ms;
    uint8_t short_events;
    uint8_t long_events;
} KEY_State;

static KEY_State g_key_state[KEY_ID_COUNT];

/* 板载按键: KEY1 = PC9, KEY2 = PC8 (CubeMX 里是输入 + 内部上拉) */
static GPIO_TypeDef *const g_key_port[KEY_ID_COUNT] = {
    KEY1_GPIO_Port,
    KEY2_GPIO_Port,
};

static const uint16_t g_key_pin[KEY_ID_COUNT] = {
    KEY1_Pin,
    KEY2_Pin,
};

static bool KEY_ReadPressed(KEY_Id key)
{
    return (HAL_GPIO_ReadPin(g_key_port[key], g_key_pin[key]) == KEY_PRESSED_LEVEL);
}

static void KEY_AddEvent(uint8_t *event_count)
{
    if (*event_count < UINT8_MAX) {
        (*event_count)++;
    }
}

void KEY_Init(void)
{
    uint32_t index;

    for (index = 0U; index < (uint32_t) KEY_ID_COUNT; index++) {
        bool pressed = KEY_ReadPressed((KEY_Id) index);

        g_key_state[index].raw_pressed       = pressed;
        g_key_state[index].stable_pressed    = pressed;
        g_key_state[index].long_reported     = false;
        g_key_state[index].raw_change_time_ms = 0U;
        g_key_state[index].press_time_ms      = 0U;
        g_key_state[index].short_events       = 0U;
        g_key_state[index].long_events        = 0U;
    }
}

void KEY_Scan(uint32_t now_ms)
{
    uint32_t index;

    for (index = 0U; index < (uint32_t) KEY_ID_COUNT; index++) {
        KEY_State *state = &g_key_state[index];
        bool pressed = KEY_ReadPressed((KEY_Id) index);

        if (pressed != state->raw_pressed) {
            state->raw_pressed = pressed;
            state->raw_change_time_ms = now_ms;
        }

        if ((state->stable_pressed != state->raw_pressed) &&
            ((uint32_t) (now_ms - state->raw_change_time_ms) >=
             KEY_DEBOUNCE_MS)) {
            state->stable_pressed = state->raw_pressed;

            if (state->stable_pressed) {
                state->press_time_ms = now_ms;
                state->long_reported = false;
            } else {
                if (!state->long_reported) {
                    KEY_AddEvent(&state->short_events);
                }
                state->long_reported = false;
            }
        }

        if (state->stable_pressed && !state->long_reported &&
            ((uint32_t) (now_ms - state->press_time_ms) >=
             KEY_LONG_PRESS_MS)) {
            state->long_reported = true;
            KEY_AddEvent(&state->long_events);
        }
    }
}

bool KEY_IsPressed(KEY_Id key)
{
    if ((uint32_t) key >= (uint32_t) KEY_ID_COUNT) {
        return false;
    }
    return g_key_state[key].stable_pressed;
}

bool KEY_TakeShortPress(KEY_Id key)
{
    if (((uint32_t) key >= (uint32_t) KEY_ID_COUNT) ||
        (g_key_state[key].short_events == 0U)) {
        return false;
    }
    g_key_state[key].short_events--;
    return true;
}

bool KEY_TakeLongPress(KEY_Id key)
{
    if (((uint32_t) key >= (uint32_t) KEY_ID_COUNT) ||
        (g_key_state[key].long_events == 0U)) {
        return false;
    }
    g_key_state[key].long_events--;
    return true;
}

bool Key1_Short_Press(void) { return KEY_TakeShortPress(KEY_ID_1); }
bool Key2_Short_Press(void) { return KEY_TakeShortPress(KEY_ID_2); }
bool Key1_Long_Press(void)  { return KEY_TakeLongPress(KEY_ID_1); }
bool Key2_Long_Press(void)  { return KEY_TakeLongPress(KEY_ID_2); }
