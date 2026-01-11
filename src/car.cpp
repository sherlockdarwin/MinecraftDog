#include "car.h"
#include <Arduino.h>

void carpin(){
  pinMode(AIN1,OUTPUT);
  pinMode(AIN2,OUTPUT);
  pinMode(PWMA,OUTPUT);

  pinMode(BIN1,OUTPUT);
  pinMode(BIN2,OUTPUT);
  pinMode(PWMB,OUTPUT);
  
  pinMode(STBY,OUTPUT);
  digitalWrite(STBY,HIGH);
}

void turnleft(){

}

void turnright(){

}