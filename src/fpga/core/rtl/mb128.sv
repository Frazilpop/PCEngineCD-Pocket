// MB128.v
//
// This executes a compatible protocol to the Memory Base 128
// or Save-kun peripheral as used by the PC Engine
//
// (c) 2020 by David Shadoff
//
//

module MB128 
(
	input	        clk_sys,     // system clock
	input	        reset,

	input         i_Clk,       // Joypad Clr/Reset line, clocks the SPI-like MB128 protocol 
	input         i_Data,      // Joypad Sel line, provides data to the SPI-like MB128 protocol

	output        o_Active,
	output  [3:0] o_Data,

	// The master storage is outside this module: mb128_psram.sv, as 128 KB won't fit in
	// the Pocket's block RAM. ram_dout is the bit at ram_addr, in time for the next i_Clk.
	output [19:0] ram_addr,
	output reg    ram_din,
	output reg    ram_we,
	input         ram_dout,

	// a save state (docs/SAVESTATES.md): ss_hold stops it; its 80 bits out at ss_q, in from
	// ss_d at ss_we
	input         ss_hold,
	output [79:0] ss_q,
	input  [79:0] ss_d,
	input         ss_we
);

// constants - STATEs
// STATE GROUP 1 - Request identification
localparam STATE_IDLE        = 0;
localparam STATE_A8_A1       = 1;
localparam STATE_A8_A2       = 2;

// STATE GROUP 2 - Synced; request infromation
localparam STATE_REQ         = 3;
localparam STATE_ADDR        = 4;
localparam STATE_LEN         = 5;

// STATE GROUP 3 - Synced; in-transfer states
localparam STATE_READ        = 6;
localparam STATE_READ_TRAIL  = 7;
localparam STATE_WRITE       = 8;
localparam STATE_WRITE_TRAIL = 9;

localparam CMD_WRITE         = 0;
localparam CMD_READ          = 1;


// registers
reg [3:0]  r_State    = STATE_IDLE;
reg [7:0]  r_Register = 0;

reg        r_Req;
reg [19:0] r_Bit_Count;
reg [19:0] r_MB128_Addr;
reg [19:0] r_MB128_Bits;
reg  [3:0] r_Data;

reg        clk_prev;

assign ram_addr = r_MB128_Addr;

assign ss_q = {r_State, r_Register, r_Req, r_Bit_Count, r_MB128_Addr, r_MB128_Bits, r_Data, clk_prev, ram_din, ram_we};

always @(posedge clk_sys) begin
	if (ss_we) {r_State, r_Register, r_Req, r_Bit_Count, r_MB128_Addr, r_MB128_Bits, r_Data, clk_prev, ram_din, ram_we} <= ss_d;
	else if (!ss_hold) begin
	ram_we <= 0;
	if (ram_we) r_MB128_Addr <= r_MB128_Addr + 1'b1;

	clk_prev <= i_Clk;

	if (reset) begin
		r_State <= STATE_IDLE;
		r_Bit_Count <= 0;
	end
	else if (~clk_prev & i_Clk) begin		// drive the SPI-like protocol based on this signal's positive edge

		r_Data <= 0;

		case (r_State)
		STATE_IDLE:
			begin
				if (r_Bit_Count <= 7) r_Bit_Count <= r_Bit_Count + 1'b1;
				r_Register <= {i_Data, r_Register[7:1]};
				if (({i_Data, r_Register[7:1]} == 8'hA8) && (r_Bit_Count >= 7))  r_State <= STATE_A8_A1;
			end

		STATE_A8_A1:
			begin
				r_State       <= STATE_A8_A2;
			end

		STATE_A8_A2:
			begin
				// Note that IDENT actually takes the value sent in data
				r_Data[2]     <= i_Data;
				r_State       <= STATE_REQ;
			end

		STATE_REQ:
			begin
				r_Req         <= i_Data;
			 
				r_MB128_Addr  <= 0;
				r_MB128_Bits  <= 0;
				r_Bit_Count   <= 0;

				r_State       <= STATE_ADDR;
			end

		STATE_ADDR:
			begin
				// 10 address bits come in LSB signifies 128 bytes of offset
				r_MB128_Addr    <= {i_Data, r_MB128_Addr[19:1]};

				r_Bit_Count     <= r_Bit_Count + 1'b1;
				if (r_Bit_Count == 9) begin
					r_Bit_Count  <= 0;
					r_State      <= STATE_LEN;
				end
			end

		STATE_LEN:
			begin
				// 20 bits come in identifying # of bits
				r_MB128_Bits <= {i_Data, r_MB128_Bits[19:1]};

				r_Bit_Count  <= r_Bit_Count + 1'b1;
				if (r_Bit_Count == 19) begin

					r_Data[0] <= r_Req;
					r_State   <= (r_Req == CMD_WRITE) ? STATE_WRITE : STATE_READ;
					r_Bit_Count <= 1;

					if (!{i_Data, r_MB128_Bits[19:1]}) begin
						r_Bit_Count <= 0;
						r_State <= (r_Req == CMD_WRITE) ? STATE_WRITE_TRAIL : STATE_READ_TRAIL;
					end
				end
			end

		STATE_READ:
			begin
				r_Bit_Count    <= r_Bit_Count + 1'b1;
				r_Data[0]      <= ram_dout;
				r_MB128_Addr   <= r_MB128_Addr + 1'b1;

				if (r_Bit_Count == r_MB128_Bits) begin
					r_Bit_Count  <= 0;
					r_State      <= STATE_READ_TRAIL;
				end
			end

		STATE_READ_TRAIL:
			begin
				r_Bit_Count <= r_Bit_Count + 1'b1;
				if (r_Bit_Count == 2) begin
					r_Bit_Count  <= 0;
					r_State      <= STATE_IDLE;
				end
			end

		STATE_WRITE:
			begin
				r_Bit_Count <= r_Bit_Count + 1'b1;
				ram_din     <= i_Data;
				ram_we      <= 1;

				if (r_Bit_Count == r_MB128_Bits) begin
					r_Bit_Count <= 0;
					r_State     <= STATE_WRITE_TRAIL;
				end
			end

		STATE_WRITE_TRAIL:
			begin
				r_Bit_Count <= r_Bit_Count + 1'b1;

				if (r_Bit_Count == 4) begin
					r_Bit_Count  <= 0;
					r_State      <= STATE_IDLE;
				end
			end
		endcase
	end
	end
end

assign o_Active = r_State != STATE_IDLE;
assign o_Data = r_Data;

endmodule
