// =============================================================================
// t12 存储器
//   ram_sp     单口 RAM：同步写、同步读（读数据晚一拍；同一拍写同一地址，读到的是写之前的旧值）
//   fifo_sync  同步 FIFO：满了不写、空了不读；dout 一直是队头的数据，rd_en 那一拍把它取走
// 数组写法：reg [位宽-1:0] mem [0:深度-1];  mem[addr] <= din;  只能一次读写一个元素
// =============================================================================

module ram_sp #(
    parameter AW = 4,              // 地址位宽，深度 = 2^AW
    parameter DW = 8
)(
    input               clk,
    input               we,
    input      [AW-1:0] addr,
    input      [DW-1:0] din,
    output reg [DW-1:0] dout
);

reg [DW-1:0] mem [0:(1<<AW)-1];

always @(posedge clk) begin
    if (we) mem[addr] <= din;
    dout <= mem[addr];
end

endmodule


module fifo_sync #(
    parameter AW = 3,              // 深度 = 2^AW
    parameter DW = 8
)(
    input           clk,
    input           rst_n,
    input           wr_en,
    input  [DW-1:0] din,
    input           rd_en,
    output [DW-1:0] dout,
    output          full,
    output          empty,
    output reg [AW:0] count        // 里面有几个（多 1 位才能表示"满"）
);

reg [DW-1:0] mem [0:(1<<AW)-1];
reg [AW-1:0] wp, rp;               // 写指针、读指针，走到头自动回 0

wire do_wr = wr_en && !full;
wire do_rd = rd_en && !empty;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        wp    <= 0;
        rp    <= 0;
        count <= 0;
    end else begin
        if (do_wr) wp <= wp + 1'b1;
        if (do_rd) rp <= rp + 1'b1;
        case ({do_wr, do_rd})
            2'b10:   count <= count + 1'b1;
            2'b01:   count <= count - 1'b1;
            default: count <= count;       // 同时读写或都不做：个数不变
        endcase
    end
end

always @(posedge clk) begin
    if (do_wr) mem[wp] <= din;
end

assign dout  = mem[rp];
assign full  = (count == (1 << AW));
assign empty = (count == 0);

endmodule
