// main.sv's pce, as core_top.v joins it, for Verilator: the real module and the real
// line buffer, with the bus to the MPU and the pads brought out for main.cpp. Core
// Settings at core_top.v's reset values (all off).

module sim_top (
	input  logic clk_sys,
	input  logic clk_mem,
	input  logic core_reset,

	input  logic cart_download,
	input  logic ioctl_wr,
	input  logic [15:0] ioctl_dout,

	input  logic ac_en,
	input  logic mb128_en,

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
	output logic [20:0] ss_words,
	// the chips' own sound, before the filters: {psg_sl, psg_sr, cdda_sl, cdda_sr, adpcm_s}
	output logic [79:0] chip_snd,
	// for SIM_SSDBG: the VDC's registers
	output logic [511:0] dbg_vdc_regs,
	output logic [20:0] dbg_cpu_a,		// SIM_PCTRACE: the CPU's address, and its opcode fetch
	output logic        dbg_cpu_sync,
	output logic [11:0] dbg_cd,		// SIM_PCTRACE: the CD's interrupt and its sources
	output logic  [7:0] dbg_cpu_sp
);
	wire [35:0] ext_bus;
	assign ext_bus[31:16] = io_din;
	assign ext_bus[33] = io_strobe;
	assign ext_bus[34] = io_enable;
	assign ext_bus[35] = 1'b0;
	assign io_dout = ext_bus[15:0];
	assign io_wait = ext_bus[32];

	wire ce_pix, hs, vs, border;
	wire [7:0] r, g, b;
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

		.p1_button_1(pad[4]), .p1_button_2(pad[5]), .p1_button_3(1'b0), .p1_button_4(1'b0),
		.p1_button_5(1'b0), .p1_button_6(1'b0), .p1_button_select(pad[6]), .p1_button_start(pad[7]),
		.p1_dpad_up(pad[0]), .p1_dpad_down(pad[1]), .p1_dpad_left(pad[2]), .p1_dpad_right(pad[3]),
		.p2_button_1(1'b0), .p2_button_2(1'b0), .p2_button_3(1'b0), .p2_button_4(1'b0),
		.p2_button_5(1'b0), .p2_button_6(1'b0), .p2_button_select(1'b0), .p2_button_start(1'b0),
		.p2_dpad_up(1'b0), .p2_dpad_down(1'b0), .p2_dpad_left(1'b0), .p2_dpad_right(1'b0),
		.p3_button_1(1'b0), .p3_button_2(1'b0), .p3_button_3(1'b0), .p3_button_4(1'b0),
		.p3_button_5(1'b0), .p3_button_6(1'b0), .p3_button_select(1'b0), .p3_button_start(1'b0),
		.p3_dpad_up(1'b0), .p3_dpad_down(1'b0), .p3_dpad_left(1'b0), .p3_dpad_right(1'b0),
		.p4_button_1(1'b0), .p4_button_2(1'b0), .p4_button_3(1'b0), .p4_button_4(1'b0),
		.p4_button_5(1'b0), .p4_button_6(1'b0), .p4_button_select(1'b0), .p4_button_start(1'b0),
		.p4_dpad_up(1'b0), .p4_dpad_down(1'b0), .p4_dpad_left(1'b0), .p4_dpad_right(1'b0),

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
		.cd_audio_boost(1'b0),
		.adpcm_audio_boost(1'b0),
		.master_audio_boost(2'b00),

		.ioctl_wr(ioctl_wr),
		.ioctl_addr(24'd1),
		.ioctl_dout(ioctl_dout),
		.cart_download(cart_download),

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
		.hblank(),
		.vblank(),
		.video_r(r),
		.video_g(g),
		.video_b(b),
		.border(border),

		.audio_l(audio_l),
		.audio_r(audio_r),

		.EXT_BUS(ext_bus),

		.SS_SAVE(ss_save), .SS_LOAD(ss_load), .SS_MENU(1'b0), .SS_CMD_NEW(1'b0), .SS_CMD(17'd0), .SS_GO(ss_go), .SS_STATUS(ss_status),
		.SS_ADDR(ss_addr), .SS_RD(ss_rd), .SS_DO(ss_do), .SS_WR(ss_wr), .SS_DI(ss_di),
		.SS_CARD_SIZE(ss_card_size), .SS_CARD_SUM(ss_card_sum), .SS_WORDS(ss_words),
		.SS_DRV_PARK(drv_park), .SS_DRV_IN(drv_in), .SS_DRV_LOAD(drv_load), .SS_MB128_ON(ss_mb128_on), .SS_AC_ON(ss_ac_on), .SS_DRV_PARKED(drv_parked), .SS_DRV_RESTORED(drv_restored)
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

	linebuffer linebuffer (
		.clk_vid(clk_sys),
		.vsync_in(vs),
		.hsync_in(hs),
		.ce_pix(ce_pix),
		.disable_pix(border),
		.rgb_in({r, g, b}),
		.vsync_out(video_vs),
		.hsync_out(video_hs),
		.slot(),
		.de(video_de),
		.rgb_out(video_rgb)
	);
endmodule
