module pce (
    input wire clk_sys_42_95,
    input wire clk_mem_85_91,

    input wire core_reset,
    input wire pll_core_locked,

    // Input
    input wire p1_button_1,
    input wire p1_button_2,
    input wire p1_button_3,
    input wire p1_button_4,
    input wire p1_button_5,
    input wire p1_button_6,
    input wire p1_button_select,
    input wire p1_button_start,
    input wire p1_dpad_up,
    input wire p1_dpad_down,
    input wire p1_dpad_left,
    input wire p1_dpad_right,

    input wire p2_button_1,
    input wire p2_button_2,
    input wire p2_button_3,
    input wire p2_button_4,
    input wire p2_button_5,
    input wire p2_button_6,
    input wire p2_button_select,
    input wire p2_button_start,
    input wire p2_dpad_up,
    input wire p2_dpad_down,
    input wire p2_dpad_left,
    input wire p2_dpad_right,

    input wire p3_button_1,
    input wire p3_button_2,
    input wire p3_button_3,
    input wire p3_button_4,
    input wire p3_button_5,
    input wire p3_button_6,
    input wire p3_button_select,
    input wire p3_button_start,
    input wire p3_dpad_up,
    input wire p3_dpad_down,
    input wire p3_dpad_left,
    input wire p3_dpad_right,

    input wire p4_button_1,
    input wire p4_button_2,
    input wire p4_button_3,
    input wire p4_button_4,
    input wire p4_button_5,
    input wire p4_button_6,
    input wire p4_button_select,
    input wire p4_button_start,
    input wire p4_dpad_up,
    input wire p4_dpad_down,
    input wire p4_dpad_left,
    input wire p4_dpad_right,

    input wire sgx,
	 input wire AC_EN,

    // Settings
    input wire turbo_tap_enable,
    input wire button6_enable,
    input wire [1:0] button1_turbo_speed,
    input wire [1:0] button2_turbo_speed,

    input wire overscan_enable,
    input wire extra_sprites_enable,
    input wire raw_rgb_enable,

    input wire mb128_enable,
    input wire skip_run_enable,

    input wire cd_audio_boost,
    input wire adpcm_audio_boost,
    input wire [1:0] master_audio_boost,

    // Data in
    input wire        ioctl_wr,
    input wire [23:0] ioctl_addr,
    input wire [15:0] ioctl_dout,
    input wire        cart_download,

    // Data out
    input wire sd_wr,
    input wire sd_rd,
    input wire [7:0] sd_buff_addr,
    input wire [16:0] sd_lba,
    input wire [15:0] sd_buff_dout,
    output wire [15:0] sd_buff_din,
    input wire save_download,

    // SDRAM
    output wire [12:0] dram_a,
    output wire [ 1:0] dram_ba,
    inout  wire [15:0] dram_dq,
    output wire [ 1:0] dram_dqm,
    output wire        dram_clk,
    output wire        dram_cke,
    output wire        dram_ras_n,
    output wire        dram_cas_n,
    output wire        dram_we_n,

    // The first PSRAM chip: the MB128's memory (mb128_psram.sv)
    output wire [21:16] cram0_a,
    inout  wire [15:0]  cram0_dq,
    output wire         cram0_clk,
    output wire         cram0_adv_n,
    output wire         cram0_cre,
    output wire         cram0_ce0_n,
    output wire         cram0_ce1_n,
    output wire         cram0_oe_n,
    output wire         cram0_we_n,
    output wire         cram0_ub_n,
    output wire         cram0_lb_n,
    // The second PSRAM chip: the ADPCM chip's memory (adpcm_psram.sv)
    output wire [21:16] cram1_a,
    inout  wire [15:0]  cram1_dq,
    output wire         cram1_clk,
    output wire         cram1_adv_n,
    output wire         cram1_cre,
    output wire         cram1_ce0_n,
    output wire         cram1_ce1_n,
    output wire         cram1_oe_n,
    output wire         cram1_we_n,
    output wire         cram1_ub_n,
    output wire         cram1_lb_n,

    // the MB128's chip set up, which core_top.v's boot status waits on (the simulation loads
    // the save after it); and both chips' test words back
    output wire         psram_ready,
    output wire         psram_mem_ok,
    // each chip apart: {ADPCM's cleared, MB128's cleared, ADPCM's test words, MB128's}
    output wire [3:0]   psram_status,

    // Video
    output reg ce_pix,
    output wire hsync,
    output wire vsync,
    output wire hblank,
    output wire vblank,
    output wire [7:0] video_r,
    output wire [7:0] video_g,
    output wire [7:0] video_b,

    output wire border,

    // Audio
    output wire [15:0] audio_l,
    output wire [15:0] audio_r,
	 
	 // CDROM Access
	 inout  			[35:0] EXT_BUS,

    // Save states (state_engine.sv): the window state_bridge.sv drives
    input  wire        SS_SAVE,
    input  wire        SS_LOAD,
    input  wire        SS_MENU,			// the Pocket's menu open (its 0x00B0 notice), on clk_sys
    input  wire        SS_CMD_NEW,			// a host command started, on clk_sys
    input  wire [16:0] SS_CMD,			// it, with its first parameter's bit 0 at bit 16
    input  wire        SS_GO,
    output wire  [1:0] SS_STATUS,
    input  wire [20:0] SS_ADDR,
    input  wire        SS_RD,
    output wire [15:0] SS_DO,
    input  wire        SS_WR,
    input  wire [15:0] SS_DI,
    // and the drive's part (the MPU's CORE_INPUT and CORE_OUTPUT bits)
    output wire [31:0] SS_CARD_SIZE,
    output wire [31:0] SS_CARD_SUM,
    output wire [20:0] SS_WORDS,
    output wire        SS_DRV_PARK,
    output wire        SS_DRV_IN,
    output wire        SS_DRV_LOAD,
    output wire [11:0] SS_REFUSED,			// state_engine.sv's refused saves, for the CD Debug overlay
    // the MB128 and Arcade System settings as the Pocket wrote them: what a state holds and is checked against
    input  wire        SS_MB128_ON,
    input  wire        SS_AC_ON,
    input  wire        SS_DRV_PARKED,
    input  wire        SS_DRV_RESTORED
);

  wire                                       [63:0] status = 0;

  wire code_download = 0;

  // wire img_mounted = 0;
  // wire img_readonly = 0;
  // wire sd_ack = 0;
  // reg                                                              sd_rd = 0;
  // reg                                                              sd_wr = 0;
  // reg                                   [31:0]                     sd_lba = 0;
  wire        cd_en;

  wire VDC_BG_EN = 1;
  wire VDC_SPR_EN = 1;
  wire [ 1:0] VDC_GRID_EN = 2'd0;
  wire CPU_PAUSE_EN;

  // a save or a load under way holds every reset off the console: the engine's own is power-up's
  wire ss_keep;
  wire reset = (core_reset | save_download) & ~ss_keep;

  // the save states' signals (state_engine.sv, below)
  wire        ss_hold, ss_rst, ss_shift, ss_sync, ss_parked, ss_busy, ss_mem, ss_mwe, ss_refetch;
  wire        ss_snap, ss_rest, ss_win;
  wire  [3:0] ss_chain, ss_msel;
  wire [15:0] ss_si, ss_so, ss_md, ss_mq;
  wire [14:0] ss_ma;
  wire  [9:0] ss_vpos;
  wire [11:0] ss_hpos;
  wire        ss_blank, ss_freeze_ok;
  wire  [1:0] ss_fsel;
  wire        ss_frd, ss_fwr, ss_fclr;
  wire [31:0] ss_fd, ss_fq;
  wire [12:0] ss_fcnt;
  wire [15:0] ss_ad_a;
  wire  [7:0] ss_ad_d, ss_ad_q;
  wire        ss_ad_we, ss_ad_rd;
  wire        ss_sd, ss_sd_ref, ss_sd_we, ss_sd_rd;
  wire [21:0] ss_sd_a;
  wire  [7:0] ss_sd_d;
  wire        ss_bk, ss_bk_we;
  wire        ss_mb, ss_mb_we, ss_mb_rd;
  wire [15:0] ss_mb_a, ss_mb_d;
  wire  [9:0] ss_bk_a;
  wire [15:0] ss_bk_d;
  wire        ss_link_we, ss_rest_we;			// main.sv's own chains, assigned below
  wire [319:0] ss_link_v, ss_link_n;
  wire  [95:0] ss_rest_v, ss_rest_n;
  wire [122:0] hps_ss_q;
  wire  [79:0] mb128_ss_q;
  wire  [15:0] ss_so_main;

  
  
	wire [14:0] PRAM_addr, 	RAM_addr;
	wire [7:0] 	PRAM_q, 		RAM_q;
	wire [7:0] 	PRAM_data, 	RAM_data;
	wire 			PRAM_wr,		RAM_wr;
	wire 			PRAM_SEL,	RAM_SEL;

	wire [15:0] VRAM1_A;
	wire [15:0] VRAM1_DI;
	wire [15:0] VRAM1_DO;
	wire 			VRAM1_WE;
	wire 			VIDEO_CE;

  wire overscan = ~status[17];

  wire [95:0]  cd_comm;
  wire         cd_comm_send;
  reg  [15:0]  cd_stat;
  reg          cd_stat_rec;
  reg          cd_dataout_req;
  wire [79:0]  cd_dataout;
  wire         cd_dataout_send;
  wire         cd_reset_req;
  reg          cd_region;
	wire			CD_almost_full;
	wire			AUDIO_almost_full;
  wire [16:0]  adram_a;
  wire [3:0]   adram_di, adram_do;
  wire         adram_we, adram_rd;
  wire [21:0]  cd_ram_a;
  wire 			cd_ram_rd, cd_ram_wr;
  wire [7:0] 	cd_ram_do;

  wire       	ce_rom;
  reg				RAM_RDY;

  wire [15:0] 	cdda_sl, cdda_sr, adpcm_s, psg_sl, psg_sr;

  pce_top #(LITE) pce_top (
		.RESET					(reset | cart_download),
		.COLD_RESET				(cart_download),

		.CLK						(clk_sys_42_95),

		.ROM_RD					(rom_rd),
		.ROM_RDY					(rom_sdrdy),
		.ROM_A					(rom_rdaddr),
		.ROM_DO					(rom_sdata),
		.ROM_SZ					(romwr_a[23:12]),
		.ROM_POP					(populous[romwr_a[9]]),
		.ROM_CLKEN				(ce_rom),

		.BRM_A 					(bram_addr),
		.BRM_DO					(bram_q),
		.BRM_DI					(bram_data),
		.BRM_WE					(bram_wr),

		.GG_EN					(status[5]),
		.GG_CODE					(gg_code),
		.GG_RESET				((cart_download | code_download) & ioctl_wr & !ioctl_addr),
		.GG_AVAIL				(gg_avail),

		.SP64						(extra_sprites_enable),
		.SGX 						(sgx && !LITE),

		.JOY_OUT					(joy_out),
		.JOY_IN 					(joy_in),

		.CD_EN					(cd_en),
		// Arcade card
		.AC_EN					(AC_EN),

		.CD_RAM_A 				(cd_ram_a),
		.CD_RAM_DO				(cd_ram_do),
		.CD_RAM_DI				(rom_sdata),
		.CD_RAM_RD				(cd_ram_rd),
		.CD_RAM_WR				(cd_ram_wr),

		.ADRAM_A					(adram_a),
		.ADRAM_DI				(adram_di),
		.ADRAM_DO				(adram_do),
		.ADRAM_WE				(adram_we),
		.ADRAM_RD				(adram_rd),

		.CD_STAT					(cd_stat[7:0]),
		.CD_MSG					(cd_stat[15:8]),
		.CD_STAT_GET			(cd_stat_rec),

		.CD_COMM					(cd_comm),
		.CD_COMM_SEND			(cd_comm_send),

		.CD_DOUT_REQ			(cd_dataout_req),
		.CD_DOUT					(cd_dataout),

		.CD_DOUT_SEND			(cd_dataout_send),

		.CD_REGION				(cd_region),
		.CD_RESET 				(cd_reset_req),

		.CD_DATA					(!cd_dat_byte ? cd_dat[7:0] : cd_dat[15:8]),
		.CD_DATA_WR				(cd_wr && cd_dm),
		.CD_AUDIO_WR			(cd_wr && !cd_dm && !cd_sub),
		.CD_SUBCD_WR			(cd_wr && !cd_dm && cd_sub),
		.CD_DATA_END			(cd_dat_req),
		.CD_DM					(cd_dm),

		.CDDA_SL					(cdda_sl),
		.CDDA_SR					(cdda_sr),
		.ADPCM_S					(adpcm_s),
		.PSG_SL 					(psg_sl),
		.PSG_SR 					(psg_sr),

		.BG_EN					(VDC_BG_EN),
		.SPR_EN					(VDC_SPR_EN),
		.GRID_EN					(VDC_GRID_EN),
		.CPU_PAUSE_EN			(CPU_PAUSE_EN),

		.ReducedVBL				(~overscan_enable),
		.BORDER_EN				(0),
		.VIDEO_R					(r),
		.VIDEO_G					(g),
		.VIDEO_B					(b),
		.VIDEO_BW				(bw),
		.VIDEO_CE_FS			(ce_vid),
		.VIDEO_VS				(vs),
		.VIDEO_HS				(hs),
		.VIDEO_HBL				(hbl),
		.VIDEO_VBL				(vbl),
		
		.CD_almost_full		(CD_almost_full),
		.AUDIO_almost_full	(AUDIO_almost_full),
		.BORDER_OUT				(border),

		.SS_HOLD					(ss_hold),
		.SS_RST					(ss_rst),
		.SS_CHAIN				(ss_chain),
		.SS_SHIFT				(ss_shift),
		.SS_SI					(ss_si),
		.SS_SO					(ss_so),
		.SS_SNAP					(ss_snap),
		.SS_REST					(ss_rest),
		.SS_SYNC					(ss_sync),
		.SS_PARKED				(ss_parked),
		.SS_WIN					(ss_win),
		.SS_BUSY					(ss_busy),
		.SS_VPOS					(ss_vpos),
		.SS_HPOS					(ss_hpos),
		.SS_MEM					(ss_mem),
		.SS_MSEL					(ss_msel),
		.SS_MA					(ss_ma),
		.SS_MWE					(ss_mwe),
		.SS_MD					(ss_md),
		.SS_MQ					(ss_mq),
		.SS_FREEZE_OK			(ss_freeze_ok),
		.SS_FSEL					(ss_fsel),
		.SS_FRD					(ss_frd),
		.SS_FWR					(ss_fwr),
		.SS_FCLR					(ss_fclr),
		.SS_FD					(ss_fd),
		.SS_FQ					(ss_fq),
		.SS_FCNT					(ss_fcnt)
  );

  ////////////////////////////  SAVE STATES  ///////////////////////////////////


  state_engine state_engine (
      .clk(clk_sys_42_95),
      .locked(pll_core_locked),

      .SS_SAVE(SS_SAVE),
      .SS_LOAD(SS_LOAD),
      .menu(SS_MENU),
      .cmd_new(SS_CMD_NEW),
      .cmd(SS_CMD),
      .SS_GO(SS_GO),
      .SS_STATUS(SS_STATUS),
      .SS_ADDR(SS_ADDR),
      .SS_RD(SS_RD),
      .SS_DO(SS_DO),
      .SS_WR(SS_WR),
      .SS_DI(SS_DI),

      .vpos(ss_vpos),
      .hpos(ss_hpos),
      .vbl(vbl),
      .window(ss_win),

      .cpu_pause(CPU_PAUSE_EN),
      .cpu_rst(ss_rst),
      .cpu_sync(ss_sync),
      .cpu_parked(ss_parked),
      .rom_rdy(rom_sdrdy),
      .refetch(ss_refetch),
      .cpu_fast(1'b0),

      .hold(ss_hold),
      .snap(ss_snap),
      .rest(ss_rest),
      .keep(ss_keep),
      .blank(ss_blank),
      .busy(ss_busy),
      .freeze_ok(ss_freeze_ok),

      .drv_park(SS_DRV_PARK),
      .drv_in(SS_DRV_IN),
      .drv_load(SS_DRV_LOAD),
      .drv_parked(SS_DRV_PARKED),
      .drv_restored(SS_DRV_RESTORED),
      .refused(SS_REFUSED),

      .chain(ss_chain),
      .shift(ss_shift),
      .si(ss_si),
      .so(ss_so_main),

      .mem(ss_mem),
      .msel(ss_msel),
      .ma(ss_ma),
      .mwe(ss_mwe),
      .md(ss_md),
      .mq(ss_mq),

      .fsel(ss_fsel),
      .frd(ss_frd),
      .fwr(ss_fwr),
      .fclr(ss_fclr),
      .fd(ss_fd),
      .fq(ss_fq),
      .fcount(ss_fcnt),

      .ad_a(ss_ad_a),
      .ad_d(ss_ad_d),
      .ad_we(ss_ad_we),
      .ad_rd(ss_ad_rd),
      .ad_q(ss_ad_q),

      .sd(ss_sd),
      .sd_a(ss_sd_a),
      .sd_d(ss_sd_d),
      .sd_ref(ss_sd_ref),
      .sd_we(ss_sd_we),
      .sd_rd(ss_sd_rd),
      .sd_q(rom_sdata),
      .sd_clkref(ce_rom | ss_refetch | ss_sd_ref),

      .mb(ss_mb),
      .mb_a(ss_mb_a),
      .mb_d(ss_mb_d),
      .mb_we(ss_mb_we),
      .mb_rd(ss_mb_rd),
      .mb_q(mb128_dout),

      .mb128_on(SS_MB128_ON),
      .ac_on(SS_AC_ON),
      .ac_write(~cart_download & cd_ram_wr & ce_rom),
      .ac_write_a(cd_ram_a),

      .bk(ss_bk),
      .bk_a(ss_bk_a),
      .bk_d(ss_bk_d),
      .bk_we(ss_bk_we),
      .bk_q(bk_int_dout),

      .cart_download(cart_download),
      .ioctl_wr(ioctl_wr),
      .ioctl_dout(ioctl_dout),

      .hdr_card_size(SS_CARD_SIZE),
      .hdr_card_sum(SS_CARD_SUM),
      .size_words(SS_WORDS)
  );
  


  ////////////////////////////  CD communication   ///////////////////////////////////

   reg  [112:0] 	cd_in = 0;
   wire [112:0] 	cd_out;
	wire 				cd_dat_download;
	wire 				cdctl_wr;
	wire [15:0]		cd_data_out;
   hps_ext hps_ext
   (
   	.clk_sys(clk_sys_42_95),
   	.EXT_BUS(EXT_BUS),
   	.cd_in(cd_in),
   	.cd_out(cd_out),
		.cd_dat_download(cd_dat_download),
		.cdctl_wr(cdctl_wr),
		.cd_data_out(cd_data_out),
		.cd_en(cd_en),
		.AUDIO_almost_full(AUDIO_almost_full),
		.CD_almost_full(CD_almost_full),
		.ss_hold(ss_hold),
		.ss_q(hps_ss_q),
		.ss_d(ss_link_n[307:185]),
		.ss_we(ss_link_we)
   );

   reg        cd_dat_req;
   reg cd_out112_last = 1;
   reg cd_comm_send_old = 0, cd_dataout_send_old = 0, cd_dat_req_old = 0, cd_reset_req_old = 0;
   // held for a save state: the chips' signals move as their chains do, and the drive is parked
   always @(posedge clk_sys_42_95) begin
   	if (ss_link_we) {cd_in, cd_stat, cd_stat_rec, cd_dataout_req, cd_region, cd_out112_last, cd_comm_send_old,
   	                 cd_dataout_send_old, cd_dat_req_old, cd_reset_req_old} <= ss_link_n[136:0];
   	else if (!ss_hold) begin
   	cd_stat_rec <= 0;
   	cd_dataout_req <= 0;
   	if (reset) begin
   		cd_region <= 0;
   	end
   	else begin
   		if (cd_out[112] != cd_out112_last) begin
   			cd_out112_last <= cd_out[112];

   			cd_stat <= cd_out[15:0];
   			cd_stat_rec <= ~cd_out[16];
   			cd_dataout_req <= cd_out[16];
   			cd_region <= cd_out[17];
   		end

   		cd_comm_send_old <= cd_comm_send;
   		cd_dataout_send_old <= cd_dataout_send;
   		cd_dat_req_old <= cd_dat_req;
   		cd_reset_req_old <= cd_reset_req;
   		if (cd_comm_send && !cd_comm_send_old) begin
   			cd_in[95:0] <= cd_comm;
   			cd_in[111:96] <= {cd_en,15'd0};
   			cd_in[112] <= ~cd_in[112];
   		end
   		else if (cd_dataout_send && !cd_dataout_send_old) begin
   			cd_in[79:0] <= cd_dataout;
   			cd_in[111:96] <= 16'h0001;
   			cd_in[112] <= ~cd_in[112];
   		end
   		else if (cd_dat_req && !cd_dat_req_old) begin
   			cd_in[111:96] <= 16'h0002;
   			cd_in[112] <= ~cd_in[112];
   		end
   		else if (cd_reset_req && !cd_reset_req_old) begin
   			cd_in[111:96] <= 16'h00FF;
   			cd_in[112] <= ~cd_in[112];
   		end
   	end
   	end
   end

  reg [15:0] cd_dat = 0;
  reg        cd_wr = 0;
  reg        cd_dat_byte = 0;
  reg        cd_dm = 0;
  reg 		 cd_sub = 0;
  reg 		 cd_cdg;
  reg cdd_old_download;
  reg cd_head_pos, cd_dat_write;
  reg [11:0] cd_dat_len, cd_dat_cnt;
   always @(posedge clk_sys_42_95) begin
   	if (ss_link_we) {cdd_old_download, cd_head_pos, cd_dat_write, cd_dat_len, cd_dat_cnt, cd_dat, cd_wr, cd_dat_byte,
   	                 cd_dm, cd_sub, cd_cdg} <= ss_link_n[184:137];
   	else if (!ss_hold) begin
   	cdd_old_download <= cd_dat_download;
   	if ((~cdd_old_download && cd_dat_download) || reset) begin
   		cd_head_pos <= 0;
   		cd_dat_len <= 0;
   		cd_dat_cnt <= 0;
   	end
   	else if (cdctl_wr && cd_dat_download) begin
   		if (!cd_head_pos) begin
   			cd_dat_len <= cd_data_out[11:0];
   			cd_dm <= cd_data_out[15];
				cd_cdg <= cd_data_out[14];
   			cd_dat_cnt <= 0;
   			cd_head_pos <= 1;
   		end
   		else if (cd_dat_cnt < cd_dat_len) begin
   			cd_dat_write <= 1;
   			cd_dat_byte <= 0;
   			cd_dat <= cd_data_out;
   		end
   	end

   	if (cd_dat_write) begin
   		if (!cd_wr) begin
   			cd_wr <= 1;
				// Bit 14 of the header: this transfer is subcode, MiSTer's separate ioctl index.
				// It goes apart from the audio, as a paused drive sends it with no audio to go with.
				cd_sub <= cd_cdg;
   		end
   		else begin
   			cd_wr <= 0;
   			cd_dat_byte <= ~cd_dat_byte;
   			cd_dat_cnt <= cd_dat_cnt + 15'd1;
   			if (cd_dat_byte || cd_dat_cnt >= cd_dat_len-1) begin
   				cd_dat_write <= 0;
   			end
   		end
   	end
   	end
   end


  ////////////////////////////  VIDEO  ///////////////////////////////////

  wire [2:0] r, g, b;
  wire hs, vs;
  wire hbl, vbl;
  wire bw;

  wire ce_vid;

  always @(posedge clk_mem_85_91) begin
    reg old_ce;

    old_ce <= ce_vid;
    ce_pix <= ~old_ce & ce_vid;
  end

  logic [23:0] pal_color;

  dpram #(
      .addr_width(9),
      .data_width(24),
      .mem_init_file("palette.mif")
  ) palette_ram (
      .clock(clk_mem_85_91),

      .address_a({g, r, b}),
      .q_a(pal_color)
  );

  logic [7:0] r1, b1, g1;

  // A save state's load blanks the picture from the header's match to the let-go: the VDC
  // runs on while VRAM, the SAT and the palette fill, and would draw them half written. A
  // save blanks it from its ask to the let-go (state_engine.sv's blank).
  // Skip the Run screen's black (below) is held the same way.
  reg skip_run_black = 1;
  reg ss_blank_v = 0;
  always @(posedge clk_mem_85_91) ss_blank_v <= ss_blank | (skip_run_enable & skip_run_black);

  assign {r1, g1, b1} = ss_blank_v ? 24'd0 :
                        raw_rgb_enable ? {{r, r, r[2:1]}, {g, g, g[2:1]}, {b, b, b[2:1]}} : pal_color;

  color_mix color_mix (
      .clk_vid(clk_mem_85_91),
      .ce_pix(ce_pix),
      .mix(bw ? 3'd5 : 0),

      .R_in(r1),
      .G_in(g1),
      .B_in(b1),
      .HSync_in(hs),
      .VSync_in(vs),
      .HBlank_in(hbl),
      .VBlank_in(vbl),

      .R_out(video_r),
      .G_out(video_g),
      .B_out(video_b),
      .HSync_out(hsync),
      .VSync_out(vsync),
      .HBlank_out(hblank),
      .VBlank_out(vblank)
  );

  ////////////////////////////  AUDIO  ///////////////////////////////////

  pce_audio pce_audio (
      .clk_sys_42_95(clk_sys_42_95),

      .cd_audio_boost(cd_audio_boost),
      .adpcm_audio_boost(adpcm_audio_boost),
      .master_audio_boost(master_audio_boost),

      .cdda_sl(cdda_sl),
      .cdda_sr(cdda_sr),
      .adpcm_s(adpcm_s),
      .psg_sl (psg_sl),
      .psg_sr (psg_sr),

      .audio_l(audio_l),
      .audio_r(audio_r)
  );

  ////////////////////////////  MEMORY  //////////////////////////////////

  localparam LITE = 1;

  wire [21:0] rom_rdaddr;
  wire [ 7:0] rom_sdata;
  wire rom_rd, rom_sdrdy;

  sdram sdram (
      .init(~pll_core_locked),
      .clk(clk_mem_85_91),
      // a save state's engine has a clkref of its own for its reads and writes of the CD RAM,
      // and its let-go reads the CPU's fetch again (state_engine.sv)
      .clkref(ce_rom | ss_refetch | ss_sd_ref),

      .waddr(cart_download ? romwr_a : {3'b001, ss_sd ? ss_sd_a : cd_ram_a}),
      .din(cart_download ? romwr_d : ss_sd ? {ss_sd_d, ss_sd_d} : {cd_ram_do, cd_ram_do}),
      .we(~cart_download & ((cd_ram_wr & ce_rom) | ss_sd_we)),
      .we_req(rom_wr),
      // .we_ack(sd_wrack),

      .raddr(ss_sd ? {3'b001, ss_sd_a} : rom_rd ? {3'b000, (rom_rdaddr + (romwr_a[9] ? 22'h200 : 22'h0))} : {3'b001, cd_ram_a}),
      .rd(((rom_rd | cd_ram_rd) & (ce_rom | ss_refetch)) | ss_sd_rd),
      .rd_rdy(rom_sdrdy),
      .dout(rom_sdata),

      // Actual SDRAM interface
      .SDRAM_DQ(dram_dq),
      .SDRAM_A(dram_a),
      .SDRAM_DQML(dram_dqm[0]),
      .SDRAM_DQMH(dram_dqm[1]),
      .SDRAM_BA(dram_ba),
      //   .SDRAM_nCS(),
      .SDRAM_nWE(dram_we_n),
      .SDRAM_nRAS(dram_ras_n),
      .SDRAM_nCAS(dram_cas_n),
      .SDRAM_CLK(dram_clk),
      .SDRAM_CKE(dram_cke)
  );
  


reg [15:0] vram_mem [32767:0];

always @(posedge clk_sys_42_95) begin
	if (~VRAM1_A[15]) begin
		if (~VRAM1_WE) vram_mem[VRAM1_A[14:0]] <= VRAM1_DO;
	VRAM1_DI <= vram_mem[VRAM1_A[14:0]];	
	end
end



  wire romwr_ack;
  reg [23:0] romwr_a;
  wire [15:0] romwr_d = status[3] ?
		{ ioctl_dout[8], ioctl_dout[9], ioctl_dout[10],ioctl_dout[11],ioctl_dout[12],ioctl_dout[13],ioctl_dout[14],ioctl_dout[15],
		  ioctl_dout[0], ioctl_dout[1], ioctl_dout[2], ioctl_dout[3], ioctl_dout[4], ioctl_dout[5], ioctl_dout[6], ioctl_dout[7] }
		: ioctl_dout;

  reg prev_ioctl_wr = 0;
  reg rom_wr = 0;
  wire sd_wrack;

  // Special support for the Populous ROM
  reg [1:0] populous;
  // reg sgx;
  always @(posedge clk_sys_42_95) begin
    reg old_download;

    old_download  <= cart_download;
    // old_reset <= reset;
    prev_ioctl_wr <= ioctl_wr;

    // if (~old_reset && reset) ioctl_wait <= 0;
    if (~old_download && cart_download) begin
      romwr_a  <= 0;
      populous <= 2'b11;
      // sgx <= ioctl_index[0];
    end else begin
      if (ioctl_wr && ~prev_ioctl_wr) begin
        // ioctl_wait <= 1;
        rom_wr <= ~rom_wr;
        // Hacks for Populous game
        if ((romwr_a[23:4] == 'h212) || (romwr_a[23:4] == 'h1f2)) begin
          case (romwr_a[3:0])
            6:  if (romwr_d != 'h4F50) populous[romwr_a[13]] <= 0;
            8:  if (romwr_d != 'h5550) populous[romwr_a[13]] <= 0;
            10: if (romwr_d != 'h4F4C) populous[romwr_a[13]] <= 0;
            12: if (romwr_d != 'h5355) populous[romwr_a[13]] <= 0;
          endcase
        end
      end  // else if (rom_wr == sd_wrack) begin
      else if (~ioctl_wr && prev_ioctl_wr) begin
        // Falling edge of ioctl_wr
        // ioctl_wait <= 0;
        romwr_a <= romwr_a + 24'd2;
      end
    end
  end

  ////////////////////////////  CODES  ///////////////////////////////////

  reg [128:0] gg_code;
  wire gg_avail;

  ////////////////////////////  INPUT  ///////////////////////////////////

  wire button1_turbo_enable = button1_turbo_speed == 1 ? turbo_counter[2] :
                              button1_turbo_speed == 2 ? turbo_counter[1] :
                              1;

  wire button2_turbo_enable = button2_turbo_speed == 1 ? turbo_counter[2] :
                              button2_turbo_speed == 2 ? turbo_counter[1] :
                              1;

  // Skip the Run screen (Core Settings): from a start or Reset core, Run on the first pad is
  // pressed for 6 frames in every 23, until the system card's first command to the drive. The
  // card sends none before Run (only its reset of the drive), and TEST UNIT READY the moment Run
  // is taken, so the presses end on the title and never reach a game. Pressing again and again
  // needs no timing for each card's title. A save state's chain going round stops it, so a
  // loaded state never gets a press, and neither register needs a place in the state.
  reg        skip_run_armed = 1;
  reg [23:0] skip_run_count = 0;
  always @(posedge clk_sys_42_95) begin
    if (reset) begin
      skip_run_armed <= 1;
      skip_run_count <= 0;
    end
    else if (ss_link_we) skip_run_armed <= 0;
    else if (skip_run_armed && cd_comm_send && !cd_comm_send_old) begin
      skip_run_armed <= 0;
      skip_run_count <= 0;                 // from the first command it times the black below
    end
    else if (!ss_hold) skip_run_count <= skip_run_count + 1'd1;
  end
  // 2^24 clocks, 0.39 s or 23 frames a round; pressed in its last quarter, the first press 0.29 s in
  wire skip_run_press = skip_run_enable && skip_run_armed && &skip_run_count[23:22];

  // and the title is never seen. The system card leaves it up, with JUST A MOMENT, until the
  // game draws over it (R-Type: 2.5 s after Run), and on a first start the drive may still be
  // opening the disc when Run is taken, so no command marks the moment. The picture is black
  // from the reset until, after the first command, a frame in which more than 32 lines differ
  // from the frame before: JUST A MOMENT in place of PUSH RUN BUTTON is one row of text, 8
  // lines, while a game's first picture, its clear to black or the CD player is far more. Each
  // line's dots are folded into 16 bits and kept for the next frame in one RAM block. Whatever
  // happens it ends 31 rounds (12.1 s) after the first command, or 8 rounds (3.1 s) with the
  // setting on if none comes, so a card that never leaves its title still shows it. A save
  // state's chain going round lets it go, as it does the presses.
  reg  [4:0] skip_run_rounds = 0;
  reg        skip_run_sent = 0;
  reg [15:0] skip_run_lines [0:255];
  reg [15:0] skip_run_sig = 0, skip_run_prev = 0;
  reg  [7:0] skip_run_line = 0, skip_run_diff = 0;
  reg        skip_run_vs_old = 0, skip_run_hbl_old = 0;
  wire       skip_run_round = &skip_run_count;
  wire       skip_run_vs = vs && !skip_run_vs_old;
  always @(posedge clk_sys_42_95) begin
    skip_run_vs_old <= vs;
    skip_run_hbl_old <= hbl;
    skip_run_prev <= skip_run_lines[skip_run_line];
    if (ce_vid && !hbl && !vbl) skip_run_sig <= {skip_run_sig[14:0], skip_run_sig[15]} + {g, r, b};
    if (hbl && !skip_run_hbl_old && !vbl) begin   // a line's dots done
      skip_run_lines[skip_run_line] <= skip_run_sig;
      if (skip_run_sig != skip_run_prev && !(&skip_run_diff)) skip_run_diff <= skip_run_diff + 1'd1;
      skip_run_line <= skip_run_line + 1'd1;
      skip_run_sig <= 0;
    end
    if (skip_run_vs) begin
      skip_run_line <= 0;
      skip_run_diff <= 0;
      skip_run_sig <= 0;
    end

    if (reset) begin
      skip_run_black <= 1;
      skip_run_rounds <= 0;
      skip_run_sent <= 0;
    end
    else if (ss_link_we) skip_run_black <= 0;
    else if (!ss_hold) begin
      if (cd_comm_send && !cd_comm_send_old) begin
        if (!skip_run_sent) skip_run_rounds <= 0;   // skip_run_count starts again with it
        skip_run_sent <= 1;
      end
      else if (skip_run_round && (skip_run_sent || skip_run_enable)) begin
        skip_run_rounds <= skip_run_rounds + 1'd1;
        if ((skip_run_sent && skip_run_rounds == 5'd30) || (!skip_run_sent && skip_run_rounds == 5'd7))
          skip_run_black <= 0;
      end
      if (skip_run_vs && skip_run_sent && skip_run_diff > 8'd32) skip_run_black <= 0;
    end
  end

  wire [11:0] joy_0 = {
    p1_button_6,
    p1_button_5,
    p1_button_4,
    p1_button_3,
    p1_button_start | skip_run_press,
    p1_button_select,
    button6_enable ? p1_button_2 : p1_button_2 | (button2_turbo_enable && p1_button_4),
    button6_enable ? p1_button_1 : p1_button_1 | (button1_turbo_enable && p1_button_3),
    p1_dpad_up,
    p1_dpad_down,
    p1_dpad_left,
    p1_dpad_right
  };

  wire [11:0] joy_1 = {
    p2_button_6,
    p2_button_5,
    p2_button_4,
    p2_button_3,
    p2_button_start,
    p2_button_select,
    button6_enable ? p2_button_2 : p2_button_2 | (button2_turbo_enable && p2_button_4),
    button6_enable ? p2_button_1 : p2_button_1 | (button1_turbo_enable && p2_button_3),
    p2_dpad_up,
    p2_dpad_down,
    p2_dpad_left,
    p2_dpad_right
  };

  wire [11:0] joy_2 = {
    p3_button_6,
    p3_button_5,
    p3_button_4,
    p3_button_3,
    p3_button_start,
    p3_button_select,
    button6_enable ? p3_button_2 : p3_button_2 | (button2_turbo_enable && p3_button_4),
    button6_enable ? p3_button_1 : p3_button_1 | (button1_turbo_enable && p3_button_3),
    p3_dpad_up,
    p3_dpad_down,
    p3_dpad_left,
    p3_dpad_right
  };

  wire [11:0] joy_3 = {
    p4_button_6,
    p4_button_5,
    p4_button_4,
    p4_button_3,
    p4_button_start,
    p4_button_select,
    button6_enable ? p4_button_2 : p4_button_2 | (button2_turbo_enable && p4_button_4),
    button6_enable ? p4_button_1 : p4_button_1 | (button1_turbo_enable && p4_button_3),
    p4_dpad_up,
    p4_dpad_down,
    p4_dpad_left,
    p4_dpad_right
  };

  wire [11:0] joy_4 = 0;

  wire [15:0] joy_data  /* synthesis keep */;
  always_comb begin
    case (joy_port)
      0:
      joy_data = (status[27:26] == 2'b01) ? {mouse_data, mouse_data} :
						                            ~{4'hF, joy_0[11:8], joy_0[1], joy_0[2], joy_0[0], joy_0[3], joy_0[7:4]};

      1:
      joy_data = (status[27:26] == 2'b10) ? pachinko                 : ~{4'hF, joy_1[11:8], joy_1[1], joy_1[2], joy_1[0], joy_1[3], joy_1[7:4]};
      2: joy_data = ~{4'hF, joy_2[11:8], joy_2[1], joy_2[2], joy_2[0], joy_2[3], joy_2[7:4]};
      3: joy_data = ~{4'hF, joy_3[11:8], joy_3[1], joy_3[2], joy_3[0], joy_3[3], joy_3[7:4]};
      4: joy_data = ~{4'hF, joy_4[11:8], joy_4[1], joy_4[2], joy_4[0], joy_4[3], joy_4[7:4]};
      default: joy_data = 16'h0FFF;
    endcase
  end

  reg [6:0] pachinko = 0;


  wire [7:0] mouse_data = 0;

  reg [3:0] joy_latch;
  reg [2:0] joy_port;
  reg [1:0] mouse_cnt;
  reg [7:0] ms_x, ms_y;
  reg [3:0] turbo_counter = 0;

  reg [ 1:0] last_gp;
  reg        high_buttons = 0;
  // held for a save state: the pads' select moves as the CPU's chain does
  always @(posedge clk_sys_42_95) begin : input_block
    reg [14:0] mouse_to;
    reg        ms_stb;
    reg [7:0] msr_x, msr_y;

    if (ss_rest_we) {joy_latch, last_gp, high_buttons, turbo_counter, joy_port} <= ss_rest_n[13:0];
    else if (!ss_hold) begin
    if (reset) high_buttons <= 0;

    joy_latch <= joy_data[{high_buttons, joy_out[0], 2'b00}+:4];

    last_gp   <= joy_out;

    if (joy_out[1]) mouse_to <= 0;
    else if (~&mouse_to) mouse_to <= mouse_to + 1'd1;

    if (&mouse_to) mouse_cnt <= 3;
    if (~last_gp[1] & joy_out[1]) begin
      mouse_cnt <= mouse_cnt + 1'd1;
      if (&mouse_cnt) begin
        ms_x  <= msr_x;
        ms_y  <= msr_y;
        msr_x <= 0;
        msr_y <= 0;
      end
    end

    // ms_stb <= ps2_mouse[24];
    // if (ms_stb ^ ps2_mouse[24]) begin
    //   msr_x <= 8'd0 - ps2_mouse[15:8];
    //   msr_y <= ps2_mouse[23:16];
    // end

    if (joy_out[1]) begin
      if (~last_gp[1]) begin
        // Rising edge of joy_out
        turbo_counter <= turbo_counter + 1;
      end

      joy_port <= 0;
      if (status[27:26] != 2'b11) begin
        joy_latch <= 0;
        if (~last_gp[1]) high_buttons <= ~high_buttons && button6_enable;
      end
    end
	else if (joy_out[0] && ~last_gp[0] && (turbo_tap_enable | status[27]) && (status[27:26] != 2'b11)) begin	// suppress if XE-1AP
      joy_port <= joy_port + 3'd1;
    end
    end
  end

  wire [1:0] joy_out;
  wire [3:0] joy_in = (mb128_ena & mb128_Active) ? mb128_Data : joy_latch;

  // The save state's chains of main.sv's own (state_engine.sv's 6 and 7), 16 bits a clock:
  // the link to the MPU (the two blocks above and hps_ext.v's), and the pads and the MB128.
  assign       ss_link_we = ss_shift && ss_chain == 4'd6;
  assign       ss_rest_we = ss_shift && ss_chain == 4'd7;
  reg   [11:0] ss_link_pad;
  reg    [1:0] ss_rest_pad;
  assign       ss_link_v = {ss_link_pad, hps_ss_q,
                            cdd_old_download, cd_head_pos, cd_dat_write, cd_dat_len, cd_dat_cnt, cd_dat, cd_wr, cd_dat_byte,
                            cd_dm, cd_sub, cd_cdg,
                            cd_in, cd_stat, cd_stat_rec, cd_dataout_req, cd_region, cd_out112_last, cd_comm_send_old,
                            cd_dataout_send_old, cd_dat_req_old, cd_reset_req_old};
  assign       ss_link_n = {ss_link_v[303:0], ss_si};
  assign       ss_rest_v = {ss_rest_pad, mb128_ss_q, joy_latch, last_gp, high_buttons, turbo_counter, joy_port};
  assign       ss_rest_n = {ss_rest_v[79:0], ss_si};
  always @(posedge clk_sys_42_95) begin
    if (ss_link_we) ss_link_pad <= ss_link_n[319:308];
    if (ss_rest_we) ss_rest_pad <= ss_rest_n[95:94];
  end
  assign       ss_so_main = ss_chain == 4'd6 ? ss_link_v[319:304] : ss_chain == 4'd7 ? ss_rest_v[95:80] : ss_so;


  /////////////////////////  BACKUP RAM SAVE/LOAD  /////////////////////////////

  wire [15:0] mb128_dout;
  wire mb128_ena = mb128_enable;
  wire mb128_Active;
  wire [3:0] mb128_Data;
  wire [19:0] mb128_ram_addr;
  wire mb128_ram_din, mb128_ram_we, mb128_ram_dout;

  MB128 MB128 (
      .reset(reset | cart_download),
      .clk_sys(clk_sys_42_95),

      .i_Clk(mb128_ena & joy_out[1]),  // send only if MB128 enabled
      .i_Data(joy_out[0]),

      .o_Active(mb128_Active),  // high if MB128 asserts itself instead of joypad inputs
      .o_Data(mb128_Data),

      .ram_addr(mb128_ram_addr),
      .ram_din(mb128_ram_din),
      .ram_we(mb128_ram_we),
      .ram_dout(mb128_ram_dout),

      .ss_hold(ss_hold),
      .ss_q(mb128_ss_q),
      .ss_d(ss_rest_n[93:14]),
      .ss_we(ss_rest_we)
  );

  wire mb128_ready, mb128_mem_ok, adpcm_ready, adpcm_mem_ok;

  // The save slot is MiSTer's: 2K of backup RAM in sectors 0 to 3, then the MB128.
  mb128_psram mb128_psram (
      .clk(clk_sys_42_95),
      .locked(pll_core_locked),

      .ready(mb128_ready),
      .mem_ok(mb128_mem_ok),

      .mb_addr(mb128_ram_addr),
      .mb_din(mb128_ram_din),
      .mb_we(mb128_ram_we & ~ss_hold),		// (held, the MB128's chain moves through it)
      .mb_dout(mb128_ram_dout),

      // the save slot's port, and a word at a time a save state's (state_engine.sv)
      .bk_addr(ss_mb ? ss_mb_a : {sd_lba[7:0] - 8'd4, sd_buff_addr}),
      .bk_din(ss_mb ? ss_mb_d : sd_buff_dout),
      .bk_dout(mb128_dout),
      .bk_we(ss_mb ? ss_mb_we : ~bk_int & sd_wr),
      .bk_rd(ss_mb ? ss_mb_rd : ~bk_int & sd_rd),

      .cram_a(cram0_a),
      .cram_dq(cram0_dq),
      .cram_clk(cram0_clk),
      .cram_adv_n(cram0_adv_n),
      .cram_cre(cram0_cre),
      .cram_ce0_n(cram0_ce0_n),
      .cram_ce1_n(cram0_ce1_n),
      .cram_oe_n(cram0_oe_n),
      .cram_we_n(cram0_we_n),
      .cram_ub_n(cram0_ub_n),
      .cram_lb_n(cram0_lb_n)
  );

  adpcm_psram adpcm_psram (
      .clk(clk_sys_42_95),
      .locked(pll_core_locked),

      .ready(adpcm_ready),
      .mem_ok(adpcm_mem_ok),

      // cd.vhd's port shut while a save state's engine has its own (state_engine.sv)
      .a(adram_a),
      .din(adram_di),
      .we(adram_we & ~ss_mem),
      .rd(adram_rd & ~ss_mem),
      .dout(adram_do),
      .ss_a(ss_ad_a),
      .ss_d(ss_ad_d),
      .ss_we(ss_ad_we),
      .ss_rd(ss_ad_rd),
      .ss_q(ss_ad_q),

      .cram_a(cram1_a),
      .cram_dq(cram1_dq),
      .cram_clk(cram1_clk),
      .cram_adv_n(cram1_adv_n),
      .cram_cre(cram1_cre),
      .cram_ce0_n(cram1_ce0_n),
      .cram_ce1_n(cram1_ce1_n),
      .cram_oe_n(cram1_oe_n),
      .cram_we_n(cram1_we_n),
      .cram_ub_n(cram1_ub_n),
      .cram_lb_n(cram1_lb_n)
  );

  assign psram_ready = mb128_ready;
  assign psram_mem_ok = mb128_mem_ok & adpcm_mem_ok;
  assign psram_status = {adpcm_ready, mb128_ready, adpcm_mem_ok, mb128_mem_ok};


  wire [10:0] bram_addr;
  wire [7:0] bram_data;
  wire [7:0] bram_q;
  wire bram_wr;

  // wire format = status[12];
  reg [3:0] bram_init_counter = 0;
  reg [15:0] defval[4] = '{16'h5548, 16'h4D42, 16'h8800, 16'h8010};  //{ HUBM,0x00881080 };

  wire bk_int = !sd_lba[15:2];
  wire [15:0] bk_int_dout;

  assign sd_buff_din = bk_int ? bk_int_dout : mb128_dout;

  dpram_difclk #(11, 8, 10, 16) backram (
      .clock0(clk_sys_42_95),
      .address_a(bram_addr),
      .data_a(bram_data),
      .wren_a(bram_wr),
      .q_a(bram_q),

      // port B: the save slot's, the format at power-up's, and a word at a time a save state's
      .clock1(clk_sys_42_95),
      .address_b(ss_bk ? ss_bk_a : bram_init_counter[3] ? {sd_lba[1:0], sd_buff_addr} : bram_init_counter[2:1]),
      .data_b(ss_bk ? ss_bk_d : bram_init_counter[3] ? sd_buff_dout : defval[bram_init_counter[2:1]]),
      .wren_b(ss_bk ? ss_bk_we : bram_init_counter[3] ? bk_int & sd_wr : 1'b1),

      .q_b(bk_int_dout)
  );

  always @(posedge clk_sys_42_95) begin
    if (pll_core_locked && bram_init_counter != 4'hF) begin
      // Initialize memory card
      bram_init_counter <= bram_init_counter + 4'd1;
    end
  end

  wire downloading = cart_download;
  reg old_downloading = 0;

   /////////////////////////  P/RAM SAVE/LOAD  /////////////////////////////
  



endmodule



