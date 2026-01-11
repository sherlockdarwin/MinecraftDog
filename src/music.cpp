#include "music.h"
#include <Arduino.h>
#include <SoftwareSerial.h>
SoftwareSerial jqSerial(8,9); //Arduino D2=RX、D3=TX 接 JQ6500 TX、RX

void musicjq(){
    jqSerial.begin(115200);
}

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