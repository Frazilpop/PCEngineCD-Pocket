# The whole console in Verilator

MiSTer's chips and `main.sv` as the core has them (the HuC6280 with its PSG, the VDC and
VCE, the CD chips, the Arcade Card), the real line buffer, and the firmware's own drive
reading a disc from this Mac's disk. A system card goes in where the Pocket's SDRAM is, and
out come the frames as PNGs and the sound as a WAV. A game's boot, and later a save state,
is tried here before a bitstream goes to the Pocket.

```sh
bash tools/sim.sh                                  # the test card and disc, 240 frames, and checks what they report
bash tools/sim.sh --card roms/bios_3_0_jap.pce --disc "roms/Game/Game.cue" --frames 900 --every 30
bash tools/sim.sh --card CARD --disc CUE --press 300:run --press 400:i:8 --save 500,501
bash tools/sim.sh --card CARD --disc CUE --arcade  # the Arcade System core setting: the card's RAM (AC_EN)
bash tools/sim.sh --card CARD --disc CUE --change 900:/full/path/Other.cue --reset 1000   # another disc chosen in Core Settings, Reset core
SIM_OUT=build/sim_b NO_BUILD=1 bash tools/sim.sh ... # on the build there is, into its own folder; several at once
SIM_FW_PRINT=1 bash tools/sim.sh ...               # the firmware's mainprintf on stderr
```

`--press F:buttons[:N]` holds buttons on pad 1 from frame F for N frames (4 by default):
`up down left right i ii select run`, joined with `+`.

Out, in `build/sim_pce/` or `SIM_OUT`:

| file | what |
|---|---|
| `f_NNNNN.png` | the frames asked for: the picture as `core_top.v` gives it to the Pocket, through the real `linebuffer.v` |
| `frames.txt` | every frame: its number, size, a CRC of its pixels and its top-left pixel, for comparing two runs |
| `audio.wav` | `main.sv`'s `audio_l`, `audio_r`, 16-bit stereo at 48 kHz |
| `drive.log` | each command to the drive and each stage of its load, with the frame and the firmware's millisecond; another disc chosen, the tray opening and shutting, the console told, Reset core |
| `run.json` | the card and disc, the frames, the time, the speed, the drive's counters |

**The test card** (`tools/testcard.py`, into `build/sim/test`) is the repo's own to commit: HuC6280 code
written out by hand and a disc of two files with a PREGAP between. It resets the drive, waits
for it with TEST UNIT READY, reads the TOC three ways, reads sectors by hand into RAM and by the
auto-ACK into CD RAM, plays CD audio and follows it with READ SUBQ, all through the real SCSI
phases. The backdrop goes green when all of it has passed, and `check_test.py` looks, and for the
PSG's and the disc's tones in the WAV. The reads take the drive's seek time, so all good comes at
frame 104, on 3 Nov 2026.

**The reference is MAME's PC Engine** (`brew install mame`):

```sh
bash tools/mame-frames.sh 30 60 90                       # the test card and disc: into build/mame_pce
bash tools/mame-frames.sh --card CARD --disc CUE 300 600
bash tools/mame-frames.sh --card CARD --disc CUE --press 40:run --arcade $(seq 1 1800)   # pad 1, and an Arcade Card Pro
python3 -I src/sim/console/compare.py build/sim_pce build/mame_pce --sheet /tmp/pairs.png
```

`compare.py` pairs each of the sim's frames with the MAME frame that shows the same, going forward
in time, and counts the dots that differ at the console's own 9 bits of colour. Give it every MAME
frame around what matters: with only every second one, a wipe or a moving sprite shows as a
difference. At 5.37 MHz the sim's picture sits 9 dots right of MAME's left edge and 2 lines above its
top, so the sim's top two lines aren't compared. `--arcade` in MAME takes Japan's 3.0 card, which its
software list names by checksum; the `bios_3_0_jap.pce` used here is that card.

**What a real game does here, 3 Nov 2026** (docs/PLAN.md has it in full): Popful Mail, R-Type
Complete CD and Mad Stalker with `--arcade` all reach their games, with no hang, and the frames match
MAME's dot for dot but for a raster window's edge one line later. The title takes Run from frame 30;
the sim then runs behind MAME by the seeks, 37 frames at the first logo and 100 to 250 later.

The test card passes in MAME too, whose drive is its own code: the same TOC, the same sums.
READ SUBQ's second byte, the control and address, is 0 here and 41 in MAME; `cue.cpp` sets it to 0
and no check reads it (docs/PLAN.md). MAME's picture is 1088 wide, four across to a dot at
5.37 MHz, and its seeks take less time, so frames pair up by what they show and not by number.

