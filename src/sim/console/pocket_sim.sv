// The Pocket's side of a save state, a Verilator model of its own beside sim_top (main.cpp's
// --pocket): state_bridge.sv on both clocks as core_top.v joins it, and the drive's block
// (the file's 0x800 to 0xFFF) as core_top.v serves it: the MPU's RAM, controller_rom.v's
// Main_Bram with its blk_rd, the address remapped to 0xF000 and the 0x4 window's read mux.
// The firmware in drive.cpp reads and writes the block straight in this RAM (main.cpp points
// the drive's block at it), as the MPU's own port would.

module pocket_bridge (
	input  wire        clk_74a,
	input  wire        clk_sys,
	input  wire        mpu_reset_n,			// the Pocket's reset, as the MPU has it

	input  wire [31:0] bridge_addr,
	input  wire        bridge_rd,
	output wire [31:0] bridge_rd_data,		// the 0x4 window's, as core_top.v muxes it
	input  wire        bridge_wr,
	input  wire [31:0] bridge_wr_data,

	input  wire        savestate_start,
	output wire        savestate_start_ack,
	output wire        savestate_start_busy,
	output wire        savestate_start_ok,
	output wire        savestate_start_err,
	input  wire        savestate_load,
	output wire        savestate_load_ack,
	output wire        savestate_load_busy,
	output wire        savestate_load_ok,
	output wire        savestate_load_err,

	input  wire [31:0] card_size,
	input  wire [31:0] card_sum,
	input  wire        mb128_on,
	input  wire        ac_on,
	input  wire [20:0] ss_words,

	output wire        ss_save,
	output wire        ss_load,
	output wire        ss_go,
	input  wire  [1:0] ss_status,
	output wire [20:0] ss_addr,
	output wire        ss_rd,
	input  wire [15:0] ss_do,
	output wire        ss_wr,
	output wire [15:0] ss_di
);
	// ---- core_top.v's, line for line ----
	wire        ss_blk_addr = bridge_addr[31:11] == 21'h080001;	// 0x40000800 to 0x40000FFF
	wire [31:0] mpu_bridge_addr = ss_blk_addr ? {20'h8000F, 1'b0, bridge_addr[10:0]} : bridge_addr;
	wire [31:0] ss_blk_q, ss_bridge_rd_data;
	reg         ss_blk_rd = 0, ss_blk_last = 0, ss_rd_old = 0;
	always @(posedge clk_74a) begin
		ss_rd_old <= bridge_rd;
		ss_blk_rd <= 0;
		if (bridge_rd & ~ss_rd_old && bridge_addr[31:28] == 4'h4) begin
			ss_blk_last <= ss_blk_addr;
			ss_blk_rd <= ss_blk_addr;
		end
	end
	assign bridge_rd_data = ss_blk_last ? ss_blk_q : ss_bridge_rd_data;

	state_bridge state_bridge (
		.clk_74a(clk_74a),
		.clk_sys(clk_sys),
		.bridge_endian_little(1'b0),
		.bridge_addr(bridge_addr),
		.bridge_rd(bridge_rd),
		.bridge_rd_data(ss_bridge_rd_data),
		.bridge_wr(bridge_wr),
		.bridge_wr_data(bridge_wr_data),
		.savestate_start(savestate_start),
		.savestate_start_ack(savestate_start_ack),
		.savestate_start_busy(savestate_start_busy),
		.savestate_start_ok(savestate_start_ok),
		.savestate_start_err(savestate_start_err),
		.savestate_load(savestate_load),
		.savestate_load_ack(savestate_load_ack),
		.savestate_load_busy(savestate_load_busy),
		.savestate_load_ok(savestate_load_ok),
		.savestate_load_err(savestate_load_err),
		.card_size(card_size),
		.card_sum(card_sum),
		.mb128_on(mb128_on),
		.ac_on(ac_on),
		.ss_words(ss_words),
		.ss_save(ss_save),
		.ss_load(ss_load),
		.ss_go(ss_go),
		.ss_status(ss_status),
		.ss_addr(ss_addr),
		.ss_rd(ss_rd),
		.ss_do(ss_do),
		.ss_wr(ss_wr),
		.ss_di(ss_di),
		.pause_lift()
	);

	// ---- MPU_AFP_CORE.v's Main_Bram, its CPU side idle (the firmware is drive.cpp's) ----
	controller_rom #(
		.mpu_address(8'h00),
		.aft_address(8'h80),
		.address_size(14),				// MPU_BRAM_SIZE, 64K
		.aft_master(1'b0)
	) Main_Bram (
		.clk(clk_74a),
		.reset_n(mpu_reset_n),
		.iBus_cmd_payload_pc(24'd0),
		.iBus_rsp_payload_inst(),
		.iBus_cmd_valid(1'b0),
		.iBus_rsp_valid(),
		.iBus_cmd_ready(),
		.data_addr(32'd0),
		.data_d(32'd0),
		.data_q(),
		.data_we(1'b0),
		.dBus_cmd_valid(1'b0),
		.data_bytesel(2'd0),
		.little_enden(1'b0),				// the firmware never sets MPU_AFP_CORE's littlenden
		.clk_74a(clk_74a),
		.bridge_addr(mpu_bridge_addr),
		.bridge_rd(bridge_rd),
		.bridge_rd_data(),
		.bridge_wr(bridge_wr),
		.blk_rd(ss_blk_rd),
		.blk_addr({12'h00F, 1'b0, bridge_addr[10:0]}),
		.blk_q(ss_blk_q),
		.bridge_wr_data(bridge_wr_data)
	);
endmodule

// Intel's dcfifo for data_loader.sv (Genesis-Pocket's stand-in): two clocks, no
// showahead, rdempty straight from the pointers.
module dcfifo #(
	parameter clocks_are_synchronized = "FALSE",
	parameter intended_device_family = "Cyclone V",
	parameter lpm_numwords = 4,
	parameter lpm_showahead = "OFF",
	parameter lpm_type = "dcfifo",
	parameter lpm_width = 8,
	parameter lpm_widthu = 2,
	parameter overflow_checking = "OFF",
	parameter rdsync_delaypipe = 5,
	parameter underflow_checking = "OFF",
	parameter use_eab = "OFF",
	parameter wrsync_delaypipe = 5
) (
	input  wire [lpm_width-1:0] data,
	input  wire                 rdclk,
	input  wire                 rdreq,
	input  wire                 wrclk,
	input  wire                 wrreq,
	output reg  [lpm_width-1:0] q,
	output wire                 rdempty,
	input  wire                 aclr,
	output wire                 eccstatus,
	output wire                 rdfull,
	output wire [lpm_widthu-1:0] rdusedw,
	output wire                 wrempty,
	output wire                 wrfull,
	output wire [lpm_widthu-1:0] wrusedw
);
	reg [lpm_width-1:0] mem [0:15];
	reg [4:0] wp = 0, rp = 0;
	assign rdempty = wp == rp;
	always @(posedge wrclk) if (wrreq) begin mem[wp[3:0]] <= data; wp <= wp + 1; end
	always @(posedge rdclk) if (rdreq && !rdempty) begin q <= mem[rp[3:0]]; rp <= rp + 1; end
endmodule

// Intel's altsyncram as controller_rom.v's dbram has it: two ports of 32 bits, each address
// registered, the outputs not; port A's bytes enabled one by one
module altsyncram #(
	parameter wrcontrol_wraddress_reg_b = "CLOCK1",
	parameter address_reg_b = "CLOCK1",
	parameter indata_reg_b = "CLOCK1",
	parameter numwords_a = 16384,
	parameter numwords_b = 16384,
	parameter widthad_a = 14,
	parameter widthad_b = 14,
	parameter width_a = 32,
	parameter width_b = 32,
	parameter width_byteena_a = 4,
	parameter width_byteena_b = 1,
	parameter clock_enable_input_a = "NORMAL",
	parameter clock_enable_input_b = "NORMAL",
	parameter clock_enable_output_a = "BYPASS",
	parameter clock_enable_output_b = "BYPASS",
	parameter intended_device_family = "Cyclone V",
	parameter lpm_type = "altsyncram",
	parameter operation_mode = "BIDIR_DUAL_PORT",
	parameter outdata_aclr_a = "NONE",
	parameter outdata_aclr_b = "NONE",
	parameter outdata_reg_a = "UNREGISTERED",
	parameter outdata_reg_b = "UNREGISTERED",
	parameter power_up_uninitialized = "FALSE",
	parameter read_during_write_mode_mixed_ports = "DONT_CARE",
	parameter read_during_write_mode_port_a = "NEW_DATA_NO_NBE_READ",
	parameter read_during_write_mode_port_b = "NEW_DATA_NO_NBE_READ"
) (
	input  wire [widthad_a-1:0] address_a,
	input  wire [widthad_b-1:0] address_b,
	input  wire clock0,
	input  wire clock1,
	input  wire [width_a-1:0] data_a,
	input  wire [width_b-1:0] data_b,
	input  wire wren_a,
	input  wire wren_b,
	output wire [width_a-1:0] q_a,
	output wire [width_b-1:0] q_b,
	input  wire aclr0, aclr1, addressstall_a, addressstall_b,
	input  wire [width_byteena_a-1:0] byteena_a,
	input  wire [width_byteena_b-1:0] byteena_b,
	input  wire clocken0, clocken1, clocken2, clocken3,
	output wire eccstatus,
	input  wire rden_a,
	input  wire rden_b
);
	reg [31:0] mem [0:numwords_a-1] /*verilator public_flat_rw*/;
	reg [widthad_a-1:0] ra = 0;
	reg [widthad_b-1:0] rb = 0;
	integer i;
	always @(posedge clock0) begin
		ra <= address_a;
		if (wren_a) for (i = 0; i < 4; i = i + 1) if (byteena_a[i]) mem[address_a][8*i +: 8] <= data_a[8*i +: 8];
	end
	always @(posedge clock1) begin
		rb <= address_b;
		if (wren_b) mem[address_b] <= data_b;
	end
	assign q_a = mem[ra];
	assign q_b = mem[rb];
endmodule
