#include "lcd.h"

#include "main.h"
#include "delay.h"
#include "lcdfont.h"

#if defined(LCD_SCL_Pin)

#if !defined(LCD_SDA_Pin) || !defined(LCD_CS_Pin) || !defined(LCD_DC_Pin) || \
    !defined(LCD_RES_Pin) || !defined(LCD_BLK_Pin)
#error "CubeMX 里 PB4~PB9 的 User Label 要配全: LCD_BLK LCD_DC LCD_RES LCD_CS LCD_SCL LCD_SDA (见 lcd.h)"
#endif

/* ST7735S 命令 */
#define ST_SLPOUT   (0x11U)
#define ST_NORON    (0x13U)
#define ST_INVOFF   (0x20U)
#define ST_INVON    (0x21U)
#define ST_DISPON   (0x29U)
#define ST_CASET    (0x2AU)
#define ST_RASET    (0x2BU)
#define ST_RAMWR    (0x2CU)
#define ST_MADCTL   (0x36U)
#define ST_COLMOD   (0x3AU)

#define ST_MADCTL_MY   (0x80U)
#define ST_MADCTL_MX   (0x40U)
#define ST_MADCTL_BGR  (0x08U)

/* 控制器的显存是 132x162, 屏只用了其中 128x128 */
#define ST_RAM_W  (132U)
#define ST_RAM_H  (162U)

/* 直接写 BSRR / BRR, 比 HAL_GPIO_WritePin 快几倍; 72 MHz 下一位约 120 ns, ST7735S 允许最快 66 ns */
#define PIN_HIGH(name)  (name##_GPIO_Port->BSRR = name##_Pin)
#define PIN_LOW(name)   (name##_GPIO_Port->BRR  = name##_Pin)

static void LCD_WriteByte(uint8_t data)
{
    uint8_t i;

    for (i = 0U; i < 8U; i++) {     /* SPI 模式 0, 高位先发, SCL 上升沿屏采样 */
        PIN_LOW(LCD_SCL);
        if (data & 0x80U) {
            PIN_HIGH(LCD_SDA);
        } else {
            PIN_LOW(LCD_SDA);
        }
        PIN_HIGH(LCD_SCL);
        data <<= 1;
    }
}

static void LCD_WriteCmd(uint8_t cmd)
{
    PIN_LOW(LCD_CS);
    PIN_LOW(LCD_DC);
    LCD_WriteByte(cmd);
    PIN_HIGH(LCD_CS);
}

static void LCD_WriteData(const uint8_t *data, uint8_t len)
{
    PIN_LOW(LCD_CS);
    PIN_HIGH(LCD_DC);
    while (len-- > 0U) {
        LCD_WriteByte(*data++);
    }
    PIN_HIGH(LCD_CS);
}

static void LCD_Cmd(uint8_t cmd, const uint8_t *data, uint8_t len)
{
    LCD_WriteCmd(cmd);
    if (len > 0U) {
        LCD_WriteData(data, len);
    }
}

/* 开一个窗口 (控制器显存坐标, 含两端), 然后进入写显存; 之后连续写颜色 */
static void LCD_RawWindow(uint16_t x0, uint16_t y0, uint16_t x1, uint16_t y1)
{
    uint8_t col[4] = {(uint8_t) (x0 >> 8), (uint8_t) x0, (uint8_t) (x1 >> 8), (uint8_t) x1};
    uint8_t row[4] = {(uint8_t) (y0 >> 8), (uint8_t) y0, (uint8_t) (y1 >> 8), (uint8_t) y1};

    LCD_Cmd(ST_CASET, col, 4U);
    LCD_Cmd(ST_RASET, row, 4U);
    LCD_WriteCmd(ST_RAMWR);
}

/* 连续写 count 个同样颜色的点 (CS 一直拉低) */
static void LCD_PushColor(uint16_t color, uint32_t count)
{
    PIN_LOW(LCD_CS);
    PIN_HIGH(LCD_DC);
    while (count-- > 0U) {
        LCD_WriteByte((uint8_t) (color >> 8));
        LCD_WriteByte((uint8_t) color);
    }
    PIN_HIGH(LCD_CS);
}

