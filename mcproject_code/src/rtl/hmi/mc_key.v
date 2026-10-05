`timescale 1ns / 1ps
// =============================================================================
// mc_key.v  按键扫描：去抖 + 短按 / 长按识别（N 个键并行，互不影响）
//
// 逻辑照搬 TI2026H 的 key.c：
//   · 每个扫描节拍（I_tick）读一次按键；连续 DEBOUNCE_MS 读到同一个值才算"稳定"；
//   · 稳定按下后开始计时；按住满 LONG_MS 的那一刻给一个"长按"脉冲（只给一次）；
//   · 松手时：如果这次按下没有触发过长按 → 给一个"短按"脉冲；触发过长按的松手不再给短按。
// 区别：C 里是 1ms 中断每 5ms 调一次 Key()，事件存进一个全局变量等主循环去取；
//       这里扫描节拍就是 mc_tick 的 10 ms 脉冲，事件是"单周期脉冲"输出，
//       谁要用谁在同一个时钟下直接接这根线（状态机里 if (S_key_short[0]) ... 即可），不需要"取走/消费"。
//
// 输出（都在 I_clk 时钟域；脉冲宽度 1 个 I_clk 周期）：
//   O_pressed[i]  去抖后的"按下中"电平（相当于 C 里的 Key_Is_Pressed）
//   O_down[i]     按下被确认的那一刻（比物理按下晚 DEBOUNCE_MS）
//   O_short[i]    短按：松手确认时给出
//   O_long[i]     长按：按住满 LONG_MS 时给出（人还没松手）
// 复位后第一次扫描如果键正被按住（例如长按 SW1 复位后手还没松）：不产生任何事件，松手后恢复正常。
// =============================================================================
module mc_key #(
    parameter N           = 3,          // 按键个数
    parameter TICK_MS     = 10,         // 扫描周期，必须等于 I_tick 的周期（毫秒）
    parameter DEBOUNCE_MS = 20,         // 去抖时间
    parameter LONG_MS     = 800,        // 长按判定时间
    parameter ACTIVE_LOW  = 1           // 1：按下为低电平（板上按键接地）
)(
    input  wire         I_clk,
    input  wire         I_rst_n,
    input  wire         I_tick,         // 每 TICK_MS 一个单周期脉冲（mc_tick 的 O_tick_10ms）
    input  wire [N-1:0] I_key,          // 按键引脚原始电平（异步，内部做两级同步）
    output wire [N-1:0] O_pressed,
    output wire [N-1:0] O_down,
    output wire [N-1:0] O_short,
    output wire [N-1:0] O_long
);

reg [N-1:0] S_sync1;
reg [N-1:0] S_sync2;

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        S_sync1 <= {N{(ACTIVE_LOW != 0) ? 1'b1 : 1'b0}};    // 复位值 = 松开状态
        S_sync2 <= {N{(ACTIVE_LOW != 0) ? 1'b1 : 1'b0}};
    end else begin
        S_sync1 <= I_key;
        S_sync2 <= S_sync1;
    end
end

wire [N-1:0] S_raw = (ACTIVE_LOW != 0) ? ~S_sync2 : S_sync2;     // 1 = 按下

genvar i;
generate
    for (i = 0; i < N; i = i + 1) begin : G_KEY
        mc_key_one #(
            .DEB_N  ((DEBOUNCE_MS + TICK_MS - 1) / TICK_MS),
            .LONG_N ((LONG_MS     + TICK_MS - 1) / TICK_MS)
        ) u_one (
            .I_clk     (I_clk),
            .I_rst_n   (I_rst_n),
            .I_tick    (I_tick),
            .I_raw     (S_raw[i]),
            .O_pressed (O_pressed[i]),
            .O_down    (O_down[i]),
            .O_short   (O_short[i]),
            .O_long    (O_long[i])
        );
    end
endgenerate

endmodule


// -----------------------------------------------------------------------------
// 单个按键的状态机（DEB_N / LONG_N 的单位都是"扫描节拍个数"）
// -----------------------------------------------------------------------------
module mc_key_one #(
    parameter DEB_N  = 2,               // 去抖需要的连续相同节拍数（1~255）
    parameter LONG_N = 80               // 长按需要的节拍数
)(
    input  wire I_clk,
    input  wire I_rst_n,
    input  wire I_tick,
    input  wire I_raw,                  // 1 = 按下（已同步）
    output reg  O_pressed,
    output reg  O_down,
    output reg  O_short,
    output reg  O_long
);

reg        S_init;                      // 1 = 复位后还没扫描过
reg        S_last;                      // 上一个节拍读到的原始值
reg [7:0]  S_deb;                       // 原始值已连续不变的节拍数（到 DEB_N 封顶）
reg [15:0] S_press;                     // 按下确认后经过的节拍数（封顶 65535）
reg        S_long_sent;                 // 本次按下已经给过长按

wire       S_changed = (I_raw != S_last);
wire [7:0] S_deb_nx  = S_changed ? 8'd0 : ((S_deb < DEB_N) ? (S_deb + 8'd1) : S_deb);
wire       S_accept  = !S_changed && (S_deb_nx == DEB_N) && (I_raw != O_pressed);

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        S_init      <= 1'b1;
        S_last      <= 1'b0;
        S_deb       <= 8'd0;
        S_press     <= 16'd0;
        S_long_sent <= 1'b0;
        O_pressed   <= 1'b0;
        O_down      <= 1'b0;
        O_short     <= 1'b0;
        O_long      <= 1'b0;
    end else begin
        O_down  <= 1'b0;
        O_short <= 1'b0;
        O_long  <= 1'b0;

        if (I_tick) begin
            if (S_init) begin
                // 第一次扫描：当前电平直接当作稳定状态，不产生事件
                S_init      <= 1'b0;
                S_last      <= I_raw;
                S_deb       <= DEB_N;
                O_pressed   <= I_raw;
                S_long_sent <= I_raw;       // 正被按住：这次按下作废（也不会再给短按），直到松手
                S_press     <= 16'd0;
            end else begin
                S_last <= I_raw;
                S_deb  <= S_deb_nx;

                if (S_accept) begin
                    O_pressed <= I_raw;
                    S_press   <= 16'd0;
                    if (I_raw) begin                    // 按下确认
                        O_down      <= 1'b1;
                        S_long_sent <= 1'b0;
                    end else begin                      // 松手确认
                        if (!S_long_sent) O_short <= 1'b1;
                        S_long_sent <= 1'b0;
                    end
                end else if (O_pressed) begin           // 按住中：计时，满 LONG_N 给一次长按
                    if (S_press != 16'hFFFF) S_press <= S_press + 16'd1;
                    if (!S_long_sent && (S_press + 16'd1 >= LONG_N)) begin
                        O_long      <= 1'b1;
                        S_long_sent <= 1'b1;
                    end
                end
            end
        end
    end
end

endmodule
