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

void speedup(){
  digitalWrite(AIN1,LOW);
  digitalWrite(AIN2,HIGH);
  digitalWrite(BIN1,HIGH);
  digitalWrite(BIN2,LOW);
  analogWrite(PWMA,255);
  analogWrite(PWMB,255);
}

void forward(){
  digitalWrite(AIN1,LOW);
  digitalWrite(AIN2,HIGH);
  digitalWrite(BIN1,HIGH);
  digitalWrite(BIN2,LOW);
  analogWrite(PWMA,120);
  analogWrite(PWMB,120);
}

void slowdown(){
  digitalWrite(AIN1,LOW);
  digitalWrite(AIN2,HIGH);
  digitalWrite(BIN1,HIGH);
  digitalWrite(BIN2,LOW);
  analogWrite(PWMA,50);
  analogWrite(PWMB,50);
}

void carstop(){
  digitalWrite(AIN1,HIGH);
  digitalWrite(AIN2,HIGH);
  digitalWrite(BIN1,HIGH);
  digitalWrite(BIN2,HIGH);
  analogWrite(PWMA,255);
  analogWrite(PWMB,255);
}

void turnleft(){
  digitalWrite(AIN1,LOW);
  digitalWrite(AIN2,HIGH);
  digitalWrite(BIN1,HIGH);
  digitalWrite(BIN2,LOW);
  analogWrite(PWMA,128);
  analogWrite(PWMB,50);
}

void turnright(){
  digitalWrite(AIN1,LOW);
  digitalWrite(AIN2,HIGH);
  digitalWrite(BIN1,HIGH);
  digitalWrite(BIN2,LOW);
  analogWrite(PWMA,50);
  analogWrite(PWMB,128);
}

void backward(){
  digitalWrite(AIN1,HIGH);
  digitalWrite(AIN2,LOW);
  digitalWrite(BIN1,LOW);
  digitalWrite(BIN2,HIGH);
  analogWrite(PWMA,128);
  analogWrite(PWMB,128);
}

/*
void peace(){
  digitalWrite(AIN1,LOW);
  digitalWrite(AIN2,LOW);
  digitalWrite(BIN1,LOW);
  digitalWrite(BIN2,LOW);
  analogWrite(PWMA,0);
  analogWrite(PWMB,0);
}
*/