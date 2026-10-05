`timescale 1ns / 1ps
// =============================================================================
// mc_crop.v  取窗：从 RAW10 流里截取一个矩形窗口，输出 tvalid/tuser/tlast 流给 ISP
//
// 输入：raw10_unpacket 输出的 40bit = 4 个像素/拍，valid 间断（4 个有效 + 1 个空拍），
//       行与行之间有 ≥ 10 拍的空隙（本模块靠这个空隙判断"一行结束"，与厂商 image_correction 相同）。
// 坐标：组(Group) = 4 个像素；行/组都从 0 开始数；窗口取 [X0_GRP, X0_GRP+W_GRP) × [Y0, Y0+H)。
//
// ★ Bayer 相位：下游 demosaic 的 BAYER_MODE 是按"第 Y0=奇数行"为窗口第 0 行标定的
//   （厂商 IMX415 工程取第 1 行起，跳过传感器输出的第 0 行）。
//   所以 Y0 必须是奇数；X0_GRP 随意（1 组 = 4 像素，不改变相位）。
// =============================================================================
module mc_crop #(
    parameter X0_GRP = 141,     // 窗口起始组：141*4 = 像素 564
    parameter W_GRP  = 200,     // 窗口宽度(组)：200*4 = 800 像素
    parameter Y0     = 317,     // 窗口起始行（奇数）
    parameter H      = 448      // 窗口高度（行）
)(
    input  wire        I_clk,
    input  wire        I_rst_n,

    input  wire [39:0] I_raw_data,
    input  wire        I_raw_valid,
    input  wire        I_raw_frame_start,

    output wire [39:0] O_raw_tdata,
    output wire        O_raw_tvalid,
    output wire        O_raw_tuser,         // 窗口内第一个像素组（帧起始）
    output wire        O_raw_tlast          // 窗口内每行最后一个像素组（行结束）
);

localparam X1_GRP = X0_GRP + W_GRP - 1;
localparam Y1     = Y0 + H - 1;

reg [39:0] S_data_r;
reg        S_valid_d;
reg [7:0]  S_gap_cnt;       // 距离上一个 valid 过了多少拍（饱和计数）
reg [14:0] S_h_cnt;         // 当前行里已经过去的像素组个数
reg [14:0] S_v_cnt;         // 当前帧里已经过去的行数

wire S_line_end = (S_gap_cnt == 8'd10);

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        S_data_r  <= 40'd0;
        S_valid_d <= 1'b0;
    end else begin
        S_data_r  <= I_raw_data;
        S_valid_d <= I_raw_valid;
    end
end

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        S_gap_cnt <= 8'd0;
    else if (I_raw_valid)
        S_gap_cnt <= 8'd0;
    else if (S_gap_cnt != 8'hFF)
        S_gap_cnt <= S_gap_cnt + 8'd1;
end

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        S_v_cnt <= 15'd0;
    else if (I_raw_frame_start)
        S_v_cnt <= 15'd0;
    else if (S_line_end)
        S_v_cnt <= S_v_cnt + 15'd1;
end

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        S_h_cnt <= 15'd0;
    else if (I_raw_frame_start || S_line_end)
        S_h_cnt <= 15'd0;
    else if (S_valid_d)
        S_h_cnt <= S_h_cnt + 15'd1;
end

wire S_h_in = (S_h_cnt >= X0_GRP) && (S_h_cnt <= X1_GRP);
wire S_v_in = (S_v_cnt >= Y0)     && (S_v_cnt <= Y1);

assign O_raw_tvalid = S_h_in && S_v_in && S_valid_d;
assign O_raw_tdata  = O_raw_tvalid ? S_data_r : 40'd0;
assign O_raw_tuser  = (S_h_cnt == X0_GRP) && (S_v_cnt == Y0) && S_valid_d;
assign O_raw_tlast  = S_v_in && (S_h_cnt == X1_GRP) && S_valid_d;

endmodule
