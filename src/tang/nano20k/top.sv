/*
    top.sv - Minimig on tang nano 20k toplevel
*/ 

/* we need two copies in case of 256k kickroms
     openFPGALoader --external-flash -o 0x400000 kick13.rom
     openFPGALoader --external-flash -o 0x440000 kick13.rom
   or a single copy of e.g. a 512k diag rom
     openFPGALoader --external-flash -o 0x400000 DiagROM
   or place a copy in the alternate rom slot (not supported yet)
     openFPGALoader --external-flash -o 0x480000 DiagROM   
*/
 
module top(
  input			clk,

  input			reset, // button S2
  input			user,  // button S1

  output [5:0]	leds_n,
  output		ws2812,

  // spi flash interface
  output		mspi_cs,
  output		mspi_clk,
  inout			mspi_di,
  inout			mspi_hold,
  inout			mspi_wp,
  inout			mspi_do,

  // "Magic" port names that the gowin compiler connects to the on-chip SDRAM
  output		O_sdram_clk,
  output		O_sdram_cke,
  output		O_sdram_cs_n,  // chip select
  output		O_sdram_cas_n, // columns address select
  output		O_sdram_ras_n, // row address select
  output		O_sdram_wen_n, // write enable
  inout [31:0]	IO_sdram_dq, // 32 bit bidirectional data bus
  output [10:0]	O_sdram_addr, // 11 bit multiplexed address bus
  output [1:0]	O_sdram_ba, // two banks
  output [3:0]	O_sdram_dqm, // 32/4

  // generic IO, used for mouse/joystick/...
  input [7:0]	io,

  // interface to external BL616/M0S
  inout [5:0]	m0s,

  // MIDI/UART
  input			midi_in,
  output		midi_out,
		   
  // SD card slot
  output		sd_clk,
  inout			sd_cmd, // MOSI
  inout [3:0]	sd_dat, // 0: MISO
	   
  // SPI connection to ob-board BL616. By default an external
  // connection is used with a M0S Dock
  input			spi_sclk, // in... 
  input			spi_csn, // in (io?)
  output		spi_dir, // out
  input			spi_dat, // in (io?)

  // hdmi/tdms
  output		tmds_clk_n,
  output		tmds_clk_p,
  output [2:0]	tmds_d_n,
  output [2:0]	tmds_d_p
);

wire [5:0]	leds;
   
// physcial dsub9 joystick  
wire [5:0] db9_joy = { !io[5], !io[0], !io[2], !io[1], !io[4], !io[3] };   
   
assign leds[5:4] = 2'b00;
assign leds[3] = |sd_rd;
assign leds_n = ~leds;  

// ============================== clock generation ===========================
   
// HDMI clock:  141.8758 MHz
// Pixel clock: 28.37516 MHz (HDMI/5)
// SDRAM clock: 70.9379 MHz (HDMI/2)
// Amiga clock: 7.09379 (Pixel/4)
   