void LCD_Init(void)
{
    static const uint8_t frmctr[6] = {0x01, 0x2C, 0x2D, 0x01, 0x2C, 0x2D};
    static const uint8_t pwctr1[3] = {0xA2, 0x02, 0x84};
    static const uint8_t pwctr3[2] = {0x0A, 0x00};
    static const uint8_t pwctr4[2] = {0x8A, 0x2A};
    static const uint8_t pwctr5[2] = {0x8A, 0xEE};
    static const uint8_t gamma_p[16] = {0x02, 0x1C, 0x07, 0x12, 0x37, 0x32, 0x29, 0x2D,
                                        0x29, 0x25, 0x2B, 0x39, 0x00, 0x01, 0x03, 0x10};
    static const uint8_t gamma_n[16] = {0x03, 0x1D, 0x07, 0x06, 0x2E, 0x2C, 0x29, 0x2D,
                                        0x2E, 0x2E, 0x37, 0x3F, 0x00, 0x00, 0x02, 0x10};
    GPIO_InitTypeDef gpio = {0};
    uint8_t arg;

    /* SCL / SDA 一定要用高速输出, 不管 CubeMX 里设的是什么 */
    gpio.Pin   = LCD_SCL_Pin;
    gpio.Mode  = GPIO_MODE_OUTPUT_PP;
    gpio.Pull  = GPIO_NOPULL;
    gpio.Speed = GPIO_SPEED_FREQ_HIGH;
    HAL_GPIO_Init(LCD_SCL_GPIO_Port, &gpio);
    gpio.Pin = LCD_SDA_Pin;
    HAL_GPIO_Init(LCD_SDA_GPIO_Port, &gpio);

    PIN_LOW(LCD_BLK);       /* 初始化完、清好屏再开背光, 上电不闪白屏 */
    PIN_HIGH(LCD_CS);
    PIN_LOW(LCD_SCL);

    /* 硬件复位 */
    PIN_LOW(LCD_RES);
    delay_ms(10);
    PIN_HIGH(LCD_RES);
    delay_ms(120);

    LCD_WriteCmd(ST_SLPOUT);
    delay_ms(120);

    LCD_Cmd(0xB1, frmctr, 3U);          /* 帧率: 正常模式 */
    LCD_Cmd(0xB2, frmctr, 3U);          /* 帧率: 空闲模式 */
    LCD_Cmd(0xB3, frmctr, 6U);          /* 帧率: 局部模式 */
    arg = 0x07U; LCD_Cmd(0xB4, &arg, 1U);           /* 不反转 */
    LCD_Cmd(0xC0, pwctr1, 3U);                      /* 电源控制 1 */
    arg = 0xC5U; LCD_Cmd(0xC1, &arg, 1U);           /* 电源控制 2 */
    LCD_Cmd(0xC2, pwctr3, 2U);                      /* 电源控制 3 */
    LCD_Cmd(0xC3, pwctr4, 2U);                      /* 电源控制 4 */
    LCD_Cmd(0xC4, pwctr5, 2U);                      /* 电源控制 5 */
    arg = 0x0EU; LCD_Cmd(0xC5, &arg, 1U);           /* VCOM */

    LCD_WriteCmd(LCD_INVERT ? ST_INVON : ST_INVOFF);

    arg = (uint8_t) ((LCD_ROTATE_180 ? 0U : (ST_MADCTL_MX | ST_MADCTL_MY)) |
                     (LCD_BGR ? ST_MADCTL_BGR : 0U));
    LCD_Cmd(ST_MADCTL, &arg, 1U);
    arg = 0x05U; LCD_Cmd(ST_COLMOD, &arg, 1U);      /* 16 位色 RGB565 */

    LCD_Cmd(0xE0, gamma_p, 16U);
    LCD_Cmd(0xE1, gamma_n, 16U);

    LCD_WriteCmd(ST_NORON);
    delay_ms(10);

    /* 整块显存 132x162 全清成黑, 偏移设得不对时边上也不会留花点 */
    LCD_RawWindow(0U, 0U, ST_RAM_W - 1U, ST_RAM_H - 1U);
    LCD_PushColor(LCD_BLACK, (uint32_t) ST_RAM_W * ST_RAM_H);

    LCD_WriteCmd(ST_DISPON);
    delay_ms(20);
    PIN_HIGH(LCD_BLK);
}

