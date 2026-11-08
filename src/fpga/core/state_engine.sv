// Save states: the console's side (docs/SAVESTATES.md). On clk_sys, in main.sv.
//
// A save: SS_SAVE finds the clean point (the vertical blank, the CPU parked at an opcode
// fetch, nothing on its way anywhere) and freezes the console there; the file is then read
// a word at a time; SS_GO lets the console go on from the same raster clock, at least a
// frame later. A load: SS_LOAD (the header already checked) stops the console at once and
// holds it; the file's words are written; SS_GO lets it go, after a whole frame for the
// raster to settle under the restored registers, at the raster clock the state was saved at.
// A save asked while a load waits to let go reads the state as it was written.
//
// SS_STATUS 0 idle, 1 busy, 2 ok (frozen, or restored), 3 error. SS_ADDR is a word's byte
// offset / 2: SS_RD has its word in SS_DO 24 clocks later, SS_WR writes SS_DI there, which
// is the pace the Pocket's bridge reads and writes at (a pair of words every 88 clocks of
// its 74 MHz). One at a time, in the file's order: a chain or a FIFO moves as it is read or written.
// The drive's block (bytes 0x800 to 0xFFF) is the bridge's to serve, from the MPU's RAM.
//
// The CPU is held by CPU_PAUSE_EN at its fetch, its opcode already read. The engine's own
// SDRAM reads overwrite the byte the CPU is waiting on, and a loaded CPU has read nothing,
// so every let-go reads the fetch again (`refetch`, a clkref of its own) a frame before it
// lets the CPU take it: a saved run and a loaded one go on from the same clock in the same way.
//
// The clocks: the freeze is decided at a clock whose raster position is recorded (R); the
// next clock holds the chips and takes the VDC's snapshot, so what is frozen is the state
// after the edge that ends R. The let-go waits for R again: that clock puts the snapshot
// back, and the next lets everything go, so the VDC, which ran on, and the chips, which
// didn't, meet again at the raster clock they parted at.

module state_engine (
	input  wire        clk,
	input  wire        locked,			// the engine's reset is power-up's, never the core's

	input  wire        SS_SAVE,
	input  wire        SS_LOAD,
	input  wire        menu,				// the Pocket's menu open
	input  wire        SS_GO,
	output reg   [1:0] SS_STATUS = 0,
	input  wire [20:0] SS_ADDR,
	input  wire        SS_RD,
	output reg  [15:0] SS_DO = 0,
	input  wire        SS_WR,
	input  wire [15:0] SS_DI,

	// the raster: the VCE's position and the window for a clean point
	input  wire  [9:0] vpos,
	input  wire [11:0] hpos,
	input  wire        vbl,
	input  wire        window,

	// the CPU
	output reg         cpu_pause = 0,
	output reg         cpu_rst = 0,
	input  wire        cpu_sync,
	input  wire        cpu_parked,
	input  wire        rom_rdy,
	output reg         refetch = 0,
	input  wire        cpu_fast,			// the CPU at 7.16 MHz, for the header

	// the rest of the console
	output reg         hold = 0,
	output reg         snap = 0,			// the VDC's snapshot taken, and put back
	output reg         rest = 0,
	output wire        keep,				// not idle: the console's resets held off
	output wire        blank,				// a save or a load under way, or the menu just closed: the picture blanked
	input  wire        busy,				// something on its way (the VDC's port or a DMA, the VCE's port)
	input  wire        freeze_ok,			// the ADPCM memory has nothing in flight

	// the drive, on the MPU (pcecd.cpp): asked to park, it writes its block and waits; on a
	// load it reads the block back once the words are all in. drv_load, with park from a
	// load's start: the block is the file's, so the drive mustn't write its own over it
	output reg         drv_park = 0,
	output reg         drv_in = 0,
	output wire        drv_load,
	input  wire        drv_parked,
	input  wire        drv_restored,

	// the chains
	output reg   [3:0] chain = 0,
	output reg         shift = 0,
	output reg  [15:0] si = 0,
	input  wire [15:0] so,

	// the memories' free ports in pce_top.vhd
	output reg         mem = 0,
	output reg   [3:0] msel = 0,
	output reg  [14:0] ma = 0,
	output reg         mwe = 0,
	output reg  [15:0] md = 0,
	input  wire [15:0] mq,

	// the CD chips' FIFOs: fcount is how many words the chosen one holds
	output reg   [1:0] fsel = 0,
	output reg         frd = 0,
	output reg         fwr = 0,
	output reg         fclr = 0,
	output reg  [31:0] fd = 0,
	input  wire [31:0] fq,
	input  wire [12:0] fcount,

	// the ADPCM chip's memory (adpcm_psram.sv's save-state port), a byte at a time
	output reg  [15:0] ad_a = 0,
	output reg   [7:0] ad_d = 0,
	output reg         ad_we = 0,
	output reg         ad_rd = 0,
	input  wire  [7:0] ad_q,

	// the SDRAM, through the CD RAM's path: a byte at cd_ram_a's address
	output reg         sd = 0,				// the SDRAM's ports are the engine's
	output reg  [21:0] sd_a = 0,
	output reg   [7:0] sd_d = 0,
	output reg         sd_ref = 0,			// a clkref of its own
	output reg         sd_we = 0,
	output reg         sd_rd = 0,
	input  wire  [7:0] sd_q,
	input  wire        sd_clkref,			// sdram.sv's clkref, from every source (the CPU's, the refetch, sd_ref)

	// the MB128's memory (mb128_psram.sv's save-path port), a word at a time
	output reg         mb = 0,
	output reg  [15:0] mb_a = 0,
	output reg  [15:0] mb_d = 0,
	output reg         mb_we = 0,
	output reg         mb_rd = 0,
	input  wire [15:0] mb_q,

	// the settings that change what the console is, and the Arcade Card's writes to its RAM
	input  wire        mb128_on,
	input  wire        ac_on,
	input  wire        ac_write,			// a write through the CD RAM's path, at cd_ram_a
	input  wire [21:0] ac_write_a,

	// the backup RAM's port B, 16 bits a word
	output reg         bk = 0,
	output reg   [9:0] bk_a = 0,
	output reg  [15:0] bk_d = 0,
	output reg         bk_we = 0,
	input  wire [15:0] bk_q,

	// the system card as it loads, for the header's size and sum
	input  wire        cart_download,
	input  wire        ioctl_wr,
	input  wire [15:0] ioctl_dout,

	// for the bridge: what a header is checked against, and a save's size in words
	output wire [31:0] hdr_card_size,
	output wire [31:0] hdr_card_sum,
	output wire [20:0] size_words
);

