#ifndef __ALLHEADER_H_
#define __ALLHEADER_H_

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>
#include <math.h>
#include <string.h>

#define u8  uint8_t
#define u16 uint16_t
#define u32 uint32_t

/* CubeMX 生成的外设句柄: huart2/3/4/5, htim2/3/8, 以及 main.h 里的引脚名 */
#include "main.h"
#include "usart.h"
#include "tim.h"
#include "bsp.h"

#include "delay.h"
#include "task.h"
#include "motor.h"
#include "encoder.h"
#include "uwb.h"
#include "KEY/key.h"
#include "ALGORITHM/follow.h"

/* USART3: FPGA 串口 (DMA 收发, 协议见 obstacle.md 第 5 节) */
#include "MLK/fpgamlk.h"


#endif
