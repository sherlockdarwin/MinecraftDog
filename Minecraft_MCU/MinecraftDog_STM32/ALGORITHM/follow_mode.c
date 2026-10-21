#include "follow_mode.h"

#include "AllHeader.h"

/* 【跟随测试模式】说明和删除方法见 follow_mode.h。 */

static bool s_follow_mode_active = false;

static void FollowMode_Enter(void)
{
    Follow_Init();          /* 清掉上次的斜坡状态, 先停车 */
    Follow_Enable(1U);
    s_follow_mode_active = true;
    LCD_ShowString(0U, 112U, "UWB FOLLOW MODE ", LCD_GREEN, LCD_BLACK, 16U);
}

static void FollowMode_Exit(void)
{
    Follow_Enable(0U);      /* 立即停车并关电机锁, 之后电机交回 FPGA 模式 */
    s_follow_mode_active = false;
    LCD_Fill(0U, 112U, LCD_W, 16U, LCD_BLACK);
}

void FollowMode_Process(uint32_t now_ms)
{
    if (Key1_Long_Press() && !s_follow_mode_active) {
        FollowMode_Enter();
    }

    if (Key2_Long_Press() && s_follow_mode_active) {
        FollowMode_Exit();
    }

    if (!s_follow_mode_active) {
        return;
    }

    /* 模式里短按 KEY1 不起作用, 吃掉事件, 免得退出后突然触发试电机
     * (短按 KEY2 照样让步进电机摇摆, 不影响轮子) */
    (void) Key1_Short_Press();

    Follow_Process(now_ms);
}

bool FollowMode_IsActive(void)
{
    return s_follow_mode_active;
}
