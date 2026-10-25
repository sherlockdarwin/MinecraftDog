`timescale 1ns / 1ps
// 仿真用 SD 卡行为模型（SPI 模式，只做仿真需要的命令）：
//   CMD0 进空闲；CMD8（V2 卡回显 0x1AA，V1 卡回"非法命令"）；CMD55/ACMD41（前 ACMD41_TRIES 次回"还在初始化"）；
//   CMD58 读 OCR（SDHC 卡 CCS=1）；CMD16；CMD17 读单块：R1 → 若干个 0xFF（读延迟）→ 令牌 0xFE → 512 字节 → 2 字节 CRC。
//   卡内容从 IMAGE_FILE（$readmemh，每行一个字节）装进来；SDHC=1 按块号寻址，SDHC=0 按字节地址寻址。
//   CS 拉高时 MISO 回到高（板上有上拉），并放弃没做完的命令；CS 低期间收到的 0xFF 不当作命令。
//   SPI 模式 0：SCK 上升沿采样 MOSI，下降沿换 MISO。
module sd_card_model #(
    parameter IMAGE_FILE   = "sd_image.hex",
    parameter SDHC         = 1,
    parameter V2           = 1,
    parameter ACMD41_TRIES = 3,
    parameter READ_DELAY   = 4,         // CMD17 的 R1 之后、令牌之前的 0xFF 个数
    parameter MAX_BYTES    = 2097152,
    parameter ERR_READ_N   = 0          // 非 0：第 ERR_READ_N 次 CMD17 回错误（R1 = 非法命令），测读卡错误的各个出口；只错这一次
)(
    input  wire cs_n,
    input  wire sck,
    input  wire mosi,
    output wire miso
);

reg [7:0] mem [0:MAX_BYTES-1];
initial begin : load
    integer i;
    for (i = 0; i < MAX_BYTES; i = i + 1) mem[i] = 8'h00;
    $readmemh(IMAGE_FILE, mem);
end

// 发送队列
reg [7:0] q [0:1023];
integer q_head = 0, q_tail = 0;
task push; input [7:0] b; begin q[q_tail % 1024] = b; q_tail = q_tail + 1; end endtask

reg        idle_state = 1'b0;          // 卡处于空闲（等待初始化）
reg        got_cmd0 = 1'b0;
reg        app_cmd = 1'b0;
integer    acmd41_cnt = 0;
reg        initialized = 1'b0;

// 命令接收
integer    nbyte = 0;                   // 命令内第几个字节（0 = 还没开始）
reg [5:0]  c_idx;
reg [31:0] c_arg;
integer    bitcnt = 0;
reg [7:0]  rx_sh = 8'hFF;
reg [7:0]  tx_sh = 8'hFF;
reg [7:0]  next_tx = 8'hFF;
reg        byte_done = 1'b0;
reg        miso_r = 1'b1;
assign miso = cs_n ? 1'b1 : miso_r;

integer    n_cmd17 = 0;                 // 统计
integer    n_cmd = 0;
reg [31:0] last_lba = 0;
integer    k;
integer    base;

task exec_cmd;
    input [5:0]  idx;
    input [31:0] arg;
    reg [7:0] r1;
    begin
        n_cmd = n_cmd + 1;
        push(8'hFF);                                           // 一个字节的应答延迟
        if (app_cmd && idx == 6'd41) begin
            app_cmd = 1'b0;
            acmd41_cnt = acmd41_cnt + 1;
            if (acmd41_cnt > ACMD41_TRIES) begin idle_state = 1'b0; initialized = 1'b1; end
            push(idle_state ? 8'h01 : 8'h00);
        end else begin
            app_cmd = 1'b0;
            case (idx)
                6'd0: begin idle_state = 1'b1; initialized = 1'b0; acmd41_cnt = 0; push(8'h01); end
                6'd8: begin
                    if (V2) begin push(8'h01); push(8'h00); push(8'h00); push(8'h01); push(8'hAA); end
                    else    push(8'h05);                       // 非法命令
                end
                6'd55: begin app_cmd = 1'b1; push(idle_state ? 8'h01 : 8'h00); end
                6'd58: begin
                    push(initialized ? 8'h00 : 8'h01);
                    push((initialized ? 8'h80 : 8'h00) | ((initialized && SDHC) ? 8'h40 : 8'h00));
                    push(8'hFF); push(8'h80); push(8'h00);
                end
                6'd16: push(8'h00);
                6'd17: begin
                    if (!initialized) push(8'h04);
                    else begin
                        n_cmd17 = n_cmd17 + 1;
                        last_lba = SDHC ? arg : (arg >> 9);
                        if (ERR_READ_N != 0 && n_cmd17 == ERR_READ_N) push(8'h04);     // 这一次读失败
                        else begin
                            push(8'h00);
                            for (k = 0; k < READ_DELAY; k = k + 1) push(8'hFF);
                            push(8'hFE);
                            base = (SDHC ? arg : (arg >> 9)) * 512;
                            for (k = 0; k < 512; k = k + 1) push(mem[base + k]);
                            push(8'hFF); push(8'hFF);                // CRC
                        end
                    end
                end
                default: push(8'h04);
            endcase
        end
    end
endtask

always @(posedge cs_n) begin                                    // CS 拉高：放弃未完成的东西
    nbyte = 0; bitcnt = 0; q_head = 0; q_tail = 0; tx_sh = 8'hFF; byte_done = 0; next_tx = 8'hFF;
end

always @(posedge sck) if (!cs_n) begin
    rx_sh = {rx_sh[6:0], mosi};
    bitcnt = bitcnt + 1;
    if (bitcnt == 8) begin
        bitcnt = 0;
        // 一个字节收完：处理命令字节
        if (nbyte == 0) begin
            if (rx_sh[7:6] == 2'b01) begin c_idx = rx_sh[5:0]; nbyte = 1; c_arg = 0; end
        end else if (nbyte >= 1 && nbyte <= 4) begin
            c_arg = {c_arg[23:0], rx_sh}; nbyte = nbyte + 1;
        end else begin                                           // 第 6 个字节（CRC）
            nbyte = 0;
            exec_cmd(c_idx, c_arg);
        end
        // 下一个要发的字节
        if (q_head != q_tail) begin next_tx = q[q_head % 1024]; q_head = q_head + 1; end
        else next_tx = 8'hFF;
        byte_done = 1;
    end
end

always @(negedge sck) if (!cs_n) begin
    if (byte_done) begin tx_sh = next_tx; byte_done = 0; end
    else tx_sh = {tx_sh[6:0], 1'b1};
    miso_r <= tx_sh[7];
end

endmodule
