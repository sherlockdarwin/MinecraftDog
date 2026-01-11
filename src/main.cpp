#include <Arduino.h>
#include <SoftwareSerial.h>
int hallPin=A0;     // 霍尔传感器引脚
int hallPin2=2;
int a0value;     // a0读取的模拟值
SoftwareSerial jqSerial(8,9); //Arduino D2=RX、D3=TX 接 JQ6500 TX、RX
unsigned long lasttime = 0;        // 上次更新时间
int cnt=0;
void volume(int volume) {
  //volume 0~30
  if(volume<0)volume=0;
  if(volume>30)volume=30;
  byte volcmd[4]={0x7E,0x06,0x00,volume};
  jqSerial.write(volcmd, 4);
}
void playmusic(int musicnum){
  byte para1=musicnum>>8;
  byte para2=musicnum&0xFF;
  byte playcmd[4]={0x7E,0x03,para1,para2};
  jqSerial.write(playcmd,4);
}

bool falling=false;
void change(){
  falling=true;
}

void setup() {
  // put your setup code here, to run once:
  Serial.begin(115200);
  jqSerial.begin(115200);
  pinMode(hallPin,INPUT);
  pinMode(hallPin2,INPUT);
  attachInterrupt(digitalPinToInterrupt(hallPin2),change, FALLING);
  delay(1000);
  volume(25);
  playmusic(1);
}

bool au=false;

void loop() {
  // put your main code here, to run repeatedly:
  a0value=analogRead(hallPin);
  if(falling&&!au){
    au=true;
    volume(30);
    playmusic(2);
    cnt++;
  }
  if(cnt==3){
    volume(25);
    playmusic(1);
    cnt=0;
    au=false;
    falling=false;
  }

}
