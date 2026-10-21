`timescale 1ns / 1ps
// =============================================================================
// mc_obs_lut.v  避障几何表：网格行 → 地面距离（厘米）、扇区 / 方向 → 地面上的水平角度（度）、车宽门限
// ★ 本文件由 tools/gen_obs_lut.pl 生成（镜头离地 174 mm、向下倾 15°、最远判断 150 cm、车宽 20 cm + 两边各 5 cm），不要手改。
//   方向 b（1~15）= 扇区 b−1 和 b 的分界线，b = 8 是正前方。O_thr：扇区 j 里的障碍距离 ≤ 这个数（厘米）就挡住方向 b（255 = 多远都挡）。
//   O_row_min = 第一个距离 ≤ 150 cm 的网格行（= 29）；再往上的行不判断障碍。
// =============================================================================
module mc_obs_lut (
    input  wire [6:0] I_row,            // 网格行 0~89
    output reg  [7:0] O_dist,           // 这一行看到的地面离镜头多远（厘米，255 = 很远 / 地平线以上）
    input  wire [3:0] I_sec,            // 扇区 0~15
    output reg  signed [6:0] O_sec_deg, // 扇区中心的水平角度（度，左负右正）
    input  wire [3:0] I_head,           // 方向 1~15
    output reg  signed [6:0] O_head_deg,// 它的水平角度
    input  wire [3:0] I_tb,             // 车宽门限：方向 b
    input  wire [3:0] I_tj,             //           扇区 j
    output reg  [7:0] O_thr,
    output wire [6:0] O_row_min
);

assign O_row_min = 7'd29;

always @(*) begin
    case (I_row)
        7'd0 : O_dist = 8'd255;
        7'd1 : O_dist = 8'd255;
        7'd2 : O_dist = 8'd255;
        7'd3 : O_dist = 8'd255;
        7'd4 : O_dist = 8'd255;
        7'd5 : O_dist = 8'd255;
        7'd6 : O_dist = 8'd255;
        7'd7 : O_dist = 8'd255;
        7'd8 : O_dist = 8'd255;
        7'd9 : O_dist = 8'd255;
        7'd10: O_dist = 8'd255;
        7'd11: O_dist = 8'd255;
        7'd12: O_dist = 8'd255;
        7'd13: O_dist = 8'd255;
        7'd14: O_dist = 8'd255;
        7'd15: O_dist = 8'd255;
        7'd16: O_dist = 8'd255;
        7'd17: O_dist = 8'd255;
        7'd18: O_dist = 8'd255;
        7'd19: O_dist = 8'd255;
        7'd20: O_dist = 8'd255;
        7'd21: O_dist = 8'd255;
        7'd22: O_dist = 8'd255;
        7'd23: O_dist = 8'd252;
        7'd24: O_dist = 8'd223;
        7'd25: O_dist = 8'd201;
        7'd26: O_dist = 8'd182;
        7'd27: O_dist = 8'd166;
        7'd28: O_dist = 8'd153;
        7'd29: O_dist = 8'd142;
        7'd30: O_dist = 8'd132;
        7'd31: O_dist = 8'd124;
        7'd32: O_dist = 8'd116;
        7'd33: O_dist = 8'd109;
        7'd34: O_dist = 8'd103;
        7'd35: O_dist = 8'd98;
        7'd36: O_dist = 8'd93;
        7'd37: O_dist = 8'd89;
        7'd38: O_dist = 8'd85;
        7'd39: O_dist = 8'd81;
        7'd40: O_dist = 8'd77;
        7'd41: O_dist = 8'd74;
        7'd42: O_dist = 8'd71;
        7'd43: O_dist = 8'd69;
        7'd44: O_dist = 8'd66;
        7'd45: O_dist = 8'd64;
        7'd46: O_dist = 8'd62;
        7'd47: O_dist = 8'd60;
        7'd48: O_dist = 8'd58;
        7'd49: O_dist = 8'd56;
        7'd50: O_dist = 8'd54;
        7'd51: O_dist = 8'd52;
        7'd52: O_dist = 8'd51;
        7'd53: O_dist = 8'd49;
        7'd54: O_dist = 8'd48;
        7'd55: O_dist = 8'd47;
        7'd56: O_dist = 8'd45;
        7'd57: O_dist = 8'd44;
        7'd58: O_dist = 8'd43;
        7'd59: O_dist = 8'd42;
        7'd60: O_dist = 8'd41;
        7'd61: O_dist = 8'd40;
        7'd62: O_dist = 8'd39;
        7'd63: O_dist = 8'd38;
        7'd64: O_dist = 8'd37;
        7'd65: O_dist = 8'd36;
        7'd66: O_dist = 8'd36;
        7'd67: O_dist = 8'd35;
        7'd68: O_dist = 8'd34;
        7'd69: O_dist = 8'd33;
        7'd70: O_dist = 8'd33;
        7'd71: O_dist = 8'd32;
        7'd72: O_dist = 8'd31;
        7'd73: O_dist = 8'd31;
        7'd74: O_dist = 8'd30;
        7'd75: O_dist = 8'd30;
        7'd76: O_dist = 8'd29;
        7'd77: O_dist = 8'd28;
        7'd78: O_dist = 8'd28;
        7'd79: O_dist = 8'd27;
        7'd80: O_dist = 8'd27;
        7'd81: O_dist = 8'd26;
        7'd82: O_dist = 8'd26;
        7'd83: O_dist = 8'd26;
        7'd84: O_dist = 8'd25;
        7'd85: O_dist = 8'd25;
        7'd86: O_dist = 8'd24;
        7'd87: O_dist = 8'd24;
        7'd88: O_dist = 8'd23;
        7'd89: O_dist = 8'd23;
        default: O_dist = 8'd255;
    endcase
end

always @(*) begin
    case (I_sec)
        4'd0 : O_sec_deg = -7'sd33;
        4'd1 : O_sec_deg = -7'sd30;
        4'd2 : O_sec_deg = -7'sd26;
        4'd3 : O_sec_deg = -7'sd22;
        4'd4 : O_sec_deg = -7'sd17;
        4'd5 : O_sec_deg = -7'sd12;
        4'd6 : O_sec_deg = -7'sd7;
        4'd7 : O_sec_deg = -7'sd3;
        4'd8 : O_sec_deg =  7'sd3;
        4'd9 : O_sec_deg =  7'sd7;
        4'd10: O_sec_deg =  7'sd12;
        4'd11: O_sec_deg =  7'sd17;
        4'd12: O_sec_deg =  7'sd22;
        4'd13: O_sec_deg =  7'sd26;
        4'd14: O_sec_deg =  7'sd30;
        4'd15: O_sec_deg =  7'sd33;
        default: O_sec_deg = 7'sd0;
    endcase
end

always @(*) begin
    case (I_head)
        4'd1 : O_head_deg = -7'sd32;
        4'd2 : O_head_deg = -7'sd28;
        4'd3 : O_head_deg = -7'sd24;
        4'd4 : O_head_deg = -7'sd19;
        4'd5 : O_head_deg = -7'sd15;
        4'd6 : O_head_deg = -7'sd10;
        4'd7 : O_head_deg = -7'sd5;
        4'd8 : O_head_deg =  7'sd0;
        4'd9 : O_head_deg =  7'sd5;
        4'd10: O_head_deg =  7'sd10;
        4'd11: O_head_deg =  7'sd15;
        4'd12: O_head_deg =  7'sd19;
        4'd13: O_head_deg =  7'sd24;
        4'd14: O_head_deg =  7'sd28;
        4'd15: O_head_deg =  7'sd32;
        default: O_head_deg = 7'sd0;
    endcase
end

always @(*) begin
    case ({I_tb, I_tj})
        8'h12: O_thr = 8'd226;
        8'h13: O_thr = 8'd109;
        8'h14: O_thr = 8'd70;
        8'h15: O_thr = 8'd51;
        8'h16: O_thr = 8'd40;
        8'h17: O_thr = 8'd33;
        8'h18: O_thr = 8'd28;
        8'h19: O_thr = 8'd25;
        8'h1A: O_thr = 8'd22;
        8'h1B: O_thr = 8'd20;
        8'h1C: O_thr = 8'd19;
        8'h1D: O_thr = 8'd18;
        8'h1E: O_thr = 8'd17;
        8'h1F: O_thr = 8'd16;
        8'h20: O_thr = 8'd226;
        8'h23: O_thr = 8'd211;
        8'h24: O_thr = 8'd102;
        8'h25: O_thr = 8'd66;
        8'h26: O_thr = 8'd49;
        8'h27: O_thr = 8'd38;
        8'h28: O_thr = 8'd32;
        8'h29: O_thr = 8'd27;
        8'h2A: O_thr = 8'd24;
        8'h2B: O_thr = 8'd22;
        8'h2C: O_thr = 8'd20;
        8'h2D: O_thr = 8'd19;
        8'h2E: O_thr = 8'd18;
        8'h2F: O_thr = 8'd17;
        8'h30: O_thr = 8'd109;
        8'h31: O_thr = 8'd211;
        8'h34: O_thr = 8'd197;
        8'h35: O_thr = 8'd96;
        8'h36: O_thr = 8'd63;
        8'h37: O_thr = 8'd46;
        8'h38: O_thr = 8'd37;
        8'h39: O_thr = 8'd31;
        8'h3A: O_thr = 8'd27;
        8'h3B: O_thr = 8'd24;
        8'h3C: O_thr = 8'd21;
        8'h3D: O_thr = 8'd20;
        8'h3E: O_thr = 8'd19;
        8'h3F: O_thr = 8'd18;
        8'h40: O_thr = 8'd70;
        8'h41: O_thr = 8'd102;
        8'h42: O_thr = 8'd197;
        8'h45: O_thr = 8'd187;
        8'h46: O_thr = 8'd91;
        8'h47: O_thr = 8'd60;
        8'h48: O_thr = 8'd45;
        8'h49: O_thr = 8'd36;
        8'h4A: O_thr = 8'd30;
        8'h4B: O_thr = 8'd26;
        8'h4C: O_thr = 8'd24;
        8'h4D: O_thr = 8'd21;
        8'h4E: O_thr = 8'd20;
        8'h4F: O_thr = 8'd19;
        8'h50: O_thr = 8'd51;
        8'h51: O_thr = 8'd66;
        8'h52: O_thr = 8'd96;
        8'h53: O_thr = 8'd187;
        8'h56: O_thr = 8'd179;
        8'h57: O_thr = 8'd88;
        8'h58: O_thr = 8'd58;
        8'h59: O_thr = 8'd44;
        8'h5A: O_thr = 8'd35;
        8'h5B: O_thr = 8'd30;
        8'h5C: O_thr = 8'd26;
        8'h5D: O_thr = 8'd24;
        8'h5E: O_thr = 8'd22;
        8'h5F: O_thr = 8'd20;
        8'h60: O_thr = 8'd40;
        8'h61: O_thr = 8'd49;
        8'h62: O_thr = 8'd63;
        8'h63: O_thr = 8'd91;
        8'h64: O_thr = 8'd179;
        8'h67: O_thr = 8'd174;
        8'h68: O_thr = 8'd86;
        8'h69: O_thr = 8'd58;
        8'h6A: O_thr = 8'd44;
        8'h6B: O_thr = 8'd35;
        8'h6C: O_thr = 8'd30;
        8'h6D: O_thr = 8'd27;
        8'h6E: O_thr = 8'd24;
        8'h6F: O_thr = 8'd22;
        8'h70: O_thr = 8'd33;
        8'h71: O_thr = 8'd38;
        8'h72: O_thr = 8'd46;
        8'h73: O_thr = 8'd60;
        8'h74: O_thr = 8'd88;
        8'h75: O_thr = 8'd174;
        8'h78: O_thr = 8'd171;
        8'h79: O_thr = 8'd86;
        8'h7A: O_thr = 8'd58;
        8'h7B: O_thr = 8'd44;
        8'h7C: O_thr = 8'd36;
        8'h7D: O_thr = 8'd31;
        8'h7E: O_thr = 8'd27;
        8'h7F: O_thr = 8'd25;
        8'h80: O_thr = 8'd28;
        8'h81: O_thr = 8'd32;
        8'h82: O_thr = 8'd37;
        8'h83: O_thr = 8'd45;
        8'h84: O_thr = 8'd58;
        8'h85: O_thr = 8'd86;
        8'h86: O_thr = 8'd171;
        8'h89: O_thr = 8'd171;
        8'h8A: O_thr = 8'd86;
        8'h8B: O_thr = 8'd58;
        8'h8C: O_thr = 8'd45;
        8'h8D: O_thr = 8'd37;
        8'h8E: O_thr = 8'd32;
        8'h8F: O_thr = 8'd28;
        8'h90: O_thr = 8'd25;
        8'h91: O_thr = 8'd27;
        8'h92: O_thr = 8'd31;
        8'h93: O_thr = 8'd36;
        8'h94: O_thr = 8'd44;
        8'h95: O_thr = 8'd58;
        8'h96: O_thr = 8'd86;
        8'h97: O_thr = 8'd171;
        8'h9A: O_thr = 8'd174;
        8'h9B: O_thr = 8'd88;
        8'h9C: O_thr = 8'd60;
        8'h9D: O_thr = 8'd46;
        8'h9E: O_thr = 8'd38;
        8'h9F: O_thr = 8'd33;
        8'hA0: O_thr = 8'd22;
        8'hA1: O_thr = 8'd24;
        8'hA2: O_thr = 8'd27;
        8'hA3: O_thr = 8'd30;
        8'hA4: O_thr = 8'd35;
        8'hA5: O_thr = 8'd44;
        8'hA6: O_thr = 8'd58;
        8'hA7: O_thr = 8'd86;
        8'hA8: O_thr = 8'd174;
        8'hAB: O_thr = 8'd179;
        8'hAC: O_thr = 8'd91;
        8'hAD: O_thr = 8'd63;
        8'hAE: O_thr = 8'd49;
        8'hAF: O_thr = 8'd40;
        8'hB0: O_thr = 8'd20;
        8'hB1: O_thr = 8'd22;
        8'hB2: O_thr = 8'd24;
        8'hB3: O_thr = 8'd26;
        8'hB4: O_thr = 8'd30;
        8'hB5: O_thr = 8'd35;
        8'hB6: O_thr = 8'd44;
        8'hB7: O_thr = 8'd58;
        8'hB8: O_thr = 8'd88;
        8'hB9: O_thr = 8'd179;
        8'hBC: O_thr = 8'd187;
        8'hBD: O_thr = 8'd96;
        8'hBE: O_thr = 8'd66;
        8'hBF: O_thr = 8'd51;
        8'hC0: O_thr = 8'd19;
        8'hC1: O_thr = 8'd20;
        8'hC2: O_thr = 8'd21;
        8'hC3: O_thr = 8'd24;
        8'hC4: O_thr = 8'd26;
        8'hC5: O_thr = 8'd30;
        8'hC6: O_thr = 8'd36;
        8'hC7: O_thr = 8'd45;
        8'hC8: O_thr = 8'd60;
        8'hC9: O_thr = 8'd91;
        8'hCA: O_thr = 8'd187;
        8'hCD: O_thr = 8'd197;
        8'hCE: O_thr = 8'd102;
        8'hCF: O_thr = 8'd70;
        8'hD0: O_thr = 8'd18;
        8'hD1: O_thr = 8'd19;
        8'hD2: O_thr = 8'd20;
        8'hD3: O_thr = 8'd21;
        8'hD4: O_thr = 8'd24;
        8'hD5: O_thr = 8'd27;
        8'hD6: O_thr = 8'd31;
        8'hD7: O_thr = 8'd37;
        8'hD8: O_thr = 8'd46;
        8'hD9: O_thr = 8'd63;
        8'hDA: O_thr = 8'd96;
        8'hDB: O_thr = 8'd197;
        8'hDE: O_thr = 8'd211;
        8'hDF: O_thr = 8'd109;
        8'hE0: O_thr = 8'd17;
        8'hE1: O_thr = 8'd18;
        8'hE2: O_thr = 8'd19;
        8'hE3: O_thr = 8'd20;
        8'hE4: O_thr = 8'd22;
        8'hE5: O_thr = 8'd24;
        8'hE6: O_thr = 8'd27;
        8'hE7: O_thr = 8'd32;
        8'hE8: O_thr = 8'd38;
        8'hE9: O_thr = 8'd49;
        8'hEA: O_thr = 8'd66;
        8'hEB: O_thr = 8'd102;
        8'hEC: O_thr = 8'd211;
        8'hEF: O_thr = 8'd226;
        8'hF0: O_thr = 8'd16;
        8'hF1: O_thr = 8'd17;
        8'hF2: O_thr = 8'd18;
        8'hF3: O_thr = 8'd19;
        8'hF4: O_thr = 8'd20;
        8'hF5: O_thr = 8'd22;
        8'hF6: O_thr = 8'd25;
        8'hF7: O_thr = 8'd28;
        8'hF8: O_thr = 8'd33;
        8'hF9: O_thr = 8'd40;
        8'hFA: O_thr = 8'd51;
        8'hFB: O_thr = 8'd70;
        8'hFC: O_thr = 8'd109;
        8'hFD: O_thr = 8'd226;
        default: O_thr = 8'd255;
    endcase
end

endmodule
