#!/bin/bash
# The whole console in Verilator (src/sim/console): a system card and a disc in,
# frames as PNGs and the sound as a WAV out, in build/sim_pce (src/sim/console/README.md).
#   bash tools/sim.sh                                    the test card and test disc for 240 frames; checks what they report
#   bash tools/sim.sh --card CARD --disc CUE [--frames N] [--every K] [--save F,F] [--press F:buttons[:N]] [--arcade]
#   NO_BUILD=1 bash tools/sim.sh ...                     a run on the build there is
#   SIM_OUT=DIR NO_BUILD=1 bash tools/sim.sh ...         somewhere else, for several at once
# The build is kept in build/sim and made again only when a source changes.
set -euo pipefail
cd "$(dirname "$0")/.."
R=$PWD/src/fpga/core/rtl
S=$PWD/src/sim/console
B=$PWD/build/sim
OUT=${SIM_OUT:-$PWD/build/sim_pce}
mkdir -p "$B/gen" "$OUT"

GHDL=$PWD/build/tools/ghdl/bin/ghdl
VHDL=("$R/CEGen.vhd" "$R/huc6202.vhd" "$R/huc6260.vhd" "$R/huc6270.vhd"
      "$R/HUC6280/HUC6280_PKG.vhd" "$R/HUC6280/AddSubBCD.vhd" "$R/HUC6280/HUC6280_ALU.vhd" "$R/HUC6280/HUC6280_AG.vhd"
      "$R/HUC6280/HUC6280_MC.vhd" "$R/HUC6280/HUC6280_CPU.vhd" "$R/HUC6280/psg.vhd" "$R/HUC6280/HUC6280.vhd"
      "$R/cd/MSM5205.vhd" "$R/cd/SCSI.vhd" "$R/cd/cd.vhd" "$R/pce_top.vhd")

