#include <Arduino.h>
#include <SoftwareSerial.h>
#include "car.h"
#include "music.h"
// int hallPin=A0;     // 霍尔传感器引脚
int hallPin2=2;
//  int a0value;     // a0读取的模拟值
unsigned long lasttime = 0;        // 上次更新时间
int cnt=0;

volatile bool falling=false;
volatile bool au=false;
void hallchange(){
  falling=(digitalRead(hallPin2)==LOW);
}

void setup() {
  // put your setup code here, to run once:
  Serial.begin(115200);
  musicjq();
//  pinMode(hallPin,INPUT);
  pinMode(hallPin2,INPUT_PULLUP);
  attachInterrupt(digitalPinToInterrupt(hallPin2),hallchange,CHANGE);
  delay(1000);
  volume(25);
  playmusic(1);
}

void loop() {
  // put your main code here, to run repeatedly:
//  a0value=analogRead(hallPin);
  if(falling&&!au){
    au=true;
    volume(30);
    playmusic(2);
    cnt++;
  }
  if(!falling){
    au=false;
    volume(25);
    playmusic(1);
    if(cnt==3)cnt=0;
  }

}
