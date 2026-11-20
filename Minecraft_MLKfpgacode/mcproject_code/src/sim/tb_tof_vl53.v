`timescale 1ns / 1ps
// =============================================================================
// tb_tof_vl53.v  测 mc_tof_vl53（VL53-200 激光测距：串口收距离）
//
//   激励：真的 115200 8N1 波形（100 MHz 时钟，mc_uart_rx 每位 868 拍），按说明书 5.3 的格式发：
//         "State;0 , Range Valid" CR LF + "d:   73 mm" CR LF（距离右对齐 5 格，和上位机截图一样）。
//   期望（测试台自己按规格算，不看 RTL 怎么写）：
//         每一组：O_st = 状态号（超过 255 记 255）、O_mm = 毫米（超过 9999 记 9999）。
//         状态 0 / 2 / 4 = 一次测量：r = (状态 0 且 MIN_MM ≤ 毫米 ≤ 9999 且 毫米 / 10 ≤ MAX_CM) ? 毫米 / 10 − OFF_CM : 255；
//           O_cm = max(r, 上一次 r)；O_near = r ≤ NEAR_CM 或 上一次 r ≤ NEAR_CM；掉线以后"上一次"从 255 重来。
//         其余状态号（255 没有新数据、1 / 3 / 5、说明书里没有的）跳过：O_upd 不打、O_cm / O_near 不变、不算活着。
//         11-17 上车的情况（量到了和 255 一组隔一组）专门造：距离必须出来。
//         11-18 上车的情况（两次测量隔得比 LINK_MS 还久，中间线上安静 → NOLK，但没到 ALIVE_MS）专门造：距离必须出来。
//   逐拍核对：O_alive = 最近一次测量以后模块数到的 1 ms 节拍 < ALV_MS；O_link = 最近一个字节以后数到的节拍 < LNK_MS。
//             O_cm / O_near / O_dt 只能在 O_upd 那一拍（或者掉线那一拍：只有 O_cm / O_near）变；O_upd 的次数 = 测量的组数（跳过的组、半组、乱码不算）。
//             每次 O_upd：O_dt = 和上一次测量隔了几个节拍（到 ALV_MS 不再加；复位以后第一次 = ALV_MS）。
//   专门造的边界：字节正好在"该掉线"的那个沿收到（以收到为准，不掉）；波特率偏 ±2%。
//   超时用 ALV_MS = 30、LNK_MS = 12（模块里是参数，车上 900 / 300；测短一点仿真快；测试台连着发，一组约 3 ms，不会无意中掉线）。
// =============================================================================
module tb_tof_vl53;

localparam MIN_MM  = 100;               // 模块在车头最前面后面 10 cm（读数比这近的不算）
localparam OFF_CM  = 5;                 // 模块比镜头靠后 5 cm：读数 − 5 cm = 离镜头（下面注释里的 cm 数是没减它的毫米 / 10，模型和检查已按减了的算）
localparam MAX_CM  = 120;
localparam NEAR_CM = 75;                // 车上 80；这里取 75，让下面 810 / 809 毫米（离镜头 76 / 75）的边界测试照样正好落在门限上
localparam ALV_MS  = 30;                // 这么久没有一次测量 = 掉线（车上 900）
localparam LNK_MS  = 12;                // 这么久没有字节 = 线上没动静（车上 300）
localparam BIT_NS  = 8680;              // 100 MHz / 115200 = 868 拍 × 10 ns
localparam MS_CLKS = 100_000;
localparam RX_LAT  = 8248;              // 起始位下降沿后第一个时钟沿 → mc_uart_rx 的 O_valid 置 1 的沿（2 拍同步 + 434 + 9 × 868 − 2）

reg clk = 1'b0;
always #5 clk = ~clk;

reg rst_n = 1'b0;
reg tick  = 1'b0;
reg rx    = 1'b1;

wire [7:0] o_cm;
wire       o_upd, o_near, o_alive, o_link;
wire [7:0] o_st;
wire [13:0] o_mm;
wire [9:0] o_dt;

mc_tof_vl53 #(.CLK_HZ (100_000_000), .BAUD (115200), .MIN_MM (MIN_MM), .OFFSET_CM (OFF_CM), .MAX_CM (MAX_CM), .NEAR_CM (NEAR_CM), .ALIVE_MS (ALV_MS), .LINK_MS (LNK_MS)) dut (
    .I_clk (clk), .I_rst_n (rst_n), .I_tick_1ms (tick), .I_rx (rx),
    .O_cm (o_cm), .O_upd (o_upd), .O_near (o_near), .O_alive (o_alive), .O_link (o_link), .O_st (o_st), .O_mm (o_mm), .O_dt (o_dt)
);

integer errors = 0;
integer nms    = 0;                     // 1 ms 节拍数
integer nupd   = 0;                     // O_upd 次数
integer r1     = 255;                   // 模型：上一组的 r
integer nskip  = 0;                     // 跳过的组数（场景真的发了）
integer ndtmid = 0;                     // O_dt 在 LNK_MS ~ ALV_MS 之间的测量次数（11-18 的情况真的造出来了）
integer edt;
integer bit_ns = BIT_NS;                // 发送用的位宽（测波特率偏差时改）

task fail;
    input [8*80-1:0] msg;
    begin
        $display("FAIL %0s (t = %0t, cm %0d near %0d alive %0d link %0d)", msg, $time, o_cm, o_near, o_alive, o_link);
        errors = errors + 1;
        if (errors > 20) begin $display("FAIL too many errors"); $finish; end
    end
endtask

// ---- 1 ms 节拍（tick 高一拍；模块在下一个沿数它）----
integer div = 0;
always @(posedge clk) begin
    if (div == MS_CLKS - 1) begin div <= 0; tick <= 1'b1; nms <= nms + 1; end
    else begin div <= div + 1; tick <= 1'b0; end
end

// ---- 监视 + 逐拍核对（下降沿取样）----
//   "模块数到的节拍" = 时钟沿上 tick 是 1 的次数。事件（一组结束 / 收到字节）记成 nms − tick：
//   tick 这时还是 1 说明这个节拍模块下一个沿才数，算在事件之后。tick 是 1 的那半拍 nms 已经加了、模块还没数，不比。
reg [7:0] l_cm = 8'd255;
reg [9:0] l_dt = 10'd0;
reg       l_near = 1'b0, l_alive = 1'b0, l_sv = 1'b0, e_alive = 1'b0, pe_alive = 1'b0, e_link = 1'b0;
integer   t_upd = -100000, t_byte = -100000;
integer   ncoin = 0;                    // 收到字节和数节拍在同一个沿的次数（专门造的场景要真的碰上）
always @(posedge clk) if (rst_n && dut.S_v && tick) ncoin = ncoin + 1;
always @(negedge clk) begin
    if (rst_n) begin
        if (o_upd) begin
            edt = (nms - tick) - t_upd; if (edt > ALV_MS) edt = ALV_MS;
            if (o_dt !== edt) begin $display("  O_dt %0d, expected %0d", o_dt, edt); fail("O_dt"); end
            if (edt > LNK_MS && edt < ALV_MS) ndtmid = ndtmid + 1;
            nupd = nupd + 1; t_upd = nms - tick;
        end
        if (o_dt !== l_dt && !o_upd) fail("O_dt changed without O_upd");
        l_dt = o_dt;
        if (l_sv) t_byte = nms - tick;                      // 上一拍 O_valid = 1 → 模块在刚过去的沿收下这个字节
        l_sv = dut.S_v;
        if (!tick) begin
            e_alive = (nms - t_upd < ALV_MS);
            e_link  = (nms - t_byte < LNK_MS);
            if (o_alive !== e_alive) fail("O_alive timing");
            if (o_link !== e_link)   fail("O_link timing");
            if (pe_alive && !e_alive) r1 = 255;             // 规格：掉线以后上一组从 255 重来
            pe_alive = e_alive;
        end
        if ((o_cm !== l_cm || o_near !== l_near) && !o_upd && !(l_alive && !o_alive))
            fail("O_cm / O_near changed without O_upd or timeout");
        l_cm = o_cm; l_near = o_near; l_alive = o_alive;
    end
end

// ---- 串口发送（模块的 TXD）----
task tx;
    input [7:0] b;
    integer i;
    begin
        rx = 1'b0; #(bit_ns);
        for (i = 0; i < 8; i = i + 1) begin rx = b[i]; #(bit_ns); end
        rx = 1'b1; #(bit_ns);
    end
endtask
task tx_at;                             // 发一个字节，让模块收下它的那个沿正好是数第 n 个节拍的沿
    input [7:0]   b;
    input integer n;
    begin
        if (nms >= n - 1) fail("tb: tx_at called too late");
        wait (nms == n - 1);
        @(negedge clk);
        while (div != MS_CLKS - 1 - RX_LAT) @(negedge clk);
        tx(b);
    end
endtask
task txs;                               // 字符串（左边是第一个字符）
    input [8*24-1:0] s;
    input integer    n;
    integer i;
    begin
        for (i = 0; i < n; i = i + 1) tx(s[(n - 1 - i) * 8 +: 8]);
    end
endtask
task crlf; begin tx(8'h0D); tx(8'h0A); end endtask
function integer ndig;                  // 十进制位数
    input integer v;
    integer p;
    begin
        ndig = 1; p = 10;
        while (v >= p) begin ndig = ndig + 1; p = p * 10; end
    end
endfunction
task txdec;                             // 十进制，至少 nd 位（前面补 0）
    input integer v;
    input integer nd;
    integer d, k, p;
    begin
        d = ndig(v);
        for (k = d; k < nd; k = k + 1) tx(8'h30);
        p = 1; for (k = 1; k < d; k = k + 1) p = p * 10;
        while (p >= 1) begin tx(8'h30 + (v / p) % 10); p = p / 10; end
    end
endtask
task st_line;                           // "State;N , xxx" CR LF
    input integer st;
    begin
        txs("State;", 6); txdec(st, 1);
        case (st)
            0: txs(" , Range Valid", 14);
            1: txs(" , Sigma Fail", 13);
            2: txs(" , Signal Fail", 14);
            3: txs(" , Min Range Fail", 17);
            4: txs(" , Phase Fail", 13);
            5: txs(" , Hardware Fail", 16);
            default: txs(" , No Update", 12);
        endcase
        crlf;
    end
endtask
task d_line;                            // "d:" + 右对齐 5 格的毫米（至少 nd 位）+ " mm" CR LF
    input integer mm;
    input integer nd;
    integer w, k;
    begin
        txs("d:", 2);
        w = (ndig(mm) > nd) ? ndig(mm) : nd;
        for (k = w; k < 5; k = k + 1) tx(8'h20);
        if (w >= 5) tx(8'h20);
        txdec(mm, nd);
        txs(" mm", 3); crlf;
    end
endtask

// ---- 模型 + 检查 ----
integer e_st = 0, e_mm = 0;             // 模型：最近一组的原始值
task raw_is;                            // 原始值还是最近一个完整组的（半组、乱码不改它）
    begin
        if (o_st !== e_st || o_mm !== e_mm) begin $display("  raw S%0d %0dmm, expected S%0d %0dmm", o_st, o_mm, e_st, e_mm); fail("raw O_st / O_mm"); end
    end
endtask
task expect_upd;                        // 刚发完一组（状态 st、毫米 mm）：原始值更新；测量（0 / 2 / 4）O_upd 正好多一次、O_cm / O_near 按规格；其余跳过
    input integer st;
    input integer mm;
    input integer n0;
    integer r, ecm;
    reg     en;
    begin
        #200;
        e_st = (st > 255) ? 255 : st;
        e_mm = (mm > 9999) ? 9999 : mm;
        raw_is;
        if (e_st == 0 || e_st == 2 || e_st == 4) begin
            r   = (e_st == 0 && mm >= MIN_MM && mm <= 9999 && mm / 10 <= MAX_CM) ? mm / 10 - OFF_CM : 255;
            ecm = (r > r1) ? r : r1;
            en  = (r <= NEAR_CM) || (r1 <= NEAR_CM);
            r1  = r;
            if (nupd != n0 + 1) begin $display("  st %0d mm %0d: %0d updates", st, mm, nupd - n0); fail("O_upd count"); end
            if (o_cm !== ecm)   begin $display("  st %0d mm %0d: expected cm %0d", st, mm, ecm); fail("O_cm"); end
            if (o_near !== en)  begin $display("  st %0d mm %0d: expected near %0d", st, mm, en); fail("O_near"); end
            if (o_alive !== 1'b1 || o_link !== 1'b1) fail("alive / link after a measurement");
        end else begin
            nskip = nskip + 1;
            if (nupd != n0) begin $display("  st %0d mm %0d: skipped group gave %0d updates", st, mm, nupd - n0); fail("O_upd on a skipped group"); end
        end
    end
endtask
task grp;                               // 发一组完整的
    input integer st;
    input integer mm;
    integer n0;
    begin
        n0 = nupd; st_line(st); d_line(mm, 1); expect_upd(st, mm, n0);
    end
endtask
task no_upd;                            // 刚发的东西不该出结果
    input integer n0;
    begin
        #200;
        if (nupd != n0) fail("unexpected O_upd");
    end
endtask
task wait_ms;
    input integer n;
    integer t0;
    begin
        t0 = nms;
        wait (nms >= t0 + n);
        #20;
    end
endtask

integer n0, k, t0;
initial begin
    #1000; rst_n = 1'b1; #1000;
    // ---- 复位以后：没有数据 ----
    if (o_cm !== 8'd255 || o_near !== 1'b0 || o_alive !== 1'b0 || o_link !== 1'b0 || o_upd !== 1'b0) fail("reset state");

    // ---- 上电从一组的半中间开始收：前面没有状态的距离行丢掉 ----
    n0 = nupd;
    txs("e , Range Valid", 15); crlf;                   // 状态行的后半截（"e;" 没收到）
    d_line(730, 1);
    no_upd(n0); raw_is;                                 // 原始值也不动（复位值 S000 0000）
    if (o_link !== 1'b1) fail("link after bytes");
    if (o_alive !== 1'b0) fail("alive without a group");
    txs("  730 mm", 8); crlf;                           // 距离行的后半截（"d:" 没收到）
    no_upd(n0);

    // ---- 第一组：一组就算近（O_near），O_cm 要两组 ----
    grp(0, 730);                                        // r 73：cm = max(73, 255) = 255，near = 1
    grp(0, 730);                                        // cm 73
    grp(0, 600);                                        // cm = max(60, 73) = 73
    grp(0, 900);                                        // cm = max(90, 60) = 90，near（上一组 60）
    grp(0, 900);                                        // cm 90，near 0

    // ---- 近 → 没有：一组量不到马上放开；没有 → 近：要两组 ----
    grp(0, 500); grp(0, 500);                           // cm 50
    grp(4, 8190);                                       // 超范围（说明书截图）：cm 255 马上放开，near 还是 1（上一组 50）
    grp(0, 500);                                        // cm 255，near 1
    grp(0, 500);                                        // cm 50

    // ---- 状态号：2 / 4 = 前面没东西（算测量，马上放开）；1 / 3 / 5 / 255 / 说明书里没有的 = 跳过（距离不变）----
    for (k = 1; k <= 5; k = k + 1) grp(k, 500);         // 1 跳过（cm 50）、2 放开（255）、3 跳过、4 255、5 跳过
    grp(255, 500);
    grp(0, 500); grp(0, 500);                           // cm 50
    for (k = 1; k <= 5; k = k + 2) grp(k, 300);         // 1 / 3 / 5：cm 还是 50（跳过的组带着别的距离也不算）
    grp(255, 300);
    n0 = nupd; txs("State;10", 8); txs(" , Range Valid", 14); crlf; d_line(300, 1); expect_upd(10, 300, n0);   // 说明书里没有的号：跳过
    grp(6, 300); grp(20, 300); grp(40, 300); grp(254, 300);                   // 6、两位数里有 0、末位是 0 / 4（不能只看个位）
    grp(256, 300); grp(260, 300); grp(300, 300); grp(1000, 300); grp(65535, 300);   // 超过 255 记 255（跳过）
    grp(250, 300); grp(25, 300); grp(2, 300);          // 250 / 25 照原样；2 放开
    n0 = nupd; txs("State;002", 9); txs(" , Signal Fail", 14); crlf; d_line(300, 1); expect_upd(2, 300, n0);    // 前导 0
    grp(0, 500); grp(0, 500);
    // ---- 11-17 上车：量到了和 255（没有新数据）一组隔一组 → 距离要出来（原来一直 255）----
    for (k = 0; k < 4; k = k + 1) begin grp(0, 450); grp(255, 450); end   // cm 45
    if (o_cm !== 8'd40) fail("alternating State 0 / 255: distance must come through");
    for (k = 0; k < 3; k = k + 1) begin grp(1, 8190); grp(0, 650); end    // Sigma Fail 夹在中间：cm 65
    if (o_cm !== 8'd60) fail("alternating State 0 / 1: distance must come through");
    // ---- 只有跳过的组：不算活着（逐拍核对管 O_alive 的时间）→ LOST，O_cm 255 ----
    t0 = nms;
    while (nms < t0 + ALV_MS + 3) grp(255, 650);
    if (o_alive !== 1'b0 || o_link !== 1'b1 || o_cm !== 8'd255 || o_near !== 1'b0) fail("only No Update groups: should be LOST with cm 255");
    grp(0, 650); grp(0, 650);
    // ---- 11-18 上车：两次测量隔得比 LNK_MS 还久（中间线上安静 → NOLK），没到 ALV_MS → 距离照样出来（原来 300 ms 就掉线，一直 255）----
    grp(0, 500); grp(0, 500);                                            // cm 50
    grp(0, 420); wait_ms(LNK_MS + 3);                                    // cm 50；线上安静
    if (o_link !== 1'b0 || o_alive !== 1'b1 || o_cm !== 8'd45) fail("quiet line shorter than ALIVE_MS: link down, still alive, distance kept");
    grp(255, 420); wait_ms(2); grp(0, 420);                              // 第二次测量隔了 > LNK_MS：cm = max(42, 42)
    if (o_cm !== 8'd37) fail("measurements further apart than LINK_MS: distance must come through");
    if (o_dt <= LNK_MS || o_dt >= ALV_MS) fail("tb: the two measurements should be between LNK_MS and ALV_MS apart");
    grp(0, 650); grp(0, 650);
    n0 = nupd; txs("State; 0", 8); txs(" , Range Valid", 14); crlf; d_line(500, 1); expect_upd(0, 500, n0);    // 数字前面的空格跳过

    // ---- MIN_MM / MAX_CM 边界（各差 1 毫米）----
    grp(0, 100); grp(0, 100);                            // 正好 MIN_MM：r 5
    grp(0, 99);                                         // 差 1：不算
    grp(0, 0);                                          // 前面没东西也会报 0 mm（说明书截图）
    grp(0, 1209); grp(0, 1209);                         // 120 cm：正好 MAX_CM
    grp(0, 1210);                                       // 121 cm：不算
    grp(0, 1000); grp(0, 1000);                         // 4 位

    // ---- NEAR_CM 边界 ----
    grp(0, 810);                                        // 81：near = 0（上一组 100）
    grp(0, 810);
    grp(0, 809);                                        // 80：near
    grp(0, 810);                                        // 上一组 80：还是 near
    grp(0, 810);                                        // 两组都 81：不 near

    // ---- 位数：前导 0、5 位、超过 9999 ----
    n0 = nupd; st_line(0); d_line(730, 4);  expect_upd(0, 730, n0);       // "0730"
    n0 = nupd; st_line(0); d_line(1200, 5); expect_upd(0, 1200, n0);      // "01200" = 1200：120 cm 算
    grp(0, 12345);                                                       // 5 位
    grp(0, 99999);
    grp(0, 9999);                                                        // 4 位最大：999 cm 不算
    grp(0, 300); grp(0, 300);

    // ---- 乱码、像 "e;" / "d:" 但不是的、没数字的距离行 ----
    n0 = nupd;
    txs("xe:d;ed", 7); tx(8'hFF); tx(8'h00); tx(8'h3B); tx(8'h3A); crlf;  // 'e' 后面不是 ';'、'd' 后面不是 ':'、单独的 ';' ':'
    no_upd(n0);
    st_line(0); txs("d:  mm", 6); crlf;                                  // 距离行没有数字：这一组作废
    d_line(400, 1);                                                      // 它后面的距离行没有状态：不算
    no_upd(n0); raw_is;
    st_line(0); txs("zz e: d", 7); crlf; d_line(400, 1); expect_upd(0, 400, n0);   // 状态和距离中间夹乱码：照常
    n0 = nupd; st_line(4); st_line(0); d_line(400, 1); expect_upd(0, 400, n0);    // 两个状态行：用后一个
    n0 = nupd; st_line(0); st_line(4); d_line(400, 1); expect_upd(4, 400, n0);
    n0 = nupd; st_line(0); txs("d:  400", 7); crlf; expect_upd(0, 400, n0);        // 没有 " mm"，CR 也算结束

    // ---- 掉线（时间由逐拍核对管）：掉线以后 O_cm = 255、O_near = 0，上一组从 255 重来 ----
    grp(0, 500); grp(0, 500);
    wait_ms(ALV_MS + 2);
    if (o_alive !== 1'b0 || o_link !== 1'b0 || o_cm !== 8'd255 || o_near !== 1'b0) fail("after timeout");
    n0 = nupd; k = ncoin;                                                // 掉线以后第一次测量正好和节拍同一拍：O_dt = ALV_MS（已经数满，不能再加 1）
    st_line(0); txs("d:  500", 7);
    tx_at(8'h20, nms + 3);
    txs("mm", 2); crlf;
    expect_upd(0, 500, n0);                                              // cm 还是 255（上一组按 255），near 1
    if (ncoin != k + 1) fail("tb: group end after a timeout did not land on a tick");
    if (o_dt !== ALV_MS) fail("O_dt after a timeout on a tick edge");
    grp(0, 500);                                                         // cm 50

    // ---- 一组正好在 O_alive 该掉的那个沿结束：以这一组为准（O_cm 用它和上一组，O_alive 不掉）----
    grp(0, 450);
    n0 = nupd; k = ncoin; t0 = t_upd;
    st_line(0); txs("d:  400", 7);
    tx_at(8'h20, t0 + ALV_MS);                                           // 组结束的那个空格
    txs("mm", 2); crlf;
    expect_upd(0, 400, n0);                                              // cm = max(40, 45) = 45
    if (ncoin != k + 1) fail("tb: group end did not land on the alive timeout tick");

    // ---- 一个字节正好在 O_link 该掉的那个沿收到：以收到为准（O_link 不掉）----
    wait_ms(ALV_MS + 2);                                                 // 先全掉线
    tx(8'h4A);
    k = ncoin; t0 = t_byte;
    tx_at(8'h4A, t0 + LNK_MS);
    if (ncoin != k + 1) fail("tb: byte did not land on the link timeout tick");
    if (o_link !== 1'b1 || o_alive !== 1'b0) fail("link after same-tick byte");

    // ---- 有字节、没有有效组：O_link = 1、O_alive = 0（屏幕 LOST）----
    for (k = 0; k < 6; k = k + 1) begin txs("junk", 4); wait_ms(LNK_MS / 4); end
    if (o_alive !== 1'b0) fail("alive with junk only");
    if (o_link !== 1'b1)  fail("link with junk");

    // ---- 波特率偏 ±2%（模块自己的晶振）----
    bit_ns = 8506; grp(0, 700); grp(0, 700); grp(0, 1150);
    bit_ns = 8854; grp(0, 710); grp(0, 710); grp(0, 330);
    bit_ns = BIT_NS;

    // ---- 恢复 ----
    grp(0, 650); grp(0, 650);

    #1000;
    if (nskip < 20) fail("tb: too few skipped groups were sent");
    if (ndtmid < 1) fail("tb: no measurement pair between LNK_MS and ALV_MS apart");
    if (errors == 0) $display("PASS tb_tof_vl53 (%0d updates, %0d skipped groups, %0d same-tick bytes)", nupd, nskip, ncoin);
    else             $display("FAIL tb_tof_vl53: %0d errors", errors);
    $finish;
end

initial begin #2_000_000_000; $display("FAIL timeout"); $finish; end

endmodule
