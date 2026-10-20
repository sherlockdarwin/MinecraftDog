#ifndef __LCD_H_
#define __LCD_H_

/*
 * 1.44 寸 128x128 彩色 TFT, ST7735S, SPI 接口 (模块上的 SCL / SDA 是 SPI 的时钟 / 数据, 不是 I2C)。
 * 用软件 SPI (GPIO 模拟): 硬件 SPI 的引脚都被电机、编码器占了。
 *
 * 接线 (板子顶上那排 LCD 排针, 丝印 -> 屏的引脚):
 *     3V3 -> VCC     GND -> GND
 *     SC  (PB8) -> SCL     DI  (PB9) -> SDA
 *     RST (PB6) -> RES     RS  (PB5) -> DC
 *     CS  (PB7) -> CS      BLK (PB4) -> BLK (背光, 高电平亮)
 *   屏和排针的引脚顺序不一样, 要用杜邦线一根根对着接, 不能直接插。
 *
 * CubeMX:
 *   1. I2C1 的 Mode 改成 Disable (PB6 / PB7 要当普通输出用)。
 *   2. PB4 ~ PB9 都设成 GPIO_Output, User Label 依次填:
 *        PB4 = LCD_BLK, PB5 = LCD_DC, PB6 = LCD_RES, PB7 = LCD_CS, PB8 = LCD_SCL, PB9 = LCD_SDA
 *      推挽、不上下拉; 初始电平都是 Low 就行 (LCD_Init 里会重新设)。
 *   没配这 6 个 Label 时这里的函数全是空操作, 工程照样编译。
 *
 * 初始化命令和 RAM 偏移参考 Adafruit-ST7735-Library (MIT 许可) 的 1.44 寸 "green tab"。
 * 不同厂家的 1.44 寸屏偏移可能差 1~2 个点: 字整体偏了就改 LCD_X_OFFSET / LCD_Y_OFFSET;
 * 上下颠倒就把 LCD_ROTATE_180 改成 1; 红蓝颠倒改 LCD_BGR; 黑白颠倒 (底色是白的) 改 LCD_INVERT。
 */

#include <stdint.h>

#define LCD_W   (128U)
#define LCD_H   (128U)

#define LCD_ROTATE_180  (0U)   /* 1 = 画面转 180° */
#define LCD_BGR         (1U)   /* 1 = 屏的色序是 BGR (这类屏大多是) */
#define LCD_INVERT      (0U)   /* 1 = 打开颜色反转 (有些 IPS 屏要) */

#if LCD_ROTATE_180
#define LCD_X_OFFSET    (2U)
#define LCD_Y_OFFSET    (1U)
#else
#define LCD_X_OFFSET    (2U)
#define LCD_Y_OFFSET    (3U)
#endif

/* RGB565 颜色 */
#define LCD_BLACK    (0x0000U)
#define LCD_WHITE    (0xFFFFU)
#define LCD_RED      (0xF800U)
#define LCD_GREEN    (0x07E0U)
#define LCD_BLUE     (0x001FU)
#define LCD_YELLOW   (0xFFE0U)
#define LCD_CYAN     (0x07FFU)
#define LCD_GRAY     (0x8410U)

void LCD_Init(void);

/* 填一个矩形: 左上角 (x, y), 宽 w, 高 h */
void LCD_Fill(uint16_t x, uint16_t y, uint16_t w, uint16_t h, uint16_t color);

/* 写字: sizey = 8 (6x8 字) 或 16 (8x16 字); fc 字的颜色, bc 底色 */
void LCD_ShowChar(uint16_t x, uint16_t y, char chr, uint16_t fc, uint16_t bc, uint8_t sizey);
void LCD_ShowString(uint16_t x, uint16_t y, const char *str, uint16_t fc, uint16_t bc, uint8_t sizey);

#endif
