# Verilog 常用语法模板与仿真指南

## 1. 模块和端口

```verilog
module example (
    input wire clk,
    input wire rst_n,
    input wire en,
    output reg [3:0] count,
    output wire done
);
// 逻辑写在这里
assign done = (count == 4'd9);
endmodule
```

- `input` 是输入，`output` 是输出，`[3:0]` 是 4 位，从高位到低位。
- `wire` 通常表示连线；在 Verilog 中，`always` / `initial` 赋值的变量须声明为 `reg`，`assign` 驱动 net（如 `wire`）。`reg` 不一定代表物理寄存器，具体看逻辑。
- 题目如果写 `output [3:0] count`，默认是 wire：可以用内部 `reg` 配合 `assign count = 内部变量;`。按题目保留模块名、端口名、位宽和功能。
- `//` 单行注释，`/* ... */` 多行注释；Verilog 区分大小写，每条语句通常以分号结束，`begin`/`end` 成对。

## 2. 数值、位宽和运算

`位宽'进制数字`：`4'b1010` 二进制，`8'h59` 十六进制，`8'd59` 十进制。`h` 表示十六进制，不表示 BCD。`8'h59` 的位模式是 `0101_1001`：按二进制整数解释是十进制 89；如果约定两个半字节分别存十位和个位，它可以表示 BCD 的 59。`8'd59` 是 `0011_1011`，不是 BCD 的 59。

- `a[7:4]` 切片；`{a,b}` 拼接，例如 `{4'd5,4'd9}` 为 `8'h59`。
- `+ - *` 算术，`& | ^ ~` 按位，`&& || !` 逻辑，`== != < >=` 比较；`cond ? a : b` 条件选择。
- 运算和赋值会受位宽、符号影响，溢出可能截断；需要进位时明确扩宽，例如 `wire [8:0] sum = {1'b0,a} + {1'b0,b};`（a、b 均为 8 位）。
- 普通二进制直接加一不等于 BCD 加一：`8'h09 + 1` 是 `8'h0a`，BCD 的下一位应为 `8'h10`。
- X 表示未知，Z 表示高阻；仿真中应检查 X 的来源，如未复位或多驱动。一般使用 `==` 比较，测试中精确比较 X/Z 时可用 `===`。

## 3. 时序逻辑：寄存器和计数器

```verilog
reg [3:0] count;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        count <= 4'd0;
    else if (en) begin
        if (count == 4'd9)
            count <= 4'd0;
        else
            count <= count + 4'd1;
    end
end
```

这是低有效**异步**复位，`rst_n` 下降时不等时钟就复位。同步复位写 `always @(posedge clk)`，在块内判断复位。复位极性与同步/异步须按题意确定。未使能时不赋值意味着保持原值。

计数 N 个上升沿：复位计数器为 0，以 `cnt == N-1` 作为末拍判断，命中时清零；需要足够位宽，例如数 0 到 9 至少 4 位。明确第一个计数沿和状态切换沿，避免多一拍或少一拍。

## 4. 组合逻辑：阻塞赋值和默认值

```verilog
reg [1:0] next_state;
always @(*) begin
    next_state = state;       // 默认保持，防止路径漏赋值
    case (state)
        2'd0: if (start) next_state = 2'd1;
        2'd1: if (done)  next_state = 2'd0;
        default: next_state = 2'd0;
    endcase
end
```

以上片段需要在模块中声明 `state`、`start`、`done`。组合块内对每个输出在所有路径赋值，否则可能推断锁存器。`case` 常给 `default`。`assign y = a & b;` 是连续赋值，也可实现组合逻辑。

## 5. `=` 与 `<=`

- 时钟触发的寄存器逻辑通常用非阻塞 `<=`；组合 `always @(*)` 通常用阻塞 `=`。两者在不同上下文可能有合理例外，初学时先遵循这条规则。
- 在同一时钟沿执行 `a <= b; b <= a;`，右侧读取更新前的值，然后更新，表现为交换。使用 `a = b; b = a;` 顺序执行，第二句读到更新后的 a，结果两者都变成原 b。
- 在一个时序块中同一变量被多个非阻塞赋值时，实际生效的是最后执行到的赋值；应整理优先级或先算下一值。不要让多个过程块驱动同一个寄存器，否则容易出现竞争或不可综合行为。
- `<=` 在条件表达式中也可能是“小于等于”，由上下文区分。

## 6. 两段式状态机

