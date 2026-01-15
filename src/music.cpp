#include "music.h"
#include <Arduino.h>
#include <SoftwareSerial.h>
SoftwareSerial jqSerial(12,13); // RX12, TX13

void musicjq(){
  jqSerial.begin(9600);
  pinMode(8,OUTPUT);
//  pinMode(11,OUTPUT);
//  digitalWrite(11,HIGH);
  digitalWrite(8,HIGH); 
}

void volume(int volume) {
  //volume 0~30
  if(volume<0)volume=0;
  if(volume>30)volume=30;
  byte volcmd[6]={0x7E,0x03,0x06,0x00,volume,0xEF};
  jqSerial.write(volcmd,6);
}

void playmusic(int musicnum){
  byte playcmd[6]={0x7E,0x04,0x03,0x00,musicnum,0xEF};
  jqSerial.write(playcmd,6);
}

void stopmusic(){
  byte stopcmd[4]={0x7E,0x02,0x0E,0xEF};
  jqSerial.write(stopcmd,4);
  delay(30);
}

void startmusic(){
  byte startcmd[4]={0x7E,0x02,0x0D,0xEF};
  jqSerial.write(startcmd,4);
  delay(30);
}