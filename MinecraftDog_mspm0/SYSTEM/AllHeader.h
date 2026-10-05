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

#include "ti_msp_dl_config.h"
#include "bsp.h"

#include "delay.h"
#include "task.h"
#include "motor.h"
#include "encoder.h"
#include "oled_hardware_i2c.h"
#include "uwb.h"
#include "KEY/key.h"
#include "ALGORITHM/follow.h"

/* uart_fpgaMLK is reserved for later use; only its module skeleton is exposed. */
#include "MLK/fpgamlk.h"


#endif