`define PIXEL_CLOCK 28375160

wire clk_pixel_x5;   
wire pll_lock;   
pll_142m pll_hdmi (
    .clkout(clk_pixel_x5),
    .lock(pll_lock),
    .clkin(clk)
);

reg clk_71m;
always @(posedge clk_pixel_x5)
  if(!pll_lock) clk_71m <= 1'b0;
  else          clk_71m <= !clk_71m;

wire clk_pixel;
Gowin_CLKDIV clk_div_5 (
    .hclkin(clk_pixel_x5), // input hclkin
    .resetn(pll_lock),     // input resetn
    .clkout(clk_pixel)     // output clkout
);

wire	clk_28m = clk_pixel;

// generate 7 Mhz from 28Mhz
//reg [1:0] clk_cnt;
//always @(posedge clk_28m)
//  clk_cnt <= clk_cnt + 2'd1; 
//wire	  clk_7m = clk_cnt[1];

wire	clk7_en;   
wire	clk7n_en;   

// control signals generated by the user via the OSD
wire 	   osd_reset;   
wire [1:0] osd_chipmem;         // 0=512k, 1=1M, 2=1.5M, 3=2M
wire [1:0] osd_slowmem;         // 0=None, 1=512k, 2=1M, 3=1.5M
wire [1:0] osd_floppy_drives;
wire       osd_floppy_turbo;
wire [1:0] osd_chipset;         // 0=OCS-A500, 1=OCS-A1000, 2=ECS
wire       osd_video_mode;      // PAL (0=PAL, 1=NTSC)
wire [1:0] osd_video_filter;
wire [1:0] osd_video_scanlines;
   
// generate a reset for some time after rom has been initialized
reg [15:0] reset_cnt;
always @(negedge clk_28m) begin
    if(!pll_lock || !rom_done || reset || osd_reset )
        reset_cnt <= 16'hffff;
    else if(reset_cnt != 0)
        reset_cnt = reset_cnt - 16'd1;
end

wire cpu_reset = |reset_cnt;
wire sdram_ready;

// -------------------------- M0S MCU interface -----------------------

// connect to ws2812 led
wire [23:0] ws2812_color;
ws2812 ws2812_inst (
    .clk(clk_28m),
    .color(ws2812_color),
    .data(ws2812)
);

// interface to M0S MCU
wire       mcu_sys_strobe;        // mcu message byte valid for sysctrl
wire       mcu_hid_strobe;        // -"- hid
wire       mcu_osd_strobe;        // -"- osd
wire       mcu_sdc_strobe;        // -"- sdc
wire       mcu_start;             // first byte of MCU message

wire [7:0] mcu_data_out;  

wire [7:0] sys_data_out;  
wire [7:0] hid_data_out;  
wire [7:0] osd_data_out = 8'h55;  // OSD actually has no data output
wire [7:0] sdc_data_out;

mcu_spi mcu (
	 .clk(clk_28m),
	 .reset(!pll_lock),

	 // SPI interface to BL616
     .spi_io_ss(m0s[2]),
     .spi_io_clk(m0s[3]),
     .spi_io_din(m0s[1]),
     .spi_io_dout(m0s[0]),

	 // byte wide data in/out to the submodules
     .mcu_sys_strobe(mcu_sys_strobe),
     .mcu_hid_strobe(mcu_hid_strobe),
     .mcu_osd_strobe(mcu_osd_strobe),
     .mcu_sdc_strobe(mcu_sdc_strobe),
     .mcu_start(mcu_start),
     .mcu_dout(mcu_data_out),
     .mcu_sys_din(sys_data_out),
     .mcu_hid_din(hid_data_out),
     .mcu_osd_din(osd_data_out),
     .mcu_sdc_din(sdc_data_out)
);

// decode SPI/MCU data received for human input devices (HID) and
// convert into Amiga compatible mouse and keyboard signals
wire [7:0] int_ack;
wire hid_int;
wire hid_iack = int_ack[1];
wire sdc_iack = int_ack[3];
wire sdc_int;
wire [7:0] hid_joy0;
wire [7:0] hid_joy1;
   
// signals to wire the floppy controller to the sd card
wire [3:0]  sd_rd;
wire [3:0]  sd_wr = 4'b0000;
wire [7:0]  sd_rd_data;
wire [7:0]  sd_wr_data = 8'h00;
wire [31:0] sd_sector;  
wire [8:0]  sd_byte_index;
wire        sd_rd_byte_strobe;
wire        sd_busy, sd_done;
wire [31:0] sd_img_size;
wire [3:0]  sd_img_mounted;
reg         sd_ready;
   
sd_card #(
    .CLK_DIV(3'd1)                   // for 28 Mhz clock
) sd_card (
    .rstn(pll_lock),                 // rstn active-low, 1:working, 0:reset
    .clk(clk_28m),                   // clock
  
    // SD card signals
    .sdclk(sd_clk),
    .sdcmd(sd_cmd),
    .sddat(sd_dat),

    // mcu interface
    .data_strobe(mcu_sdc_strobe),
    .data_start(mcu_start),
    .data_in(mcu_data_out),
    .data_out(sdc_data_out),

    // output file/image information. Image size is e.g. used by fdc to 
    // translate between sector/track/side and lba sector
    .image_mounted(sd_img_mounted),
    .image_size(sd_img_size),           // length of image file

    // interrupt to signal communication request
    .irq(sdc_int),
    .iack(sdc_iack),

    // user read sector command interface (sync with clk32)
    .rstart(sd_rd), 
    .wstart(sd_wr), 
    .rsector(sd_sector),
    .rbusy(sd_busy),
    .rdone(sd_done),

    // sector data output interface (sync with clk32)
    .inbyte(sd_wr_data),
    .outen(sd_rd_byte_strobe), // when outen=1, a byte of sector content is read out from outbyte
    .outaddr(sd_byte_index),   // outaddr from 0 to 511, because the sector size is 512
    .outbyte(sd_rd_data)       // a byte of sector content
);

// keyboard and mouse interface to Minimig
wire [2:0] mouse_buttons; // mouse buttons
wire	   kbd_mouse_level;  
wire [1:0] kbd_mouse_type;  
wire [7:0] kbd_mouse_data;  

hid hid (
        .clk(clk_28m),
        .reset(!pll_lock),

         // interface to receive user data from MCU (mouse, kbd, ...)
        .data_in_strobe(mcu_hid_strobe),
        .data_in_start(mcu_start),
        .data_in(mcu_data_out),
        .data_out(hid_data_out),

        // input local db9 port events to be sent to MCU. Changes also trigger
        // an interrupt, so the MCU doesn't have to poll for joystick events
        .db9_port( db9_joy ),
        .irq( hid_int ),
        .iack( hid_iack ),

		 // keyboard & mouse				 
		 .mouse_buttons(mouse_buttons), // mouse buttons
		 .kbd_mouse_level(kbd_mouse_level),  
		 .kbd_mouse_type(kbd_mouse_type),  
		 .kbd_mouse_data(kbd_mouse_data),
		 
        .joystick0(hid_joy0),
        .joystick1(hid_joy1)
         );   

sysctrl sysctrl (
        .clk(clk_28m),
        .reset(!pll_lock),

         // interface to send and receive generic system control
        .data_in_strobe(mcu_sys_strobe),
        .data_in_start(mcu_start),
        .data_in(mcu_data_out),
        .data_out(sys_data_out),

        // values controlled by the OSD
		.system_reset(osd_reset),
		.system_floppy_drives(osd_floppy_drives),
		.system_floppy_turbo(osd_floppy_turbo),
	    .system_chipset(osd_chipset),
		.system_video_mode(osd_video_mode),
		.system_video_filter(osd_video_filter),
		.system_video_scanlines(osd_video_scanlines),
		.system_chipmem(osd_chipmem),
		.system_slowmem(osd_slowmem),
				 
        .int_out_n(m0s[4]),
        .int_in( { 4'b0000, sdc_int, 1'b0, hid_int, 1'b0 }),
        .int_ack( int_ack ),

        .buttons( {reset, user} ),
        .leds(),
        .color(ws2812_color)
);
   
// digital 12 bit video
wire hs_n, vs_n;
wire [3:0] red;
wire [3:0] green;
wire [3:0] blue;
   
wire [5:0] video_red;
wire [5:0] video_green;
wire [5:0] video_blue;   

osd_u8g2 osd_u8g2 (
        .clk(clk_28m),
        .reset(!pll_lock),

        .data_in_strobe(mcu_osd_strobe),
        .data_in_start(mcu_start),
        .data_in(mcu_data_out),

        .hs(hs_n),
        .vs(vs_n),

        .r_in({red,   2'b00}),
        .g_in({green, 2'b00}),
        .b_in({blue,  2'b00}),

        .r_out(video_red),
        .g_out(video_green),
        .b_out(video_blue)
);   

/* ---------------------- Minimig chipset ----------------------- */

// two 15 bit audio channels
wire [14:0] audio_left;
wire [14:0] audio_right;   

// map first HID/USB joystick into second amiga joystick port
// wire in db9 joystick
wire [7:0] joystick = { 
	  (hid_joy0[7] | hid_joy1[7]), 
	  (hid_joy0[6] | hid_joy1[6]), 
	  (hid_joy0[5] | hid_joy1[5] | db9_joy[5]), 
	  (hid_joy0[4] | hid_joy1[4] | db9_joy[4]),
	  (hid_joy0[3] | hid_joy1[3] | db9_joy[3]), 
	  (hid_joy0[2] | hid_joy1[2] | db9_joy[2]),
	  (hid_joy0[1] | hid_joy1[1] | db9_joy[1]),
	  (hid_joy0[0] | hid_joy1[0] | db9_joy[0]) };   
   
wire [23:1] cpu_a;
wire cpu_as_n, cpu_lds_n, cpu_uds_n;
wire cpu_rw, cpu_dtack_n;
wire [2:0] ipl_n;
wire [15:0] cpu_din, cpu_dout;       

// Minimig ram/rom interface
wire [23:1] ram_a;
wire [15:0] ram_din;
wire [15:0] ram_dout;
wire 	    ram_we_n;
wire [1:0]  ram_be;
wire 	    ram_oe_n;
wire		ram_refresh;   
   
wire [15:0] sdram_dout;

assign ram_din = sdram_dout;

// pack config values into minimig config
wire [5:0] chipset_config = { 1'b0,osd_chipset,osd_video_mode,1'b0 };
wire [7:0] memory_config = { 4'b0_000, osd_slowmem, osd_chipmem };   
wire [3:0] floppy_config = { osd_floppy_drives, 1'b0, osd_floppy_turbo };
wire [3:0] video_config = { osd_video_filter, osd_video_scanlines };   
   
nanomig nanomig
(
 .clk_sys(clk_28m),
 .reset(cpu_reset),

 .clk7_en(clk7_en),
 .clk7n_en(clk7n_en),

 .pwr_led(leds[0]),
 .fdd_led(leds[1]),
 
 .memory_config(memory_config),
 .chipset_config(chipset_config),
 .floppy_config(floppy_config),
 .video_config(video_config),
 
 // video
 .hs(hs_n), // horizontal sync
 .vs(vs_n), // vertical sync
 .r(red),
 .g(green),
 .b(blue),

 .audio_left(audio_left),
 .audio_right(audio_right),

 // uart interface 
 .uart_rx(midi_in),
 .uart_tx(midi_out),
 
 // keyboard & mouse				 
 .mouse_buttons(mouse_buttons), // mouse buttons
 .kbd_mouse_level(kbd_mouse_level),  
 .kbd_mouse_type(kbd_mouse_type),  
 .kbd_mouse_data(kbd_mouse_data),
 .joystick(joystick),
				 
 // sd card interface for floppy disk emulation
 .sdc_img_size(sd_img_size),
 .sdc_img_mounted(sd_img_mounted), 
 .sdc_rd(sd_rd),
 .sdc_sector(sd_sector),
 .sdc_busy(sd_busy),
 .sdc_done(sd_done), 
 .sdc_byte_in_strobe(sd_rd_byte_strobe),
 .sdc_byte_in_addr(sd_byte_index),
 .sdc_byte_in_data(sd_rd_data),
 
 // (s)ram interface
 .ram_data(ram_dout),       // sram data bus
 .ram_address(ram_a),       // sram address bus
 .ramdata_in(ram_din),      // sram data bus in
 ._ram_bhe(ram_be[1]),      // sram upper byte select
 ._ram_ble(ram_be[0]),      // sram lower byte select
 ._ram_we(ram_we_n),        // sram write enable
 ._ram_oe(ram_oe_n),        // sram output enable
 .chip48(48'd0),
 .refresh(ram_refresh)
);

wire           flash_ready;  
wire           mem_ready = sdram_ready && flash_ready && pll_lock;  
   
reg            start_rom_copy;
reg            mem_ready_D;

// geneate a start_rom_copy signal once flash and SDRAM are initialized
always @(posedge clk_28m or negedge pll_lock) begin
   if(!pll_lock) begin
      start_rom_copy <= 1'b0;
      mem_ready_D <= 1'b0;
         
   end else begin
      mem_ready_D <= mem_ready;  
      start_rom_copy <= 1'b0;         

      if(mem_ready && !mem_ready_D)
          start_rom_copy <= 1'b1;     
   end
end

/* -------------- state machine copying data from flash to sdram ---------------- */
reg [21:0]  flash_addr;  
wire [15:0] flash_dout;
reg [15:0]  flash_doutD;
reg		    flash_cs;  
reg [31:0]  word_count;
reg [2:0]   state;
wire        flash_data_strobe;
wire        flash_busy;   

// once the copy counter has run to zero, all rom has been copied
wire		rom_done = (word_count == 0);

assign leds[2] = !rom_done;  
   
reg [21:0]  flash_ram_addr;   
reg         flash_ram_write;
reg [5:0]   flash_cnt;  

always @(posedge clk_28m or negedge mem_ready) begin
    if(!mem_ready) begin
       flash_addr <= 22'h200000;          // 4MB flash offset (word address)
       flash_ram_addr <= { 4'hf, 18'h0 }; // write into 512k sdram segment used for kick rom
       word_count <= 22'h40001;           // 512k bytes ROM data = 256k words

       state <= 3'h0;
       flash_ram_write <= 1'b0;
       flash_cs <= 1'b0;        
       flash_cnt <= 6'd0;
    end else begin
        if((start_rom_copy || state == 7) && (word_count != 0)) begin
            flash_cs <= 1'b1;
            flash_cnt <= 6'd15; // >= 30 @ 32MHz
        end else begin
            if(flash_cnt != 0) flash_cnt <= flash_cnt - 6'd1;
            if(flash_busy)     flash_cs <= 1'b0;

            // ... static timing with fixed counter
            if(flash_cnt == 6'd1) begin
               state <= 1;
               flash_addr <= flash_addr + 22'd1;
               word_count <= word_count - 22'd1;
			   
               if ((flash_addr == 22'h2000aa || flash_addr == 22'h2200aa) && flash_dout == 16'h6678)
				 // transform bne.b to bra.b in Kickstart ROM 1.2/1.3 @ $f80154 (mirror) and $fc0154
				 // this forces memory detection on every reset
				 flash_doutD <= flash_dout & 16'hf0ff;
               else
                 // we don't necessarily need to latch the data. But latching it here
                 // allows to exactly determine the real access time by adjusting flash_cnt
                 // to the lowest value that gives a stable image
                 flash_doutD <= flash_dout;
            end
        end

        // advance ram write state
        if(state != 0)  state <= state + 3'd1;
        if(state == 1)  flash_ram_write <= 1'b1;
        if(state == 6)  flash_ram_write <= 1'b0;
        if(state == 7)  flash_ram_addr <= flash_ram_addr + 22'd1;
    end
end

// ----------------------------- SDRAM ---------------------------------

// there's a total of 16 sdram segments of 512kBytes. The last
// one is being used to store the kick romm

// run a counter at 28Mhz synchonous to the 7Mhz bus cycle
reg	    [1:0] cyc;   
always @(posedge clk_28m)
  if(clk7_en) cyc <= 2'd0;
  else        cyc <= cyc + 2'd1;

wire        sdram_access  = (!ram_oe_n || !ram_we_n);  
wire	    sdram_rw      = !ram_we_n;
   
wire		sdram_cs      = rom_done?sdram_access:flash_ram_write;

wire        sdram_sync    = rom_done?!cyc:flash_ram_write;
   
wire		sdram_refresh = rom_done?ram_refresh:1'b0;
   
wire [21:0] sdram_addr    = rom_done?ram_a[22:1]:flash_ram_addr;
wire [15:0] sdram_din     = rom_done?ram_dout:flash_doutD;
wire [1:0]  sdram_be      = rom_done?ram_be:2'b00;
wire		sdram_we      = rom_done?sdram_rw:flash_ram_write; 
   
sdram sdram (
  	.sd_clk     ( O_sdram_clk   ), // sd clock
	.sd_cke     ( O_sdram_cke   ), // clock enable
	.sd_data    ( IO_sdram_dq   ), // 32 bit bidirectional data bus
	.sd_addr    ( O_sdram_addr  ), // 11 bit multiplexed address bus
	.sd_dqm     ( O_sdram_dqm   ), // two byte masks
	.sd_ba      ( O_sdram_ba    ), // two banks
	.sd_cs      ( O_sdram_cs_n  ), // a single chip select
	.sd_we      ( O_sdram_wen_n ), // write enable
	.sd_ras     ( O_sdram_ras_n ), // row address select
	.sd_cas     ( O_sdram_cas_n ), // columns address select

	// cpu/chipset interface
	.clk        ( clk_71m       ), // sdram is accessed at 71MHz
	.reset_n    ( pll_lock      ), // init signal after FPGA config to initialize RAM

	.ready      ( sdram_ready   ), // ram is ready and has been initialized
	.sync       ( sdram_sync    ), // rising edge of sync is begin of a memory cycle
	.refresh    ( sdram_refresh ), // refresh cycle
	.din        ( sdram_din     ), // data input from chipset/cpu
	.dout       ( sdram_dout    ),
	.addr       ( sdram_addr    ), // 22 bit word address
	.ds         ( sdram_be      ), // upper/lower data strobe
	.cs         ( sdram_cs      ), // cpu/chipset requests read/wrie
	.we         ( sdram_we      )  // cpu/chipset requests write
);

// run the flash a 71MHz. This is only used at power-up to copy kickstart
// from flash to sdram
assign mspi_clk = ~clk_71m;   
flash flash (
    .clk       ( clk_71m     ),
    .resetn    ( pll_lock    ),
    .ready     ( flash_ready ),

    .address   ( flash_addr  ),
    .cs        ( flash_cs    ),
    .dout      ( flash_dout  ),
	.busy      ( flash_busy  ),

    .mspi_cs   ( mspi_cs     ),
    .mspi_di   ( mspi_di     ),
    .mspi_hold ( mspi_hold   ),
    .mspi_wp   ( mspi_wp     ),
    .mspi_do   ( mspi_do     )
);

/* -------------------- HDMI video and audio -------------------- */

// generate 48khz audio clock
reg clk_audio;
reg [8:0] aclk_cnt;
always @(posedge clk_pixel) begin
    // divisor = pixel clock / 48000 / 2 - 1
    if(aclk_cnt < `PIXEL_CLOCK / 48000 / 2 -1)
        aclk_cnt <= aclk_cnt + 9'd1;
    else begin
        aclk_cnt <= 9'd0;
        clk_audio <= ~clk_audio;
    end
