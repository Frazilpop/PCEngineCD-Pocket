// The Memory Base 128's 128 KB, in the first PSRAM chip's first die.
//
// MiSTer keeps it in block RAM (rtl/mb128.sv's dpram_difclk, about 105 M10K), and this
// chip had 7 free. Nothing else uses this PSRAM chip (the ADPCM chip's memory is on the
// other, adpcm_psram.sv), so nothing here can get in the way of the console's own memory, and the protocol is slow enough to have no need of speed:
// the fastest a CPU can clock a bit is about 70 of these clocks, and the longest this
// takes between two bits is a write and a read, 18.
//
// THE PART. AS1C8M16PL-70: 70 ns, the low sixteen address bits on the DQ pins, latched
// by ADV#. Asynchronous, the clock pin held low.
//
// THE MODE. Another core may have left the part in synchronous bursts (Cave 68000 does,
// BCR 0x5C1F) and the Pocket's PSRAM may stay powered between cores, so the BCR is
// written first, whatever it was: 0x9D1F, the part's own default, with CRE high and the
// value on the address lines (A19:18 = 10 says BCR).
//
// THE START. Power-up time; the BCR; two words written and read back above the MB128's
// 128 KB (mem_ok, the firmware's to show). ready goes high after that, about 0.2 ms in, and
// core_top.v holds its boot status until then, as the save can come straight after boot.
//
// NO CLEAR. Whatever the last core left in the chip must read as 0, so that an old 2K save
// leaves an unformatted MB128. Up to 8 Nov 2026 the chip was cleared word by word, 14 ms,
// with the boot status held until the clear was done, as the save mustn't land under it;
// the Pocket gave "Error in framework, RS: Host commands ignored" on many starts from the
// first build that held it (4 Nov), and on none before. Now each word has a bit
// in block RAM, `written`, set by any write and 0 at every load of the core, as block RAM
// starts; a read of a word never written gives 0, whatever the chip holds.
//
// THE MB128'S SIDE is a bit address and one word of it held here, written through bit by
// bit, so a read of the save always sees the chip, and mb_dout is good a clock after the
// address within a word and 11 clocks after it crossing into another. The save's side
// goes first, but the console is in reset while the Pocket moves the save (main.sv's
// reset, save_download).

