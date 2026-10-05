
module display_config_wrapper (
    input wire  I_clk,
    input wire  I_rst,
 
    input wire  I_config_start,
    output wire O_config_done,
 
    output wire O_lp_tx_p,
    output wire O_lp_tx_n
);

    wire[9:0]      S_rom_addr;   //synthesis keep
    wire[7:0]      S_rom_data;   //synthesis keep
    wire           S_fetch_trig;
    wire           S_long_packet_valid;   
    wire[7:0]      S_long_packet_data;    
    wire           S_short_packet_1_valid;
    wire[7:0]      S_short_packet_1_data; 
    wire           S_short_packet_2_valid;
    wire[7:0]      S_short_packet_2_data; 
    wire           S_delay_valid;         
    wire[7:0]      S_delay_data;          
    wire           S_end_valid;           

    wire           S_lp_tx_valid;   //synthesis keep
    wire           S_lp_tx_last;    //synthesis keep
    wire[7:0]      S_lp_tx_data;    //synthesis keep
    wire           S_lp_tx_ready;   //synthesis keep


     w8_d1024_rom u_w8_d1024_rom(
         .clka  ( I_clk      ),

         .doa   ( S_rom_data ),
         .addra ( S_rom_addr )
     );

//    soft_rom u_soft_rom(
//		.I_clk      ( I_clk      ),
//        .I_rom_addr ( S_rom_addr ),
//        .O_rom_data ( S_rom_data )
//    );


    instruction_fetch u_instruction_fetch(
        .I_clk                  ( I_clk                  ),
        .I_rst                  ( I_rst                  ),

        .I_config_start         ( I_config_start         ),
        .I_fetch_trig           ( S_fetch_trig           ),

        .O_rom_addr             ( S_rom_addr             ),
        .I_rom_data             ( S_rom_data             ),

        .O_long_packet_valid    ( S_long_packet_valid    ),
        .O_long_packet_data     ( S_long_packet_data     ),

        .O_short_packet_1_valid ( S_short_packet_1_valid ),
        .O_short_packet_1_data  ( S_short_packet_1_data  ),

        .O_short_packet_2_valid ( S_short_packet_2_valid ),
        .O_short_packet_2_data  ( S_short_packet_2_data  ),

        .O_delay_valid          ( S_delay_valid          ),
        .O_delay_data           ( S_delay_data           ),

        .O_end_valid            ( S_end_valid            )
    );



    instruction_execution u_instruction_execution(
        .I_clk                  ( I_clk                  ),
        .I_rst                  ( I_rst                  ),


        .I_long_packet_valid    ( S_long_packet_valid    ),
        .I_long_packet_data     ( S_long_packet_data     ),

        .I_short_packet_1_valid ( S_short_packet_1_valid ),
        .I_short_packet_1_data  ( S_short_packet_1_data  ),

        .I_short_packet_2_valid ( S_short_packet_2_valid ),
        .I_short_packet_2_data  ( S_short_packet_2_data  ),

        .I_delay_valid          ( S_delay_valid          ),
        .I_delay_data           ( S_delay_data           ),

        .I_end_valid            ( S_end_valid            ),


        .O_fetch_trig           ( S_fetch_trig           ),
        .O_config_done          ( O_config_done          ),


        .O_lp_tx_valid          ( S_lp_tx_valid          ),
        .O_lp_tx_last           ( S_lp_tx_last           ),
        .O_lp_tx_data           ( S_lp_tx_data           ),
        .I_lp_tx_ready          ( S_lp_tx_ready          )
    );


    lp_tx_wrapper u_lp_tx_wrapper(
        .I_clk         ( I_clk         ),
        .I_rst         ( I_rst         ),

        .I_lp_tx_valid ( S_lp_tx_valid ),
        .I_lp_tx_data  ( S_lp_tx_data  ),
        .I_lp_tx_last  ( S_lp_tx_last  ),
        .O_lp_tx_ready ( S_lp_tx_ready ),

        .O_lp_tx_p     ( O_lp_tx_p     ),
        .O_lp_tx_n     ( O_lp_tx_n     )
    );


    
endmodule