localparam [31:0] CLK_HZ = 32'd42954545;

// ---- the file (docs/SAVESTATES.md, The format), in words ----
localparam [20:0] W_HDR_END   = 21'h00080;		// the header, 256 bytes
localparam [20:0] W_CHAINS    = 21'h00080;		// the chains, 64 words a slot from byte 0x100
localparam [20:0] W_CHAIN_END = 21'h00280;		// eight slots
localparam [20:0] W_WAVES     = 21'h00800;		// byte 0x1000: the PSG's waves, a byte an entry
localparam [20:0] W_WAVES_END = 21'h00860;
localparam [20:0] W_SAT       = 21'h00880;		// byte 0x1100: the SAT, 256 words
localparam [20:0] W_SAT_END   = 21'h00980;
localparam [20:0] W_PAL       = 21'h00A00;		// byte 0x1400: the palette, 512 words of 9 bits
localparam [20:0] W_PAL_END   = 21'h00C00;
localparam [20:0] W_SUBC_CNT  = 21'h00C00;		// byte 0x1800: the subcode FIFO's count, then its 490 bytes
localparam [20:0] W_SUBC      = 21'h00C01;
localparam [20:0] W_SUBC_END  = 21'h00CF6;
localparam [20:0] W_SCSI_CNT  = 21'h00D00;		// byte 0x1A00: the SCSI FIFO's count
localparam [20:0] W_CDDA_CNT  = 21'h00D01;		// byte 0x1A02: the CD-DA FIFO's
localparam [20:0] W_RAM       = 21'h01000;		// byte 0x2000: the CPU's 8K
localparam [20:0] W_RAM_END   = 21'h02000;
localparam [20:0] W_SCSI      = 21'h02000;		// byte 0x4000: the SCSI FIFO's 4096 bytes
localparam [20:0] W_SCSI_END  = 21'h02800;
localparam [20:0] W_CDDA      = 21'h02800;		// byte 0x5000: the CD-DA FIFO's 1024 words of 32 bits
localparam [20:0] W_CDDA_END  = 21'h03000;
localparam [20:0] W_BRAM      = 21'h03000;		// byte 0x6000: the backup RAM's 2K
localparam [20:0] W_BRAM_END  = 21'h03400;
localparam [20:0] W_VRAM      = 21'h04000;		// byte 0x8000: VRAM's 32K words
localparam [20:0] W_VRAM_END  = 21'h0C000;
localparam [20:0] W_ADPCM     = 21'h0C000;		// byte 0x18000: ADPCM's 64K
localparam [20:0] W_ADPCM_END = 21'h14000;
localparam [20:0] W_CDRAM     = 21'h14000;		// byte 0x28000: SDRAM 0x600000 to 0x647FFF
localparam [20:0] W_CDRAM_END = 21'h38000;
localparam [20:0] W_MB128     = 21'h38000;		// byte 0x70000: the MB128's 128K, with its setting on
localparam [20:0] W_MB128_END = 21'h48000;
localparam [20:0] W_AC        = 21'h48000;		// byte 0x90000: the Arcade Card's RAM, as far as it's written

