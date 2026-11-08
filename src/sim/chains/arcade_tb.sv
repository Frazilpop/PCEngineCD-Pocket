// The Arcade Card's save-state chain on its own (tools/chain-test.sh): random words written
// in as a load writes them, then read out twice as a save reads them, each word put back at
// the foot. Both reads must give the words written, every bit of all 19: a chain that drops
// bits loses them from the file and from the running console.
module arcade_tb;
	reg         clk = 0;
	reg         shift = 0;
	reg  [15:0] si = 0;
	wire [15:0] so;
	wire  [7:0] do_;
	wire        sel_n, ram_cs_n;
	wire [20:0] ram_a;

	ARCADE_CARD ac (
		.CLK(clk), .RST_N(1'b1), .EN(1'b0), .WR_N(1'b1), .RD_N(1'b1), .A(21'd0), .DI(8'd0),
		.DO(do_), .SEL_N(sel_n), .RAM_CS_N(ram_cs_n), .RAM_A(ram_a),
		.SS_SHIFT(shift), .SS_SI(si), .SS_SO(so)
	);

	always #1 clk = ~clk;

	reg [15:0] words [0:18];
	integer i, pass, bad = 0, seed = 7;

	task step(input [15:0] w);
		begin
			si = w; shift = 1;
			@(posedge clk); #0.1;
			shift = 0;
			@(posedge clk); #0.1;
		end
	endtask

	initial begin
		@(posedge clk); #0.1;
		for (i = 0; i < 19; i = i + 1) begin
			words[i] = $random(seed);
			step(words[i]);
		end
		for (pass = 1; pass <= 2; pass = pass + 1)
			for (i = 0; i < 19; i = i + 1) begin
				if (so !== words[i]) begin
					$display("read %0d, word %0d: %04x, written %04x", pass, i, so, words[i]);
					bad = bad + 1;
				end
				step(so);
			end
		if (bad) $display("arcade.sv's chain: FAILED, %0d words wrong", bad);
		else $display("arcade.sv's chain: ok, 19 words read back twice the same");
		$finish;
	end
endmodule