```verilog
module fsm_example(input wire clk, input wire rst_n,
                   input wire start, input wire done,
                   output wire busy);
    localparam IDLE = 1'b0, RUN = 1'b1;
    reg state, next_state;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= IDLE;
        else        state <= next_state;
    end
    always @(*) begin
        next_state = state;
        case (state)
            IDLE: if (start) next_state = RUN;
            RUN:  if (done)  next_state = IDLE;
            default: next_state = IDLE;
        endcase
    end
    assign busy = (state == RUN);
endmodule
```

先列出状态、切换条件和输出，再写逻辑。与计数器配合时，明确进入状态后哪一拍开始计数。声明应放在使用之前以保持兼容性。

## 7. BCD 00–59 计数示例

```verilog
module bcd60(input wire clk, input wire rst, input wire en,
             output reg [7:0] q);
    always @(posedge clk) begin
        if (rst) q <= 8'h00;
        else if (en) begin
            if (q == 8'h59) q <= 8'h00;
            else if (q[3:0] == 4'd9)
                q <= {q[7:4] + 4'd1, 4'd0};
            else
                q <= {q[7:4], q[3:0] + 4'd1};
        end
    end
endmodule
```

同步高有效复位；每个使能的上升沿加一。若用于时钟，分位进位条件为 `en && q == 8'h59`；具体按题目的计时单位和进位要求处理。

## 8. Testbench 模板

```verilog
`timescale 1ns/1ps
module tb;
    reg clk = 0, rst = 1, en = 1;
    wire [7:0] q;
    bcd60 dut(.clk(clk), .rst(rst), .en(en), .q(q));
    always #5 clk = ~clk; // 周期 10 ns
    initial begin
        #12 rst = 0;       // 在下降沿附近释放，避开上升沿竞争
        #600;
        $stop;
    end
endmodule
```

`tb` 是仿真顶层，`bcd60` 是被测模块类型，`dut` 是实例名。`#5` 表示延迟 5 个时间单位，单位由 `timescale` 决定；波形可手工核对，也可添加 `$display`、`$error` 或断言自动检查。只有激励并不代表自动验证结果。尽量不要在被测电路采样的时钟沿用阻塞赋值改变输入，避免仿真竞争；测试题原文件有此情况时先按原题运行，再用独立测试验证边界。

## 9. Windows：VS Code + ModelSim

1. VS Code 创建两个纯文本文件，例如 `clock_12h.v` 与 `tb_clock_12h.v`，后者模块名为 `tb`。语法高亮插件可选，保存文件。
2. 在 ModelSim Transcript 中切换目录，如 `cd {C:/fpga_practice}`，将两个文件放入该目录。建议路径简单且无中文、空格以排除旧版软件兼容问题。
3. 首次在该目录创建库并编译：

```tcl
vlib work
vlog -work work clock_12h.v tb_clock_12h.v
vsim work.tb
add wave sim:/tb/*
run 200 ns
```

`work.tb` 是 testbench 模块名，不是实例名 `test`。在 Wave 中右键输出设置 Radix 为 Hexadecimal（BCD 更直观），并 Zoom Full。看不到内部信号时通过 Objects/Sim 窗格选择实例后添加。ModelSim GUI 可直接显示波形，无需 `$dumpfile` 或 GTKWave。

4. 修改代码后保存，在 Transcript 先 `quit -sim`，再运行 `vlog ...`、`vsim work.tb`、`add wave ...` 和 `run ...`。已有 `work` 时无需每次 `vlib work`。错误先查看 Transcript 里第一条编译错误和文件行号。
5. 先对 testbench 加上明确的 `` `timescale 1ns/1ps ``，保证延迟单位可预期。题目文件务必另存练习副本；考试按组委会要求使用。

`run -all` 会一直运行到 `$stop`、`$finish` 或没有事件；无限时钟但没有结束语句的 tb 不会自己结束，练习时可用 `run 500 ns`。`$stop` 通常暂停以查看波形，`$finish` 结束仿真。版本和界面可能稍有差异。

## 10. 考前检查

- 按题意检查接口、复位电平和优先级、使能、所有状态及每次切换。
- 波形至少覆盖复位、开始/停止、进位、边界值及同时发生的输入；仿真结束或无编译报错不等于功能正确。
- 给关键时间点写预期结果，检查 X、位宽截断、计数偏一拍。提供的 tb 不一定覆盖所有要求。
- 工作区《FPGA国赛测评纪律》禁止考试时网页搜索、询问在线或本地 AI；《能力测评录屏指南》要求录屏。以组委会最新规则为准。
