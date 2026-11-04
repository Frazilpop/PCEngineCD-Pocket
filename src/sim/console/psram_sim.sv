// One die of the AS1C8M16PL-70, as mb128_psram.sv uses it, on that module's clock, with
// the datasheet's asynchronous timings counted in its 23.3 ns clocks, so a fault in the
// sequence shows here rather than on the Pocket.
//
// It powers up as another core may leave it, in synchronous bursts (Cave 68000's BCR), and
// holds rubbish: until the BCR says asynchronous, a read gives rubbish and a write does
// nothing. It gives rubbish, too, for a read taken before tAA and tOE have passed.

module psram_sim #(
	parameter int MAX_CE_LOW = 171		// tCEM, 4 us
) (
	input  wire         clk,
	input  wire [21:16] a,
	inout  wire [15:0]  dq,
	input  wire         cram_clk,
	input  wire         adv_n,
	input  wire         cre,
	input  wire         ce_n,
	input  wire         oe_n,
	input  wire         we_n,
	input  wire         ub_n,
	input  wire         lb_n,
	output logic [31:0] violations = 0
);

reg [15:0] mem [0:(1 << 17) - 1];
reg [15:0] bcr = 16'h5C1F;
wire       asyn = bcr[15];

reg [21:0] addr = 0;
reg        addr_cre = 0;
reg [15:0] out = 0;
reg        ce_old = 1, adv_old = 1, oe_old = 1, we_old = 1;
int        since_adv = 0, since_oe = 0, ce_low = 0, ce_high = 100, we_low = 0, since_adv_rise = 100;
reg [15:0] dq_old = 0;
reg [15:0] addr_dq = 0;

initial for (int i = 0; i < (1 << 17); i++) mem[i] = 16'hBEEF ^ i[15:0];

assign dq = (!ce_n && !oe_n && we_n) ? out : 16'hZZZZ;

task fault(input string what);
	$display("PSRAM: %s", what);
	violations <= violations + 1;
endtask

// 70 ns from the address is 4 clocks, 20 ns from OE# is 1
wire good = asyn && since_adv >= 4 && since_oe >= 1;

always @(posedge clk) begin
	ce_old  <= ce_n;
	adv_old <= adv_n;
	oe_old  <= oe_n;
	we_old  <= we_n;
	dq_old  <= dq;

	if (cram_clk) fault("the clock pin moved");

	ce_low  <= ce_n ? 0 : ce_low + 1;
	ce_high <= ce_n ? ce_high + 1 : 0;
	if (ce_low == MAX_CE_LOW) fault("CE# low past tCEM");
	if (!ce_n && ce_old && ce_high < 1) fault("CE# high too short");

	if (!adv_n) begin
		if (!ce_n) begin
			addr     <= {a, dq};
			addr_cre <= cre;
			addr_dq  <= dq;
		end else fault("ADV# low with CE# high");
		since_adv <= 0;
		since_adv_rise <= 0;
	end else begin
		since_adv <= since_adv + 1;
		if (since_adv_rise < 100) since_adv_rise <= since_adv_rise + 1;
	end
	// tAVH: the address stays a clock past ADV#'s rise
	if (adv_n && !adv_old && dq !== addr_dq) fault("the address went with ADV#'s rise");

	if (!oe_n && oe_old && since_adv_rise < 2) fault("OE# low with the address maybe still on the bus");
	since_oe <= oe_n ? 0 : since_oe + 1;
	we_low   <= we_n ? 0 : we_low + 1;

	out <= good ? mem[addr[16:0]] : 16'hDEAD;

	// A write lands at WE#'s rise
	if (we_n && !we_old) begin
		if (we_low < 2) fault("tWP: WE# low under 45 ns");
		if (dq !== dq_old) fault("tDW: data moving as WE# rises");
		if (since_adv < 3) fault("tAW: write ended under 70 ns from the address");
		if (addr_cre) begin
			if (addr[19:18] == 2'b10) bcr <= addr[15:0];
		end else if (asyn) begin
			if (!ub_n) mem[addr[16:0]][15:8] <= dq[15:8];
			if (!lb_n) mem[addr[16:0]][7:0]  <= dq[7:0];
		end
	end
end
endmodule
