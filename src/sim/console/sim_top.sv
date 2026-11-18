// main.sv's pce, as core_top.v joins it, for Verilator: the real module and the real
// line buffer, with the bus to the MPU and the pads brought out for main.cpp. Core
// Settings at core_top.v's reset values (all off) but those main.cpp sets.

module sim_top (
	input  logic clk_sys,
	input  logic clk_mem,
	input  logic core_reset,

	input  logic cart_download,
	input  logic hucard_download,		// slot 100's load (core_top.v's), and the firmware's CORE_OUTPUT[5]
	input  logic hucard,
	input  logic ioctl_wr,
	input  logic [15:0] ioctl_dout,

	input  logic ac_en,
	input  logic mb128_en,
	input  logic skip_run,

	// the save slot, as core_top.v's data_loader and data_unloader give it to main.sv
	input  logic save_download,
	input  logic sd_wr,
	input  logic sd_rd,
	input  logic [7:0] sd_buff_addr,
	input  logic [16:0] sd_lba,
	input  logic [15:0] sd_buff_dout,
	output logic [15:0] sd_buff_din,

	output logic psram_ready,
	output logic psram_mem_ok,
	output logic [31:0] psram_violations,
	output logic [31:0] adpcm_reads,
	output logic [31:0] adpcm_writes,

	// what a game asks of the MB128, for drive.log
	output logic [3:0] mb128_state,
	output logic mb128_req,
	output logic [19:0] mb128_addr,
	output logic [19:0] mb128_bits,

	// {run, select, ii, i, right, left, down, up}
	input  logic [7:0] pad,

	// the MPU's side of EXT_BUS (core_top.v's MPU_AFP_CORE)
	input  logic io_enable,
	input  logic io_strobe,
	input  logic [15:0] io_din,
	output logic [15:0] io_dout,
	output logic io_wait,

	// as core_top.v gives them to the Pocket
	output logic video_vs,
	output logic video_hs,
	output logic video_de,
	output logic [23:0] video_rgb,

	output logic [15:0] audio_l,
	output logic [15:0] audio_r,

	// save states: main.sv's window to state_engine.sv
	input  logic        ss_save,
	input  logic        ss_load,
	input  logic        ss_go,
	output logic  [1:0] ss_status,
	input  logic [20:0] ss_addr,
	input  logic        ss_rd,
	output logic [15:0] ss_do,
	input  logic        ss_wr,
	input  logic [15:0] ss_di,
	output logic        drv_park,
	output logic        drv_in,
	output logic        drv_load,
	input  logic        ss_mb128_on,		// the settings as the Pocket writes them (core_top.v's ss_setting)
	input  logic        ss_ac_on,
	input  logic        drv_parked,
	input  logic        drv_restored,
	// what state_bridge.sv checks a header against, and a save's size (main.cpp's --pocket)
	output logic [31:0] ss_card_size,
	output logic [31:0] ss_card_sum,
	output logic [31:0] ss_hu_size,
	output logic [31:0] ss_hu_sum,
	output logic [20:0] ss_words,
	output logic [11:0] ss_refused,		// state_engine.sv's refused saves and the last one's seen bits
	// the chips' own sound, before the filters: {psg_sl, psg_sr, cdda_sl, cdda_sr, adpcm_s}
	output logic [79:0] chip_snd,
	// for SIM_SSDBG: the VDC's registers
	output logic [511:0] dbg_vdc_regs,
	output logic [20:0] dbg_cpu_a,		// SIM_PCTRACE: the CPU's address, and its opcode fetch
	output logic        dbg_cpu_sync,
	output logic [11:0] dbg_cd,		// SIM_PCTRACE: the CD's interrupt and its sources
	output logic  [7:0] dbg_cpu_sp
`ifdef ANZ
	// the Analogizer (SIM_VFLAGS=-DANZ, tools/anz-test.sh): pocket_analogizer.sv as core_top.v
	// joins it, with PC Engine pads at the slot (below)
	, input  logic        anz_wr,		// analogizer.bin's word written onto the bridge (clk_sys here)
	input  logic [31:0] anz_data,
	input  logic  [1:0] anz_pad_type,	// 0 none, 1 a 2-button pad, 2 a 6-button pad, 3 a multitap of five
	input  logic [59:0] anz_held,		// each pad's buttons held, 12 a pad from bit 0: up, right, down,
						//   left, I, II, Select, Run, III, IV, V, VI
	input  logic        anz_tx,		// the MPU's UART out, stood in for
	output logic [23:0] anz_banks,		// {bank3, bank2, bank1}
	output logic [15:0] anz_misc,		// {bank3, 2, 1, 0 dirs, pin30 dir, pin31 dir, pwroff, rx,
						//   bank0[7:4], pin30, pin31, 2'b0}
	output logic [63:0] anz_keys,		// {key4, key3, key2, key1}, as the console's pads take them
	output logic        anz_pocket_off,
	output logic  [3:0] anz_div		// the scandoubler's divider
`endif
);
	wire [35:0] ext_bus;
	assign ext_bus[31:16] = io_din;
	assign ext_bus[33] = io_strobe;
	assign ext_bus[34] = io_enable;
	assign ext_bus[35] = 1'b0;
	assign io_dout = ext_bus[15:0];
	assign io_wait = ext_bus[32];

	wire ce_pix, hs, vs, border, hbl, vbl;
	wire [7:0] r, g, b;
	// the players' controls in the Pocket's order (up, down, left, right, A, B, X, Y, L1, R1,
	// L2, R2, L3, R3, select, start): main.cpp's pad as player 1's, the others' none
	wire [15:0] cont1 = {pad[7], pad[6], 8'd0, 2'd0, pad[5], pad[4], pad[3], pad[2], pad[1], pad[0]};
	wire [15:0] k1, k2, k3, k4;
	wire        pocket_off;
