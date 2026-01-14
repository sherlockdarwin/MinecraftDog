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
int music=2;
void hallchange(){
  falling=(digitalRead(hallPin2)==LOW);
}

void setup() {
  // put your setup code here, to run once:
  Serial.begin(9600);
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
    digitalWrite(8,LOW);
    volume(30);
    playmusic(2);
    music=2;
    cnt++;
  }
  if(!falling&&(au||music!=1)){
    au=false;
    digitalWrite(8,HIGH);
    volume(25);
    playmusic(1);
    music=1;
    if(cnt==3)cnt=0;
  }

}
