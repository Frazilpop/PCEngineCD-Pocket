// The ADPCM chip's 128K nibbles, in the second PSRAM chip, which nothing else uses.
//
// MiSTer keeps them in block RAM (cd.vhd's ADPCM_DRAM, 64 M10K of the chip's 308). The real
// console has a DRAM there and cd.vhd's slots model it: one access every 18 clocks of 42.95
// MHz at most, an address that holds for the whole slot and read data taken at its end. A read
// here is 9 clocks and a write 8, so this chip answers inside the same slot, on the same
// clock, and nothing outside this module and cd.vhd's ports can tell the difference. The
// one exception: cd.vhd takes the read's address at clock 9 of the 18 where block RAM took it
// at 17, so a CPU write to the read address landing in those 8 clocks gets the old address's
// nibble for that one read, which a game can't aim for and could only just hear.
//
// A SLOT, each number being cd.vhd's DRAM_CLK_CNT, 0 being the clock DRAM_CLKEN is high:
//   a write: taken at 0, CE# ADV# and the address out at 1, done by 7, nothing moving by 8
//   a read:  taken at 9 (ADRAM_RD), address out at 10, OE# at 13, the data taken at 17, so
//            read_data is good at 0, the clock cd.vhd uses it
// A write slot is always followed by a slot that doesn't start before 9. The slot order
// (cd.vhd) is refresh, write, write, read.
//
// THE PART, the bus cycles and the mode set first are as mb128_psram.sv, which says why. The
// two nibbles of a byte share a word, one in the low four bits of each lane, so a write
// touches its own lane alone and the 64K words clear in the time mb128_psram.sv takes: start-up
// is to the clock what it was before this chip had anything to do.
//
// THE START, also as mb128_psram.sv: power-up time, the BCR, two words above the nibbles
// written and read back (mem_ok), then all clear, as block RAM starts. Block RAM keeps its
// contents through a reset and so does this: the clear is only here. About 12 ms.

module adpcm_psram (
	input  wire         clk,
	input  wire         locked,

	output wire         ready,
	output reg          mem_ok = 0,

	// cd.vhd's ADPCM_DRAM port
	input  wire [16:0]  a,
	input  wire [3:0]   din,
	input  wire         we,
	input  wire         rd,
	output reg  [3:0]   dout = 0,

	// a save state's port (state_engine.sv), while cd.vhd is held: a byte, the two nibbles
	// of one word, the even nibble (the one cd.vhd writes first) in the byte's top four bits;
	// a strobe starts it, and it's done in nine clocks
	input  wire [15:0]  ss_a,
	input  wire [7:0]   ss_d,
	input  wire         ss_we,
	input  wire         ss_rd,
	output wire [7:0]   ss_q,

	output reg  [21:16] cram_a = 0,
	inout  wire [15:0]  cram_dq,
	output wire         cram_clk,
	output reg          cram_adv_n = 1,
	output reg          cram_cre = 0,
	output wire         cram_ce0_n,
	output wire         cram_ce1_n,
	output reg          cram_oe_n = 1,
	output reg          cram_we_n = 1,
	output reg          cram_ub_n = 1,
	output reg          cram_lb_n = 1
);

localparam [15:0] BCR_ASYNC = 16'h9D1F;
localparam [12:0] POWER_UP  = 13'd6500;		// 150 us

reg        ce_n = 1;
reg        dq_oe = 0;
reg [15:0] dq_o = 0;

assign cram_clk   = 1'b0;
assign cram_ce0_n = ce_n;
assign cram_ce1_n = 1'b1;
assign cram_dq    = dq_oe ? dq_o : 16'hZZZZ;

localparam [1:0] OP_NONE = 2'd0, OP_WRITE = 2'd1, OP_READ = 2'd2, OP_BCR = 2'd3;

reg  [1:0]  op = OP_NONE;
reg  [3:0]  n = 1;
reg  [16:0] op_a = 0;
reg         op_hi = 0;			// a[0] of this access: the high lane
reg         op_both = 0;		// the BCR, the test words and the clear take both lanes
reg  [15:0] op_d = 0;
reg  [15:0] op_q = 0;
reg         op_done = 0;

localparam [3:0] S_POWER = 0, S_BCR = 1, S_T0 = 2, S_T1 = 3, S_T0R = 4, S_T1R = 5, S_CLEAR0 = 6,
                 S_CLEAR = 7, S_RUN = 8;