void LCD_Fill(uint16_t x, uint16_t y, uint16_t w, uint16_t h, uint16_t color)
{
    if ((w == 0U) || (h == 0U) || (x >= LCD_W) || (y >= LCD_H)) {
        return;
    }
    if (x + w > LCD_W) {
        w = (uint16_t) (LCD_W - x);
    }
    if (y + h > LCD_H) {
        h = (uint16_t) (LCD_H - y);
    }

    LCD_RawWindow((uint16_t) (x + LCD_X_OFFSET), (uint16_t) (y + LCD_Y_OFFSET),
                  (uint16_t) (x + w - 1U + LCD_X_OFFSET), (uint16_t) (y + h - 1U + LCD_Y_OFFSET));
    LCD_PushColor(color, (uint32_t) w * h);
}

void LCD_ShowChar(uint16_t x, uint16_t y, char chr, uint16_t fc, uint16_t bc, uint8_t sizey)
{
    const unsigned char *glyph;
    uint8_t w;
    uint8_t row;
    uint8_t col;
    uint8_t c = (uint8_t) chr;

    if ((c < ' ') || (c > '~')) {
        c = ' ';
    }

    if (sizey == 16U) {
        glyph = asc2_1608[c - ' '];
        w = 8U;
    } else {
        glyph = asc2_0806[c - ' '];
        w = 6U;
        sizey = 8U;
    }

    if ((x + w > LCD_W) || (y + sizey > LCD_H)) {
        return;
    }

    LCD_RawWindow((uint16_t) (x + LCD_X_OFFSET), (uint16_t) (y + LCD_Y_OFFSET),
                  (uint16_t) (x + w - 1U + LCD_X_OFFSET), (uint16_t) (y + sizey - 1U + LCD_Y_OFFSET));

    PIN_LOW(LCD_CS);
    PIN_HIGH(LCD_DC);
    for (row = 0U; row < sizey; row++) {
        for (col = 0U; col < w; col++) {
            /* 字模是竖排的: 第 row 行在第 (row / 8) 个半字里, 取第 (row % 8) 位 */
            uint16_t color = ((glyph[(row / 8U) * w + col] >> (row % 8U)) & 1U) ? fc : bc;

            LCD_WriteByte((uint8_t) (color >> 8));
            LCD_WriteByte((uint8_t) color);
        }
    }
    PIN_HIGH(LCD_CS);
}

void LCD_ShowString(uint16_t x, uint16_t y, const char *str, uint16_t fc, uint16_t bc, uint8_t sizey)
{
    uint8_t w = (sizey == 16U) ? 8U : 6U;

    while (*str != '\0') {
        LCD_ShowChar(x, y, *str++, fc, bc, sizey);
        x = (uint16_t) (x + w);
    }
}

#else   /* CubeMX 里还没配 LCD 的 6 个引脚: 全部空操作 */

void LCD_Init(void)
{
}

void LCD_Fill(uint16_t x, uint16_t y, uint16_t w, uint16_t h, uint16_t color)
{
    (void) x; (void) y; (void) w; (void) h; (void) color;
}

void LCD_ShowChar(uint16_t x, uint16_t y, char chr, uint16_t fc, uint16_t bc, uint8_t sizey)
{
    (void) x; (void) y; (void) chr; (void) fc; (void) bc; (void) sizey;
}

void LCD_ShowString(uint16_t x, uint16_t y, const char *str, uint16_t fc, uint16_t bc, uint8_t sizey)
{
    (void) x; (void) y; (void) str; (void) fc; (void) bc; (void) sizey;
}

#endif