// each chain's length in words, by its number (pce_top.vhd's SS_CHAIN)
localparam NCHAIN = 8;
function [5:0] chain_len(input [3:0] c);
	case (c)
	4'd0:    chain_len = 6'd13;		// the CPU: the core's 144 bits, the timer and the rest's 64
	4'd1:    chain_len = 6'd38;		// the PSG: 608 bits
	4'd2:    chain_len = 6'd23;		// the VDC: 368 bits, its snapshot among them
	4'd3:    chain_len = 6'd3;		// the VCE: 48 bits
	4'd4:    chain_len = 6'd42;		// the CD chips: 672 bits
	4'd5:    chain_len = 6'd19;		// the Arcade Card: 304 bits
	4'd6:    chain_len = 6'd20;		// main.sv's link to the MPU: 320 bits
	4'd7:    chain_len = 6'd6;		// main.sv's pads and the MB128: 96 bits
	default: chain_len = 6'd0;
	endcase
endfunction

// memory numbers (pce_top.vhd's SS_MSEL), FIFO numbers (cd.vhd's SS_FSEL)
localparam [3:0] M_RAM = 4'd0, M_VRAM = 4'd1, M_WAVES = 4'd2, M_SAT = 4'd3, M_PAL = 4'd4;
localparam [1:0] F_SCSI = 2'd0, F_CDDA = 2'd1, F_SUBC = 2'd2;

// ---- the card, as it loads ----
reg [31:0] card_size = 0, card_sum = 0;
assign hdr_card_size = card_size;
assign hdr_card_sum = card_sum;
reg        dl_old = 0, wr_old = 0;
always @(posedge clk) begin
	dl_old <= cart_download;
	wr_old <= ioctl_wr;
	if (cart_download & ~dl_old) begin card_size <= 0; card_sum <= 0; end
	else if (cart_download && ioctl_wr && !wr_old) begin
		card_size <= card_size + 32'd2;
		card_sum <= card_sum + {ioctl_dout[7:0], ioctl_dout[15:8]};
	end
end