end
   
wire [2:0] tmds;
wire tmds_clock;

wire vreset, vpal, interlace, short_frame;
video_analyzer video_analyzer (
    .clk         ( clk_28m   ),
    .hs          ( hs_n      ),
    .vs          ( vs_n      ),
    .pal         ( vpal      ),
    .short_frame ( short_frame ),
    .interlace   ( interlace ),
    .vreset      ( vreset    )
);
   
hdmi #(
    .AUDIO_RATE(48000), .AUDIO_BIT_WIDTH(16),
    .VENDOR_NAME( { "MiSTle", 16'd0} ),
    .PRODUCT_DESCRIPTION( {"Nanomig", 72'd0} )
) hdmi(
  .clk_pixel_x5(clk_pixel_x5),
  .clk_pixel(clk_pixel),
  .clk_audio(clk_audio),
  .audio_sample_word( { { 1'b0, ~audio_left[14],audio_left[13:0]}, {1'b0, ~audio_right[14],audio_right[13:0]}} ),
  .tmds(tmds),
  .tmds_clock(tmds_clock),

  .pal_mode(vpal),
  .short_frame ( short_frame ),
  .interlace(interlace),
  .reset(vreset),    // signal to synchronize HDMI

  .rgb( { video_red, 2'b00, video_green, 2'b00, video_blue, 2'b00 } )
);

// differential output
ELVDS_OBUF tmds_bufds [3:0] (
        .I({tmds_clock, tmds}),
        .O({tmds_clk_p, tmds_d_p}),
        .OB({tmds_clk_n, tmds_d_n})
);
   
endmodule

// To match emacs with gw_ide default
// Local Variables:
// tab-width: 4
// End:

