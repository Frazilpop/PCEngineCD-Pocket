#!/bin/bash
# The Memory Base 128 and the save it lives in, in the simulation: tools/mb128card.py on
# the real chips and the real mb128_psram.sv, against a PSRAM that counts timing faults and
# starts in another core's mode. Five runs, each with a kind of save:
#
#   1 of 5  no save, setting on: reads clear, takes three sectors, a 130K file
#   2 of 5  that file back: the sectors are there, the file comes out the same
#   3 of 5  an old 2K save, setting on: clear again, and the file keeps its 2K
#   4 of 5  an old 2K save, setting off: no MB128 answers, and the file stays 2K
#   5 of 5  the 130K file, setting off: no MB128 answers, and it isn't cut down to 2K
#
#   bash tools/mb128-test.sh     (NO_BUILD=1 for the build there is)
set -euo pipefail
cd "$(dirname "$0")/.."
T=$PWD/build/sim_mb128
rm -rf "$T"; mkdir -p "$T"
python3 -I tools/mb128card.py "$T/card.pce"
python3 -I - "$T/old2k.sav" <<'PY'
import random, sys
random.seed(128)
open(sys.argv[1], 'wb').write(b'HUBM\x00\x88\x10\x80' + bytes(random.randrange(256) for _ in range(2040)))
PY
run() {  # name, then the simulator's arguments
  local n=$1; shift
  SIM_OUT=$T/$n bash tools/sim.sh --card "$T/card.pce" --frames 20 --every 0 "$@" | grep -E 'PSRAM|Done|Error|error' || true
  NO_BUILD=1; export NO_BUILD
}
echo "1 of 5"; run fresh --mb128 --save-out "$T/fresh.sav"
echo "2 of 5"; run kept --mb128 --save-in "$T/fresh.sav" --save-out "$T/kept.sav"
echo "3 of 5"; run old --mb128 --save-in "$T/old2k.sav" --save-out "$T/old.sav"
echo "4 of 5"; run off --save-in "$T/old2k.sav" --save-out "$T/off.sav"
echo "5 of 5"; run offbig --save-in "$T/fresh.sav" --save-out "$T/offbig.sav"
python3 -I src/sim/console/check_mb128.py "$T" "$PWD/build/sim/gen/palette.hex"
