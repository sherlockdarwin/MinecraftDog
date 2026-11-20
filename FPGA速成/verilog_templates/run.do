# =============================================================================
# ModelSim 一键脚本：编译 → 加载仿真 → 加波形 → 运行
# 1. 把 tb 和自己的 .v 放进一个路径里没有中文的文件夹（如 D:/exam/q1），本文件也复制进去
#    （ModelSim 10.4 在中文路径下建不了 work 库，vlog 直接报错）
# 2. 改下面 4 行
# 3. 运行：VS Code 终端 cd 到这个文件夹，输入  vsim -do run.do
#          或者在 ModelSim 里 File → Change Directory 选这个文件夹，Transcript 里输入  do run.do
# 4. 改完代码保存，在 Transcript 里再输入一次  do run.do（会退出旧仿真、重新编译、重新跑）
# =============================================================================

# 怎么填：
#   TB    打开 tb 文件，看 module 后面的名字（电子钟题是 tb，不是 top：top 是你写的模块）
#   SRCS  你的 .v 和 tb 的 .v 两个文件都要写
#   TIME  tb 的 initial 最后有 $stop / $finish → -all
#         没有 → 把 initial 里所有 #延时加起来，再多给一些，比如加起来 335 就写 1us
#         （没有 $stop 还写 -all 会一直跑下去不停，只能点 ModelSim 工具栏的 Break）
#         波形没跑完：Transcript 里输入 run 500ns 接着跑
#   RADIX 输出是 BCD（电子钟）→ hex；其他 → unsigned。跑完也能在波形里右键信号 → Radix 改
# =============================================================================

set TB    tb_template                         ;# tb 的模块名（module 后面的名字，不是文件名）
set SRCS  {t00_skeleton.v t13_tb_template.v}  ;# 所有 .v 文件，空格隔开
set TIME  -all                                ;# -all 跑到 $stop；tb 里没有 $stop 就写时长，如 2us
set RADIX unsigned                            ;# 波形数字格式：unsigned / hex（BCD 题用 hex）/ binary

catch {quit -sim}
if {![file exists work]} { vlib work }
eval vlog -work work $SRCS
vsim -voptargs=+acc -onfinish stop work.$TB   ;# +acc：保留内部信号，波形里才看得到；-onfinish stop：tb 用 $finish 时不关掉 ModelSim
if {![batch_mode]} {
    add wave -radix $RADIX -r /*              ;# 所有层次的所有信号；只看 tb 那一层：add wave /$TB/*
}
if {$TIME eq "-all"} { run -all } else { run $TIME }
if {![batch_mode]} { wave zoom full }