// ---- the Arcade Card's RAM: the end of the highest 64K the game has written since power-up ----
reg [5:0] ac_hw = 0;
reg       ac_hw_set = 0;				// a load's header sets it
reg [5:0] ac_hw_d = 0;
always @(posedge clk) begin
	if (ac_write && !ac_write_a[21] && {1'b0, ac_write_a[20:16]} >= ac_hw) ac_hw <= ac_write_a[20:16] + 1'd1;
	if (ac_hw_set) ac_hw <= ac_hw_d;
end

// the file's size and what's in it: 448 KB, the MB128's 128K after it, the Arcade Card's
// RAM after that as far as it's used (an Arcade Card game's file has the MB128's room, empty
// with its setting off)
wire        f_ac   = ac_on && ac_hw != 0;
wire [20:0] W_SIZE = f_ac ? W_AC + {ac_hw, 15'd0} : mb128_on ? W_MB128_END : W_MB128;
wire [20:0] W_AC_END = W_AC + {ac_hw, 15'd0};
assign size_words = W_SIZE;

// ---- when the SDRAM can be asked ----
// sdram.sv runs a 16-clock cycle of its 85.9 MHz (8 of this clock): a clkref's rise starts
// one, and with nothing asked at its start it refreshes. Its q wraps on its own when no
// clkref comes, so an engine asking at any time it liked put its ACTIVE 2 or 4 clocks of
// 85.9 MHz after a refresh, inside tRFC. The Pocket's chip mostly took
// it, but about one access in 400 read the bus's last word: 6 Nov 2026's Memories had some
// 400 words of CD RAM each from the word before, and the game crashed on the code. ref_t
// counts this clock's clocks since a clkref was last high (mod 8, as the cycle wraps); an
// access asked when it is 4 restarts the cycle 10 of its clocks in (11 at most), after the
// last cycle's ACTIVE or refresh and its own read's READY (7), before the next wrap (16).
reg  [2:0] ref_t = 0;
wire       sd_ok = ref_t == 3'd4;
always @(posedge clk) ref_t <= sd_clkref ? 3'd1 : ref_t + 1'd1;

// ---- frames since power-up ----
reg [31:0] frame = 0;
reg        vbl_old = 0;
always @(posedge clk) begin
	vbl_old <= vbl;
	if (vbl & ~vbl_old) frame <= frame + 1'd1;
end

// ---- the Pocket's menu ----
// The picture black for MENU_HOLD frames after the menu closes, so a Memory's save, which the
// Pocket asks for a frame or two after, is black from the menu to its let-go. The save's
// header records, at word 22, the menu open at the ask (bit 15), the menu seen open since
// power-up (bit 14), and the frames since it last closed (saturating at 0x3FFF); and at word
// 23 the frames from the ask to the freeze.
localparam [3:0] MENU_HOLD = 4'd10;
reg        menu_old = 0, menu_seen = 0;
reg  [3:0] menu_hold = 0;
reg [13:0] menu_since = 14'h3FFF;
always @(posedge clk) begin
	menu_old <= menu;
	if (menu) menu_seen <= 1;
	if (~menu & menu_old) begin menu_hold <= MENU_HOLD; menu_since <= 0; end
	else if (vbl & ~vbl_old) begin
		if (menu_hold) menu_hold <= menu_hold - 1'd1;
		if (~&menu_since) menu_since <= menu_since + 1'd1;
	end
end

// ---- the machine ----
localparam [3:0] S_IDLE = 0, S_SEEK = 1, S_PARK = 2, S_FREEZE = 3, S_FROZEN = 4, S_UNWIND = 5,
                 S_GO_FRAME = 6, S_GO_FETCH = 7, S_GO_POS = 8, S_GO = 9, S_LOADING = 10, S_LWAIT = 11;
reg   [3:0] st = S_IDLE;
reg  [31:0] tmr = 0;
reg         from_load = 0;			// the let-go ends a load: a whole frame first
reg   [9:0] rec_v = 0;				// the raster clock of the freeze
reg  [11:0] rec_h = 0;
reg         rec_fast = 0;
reg  [31:0] rec_frame = 0;
reg  [15:0] rec_menu = 0;				// the menu at the save's ask (word 22)
reg  [31:0] ask_frame = 0;				// the frame of the save's ask
reg   [5:0] cnt [0:NCHAIN-1];			// each chain's words moved since its start, mod its length
reg  [12:0] fcnt [0:2];					// each FIFO's count, as the file has it
reg  [12:0] fpos [0:2];					// and how many of its words have gone round or in
reg  [15:0] cdda_hi = 0;				// a CD-DA word's first half, on a load
reg   [3:0] uw = 0;						// the chain or FIFO being unwound
reg         saw_vbl = 0;
reg         go_pend = 0;				// SS_GO, kept until the word under way is done
reg         save_pend = 0;				// a save asked while a load is still going in
reg         ld_fast = 0;				// a header's, before its load starts
wire        at_rec = vpos == rec_v && hpos == rec_h;

// the word under way: w_t counts its clocks
reg         w_busy = 0, w_wr = 0;
reg  [20:0] w_a = 0;
reg  [15:0] w_d = 0;
reg   [5:0] w_t = 0;
reg   [1:0] sd_ph = 0;					// an SDRAM word: 0 its first byte to ask, 1 its second, 2 both asked
reg   [2:0] sd_t = 0;					// clocks since the last ask
reg         fetch_pend = 0;				// the refetch's R seen, waiting for sd_ok
reg         go_lead = 0;				// the let-go's clkref sent (S_GO_POS)

integer i;
initial begin
	for (i = 0; i < NCHAIN; i = i + 1) cnt[i] = 0;
	for (i = 0; i < 3; i = i + 1) begin fcnt[i] = 0; fpos[i] = 0; end
end

assign keep  = st != S_IDLE;
// A save blanks the picture from its ask to the let-go: the frozen states as the VDC draws
// them with the vertical blank's registers and none of the game's raster changes (R-Type's
// sprites, Exile II's top half), and the frames before them while the drive parks and the
// clean point is sought. Blanked from the freeze alone, a save on the Pocket went black, then
// showed the game for a moment, then black again. A load blanks from its stop to its let-go.
// Blanked from the ask, the Pocket still showed a black frame, then the game for a frame or
// two, then the save's black (the ninth play): the gap is the Pocket's, between its menu's
// close and its ask, so the picture is held black from the close as well.
assign blank = st != S_IDLE || menu_hold != 0;
assign drv_load = from_load;

wire [3:0]  w_chain = (w_a - W_CHAINS) >> 6;
wire [5:0]  w_k     = w_a[5:0];
// a FIFO word's first byte (or, for CD audio, its word), counted from the FIFO's head
wire        w_subc  = w_a >= W_SUBC && w_a < W_SUBC_END;
wire [12:0] w_fpos  = w_subc ? {w_a[11:0] - W_SUBC[11:0], 1'b0} : {1'b0, w_a[10:0], 1'b0};
wire [1:0]  w_fifo  = w_subc ? F_SUBC : F_SCSI;
wire [12:0] w_cpos  = {3'd0, w_a[10:1]};

// the header's words
function [15:0] hdr_word(input [6:0] k);
	case (k)
	7'd0:  hdr_word = 16'h5043;			// PCSS
	7'd1:  hdr_word = 16'h5353;
	7'd2:  hdr_word = 16'd1;				// the format's version
	7'd3:  hdr_word = {12'd0, 1'b0, rec_fast, f_ac, mb128_on};	// flags: the MB128, the Arcade Card's RAM, 7.16 MHz, SuperGrafx
	7'd4:  hdr_word = {10'd0, W_SIZE[20:15]};	// the file's size in bytes: W_SIZE * 2
	7'd5:  hdr_word = {W_SIZE[15:0], 1'b0};
	7'd6:  hdr_word = card_size[31:16];
	7'd7:  hdr_word = card_size[15:0];
	7'd8:  hdr_word = card_sum[31:16];
	7'd9:  hdr_word = card_sum[15:0];
	7'd10: hdr_word = {10'd0, ac_hw};
	7'd18: hdr_word = rec_frame[31:16];
	7'd19: hdr_word = rec_frame[15:0];
	7'd20: hdr_word = {6'd0, rec_v};
	7'd21: hdr_word = {4'd0, rec_h};
	7'd22: hdr_word = rec_menu;
	7'd23: hdr_word = rec_frame[15:0] - ask_frame[15:0];
	default: hdr_word = 16'd0;
	endcase
endfunction

// A FIFO's word on its way, eight clocks from t0 (fsel already chosen): on a save its head
// taken and put back at its tail, on a load `wd` put at its tail.
task fifo_step(input [5:0] t0, input [31:0] wd, input wr);
	begin
		if (w_t == t0 + 1) begin
			if (wr) begin fd <= wd; fwr <= 1; end
			else begin fd <= fq; frd <= 1; end
		end
		if (w_t == t0 + 2 && !wr) fwr <= 1;
	end
endtask

always @(posedge clk) begin
	shift <= 0; mwe <= 0; refetch <= 0; snap <= 0; rest <= 0; ac_hw_set <= 0; mb_we <= 0; mb_rd <= 0;
	frd <= 0; fwr <= 0; fclr <= 0; ad_we <= 0; ad_rd <= 0; sd_ref <= 0; sd_we <= 0; sd_rd <= 0; bk_we <= 0;
	tmr <= tmr + 1'd1;
	if (SS_GO) go_pend <= 1;
	if (SS_SAVE && from_load && (st == S_LOADING || st == S_LWAIT)) save_pend <= 1;	// read back once restored

	if (!locked) begin
		st <= S_IDLE; SS_STATUS <= 0;
		cpu_pause <= 0; cpu_rst <= 0; hold <= 0; mem <= 0; w_busy <= 0; sd <= 0; bk <= 0;
	end
	else begin
		// ---- a word of the file ----
		if ((SS_RD | SS_WR) && (st == S_FROZEN || st == S_LOADING || (SS_WR && SS_ADDR < W_HDR_END))) begin
			w_busy <= 1; w_wr <= SS_WR; w_a <= SS_ADDR; w_d <= SS_DI; w_t <= 0;
			SS_DO <= 16'd0;
		end
		else if (w_busy) begin
			w_t <= w_t + 1'd1;
			if (w_a < W_HDR_END) begin
				// the header: the raster clock and the speed come from it on a load
				// (the bridge writes a header before the load starts, which may yet be refused:
				// what is the console's waits for the load)
				if (!w_wr) SS_DO <= hdr_word(w_a[6:0]);
				else if (w_a == 21'd3) begin ld_fast <= w_d[2]; if (st == S_LOADING) rec_fast <= w_d[2]; end
				else if (w_a == 21'd10) begin ac_hw_d <= w_d[5:0]; ac_hw_set <= st == S_LOADING; end
				else if (w_a == 21'd20) rec_v <= w_d[9:0];
				else if (w_a == 21'd21) rec_h <= w_d[11:0];
				w_busy <= 0;
			end
			else if (w_a < W_CHAIN_END) begin
				// a chain: its head out, then a move of 16 bits, the same word back in at its foot
				// on a save, the file's on a load
				if (w_chain >= NCHAIN || w_k >= chain_len(w_chain)) w_busy <= 0;
				else if (w_t == 0) chain <= w_chain;
				else if (w_t == 1) begin
					if (cnt[w_chain] != w_k) SS_STATUS <= 2'd3;		// out of order: it would come back wrong
					else begin
						SS_DO <= so;
						si <= w_wr ? w_d : so;
						shift <= 1;
						cnt[w_chain] <= w_k + 1'd1 == chain_len(w_chain) ? 6'd0 : w_k + 1'd1;
					end
					w_busy <= 0;
				end
			end
			else if (w_a >= W_WAVES && w_a < W_WAVES_END) begin
				// two entries a word, the first in its high byte; 32 entries a channel
				if (w_t == 0 || w_t == 4) begin
					msel <= M_WAVES;
					ma <= {7'd0, w_a[6:0], w_t[2]};
					md <= {11'd0, w_t[2] ? w_d[4:0] : w_d[12:8]};
					mwe <= w_wr;
				end
				if (w_t == 2) SS_DO[15:8] <= {3'd0, mq[4:0]};
				if (w_t == 6) begin SS_DO[7:0] <= {3'd0, mq[4:0]}; w_busy <= 0; end
			end
			else if ((w_a >= W_SAT && w_a < W_SAT_END) || (w_a >= W_PAL && w_a < W_PAL_END)) begin
				// a word a word: the SAT's 16 bits, the palette's 9
				if (w_t == 0) begin
					msel <= w_a < W_SAT_END ? M_SAT : M_PAL;
					ma <= w_a < W_SAT_END ? {7'd0, w_a[7:0]} : {6'd0, w_a[8:0]};
					md <= w_d;
					mwe <= w_wr;
				end
				if (w_t == 2) begin SS_DO <= mq; w_busy <= 0; end
			end
			else if (w_a == W_SUBC_CNT || w_a == W_SCSI_CNT || w_a == W_CDDA_CNT) begin
				// a FIFO's count: how many it holds now, on a save; on a load, emptied for what comes
				if (w_t == 0) fsel <= w_a == W_SUBC_CNT ? F_SUBC : w_a == W_SCSI_CNT ? F_SCSI : F_CDDA;
				if (w_t == 2) begin
					if (w_wr) begin fcnt[fsel] <= w_d[12:0]; fclr <= 1; end
					else begin fcnt[fsel] <= fcount; SS_DO <= {3'd0, fcount}; end
					fpos[fsel] <= 0;
				end
				if (w_t == 3) w_busy <= 0;
			end
			else if (w_subc || (w_a >= W_SCSI && w_a < W_SCSI_END)) begin
				// a FIFO of bytes: two a word, the older in the high byte, in order
				if (w_t == 0) fsel <= w_fifo;
				if (w_t == 1 && (fpos[w_fifo] != w_fpos || w_fpos >= fcnt[w_fifo])) begin
					if (fpos[w_fifo] != w_fpos && w_fpos < fcnt[w_fifo]) SS_STATUS <= 2'd3;
					w_busy <= 0;
				end
				else begin
					if (w_t == 2) SS_DO[15:8] <= fq[7:0];
					fifo_step(6'd2, {24'd0, w_d[15:8]}, w_wr);
					if (w_t == 10) begin
						fpos[w_fifo] <= fpos[w_fifo] + 1'd1;
						if (fpos[w_fifo] + 1'd1 >= fcnt[w_fifo]) w_busy <= 0;
					end
					if (w_t == 11) SS_DO[7:0] <= fq[7:0];
					fifo_step(6'd11, {24'd0, w_d[7:0]}, w_wr);
					if (w_t == 19) begin fpos[w_fifo] <= fpos[w_fifo] + 1'd1; w_busy <= 0; end
				end
			end
			else if (w_a >= W_CDDA && w_a < W_CDDA_END) begin
				// CD audio's FIFO: a word of 32 bits in two, its high half first
				if (w_t == 0) fsel <= F_CDDA;
				if (w_t == 1 && (fpos[F_CDDA] != w_cpos || w_cpos >= fcnt[F_CDDA])) begin
					if (fpos[F_CDDA] != w_cpos && w_cpos < fcnt[F_CDDA]) SS_STATUS <= 2'd3;
					w_busy <= 0;
				end
				else if (!w_a[0]) begin
					// the first half: read, or kept for the second
					if (w_t == 2) begin SS_DO <= fq[31:16]; cdda_hi <= w_d; end
					if (w_t == 3) w_busy <= 0;
				end
				else begin
					if (w_t == 2) SS_DO <= fq[15:0];
					fifo_step(6'd2, {cdda_hi, w_d}, w_wr);
					if (w_t == 10) begin fpos[F_CDDA] <= fpos[F_CDDA] + 1'd1; w_busy <= 0; end
				end
			end
			else if (w_a >= W_RAM && w_a < W_RAM_END) begin
				// two bytes a word, the even address in the high byte
				if (w_t == 0 || w_t == 4) begin
					msel <= M_RAM;
					ma <= {2'd0, w_a[11:0], w_t[2]};
					md <= {8'd0, w_t[2] ? w_d[7:0] : w_d[15:8]};
					mwe <= w_wr;
				end
				if (w_t == 2) SS_DO[15:8] <= mq[7:0];
				if (w_t == 6) begin SS_DO[7:0] <= mq[7:0]; w_busy <= 0; end
			end
			else if (w_a >= W_BRAM && w_a < W_BRAM_END) begin
				// port B's words hold the even byte low
				if (w_t == 0) begin bk <= 1; bk_a <= w_a[9:0]; bk_d <= {w_d[7:0], w_d[15:8]}; end
				if (w_t == 1) bk_we <= w_wr;
				if (w_t == 5) begin SS_DO <= {bk_q[7:0], bk_q[15:8]}; bk <= 0; w_busy <= 0; end
			end
			else if (w_a >= W_VRAM && w_a < W_VRAM_END) begin
				if (w_t == 0) begin
					msel <= M_VRAM;
					ma <= w_a[14:0];
					md <= w_d;
					mwe <= w_wr;
				end
				if (w_t == 2) begin SS_DO <= mq; w_busy <= 0; end
			end
			else if (w_a >= W_ADPCM && w_a < W_ADPCM_END) begin
				// two bytes a word, the first in the high byte; nine clocks each through the PSRAM
				if (w_t == 0 || w_t == 10) begin
					ad_a <= {w_a[14:0], w_t != 0};
					ad_d <= w_t == 0 ? w_d[15:8] : w_d[7:0];
					ad_we <= w_wr; ad_rd <= ~w_wr;
				end
				if (w_t == 10) SS_DO[15:8] <= ad_q;
				if (w_t == 20) begin SS_DO[7:0] <= ad_q; w_busy <= 0; end
			end
			else if (w_a >= W_MB128 && w_a < W_MB128_END) begin
				// the MB128's words hold the even byte low, as the save's do; the port answers on
				// the rise of its strobe, behind whatever the chip has under way
				if (!mb128_on) w_busy <= 0;
				else begin
					if (w_t == 0) begin mb <= 1; mb_a <= w_a[15:0]; mb_d <= {w_d[7:0], w_d[15:8]}; end
					if (w_t == 1) begin mb_we <= w_wr; mb_rd <= ~w_wr; end
					if (w_t == 21) begin SS_DO <= {mb_q[7:0], mb_q[15:8]}; mb <= 0; w_busy <= 0; end
				end
			end
			else if ((w_a >= W_CDRAM && w_a < W_CDRAM_END) || (f_ac && w_a >= W_AC && w_a < W_AC_END)) begin
				// the SDRAM, a byte at a time through the CD RAM's path, on a clkref of its own,
				// each asked when sd_ok says the chip's cycle allows (above): the second 5 clocks
				// after the first, each byte read 7 clocks after its ask. 21 clocks at the most,
				// inside the bridge's 24.
				if (w_t == 0) begin
					sd <= 1;
					sd_a <= w_a < W_CDRAM_END ? 22'h200000 + {(w_a - W_CDRAM), 1'b0} : {(w_a - W_AC), 1'b0};
					sd_d <= w_d[15:8];
					sd_ph <= 0;
				end
				else begin
					sd_t <= sd_t + 1'd1;
					if (sd_ph == 2'd0 && sd_ok) begin
						sd_ref <= 1; sd_we <= w_wr; sd_rd <= ~w_wr;
						sd_ph <= 2'd1; sd_t <= 0;
					end
					if (sd_ph == 2'd1 && sd_ok) begin
						sd_a[0] <= 1'b1;
						sd_d <= w_d[7:0];
						sd_ref <= 1; sd_we <= w_wr; sd_rd <= ~w_wr;
						sd_ph <= 2'd2; sd_t <= 0;
					end
					if (sd_ph == 2'd2 && sd_t == 3'd1) SS_DO[15:8] <= sd_q;
					if (sd_ph == 2'd2 && sd_t == 3'd6) begin SS_DO[7:0] <= sd_q; sd <= 0; w_busy <= 0; end
				end
			end
			else w_busy <= 0;		// unused, or the bridge's: reads 0, a write goes nowhere
		end

		case (st)
		S_IDLE: begin
			SS_STATUS <= 0;
			from_load <= 0;
			go_pend <= 0;
			save_pend <= 0;
			fetch_pend <= 0;
			if (SS_SAVE) begin
				SS_STATUS <= 1;
				rec_menu <= {menu, menu_seen, menu_since};
				ask_frame <= frame;
				drv_park <= 1;
				tmr <= 0;
				st <= S_SEEK;
			end
			else if (SS_LOAD) begin
				// stop everything where it is; the CPU and the VDC into their own resets, then the
				// CPU parked
				SS_STATUS <= 1;
				hold <= 1; cpu_pause <= 1; cpu_rst <= 1; mem <= 1; drv_park <= 1;
				rec_fast <= ld_fast; ac_hw_set <= 1;
				for (i = 0; i < NCHAIN; i = i + 1) cnt[i] <= 0;
				from_load <= 1;
				tmr <= 0;
				st <= S_LOADING;
			end
		end

		// ---- a save ----
		S_SEEK:
			// the drive parked first, at the top of its pass; then the CPU at its next opcode
			// fetch inside the window
			if (tmr >= 2 * CLK_HZ) begin SS_STATUS <= 3; drv_park <= 0; st <= S_IDLE; end
			else if (window && cpu_sync && drv_parked) begin cpu_pause <= 1; st <= S_PARK; end

		S_PARK:
			// the pause can come a clock after the fetch was taken, and the CPU then parks inside
			// the instruction: let it go and try at the next fetch
			if (!window || (cpu_parked && !cpu_sync)) begin cpu_pause <= 0; st <= S_SEEK; end
			else if (cpu_parked && rom_rdy && !busy && freeze_ok && drv_parked) begin
				rec_v <= vpos; rec_h <= hpos; rec_fast <= cpu_fast; rec_frame <= frame;
				st <= S_FREEZE;
			end

		S_FREEZE: begin
			// the clock after R: the chips held from its edge, the VDC's snapshot taken at it
			hold <= 1; snap <= 1; mem <= 1;
			for (i = 0; i < NCHAIN; i = i + 1) cnt[i] <= 0;
			SS_STATUS <= 2;
			st <= S_FROZEN;
		end

		S_FROZEN:
			if ((SS_GO || go_pend) && !w_busy) begin
				// the chains and FIFOs read part way are brought round to where they started
				go_pend <= 0;
				uw <= 0; w_t <= 0; st <= S_UNWIND;
			end

		S_UNWIND: begin
			w_t <= w_t + 1'd1;
			if (uw < NCHAIN) begin
				if (cnt[uw] == 0) begin uw <= uw + 1'd1; w_t <= 0; end
				else if (w_t == 0) chain <= uw;
				else if (w_t == 1) begin
					si <= so; shift <= 1;
					cnt[uw] <= cnt[uw] + 1'd1 == chain_len(uw) ? 6'd0 : cnt[uw] + 1'd1;
					w_t <= 0;
				end
			end
			else if (uw < NCHAIN + 3) begin
				if (fpos[uw - NCHAIN] >= fcnt[uw - NCHAIN]) begin uw <= uw + 1'd1; w_t <= 0; end
				else begin
					if (w_t == 0) fsel <= uw - NCHAIN;
					fifo_step(6'd0, 32'd0, 1'b0);
					if (w_t == 7) begin fpos[uw - NCHAIN] <= fpos[uw - NCHAIN] + 1'd1; w_t <= 0; end
				end
			end
			else begin saw_vbl <= 0; st <= from_load ? S_GO_FRAME : S_GO_FETCH; end
		end

		S_GO_FRAME:
			// a loaded state: a whole frame for the raster to settle under the restored registers
			if (SS_SAVE || save_pend) begin
				save_pend <= 0;
				for (i = 0; i < NCHAIN; i = i + 1) cnt[i] <= 0;
				st <= S_FROZEN;
			end
			else if (vbl & ~vbl_old) begin
				if (saw_vbl) st <= S_GO_FETCH;
				saw_vbl <= 1;
			end

		S_GO_FETCH:
			// R once: the opcode read again, a frame ahead of the let-go
			if ((SS_SAVE || save_pend) && from_load) begin
				save_pend <= 0;
				fetch_pend <= 0;
				for (i = 0; i < NCHAIN; i = i + 1) cnt[i] <= 0;
				st <= S_FROZEN;
			end
			else if (at_rec || fetch_pend) begin
				// as soon after R as the SDRAM's cycle allows (sd_ok): the CPU waits till the let-go
				fetch_pend <= 1;
				if (sd_ok) begin refetch <= 1; fetch_pend <= 0; go_lead <= 0; st <= S_GO_POS; end
			end

		S_GO_POS: begin
			// R again: the snapshot back at its edge. The CPU's first clkref comes 4 clocks
			// after R (its pause off at S_GO, its CE, then ce_rom), at a time sdram.sv's cycle
			// knows nothing of; a clkref of the engine's 3 to 7 clocks before it, sent where
			// the cycle allows (ref_t 4 to 7, one of R-4 to R always is), puts it inside.
			if (!go_lead && ref_t[2] && vpos == rec_v && hpos <= rec_h && rec_h - hpos <= 12'd4) begin
				sd_ref <= 1; go_lead <= 1;
			end
			if (at_rec) begin rest <= 1; mem <= 0; st <= S_GO; end
		end

		S_GO: begin
			// and from this clock's edge on, everything goes on
			hold <= 0; cpu_pause <= 0; drv_park <= 0; drv_in <= 0;
			st <= S_IDLE;
		end

		// ---- a load ----
		S_LOADING: begin
			if (tmr == 8) cpu_rst <= 0;
			if ((SS_GO || go_pend) && !w_busy) begin go_pend <= 0; drv_in <= 1; st <= S_LWAIT; end
		end

		S_LWAIT:
			// written in: once the CPU is parked again at its restored fetch and the drive has
			// read its block back, ok, and readable until it lets go
			if (cpu_parked && drv_restored) begin SS_STATUS <= 2; saw_vbl <= 0; st <= S_GO_FRAME; end

		default: st <= S_IDLE;
		endcase
	end
end

endmodule
