// RndMnkIII's Analogizer in the cartridge slot: the console's picture out of the
// adapter's VGA connector (RGBS, RGsB, YPbPr, Y/C NTSC and PAL, or the scandoubler's
// 31 kHz), and SNAC controllers in for any of the four players, through his
// openFPGA_Pocket_Analogizer (src/fpga/analogizer/).
//
// CLOCK. Everything here is on clk_sys, the console's master clock (42.954545 MHz), as
// the picture is: the VCE gives a dot every 8, 6 or 4 clocks (5.37, 7.16 and 10.74 MHz,
// and 4 throughout a frame that mixes them), main.sv's ce_pix marks it, and the colours
// and syncs change on it. The module's DAC clock (the cartridge pin bank1[5]) is clk_sys
// too, so no picture crosses a clock. The scandoubler takes a sample every dot from where
// hsync ends (its divider, the dot's clocks less one, measured here from ce_pix, as the
// VCE's dot clock register is inside its chip) and gives each twice as fast.
//
// Y/C. yc_out's colour subcarrier is a step of a 40-bit phase per clock,
// f * 2^40 / clk_sys: NTSC's 3.579545 MHz or PAL's 4.43361875 MHz on the console's one
// clock. Its burst starts 60 clocks after hsync ends and runs to 173 (PAL) or 186 (NTSC),
// which its own table picks for a clock of this speed; the VCE's picture starts 218
// clocks after hsync ends (its HBL falls at 456, HS ends at 238), so the burst is clear
// of it and the console's hsync goes to the adapter as it is.
//
// SETTINGS come from analogizer.bin, the file the Analogizer's configurators write to
// Assets/analogizer/common/ and every Analogizer core that reads it shares: data slot
// 330 (data.json), platform index 1 (core.json's second platform id, "analogizer"),
// loaded to 0xF7000000. It is one 32-bit word, little-endian; the bridge is big-endian
// here (bridge_endian_little = 0), so the file's first byte arrives in [31:24] and the
// bytes are turned back round:
//
//   [4:0]   SNAC controller: 0 none, 1 DB15, 2 NES, 3 SNES, 4 PC Engine 2-button,
//           5 6-button, 6 multitap, 9 DB15 fast, 0xB SNES with A,B and X,Y swapped
//           (the ones taken here; the PS/2 and PlayStation types and JVS are not, and
//           leave the Pocket's controls in place)
//   [5]     Analogizer on
//   [9:6]   SNAC assignment: 0 SNAC 1 -> player 1, 1 SNAC 1 -> player 2,
//           2 SNAC 1, 2 -> players 1, 2, 3 SNAC 1, 2 -> players 2, 1,
//           4 SNAC 1, 2 -> players 3, 4, 5 SNAC 1-4 -> players 1-4 (3 and 4 only from
//           the PC Engine multitap; with any other controller they stay the Pocket's)
//   [13:10] video: 0 RGBS, 1 RGsB, 2 YPbPr, 3 Y/C NTSC, 4 Y/C PAL, 5-8 the scandoubler
//           (31 kHz RGBHV) with scanlines of 0, 25, 50 and 75 %, 9 HQ2x, which this
//           module has not got: the scandoubler without scanlines. The module's own
//           codes are older (5-7 the scandoubler, its scanlines on fx; 8-F the same
//           modes with the Pocket's screen off), so the file's are turned into them.
//   [14]    the Pocket's own screen black
//   [15]    OSD on the adapter's output, [19:16] region: nothing here uses them
//
// No file, or [5] clear, is the Analogizer off, and the slot is exactly as it was before
// the Analogizer: the module holds bank1 to bank3, pin30 and pin31 as inputs, and bank0
// and cart_pin30_pwroff_reset are this core's own tie-offs here, bank0 carrying the MPU's
// debug UART out ({0, uart_tx, 0, 0}) and pin31 its input. With the Analogizer on, the
// adapter has those pins and the UART's input rests high.
//
// SNAC words come out in the Pocket's controller order (key[15:0]: up, down, left,
// right, A, B, X, Y, L1, R1, L2, R2, L3, R3, select, start), which is the order the
// console's pads are taken in (core_top.v): a PC Engine pad's I and II are A and B,
// III to VI X, Y, L1 and R1, Select and Run select and start. They stand in for the
// Pocket's controls after their synchronisers. key1 to key4 are each a player's.

