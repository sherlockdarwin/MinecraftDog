// 带安全锁定的电子密码锁（国赛测试2 题一）
// 状态：待机 IDLE → 开锁 UNLOCK（10 拍）→ 待机；待机 → 锁定 LOCKED（50 拍）→ 待机
// 缓冲区：最多 4 位，右对齐存放（先输入的在高位），输入 1-2-3-4 后 buf_r = 16'h1234
// 题目没写死、这里自己定的规则：
//   · 同一拍来多个按键：confirm > backspace > key_valid
//   · 开锁的 10 拍里也不接受按键
//   · 第二次输错：retry_cnt 从 1 变 0，同一拍进入 LOCKED
module serial_lock(
    input         clk,
    input         rst_n,
    input  [3 : 0] key_val,
    input         key_valid,
    input         backspace,
    input         confirm,
    output        unlock,
    output        alarm,
    output [1 : 0] retry_cnt,
    output [2 : 0] input_len
);

localparam S_IDLE = 2'd0, S_UNLOCK = 2'd1, S_LOCKED = 2'd2;
localparam T_UNLOCK = 6'd10, T_LOCKED = 6'd50;

reg [1:0]  state;
reg [5:0]  cnt;                    // 在 UNLOCK / LOCKED 里待了几拍
reg [15:0] buf_r;
reg [2:0]  len;
reg [1:0]  retry;

wire pass_ok = (len == 3'd4) && (buf_r == 16'h1234);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= S_IDLE;
        cnt   <= 6'd0;
        buf_r <= 16'h0000;
        len   <= 3'd0;
        retry <= 2'd2;
    end else begin
        case (state)
            S_IDLE: begin
                if (confirm) begin
                    buf_r <= 16'h0000;                 // 确认后一律清空
                    len   <= 3'd0;
                    cnt   <= 6'd0;
                    if (pass_ok) begin
                        state <= S_UNLOCK;
                        retry <= 2'd2;
                    end else if (retry == 2'd1) begin
                        state <= S_LOCKED;
                        retry <= 2'd0;
                    end else
                        retry <= retry - 2'd1;
                end else if (backspace) begin
                    if (len != 3'd0) begin
                        buf_r <= {4'h0, buf_r[15:4]};  // 删掉最后输入的一位
                        len   <= len - 3'd1;
                    end
                end else if (key_valid) begin
                    if (len != 3'd4) begin             // 满 4 位后忽略
                        buf_r <= {buf_r[11:0], key_val};
                        len   <= len + 3'd1;
                    end
                end
            end

            S_UNLOCK: begin
                if (cnt == T_UNLOCK - 1) begin
                    state <= S_IDLE;
                    cnt   <= 6'd0;
                end else
                    cnt <= cnt + 6'd1;
            end

            S_LOCKED: begin                            // 忽略所有按键
                if (cnt == T_LOCKED - 1) begin
                    state <= S_IDLE;
                    cnt   <= 6'd0;
                    retry <= 2'd2;                     // 解除锁定，次数恢复
                end else
                    cnt <= cnt + 6'd1;
            end

            default: state <= S_IDLE;
        endcase
    end
end

assign unlock    = (state == S_UNLOCK);
assign alarm     = (state == S_LOCKED);
assign retry_cnt = retry;
assign input_len = len;

endmodule
