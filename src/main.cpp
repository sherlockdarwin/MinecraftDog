#include <Arduino.h>
#include <SoftwareSerial.h>
#include "car.h"
#include "music.h"
// int hallPin=A0;     // 霍尔传感器引脚
int hallPin2=2;
//  int a0value;     // a0读取的模拟值
//unsigned long lasttime = 0;        // 上次更新时间
//int cnt=0;
SoftwareSerial openmvSerial(A4, A5);

volatile bool falling=false;
volatile bool au=false;
int music=2;
void hallchange(){
  falling=(digitalRead(hallPin2)==LOW);
}

void setup() {
  // put your setup code here, to run once:
  Serial.begin(9600);
  openmvSerial.begin(9600);
  musicjq();
//  pinMode(hallPin,INPUT);
  pinMode(hallPin2,INPUT_PULLUP);
  attachInterrupt(digitalPinToInterrupt(hallPin2),hallchange,CHANGE);
  delay(2000);
  startmusic();
  volume(25);
  playmusic(1);
}

void loop() {
  // put your main code here, to run repeatedly:
//  a0value=analogRead(hallPin);
  if(falling&&!au){
    au=true;
    volume(30);
    digitalWrite(8,LOW);
    music=2;
//    cnt++;
  }
  if(!falling&&(au||music!=1)){
    au=false;
    digitalWrite(8,HIGH);
//    digitalWrite(11,HIGH);
    volume(25);
    playmusic(1);
    music=1;
/*
    if(cnt==3){
      cnt=0;
      digitalWrite(11,LOW); 
    }
*/
  }

  if (openmvSerial.available()) {
    String data = openmvSerial.readStringUntil('\n');
    int cx, cy, r;
    if (sscanf(data.c_str(), "%d,%d,%d", &cx, &cy, &r) == 3) {
      Serial.print("X: ");
      Serial.print(cx);
      Serial.print("  Y: ");
      Serial.print(cy);
      Serial.print("  R: ");
      Serial.println(r);
      //控制逻辑
      forward();
      if(cx<50){
        turnright();
        delay(500);
        forward();
      }
      if(cx>200){
        turnleft();
        delay(500);
        forward();
      }
      if(r>30)slowdown();
      if(r<15)speedup();
    }
  }
  else carstop();

}
