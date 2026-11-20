`timescale 1ns / 1ps
// =============================================================================
// mc_tof_vl53.v  激光测距 VL53-200（维特）：串口收距离（115200 8N1，只收不发）
//
//   模块出厂是"串口模式"：自己每 100 ms（10 Hz）发两行 ASCII（说明书 5.3）：
//       State;0 , Range Valid\r\n     ← 状态号（说明书的表）：0 量到了；1 Sigma Fail；2 Signal Fail（信号太弱）；3 Min Range Fail；
//                                        4 Phase Fail（超出测量范围）；5 Hardware Fail；255 No Update（没有新数据）
//       d:   73 mm\r\n                 ← 距离（毫米）
//   一个字节一个字节地解：
//     "e;" 后面的数字 = 状态号（超过 255 记 255）；"d:" 后面的数字 = 毫米，第一个不是数字的字节 = 这一组结束（两处数字前面的空格都跳过）。
//     一组 = 先有状态、后有距离；前面没有状态的距离行（上电从一组的半中间开始收）丢掉。
//   每一组都把原始状态号、毫米放到 O_st / O_mm（屏幕排查用：模块到底发了什么）。
//   按状态号分两种（11-17 上车：一直显示 255、近处却有 REF HOLD = 两组里总有一组不算，原来把 255 等也当成"前面没东西"）：
//     · 算一次测量：0（量到了）、2 / 4（信号太弱 / 超范围 = 前面没东西）。这一组的距离 r：
//         状态 0 且 MIN_MM ≤ 毫米、厘米 ≤ MAX_CM → 毫米 / 10 − OFFSET_CM（向下取整，再减模块在镜头后面多少 = 离镜头的距离）；否则 255（没东西 / 超出 MAX_CM /
//         比 MIN_MM 近：说明书的截图里前面没东西时也会报 0~33 mm 的"有效"值）。O_upd 打一拍。
//     · 跳过：255（没有新数据）、1 / 3 / 5（这次测得不可靠）和说明书里没有的号：不改距离，也不算"模块还活着"。
//   安装位置（11-20 改）：模块装在车头最前面后面 10 cm（原来 5 cm），镜头没动、还在最前面后面 5 cm → 模块比镜头靠后 OFFSET_CM = 5 cm。
//     量到的毫米 / 10 减掉它才是离镜头的距离（避障画面和跟随的所有门限都从镜头算）；MIN_MM 跟着由 50 改成 100（比模块到车头最前面的 10 cm 还近的不可能是车外面的东西）。
//     MAX_CM 比的是模块的原始读数（模块最远 1.2 m），不减 OFFSET_CM。OFFSET_CM 要是整数厘米、MIN_MM ≥ OFFSET_CM × 10（否则离镜头的距离会减成负数）。
//   O_cm = 最近两次测量的 r 里大的那个：偶尔一次量错的近距离不会让车乱转（要连着两次都近才算）；东西一离开，一次量不到马上就放开。
//     11-18 上车：原始值在 S000 / S255 之间跳、S000 0240mm 时距离还是 255、REF HOLD → 两次测量之间总是先"掉线"了：
//     最可能是模块 300 ms 左右才出一次新测量（S000 后面跟一两个 S255），原来"300 ms 没有测量就掉线"正好卡在边上，
//     每次掉线都把"上一次"清成 255，两次永远凑不齐。所以"没有测量"和"没有字节"分开算：ALIVE_MS（900）和 LINK_MS（300）；
//     O_dt 把真实间隔显示出来。
//     厘米不用除法：读数字时记下"加这一位之前的数"，读完它就是去掉个位的数 = 毫米 / 10。
//   O_near = 最近两次测量的 r 里小的那个 ≤ NEAR_CM（车前这么近有东西 → 它可能快进 / 已经进了地面参考区，避障暂停学地面）。
//     和 O_cm 反过来取：停学地面代价小，一次近就停（早一次）；转向代价大，要两次都近才算。掉线 = 0（照常学）。
//   掉线：ALIVE_MS 没有一次测量 → O_cm = 255、O_alive = 0（跟随退回只用相机）；LINK_MS 一个字节都没收到 → O_link = 0
//     （线上安静一会儿只说明线上没字节，不清距离；距离要 ALIVE_MS 没有测量才清）。
//   O_dt = 最近两次测量隔了多少毫秒（到 ALIVE_MS 不再加；屏幕排查用：模块多久出一次新测量）。
//   MAX_CM 不能超过 254（255 = 没有）；ALIVE_MS、LINK_MS 不能超过 999（10 位计数、屏幕 3 位）。
// =============================================================================
module mc_tof_vl53 #(
    parameter CLK_HZ     = 100_000_000,
    parameter BAUD       = 115200,
    parameter MIN_MM     = 100,         // 比这近的不算：模块在车头最前面后面 10 cm，比 10 cm 近的不可能是车外面的东西（没东西时也会报几毫米）
    parameter OFFSET_CM  = 5,           // 模块在镜头后面多少厘米（模块离车头最前 10 cm − 镜头离车头最前 5 cm）：量到的距离减掉它 = 离镜头的距离；整数厘米，MIN_MM ≥ 它 × 10
    parameter MAX_CM     = 120,         // 比这远当作没有（模块默认"一般模式"最远 1.2 m）
    parameter NEAR_CM    = 80,          // O_near 的门限
    parameter ALIVE_MS   = 900,         // 这么久没有一次测量 = 掉线（车上的模块约 300 ms 一次测量，留 2 次的余量）
    parameter LINK_MS    = 300          // 这么久一个字节都没收到 = 线上没动静（模块 100 ms 一组）
)(
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_tick_1ms,
    input  wire        I_rx,            // 模块 TXD（脚上开了上拉）
    output reg  [7:0]  O_cm,            // 前面最近的东西（厘米，离镜头：模块的读数减 OFFSET_CM）；255 = 没有 / 没量到 / 掉线
    output reg         O_upd,           // 每次测量（算数的一组）打一拍
    output reg         O_near,          // 最近两次测量里有一次 ≤ NEAR_CM
    output wire        O_alive,         // ALIVE_MS 内有过一次测量（屏幕 OK）
    output wire        O_link,          // LINK_MS 内收到过字节（0 = 线上没动静，屏幕 NOLK）
    output reg  [9:0]  O_dt,            // 最近两次测量隔了多少毫秒（≤ ALIVE_MS）
    output reg  [7:0]  O_st,            // 最近一组的原始状态号（0~255，超过 255 记 255）
    output reg  [13:0] O_mm             // 最近一组的原始毫米（超过 4 位记 9999）
);

wire       S_v;
wire [7:0] S_b;
mc_uart_rx #(.CLK_HZ (CLK_HZ), .BAUD (BAUD)) u_rx (
    .I_clk (I_clk), .I_rst_n (I_rst_n), .I_rx (I_rx), .O_valid (S_v), .O_data (S_b)
);

localparam [1:0] P_IDLE = 2'd0, P_ST = 2'd1, P_MM = 2'd2;
localparam [7:0] OFF8 = OFFSET_CM;      // 模块在镜头后面多少厘米（8 位，做减法用）
reg  [1:0]  S_md;                       // 正在读：0 什么都不读（找 "e;" / "d:"）、1 状态号、2 毫米
reg  [7:0]  S_prev;                     // 上一个字节
reg         S_sd;                       // 状态号读到过数字
reg  [7:0]  S_stn;                      // 正在读的状态号（超过 255 记 255）
reg         S_hs;                       // 有一个状态在等距离行
reg  [7:0]  S_st;                       // 它的状态号
reg         S_dd;                       // 距离读到过数字
reg  [13:0] S_mm;                       // 毫米（4 位以内）
reg  [9:0]  S_cmv;                      // 加最后一位之前的数 = 毫米 / 10
reg         S_big;                      // 超过 4 位
reg  [7:0]  S_r1;                       // 上一次测量的 r
reg  [9:0]  S_ta, S_tl;                 // 上一次测量 / 上一个字节以后多少毫秒（到 ALIVE_MS / LINK_MS 不再加）

wire        S_dig  = (S_b >= 8'h30) && (S_b <= 8'h39);
wire [13:0] S_mm10 = {S_mm[10:0], 3'd0} + {S_mm[12:0], 1'b0} + {10'd0, S_b[3:0]};   // × 10 + 这一位（S_mm < 1000 时才用）
wire [7:0]  S_st10 = {S_stn[4:0], 3'd0} + {S_stn[6:0], 1'b0} + {4'd0, S_b[3:0]};    // × 10 + 这一位（S_stn ≤ 25 时才用，最大 255）
wire        S_stov = (S_stn > 8'd25) || (S_stn == 8'd25 && S_b[3:0] > 4'd5);       // 再加这一位就超过 255
wire        S_meas = (S_st == 8'd0) || (S_st == 8'd2) || (S_st == 8'd4);           // 算一次测量（其余跳过）
wire        S_ok   = (S_st == 8'd0) && !S_big && (S_mm >= MIN_MM) && (S_cmv <= MAX_CM);
wire [7:0]  S_r    = S_ok ? (S_cmv[7:0] - OFF8) : 8'd255;                                    // 这一次测量的 r

assign O_alive = (S_ta != ALIVE_MS);
assign O_link  = (S_tl != LINK_MS);

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        S_md <= P_IDLE; S_prev <= 8'd0; S_sd <= 1'b0; S_stn <= 8'd0; S_hs <= 1'b0; S_st <= 8'd0;
        S_dd <= 1'b0; S_mm <= 14'd0; S_cmv <= 10'd0; S_big <= 1'b0; S_r1 <= 8'd255;
        S_ta <= ALIVE_MS; S_tl <= LINK_MS;
        O_cm <= 8'd255; O_upd <= 1'b0; O_near <= 1'b0; O_st <= 8'd0; O_mm <= 14'd0; O_dt <= 10'd0;
    end else begin
        O_upd <= 1'b0;
        if (I_tick_1ms) begin
            if (S_ta != ALIVE_MS) S_ta <= S_ta + 10'd1;
            if (S_ta == ALIVE_MS - 1) begin O_cm <= 8'd255; S_r1 <= 8'd255; O_near <= 1'b0; end
            if (S_tl != LINK_MS) S_tl <= S_tl + 10'd1;
        end
        if (S_v) begin                                              // 收到一个字节（写在后面：和超时同一拍时以这里为准）
            S_prev <= S_b; S_tl <= 10'd0;
            case (S_md)
                P_ST: if (S_dig) begin
                          S_sd <= 1'b1;
                          S_stn <= S_stov ? 8'd255 : S_st10;
                      end else if (!(S_b == 8'h20 && !S_sd)) begin  // 不是数字前面的空格：状态号读完
                          S_hs <= S_sd; S_st <= S_stn; S_md <= P_IDLE;
                      end
                P_MM: if (S_dig) begin
                          S_dd <= 1'b1;
                          if (S_mm >= 14'd1000) S_big <= 1'b1;
                          else begin S_cmv <= S_mm[9:0]; S_mm <= S_mm10; end
                      end else if (!(S_b == 8'h20 && !S_dd)) begin  // 不是数字前面的空格：这一组结束
                          if (S_hs && S_dd) begin
                              O_st <= S_st; O_mm <= S_big ? 14'd9999 : S_mm;
                              if (S_meas) begin
                                  O_upd <= 1'b1; S_ta <= 10'd0;
                                  O_dt <= (I_tick_1ms && S_ta != ALIVE_MS) ? S_ta + 10'd1 : S_ta;   // 和节拍同一拍：这个节拍也算上（S_ta 这一拍不加了）
                                  S_r1 <= S_r; O_cm <= (S_r > S_r1) ? S_r : S_r1;
                                  O_near <= (S_r <= NEAR_CM) || (S_r1 <= NEAR_CM);
                              end
                          end
                          S_hs <= 1'b0; S_md <= P_IDLE;
                      end
                default: if (S_b == 8'h3B && S_prev == 8'h65) begin          // "e;"
                             S_md <= P_ST; S_sd <= 1'b0; S_stn <= 8'd0;
                         end else if (S_b == 8'h3A && S_prev == 8'h64) begin // "d:"
                             S_md <= P_MM; S_dd <= 1'b0; S_mm <= 14'd0; S_cmv <= 10'd0; S_big <= 1'b0;
                         end
            endcase
        end
    end
end

endmodule