reg  [3:0]  s = S_POWER;
reg  [12:0] power = 0;
reg  [15:0] clear_a = 0;

// From the state, not a register of its own (mb128_psram.sv says what Quartus does with one).
// S_RUN alone has bit 3 set.
assign ready = s[3];

assign ss_q = {op_q[3:0], op_q[11:8]};

task start(input [1:0] what, input [16:0] addr, input [15:0] d);
	op      <= what;
	op_a    <= addr;
	op_d    <= d;
	op_both <= 1;
endtask

task nibble(input [1:0] what);
	op      <= what;
	op_a    <= {1'b0, a[16:1]};
	op_d    <= {4'd0, din, 4'd0, din};
	op_hi   <= a[0];
	op_both <= 0;
endtask

always @(posedge clk) begin
	op_done <= 0;
	if (op != OP_NONE) begin
		n <= n + 1'd1;
		case (n)
		4'd1: begin
			cram_cre   <= (op == OP_BCR);
			ce_n       <= 0;
			cram_adv_n <= 0;
			cram_we_n  <= (op == OP_READ);
			cram_ub_n  <= ~(op_both | op_hi);
			cram_lb_n  <= ~(op_both | ~op_hi);
			cram_a     <= (op == OP_BCR) ? 6'b00_10_00 : {5'd0, op_a[16]};
			dq_o       <= (op == OP_BCR) ? BCR_ASYNC : op_a[15:0];
			dq_oe      <= 1;
		end
		4'd2: cram_adv_n <= 1;
		4'd3: begin
			dq_o  <= op_d;
			dq_oe <= (op != OP_READ);
		end
		4'd4: cram_oe_n <= (op != OP_READ);
		4'd6: if (op != OP_READ) begin
			cram_we_n <= 1;
			ce_n      <= 1;
		end
		4'd7: if (op != OP_READ) begin
			dq_oe     <= 0;
			cram_ub_n <= 1;
			cram_lb_n <= 1;
			cram_cre  <= 0;
			op        <= OP_NONE;
			op_done   <= 1;
			n         <= 1;
		end
		4'd8: begin
			op_q      <= cram_dq;
			ce_n      <= 1;
			cram_oe_n <= 1;
			cram_ub_n <= 1;
			cram_lb_n <= 1;
			op        <= OP_NONE;
			op_done   <= 1;
			n         <= 1;
			if (s == S_RUN) dout <= op_hi ? cram_dq[11:8] : cram_dq[3:0];
		end
		default: ;
		endcase
	end

	case (s)
	S_POWER: if (locked) begin
		power <= power + 1'd1;
		if (power == POWER_UP) begin
			start(OP_BCR, 17'd0, 16'd0);
			s <= S_BCR;
		end
	end
	S_BCR: if (op_done) begin
		start(OP_WRITE, 17'h10000, 16'hA55A);
		s <= S_T0;
	end
	S_T0: if (op_done) begin
		start(OP_WRITE, 17'h10001, 16'h5AA5);
		s <= S_T1;
	end
	S_T1: if (op_done) begin
		start(OP_READ, 17'h10000, 16'd0);
		s <= S_T0R;
	end
	S_T0R: if (op_done) begin
		mem_ok <= (op_q == 16'hA55A);
		start(OP_READ, 17'h10001, 16'd0);
		s <= S_T1R;
	end
	S_T1R: if (op_done) begin
		mem_ok <= mem_ok & (op_q == 16'h5AA5);
		s <= S_CLEAR0;
	end
	S_CLEAR0: begin
		clear_a <= 16'd1;
		start(OP_WRITE, 17'd0, 16'd0);
		s <= S_CLEAR;
	end
	S_CLEAR: if (op_done) begin
		if (clear_a == 16'd0) begin
			s <= S_RUN;
		end else begin
			clear_a <= clear_a + 1'd1;
			start(OP_WRITE, {1'b0, clear_a}, 16'd0);
		end
	end
	S_RUN: begin
		// cd.vhd's slots keep these apart: see the top of this file
		if (we) nibble(OP_WRITE);
		else if (rd) nibble(OP_READ);
		else if (ss_we) start(OP_WRITE, {1'b0, ss_a}, {4'd0, ss_d[3:0], 4'd0, ss_d[7:4]});
		else if (ss_rd) start(OP_READ, {1'b0, ss_a}, 16'd0);
	end
	default: s <= S_RUN;
	endcase
end

endmodule