`ifndef ANZ
	assign {k4, k3, k2, k1} = {48'd0, cont1};
	assign pocket_off = 1'b0;
`endif
	wire [15:0] dq;

	wire [21:16] cram_a;
	wire [15:0] cram_dq;
	wire cram_clk, cram_adv_n, cram_cre, cram_ce0_n, cram_oe_n, cram_we_n, cram_ub_n, cram_lb_n;

	psram_sim psram_sim (
		.clk(clk_sys), .a(cram_a), .dq(cram_dq), .cram_clk(cram_clk), .adv_n(cram_adv_n), .cre(cram_cre),
		.ce_n(cram_ce0_n), .oe_n(cram_oe_n), .we_n(cram_we_n), .ub_n(cram_ub_n), .lb_n(cram_lb_n),
		.violations(mb128_violations), .reads(), .writes()
	);

	wire [21:16] cram1_a;
	wire [15:0] cram1_dq;
	wire cram1_clk, cram1_adv_n, cram1_cre, cram1_ce0_n, cram1_oe_n, cram1_we_n, cram1_ub_n, cram1_lb_n;
	wire [31:0] mb128_violations, adpcm_violations;
	assign psram_violations = mb128_violations + adpcm_violations;

	psram_sim psram1_sim (
		.clk(clk_sys), .a(cram1_a), .dq(cram1_dq), .cram_clk(cram1_clk), .adv_n(cram1_adv_n), .cre(cram1_cre),
		.ce_n(cram1_ce0_n), .oe_n(cram1_oe_n), .we_n(cram1_we_n), .ub_n(cram1_ub_n), .lb_n(cram1_lb_n),
		.violations(adpcm_violations), .reads(adpcm_reads), .writes(adpcm_writes)
	);

	pce pce (
		.clk_sys_42_95(clk_sys),
		.clk_mem_85_91(clk_mem),
		.core_reset(core_reset),
		.pll_core_locked(1'b1),

		.p1_button_1(k1[4]), .p1_button_2(k1[5]), .p1_button_3(k1[6]), .p1_button_4(k1[7]),
		.p1_button_5(k1[8]), .p1_button_6(k1[9]), .p1_button_select(k1[14]), .p1_button_start(k1[15]),
		.p1_dpad_up(k1[0]), .p1_dpad_down(k1[1]), .p1_dpad_left(k1[2]), .p1_dpad_right(k1[3]),
		.p2_button_1(k2[4]), .p2_button_2(k2[5]), .p2_button_3(k2[6]), .p2_button_4(k2[7]),
		.p2_button_5(k2[8]), .p2_button_6(k2[9]), .p2_button_select(k2[14]), .p2_button_start(k2[15]),
		.p2_dpad_up(k2[0]), .p2_dpad_down(k2[1]), .p2_dpad_left(k2[2]), .p2_dpad_right(k2[3]),
		.p3_button_1(k3[4]), .p3_button_2(k3[5]), .p3_button_3(k3[6]), .p3_button_4(k3[7]),
		.p3_button_5(k3[8]), .p3_button_6(k3[9]), .p3_button_select(k3[14]), .p3_button_start(k3[15]),
		.p3_dpad_up(k3[0]), .p3_dpad_down(k3[1]), .p3_dpad_left(k3[2]), .p3_dpad_right(k3[3]),
		.p4_button_1(k4[4]), .p4_button_2(k4[5]), .p4_button_3(k4[6]), .p4_button_4(k4[7]),
		.p4_button_5(k4[8]), .p4_button_6(k4[9]), .p4_button_select(k4[14]), .p4_button_start(k4[15]),
		.p4_dpad_up(k4[0]), .p4_dpad_down(k4[1]), .p4_dpad_left(k4[2]), .p4_dpad_right(k4[3]),

		.sgx(1'b0),
		.AC_EN(ac_en),

		.turbo_tap_enable(1'b0),
		.button6_enable(1'b0),
		.button1_turbo_speed(2'b00),
		.button2_turbo_speed(2'b00),
		.overscan_enable(1'b0),
		.extra_sprites_enable(1'b0),
		.raw_rgb_enable(1'b0),
		.mb128_enable(mb128_en),
		.skip_run_enable(skip_run),
		.cd_audio_boost(1'b0),
		.adpcm_audio_boost(1'b0),
		.master_audio_boost(2'b00),

		.ioctl_wr(ioctl_wr),
		.ioctl_addr(24'd1),
		.ioctl_dout(ioctl_dout),
		.cart_download(cart_download),
		.hucard_download(hucard_download),
		.hucard(hucard),

		.sd_wr(sd_wr),
		.sd_rd(sd_rd),
		.sd_buff_addr(sd_buff_addr),
		.sd_lba(sd_lba),
		.sd_buff_dout(sd_buff_dout),
		.sd_buff_din(sd_buff_din),
		.save_download(save_download),

		.dram_a(), .dram_ba(), .dram_dq(dq), .dram_dqm(), .dram_clk(), .dram_cke(),
		.dram_ras_n(), .dram_cas_n(), .dram_we_n(),

		.cram0_a(cram_a), .cram0_dq(cram_dq), .cram0_clk(cram_clk), .cram0_adv_n(cram_adv_n),
		.cram0_cre(cram_cre), .cram0_ce0_n(cram_ce0_n), .cram0_ce1_n(), .cram0_oe_n(cram_oe_n),
		.cram0_we_n(cram_we_n), .cram0_ub_n(cram_ub_n), .cram0_lb_n(cram_lb_n),
		.cram1_a(cram1_a), .cram1_dq(cram1_dq), .cram1_clk(cram1_clk), .cram1_adv_n(cram1_adv_n),
		.cram1_cre(cram1_cre), .cram1_ce0_n(cram1_ce0_n), .cram1_ce1_n(), .cram1_oe_n(cram1_oe_n),
		.cram1_we_n(cram1_we_n), .cram1_ub_n(cram1_ub_n), .cram1_lb_n(cram1_lb_n),
		.psram_ready(psram_ready),
		.psram_mem_ok(psram_mem_ok),

		.ce_pix(ce_pix),
		.hsync(hs),
		.vsync(vs),
		.hblank(hbl),
		.vblank(vbl),
		.video_r(r),
		.video_g(g),
		.video_b(b),
		.border(border),

		.audio_l(audio_l),
		.audio_r(audio_r),

		.EXT_BUS(ext_bus),

		.SS_SAVE(ss_save), .SS_LOAD(ss_load), .SS_MENU(1'b0), .SS_CMD_NEW(1'b0), .SS_CMD(17'd0), .SS_GO(ss_go), .SS_STATUS(ss_status),
		.SS_ADDR(ss_addr), .SS_RD(ss_rd), .SS_DO(ss_do), .SS_WR(ss_wr), .SS_DI(ss_di),
		.SS_CARD_SIZE(ss_card_size), .SS_CARD_SUM(ss_card_sum), .SS_HU_SIZE(ss_hu_size), .SS_HU_SUM(ss_hu_sum), .SS_WORDS(ss_words),
		.SS_DRV_PARK(drv_park), .SS_DRV_IN(drv_in), .SS_DRV_LOAD(drv_load), .SS_REFUSED(ss_refused), .SS_MB128_ON(ss_mb128_on), .SS_AC_ON(ss_ac_on), .SS_DRV_PARKED(drv_parked), .SS_DRV_RESTORED(drv_restored)
	);

	assign dbg_vdc_regs = pce.pce_top.chip.vdc0.regs;
	assign dbg_cpu_a = pce.pce_top.chip.cpu_a;
	assign dbg_cpu_sync = pce.ss_sync;
	assign dbg_cpu_sp = pce.pce_top.chip.cpu.core.sp;
	assign dbg_cd = {pce.pce_top.chip.cd.irq_n, pce.pce_top.chip.cd.cd_dtr_en, pce.pce_top.chip.cd.cd_dtr,
		pce.pce_top.chip.cd.cd_dtd_en, pce.pce_top.chip.cd.cd_dtd, pce.pce_top.chip.cd.cd_subcd_en, pce.pce_top.chip.cd.cd_subcd,
		pce.pce_top.chip.cd.adpcm_end_en, pce.pce_top.chip.cd.adpcm_end, pce.pce_top.chip.cd.adpcm_half_en, pce.pce_top.chip.cd.adpcm_half,
		pce.pce_top.chip.cd.scsi_req_n};
`ifdef VDC_TRACE
	// SIM_VFLAGS=-DVDC_TRACE: each change of the VDC's CR or RCR, its RCR interrupt and its
	// per-line BB/SB latch, with where in the line and frame it fell (the window step, 9 Nov 2026)
	logic [31:0] vt_clk = 0, vt_frame = 0, vt_irq_at = 0;
	logic vt_vs = 0, vt_irq = 0, vt_bb = 0, vt_sb = 0;
	logic [15:0] vt_cr = 0, vt_rcr = 0;
	wire [15:0] vt_cr_now  = pce.pce_top.chip.vdc0.regs[(31-5)*16 +: 16];
	wire [15:0] vt_rcr_now = pce.pce_top.chip.vdc0.regs[(31-6)*16 +: 16];
	`define VT_WHERE vt_frame, vt_clk, pce.pce_top.chip.vdc0.disp_cnt, pce.pce_top.chip.vdc0.rc_cnt, \
		pce.pce_top.chip.vdc0.tile_cnt, pce.pce_top.chip.vdc0.dot_cnt, pce.pce_top.chip.vdc0.hds_end_pos, pce.pce_top.chip.vdc0.hdisp_end_pos
	always @(posedge clk_sys) begin
		vt_clk <= vt_clk + 1;
		vt_vs <= vs;
		if (vs && !vt_vs) vt_frame <= vt_frame + 1;
		vt_irq <= pce.pce_top.chip.vdc0.irq_rcr;
		vt_bb <= pce.pce_top.chip.vdc0.bb; vt_sb <= pce.pce_top.chip.vdc0.sb;
		vt_cr <= vt_cr_now; vt_rcr <= vt_rcr_now;
		if (pce.pce_top.chip.vdc0.irq_rcr && !vt_irq) begin
			vt_irq_at <= vt_clk;
			$display("vt %0d %0d irq   disp %0d rc %03x tile %0d.%0d hds %0d hdisp %0d", `VT_WHERE);
		end
		if (vt_cr_now != vt_cr)
			$display("vt %0d %0d cr %04x disp %0d rc %03x tile %0d.%0d hds %0d hdisp %0d  +%0d from irq", vt_frame, vt_clk, vt_cr_now,
				pce.pce_top.chip.vdc0.disp_cnt, pce.pce_top.chip.vdc0.rc_cnt, pce.pce_top.chip.vdc0.tile_cnt, pce.pce_top.chip.vdc0.dot_cnt,
				pce.pce_top.chip.vdc0.hds_end_pos, pce.pce_top.chip.vdc0.hdisp_end_pos, vt_clk - vt_irq_at);
		if (vt_rcr_now != vt_rcr)
			$display("vt %0d %0d rcr %03x disp %0d rc %03x tile %0d.%0d hds %0d hdisp %0d", vt_frame, vt_clk, vt_rcr_now[9:0],
				pce.pce_top.chip.vdc0.disp_cnt, pce.pce_top.chip.vdc0.rc_cnt, pce.pce_top.chip.vdc0.tile_cnt, pce.pce_top.chip.vdc0.dot_cnt,
				pce.pce_top.chip.vdc0.hds_end_pos, pce.pce_top.chip.vdc0.hdisp_end_pos);
		if (pce.pce_top.chip.vdc0.bb != vt_bb || pce.pce_top.chip.vdc0.sb != vt_sb)
			$display("vt %0d %0d latch bb %0d sb %0d disp %0d rc %03x tile %0d.%0d hds %0d hdisp %0d", vt_frame, vt_clk,
				pce.pce_top.chip.vdc0.bb, pce.pce_top.chip.vdc0.sb, pce.pce_top.chip.vdc0.disp_cnt, pce.pce_top.chip.vdc0.rc_cnt,
				pce.pce_top.chip.vdc0.tile_cnt, pce.pce_top.chip.vdc0.dot_cnt, pce.pce_top.chip.vdc0.hds_end_pos, pce.pce_top.chip.vdc0.hdisp_end_pos);
	end
	// and every dot of line 120 of frame 100 as it reaches the line buffer: the border flag, the
	// colour and whether the line buffer takes it
	logic [9:0] vt_line = 0; logic vt_hs = 0;
	always @(posedge clk_sys) begin
		vt_hs <= hs;
		if (vs && !vt_vs) vt_line <= 0; else if (hs && !vt_hs) vt_line <= vt_line + 1;
		if (vt_frame == 100 && vt_line == 120 && (ce_pix || linebuffer.bank_write))
			$display("vd ce %0d border %0d rgb %02x%02x%02x write %0d", ce_pix, border, r, g, b, linebuffer.bank_write);
	end
`endif
	assign chip_snd = {pce.psg_sl, pce.psg_sr, pce.cdda_sl, pce.cdda_sr, pce.adpcm_s};
	assign mb128_state = pce.MB128.r_State;
	assign mb128_req   = pce.MB128.r_Req;
	assign mb128_addr  = pce.MB128.r_MB128_Addr;
	assign mb128_bits  = pce.MB128.r_MB128_Bits;

`ifdef ANZ
	// ---- the Analogizer, as core_top.v has it (the bridge's clock is clk_sys here) ----
	wire [7:0] cb3, cb2, cb1;
	wire [7:4] cb0;
	wire       cp30, cp31;
	wire       cb3d, cb2d, cb1d, cb0d, cp30d, cp31d, cpwr, rx;
	pocket_analogizer analogizer (
		.clk_74a(clk_sys), .bridge_wr(anz_wr), .bridge_addr(anz_wr ? 32'hF7000000 : 32'h0), .bridge_wr_data(anz_data),
		.clk_sys(clk_sys), .ce_pix(ce_pix), .hs(hs), .vs(vs), .hblank(hbl), .vblank(vbl),
		.r(r), .g(g), .b(b), .pocket_off(pocket_off),
		.cont1_key(cont1), .cont2_key(16'd0), .cont3_key(16'd0), .cont4_key(16'd0),
		.key1(k1), .key2(k2), .key3(k3), .key4(k4),
		.uart_tx(anz_tx), .uart_rx(rx),
		.cart_tran_bank2(cb2), .cart_tran_bank2_dir(cb2d), .cart_tran_bank3(cb3), .cart_tran_bank3_dir(cb3d),
		.cart_tran_bank1(cb1), .cart_tran_bank1_dir(cb1d), .cart_tran_bank0(cb0), .cart_tran_bank0_dir(cb0d),
		.cart_tran_pin30(cp30), .cart_tran_pin30_dir(cp30d), .cart_pin30_pwroff_reset(cpwr),
		.cart_tran_pin31(cp31), .cart_tran_pin31_dir(cp31d)
	);
	assign anz_banks = {cb3, cb2, cb1};
	assign anz_misc = {cb3d, cb2d, cb1d, cb0d, cp30d, cp31d, cpwr, rx, cb0, cp30, cp31, 2'b0};
	assign anz_keys = {k4, k3, k2, k1};
	assign anz_pocket_off = pocket_off;
	assign anz_div = analogizer.sd_div;

	// PC Engine pads at the slot, answering CLR (bank1[6]) and SEL (bank1[7]) on D0 bank0[7],
	// D1 pin31, D2 bank0[4] and D3 bank0[5] (openFPGA_Pocket_Analogizer_SNAC.sv's
	// Configuration A): SEL high the d-pad (up, right, down, left), low the buttons (I, II,
	// Select, Run), a held button low, CLR high all low. A 6-button pad changes set on each
	// CLR, its second set 0000 with SEL high and III to VI with SEL low. A multitap's port
	// steps on SEL's rise and goes back to the first on CLR, and it passes the port's pad on
	// with CLR high too (the module's multitap reader takes port 1's d-pad then, as it does
	// on the hardware it was tried on). No pad: the lines float high.
	logic       clr_d = 0, sel_d = 0, set6 = 0;
	logic [2:0] port = 0;
	always @(posedge clk_sys) begin
		clr_d <= cb1[6]; sel_d <= cb1[7];
		if (cb1[6] && !clr_d) set6 <= ~set6;
		if (cb1[6]) port <= 0;
		else if (cb1[7] && !sel_d && port != 3'd7) port <= port + 3'd1;
	end
	wire [11:0] held = anz_pad_type == 2'd3 ? (port < 3'd5 ? anz_held[port * 12 +: 12] : 12'd0) : anz_held[11:0];
	wire        ext = anz_pad_type == 2'd2 && set6;
	wire [3:0]  d = anz_pad_type == 2'd0 ? 4'hF :
	                (cb1[6] && anz_pad_type != 2'd3) ? 4'h0 :
	                (anz_pad_type == 2'd3 && port >= 3'd5) ? 4'h0 :
	                ext ? (cb1[7] ? 4'h0 : ~held[11:8]) :
	                (cb1[7] ? ~held[3:0] : ~held[7:4]);
	assign cb0  = cb0d  ? 4'bzzzz : {d[0], 1'b1, d[3], d[2]};
	assign cp31 = cp31d ? 1'bz    : d[1];
`endif

	linebuffer linebuffer (
		.clk_vid(clk_sys),
		.vsync_in(vs),
		.hsync_in(hs),
		.ce_pix(ce_pix),
		.disable_pix(border),
		.rgb_in(pocket_off ? 24'd0 : {r, g, b}),
		.vsync_out(video_vs),
		.hsync_out(video_hs),
		.slot(),
		.de(video_de),
		.rgb_out(video_rgb)
	);
endmodule
