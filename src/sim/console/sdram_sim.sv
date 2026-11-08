// rtl/sdram.sv's chip as an array: its access manager word for word (q, the idle
// slot, rd_rdy and we_ack at STATE_READY, so a game sees the Pocket's timing), with
// memory in place of the MT48LC16M16's pins. 16 MB: the system card in bank 0's first
// half ({3'b000, a}), CD RAM and the Arcade Card in its second ({3'b001, a}). No
// refresh in the array; where the real one refreshes (do_ref, as rtl/sdram.sv's) is
// tracked below for its timing.

module sdram
(
	inout  wire [15:0] SDRAM_DQ,
	output wire [12:0] SDRAM_A,
	output wire        SDRAM_DQML,
	output wire        SDRAM_DQMH,
	output wire [1:0]  SDRAM_BA,
	output wire        SDRAM_nCS,
	output wire        SDRAM_nWE,
	output wire        SDRAM_nRAS,
	output wire        SDRAM_nCAS,
	output wire        SDRAM_CLK,
	output wire        SDRAM_CKE,

	input             init,
	input             clk,
	input             clkref,

	input      [24:0] raddr,
	input             rd,
	output reg        rd_rdy = 0,
	output reg  [7:0] dout,

	input      [24:0] waddr,
	input      [15:0] din,
	input             we,
	input             we_req,
	output reg        we_ack = 0
);

localparam RASCAS_DELAY = 3'd2;
localparam CAS_LATENCY  = 3'd2;
localparam STATE_IDLE   = 4'd0;
localparam STATE_START  = 4'd1;
localparam STATE_CONT   = STATE_START+RASCAS_DELAY;
localparam STATE_READY  = STATE_CONT+CAS_LATENCY+2;

reg [15:0] mem [0:(1<<23)-1];

reg  [3:0] q;
reg [22:0] a;
reg  [1:0] bank;
reg [15:0] data;
reg        wr;
reg        b;
reg        ram_req = 0;
reg        old_ref;

// rtl/sdram.sv's refresh: in an idle slot of a cycle a clkref started, or of one that
// wrapped on its own once REF_DUE clocks have gone since the last
localparam [8:0] REF_DUE = 9'd256;
reg  [8:0] since_ref = 0;
reg        own_cycle = 0;
localparam [8:0] TRFC = 9'd5;
wire       do_ref = !ram_req && q == STATE_START && (!own_cycle || since_ref >= REF_DUE);
wire       rfc_wait = ram_req && q == STATE_START && since_ref < TRFC;	// rtl/sdram.sv's hold for tRFC

wire [22:0] word = {bank[0], a[22:1]};

// The chip's own timing, which an array can't show: the controller refreshes in an idle
// slot (do_ref), and a clkref resets q wherever it is, so an ACTIVE
// can follow a REFRESH or another ACTIVE too soon. Each such ACTIVE is counted and named;
// with +strict (SIM_SDRAM_STRICT=1) its read gives what the data bus last carried and its
// write is lost, as a chip that ignored the command would. tRC and tRFC: 6 clocks of 85.9 MHz.
localparam TRC = 6;
reg [63:0] cyc = 0, last_ref = 0, last_act = 0;
reg        bad = 0, strict = 0;
reg [15:0] last_dq = 0;
integer    viol = 0;
initial strict = $test$plusargs("strict");
always @(posedge clk) begin
	cyc <= cyc + 1'd1;
	if (q == STATE_START && cyc > 64 && !rfc_wait) begin
		if (ram_req) begin
			bad <= (cyc - last_ref < TRC) || (cyc - last_act < TRC);
			if ((cyc - last_ref < TRC) || (cyc - last_act < TRC)) begin
				viol = viol + 1;
				if (viol <= 20 || viol % 1000 == 0)
					$display("sdram: ACTIVE %0d clocks after a REFRESH, %0d after an ACTIVE (%s %06x), %0d so far",
						cyc - last_ref, cyc - last_act, wr ? "write" : "read", {bank, a}, viol);
			end
			last_act <= cyc;
		end
		else if (do_ref) last_ref <= cyc;
	end
	if (q == STATE_READY && ~wr && ram_req && !(strict && bad)) last_dq <= mem[word];
end

always @(posedge clk) begin
	old_ref <= clkref;

	if (do_ref) since_ref <= 0;
	else if (~&since_ref) since_ref <= since_ref + 1'd1;
	if (q == 4'd15) own_cycle <= 1;
	if (~old_ref & clkref) own_cycle <= 0;

	if(q==STATE_IDLE) begin
		rd_rdy <= 1;
		ram_req <= 0;
		wr <= 0;

		if(we_ack != we_req || we) begin
			ram_req <= 1;
			wr <= 1;
			{bank,a} <= waddr;
			data <= din;
			b <= we;
		end
		else
		if(rd) begin
			rd_rdy <= 0;
			ram_req <= 1;
			wr <= 0;
			{bank,a} <= raddr;
			b <= 0;
		end
	end

	if (q == STATE_READY && ram_req) begin
		if(wr) we_ack <= we_req;
		else   rd_rdy <= 1;
	end

	// the chip: a write in CONT, by byte when b; a read's byte as dout at READY
	if (q == STATE_CONT && ram_req && wr && !(strict && bad)) begin
		if (!b) mem[word] <= data;
		else if (a[0]) mem[word][15:8] <= data[15:8];
		else mem[word][7:0] <= data[7:0];
	end
	if (q == STATE_READY && ~wr && ram_req) begin
		if (strict && bad) dout <= a[0] ? last_dq[15:8] : last_dq[7:0];
		else dout <= a[0] ? mem[word][15:8] : mem[word][7:0];
	end

	if (!rfc_wait) q <= q + 1'd1;
	if(~old_ref & clkref) q <= 0;
end

endmodule
