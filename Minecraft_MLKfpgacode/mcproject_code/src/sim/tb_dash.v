`timescale 1ns / 1ps
// 测试 mc_osd_dash（屏幕中间状态带的文字，5 行 × 45 列，只有一页）+ mc_osd_text 的字符 RAM。
// 每个场景都把整块字符 RAM（225 个字符）和测试台里按版面规则拼出来的期望逐字符比较（多一个、少一个、错位都会报），覆盖：
//   · 全部文字和位置；没有项目的格子必须是空格（复位清屏）；
//   · 数字转换：位数不够显示高位时只显示低位（开机秒数 32 位取低 5 位）、0、最大值、保留前导零；
//     有符号数字（亮度档 −4~+4，显示 '+' / '-' 和一位数；4 位有符号的最大 +7 / 最小 −8）；曝光行数 4 位；
//   · 跟随行：UWB 有 / 没有、有符号角度（8 位：显示低两位）、距离（10 位：显示低三位）、8 个决策状态、左右轮 PWM（14 位有符号，4 位 + 符号）；
//   · 所有状态名（尾巴 / TF 卡 / 编解码器 / 背景音乐 / 音效）、未定义状态值显示 "?"；背景音乐和音效取不同的值（接反能看出来）；
//   · 三个键的电平的 8 种组合、最近一次按键事件（含同时来的优先级）、开机秒数（先让它自己数，再强制成各种值）；
//   · 刷新节奏：复位后第一遍很快就画完（不等 100 ms）、之后每个 100 ms 节拍恰好一遍（两遍之间总线安静）。
// 为了仿真快：1 ms 节拍取 100 个时钟，100 ms 节拍取 10000 个时钟。
module tb_dash;

localparam COLS = 45, ROWS = 5, CELLS = 225;

reg clk = 0, rst_n = 0;
always #5 clk = ~clk;

reg [31:0] cnt = 0;
reg tick1 = 0, tick100 = 0;
always @(posedge clk) begin
    cnt <= cnt + 1;
    tick1   <= (cnt % 100)   == 99;
    tick100 <= (cnt % 10000) == 9999;
end

reg  [2:0] kp = 3'b000, ks = 0, kl = 0;
reg  [7:0] cam_gain = 8'd50;
reg  [11:0] cam_exp = 12'd2275;
reg  [3:0] cam_ev = 4'd4;
reg  [7:0] obs_near = 8'd255, obs_free = 8'd0;
reg  [6:0] obs_ndeg = 7'd0, obs_gdeg = 7'd0;
reg        obs_stop = 1'b1;
reg        uwb_ok = 1'b0;
reg        uwb_link = 1'b0;
reg  [7:0] uwb_deg = 8'd0;
reg  [9:0] uwb_cm = 10'd0;
reg  [2:0] cmd_st = 3'd0;
reg  [13:0] cmd_l = 14'd0, cmd_r = 14'd0;
reg        hall = 0;
reg  [1:0] tail_seq = 2'd0;
reg  [2:0] aud_sd = 3'd1;
reg  [1:0] aud_codec = 2'd1;
reg  [1:0] bgm_state = 2'd2, sfx_state = 2'd0;
wire [19:0] bus;

mc_osd_dash dut (
    .I_clk(clk), .I_rst_n(rst_n), .I_tick_1ms(tick1), .I_tick_100ms(tick100),
    .I_key_pressed(kp), .I_key_short(ks), .I_key_long(kl),
    .I_cam_gain(cam_gain), .I_cam_exp(cam_exp), .I_cam_ev(cam_ev), .I_obs_near(obs_near), .I_obs_near_deg(obs_ndeg), .I_obs_go_deg(obs_gdeg), .I_obs_free(obs_free), .I_obs_stop(obs_stop),
    .I_hall(hall), .I_tail_seq(tail_seq),
    .I_uwb_ok(uwb_ok), .I_uwb_link(uwb_link), .I_uwb_deg(uwb_deg), .I_uwb_cm(uwb_cm), .I_cmd_state(cmd_st), .I_cmd_l(cmd_l), .I_cmd_r(cmd_r),
    .I_aud_sd(aud_sd), .I_aud_codec(aud_codec), .I_bgm_state(bgm_state), .I_sfx_state(sfx_state),
    .O_bus(bus)
);

// 只用它的字符 RAM（像素口不接）
mc_osd_text #(.COLS(COLS), .ROWS(ROWS)) u_text (
    .I_pclk(clk), .I_x(11'd0), .I_y(11'd0), .O_hit(), .O_on(), .I_wclk(clk), .I_wbus(bus)
);

integer errors = 0;

// 任何一项检查失败就马上结束（突变检查时省时间；全部通过时没有影响）
always @(errors) if (errors != 0) begin
    #1;
    $display("FAIL  tb_dash: %0d error(s) so far, aborting early", errors);
    $finish;
end

// ---------------- 期望屏幕 ----------------
reg [7:0] exp_mem [0:CELLS-1];

task put;                                    // 在第 r 行第 c 列起放 len 个字符
    input integer r, c;
    input [8*45-1:0] s;
    input integer len;
    integer k;
    begin
        for (k = 0; k < len; k = k + 1) exp_mem[r*COLS + c + k] = s[(len-1-k)*8 +: 8];
    end
endtask

// 测试台自己的期望值（版面规则）：名字表、事件、数字
reg [63:0] e_evt;                            // 8 字符最近按键事件
reg [39:0] e_sec;                            // 5 字符开机秒数
function [31:0] tail_name;  input [1:0] v; case (v) 2'd0: tail_name = "IDLE"; 2'd1: tail_name = "HOME"; 2'd2: tail_name = "WAG "; default: tail_name = "????"; endcase endfunction
function [31:0] state_name; input [1:0] v; case (v) 2'd0: state_name = "IDLE"; 2'd1: state_name = "OPEN"; 2'd2: state_name = "PLAY"; default: state_name = "ERR "; endcase endfunction
function [31:0] codec_name; input [1:0] v; case (v) 2'd0: codec_name = "INIT"; 2'd1: codec_name = "OK  "; 2'd2: codec_name = "ERR "; default: codec_name = "????"; endcase endfunction
function [47:0] sd_name;    input [2:0] v; case (v) 3'd0: sd_name = "INIT  "; 3'd1: sd_name = "READY "; 3'd2: sd_name = "NO SD "; 3'd3: sd_name = "NO FAT"; 3'd4: sd_name = "BADFAT"; 3'd5: sd_name = "RD ERR"; default: sd_name = "??????"; endcase endfunction
function [23:0] dec3;       input [7:0] v; reg [7:0] h, t, o; begin h = 8'h30 + v / 8'd100; t = 8'h30 + (v / 8'd10) % 8'd10; o = 8'h30 + v % 8'd10; dec3 = {h, t, o}; end endfunction
function [31:0] dec4;       input [11:0] v; reg [7:0] a, b, c, d; begin a = 8'h30 + v / 12'd1000 % 12'd10; b = 8'h30 + v / 12'd100 % 12'd10; c = 8'h30 + v / 12'd10 % 12'd10; d = 8'h30 + v % 12'd10; dec4 = {a, b, c, d}; end endfunction
function [23:0] sdeg;       input [6:0] v; integer e; reg [7:0] s, t, o; begin e = (v > 63) ? v - 128 : v; s = (e < 0) ? 8'h2D : 8'h2B; if (e < 0) e = -e; t = 8'h30 + e / 10; o = 8'h30 + e % 10; sdeg = {s, t, o}; end endfunction   // 7 位有符号 → "±dd"
function [23:0] sdeg8;      input [7:0] v; integer e; reg [7:0] s, t, o; begin e = (v > 127) ? v - 256 : v; s = (e < 0) ? 8'h2D : 8'h2B; if (e < 0) e = -e; t = 8'h30 + (e / 10) % 10; o = 8'h30 + e % 10; sdeg8 = {s, t, o}; end endfunction   // 8 位有符号 → "±dd"（只显示低两位）
function [23:0] dec3w;      input [9:0] v; reg [7:0] a, b, c; begin a = 8'h30 + (v / 100) % 10; b = 8'h30 + (v / 10) % 10; c = 8'h30 + v % 10; dec3w = {a, b, c}; end endfunction   // 10 位 → 低三位
function [39:0] sdec4;      input [13:0] v; integer e; reg [7:0] s, a, b, c, d; begin e = (v > 8191) ? v - 16384 : v; s = (e < 0) ? 8'h2D : 8'h2B; if (e < 0) e = -e;
                            a = 8'h30 + (e / 1000) % 10; b = 8'h30 + (e / 100) % 10; c = 8'h30 + (e / 10) % 10; d = 8'h30 + e % 10; sdec4 = {s, a, b, c, d}; end endfunction   // 14 位有符号 → "±dddd"
function [31:0] cmd_name;   input [2:0] v; case (v) 3'd0: cmd_name = "LOST"; 3'd1: cmd_name = "NCAM"; 3'd2: cmd_name = "HERE"; 3'd3: cmd_name = "BLK "; 3'd4: cmd_name = "TURN"; 3'd5: cmd_name = "GO  "; 3'd6: cmd_name = "AVD "; default: cmd_name = "SPIN"; endcase endfunction
function [15:0] evtxt;      input [3:0] v; integer e; begin e = v - 4; if (e > 7) e = e - 16; evtxt[15:8] = (e < 0) ? 8'h2D : 8'h2B; evtxt[7:0] = 8'h30 + ((e < 0) ? -e : e); end endfunction   // 档位 v → "−4"~"+4"（v 当成 v−4 的 4 位有符号数）

task build_exp;                              // 按当前输入拼出整屏期望
    integer i;
    begin
        for (i = 0; i < CELLS; i = i + 1) exp_mem[i] = 8'h20;
        put(0, 0,  "GAIN ", 5);  put(0, 5, dec3(cam_gain), 3);
        put(0, 10, "HALL ", 5);  exp_mem[15] = hall ? "1" : "0";
        put(0, 18, "TAIL ", 5);  put(0, 23, tail_name(tail_seq), 4);
        put(0, 28, "KEY ", 4);   put(0, 32, {(kp[0] ? "1" : "0"), (kp[1] ? "1" : "0"), (kp[2] ? "1" : "0")}, 3);
        put(0, 36, "UP ", 3);    put(0, 39, e_sec, 5);   put(0, 44, "s", 1);
        put(1, 0,  "SD ", 3);    put(1, 3, sd_name(aud_sd), 6);
        put(1, 10, "CODEC ", 6); put(1, 16, codec_name(aud_codec), 4);
        put(1, 22, "BGM ", 4);   put(1, 26, state_name(bgm_state), 4);
        put(1, 32, "SFX ", 4);   put(1, 36, state_name(sfx_state), 4);
        put(1, 41, "EV", 2);     put(1, 43, evtxt(cam_ev), 2);
        put(2, 0,  e_evt, 8);
        put(2, 10, "SW2/3 EV+/- SW1 2s reset", 24);
        put(2, 35, "EXP ", 4);   put(2, 39, dec4(cam_exp), 4);
        put(3, 0,  "NEAR ", 5);  put(3, 5, dec3(obs_near), 3);  put(3, 8, "cm ", 3);  put(3, 11, sdeg(obs_ndeg), 3);  put(3, 14, "deg", 3);
        put(3, 19, obs_stop ? "STOP" : "GO  ", 4);  put(3, 24, sdeg(obs_gdeg), 3);  put(3, 27, "deg ", 4);  put(3, 31, dec3(obs_free), 3);  put(3, 34, "cm", 2);
        put(4, 0,  "UWB ", 4);  put(4, 4, uwb_ok ? "OK  " : uwb_link ? "LOST" : "NOLK", 4);  put(4, 9, sdeg8(uwb_deg), 3);  put(4, 12, "deg ", 4);  put(4, 16, dec3w(uwb_cm), 3);
        put(4, 19, "cm  CMD ", 8);  put(4, 27, cmd_name(cmd_st), 4);  put(4, 32, "L", 1);  put(4, 33, sdec4(cmd_l), 5);  put(4, 39, "R", 1);  put(4, 40, sdec4(cmd_r), 5);
    end
endtask

task check;
    input [8*50-1:0] name;
    integer i, bad;
    reg [7:0] got;
    begin
        build_exp;
        bad = 0;
        for (i = 0; i < CELLS; i = i + 1) begin
            got = u_text.S_mem[i];
            if (got !== exp_mem[i]) begin
                if (bad < 4) $display("FAIL [%0s] row %0d col %0d: got '%c' (%h) expected '%c'", name, i / COLS, i % COLS, got, got, exp_mem[i]);
                bad = bad + 1;
            end
        end
        if (bad != 0) begin
            $display("FAIL [%0s] %0d cells differ; screen now:", name, bad);
            show;
            errors = errors + 1;
        end
    end
endtask

reg [8*COLS-1:0] line;
task show; integer r, c; begin
    for (r = 0; r < ROWS; r = r + 1) begin
        for (c = 0; c < COLS; c = c + 1) line[(COLS-1-c)*8 +: 8] = u_text.S_mem[r*COLS + c];
        $display("   |%0s|", line);
    end
end endtask

// 刷新节奏监视：总线上的写使能连成一串 = 一遍（两次写之间隔 > 2000 个时钟算新的一遍）
integer clkn = 0, last_we = -1000000, burst_n = 0;
always @(posedge clk) begin
    clkn <= clkn + 1;
    if (bus[19]) begin
        if (clkn - last_we > 2000) burst_n = burst_n + 1;
        last_we = clkn;
    end
end
// 复位后 65000 个时钟（6.5 个 100 ms 节拍）：第 0 遍（复位清屏 + 第一遍文字）+ 第 1~6 个节拍各一遍 = 7 遍
initial begin
    repeat (65000) @(posedge clk);
    if (burst_n != 7) begin $display("FAIL refresh rhythm: %0d write bursts in the first 65000 clocks, expected 7 (first pass + one per 100 ms tick)", burst_n); errors = errors + 1; end
end

task settle; begin repeat (25000) @(posedge clk); end endtask     // 2.5 个 100 ms 节拍（至少完整刷新一遍）

// 一个时钟的按键脉冲
task pulse_short; input integer k; begin @(posedge clk); ks <= (3'd1 << k); @(posedge clk); ks <= 3'd0; end endtask
task pulse_long;  input integer k; begin @(posedge clk); kl <= (3'd1 << k); @(posedge clk); kl <= 3'd0; end endtask

initial begin
    e_evt = "--------"; e_sec = "00000";
    // ---- 复位前整块 RAM 内容不确定；复位后清屏 + 画第一遍（约 1 ms）----
    #100 rst_n = 1;
    // 复位后 3000 个时钟（远小于第一个 100 ms 节拍 = 10000 个时钟）：第一遍就应该画完了（"约 1 ms 画第一遍"）
    repeat (3000) @(posedge clk);
    check("first pass within 3000 clocks after reset");
    repeat (147000) @(posedge clk);

    // 开机秒数先不强制，让它自己数：复位后每 10 个 100 ms 节拍加 1，约 99 个节拍时应该是 9
    repeat (800000) @(posedge clk);
    settle;
    e_sec = "00009";
    check("uptime counts by itself (9 after 99 ticks)");
    force dut.S_sec = 32'd123; e_sec = "00123";
    settle; check("default screen");

    // ---- 相机增益 / 曝光 / 亮度档、霍尔 ----
    cam_gain = 8'd255; cam_exp = 12'd4095; cam_ev = 4'd8; hall = 1; settle; check("gain 255, exp 4095, EV+4, hall 1");
    cam_gain = 8'd0;   cam_exp = 12'd0;    cam_ev = 4'd0; hall = 0; settle; check("gain 0, exp 0, EV-4, hall 0");
    cam_gain = 8'd109; cam_exp = 12'd1234; cam_ev = 4'd4;           settle; check("gain 109, exp 1234, EV+0");
    cam_gain = 8'd7;   cam_exp = 12'd4;    cam_ev = 4'd3;           settle; check("gain 7, exp 4, EV-1");
    cam_ev = 4'd5;  settle; check("EV+1");
    cam_ev = 4'd11; settle; check("ev 11 -> +7 (largest 4-bit signed)");
    cam_ev = 4'd12; settle; check("ev 12 -> -8 (smallest 4-bit signed)");
    cam_gain = 8'd150; cam_exp = 12'd2275; cam_ev = 4'd4;           settle; check("gain 150, exp 2275, EV+0");

    // ---- 避障：最近的障碍 / 建议方向（有符号角度、STOP / GO）----
    obs_near = 8'd45; obs_ndeg = -7'sd12; obs_gdeg = 7'sd6;  obs_free = 8'd150; obs_stop = 1'b0; settle; check("obstacle 45 cm at -12, go +6 150 cm");
    obs_near = 8'd0;  obs_ndeg = -7'sd34; obs_gdeg = -7'sd29; obs_free = 8'd23; obs_stop = 1'b1; settle; check("obstacle 0 cm at -34, stop");
    obs_near = 8'd123; obs_ndeg = 7'sd34; obs_gdeg = 7'sd29;  obs_free = 8'd99; obs_stop = 1'b0; settle; check("obstacle 123 cm at +34, go +29");
    obs_ndeg = 7'sd63; obs_gdeg = -7'sd64;                                         settle; check("angles +63 / -64 (7-bit extremes)");
    obs_near = 8'd255; obs_ndeg = 7'sd0; obs_gdeg = 7'sd0; obs_free = 8'd0; obs_stop = 1'b1;    settle; check("no obstacle (255)");

    // ---- 跟随：主人在哪、决策状态、左右轮 ----
    uwb_link = 1;
    uwb_ok = 1; uwb_deg = -8'sd12; uwb_cm = 10'd350; cmd_st = 3'd5; cmd_l = 14'sd3000; cmd_r = -14'sd500;  settle; check("UWB -12 350 cm, GO L+3000 R-0500");
    uwb_deg = 8'sd99; uwb_cm = 10'd999; cmd_st = 3'd4; cmd_l = -14'sd8192; cmd_r = 14'sd8191;               settle; check("UWB +99 999 cm, TURN extremes");
    uwb_deg = -8'sd128; uwb_cm = 10'd1023; cmd_st = 3'd3; cmd_l = 14'sd7; cmd_r = -14'sd60;                 settle; check("8-bit -128 -> -28, 1023 -> 023, BLK");
    uwb_deg = 8'sd127; cmd_st = 3'd2; cmd_l = 14'sd0; cmd_r = 14'sd0;                                         settle; check("+127 -> +27, HERE");
    uwb_ok = 0; uwb_deg = 8'sd0; uwb_cm = 10'd0; cmd_st = 3'd1;                                               settle; check("UWB lost, NCAM");
    uwb_link = 0;                                                                                              settle; check("no bytes from STM32 -> NOLK");
    uwb_ok = 1;                                                                                                settle; check("OK wins over the link flag");
    uwb_ok = 0; uwb_link = 1;                                                                                  settle; check("bytes but no frame -> LOST");
    cmd_st = 3'd0;                                                                                             settle; check("LOST");
    cmd_st = 3'd6; settle; check("AVD");
    cmd_st = 3'd7; settle; check("SPIN");
    cmd_st = 3'd0; settle; check("LOST again");

    // ---- 尾巴动作 ----
    tail_seq = 2'd1; settle; check("tail HOME");
    tail_seq = 2'd2; settle; check("tail WAG");
    tail_seq = 2'd3; settle; check("tail undefined -> ????");
    tail_seq = 2'd0; settle; check("tail IDLE");

    // ---- 三个键的电平：8 种组合 ----
    kp = 3'b100; settle; check("keys 100");
    kp = 3'b010; settle; check("keys 010");
    kp = 3'b001; settle; check("keys 001");
    kp = 3'b111; settle; check("keys 111");
    kp = 3'b101; settle; check("keys 101");
    kp = 3'b110; settle; check("keys 110");
    kp = 3'b011; settle; check("keys 011");
    kp = 3'b000; settle; check("keys 000");

    // ---- 最近一次按键事件 ----
    pulse_short(0); settle; e_evt = "K1 SHORT"; check("event K1 short");
    pulse_long(0);  settle; e_evt = "K1 LONG "; check("event K1 long");
    pulse_short(1); settle; e_evt = "K2 SHORT"; check("event K2 short");
    pulse_long(1);  settle; e_evt = "K2 LONG "; check("event K2 long");
    pulse_short(2); settle; e_evt = "K3 SHORT"; check("event K3 short");
    pulse_long(2);  settle; e_evt = "K3 LONG "; check("event K3 long");
    @(posedge clk); ks <= 3'b111; kl <= 3'b111; @(posedge clk); ks <= 0; kl <= 0;      // 同时来：K1 短 > K1 长 > K2 短 > K2 长 > K3 短 > K3 长
    settle; e_evt = "K1 SHORT"; check("event priority: K1 short first");
    @(posedge clk); ks <= 3'b100; kl <= 3'b010; @(posedge clk); ks <= 0; kl <= 0;
    settle; e_evt = "K2 LONG "; check("event priority: K2 long before K3 short");
    @(posedge clk); ks <= 3'b010; kl <= 3'b010; @(posedge clk); ks <= 0; kl <= 0;
    settle; e_evt = "K2 SHORT"; check("event priority: K2 short before K2 long");
    @(posedge clk); ks <= 3'b100; kl <= 3'b100; @(posedge clk); ks <= 0; kl <= 0;
    settle; e_evt = "K3 SHORT"; check("event priority: K3 short before K3 long");

    // ---- 开机秒数：保留前导零、只显示低 5 位 ----
    force dut.S_sec = 32'd7;          e_sec = "00007"; settle; check("uptime 7");
    force dut.S_sec = 32'd99999;      e_sec = "99999"; settle; check("uptime 99999");
    force dut.S_sec = 32'd100000;     e_sec = "00000"; settle; check("uptime 100000 (low 5 digits)");
    force dut.S_sec = 32'hFFFFFFFF;   e_sec = "67295"; settle; check("uptime 4294967295 (low 5 digits)");
    force dut.S_sec = 32'd123;        e_sec = "00123"; settle; check("uptime back to 123");

    // ---- 音频状态名（背景音乐和音效每次取不同的值）----
    aud_sd = 3'd0; aud_codec = 2'd0; bgm_state = 2'd0; sfx_state = 2'd1; settle; check("SD INIT, codec INIT, BGM IDLE, SFX OPEN");
    aud_sd = 3'd2; aud_codec = 2'd2; bgm_state = 2'd1; sfx_state = 2'd2; settle; check("NO SD, codec ERR, BGM OPEN, SFX PLAY");
    aud_sd = 3'd3; aud_codec = 2'd3; bgm_state = 2'd3; sfx_state = 2'd0; settle; check("NO FAT, codec ????, BGM ERR, SFX IDLE");
    aud_sd = 3'd4; bgm_state = 2'd2; sfx_state = 2'd3;                   settle; check("SD BADFAT, BGM PLAY, SFX ERR");
    aud_sd = 3'd7;                                                       settle; check("SD state 7 -> ??????");
    aud_sd = 3'd6;                                                       settle; check("SD state 6 -> ??????");
    aud_sd = 3'd5;                                                       settle; check("SD RD ERR");
    aud_sd = 3'd1; aud_codec = 2'd1; bgm_state = 2'd2; sfx_state = 2'd0; settle; check("READY / OK / PLAY / IDLE");

    release dut.S_sec;
    if (errors == 0) $display("PASS  tb_dash");
    else             $display("FAIL  tb_dash: %0d errors", errors);
    $finish;
end

initial begin #100_000_000; $display("FAIL  tb_dash: timeout"); $finish; end

endmodule
