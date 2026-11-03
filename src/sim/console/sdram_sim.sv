// rtl/sdram.sv's chip as an array: its access manager word for word (q, the idle
// slot, rd_rdy and we_ack at STATE_READY, so a game sees the Pocket's timing), with
// memory in place of the MT48LC16M16's pins. 16 MB: the system card in bank 0's first
// half ({3'b000, a}), CD RAM and the Arcade Card in its second ({3'b001, a}). No
// refresh, which the real one does in the idle slots, where nothing waits on it.

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

wire [22:0] word = {bank[0], a[22:1]};

always @(posedge clk) begin
	old_ref <= clkref;

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
	if (q == STATE_CONT && ram_req && wr) begin
		if (!b) mem[word] <= data;
		else if (a[0]) mem[word][15:8] <= data[15:8];
		else mem[word][7:0] <= data[7:0];
	end
	if (q == STATE_READY && ~wr && ram_req) dout <= a[0] ? mem[word][15:8] : mem[word][7:0];

	q <= q + 1'd1;
	if(~old_ref & clkref) q <= 0;
end

endmodule