build() {
# 1 of 3: GHDL, fetched once
bash tools/get-ghdl.sh
echo "1 of 3 build steps"

# 2 of 3: the VHDL chips in Verilog, again when one of them changes
KEY=$(cat "${VHDL[@]}" "$S/bram_sim.vhd" "$S/wrap.py" "$R/../main.sv" tools/sim.sh | shasum | cut -c1-16)
if [ "$(cat "$B/gen/key" 2>/dev/null)" != "$KEY" ]; then
  echo "Translating the chips from VHDL (half a minute)"
  rm -rf "$B/gen"; mkdir -p "$B/gen/work" "$B/gen/vhd" "$B/gen/HUC6280"
  (
    cd "$B/gen"
    # The chips' image files as plain hex, for bram_sim.vhd's and bram.sv's reads
    python3 -I - "$R" <<'PY'
import re, sys
rtl = sys.argv[1]
for src, dst in (('huc6260_palette_init.mif', 'huc6260_palette_init.mif.hex'),
                 ('HUC6280/voltab.mif', 'HUC6280/voltab.mif.hex'),
                 ('palette.mif', 'palette.hex')):
    text = open(f'{rtl}/{src}').read()
    depth = int(re.search(r'DEPTH\s*=\s*(\d+)', text).group(1))
    vals = ['0'] * depth
    for a, v in re.findall(r'^\s*([0-9A-Fa-f]+)\s*:\s*([0-9A-Fa-f]+)\s*;', text, re.M):
        vals[int(a, 16)] = v.lower()
    open(dst, 'w').write('\n'.join(vals) + '\n')
PY
    A=(--std=08 -frelaxed -fsynopsys --workdir=work)
    "$GHDL" -a "${A[@]}" "$S/bram_sim.vhd" 2>> ghdl.log || { tail -20 ghdl.log; exit 1; }
    for f in "${VHDL[@]}"; do
      b=$(basename "$f")
      # Three things Quartus lets by and GHDL doesn't, written out in build's copies; rtl/ is untouched.
      # - huc6270.vhd: a reset value of two bits for a four-bit field (as tools/vdc-compare.sh).
      # - psg.vhd: xor "1000" on five bits. The right-hand end is taken as bit 0: only the LFO uses it.
      # - psg.vhd: CH(CHSEL).x <= in one process with other fields of CH in another. GHDL takes an
      #   assignment through a run-time index as driving all of CH, so each is written as a loop
      #   over the channels, the same registers. A CHSEL of 6 or 7 then writes nothing.
      sed -E "s/'0',\"00\",'0','0',\"00\",/'0',\"0000\",'0','0',\"00\",/" "$f" > "vhd/$b"
      if [ "$b" = psg.vhd ]; then
        perl -pi -e 's/xor "1000";/xor "01000";/; s/^(\s*)CH\(CHSEL\)(\.\S+(?:\(.*?\))?\s*<=.*;)\s*$/$1for i in 0 to 5 loop if i = CHSEL then CH(i)$2 end if; end loop;\n/' "vhd/$b"
      fi
      "$GHDL" -a "${A[@]}" "vhd/$b" 2>> ghdl.log || { tail -20 ghdl.log; exit 1; }
    done
    "$GHDL" --synth --latches "${A[@]}" --out=verilog -gLITE=1 pce_top > pce_top.raw.v 2>> ghdl.log \
      || { grep -i error ghdl.log | tail -20; exit 1; }
    # (a latch GHDL writes as always @(enable) never follows its input in Verilator: Genesis-Pocket's sim.sh)
    if grep -nE 'always @\(n[0-9]+\)' pce_top.raw.v; then echo "A latch in the translation that won't work in Verilator"; exit 1; fi
    python3 -I "$S/wrap.py" pce_top.raw.v "$R/pce_top.vhd" pce_top "$R/../main.sv" LITE=1 > pce_top.sv
  )
  echo "$KEY" > "$B/gen/key"
fi
echo "2 of 3 build steps"

# 3 of 3: the firmware for the Mac, then Verilator
FW=$PWD/src/cdfw
mkdir -p "$B/fw/stubs"
(cd "$B/fw/stubs" && touch apf.h fileio.h spi.h timer.h riscprintf.h osd_menu.h)
FW_FLAGS=(-std=gnu++17 -O2 -w -Wno-c++11-narrowing -I"$B/fw/stubs" -I"$FW/drivers/cue" -I"$FW/.." -I"$S"
          -include "$FW/tests/host/host_stubs.h" -include "$S/drive_host.h")
(
  cd "$B/fw"
  for c in sscanf vscanf stropen; do
    [ "$c.o" -nt "$FW/lib/$c.c" ] || gcc -O2 -w -c -I"$FW/lib" -Dsscanf=fw_sscanf "$FW/lib/$c.c" -o "$c.o"
  done
  # drive.cpp holds the firmware's sources, so any of them makes it again
  if [ -z "$(find "$S/drive.cpp" "$S/drive.h" "$S/drive_host.h" "$FW/drivers/cue" "$FW/drivers/apf/fileio.cpp" "$FW/app/pcecd.cpp" "$FW/tests/host/host_stubs.h" -newer drive.o 2>/dev/null || echo new)" ] && [ -f drive.o ]; then :; else
    g++ "${FW_FLAGS[@]}" -c "$S/drive.cpp" -o drive.o
  fi
)
echo "Building the simulation (Verilator; some minutes the first time)"
SRC=("$S/sim_top.sv" "$R/../main.sv" "$R/../audio.sv" "$R/../sys/iir_filter.v" "$R/../linebuffer.v"
     "$R/hps_ext.v" "$R/color_mix.sv" "$R/arcade.sv" "$S/bram.sv" "$S/sdram_sim.sv" "$B/gen/pce_top.sv" "$S/main.cpp")
verilator --cc --exe --build -j 0 -O3 --x-assign fast --x-initial fast --noassert \
  -Wno-fatal -Wno-lint -Wno-style -Wno-MULTIDRIVEN -Wno-COMBDLY -Wno-LATCH -Wno-UNOPTFLAT -Wno-INITIALDLY -Wno-PROCASSWIRE -Wno-MULTITOP \
  --top-module sim_top -Mdir "$B/obj" ${SIM_VFLAGS:-} \
  -CFLAGS "-O2 -I$S" -LDFLAGS "-lz $B/fw/drive.o $B/fw/sscanf.o $B/fw/vscanf.o $B/fw/stropen.o" -MAKEFLAGS OPT_FAST=-O3 \
  "${SRC[@]}" > "$B/verilator.log" 2>&1 || { grep -E '%Error' "$B/verilator.log" | head -30; tail -5 "$B/verilator.log"; exit 1; }
echo "3 of 3 build steps"
}

[ -n "${NO_BUILD:-}" ] || build

rm -f "$OUT"/f_*.png "$OUT"/frames.txt "$OUT"/audio.wav "$OUT"/run.json "$OUT"/drive.log
TEST=""
if [ $# -eq 0 ]; then
  TEST=1
  mkdir -p "$B/test"
  python3 -I tools/testcard.py "$B/test"
  set -- --card "$B/test/card.pce" --disc "$B/test/Test Disc.cue" --frames 240 --every 30 --press 200:run:20
fi
# from where the build left the palette's hex (bram.sv reads it)
(cd "$B/gen" && "$B/obj/Vsim_top" --out "$OUT" "$@")
[ -z "$TEST" ] || python3 -I src/sim/console/check_test.py "$OUT" "$B/gen/palette.hex"
