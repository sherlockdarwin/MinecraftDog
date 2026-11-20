// 游戏机自动计费（24 年能力测试 / 国赛测试1 题二）
// 1 拍 = 1 分钟，1 个单位 = 1 元
// 题目没写死、这里自己定的规则（评委问起来要能说清楚）：
//   · 模式由当前 boost 决定，这一拍就按新模式计费
//   · 体验（2'b11）：复位后第一次选 11 开始，免费 5 拍；5 拍到了回普通（boost 还是 11 也按普通收费）；
//     中途换走算用掉；用过以后再选 11 → 按普通收费
//   · 关机（2'b00）不收费；任何模式下 set 都能充值
//   · set 和扣费在同一拍：先加充值再扣费，一句赋值算出新余额；不够扣时停在 0，超过 1023 停在 1023
//   · yellow：余额 < 10；red：余额 = 0
module game_count(
input rst_n,
input clk,
input [9:0]money,
input set,
input [1:0]boost,
output [9:0]remain,
output yellow,
output red
);

reg [9:0] r_remain;
reg       trial_used;              // 复位后已经开始过体验
reg       trial_on;                // 正在体验
reg [2:0] trial_cnt;               // 已经体验了几分钟

wire in_trial = (boost == 2'b11) && (trial_on || !trial_used);   // 这一分钟是免费体验

wire [1:0] cost = (boost == 2'b00) ? 2'd0 :    // 关机
                  (boost == 2'b10) ? 2'd2 :    // 畅玩
                  in_trial         ? 2'd0 :    // 体验
                                     2'd1;     // 普通（01，或体验用过后的 11）

wire [10:0] sum  = r_remain + (set ? money : 10'd0);       // 11 位，两个 10 位数相加不会溢出
wire [10:0] left = (sum >= cost) ? (sum - cost) : 11'd0;   // 不够扣 → 0

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)       r_remain <= 10'd0;
    else if (left[10]) r_remain <= 10'd1023;
    else              r_remain <= left[9:0];
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        trial_used <= 1'b0;
        trial_on   <= 1'b0;
        trial_cnt  <= 3'd0;
    end else if (in_trial) begin
        trial_used <= 1'b1;
        if (trial_cnt == 3'd4)                       // 这是第 5 分钟
            trial_on <= 1'b0;
        else begin
            trial_on  <= 1'b1;
            trial_cnt <= trial_cnt + 3'd1;
        end
    end else
        trial_on <= 1'b0;                            // 不在体验（或中途换走了）
end

assign remain = r_remain;
assign yellow = (r_remain < 10'd10);
assign red    = (r_remain == 10'd0);

endmodule
