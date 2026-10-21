#ifndef __FOLLOW_MODE_H_
#define __FOLLOW_MODE_H_

/*
 * 【跟随测试模式】单独的 UWB 跟随, 不经过 FPGA, 用来试 follow.c 的跟随算法有没有用。
 *
 *   长按 KEY1 (1 秒) 进入: 电机只听 Follow_Process(), FPGA 的命令不管;
 *                          屏幕最下面一行显示 "UWB FOLLOW MODE"。
 *   长按 KEY2 (1 秒) 退出: 停车, 回到正常的 FPGA 模式。
 *   模式里短按 KEY1 不起作用 (不会触发试电机); 短按 KEY2 照样让步进电机摇摆。
 *
 * 跟随参数 (停车距离 3 m、系数、限幅、斜坡) 在 follow.h。
 *
 * 不要了就删掉 (全工程搜 FollowMode 就能找全):
 *   1. 这两个文件 follow_mode.c / follow_mode.h
 *   2. AllHeader.h 里 #include "ALGORITHM/follow_mode.h" 那一行
 *   3. task.c / task.h 里的 Task_Follow_Mode 和任务表里那一行
 *   4. task.c 里 Task_Motor_Drive 开头的 FollowMode_IsActive() 判断
 */

#include <stdbool.h>
#include <stdint.h>

/* 每 20 ms 调一次: 看长按事件进出模式; 模式里跑 Follow_Process()。 */
void FollowMode_Process(uint32_t now_ms);

/* true = 正在跟随测试模式, 电机归 Follow_Process 管。 */
bool FollowMode_IsActive(void);

#endif
