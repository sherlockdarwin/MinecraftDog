#ifndef CAR_H
#define CAR_H
#include <Arduino.h>

constexpr uint8_t AIN1 = 4;
constexpr uint8_t AIN2 = 5;
constexpr uint8_t PWMA = 9; //pwm 控速

constexpr uint8_t BIN1 = 6;
constexpr uint8_t BIN2 = 7;
constexpr uint8_t PWMB = 10; //pwm 控速

constexpr uint8_t STBY = 3; //使能引脚要拉高

void carpin();
void speedup();
void slowdown();
void carstop();
void turnleft();
void turnright();
void peace();

#endif // CAR_H