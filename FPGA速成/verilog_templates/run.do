# =============================================================================
# ModelSim 一键脚本：编译 → 加载仿真 → 加波形 → 运行
# 1. 把 tb 和自己的 .v 放进一个路径里没有中文的文件夹（如 D:/exam/q1），本文件也复制进去
#    （ModelSim 10.4 在中文路径下建不了 work 库，vlog 直接报错）
# 2. 改下面 4 行
# 3. 运行：VS Code 终端 cd 到这个文件夹，输入  vsim -do run.do
#          或者在 ModelSim 里 File → Change Directory 选这个文件夹，Transcript 里输入  do run.do
# 4. 改完代码保存，在 Transcript 里再输入一次  do run.do（会退出旧仿真、重新编译、重新跑）
# =============================================================================

set TB    tb_template                         ;# tb 的模块名（module 后面的名字，不是文件名）
set SRCS  {t00_skeleton.v t13_tb_template.v}  ;# 所有 .v 文件，空格隔开
set TIME  -all                                ;# -all 跑到 $stop；tb 里没有 $stop 就写时长，如 2us
set RADIX unsigned                            ;# 波形数字格式：unsigned / hex（BCD 题用 hex）/ binary

catch {quit -sim}
if {![file exists work]} { vlib work }
eval vlog -work work $SRCS
vsim -voptargs=+acc work.$TB                  ;# +acc：保留模块内部信号，波形里才能看到
if {![batch_mode]} {
    add wave -radix $RADIX -r /*              ;# 所有层次的所有信号；只看 tb 那一层：add wave /$TB/*
}
if {$TIME eq "-all"} { run -all } else { run $TIME }
if {![batch_mode]} { wave zoom full }
