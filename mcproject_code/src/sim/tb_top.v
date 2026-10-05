`timescale 1ns / 1ps
// 顶层集成测试：仿真真正的 mctop.v（视频相关的 mcsys_pll / mc_cam_if / mc_framebuf / mc_disp_if 用 stubs/ 里的替身，
// 但文字层、音频子系统用真的；外面接一个行为级 TF 卡和一个什么都应答的 ES8388 I2C 从机），检查顶层接线：
//   版面 / 音量参数 → 上电尾巴自动回零（发出的每个字节）→ 按键（相机增益键）/ 屏幕文字 → 背景音乐上电自动播
//   → 喂食（霍尔：尾巴摇来回 + 进食音效）→ 状态灯真值表 → SW1 按住复位（尾巴重新回零、背景音乐重新开始）。
//
// 为了仿真快（整个顶层的行为级仿真每个时钟都要算几百个 always 块，很慢），用 defparam 把时间全部压缩：
//   mc_tick 按 1 MHz 时钟工作（"1 ms" = 1000 个 100MHz 时钟，"10 ms 节拍" = 100 us）、按键去抖/长按缩短、
//   尾巴串口 1 Mbps 且各段等待缩短、SW1 长按复位 3 ms。
// 各模块在真实参数下的行为由各自的测试台（tb_key / tb_tail / tb_audio ...）覆盖，这里只看"顶层连得对不对"。
module tb_top;

reg  sys_clk = 0;
always #20 sys_clk = ~sys_clk;                  // 25 MHz

reg  [2:0] key = 3'b111;                        // SW1 SW2 SW3，按下为低
wire [2:0] led;

wire cam_scl, cam_sda, cam_24m, cam_rst;
wire rx_clk_n, rx_clk_p; wire [3:0] rx_d_n, rx_d_p;
wire tx_clk_n, tx_clk_p; wire [3:0] tx_d_n, tx_d_p;
wire dsi_pwm, dsi_rst_n;
reg  hall = 0;                                  // 霍尔传感器：1 = 磁铁靠近
wire step_tx;
wire [12:0] ddr_addr; wire [1:0] ddr_ba; wire [0:0] ddr_cke, ddr_odt, ddr_cs_n, ddr_ck_p, ddr_ck_n;
wire ddr_ras_n, ddr_cas_n, ddr_we_n;
wire [1:0] ddr_dm, ddr_dqs_p, ddr_dqs_n; wire [15:0] ddr_dq;
wire aud_mclk, aud_sclk, aud_lrck, aud_dsdin, aud_cclk, spk_ctl;
tri1 aud_sda;
wire sd_cs_n, sd_sck, sd_mosi, sd_miso;

mctop dut (
    .I_sys_clk(sys_clk), .I_key(key), .O_led(led),
    .O_cam_scl(cam_scl), .IO_cam_sda(cam_sda), .O_cam_24m(cam_24m), .O_cam_rst(cam_rst),
    .IO_rx_clk_pad_n(rx_clk_n), .IO_rx_clk_pad_p(rx_clk_p), .IO_rx_data_pad_n(rx_d_n), .IO_rx_data_pad_p(rx_d_p),
    .IO_tx_clk_pad_n(tx_clk_n), .IO_tx_clk_pad_p(tx_clk_p), .IO_tx_data_pad_n(tx_d_n), .IO_tx_data_pad_p(tx_d_p),
    .O_dsi_pwm(dsi_pwm), .O_dsi_rst_n(dsi_rst_n),
    .O_step_tx(step_tx), .I_hall(hall),
    .O_aud_mclk(aud_mclk), .O_aud_sclk(aud_sclk), .O_aud_lrck(aud_lrck), .O_aud_dsdin(aud_dsdin),
    .O_aud_cclk(aud_cclk), .IO_aud_cdata(aud_sda), .O_spk_ctl(spk_ctl),
    .O_sd_cs_n(sd_cs_n), .O_sd_sck(sd_sck), .O_sd_mosi(sd_mosi), .I_sd_miso(sd_miso),
    .ddr_addr(ddr_addr), .ddr_ba(ddr_ba), .ddr_cke(ddr_cke), .ddr_odt(ddr_odt), .ddr_cs_n(ddr_cs_n),
    .ddr_ras_n(ddr_ras_n), .ddr_cas_n(ddr_cas_n), .ddr_we_n(ddr_we_n), .ddr_ck_p(ddr_ck_p), .ddr_ck_n(ddr_ck_n),
    .ddr_dm(ddr_dm), .ddr_dq(ddr_dq), .ddr_dqs_p(ddr_dqs_p), .ddr_dqs_n(ddr_dqs_n)
);

i2c_ack_slave u_codec (.scl(aud_cclk), .sda(aud_sda));
sd_card_model #(.IMAGE_FILE("sd_mbr.hex"), .SDHC(1), .V2(1), .ACMD41_TRIES(3), .READ_DELAY(5)) u_card (
    .cs_n(sd_cs_n), .sck(sd_sck), .mosi(sd_mosi), .miso(sd_miso)
);

// ---- 时间压缩 ----
defparam dut.u_mc_tick.CLK_HZ        = 1_000_000;    // "1 ms" = 1000 个时钟
defparam dut.u_key.DEBOUNCE_MS       = 10;           // 去抖 1 个节拍
defparam dut.u_key.LONG_MS           = 50;           // 长按 5 个节拍（0.5 ms 仿真时间）
defparam dut.u_hold_rst.HOLD_MS      = 3;            // SW1 按住 3 ms 复位（长按判定 0.5 ms，远小于它）
defparam dut.u_tail.BAUD             = 1_000_000;    // 尾巴串口 1 Mbps（真实 115200 的行为由 tb_tail/tb_uart 覆盖）
defparam dut.u_tail.LEG_MS           = 10;
defparam dut.u_tail.HOME_MS          = 10;
defparam dut.u_tail.GAP_MS           = 2;
defparam dut.u_tail.INIT_DELAY_MS    = 20;           // 上电 20 "ms" 后自动回零（真实是 1000 ms，由 tb_tail 覆盖）
defparam dut.u_hall.DEBOUNCE_MS      = 3;            // 霍尔去抖 3 个"毫秒"

integer errors = 0;
task fail; input [255:0] msg; begin $display("FAIL %0s (t=%0t)", msg, $time); errors = errors + 1; end endtask

// 任何一项检查失败就马上结束（突变检查时省时间；全部通过时没有影响）
always @(errors) if (errors != 0) begin
    #1;
    $display("FAIL  tb_top: %0d error(s) so far, aborting early", errors);
    $finish;
end

// ---- 白盒接线核对：每个时钟比较"连线两端"（功能测试里看不出来的接错）----
`define WCHK(a, b, msg) if ((a) !== (b)) begin $display("FAIL wiring: %0s (t=%0t)", msg, $time); errors = errors + 1; end
reg wire_en = 1'b0;
always @(posedge dut.S_clk_100m) if (wire_en) begin
    `WCHK(dut.u_disp.I_status[0], dut.S_time_ms[9],      "status square 0 (heartbeat) is not the 1 Hz heartbeat")
    `WCHK(dut.u_disp.I_status[1], dut.S_ddr_ready_s,     "status square 1 is not the DDR-calibrated flag")
    `WCHK(dut.u_disp.I_status[2], dut.S_panel_ready_s,   "status square 2 is not the panel-ready flag")
    `WCHK(dut.u_disp.I_status[3], dut.S_cam_cfg_done_s,  "status square 3 is not the camera-configured flag")
    `WCHK(dut.u_disp.I_status[4], dut.S_csi_alive,       "status square 4 is not the CSI-frames-alive flag")
    `WCHK(dut.u_disp.I_status[5], dut.S_isp_alive,       "status square 5 is not the ISP-frames-alive flag")
    `WCHK(dut.u_disp.I_status[6], ~dut.S_lane_error_s,   "status square 6 is not the no-lane-error flag")
    `WCHK(dut.u_disp.I_status[7], 1'b1,                  "status square 7 must be always green")
    `WCHK(dut.u_disp.I_win_en,    dut.S_isp_alive,       "the camera window enable is not the ISP-frames-alive flag")
    `WCHK(dut.u_disp.I_txt_bus,   dut.u_dash.O_bus,      "the text bus of the display interface is not the dashboard bus")
    `WCHK(dut.u_tail.I_cmd_wag,   dut.u_behavior.O_tail_wag, "tail wag command is not the behaviour layer's")
    `WCHK(dut.u_behavior.I_tail_busy, dut.u_tail.O_busy, "behaviour layer tail-busy is not the tail's busy")
    `WCHK(dut.u_behavior.I_hall,  dut.u_hall.O_fed,      "behaviour layer hall input is not the debounced hall")
    `WCHK(dut.u_audio.I_sfx_play, dut.u_behavior.O_sfx_play, "audio effect play is not the behaviour layer's")
    `WCHK(dut.u_audio.I_sfx_clip, dut.u_behavior.O_sfx_clip, "audio effect clip is not the behaviour layer's")
    `WCHK(dut.u_behavior.I_sfx_busy, dut.u_audio.O_sfx_busy, "behaviour layer sfx-busy is not the audio's")
    `WCHK(dut.u_dash.I_tail_seq,  dut.u_tail.O_seq,      "dashboard tail state is not the tail's O_seq")
    `WCHK(dut.u_dash.I_hall,      dut.u_hall.O_fed,      "dashboard hall input is not the debounced hall")
    `WCHK(dut.u_dash.I_key_pressed, dut.u_key.O_pressed, "dashboard key levels are not the key module's O_pressed")
    `WCHK(dut.u_bench.I_key_short, dut.u_key.O_short,    "bench short-press input is not the key module's O_short")
    `WCHK(dut.u_cam.I_key_n,      dut.u_bench.O_cam_key_n, "camera gain keys are not the bench's")
end

// "一个节拍(10 ms)" = 100 us 仿真时间
localparam TICK_NS = 100_000;
task press;  input integer k; input integer ticks; begin key[k] = 1'b0; #(ticks * TICK_NS); key[k] = 1'b1; #(4 * TICK_NS); end endtask
task spress; input integer k; begin press(k, 3); end endtask           // 短按
task lpress; input integer k; begin press(k, 9); end endtask           // 长按（> 5 个节拍）

// ---- 字符 RAM 读取 ----
localparam COLS = 45;
task expect_text;
    input integer r, col;
    input [8*45-1:0] s;
    input integer len;
    integer k;
    reg [7:0] got, exp;
    begin
        for (k = 0; k < len; k = k + 1) begin
            got = dut.u_disp.u_osd.S_mem[r*COLS + col + k];
            exp = s[(len-1-k)*8 +: 8];
            if (got !== exp) begin
                $display("FAIL text row %0d col %0d: got '%c' expected '%c' (t=%0t)", r, col + k, got, exp, $time);
                errors = errors + 1;
            end
        end
    end
endtask

// ---- 步进 UART 解码（1 Mbps）----
localparam BIT_NS = 1000;
reg [7:0] txb [0:16383];
integer   txn = 0;
reg [7:0] tb_b;
integer   tbi;
initial begin
    forever begin
        @(negedge step_tx);
        #(BIT_NS / 2);
        for (tbi = 0; tbi < 8; tbi = tbi + 1) begin #(BIT_NS); tb_b[tbi] = step_tx; end
        #(BIT_NS);
        txb[txn] = tb_b; txn = txn + 1;
    end
end

// 期望字节流
reg [7:0] exb [0:127];
integer   exn;
task ex; input [7:0] v; begin exb[exn] = v; exn = exn + 1; end endtask
task home_bytes; begin
    ex(8'h01); ex(8'h0E); ex(8'h52); ex(8'h6B);
    ex(8'h01); ex(8'hF3); ex(8'hAB); ex(8'h01); ex(8'h00); ex(8'h6B);
    ex(8'h01); ex(8'h9A); ex(8'h00); ex(8'h00); ex(8'h6B);
    ex(8'h01); ex(8'h0A); ex(8'h6D); ex(8'h6B);
end endtask
task pos_frame; input dir; input [31:0] pul; begin
    ex(8'h01); ex(8'hFD); ex({7'd0, dir}); ex(8'h00); ex(8'd80); ex(8'h00);           // 80 RPM、加速度 0
    ex(pul[31:24]); ex(pul[23:16]); ex(pul[15:8]); ex(pul[7:0]); ex(8'h01); ex(8'h00); ex(8'h6B);
end endtask
task wag_bytes; begin
    ex(8'h01); ex(8'hF3); ex(8'hAB); ex(8'h01); ex(8'h00); ex(8'h6B);
    pos_frame(1'b1, 32'd267); pos_frame(1'b0, 32'd0); pos_frame(1'b0, 32'd267); pos_frame(1'b0, 32'd0);   // 左 = CCW，30° = 267 脉冲
end endtask
task compare_tx;
    input [255:0] name;
    input integer start;
    integer j;
    begin
        for (j = 0; j < exn; j = j + 1)
            if (txb[start + j] !== exb[j]) begin $display("FAIL %0s: byte %0d = %h, expected %h", name, j, txb[start + j], exb[j]); errors = errors + 1; end
    end
endtask

// ---- 音频：I2S 接收器，左（背景音乐）、右（音效）两个声道各数"非零帧"有多少 ----
reg        lrck_q = 1;
integer    cnt = 0;
reg [15:0] sh = 0, rx_l = 0;
reg        got_l = 0;
integer    l_nz = 0, r_nz = 0, n_frames = 0;
reg        l_first_set = 0, r_arm = 0, r_first_set = 0;     // 第一个非零的左声道采样；右声道要先"上膛"，再记下之后第一个非零采样
reg [15:0] l_first = 0, r_first = 0;
always @(posedge aud_sclk) begin
    if (aud_lrck !== lrck_q) cnt = 0; else cnt = cnt + 1;
    lrck_q = aud_lrck;
    if (cnt >= 1 && cnt <= 16) sh = {sh[14:0], aud_dsdin};
    if (cnt == 16) begin
        if (aud_lrck == 1'b0) begin rx_l = sh; got_l = 1; end
        else if (got_l) begin
            n_frames = n_frames + 1;
            if (rx_l !== 16'd0) l_nz = l_nz + 1;
            if (sh   !== 16'd0) r_nz = r_nz + 1;
            if (rx_l !== 16'd0 && !l_first_set) begin l_first_set = 1; l_first = rx_l; end
            if (sh   !== 16'd0 && r_arm && !r_first_set) begin r_first_set = 1; r_first = sh; end
            got_l = 0;
        end
    end
end

// 曲目开头的字节（第 0 个采样的值用来核对：曲目号、声道的接线）
reg [7:0] clip1_b [0:63];
reg [7:0] clip2_b [0:63];
initial begin
    $readmemh("sd_mbr_clip1.hex", clip1_b, 0, 47);
    $readmemh("sd_mbr_clip2.hex", clip2_b, 0, 47);
end
function integer s16w; input [15:0] v; begin s16w = (v >= 32768) ? (v - 65536) : v; end endfunction
integer exp_v;

// 音效（右声道那一路）开始播放的次数
integer n_sfx_start = 0;
reg sfx_busy_d = 0;
always @(posedge dut.S_clk_100m) begin
    sfx_busy_d <= dut.S_sfx_busy;
    if (dut.S_sfx_busy && !sfx_busy_d) n_sfx_start = n_sfx_start + 1;
end

// 相机增益键脉冲的宽度：台架把一次短按变成 4 个 "10 ms" 节拍宽的低电平（真实的 ae_set 要 ≥ 30 ms 才认）；
// 加载时刻相对节拍的相位不定，所以宽度在 3 ~ 4 个节拍之间（压缩后一个节拍 = 100 us）。
// 顶层把哪个节拍送给台架，宽度就差一个数量级（1 ms 节拍 → 约 1/10，100 ms 节拍 → 约 10 倍）。
time    kp0_t = 0, kp1_t = 0, kp0_w = 0, kp1_w = 0;
integer kp0_n = 0, kp1_n = 0;
reg     kp0_open = 1'b0, kp1_open = 1'b0;
always @(negedge dut.S_cam_key_n[0]) if (wire_en) begin kp0_t = $time; kp0_open = 1'b1; end
always @(posedge dut.S_cam_key_n[0]) if (kp0_open) begin kp0_w = $time - kp0_t; kp0_n = kp0_n + 1; kp0_open = 1'b0; end
always @(negedge dut.S_cam_key_n[1]) if (wire_en) begin kp1_t = $time; kp1_open = 1'b1; end
always @(posedge dut.S_cam_key_n[1]) if (kp1_open) begin kp1_w = $time - kp1_t; kp1_n = kp1_n + 1; kp1_open = 1'b0; end

task wait_sfx_idle;                              // 等音效播完（带超时，单位：10 us）
    input integer timeout_10us;
    integer n;
    begin
        n = 0;
        while (dut.S_sfx_busy !== 1'b0 && n < timeout_10us) begin #10_000; n = n + 1; end
        if (dut.S_sfx_busy !== 1'b0) begin $display("FAIL sound effect never finished (state %0d err %0d)", dut.S_sfx_state, dut.u_audio.O_sfx_err); errors = errors + 1; end
    end
endtask

reg [2:0] led_lo, led_hi;                        // 一个观察窗口里每个灯出现过 0 / 出现过 1
task led_window;                                 // 看 n 个 100 us
    input integer n;
    integer q;
    begin
        led_lo = 3'b000; led_hi = 3'b000;
        for (q = 0; q < n; q = q + 1) begin #100_000; led_lo = led_lo | ~led; led_hi = led_hi | led; end
    end
endtask

// 0a 窗口：强制前存下的原值（见 0a 的说明）
reg sv_ddr, sv_panel, sv_cfg, sv_csi, sv_isp, sv_lane;
reg [7:0] sv_ae;   reg [2:0] sv_asd;   reg [1:0] sv_acd, sv_bst, sv_sst;
integer i, s0, lock_low_seen, t, e0, n1;
initial begin
    #200_000;
    wire_en = 1'b1;
    if (dut.S_pll_lock !== 1'b1) fail("PLL not locked");
    if (spk_ctl !== 1'b1) fail("speaker amp enable should be high");

    // ---------- 0. 配置区的参数是否真的送到了下游（版面：上半相机 800×560、方块 v 568 高 40、文字 v 616 三行；音量最大 33）----------
    if (dut.u_disp.IMG_W !== 800 || dut.u_disp.IMG_H !== 560) fail("camera window size parameters");
    if (dut.u_disp.SQ_V0 !== 568 || dut.u_disp.SQ_H !== 40)   fail("status square row / height parameters");
    if (dut.u_disp.TXT_V0 !== 616 || dut.u_disp.TXT_ROWS !== 3 || dut.u_disp.TXT_U0 !== 40 || dut.u_disp.TXT_COLS !== 45) fail("text box parameters");
    if (dut.u_dash.ROWS !== 3 || dut.u_dash.COLS !== 45) fail("dashboard rows / cols parameters");
    if (dut.u_cam.CROP_H !== 560 || dut.u_cam.IMG_H !== 560 || dut.u_cam.CROP_Y0 !== 261) fail("camera crop parameters (560 rows from row 261)");
    if (dut.u_audio.u_cfg.SPK_VOL !== 6'd33 || dut.u_audio.u_cfg.HP_VOL !== 6'd33) fail("volume must be the maximum 33");

    // ---------- 0a. 接线核对（强制值窗口）----------
    // 仿真里相机 / DDR / 屏幕是替身，状态信号全是常数，接错、接反都看不出来。
    // 所以把顶层里喂给"状态方块 / 相机窗口 / 状态面板"的信号强制成互不相同的值，核对下游每个输入口收到的就是对应的那一个。
    // 状态方块 1..6 的六个来源：每个来源在三个相位里的取值 = 编号 1..6 的二进制位（六个来源两两不同，也没有一个是常数）；
    // 方块的比较由上面的 wire_en 那一块每个时钟自动做。
    //                   相位 0 / 1 / 2
    //   ddr_ready(1)      1 / 0 / 0         panel_ready(2)   0 / 1 / 0         cam_cfg_done(3)  1 / 1 / 0
    //   csi_alive(4)      0 / 0 / 1         isp_alive(5)     1 / 0 / 1         lane_error(6)    0 / 1 / 1
    sv_ddr = dut.S_ddr_ready_s; sv_panel = dut.S_panel_ready_s; sv_cfg = dut.S_cam_cfg_done_s;
    sv_csi = dut.S_csi_alive;   sv_isp   = dut.S_isp_alive;     sv_lane = dut.S_lane_error_s;
    force dut.S_ddr_ready_s = 1'b1; force dut.S_panel_ready_s = 1'b0; force dut.S_cam_cfg_done_s = 1'b1;
    force dut.S_csi_alive   = 1'b0; force dut.S_isp_alive     = 1'b1; force dut.S_lane_error_s    = 1'b0;
    #(1_000);
    force dut.S_ddr_ready_s = 1'b0; force dut.S_panel_ready_s = 1'b1; force dut.S_cam_cfg_done_s = 1'b1;
    force dut.S_csi_alive   = 1'b0; force dut.S_isp_alive     = 1'b0; force dut.S_lane_error_s    = 1'b1;
    #(1_000);
    force dut.S_ddr_ready_s = 1'b0; force dut.S_panel_ready_s = 1'b0; force dut.S_cam_cfg_done_s = 1'b0;
    force dut.S_csi_alive   = 1'b1; force dut.S_isp_alive     = 1'b1; force dut.S_lane_error_s    = 1'b1;
    #(1_000);
    force dut.S_ddr_ready_s = sv_ddr; force dut.S_panel_ready_s = sv_panel; force dut.S_cam_cfg_done_s = sv_cfg;
    force dut.S_csi_alive   = sv_csi; force dut.S_isp_alive     = sv_isp;   force dut.S_lane_error_s    = sv_lane;
    #(10);
    release dut.S_ddr_ready_s; release dut.S_panel_ready_s; release dut.S_cam_cfg_done_s;
    release dut.S_csi_alive;   release dut.S_isp_alive;     release dut.S_lane_error_s;
    // 状态面板的输入口：每一路给一个不同的值（正常运行时两路音频的状态量常常相同）。
    // 尾巴动作和霍尔不在这里强制（它们是 mc_tail / mc_hall 自己的寄存器，强制会改变这两个模块自己的行为），
    // 由上面的白盒核对每个时钟比较 + 后面喂食时屏幕上的 HALL 1 来核对
    sv_ae = dut.S_cam_ae; sv_asd = dut.S_aud_sd; sv_acd = dut.S_aud_codec; sv_bst = dut.S_bgm_state; sv_sst = dut.S_sfx_state;
    force dut.S_cam_ae = 8'd77;
    force dut.S_aud_sd = 3'd2;  force dut.S_aud_codec = 2'd3;  force dut.S_bgm_state = 2'd1;  force dut.S_sfx_state = 2'd3;
    #(1_000);
    if (dut.u_dash.I_cam_ae !== 8'd77) fail("dashboard camera-gain input");
    if (dut.u_dash.I_aud_sd !== 3'd2 || dut.u_dash.I_aud_codec !== 2'd3) fail("dashboard SD / codec inputs");
    if (dut.u_dash.I_bgm_state !== 2'd1 || dut.u_dash.I_sfx_state !== 2'd3) fail("dashboard background-music / sound-effect inputs");
    // 这些线有的由子模块的寄存器直接驱动：release 不会恢复寄存器，所以先强制回原值
    force dut.S_cam_ae = sv_ae; force dut.S_aud_sd = sv_asd; force dut.S_aud_codec = sv_acd; force dut.S_bgm_state = sv_bst; force dut.S_sfx_state = sv_sst;
    #(10);
    release dut.S_cam_ae; release dut.S_aud_sd; release dut.S_aud_codec; release dut.S_bgm_state; release dut.S_sfx_state;
    #(1_000);

    // ---------- 1. 上电后尾巴自动回零（20 "ms" 之后：解除保护 / 使能 / 单圈就近回零 / 设坐标零点，共 19 字节）----------
    #(2_000_000);
    if (txn !== 19) begin $display("FAIL tail auto-homing after power-up sent %0d bytes, expected 19", txn); errors = errors + 1; end
    exn = 0; home_bytes; compare_tx("tail auto-homing", 0);

    // ---------- 2. 按键：SW2 / SW3 短按 = 相机增益 ±1；长按、SW1 短按什么也不做 ----------
    spress(1);                                                      // SW2 短按：增益 +1（40 ms 低电平脉冲 → 相机增益键）
    #(1_000_000);
    if (dut.u_cam.ae !== 8'd51) begin $display("FAIL cam gain after SW2 short: %0d (expected 51)", dut.u_cam.ae); errors = errors + 1; end
    if (kp0_n !== 1 || kp0_w < 299_000 || kp0_w > 401_000) begin $display("FAIL gain+ key pulse: %0d pulse(s), last one %0d ns wide, expected 1 pulse of 300 ~ 400 us (4 ticks of 10 ms)", kp0_n, kp0_w); errors = errors + 1; end
    spress(2);                                                      // SW3 短按：增益 -1
    #(1_000_000);
    if (dut.u_cam.ae !== 8'd50) begin $display("FAIL cam gain after SW3 short: %0d (expected 50)", dut.u_cam.ae); errors = errors + 1; end
    if (kp1_n !== 1 || kp1_w < 299_000 || kp1_w > 401_000) begin $display("FAIL gain- key pulse: %0d pulse(s), last one %0d ns wide, expected 1 pulse of 300 ~ 400 us (4 ticks of 10 ms)", kp1_n, kp1_w); errors = errors + 1; end
    // 按着 SW2 + SW3 不放（超过两个 "100 ms" 刷新周期）：第 0 行的 KEY 要显示还按着的键（011），松手后回到 000；
    // 上报给面板的必须是"按着"的电平，不是"刚按下"的单拍脉冲（单拍脉冲显示不出来）。SW1 按住超过 3 ms 会整机复位，这里不碰
    key[1] = 1'b0; key[2] = 1'b0;
    #(2_500_000);
    expect_text(0, 32, "011", 3);
    key[1] = 1'b1; key[2] = 1'b1;
    #(4 * TICK_NS);
    if (dut.u_cam.ae !== 8'd50) begin $display("FAIL cam gain changed by holding SW2 + SW3: %0d", dut.u_cam.ae); errors = errors + 1; end
    spress(0);                                                      // SW1 短按：没有功能
    lpress(1);                                                      // 长按：不改增益
    lpress(2);
    #(1_000_000);
    if (dut.u_cam.ae !== 8'd50) begin $display("FAIL cam gain changed by SW1 / a long press: %0d", dut.u_cam.ae); errors = errors + 1; end
    if (kp0_n !== 1 || kp1_n !== 1) fail("SW1 / long presses must not give gain-key pulses");

    // ---------- 3. 背景音乐上电自动循环播放（左声道），音效那一路（右声道）没触发时静音 ----------
    t = 0;
    while ((dut.S_aud_sd !== 3'd1 || dut.S_aud_codec !== 2'd1) && t < 3000) begin #10_000; t = t + 1; end
    if (dut.S_aud_codec !== 2'd1) begin $display("FAIL codec not configured (state %0d)", dut.S_aud_codec); errors = errors + 1; end
    if (dut.S_aud_sd !== 3'd1)    begin $display("FAIL TF card not mounted (state %0d)", dut.S_aud_sd); errors = errors + 1; end
    if (dut.u_audio.O_nclips !== 8'd8) begin $display("FAIL nclips = %0d, expected 8", dut.u_audio.O_nclips); errors = errors + 1; end
    if (dut.S_audio_ready !== 1'b1) fail("audio should be ready after the card is mounted and the codec configured");
    t = 0;
    while (dut.S_bgm_state !== 2'd2 && t < 3000) begin #10_000; t = t + 1; end
    if (dut.S_bgm_state !== 2'd2) begin $display("FAIL background music did not start by itself (state %0d err %0d)", dut.S_bgm_state, dut.u_audio.O_bgm_err); errors = errors + 1; end
    s0 = l_nz;
    #(2_000_000);
    if (l_nz - s0 < 90) begin $display("FAIL background music: only %0d non-zero left-channel frames in 2 ms (about 97 frames fit)", l_nz - s0); errors = errors + 1; end
    if (r_nz !== 0) begin $display("FAIL right channel (sound effects) not silent before any effect: %0d non-zero frames", r_nz); errors = errors + 1; end
    // 背景音乐的第一个采样 = AUD_BGM_CLIP.wav（这里 1.wav）的第 0 个采样：同时核对曲目号、声道的接线
    exp_v = s16w({clip1_b[45], clip1_b[44]});
    if (!l_first_set || s16w(l_first) !== exp_v) begin $display("FAIL first background-music sample %0d, expected %0d (clip 1 sample 0)", s16w(l_first), exp_v); errors = errors + 1; end
    // 屏幕文字（3 行整行核对，开机秒数那 5 位不比）
    expect_text(0, 0,  "GAIN 050  HALL 0  TAIL IDLE KEY 000 UP ", 39);
    expect_text(0, 44, "s", 1);
    expect_text(1, 0,  "SD READY  CODEC OK    BGM PLAY  SFX IDLE     ", 45);
    expect_text(2, 0,  "K3 LONG   SW2 gain+ SW3 gain- SW1 2s reset   ", 45);

    // ---------- 4. 喂食（霍尔 = 1）：尾巴摇一个来回再检查一次；进食音效（2.wav）播一遍，磁铁没拿开不重播 ----------
    if (dut.S_tail_busy !== 1'b0) fail("tail should be idle before the feeding test");
    s0 = txn; e0 = r_nz; n1 = n_sfx_start;
    r_arm = 1; r_first_set = 0;
    hall = 1;
    #(300_000);
    if (dut.S_hall_fed !== 1'b1) fail("hall input should be debounced to 1");
    if (dut.u_audio.O_sfx_cur !== 7'd2) begin $display("FAIL feeding played clip %0d, expected the eat sound 2", dut.u_audio.O_sfx_cur); errors = errors + 1; end
    // 第一个来回 58 字节，磁铁还在 → 马上第二个来回
    t = 0; while (txn - s0 < 70 && t < 2000) begin #10_000; t = t + 1; end
    if (txn - s0 < 70) begin $display("FAIL tail did not start a second wag cycle while the magnet stayed (%0d bytes)", txn - s0); errors = errors + 1; end
    hall = 0;                                                       // 拿开：当前这个来回摇完就停
    #(3_000_000);
    if (txn - s0 !== 116) begin $display("FAIL feeding: tail sent %0d bytes, expected 116 (two full wag cycles)", txn - s0); errors = errors + 1; end
    exn = 0; wag_bytes; wag_bytes; compare_tx("feeding: two wag cycles", s0);
    if (n_sfx_start - n1 !== 1) begin $display("FAIL feeding: %0d sound effects started, expected exactly 1", n_sfx_start - n1); errors = errors + 1; end
    wait_sfx_idle(4000);
    #(500_000);
    if (r_nz - e0 < 600) begin $display("FAIL feeding: only %0d non-zero right-channel frames (eat sound = 2.wav)", r_nz - e0); errors = errors + 1; end
    if (dut.u_audio.O_sfx_err !== 8'd0) begin $display("FAIL feeding: sfx error code %0d", dut.u_audio.O_sfx_err); errors = errors + 1; end
    exp_v = (s16w({clip2_b[45], clip2_b[44]}) + s16w({clip2_b[47], clip2_b[46]})) >>> 1;   // 立体声：左右取平均
    if (!r_first_set || s16w(r_first) !== exp_v) begin $display("FAIL first sample of the eat sound: %0d, expected %0d", s16w(r_first), exp_v); errors = errors + 1; end
    r_arm = 0;
    if (dut.S_bgm_state !== 2'd2) fail("background music must keep playing while the effect plays");
    #(2_500_000);
    expect_text(0, 10, "HALL 0", 6);
    // 磁铁一直在的情况：进食音效只播一遍；拿开再靠近才再播
    n1 = n_sfx_start;
    hall = 1;
    #(2_500_000);
    expect_text(0, 10, "HALL 1", 6);
    wait_sfx_idle(4000);
    #(6_000_000);
    if (n_sfx_start - n1 !== 1) begin $display("FAIL magnet kept near: %0d effects started, expected 1 (no replay)", n_sfx_start - n1); errors = errors + 1; end
    hall = 0; #(1_000_000);
    hall = 1; #(1_000_000);
    if (n_sfx_start - n1 !== 2) begin $display("FAIL magnet removed and put back: %0d effects started in total, expected 2", n_sfx_start - n1); errors = errors + 1; end
    hall = 0;
    wait_sfx_idle(4000);
    #(3_000_000);

    // ---------- 5. 状态灯真值表（没有屏幕时靠 LED 判断初始化进度）----------
    // 视频块在这里是替身，所以用 force 把 DDR 校准 / 面板初始化 / 相机配置 / 图像帧 这四个状态拉到各种组合；
    // "毫秒"被压缩了：约 2 Hz 的闪烁半周期 = 2.56 ms，约 1 Hz 的心跳半周期 = 5.12 ms
    force dut.S_ddr_ready_s = 1'b0; force dut.S_panel_ready_s = 1'b1; force dut.S_isp_alive = 1'b1; force dut.S_cam_cfg_done_s = 1'b0;
    #(500_000);
    led_window(110);                                                // 阶段 1：DDR 没好、面板好了、有图像帧、相机寄存器没配完
    if (led_hi[1] || !led_lo[1]) fail("LED2 must be off while the DDR is not calibrated");
    if (led_lo[2] || !led_hi[2]) fail("LED3 must be steady on while image frames arrive");
    if (!(led_lo[0] && led_hi[0])) fail("LED1 (heartbeat) must blink");
    force dut.S_ddr_ready_s = 1'b1; force dut.S_isp_alive = 1'b0; force dut.S_cam_cfg_done_s = 1'b1;
    #(500_000);
    led_window(60);                                                 // 阶段 2：DDR 好了、面板好了；相机配完了但没有图像帧（没接相机就是这样）
    if (led_lo[1] || !led_hi[1]) fail("LED2 must be steady on when the DDR and the panel are ready");
    if (!(led_lo[2] && led_hi[2])) fail("LED3 must blink when the camera is configured but no frames arrive");
    force dut.S_panel_ready_s = 1'b0; force dut.S_cam_cfg_done_s = 1'b0;
    #(500_000);
    led_window(60);                                                 // 阶段 3：DDR 好了、面板脚本没发完；相机寄存器没配完
    if (!(led_lo[1] && led_hi[1])) fail("LED2 must blink when the DDR is ready but the panel script has not finished");
    if (led_hi[2] || !led_lo[2]) fail("LED3 must be off while the camera is not configured");
    force dut.S_ddr_ready_s = 1'b0; force dut.S_isp_alive = 1'b1; force dut.S_cam_cfg_done_s = 1'b1;
    #(500_000);
    led_window(60);                                                 // 阶段 4：DDR 没好（面板也没好）；有图像帧、相机也配完了
    if (led_hi[1] || !led_lo[1]) fail("LED2 must be off while the DDR is not calibrated (panel not ready either)");
    if (led_lo[2] || !led_hi[2]) fail("LED3 must be steady on when frames arrive (even when the camera config is done)");
    release dut.S_ddr_ready_s; release dut.S_panel_ready_s; release dut.S_isp_alive; release dut.S_cam_cfg_done_s;
    #(500_000);

    // ---------- 6. SW1 按住 > 3 ms：整机复位（尾巴重新回零、背景音乐重新开始）----------
    lock_low_seen = 0;
    s0 = txn;
    key[0] = 1'b0;
    for (t = 0; t < 600; t = t + 1) begin #10_000; if (dut.S_pll_lock === 1'b0) lock_low_seen = 1; end   // 6 ms
    key[0] = 1'b1;
    #(2_000_000);
    if (!lock_low_seen) fail("hold SW1 did not reset the PLL");
    if (dut.S_pll_lock !== 1'b1) fail("PLL did not re-lock");
    if (txn - s0 !== 19) begin $display("FAIL tail did not re-home after the system reset (%0d bytes)", txn - s0); errors = errors + 1; end
    exn = 0; home_bytes; compare_tx("tail re-homing after reset", s0);
    t = 0; while (dut.S_bgm_state !== 2'd2 && t < 6000) begin #10_000; t = t + 1; end
    if (dut.S_bgm_state !== 2'd2) fail("background music did not restart by itself after the system reset");

    if (errors == 0) $display("PASS  tb_top");
    else             $display("FAIL  tb_top: %0d errors", errors);
    $finish;
end

initial begin #900_000_000; $display("FAIL  tb_top: timeout"); $finish; end

endmodule