## How it is built

`tools/sim.sh` does it all, again only for what changed (build in `build/sim`):

1. **GHDL** (`tools/get-ghdl.sh`): its macOS release, pinned by checksum, into
   `build/tools/ghdl` the first time.
2. **The VHDL chips in Verilog.** `ghdl --synth --out=verilog -gLITE=1 pce_top` translates
   everything under `pce_top`, as `main.sv` sets it. `bram_sim.vhd` stands in for `dpram.vhd`
   and the three FIFOs, whose Altera parts GHDL can't read: the same entities, behaved as their
   settings say. Three of Quartus's allowances are written out in build's copies, `rtl/` being
   untouched; the comment in `tools/sim.sh` has each. `wrap.py` is Genesis's: a module in front
   of the translation, its ports spelled as `main.sv` spells them. `arcade.sv` stays Verilog, the
   one chip GHDL leaves as an instance.
3. **The firmware for the Mac.** `drive.cpp` includes `cue.cpp`, `seektime.cpp`, `fileio.cpp` and
   `pcecd.cpp`, the sources that go on the card, unchanged, over `tests/host/host_stubs.h`.
4. **Verilator** over `sim_top.sv`, `main.sv`, `audio.sv`, `linebuffer.v`, `hps_ext.v`, `color_mix.sv`,
   `arcade.sv`, `bram.sv` (the memories those hold themselves), `sdram_sim.sv` and `main.cpp`.

## What the harness does and does not model

- **`main.sv` is the real one**, and so are `hps_ext.v` and `linebuffer.v`. The MPU and
  `core_top.v` aren't here: `sim_top.sv` joins the parts as `core_top.v` does, with the Core
  Settings at their reset values, so no extra sprites, no boost, the overscan off. The system card
  comes in through `ioctl_wr`, as the data loader's writes do, so `ROM_SZ` and the header's skip are
  real.
- **The drive runs as the MPU's program does, except for time.** Time passes in the firmware
  only on a bus word and a card read. A bus word is 14 clocks of 42.95 MHz (`SIM_SPI_SETUP` and
  `SIM_SPI_HOLD`, 6 each, an estimate from `MPU_AFP_CORE.v`, not measured) and waits on `IO_WAIT` as the
  MPU's does. A pass of the main loop gets 100 clocks besides. The firmware's arithmetic takes
  no time, so the drive is a little quicker than the Pocket's where it computes.
- **The card** is files on this Mac: a read takes `SIM_CARD_SEEK_US` (500) plus `SIM_CARD_KB_US`
  (100) a KB, and a file's open `SIM_CARD_OPEN_US` (2000). These are guesses at the Pocket's, not
  measured. A background read's bytes reach the scratch RAM only when it's done.
- **`sdram_sim.sv`** has `sdram.sv`'s access manager word for word, so the `rd_rdy` a game waits
  on is timed as on the Pocket, and an array where the chip is. No refresh, which the real one does
  only in idle slots.
- **It is deterministic**: the same card, disc, presses and settings give the same frames, CRC for
  CRC.
- Not here: saves loaded or written (`save_download`, `sd_wr` are tied off; the backup RAM starts
  formatted as `main.sv` does it), the OSD, the settings menu, a second pad.
- **A line is 257 wide at 5.37 MHz.** `tools/vdc-compare.sh`'s stand-in for the line buffer's writer
  counts 256: it takes `CE_FS`, and the real one takes `main.sv`'s `ce_pix`, half a clock later, so
  one more pixel gets past its border delay. The first or last pixel of a line isn't worth reading
  anything into. The Pocket's picture is straight and whole, so nothing has been done about it.
- **Speed:** 1.3 to 2 s of CPU a frame on the MacBook Air, so a second of the console takes a minute
  or two. With the Mac busy (load average 50 to 80, 3 Nov 2026) it took up to 7.7 s a frame.
- **A disc read from the Pocket's card needs the card left in for the whole run.** With a file gone,
  the drive's open sets error 2 in `run.json` and the game carries on with what it read. For a long
  run, copy the disc into `roms/`.
- **Don't edit `tools/sim.sh` while it runs:** bash reads it as it goes, and it ends in a syntax error
  after the run has finished, its output whole.

One trap, as Genesis's: an input port's default is run at time 0, and where the module has been
inlined it lands on the net the port is wired to, so `main.cpp` evaluates once before it sets the
inputs. Another: a comment beginning with the word Verilator is read as a directive.
