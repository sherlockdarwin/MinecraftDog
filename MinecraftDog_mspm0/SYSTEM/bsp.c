#include "bsp.h"
#include "AllHeader.h"

//Select whether the car moves forward autonomously after initialization is completed, 0 for no, 1 for yes (used in autonomous avoidance cases)

int Car_Auto_Drive = 0;

void board_init(void)
{
	SYSCFG_DL_init();
}


void bsp_init(void)
{
    board_init();

    OLED_Init();
    Init_Motor_PWM();
    encoder_init();
    UWB_Init();
    KEY_Init();
    Follow_Init();
    Timer_1ms_Init();
}
