// =============================================================================
// t00 模块骨架 + 语法速查
// 用法：把题目的"程序头"整段贴进来替换 module 头（模块名、端口名、位宽一个字都不改），
//       再按下面 1~4 的顺序往里填。
// =============================================================================
module skeleton (
    input            clk,
    input            rst_n,       // 名字带 _n、tb 一开始给 0 → 低电平复位
    input            en,
    input      [7:0] din,
    output reg [7:0] dout_r,      // 程序头写了 output reg → 直接在 always 里赋值
    output     [7:0] dout_w,      // 程序头没写 reg → 用 assign 接出去
    output           flag
);

// 参数也可写在 module 名后：module m #(parameter W=8)(input [W-1:0] din); ... endmodule
// parameter 可在例化时改；localparam 是模块内部常量。普通 Verilog 不把它们写在 module 外。
// ---- 1. 常量：localparam 只在模块内部用；parameter 例化时可以改 ----
localparam MAX = 8'd99;

// ---- 2. 内部信号：要"记住"的量用 reg；连线 / 组合结果用 wire ----
reg  [7:0] cnt;
wire       cnt_end = (cnt == MAX);         // 声明时直接给式子 = 一条 assign

// ---- 3. 时序逻辑：always @(posedge clk ...) 里一律用 <= ----
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        cnt <= 8'd0;                       // 复位值
    else if (en) begin
        if (cnt_end) cnt <= 8'd0;
        else         cnt <= cnt + 8'd1;
    end                                    // 没写到的情况 = 保持原值
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) dout_r <= 8'd0;
    else        dout_r <= din;             // 打一拍：dout_r 比 din 晚一个时钟
end

// ---- 4. 组合逻辑：assign，或者 always @(*) 里用 = ----
assign dout_w = cnt;
assign flag   = en & cnt_end;

endmodule

// =============================================================================
// 语法速查
// -----------------------------------------------------------------------------
// 数字    位宽'进制数值：4'b1010  8'hFF  8'd59  1'b1；不写位宽（如 0、10）按 32 位算
//         8'h59 = 0101_1001（BCD 的 59）；8'd59 = 0011_1011（二进制 59）。h 只是十六进制
// 运算    + - * / %    & | ^ ~（按位）   && || !（逻辑）   == != < <= > >=
//         << >>（移位）  &a（a 的所有位相与）  |a（a 有任一位为 1）  ^a（奇偶）
//         c ? x : y    {a, b}（拼接）   {4{1'b0}}（重复 4 次）   a[7:4]（取几位）
// 位宽    结果按最宽的操作数 / 左边算，多出来的高位被截掉：4'd15 + 4'd1 存进 4 位是 0
//         要进位就多开一位：wire [8:0] s = a + b;（a、b 是 8 位）
// case    case (sel)  2'd0: ...;  2'd1, 2'd2: ...;  default: ...;  endcase
// for     integer i;  always @(*) for (i = 0; i < 4; i = i + 1) y[i] = a[3-i];  // 位反转
//         for 只是"复制 4 份电路"的简写，不是循环执行
// 复位    异步低有效：always @(posedge clk or negedge rst_n)  if (!rst_n) ...  复位一来马上生效，敏感表里要有 rst_n
//         同步高有效：always @(posedge i_clk)                if (i_rst)  ...  只在时钟沿检查复位，敏感表里只有时钟
//         clk / i_clk、rst_n / i_rst 都只是端口名，照抄题目程序头
//         极性必须和题目一致；同步 / 异步题目没说时两种都行
// 输出    output reg x → always 里给 x 赋值；output x → 只能 assign x = ...;
// 规则    ① 带 posedge 的 always 用 <=，always @(*) 用 =
//         ② 一个 reg 只在一个 always 里赋值（两个 always 都改它 = 两个电路抢一根线）
//         ③ always @(*) 里每个被赋值的变量在每条路径上都要有值（开头先给默认值），否则生成锁存器
//         ④ #延时、initial、$display 只在 tb 里用，设计文件里不写
//         ⑤ 设计文件不用写 `timescale（写了就和 tb 写一样的）
// =============================================================================
