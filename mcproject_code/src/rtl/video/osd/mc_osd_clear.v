`timescale 1ns / 1ps
// =============================================================================
// mc_osd_clear.v  文字层小部件：把文字框写成空格（清屏）
//   复位后自动把整个文字框（第 0 ~ ROWS-1 行）清一遍。字符 RAM 上电内容不确定（未写过的格子不是空格），所以需要它。
//   必须放在写总线链的最前面（优先级最高），这样它先写完，后面的字符串/数字才写进来，不会被它盖掉。
// =============================================================================
module mc_osd_clear #(
    parameter ROWS = 8,
    parameter COLS = 45
)(
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire [19:0] I_bus,           // 链头一般接 20'd0
    output wire [19:0] O_bus
);

localparam [3:0] LAST_ROW = ROWS - 1;
localparam [6:0] LAST_COL = COLS - 1;

reg [3:0]  S_row;
reg [6:0]  S_col;
reg        S_run;
reg        S_bus_we;
reg [18:0] S_bus_d;                     // 无复位：we=1 时才有意义

assign O_bus = {S_bus_we, S_bus_d};

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        S_row    <= 4'd0;
        S_col    <= 7'd0;
        S_run    <= 1'b1;
        S_bus_we <= 1'b0;
    end else begin
        if (I_bus[19]) begin
            S_bus_we <= 1'b1;
        end else if (S_run) begin
            S_bus_we <= 1'b1;
            if (S_col == LAST_COL) begin
                S_col <= 7'd0;
                if (S_row == LAST_ROW) S_run <= 1'b0;
                else                   S_row <= S_row + 4'd1;
            end else begin
                S_col <= S_col + 7'd1;
            end
        end else begin
            S_bus_we <= 1'b0;
        end
    end
end

always @(posedge I_clk) begin
    if (I_bus[19])  S_bus_d <= I_bus[18:0];
    else if (S_run) S_bus_d <= {S_row, S_col, 8'h20};
end

endmodule
