// The memories main.sv and linebuffer.v hold themselves, in plain SystemVerilog for
// the simulator: dpram (the palette), dpram_difclk (the backup RAM, its two widths) and
// Altera's scfifo (the line buffer's banks, show-ahead). The chips' own are in
// bram_sim.vhd, as they go through GHDL.

module dpram #(parameter int addr_width = 8, parameter int data_width = 8,
               parameter mem_init_file = " ", parameter logic disable_value = 1'b1) (
	input  logic clock,
	input  logic [addr_width-1:0] address_a,
	output logic [data_width-1:0] q_a
);
	logic [data_width-1:0] mem [0:2**addr_width-1];
	// sim.sh runs the model from where it left palette.mif as hex
	initial $readmemh("palette.hex", mem);
	always_ff @(posedge clock) q_a <= mem[address_a];
endmodule

module dpram_difclk #(parameter int addr_width_a = 8, parameter int data_width_a = 8,
                      parameter int addr_width_b = 8, parameter int data_width_b = 8) (
	input  logic clock0,
	input  logic [addr_width_a-1:0] address_a,
	input  logic [data_width_a-1:0] data_a,
	input  logic wren_a,
	output logic [data_width_a-1:0] q_a,
	input  logic clock1,
	input  logic [addr_width_b-1:0] address_b,
	input  logic [data_width_b-1:0] data_b,
	input  logic wren_b,
	output logic [data_width_b-1:0] q_b
);
	// bytes, as data_width_a is 8 and data_width_b 16; altsyncram puts the low byte first
	logic [7:0] mem [0:2**addr_width_a-1];
	always_ff @(posedge clock0) begin
		if (wren_a) mem[address_a] <= data_a;
		q_a <= wren_a ? data_a : mem[address_a];
	end
	always_ff @(posedge clock1) begin
		if (wren_b) begin
			mem[{address_b, 1'b0}] <= data_b[7:0];
			mem[{address_b, 1'b1}] <= data_b[15:8];
		end
		q_b <= wren_b ? data_b : {mem[{address_b, 1'b1}], mem[{address_b, 1'b0}]};
	end
endmodule

module scfifo #(parameter add_ram_output_register = "ON", parameter intended_device_family = "Cyclone V",
                parameter int lpm_numwords = 1024, parameter lpm_type = "scfifo",
                parameter int lpm_width = 24, parameter int lpm_widthu = 10,
                parameter lpm_showahead = "ON", parameter overflow_checking = "ON",
                parameter underflow_checking = "ON", parameter use_eab = "ON") (
	input  logic clock,
	input  logic [lpm_width-1:0] data,
	input  logic rdreq,
	input  logic wrreq,
	output logic empty,
	output logic [lpm_width-1:0] q,
	output logic [lpm_widthu-1:0] usedw
);
	logic [lpm_width-1:0] mem [0:lpm_numwords-1];
	logic [lpm_widthu-1:0] wa = 0, ra = 0;
	logic [lpm_widthu:0] count = 0;
	wire do_wr = wrreq && count != lpm_numwords;
	wire do_rd = rdreq && count != 0;
	assign empty = count == 0;
	assign usedw = count[lpm_widthu-1:0];
	assign q = mem[ra];
	always_ff @(posedge clock) begin
		if (do_wr) begin mem[wa] <= data; wa <= wa + 1'd1; end
		if (do_rd) ra <= ra + 1'd1;
		count <= count + (do_wr ? 1'd1 : 1'd0) - (do_rd ? 1'd1 : 1'd0);
	end
endmodule