`default_nettype none

module pocket_analogizer (
    input  wire        clk_74a,
    input  wire        bridge_wr,
    input  wire [31:0] bridge_addr,
    input  wire [31:0] bridge_wr_data,

    input  wire        clk_sys,
    input  wire        ce_pix,
    input  wire        hs, vs,              // active high
    input  wire        hblank, vblank,
    input  wire [7:0]  r, g, b,
    output wire        pocket_off,          // clk_sys: the Pocket's own screen to black

    input  wire [15:0] cont1_key, cont2_key, cont3_key, cont4_key, // the Pocket's (clk_sys)
    output wire [15:0] key1, key2, key3, key4,                     // the players'

    input  wire        uart_tx,             // the MPU's debug UART, on bank0 with no adapter
    output wire        uart_rx,

    inout  wire [7:0]  cart_tran_bank2,
    output wire        cart_tran_bank2_dir,
    inout  wire [7:0]  cart_tran_bank3,
    output wire        cart_tran_bank3_dir,
    inout  wire [7:0]  cart_tran_bank1,
    output wire        cart_tran_bank1_dir,
    inout  wire [7:4]  cart_tran_bank0,
    output wire        cart_tran_bank0_dir,
    inout  wire        cart_tran_pin30,
    output wire        cart_tran_pin30_dir,
    output wire        cart_pin30_pwroff_reset,
    inout  wire        cart_tran_pin31,
    output wire        cart_tran_pin31_dir
);

    // ------------------------------------------------------- the settings
    reg  [15:0] cfg_74 = 16'd0;
    always @(posedge clk_74a)
        if (bridge_wr && bridge_addr == 32'hF7000000)
            cfg_74 <= {bridge_wr_data[23:16], bridge_wr_data[31:24]};

    // (a word the Pocket writes once as the core starts, held long after)
    wire [15:0] cfg;
    synch_3 #(.WIDTH(16)) cfg_s (cfg_74, cfg, clk_sys);

    wire        on      = cfg[5];
    wire [4:0]  ctype   = cfg[4:0];
    wire [3:0]  assign_ = cfg[9:6];
    wire [3:0]  vtype   = cfg[13:10];
    assign pocket_off = on & cfg[14];

    reg  [3:0]  m_vtype = 4'd0;             // the module's video code
    reg  [1:0]  m_lines = 2'd0;             // its scanlines (fx[1:0])
    reg         snac_ok = 1'b0;
    reg  [2:0]  sel1 = 3'd0, sel2 = 3'd0,   // each player's: 0 the Pocket's controls,
                sel3 = 3'd0, sel4 = 3'd0;   //   1 to 4 SNAC 1 to 4
    always @(posedge clk_sys) begin
        m_vtype <= (vtype <= 4'd4) ? vtype : (vtype <= 4'd9) ? 4'd5 : 4'd0;
        m_lines <= (vtype >= 4'd5 && vtype <= 4'd8) ? vtype[1:0] - 2'd1 : 2'd0;
        case (ctype)
        5'h01, 5'h02, 5'h03, 5'h04, 5'h05, 5'h06, 5'h09, 5'h0B: snac_ok <= on;
        default:                                               snac_ok <= 1'b0;
        endcase
        sel1 <= !snac_ok ? 3'd0 :
                (assign_ == 4'd0 || assign_ == 4'd2 || assign_ == 4'd5) ? 3'd1 :
                (assign_ == 4'd3) ? 3'd2 : 3'd0;
        sel2 <= !snac_ok ? 3'd0 :
                (assign_ == 4'd1 || assign_ == 4'd3) ? 3'd1 :
                (assign_ == 4'd2 || assign_ == 4'd5) ? 3'd2 : 3'd0;
        sel3 <= !snac_ok ? 3'd0 :
                (assign_ == 4'd4) ? 3'd1 :
                (assign_ == 4'd5 && ctype == 5'h06) ? 3'd3 : 3'd0;
        sel4 <= !snac_ok ? 3'd0 :
                (assign_ == 4'd4) ? 3'd2 :
                (assign_ == 4'd5 && ctype == 5'h06) ? 3'd4 : 3'd0;
    end

    wire [15:0] snac1, snac2, snac3, snac4;
    function automatic [15:0] pick(input [2:0] sel, input [15:0] pocket,
                                   input [15:0] s1, input [15:0] s2, input [15:0] s3, input [15:0] s4);
        case (sel)
        3'd1:    pick = s1;
        3'd2:    pick = s2;
        3'd3:    pick = s3;
        3'd4:    pick = s4;
        default: pick = pocket;
        endcase
    endfunction
    assign key1 = pick(sel1, cont1_key, snac1, snac2, snac3, snac4);
    assign key2 = pick(sel2, cont2_key, snac1, snac2, snac3, snac4);
    assign key3 = pick(sel3, cont3_key, snac1, snac2, snac3, snac4);
    assign key4 = pick(sel4, cont4_key, snac1, snac2, snac3, snac4);

    // Y/C: f * 2^40 / 42.954545 MHz, NTSC's colour or PAL's
    wire        yc_pal = (m_vtype == 4'd4);
    reg  [39:0] phase_inc = 40'd0;
    always @(posedge clk_sys)
        phase_inc <= yc_pal ? 40'd113487765198 : 40'd91625968981;

    // ----------------------------------------------------------- the dot
    // Registered once, so only registers drive the module's paths to the pins. A line's
    // vblank is taken where its picture starts (hblank's end): the scandoubler notes
    // where in a line vblank changed and replays it there in both lines it makes, so it
    // must change inside the line, and the VCE's changes as a line begins, before hsync.
    reg  [7:0]  vr = 8'd0, vg = 8'd0, vb = 8'd0;
    reg         vhs = 1'b0, vvs = 1'b0, vhb = 1'b1, vvb = 1'b1;
    reg         hb_was = 1'b1;
    always @(posedge clk_sys) begin
        {vr, vg, vb} <= {r, g, b};
        {vhs, vvs, vhb} <= {hs, vs, hblank};
        hb_was <= hblank;
        if (hb_was && !hblank) vvb <= vblank;
    end
    wire        vde = ~(vhb | vvb);

    // The dot's clocks: the gap between two ce_pix inside the picture. A line's last dot is
    // not a whole one (2730 clocks is 682 dots and 2 clocks at 10.74 MHz, so its last is 6),
    // and the scandoubler reads the divider on every clock, not only at hsync, so a gap
    // taken in the blanking would put a beat out in the second of each pair of lines.
    reg  [3:0]  gap = 4'd0;
    reg  [3:0]  sd_div = 4'd7;
    always @(posedge clk_sys) begin
        if (ce_pix) begin
            gap <= 4'd1;
            if (!hblank && (gap == 4'd4 || gap == 4'd6 || gap == 4'd8)) sd_div <= gap - 4'd1;
        end else if (gap != 4'd15)
            gap <= gap + 4'd1;
    end

    // --------------------------------------------------------- the module
    wire        m_pwroff;

    openFPGA_Pocket_Analogizer #(
        .MASTER_CLK_FREQ (42_954_545),
        .LINE_LENGTH     (341),             // dots a line at 5.37 MHz (the module doesn't use it)
        .SD_HCNT_WIDTH   (10)
    ) u_anz (
        .i_clk            (clk_sys),
        .i_rst            (1'b0),
        .i_ena            (on),
        .video_clk        (clk_sys),
        .analog_video_type(m_vtype),
        .R (vr), .G (vg), .B (vb),
        .Hblank (vhb),    .Vblank (vvb),    .BLANKn (vde),
        .Hsync  (vhs),    .Vsync  (vvs),
        .Csync  (~(vhs ^ vvs)),             // active low
        .CHROMA_PHASE_INC (phase_inc),
        .PALFLAG          (yc_pal),
        .ce_pix           (ce_pix),
        .scandoubler      (1'b1),
        .sd_ce_divider    (sd_div),
        .fx               ({1'b0, m_lines}),
        .conf_AB          (1'b0),
        .game_cont_type   (snac_ok ? ctype : 5'd0),
        .p1_btn_state     (snac1), .p1_joy_state (),
        .p2_btn_state     (snac2), .p2_joy_state (),
        .p3_btn_state     (snac3), .p4_btn_state (snac4),
        .i_VIB_SW1 (2'b00), .i_VIB_DAT1 (8'h00), .i_VIB_SW2 (2'b00), .i_VIB_DAT2 (8'h00),
        .busy             (),
        .cart_tran_bank2  (cart_tran_bank2), .cart_tran_bank2_dir (cart_tran_bank2_dir),
        .cart_tran_bank3  (cart_tran_bank3), .cart_tran_bank3_dir (cart_tran_bank3_dir),
        .cart_tran_bank1  (cart_tran_bank1), .cart_tran_bank1_dir (cart_tran_bank1_dir),
        .cart_tran_bank0  (cart_tran_bank0), .cart_tran_bank0_dir (cart_tran_bank0_dir),
        .bank0_idle       ({1'b0, uart_tx, 1'b0, 1'b0}),
        .cart_tran_pin30  (cart_tran_pin30), .cart_tran_pin30_dir (cart_tran_pin30_dir),
        .cart_pin30_pwroff_reset (m_pwroff),
        .cart_tran_pin31  (cart_tran_pin31), .cart_tran_pin31_dir (cart_tran_pin31_dir),
        .DBG_TX (), .o_stb ()
    );

    // With no adapter, pin30's power-off reset as the core had it before (the module
    // leaves it low when off), and bank0 the UART's (bank0_idle; its direction an output)
    assign cart_pin30_pwroff_reset = on ? m_pwroff    : 1'b1;
    assign uart_rx                 = on ? 1'b1        : cart_tran_pin31;

endmodule

`default_nettype wire
