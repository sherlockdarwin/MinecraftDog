`timescale 1ns / 1ps
// 测试 mc_imu_jy61p（维特 JY61P 陀螺仪，UART）。
//   测试台里有一个按官网协议写的 JY61P 模型：真实的 9600 / 115200 波形；收 FF AA 地址 数据低 数据高 写寄存器（没解锁不理，
//   解锁后不到 150 ms 就来下一条算错；改波特率马上生效、要重新解锁）；保存后"断电重启"恢复保存的设置；
//   按 RSW / RRATE 发 50~54 帧（校验 = 前 10 字节和的低 8 位），数据里故意带 0x55；可以插坏帧 / 诱饵帧 / 乱码 / 半帧。
//   两个被测实例：A（默认方向 CCW_POS = 1）接模型的收发；B（CCW_POS = 0、200 Hz、静止门限 100）只听模型，发的命令另外解出来核对。
//   场景：出厂设置（9600）→ A 自动改成 115200 并配置；探测 / 命令间隔的毫秒数精确核对；归零前车在动（门限正好 49 算静止、50 不算）；
//         静止够 STILL_MS 才归零（精确到节拍）；航向角 / 角速度的方向、零点、回绕、屏幕度数四舍五入（±0.5° 边界）；
//         坏校验 / 加速度帧 / 磁场帧 / 类型错 / 半帧 / 乱码都不影响数据；只缺角速度帧或只缺角度帧都算掉线；
//         短暂掉线（< LOST_MS）恢复后不重新配置、不重新归零；长时间掉线重新探测（模块已是 115200：只发 4 条）、重新归零；
//         模块在 115200 但什么都不输出（RSW = 0）→ 也要配好；断电重启后直接 115200；一直不静止 → ZERO_MAX_MS 后归零。
//         屏幕状态：线上有数据但没有有效帧 = LOST、IDLE_MS 没有下降沿 = NOLK（精确到节拍）；FPGA → 模块那根线断了（模块出厂 9600、听不见命令）
//         → 只在 CFG 和 LOST 之间来回、不重新归零；模块不说话 → 只在 CFG 和 NOLK 之间来回。
// 为了仿真快：时钟 10 MHz（CLK_HZ 也给 10 MHz），1 ms 节拍 = 2000 个时钟（0.2 ms），模型 100 Hz 时 12 个节拍发一组。
module tb_imu;

reg clk = 0;
always #50 clk = ~clk;                              // 10 MHz
reg rst_a = 0, rst_b = 0;
reg tick = 0;
integer ntick = 0;
integer cc = 0;
always @(posedge clk) begin
    cc <= (cc == 1999) ? 0 : cc + 1;
    tick <= (cc == 1999);
    if (cc == 1999) ntick <= ntick + 1;
end

localparam A_BOOT = 30, A_PROBE = 40, A_TO = 60, A_LOST = 150, A_STILL = 50, A_ZMAX = 400, A_IDLE = 90;
localparam B_BOOT = 20, B_PROBE = 25, B_TO = 70, B_LOST = 200, B_STILL = 30, B_ZMAX = 300;

reg  mline = 1'b1;                                  // 模型 TX → 两个实例的 RX
wire txa, txb;
wire oka, okb;
wire [2:0] sta, stb;
wire signed [15:0] yawa, gza, yawb, gzb;
wire signed [8:0]  yda, ydb;
wire signed [11:0] gda, gdb;

mc_imu_jy61p #(.CLK_HZ(10_000_000), .BOOT_MS(A_BOOT), .PROBE_MS(A_PROBE), .TIMEOUT_MS(A_TO), .LOST_MS(A_LOST), .IDLE_MS(A_IDLE),
               .STILL_RAW(49), .STILL_MS(A_STILL), .ZERO_MAX_MS(A_ZMAX)) da (
    .I_clk(clk), .I_rst_n(rst_a), .I_tick_1ms(tick), .I_rx(mline), .O_tx(txa),
    .O_ok(oka), .O_state(sta), .O_yaw(yawa), .O_gz(gza), .O_yaw_deg(yda), .O_gz_dps(gda));
mc_imu_jy61p #(.CLK_HZ(10_000_000), .RATE_CODE(4'hB), .BOOT_MS(B_BOOT), .PROBE_MS(B_PROBE), .TIMEOUT_MS(B_TO), .LOST_MS(B_LOST),
               .STILL_RAW(100), .STILL_MS(B_STILL), .ZERO_MAX_MS(B_ZMAX), .CCW_POS(0)) db (
    .I_clk(clk), .I_rst_n(rst_b), .I_tick_1ms(tick), .I_rx(mline), .O_tx(txb),
    .O_ok(okb), .O_state(stb), .O_yaw(yawb), .O_gz(gzb), .O_yaw_deg(ydb), .O_gz_dps(gdb));

integer errors = 0;
always @(errors) if (errors > 15) begin #1; $display("FAIL  tb_imu: too many errors"); $finish; end
task fail; input [8*80-1:0] msg; begin $display("FAIL t=%0d tick %0d: %0s", $time, ntick, msg); errors = errors + 1; end endtask

// =============================================================================
// JY61P 模型
// =============================================================================
integer m_baud = 9600;
reg [15:0] m_rsw = 16'h001E;
reg [3:0]  m_rate = 4'h6;
reg        m_unlk = 0;
integer    m_unlk_t = -1000;
integer    s_baud = 9600; reg [15:0] s_rsw = 16'h001E; reg [3:0] s_rate = 4'h6;   // 保存的设置
reg        m_on = 1;                                // 在发数据
reg        m_deaf = 0;                              // 听不见（FPGA → 模块 RX 那根线断了）
reg        skip_g = 0, skip_a = 0;                  // 不发角速度帧 / 角度帧
reg signed [15:0] m_yaw = 16'sd6000, m_gz = 16'sd300;
integer    n_frames = 0;
integer    early_cmd = 0;
integer    m_ferr = 0;                              // 模型收到的帧错误（波特率不对的字节）
integer    t_ferr = -100000;                        // 打开记录以后第一个帧错误字节开始的节拍
reg        ferr_arm = 0;
integer    m_last_end = -100000;                    // 模型最后一个角度帧发完的节拍

// 收到的命令记录
integer    nc = 0;
reg [7:0]  c_addr [0:63];
reg [15:0] c_data [0:63];
integer    c_baud [0:63];
reg        c_ok   [0:63];
integer    c_t0   [0:63], c_t1 [0:63];             // 第一个字节开始 / 最后一个字节开始的节拍数

real bitns;
reg [7:0] rb;
integer   rb_t;                                     // 这个字节开始的节拍数
integer   pidx = 0;
reg [7:0] pbuf [0:4];
integer   p_t0 = 0;
integer   i;

always begin : model_rx
    @(negedge txa);
    rb_t = ntick;
    bitns = 1.0e9 / m_baud;
    #(bitns / 2.0);
    if (txa == 1'b0) begin
        for (i = 0; i < 8; i = i + 1) begin #(bitns); rb[i] = txa; end
        #(bitns);
        if (txa == 1'b1) begin if (!m_deaf) model_byte(rb, rb_t); end
        else begin m_ferr = m_ferr + 1; if (ferr_arm) begin t_ferr = rb_t; ferr_arm = 0; end wait (txa == 1'b1); end   // 帧错误（波特率不对）：丢掉，等线回到空闲
    end
end

task model_byte;
    input [7:0] b;
    input integer t;
    reg [15:0] d;
    begin
        if (pidx == 0) begin if (b == 8'hFF) begin pidx = 1; p_t0 = t; end end
        else if (pidx == 1) begin pidx = (b == 8'hAA) ? 2 : (b == 8'hFF) ? 1 : 0; if (b == 8'hFF) p_t0 = t; end
        else begin
            pbuf[pidx] = b; pidx = pidx + 1;
            if (pidx == 5) begin
                pidx = 0; d = {pbuf[4], pbuf[3]};
                c_addr[nc] = pbuf[2]; c_data[nc] = d; c_baud[nc] = m_baud; c_t0[nc] = p_t0; c_t1[nc] = t; c_ok[nc] = 0;
                if (pbuf[2] == 8'h69) begin
                    if (d == 16'hB588) begin m_unlk = 1; m_unlk_t = t; c_ok[nc] = 1; end
                end else if (m_unlk) begin
                    if (p_t0 - m_unlk_t < 150) early_cmd = early_cmd + 1;
                    c_ok[nc] = 1;
                    case (pbuf[2])
                        8'h00: if (d == 16'h0000) begin s_baud = m_baud; s_rsw = m_rsw; s_rate = m_rate; end
                        8'h02: m_rsw = d;
                        8'h03: m_rate = d[3:0];
                        8'h04: begin m_baud = (d == 16'h0006) ? 115200 : (d == 16'h0002) ? 9600 : 1; m_unlk = 0; end
                        default: ;
                    endcase
                end
                nc = nc + 1;
            end
        end
    end
endtask

task power_cycle; begin m_baud = s_baud; m_rsw = s_rsw; m_rate = s_rate; m_unlk = 0; pidx = 0; end endtask

// 发
task m_send;
    input [7:0] b;
    real bt;
    integer k;
    begin
        bt = 1.0e9 / m_baud;
        mline = 1'b0; #(bt);
        for (k = 0; k < 8; k = k + 1) begin mline = b[k]; #(bt); end
        mline = 1'b1; #(bt);
    end
endtask
task m_frame;                                       // 一帧：55 TYPE D1 D2 D3 D4 SUM（corrupt = 1：校验加 1）
    input [7:0] typ;
    input [15:0] d1, d2, d3, d4;
    input corrupt;
    reg [7:0] s;
    begin
        s = 8'h55 + typ + d1[7:0] + d1[15:8] + d2[7:0] + d2[15:8] + d3[7:0] + d3[15:8] + d4[7:0] + d4[15:8] + (corrupt ? 8'd1 : 8'd0);
        m_send(8'h55); m_send(typ);
        m_send(d1[7:0]); m_send(d1[15:8]); m_send(d2[7:0]); m_send(d2[15:8]);
        m_send(d3[7:0]); m_send(d3[15:8]); m_send(d4[7:0]); m_send(d4[15:8]); m_send(s);
    end
endtask

reg        inj = 0;                                 // 测试台要插东西：模型这一组先不发，插完再发
reg        m_busy = 0;
integer    tstart;
always begin : model_tx
    wait (m_on && !inj);
    m_busy = 1;
    tstart = ntick;
    if (m_rsw[0]) m_frame(8'h50, 16'h0A1A, 16'h0C0B, 16'h3A10, 16'h0155, 0);
    if (m_rsw[1]) m_frame(8'h51, 16'h0055, 16'h5553, 16'h07D0, 16'h0BB8, 0);            // 加速度：数据里带 55 53
    if (m_rsw[2] && !skip_g) m_frame(8'h52, 16'h5552, 16'h0055, m_gz, 16'h0000, 0);     // 角速度：Z 在 D3
    if (m_rsw[3] && !skip_a) begin m_frame(8'h53, 16'h5355, 16'h0100, m_yaw, 16'h5A55, 0); m_last_end = ntick; end   // 角度：Yaw 在 D3
    if (m_rsw[4]) m_frame(8'h54, 16'h1234, 16'h5555, 16'h4321, 16'h0000, 0);
    n_frames = n_frames + 1;
    m_busy = 0;
    if (m_rsw[4:0] == 5'd0) wait (m_rsw[4:0] != 5'd0 || !m_on);
    while (ntick < tstart + ((m_rate == 4'h9 || m_rate == 4'hB) ? 12 : 100) && m_on && !inj) @(posedge tick);
end

// B 发的命令（只用 115200 解，9600 的字节解出来是乱的）
integer nb = 0, nb_bad = 0;
reg [7:0] b_log [0:63];
reg [7:0] sb;
integer j;
always begin : sniff_b
    @(negedge txb);
    #(1.0e9 / 115200 / 2.0);
    if (txb == 1'b0) begin
        for (j = 0; j < 8; j = j + 1) begin #(1.0e9 / 115200); sb[j] = txb; end
        #(1.0e9 / 115200);
        if (txb == 1'b1) begin b_log[nb] = sb; nb = nb + 1; end
        else begin nb_bad = nb_bad + 1; wait (txb == 1'b1); end
    end
end

// =============================================================================
// 期望值（测试台自己算）
// =============================================================================
function integer rdeg;                              // 航向角 → 度，四舍五入（x.5 往上）
    input integer y;
    real r;
    begin r = y * 360.0 / 65536.0 + 0.5; rdeg = $rtoi(r); if (r < 0.0 && $itor(rdeg) != r) rdeg = rdeg - 1; end
endfunction
function integer rdps;                              // 角速度原始值 → 度/秒，四舍五入
    input integer g;
    real r;
    begin r = g * 2000.0 / 32768.0 + 0.5; rdps = $rtoi(r); if (r < 0.0 && $itor(rdps) != r) rdps = rdps - 1; end
endfunction
function signed [15:0] w16; input integer v; w16 = v; endfunction

// 输出核对：A 取反（逆时针为正 → 右转为正）、B 不取反；减零点；16 位回绕
integer za, zb;                                     // 零点（模型的原始航向角）
reg     chk_a = 0, chk_b = 0;
task check_out;
    begin
        if (chk_a) begin
            if (yawa !== w16(-(m_yaw - za))) fail("A yaw");
            if (gza !== w16(-m_gz))          fail("A gz");
            if (yda !== rdeg(w16(-(m_yaw - za)))) begin $display("   A deg %0d expected %0d (yaw %0d)", yda, rdeg(w16(-(m_yaw - za))), yawa); fail("A yaw degrees"); end
            if (gda !== rdps(w16(-m_gz)))    begin $display("   A dps %0d expected %0d", gda, rdps(w16(-m_gz))); fail("A gz deg/s"); end
        end
        if (chk_b) begin
            if (yawb !== w16(m_yaw - zb))    fail("B yaw");
            if (gzb !== m_gz)                fail("B gz");
            if (ydb !== rdeg(w16(m_yaw - zb))) fail("B yaw degrees");
            if (gdb !== rdps(m_gz))          fail("B gz deg/s");
        end
    end
endtask

task ticks; input integer n; integer t; begin t = ntick + n; while (ntick < t) @(posedge clk); end endtask
task settle; begin ticks(30); check_out; end endtask   // 新值至少过一组帧再核对
task set_yaw_gz; input integer y, g; begin m_yaw = y; m_gz = g; settle; end endtask

// 诱饵：这些值绝不能出现在输出上
reg decoy_on = 0;
always @(posedge clk) if (decoy_on && chk_a) begin
    if (gza === w16(-16'sd12345) || yawa === w16(-(16'sd4321 - za)) || yawa === w16(-(16'sd7777 - za)) || gza === w16(-16'sd2222))
        fail("decoy value reached the output");
end

// 一条命令期望：地址、数据、波特率
task exp_cmd;
    input integer k;
    input [7:0] a;
    input [15:0] d;
    input integer baud;
    begin
        if (k >= nc) begin $display("   command %0d missing", k); fail("command missing"); end
        else if (c_addr[k] !== a || c_data[k] !== d || c_baud[k] != baud || !c_ok[k]) begin
            $display("   command %0d: addr %h data %h baud %0d applied %b, expected %h %h %0d", k, c_addr[k], c_data[k], c_baud[k], c_ok[k], a, d, baud);
            fail("wrong command");
        end
    end
endtask
task exp_gap;                                       // 第 k 条命令最后一个字节开始 → 第 k+1 条第一个字节开始 = n 个节拍
    input integer k, n;
    begin
        if (c_t0[k+1] - c_t1[k] != n) begin $display("   gap after command %0d: %0d ticks, expected %0d", k, c_t0[k+1] - c_t1[k], n); fail("command spacing"); end
    end
endtask

// 事件时间
integer t_rel_a = -100000, t_tx1 = -100000, t_zero_a = -100000, t_small = -100000, t_wait_a = -100000, t_ok_drop = -100000, t_last_a = -100000, t_wait_b = -100000, t_zero_b = -100000;
reg [2:0] stb_d = 0;
reg oka_d = 0, okb_d = 0;
reg [2:0] sta_d = 0;
reg small_seen = 0;
reg first_tx = 0;
always @(posedge clk) begin
    oka_d <= oka; sta_d <= sta; okb_d <= okb;
    if (oka && !oka_d) t_zero_a = ntick;
    if (!oka && oka_d) t_ok_drop = ntick;
    if (sta == 3'd2 && sta_d == 3'd1) t_wait_a = ntick;
    stb_d <= stb;
    if (stb == 3'd2 && stb_d == 3'd1) t_wait_b = ntick;
    if (okb && !okb_d) t_zero_b = ntick;
end
always @(negedge txa) if (!first_tx) begin first_tx = 1; t_tx1 = ntick; end
integer t_fall = -100000;                          // 模型 TX 线上最后一个下降沿的节拍
always @(negedge mline) t_fall = ntick;
reg     rec = 0;                                   // 记下 A 显示过哪些状态
reg [7:0] seen = 0;
always @(posedge clk) if (rec) seen[sta] <= 1'b1;

// O_state / O_ok 的一致性：ok 一定是 OK 状态；OK 状态一定 ok（同一拍算出来的）
always @(posedge clk) if (rst_a) begin
    if (oka && sta != 3'd3) fail("O_ok without state OK");
    if (sta == 3'd3 && !oka) fail("state OK without O_ok");
    if (sta > 3'd4) fail("state out of range");
end

integer n0, k, zprev, tz;
initial begin
    // ---------------- 1. 出厂设置：9600、10 Hz、输出 51~54 ----------------
    repeat (3) @(posedge clk); rst_a = 1; t_rel_a = ntick;
    ticks(5);
    if (sta !== 3'd4 || oka) fail("not LOST while booting (module talking at 9600)");
    wait (nc >= 2); @(posedge clk);
    if (t_tx1 - t_rel_a != A_BOOT + A_PROBE) begin $display("   first byte after %0d ticks", t_tx1 - t_rel_a); fail("boot + probe time"); end
    if (sta !== 3'd1) fail("state not CFG while configuring");
    wait (nc >= 6); ticks(5);
    exp_cmd(0, 8'h69, 16'hB588, 9600);
    exp_cmd(1, 8'h04, 16'h0006, 9600);
    exp_cmd(2, 8'h69, 16'hB588, 115200);
    exp_cmd(3, 8'h02, 16'h000C, 115200);
    exp_cmd(4, 8'h03, 16'h0009, 115200);
    exp_cmd(5, 8'h00, 16'h0000, 115200);
    exp_gap(0, 200); exp_gap(1, 100); exp_gap(2, 200); exp_gap(3, 50); exp_gap(4, 50);
    if (s_baud != 115200 || s_rsw != 16'h000C || s_rate != 4'h9) fail("module settings not saved");
    if (early_cmd != 0) fail("command sent less than 150 ms after unlock");
    // 车在动（gz 300 > 49）：不归零
    ticks(220);
    if (sta !== 3'd2 || oka) fail("should be waiting for still (WAIT)");
    if (t_wait_a - c_t1[5] != 200) begin $display("   WAIT after %0d ticks", t_wait_a - c_t1[5]); fail("wait after save"); end
    // 49 / −49 正好算静止，中间来一下 50 → 重新计时
    m_gz = 16'sd49; ticks(15); m_gz = -16'sd49; ticks(15); m_gz = 16'sd50; ticks(15);
    if (oka) fail("zeroed although a 50 came in");
    m_gz = -16'sd49; t_small = -1;                  // 正好 49：算静止
    wait (gza == 16'sd49); t_small = ntick;
    wait (oka); repeat (2) @(posedge clk); za = 6000; chk_a = 1;
    if (t_zero_a - t_small != A_STILL) begin $display("   zero %0d ticks after still", t_zero_a - t_small); fail("STILL_MS"); end
    if (yawa !== 16'sd0) fail("yaw not zero right after zeroing");
    settle;
    // ---------------- 2. 方向、回绕、度数 ----------------
    set_yaw_gz(6000 - 1820, 300);                   // 逆时针减小 = 右转 10°
    if (yda !== 9'sd10) fail("10 degrees right");
    set_yaw_gz(6000 + 91, -300);  set_yaw_gz(6000 + 92, 8);  set_yaw_gz(6000 - 91, -8); set_yaw_gz(6000 - 92, 16'sd32767);
    set_yaw_gz(6000 - 32768, -16'sd32768);          // 正好 180°
    set_yaw_gz(6000 - 32767, 17); set_yaw_gz(6000 + 32767 - 65536 + 65536, -17);
    set_yaw_gz(-32000, 33); set_yaw_gz(32000, -33); // 原始值跨过 ±180°
    set_yaw_gz(6000 - 2, 16); set_yaw_gz(6000 + 2, -16);
    set_yaw_gz(6000 - 4096, -1024); set_yaw_gz(6000 + 4096, 1024);   // 正好 22.5° / 62.5°/s：.5 往上（+23 / −22、+63 / −62）
    // ---------------- 3. 坏帧 / 诱饵 ----------------
    decoy_on = 1; n0 = nc;
    m_yaw = 1000; m_gz = 100; settle;
    inj = 1; wait (!m_busy);
    m_frame(8'h53, 16'h0000, 16'h0000, 16'd4321, 16'h0000, 1);   // 校验错
    m_frame(8'h52, 16'h0000, 16'h0000, 16'd12345, 16'h0000, 1);
    m_frame(8'h51, 16'h0000, 16'h0000, 16'd12345, 16'h0000, 0);  // 加速度帧 D3 = 诱饵
    m_frame(8'h54, 16'h0000, 16'h0000, 16'd7777, 16'h0000, 0);   // 磁场帧
    m_frame(8'h43, 16'h0000, 16'h0000, 16'd7777, 16'h0000, 0);   // 类型错（不是 5x）
    m_send(8'h55); m_send(8'h53); m_send(8'h10); m_send(8'h00);  // 半帧，后面紧接着一个好帧
    m_frame(8'h53, 16'h0000, 16'h0000, 16'd31000, 16'h0000, 0);  // 开头被半帧吃掉（收不收都行，后面的好帧会改回来）
    m_send(8'h00); m_send(8'h55); m_send(8'h55); m_send(8'h52); m_send(8'hAE);
    m_frame(8'h52, 16'h0000, 16'h0000, 16'd2222, 16'h0000, 1);
    m_frame(8'h53, 16'h0000, 16'h0000, 16'd1000, 16'h0000, 0); m_frame(8'h53, 16'h0000, 16'h0000, 16'd1000, 16'h0000, 0);   // 两个好帧：解析器先对齐
    m_send(8'h55); m_send(8'h51); m_send(8'h00); m_send(8'h00); m_send(8'h00); m_send(8'h00); m_send(8'h00); m_send(8'h00); m_send(8'h00); m_send(8'h00);   // 10 个字节的半帧
    m_frame(8'h53, 16'h0000, 16'h0000, 16'd2500, 16'h0000, 0);  // 好帧的 55 落在半帧的校验位上：校验不对，但要从这个 55 重新开始
    ticks(3);
    if (yawa !== w16(-(2500 - za))) fail("frame whose header was the failed checksum byte was lost (no resync)");
    ticks(2); inj = 0;
    settle; settle;
    if (yawa !== w16(-(1000 - za)) || gza !== w16(-100)) fail("data changed by bad frames");
    if (nc != n0) fail("transmitted while running");
    decoy_on = 0;
    // ---------------- 4. 掉线 ----------------
    skip_g = 1; ticks(A_TO + 30);
    if (oka || sta !== 3'd4) fail("no gyro frames: should be LOST (line busy)");
    skip_g = 0; settle;
    if (!oka) fail("gyro frames back: should be OK");
    skip_a = 1; ticks(A_TO + 30);
    if (oka || sta !== 3'd4) fail("no angle frames: should be LOST (line busy)");
    skip_a = 0; settle;
    m_on = 0; wait (!m_busy); t_last_a = ntick; t_ok_drop = -100000; ticks(A_TO + 20);
    if (oka) fail("module silent: should drop");
    if (t_ok_drop - t_last_a < A_TO - 13 || t_ok_drop - t_last_a > A_TO + 1) begin $display("   dropped %0d ticks after last group", t_ok_drop - t_last_a); fail("TIMEOUT_MS"); end
    if (sta !== 3'd4) fail("silent < IDLE_MS: should still be LOST");
    wait (sta == 3'd0);
    $display("NOLK %0d ticks after the last falling edge (IDLE_MS %0d)", ntick - t_fall, A_IDLE);
    if (ntick - t_fall != A_IDLE) fail("IDLE_MS");
    m_yaw = 1500; m_on = 1; settle;                 // 没超过 LOST_MS：不重新配置、不重新归零
    if (!oka || nc != n0) fail("short dropout: should recover without reconfiguring");
    // 长时间掉线：重新探测（模块已经是 115200，只发后 4 条）、重新归零
    m_on = 0; wait (!m_busy); k = m_ferr; ferr_arm = 1; ticks(A_LOST + A_PROBE + 20);
    if (nc != n0) fail("module decoded a command while it was at 115200 and silent");
    if (m_ferr == k) fail("no re-probe after LOST_MS");
    else if (t_ferr - m_last_end < A_LOST + A_PROBE - 1 || t_ferr - m_last_end > A_LOST + A_PROBE + 1) begin
        $display("   9600 bytes started %0d ticks after the last angle frame", t_ferr - m_last_end); fail("LOST_MS + PROBE_MS");
    end
    m_yaw = -20000; m_gz = 5; m_on = 1;
    wait (nc >= n0 + 4); ticks(3);
    exp_cmd(n0, 8'h69, 16'hB588, 115200); exp_cmd(n0 + 1, 8'h02, 16'h000C, 115200); exp_cmd(n0 + 2, 8'h03, 16'h0009, 115200); exp_cmd(n0 + 3, 8'h00, 16'h0000, 115200);
    ticks(5);
    if (nc != n0 + 4) fail("re-probe sent more than 4 commands");
    chk_a = 0; wait (oka); za = -20000; chk_a = 1; settle;
    // ---------------- 5. B：只听、200 Hz、不取反、静止门限 100 ----------------
    rst_b = 1;
    m_gz = 80; m_yaw = 12000; ticks(B_BOOT + B_PROBE + 200 + 50 + 50 + 200 + 20);
    if (nb != 20 || nb_bad != 0) begin $display("   B sent %0d bytes (%0d bad)", nb, nb_bad); fail("B command count"); end
    for (k = 0; k < 20; k = k + 1) begin
        case (k % 5) 0: if (b_log[k] !== 8'hFF) fail("B byte"); 1: if (b_log[k] !== 8'hAA) fail("B byte"); default: ; endcase
    end
    if (b_log[2] !== 8'h69 || b_log[3] !== 8'h88 || b_log[4] !== 8'hB5 || b_log[7] !== 8'h02 || b_log[8] !== 8'h0C || b_log[9] !== 8'h00 ||
        b_log[12] !== 8'h03 || b_log[13] !== 8'h0B || b_log[14] !== 8'h00 || b_log[17] !== 8'h00 || b_log[18] !== 8'h00 || b_log[19] !== 8'h00) fail("B commands (rate 0x0B)");
    wait (okb); repeat (2) @(posedge clk); zb = 12000; chk_b = 1;   // 80 < 100：B 停稳了（A 的门限 49 就不算）
    if (t_zero_b - t_wait_b != B_STILL) begin $display("   B zeroed %0d ticks after WAIT", t_zero_b - t_wait_b); fail("B STILL_RAW / STILL_MS"); end
    if (!oka) fail("A lost");
    settle;
    set_yaw_gz(12000 + 3000, -1200); set_yaw_gz(12000 - 7000, 2047);
    // ---------------- 6. 模块在 115200 但不输出（RSW = 0）→ A 当成出厂，9600 的命令模块收不到，115200 的配置把它救回来 ----------------
    chk_a = 0; chk_b = 0;
    m_rsw = 16'h0000; s_rsw = 16'h0000; n0 = nc;
    rst_a = 0; repeat (3) @(posedge clk); rst_a = 1;
    wait (nc >= n0 + 4); ticks(3);
    exp_cmd(n0, 8'h69, 16'hB588, 115200); exp_cmd(n0 + 1, 8'h02, 16'h000C, 115200); exp_cmd(n0 + 2, 8'h03, 16'h0009, 115200); exp_cmd(n0 + 3, 8'h00, 16'h0000, 115200);
    if (m_rsw !== 16'h000C) fail("RSW not restored");
    // 一直在动 → ZERO_MAX_MS 后也归零
    m_gz = 400; m_yaw = 777;
    wait (sta == 3'd2); repeat (2) @(posedge clk);
    tz = t_wait_a;
    wait (oka); repeat (2) @(posedge clk); za = 777; chk_a = 1;
    if (t_zero_a - tz != A_ZMAX) begin $display("   zeroed %0d ticks after WAIT", t_zero_a - tz); fail("ZERO_MAX_MS"); end
    settle;
    // ---------------- 7. 断电重启（存的是 115200）+ 复位 → 直接 115200，只发 4 条 ----------------
    chk_a = 0; m_on = 0; wait (!m_busy); power_cycle; n0 = nc; k = m_ferr;
    rst_a = 0; repeat (3) @(posedge clk); rst_a = 1; m_on = 1; m_gz = 400; m_yaw = -5;
    ticks(20);
    if (sta !== 3'd2) fail("frames already valid while booting: should show WAIT (not NOLK)");
    wait (nc >= n0 + 4); ticks(3);
    exp_cmd(n0, 8'h69, 16'hB588, 115200); exp_cmd(n0 + 3, 8'h00, 16'h0000, 115200);
    if (m_ferr != k) fail("sent 9600 bytes although the module answered at 115200");
    // 等归零时（车在动）模块停了，超过 LOST_MS：要重新探测、配置
    wait (sta == 3'd2); m_on = 0; wait (!m_busy); n0 = nc;
    tz = ntick; while (nc < n0 + 4 && ntick < tz + 2500) @(posedge clk);
    if (nc < n0 + 4) fail("silent while waiting to zero: no re-probe");
    // 等归零时只有角度帧（角速度帧断了）：过了 ZERO_MAX_MS 也不能归零；角速度帧回来 → 马上用那时的航向归零
    skip_g = 1; m_on = 1;
    ticks(200 + A_ZMAX + 60);
    if (oka || sta == 3'd3) fail("zeroed / OK without gyro frames");
    m_yaw = 1234; ticks(30); skip_g = 0;
    wait (oka); repeat (2) @(posedge clk); za = 1234; chk_a = 1; settle;
    set_yaw_gz(1234 - 16384, 0);                     // 右转 90°
    if (yda !== 9'sd90) fail("90 degrees");
    // ---------------- 8. 接线断了：屏幕要分得出是哪根 ----------------
    // FPGA → 模块 RX 断了（模块出厂 9600、听不见命令）：线上一直有 9600 的数据 → 只在 LOST 和 CFG 之间来回
    chk_a = 0; m_on = 0; wait (!m_busy); s_baud = 9600; s_rsw = 16'h001E; s_rate = 4'h6; power_cycle; m_deaf = 1; n0 = nc;
    rst_a = 0; repeat (3) @(posedge clk); rst_a = 1; m_on = 1;
    ticks(5); seen = 0; rec = 1; ticks(2000); rec = 0;
    if (seen != 8'b0001_0010) begin $display("   states seen %b", seen); fail("FPGA TX wire broken: should cycle CFG / LOST only"); end
    if (nc != n0 || m_baud != 9600) fail("deaf module changed");
    // 模块不说话（模块 TX → FPGA 断了 / 没电）：只在 NOLK 和 CFG 之间来回
    m_on = 0; wait (!m_busy); ticks(A_IDLE + 5);
    rst_a = 0; repeat (3) @(posedge clk); rst_a = 1;   // 复位后"多久没下降沿"从最大值开始：要停在最大值，不能绕回 0 变成 LOST
    seen = 0; rec = 1; ticks(2000); rec = 0;
    if (seen != 8'b0000_0011) begin $display("   states seen %b", seen); fail("module silent: should cycle NOLK / CFG only"); end

    $display("frames %0d, commands %0d", n_frames, nc);
    if (errors == 0) $display("PASS  tb_imu");
    else             $display("FAIL  tb_imu: %0d error(s)", errors);
    $finish;
end

initial begin #(4.0e9); $display("FAIL  tb_imu: timeout"); $finish; end

endmodule
