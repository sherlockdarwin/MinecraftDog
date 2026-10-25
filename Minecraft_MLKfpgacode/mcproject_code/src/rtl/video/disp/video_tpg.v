`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: anlgoic
// Author: 	xg 
//////////////////////////////////////////////////////////////////////////////////


/*
// 0x01 : red
// 0x02 : green
// 0x03 : blue
// 0x04 : white
// 0x05 : gray red
// 0x06 : gray green
// 0x07 : gray blue
// 0x08 : gray white
// 0x09 : mosaic
// 0x0A : diagonal gray scan
// 0x0B : grid scan
*/

//1920 * 1080 @60Hz ,148.5M
//1280 * 1024 @60Hz ,108M
//1280 * 720  @60Hz ,74.25M
//1680 * 1050  @60Hz ,119M
//1024*768,65m
//800600,40m

module video_tpg(   
		input   PCLK,
        input   Reset,
		input   		DEN_TPG,
		input [3:0] 	TPG_mode,
		output  		PDEN,
        output  		HSYNC,      //VESA��ͬ���ź�
        output  		VSYNC,      //VESA��ͬ���ź�
        output  [23:0]  PDATA
	);


reg  den_tpg_en_reg_one=1'd0;
reg [11:0] hsync_cnt=12'd1; //vesa��ɨ��������
reg [10:0] vsync_cnt=11'd1; //vesa��ɨ��������
wire h_end;
wire v_end;

parameter  HTOTAL = 1344; // 800;//2200; //2720; //1688;  //1344;
parameter  VTOTAL = 635; //1525;//1125; //1646; //1066;  //806;

parameter  HSA    = 24; //96;//44; //32; //112;  //136;
parameter  HBP    = 136;  //40; //80;  //248;  //160;
parameter  HFP    = 160;///8;//88; //48;  //48;  //24;

parameter  VSA    = 2; //2;//5; //6;  //3;  //6;
parameter  VBP    = 21; //25;//36; //37;  //38;  //29;
parameter  VFP    = 12; //2;//4; //3;  //1;  //3;

localparam  DEN_HSYNC_back_porch  = HSA + HBP;
localparam  DEN_HSYNC_front_porch = HTOTAL-HFP;
localparam  DEN_VSYNC_back_porch  = VSA + VBP;
localparam  DEN_VSYNC_front_porch = VTOTAL-VFP;
 

reg [3:0] tpg_mode_reg_one=4'd0; 
always @(posedge PCLK)
   begin
	      tpg_mode_reg_one <= TPG_mode;
			den_tpg_en_reg_one <= DEN_TPG;
	end
 
	
// ����.... HTOTAL
always @(posedge PCLK)
   begin
	    if (den_tpg_en_reg_one)
              if(h_end)
                   hsync_cnt <= 12'd1;
              else
                   hsync_cnt <= hsync_cnt + 1;
		 else
		        hsync_cnt <= 12'd1;
   end
assign h_end = (hsync_cnt == HTOTAL);  //HTOTAL

// ����.... VTOTAL
always @(posedge PCLK)
   begin
	     if (Reset)
		       vsync_cnt <= 10'd1;
        else if(h_end)
             begin
                   if(v_end)
                         vsync_cnt <= 10'd1;
                   else
                         vsync_cnt <= vsync_cnt + 1;
              end
   end	
assign v_end = (vsync_cnt == VTOTAL);  //VTOTAL

wire den_tmp;
reg  den_reg_one=1'd0;
reg  den_reg_two=1'd0;
reg  den_reg_three=1'd0;
wire  hsync_tmp;
wire  vsync_tmp;

//ʹ���ź�
//DEN--HSYNC :  (HSA + HBP + H_Left_Border) <= DE <= (HTOTAL - H_Rignt_Border + HFP)
//DEN--VSYNC :  (VSA + VBP + V_Top_Border)  <= DE <= (VTOTAL-V_Bottom_Border-VFP)
assign den_tmp = ((hsync_cnt > DEN_HSYNC_back_porch) && (hsync_cnt <= DEN_HSYNC_front_porch))&& ((vsync_cnt > DEN_VSYNC_back_porch) && (vsync_cnt <= DEN_VSYNC_front_porch));

//pipe
always @(posedge PCLK)
   begin
	    den_reg_one <= den_tmp;
		 den_reg_two <= den_reg_one;
		 den_reg_three <= den_reg_two;
	end
assign PDEN = Reset ? 1'b0 : den_reg_three;
 
//HSYNC=HSA + HYSNC Enablbe time
//VSYNC=VSA + VYSNC Enablbe time
assign hsync_tmp = (hsync_cnt > HSA);//ˮƽͬ��  // > HSA
assign vsync_tmp = (vsync_cnt > VSA);//��ֱͬ��   // > VSA

reg hsync_reg_one=1'd0;
reg vsync_reg_one=1'd0;
reg vsync_reg_two=1'd0;
//pipe
always @(posedge PCLK)
   begin
         hsync_reg_one <= 	hsync_tmp;
			vsync_reg_one <= 	vsync_tmp;
	end
assign HSYNC = Reset ? 1'b0 : hsync_reg_one;
assign VSYNC = Reset ? 1'b0 : vsync_reg_one;


wire[10:0] x_pos;
wire[10:0] y_pos;
assign x_pos = hsync_cnt - DEN_HSYNC_back_porch ;  //ˮƽλ��  //DEN_HSYNC_back_porch 
assign y_pos = vsync_cnt - DEN_VSYNC_back_porch-1 ;   //��ֱλ��  //DEN_VSYNC_back_porch 

reg  [10:0] x_pos_reg_one_a=11'd0;
reg  [4:0] x_pos_reg_one_b=5'd0;
reg  [7:0] x_pos_reg_two=8'd0;
reg  [7:0] x_pos_reg_three=8'd0;
reg  [10:0] y_pos_reg_one_a=11'd0;
reg  [4:0] y_pos_reg_one_b=11'd0;
//pipe
always @(posedge PCLK)
    begin
         x_pos_reg_one_a <= x_pos;
			x_pos_reg_one_b <= x_pos[4:0];
			x_pos_reg_two <= x_pos_reg_one_a[7:0];
			x_pos_reg_three <= x_pos_reg_two;
			y_pos_reg_one_a <= y_pos;
			y_pos_reg_one_b <= y_pos[4:0];
	 end

reg vsync_begin_flag=1'd0;
//pipe
always @(posedge PCLK)
    begin	
         vsync_reg_two <= vsync_reg_one;
			vsync_begin_flag <= vsync_reg_one & (~vsync_reg_two);
	 end

reg [9:0] frame_cnt=10'd0;
//frame cnt
always @(posedge PCLK)
    begin	
	       if (vsync_begin_flag)
			       frame_cnt <= frame_cnt+1;
	 end

reg [23:0] pixel_value=24'd0;
reg [7:0]  mosaic=8'd0;
reg [7:0]  mosaic_reg_one=8'd0;
reg [7:0]  diagonal_gray_scan=8'd0;
reg [7:0]  diagonal_gray_scan_reg_one=8'd0;
reg [7:0]  grid_scan=8'd0;
reg [7:0]  grid_scan_reg_one=8'd0;

	
//mosaic
always @(posedge PCLK)
    begin
          if ( ((x_pos_reg_one_b[4]) && (y_pos_reg_one_a[4])) ||  ((~x_pos_reg_one_b[4]) && (~y_pos_reg_one_a[4]))	) 
				     mosaic <= 8'd255;
			 else
			        mosaic <= 8'd0;
	 end	
	 
//////diagonal gray scan	 
//diagonal gran scan vlaue 
always @(posedge PCLK)
    begin
           if (x_pos_reg_one_b[3:0]==	(frame_cnt[9:6]-y_pos_reg_one_b[3:0]))
         		   diagonal_gray_scan <=8'd255; 
           else
                  diagonal_gray_scan <=8'd0;
    end	
	 
//grid scan
always @(posedge PCLK)
    begin
	      if  ( (x_pos_reg_one_b[3:0]==frame_cnt[9:6]) || (y_pos_reg_one_a[3:0]==frame_cnt[9:6]) ) 
                grid_scan <= 8'd255;
         else
                grid_scan <= 8'd0;
    end					 
	 
//pipe
always @(posedge PCLK)
    begin
	       mosaic_reg_one <= mosaic;
			 diagonal_gray_scan_reg_one <= diagonal_gray_scan;
			 grid_scan_reg_one <= grid_scan;
    end	 

wire [10:0] debug_data;
assign debug_data=x_pos_reg_three+y_pos_reg_one_b;

always @*
    begin
	      case (1)
	         tpg_mode_reg_one==4'd1:   pixel_value ={16'd0,8'd255};
				tpg_mode_reg_one== 4'd2:   pixel_value ={8'd0,8'd255,8'd0};
				tpg_mode_reg_one== 4'd3:   pixel_value ={8'd255,16'd0};
				tpg_mode_reg_one== 4'd4:   pixel_value ={24'hFFFFFF};
				tpg_mode_reg_one== 4'd5:   pixel_value ={16'd0,x_pos_reg_three[7:0]};
				tpg_mode_reg_one== 4'd6:   pixel_value ={8'd0,x_pos_reg_three[7:0],8'd0};
				tpg_mode_reg_one== 4'd7:   pixel_value ={x_pos_reg_three[7:0],16'd0};
				tpg_mode_reg_one== 4'd8:   pixel_value ={x_pos_reg_three[7:0],x_pos_reg_three[7:0],x_pos_reg_three[7:0]};
				tpg_mode_reg_one== 4'd9:   pixel_value ={mosaic_reg_one,mosaic_reg_one,mosaic_reg_one};
				tpg_mode_reg_one== 4'd10:  pixel_value ={diagonal_gray_scan_reg_one,diagonal_gray_scan_reg_one,diagonal_gray_scan_reg_one};
				tpg_mode_reg_one== 4'd11:  pixel_value ={grid_scan_reg_one,grid_scan_reg_one,grid_scan_reg_one};
				tpg_mode_reg_one>4'd11 && tpg_mode_reg_one<4'd15:  pixel_value ={debug_data[7:0],debug_data[7:0],debug_data[7:0]};
				default: pixel_value = 24'd0;
			endcase
	end	 
	 
reg [23:0] vesa_pixel=8'd0;
always @(posedge PCLK)
    begin
          if( den_reg_two)
               vesa_pixel <= {pixel_value[7:0],pixel_value[15:8],pixel_value[23:16]};
			 else
               vesa_pixel <=  24'd0;
     end


assign PDATA = vesa_pixel;

//assign PDATA = {8'h00,8'hFF,8'h00};


endmodule 