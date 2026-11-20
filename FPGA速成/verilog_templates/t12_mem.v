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

  // DW=每格数据位宽；AW=地址位宽；1 << AW 是把数字 1 左移 AW 位，即 2^AW 格。
  // 例 AW=3、DW=8：mem[0] 到 mem[7]，每格 8 位。
  reg [DW-1:0] mem [0:(1<<AW)-1];

  always @(posedge clk)
  begin
    if (we)
      mem[addr] <= din;
    dout <= mem[addr];
  end

endmodule
//输入数据？

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

  // wr_en+din 请求写，rd_en 请求取走队头；只有非空时 dout 才有效。
  // 满时即使同时读也不接受写；空时即使同时写也不接受读，均按沿前 full/empty 判断。
  wire do_wr = wr_en && !full;
  wire do_rd = rd_en && !empty;

  always @(posedge clk or negedge rst_n)
  begin
    if (!rst_n)
    begin
      wp    <= 0;
      rp    <= 0;
      count <= 0;
    end
    else
    begin
      if (do_wr)
        wp <= wp + 1'b1;
      if (do_rd)
        rp <= rp + 1'b1;
      case ({do_wr, do_rd})
        2'b10:
          count <= count + 1'b1;
        2'b01:
          count <= count - 1'b1;
        default:
          count <= count;       // 同时读写或都不做：个数不变
      endcase
    end
  end

  always @(posedge clk)
  begin
    if (do_wr)
      mem[wp] <= din;
  end

  assign dout  = mem[rp];
  assign full  = (count == (1 << AW));
  assign empty = (count == 0);

endmodule
