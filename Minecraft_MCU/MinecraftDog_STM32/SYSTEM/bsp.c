#include "bsp.h"
#include "AllHeader.h"

//Select whether the car moves forward autonomously after initialization is completed, 0 for no, 1 for yes (used in autonomous avoidance cases)

int Car_Auto_Drive = 0;

/* 时钟和外设(GPIO / DMA / USART / TIM)已经在 main() 里由 CubeMX 生成的
 * SystemClock_Config() + MX_xxx_Init() 初始化好了, 这里不用再做。 */
void board_init(void)
{
}


void bsp_init(void)
{
    board_init();

    Init_Motor_PWM();
    encoder_init();
    UWB_Init();
    KEY_Init();
    /* Follow_Init();  本地跟随已停用, 电机由 FPGA 命令驱动 */
    FPGAMLK_Init();
}