module mb128_psram (
	input  wire        clk,
	input  wire        locked,

	output wire        ready,
	output reg         mem_ok = 0,

	// rtl/mb128.sv's memory port
	input  wire [19:0] mb_addr,
	input  wire        mb_din,
	input  wire        mb_we,
	output wire        mb_dout,

	// the save slot, a word at a time: each started by the rise of bk_we or bk_rd. A
	// read is good twelve clocks later, against the unloader's sixteen.
	input  wire [15:0] bk_addr,
	input  wire [15:0] bk_din,
	output reg  [15:0] bk_dout = 0,
	input  wire        bk_we,
	input  wire        bk_rd,

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

// ---------------------------------------------------------------- one access

localparam [1:0] OP_NONE = 2'd0, OP_WRITE = 2'd1, OP_READ = 2'd2, OP_BCR = 2'd3;

reg  [1:0] op = OP_NONE;
reg  [3:0] n = 0;
reg [16:0] op_a = 0;
reg [15:0] op_d = 0;
reg [15:0] op_q = 0;
reg        op_done = 0;

// A write, in 23.3 ns clocks: ADV# low with the address at 1, high at 2, the data from
// 3, WE# and CE# high at 6 (116 ns of WE#, against tWP 45 and tAW 70), the bus let go at
// 7. The BCR is one with CRE high around it. A read: ADV# low at 1, high at 2, the bus
// let go at 3, OE# low at 4, the data taken at 8, 163 ns from the address and 93 ns from
// OE#, against tAA 70 and tOE 20, which leaves room for the pins and the board.

// ---------------------------------------------------------------- what to do next

localparam [3:0] S_POWER = 0, S_BCR = 1, S_T0 = 2, S_T1 = 3, S_T0R = 4, S_T1R = 5,
                 S_IDLE = 8, S_BK_WR = 9, S_BK_RD = 10, S_FILL = 11, S_MB_WR = 12;

reg  [3:0]  s = S_POWER;
reg  [12:0] power = 0;

// one bit a word of the MB128's 64K: written since the core was loaded. Read at op_a,
// taken with a read's data at its last clock; set where a write starts. No write starts
// while a read is under way, so the read that matters never shares a clock with a write.
(* ramstyle = "M10K, no_rw_check" *) reg written [0:65535];
reg         written_q = 0;
reg         written_we = 0;
reg  [15:0] written_wa = 0;
// synthesis translate_off
initial for (int i = 0; i < 65536; i++) written[i] = 0;
// synthesis translate_on
always @(posedge clk) begin
	written_q <= written[op_a[15:0]];
	if (written_we) written[written_wa] <= 1'b1;
end

reg         bk_we_old = 0, bk_rd_old = 0;
reg         bk_wp = 0, bk_rp = 0;
reg  [15:0] bk_a = 0;
reg  [15:0] bk_d = 0;

reg  [15:0] win = 0;				// the word mb_addr is in, once win_a has caught up
reg  [15:0] win_a = 0;
reg         mb_wp = 0;
reg  [15:0] mb_wa = 0;
reg  [3:0]  mb_wb = 0;
reg         mb_wd = 0;

wire [15:0] mb_word = mb_addr[19:4];
wire        op_free = (op == OP_NONE) && !op_done;

assign mb_dout = win[mb_addr[3:0]];

// From the state, not a register of its own: a register only ever set to 1 is one Quartus
// takes as stuck at 1, whatever its start value says (a first build did), which would let
// the Pocket load the save before the chip is set up. The states from S_IDLE on have bit 3 set.
assign ready = s[3];

task start(input [1:0] what, input [16:0] a, input [15:0] d);
	op   <= what;
	op_a <= a;
	op_d <= d;
	written_we <= (what == OP_WRITE) && !a[16];
	written_wa <= a[15:0];
endtask

always @(posedge clk) begin
	op_done <= 0;
	written_we <= 0;
	if (op != OP_NONE) begin
		n <= n + 1'd1;
		case (n)
		4'd0: cram_cre <= (op == OP_BCR);
		4'd1: begin
			ce_n       <= 0;
			cram_adv_n <= 0;
			cram_we_n  <= (op == OP_READ);
			cram_ub_n  <= 0;
			cram_lb_n  <= 0;
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
			n         <= 0;
		end
		4'd8: begin
			op_q      <= (op_a[16] | written_q) ? cram_dq : 16'd0;
			ce_n      <= 1;
			cram_oe_n <= 1;
			cram_ub_n <= 1;
			cram_lb_n <= 1;
			op        <= OP_NONE;
			op_done   <= 1;
			n         <= 0;
		end
		default: ;
		endcase
	end

	bk_we_old <= bk_we;
	bk_rd_old <= bk_rd;

	if (bk_we & ~bk_we_old) begin
		bk_wp <= 1;
		bk_a  <= bk_addr;
		bk_d  <= bk_din;
	end
	if (bk_rd & ~bk_rd_old) begin
		bk_rp <= 1;
		bk_a  <= bk_addr;
	end
	if (mb_we) begin
		mb_wp <= 1;
		mb_wa <= mb_word;
		mb_wb <= mb_addr[3:0];
		mb_wd <= mb_din;
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
		s <= S_IDLE;
	end

	S_IDLE: if (op_free) begin
		if (bk_wp) begin
			bk_wp <= 0;
			if (bk_a == win_a) win <= bk_d;
			start(OP_WRITE, {1'b0, bk_a}, bk_d);
			s <= S_BK_WR;
		end else if (bk_rp) begin
			bk_rp <= 0;
			start(OP_READ, {1'b0, bk_a}, 16'd0);
			s <= S_BK_RD;
		end else if (mb_wp && mb_wa == win_a) begin
			mb_wp <= mb_we;			// (one landing now is a later bit's)
			win[mb_wb] <= mb_wd;
			start(OP_WRITE, {1'b0, mb_wa}, (win & ~(16'd1 << mb_wb)) | ({15'd0, mb_wd} << mb_wb));
			s <= S_MB_WR;
		end else if (mb_wp) begin
			start(OP_READ, {1'b0, mb_wa}, 16'd0);
			win_a <= mb_wa;
			s <= S_FILL;
		end else if (mb_word != win_a) begin
			start(OP_READ, {1'b0, mb_word}, 16'd0);
			win_a <= mb_word;
			s <= S_FILL;
		end
	end
	S_BK_WR, S_MB_WR: if (op_done) s <= S_IDLE;
	S_BK_RD: if (op_done) begin
		bk_dout <= op_q;
		s <= S_IDLE;
	end
	S_FILL: if (op_done) begin
		win <= op_q;
		s <= S_IDLE;
	end
	default: s <= S_IDLE;
	endcase
end

endmodule
