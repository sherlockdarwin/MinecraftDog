# VS Code + ModelSim + TerosHDL 配置

## 环境变量

不用新加，本机已经有：

- `PATH` 里有 `D:\Modelsim10.4\win64`：终端里能直接用 `vsim`、`vlog`、`vlib`。
- `MGLS_LICENSE_FILE = D:\Modelsim10.4\win64\LICENSE.TXT`：ModelSim SE 的许可证。

检查：VS Code 终端输入 `vsim -version`，打出 `ModelSim SE-64 vsim 10.4` 就行。换电脑考试的话这两个都要有。
TerosHDL 不需要环境变量。

## 已经改好的 VS Code 设置

在用户设置 `settings.json` 里加了两行（界面里：设置 → 搜索 `ctags path` / `modelsim work` 能看到）：

```json
"verilog.linting.modelsim.work": "E:/FPGA/modelsim_lint/work",
"verilog.ctags.path": "E:/FPGA/ctags/ctags.exe"
```

- 第一行：Verilog-HDL 插件用 ModelSim 检查语法时，默认把 `work` 库建在当前文件夹，在 `FPGA速成` 这种中文路径下会静默失败（代码写错了也不标红）。指到英文路径的库就好了，这个库已经用 `vlib` 建好。
- 第二行：ctags 的位置，见下一节。

## ctags

ctags 给代码建"名字在哪定义"的索引（模块、端口、wire、reg、localparam）。有了它：

- Ctrl+单击信号名，或按 F12：跳到定义处
- 鼠标停在信号名上：显示它的声明（位宽）
- Ctrl+Shift+O：列出文件里所有信号，输入名字快速跳转

下载的是 Universal Ctags 6.1.0（GitHub `universal-ctags/ctags-win32` 官方发布），放在 `E:\FPGA\ctags\ctags.exe`，已经试过能认出 Verilog 的模块、端口、wire、localparam。

谁用它：你装的 **Verilog-HDL** 插件（作者 mshr-h）要靠外部的 ctags，默认找 PATH 里的 `ctags`，找不到就没有跳转——上面第二行设置就是给它指路，不用加 PATH。**TerosHDL 自己带了一个 ctags**（插件目录里，比较老的版本），不用配置。

## TerosHDL 的几个功能

打开一个 `.v` 文件，编辑器右上角那一排图标就是（也可以 Ctrl+Shift+P 搜 TerosHDL）。

- **Schematic viewer（原理图）**：用内置的 Yosys 把代码综合成电路，画出寄存器、选择器、加法器和连线。"网表"（netlist）就是"电路由哪些元件组成、它们怎么连"的清单，原理图是把网表画出来。用途：看代码变成了什么电路，查有没有意外生成的锁存器。Yosys 已经打包在插件里，不用联网。
- **State machine viewer（状态机图）**：从 `case (state)` 里找出所有状态和跳转条件，画成圆圈加箭头。用来检查跳转有没有写错、有没有走不到的状态。
- **Generate template（生成模板）**：对当前文件的模块生成代码，复制到剪贴板。选项有 `Copy as Verilog instance`（例化代码）、`Copy as Verilog testbench`（tb 骨架）、`Copy as signal`（按端口生成 wire / reg 声明）等。
- **Module documentation preview**：把端口列表生成一份文档。
- **Format**：整理缩进。
- **Verify Setup**（Ctrl+Shift+P → `TerosHDL: Verify Setup`）：检查工具找不找得到。

考试只验波形，这些都是辅助，不用也行。

## 例化是什么，考试用不用

模块 ≈ 一张电路图纸，例化 = 按图纸放一块真的电路，并把它的引脚接到线上。写法：

```verilog
//模块名      实例名  (.模块的端口(接到的信号), ...);
serial_lock  u_dut   (.clk(clk), .rst_n(rst_n), .unlock(unlock) /* ... */);
```

"生成例化"就是 TerosHDL 读你的模块端口，自动写出上面这段，省得一个个敲端口名。

考试用不到：题目 tb 里已经写好了例化（`top test(...)`、`serial_lock u_dut(...)`），你只写模块本身。只有两种情况会用：自己写 tb 补测；或者把一道题拆成几个小模块，再在题目要求的那个模块里例化它们（`verilog_templates/t02_bcd.v` 的 `clock_hms` 就是例化了三个 `bcd2`）。

## initial 和"激励"

对。整个 tb 文件常被叫作"激励文件"（testbench），它不是电路，只负责给你的模块喂输入。里面：

- `always #5 clk = ~clk;` 产生时钟
- `initial begin ... end` 从 0 时刻开始按顺序执行一遍：什么时候松开复位、什么时候按键、等多久——这一串输入变化就叫"激励"
- `#10` 等 10 个时间单位，`@(posedge clk)` 等下一个上升沿，`wait (x == 1)` 等到条件成立，`$stop` 暂停仿真

考试的 tb 是题目写好的，你只需要读懂它：从 `initial` 里按顺序列出"第几 ns 输入变成什么"，再对照波形看你的输出对不对。设计文件里不写 `initial` 和 `#延时`。

## 可能遇到的小问题

- **每个 .v 文件第一行都标红**：TerosHDL 的语法检查找不到 ModelSim，报 `Failed to open ini file "modelsim.ini"` / `Execution of vlib failed`，这条错没有行号，就画在第 1 行，和代码无关。原因是它只用 `vlog` 这个名字去启动，ModelSim 10.4 这样启动时找不到自己的安装目录。修法：Ctrl+Shift+P → `TerosHDL: Open Global Settings Menu` → 左边 Tools 下的 **ModelSim** → `Installation path` 填 `D:\Modelsim10.4\win64` → 点 **Apply**，再随便改一下文件保存，红线就消失（实测用完整路径启动就能正常检查，写错时报的是真正的行号）。不想折腾也可以直接关掉它：同一个菜单 Linter → Verilog/SV linter 选 disabled（Verilog-HDL 插件的检查是好的，日志里每个文件都是 0 错误）。
- 同一个错误提示出现两遍：Verilog-HDL 和 TerosHDL 都在用 ModelSim 检查语法。嫌乱就关一个：VS Code 设置里 `verilog.linting.linter` 改成 `none`，或者 TerosHDL 的 Global Settings → Linter 里把 Verilog linter 设成 disabled。
- 粘贴代码后缩进变了：你开了 `editor.formatOnPaste` / `formatOnSave`，是格式化器在整理缩进，不影响功能。
