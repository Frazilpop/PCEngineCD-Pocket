#!/bin/bash
# Save states in the simulation, proved (docs/SAVESTATES.md, The proofs): a save at
# frame F and the run going on; the state loaded into a fresh run and, before it lets
# go, read straight back out; then from the clock each lets go, the two compared frame
# by frame (the picture, and the chips' sound on every clock) for N frames. Each run ends N
# frames after its let-go, however long the file took to move (2.6 MB at the Pocket's pace
# is some 70 frames each way).
# Out in build/state_test/NAME.
#   bash tools/state-test.sh --card CARD --disc CUE --at F [--frames N] [--name NAME] [--load-at F] [--press F:BUTTONS[:N]]... [--change F:CUE]... [--opt OPTION]... [--refuse VAR]
# With no card, the test card and disc (tools/testcard.py). --press and --change (another
# disc chosen): in the saving run only, before F. --opt: an option of tools/sim.sh's for
# both runs, as --arcade, --mb128 or --pocket (through the Pocket's side; SIM_POCKET_RESET=1
# in the environment makes the load a launch's, with the reset on). --refuse VAR: the load
# goes through the Pocket's side with VAR=1 (SIM_POCKET_BADSUM, SIM_POCKET_ACFLAG), must be
# answered with an error, and the game must go on as the saving run did until its save.
# --reuse: the saving run already in build/state_test/NAME is kept, and only the load is run.
# Runs the simulation tools/sim.sh builds; NO_BUILD=1 to run two at once on that build, and
# STATE_SIM=build/DIR to run a copy of build/sim, so a long run isn't touched by a new build.
set -uo pipefail
# The SDRAM's timing strict: an access the chip may ignore fails (src/sim/console/README.md).
# SIM_SDRAM_STRICT= (empty) runs without it.
export SIM_SDRAM_STRICT=${SIM_SDRAM_STRICT-1}
[ -n "$SIM_SDRAM_STRICT" ] || unset SIM_SDRAM_STRICT
cd "$(dirname "$0")/.."
CARD=""; DISC=""; F=60; N=300; NAME=""; LOADAT=30; PRESS=(); OPT=(); REFUSE=""; REUSE=""
BIN=${STATE_SIM:-build/sim}
while [ $# -gt 0 ]; do
  case "$1" in
    --card) CARD=$2; shift 2 ;; --disc) DISC=$2; shift 2 ;; --at) F=$2; shift 2 ;; --frames) N=$2; shift 2 ;;
    --name) NAME=$2; shift 2 ;; --load-at) LOADAT=$2; shift 2 ;;
    --press) PRESS+=(--press "$2"); shift 2 ;;
    --change) PRESS+=(--change "$2"); shift 2 ;;
    --refuse) REFUSE=$2; shift 2 ;;
    --reuse) REUSE=1; shift ;;
    --opt) OPT+=("$2"); shift 2 ;;
    *) echo "unknown option $1"; exit 2 ;;
  esac
done
B=$PWD/$BIN
[ -n "${NO_BUILD:-}" ] || SIM_OUT=$PWD/build/sim_pce bash tools/sim.sh --card "${CARD:-$B/test/card.pce}" --frames 1 > /dev/null 2>&1 || true
if [ -z "$CARD" ]; then
  mkdir -p "$B/test"; python3 -I tools/testcard.py "$B/test" > /dev/null
  CARD=$B/test/card.pce; DISC="$B/test/Test Disc.cue"
fi
abs() { echo "$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; }
CARD=$(abs "$CARD"); [ -z "$DISC" ] || DISC=$(abs "$DISC")
[ -n "$NAME" ] || NAME=$(basename "${DISC:-$CARD}" | sed 's/\.[^.]*$//' | tr ' ' '_')_$F
D=$PWD/build/state_test/$NAME
if [ -n "$REUSE" ]; then [ -s "$D/state" ] || { echo "no saving run in $D to reuse"; exit 2; }; rm -rf "$D/load" "$D/resave"
else rm -rf "$D"; fi
mkdir -p "$D/save" "$D/load"
DARGS=(--card "$CARD"); [ -z "$DISC" ] || DARGS+=(--disc "$DISC")
cd "$B/gen"				# bram.sv reads the palette's hex from here
if [ -z "$REUSE" ]; then
  echo "1 of 2 runs: saved at frame $F"
  "$B/obj/Vsim_top" "${DARGS[@]}" --out "$D/save" --every 0 --frames $((F + 600 + N)) --after "$N" --state-save "$F" "$D/state" \
    ${PRESS[@]+"${PRESS[@]}"} ${OPT[@]+"${OPT[@]}"} > "$D/save.log" 2>&1
else echo "1 of 2 runs: the saving run at frame $F, kept"; fi
if [ -n "$REFUSE" ]; then
  # refused: the file goes in at LOADAT and is answered with an error; the game goes on
  echo "2 of 2 runs: a load refused at frame $LOADAT ($REFUSE)"
  env "$REFUSE=1" "$B/obj/Vsim_top" "${DARGS[@]}" --out "$D/load" --every 0 --frames $((F - 1)) --state-load "$D/state" --load-at "$LOADAT" \
    --pocket ${OPT[@]+"${OPT[@]}"} > "$D/load.log" 2>&1
  cd - > /dev/null
  grep -h "^state: " "$D/load.log"
  ok=1
  grep -q "an error (Savestate Load)" "$D/load.log" || { echo "Savestate Load was not answered with an error"; ok=0; }
  ! grep -q "let go\|restored" "$D/load.log" || { echo "the console was stopped"; ok=0; }
  # the frames, and the sound (48 kHz, 4 bytes a sample) to 5 frames before the save
  n=$((F - 1)); p=$(paste -d' ' <(head -n "$n" "$D/save/frames.txt") <(head -n "$n" "$D/load/frames.txt") | awk '$3==$7' | wc -l | tr -d ' ')
  bytes=$(( (F - 5) * 800 * 4 ))
  cmp -s <(head -c $((44 + bytes)) "$D/save/audio.wav" | tail -c "$bytes") <(head -c $((44 + bytes)) "$D/load/audio.wav" | tail -c "$bytes") && snd=same || snd=different
  echo "the game going on: the picture the same in $p of $n frames, the sound to frame $((F - 5)) $snd"
  [ "$p" -eq "$n" ] && [ "$snd" = same ] || ok=0
  [ $ok -eq 1 ] && echo "$NAME: ok" || echo "$NAME: FAILED"
  exit 0
fi
echo "2 of 2 runs: loaded at frame $LOADAT"
"$B/obj/Vsim_top" "${DARGS[@]}" --out "$D/load" --every 0 --frames $((LOADAT + 600 + N)) --after "$N" --state-load "$D/state" --load-at "$LOADAT" \
  --resave "$D/resave" ${OPT[@]+"${OPT[@]}"} > "$D/load.log" 2>&1
cd - > /dev/null
grep -h "^state: " "$D/save.log" "$D/load.log" | grep -v "ms to the point"
ok=1
if [ ! -s "$D/resave" ]; then echo "no state read back"; ok=0
else
  r=$(python3 -I tools/state-dump.py "$D/state" "$D/resave" | tail -1)
  if [ "$r" = "0 bytes differ" ]; then echo "read back at once: the same, bar the frame number"
  else echo "read back at once: NOT the same"; python3 -I tools/state-dump.py "$D/state" "$D/resave"; ok=0; fi
fi
touch "$D/save/after.txt" "$D/load/after.txt"
n=$(wc -l < "$D/load/after.txt" | tr -d ' '); m=$(wc -l < "$D/save/after.txt" | tr -d ' ')
[ "$m" -lt "$n" ] && n=$m
paste -d' ' <(head -n "$n" "$D/save/after.txt") <(head -n "$n" "$D/load/after.txt") > "$D/compare.txt"
read p snd first ad cd <<< "$(awk '{ if ($3==$9) p++; if ($4==$10) s++; if (f=="" && ($3!=$9 || $4!=$10)) f=$1; if ($5) a++; if ($6) c++ } END { print p+0, s+0, (f=="" ? "-" : f), a+0, c+0 }' "$D/compare.txt")"
echo "after letting go: $n frames, the picture the same in $p, the sound in $snd (the first that differs: $first)"
echo "  (ADPCM sounding in $ad of them, CD audio in $cd)"
[ "$n" -ge "$N" ] && [ "$p" -eq "$n" ] && [ "$snd" -eq "$n" ] || ok=0
[ $ok -eq 1 ] && echo "$NAME: ok" || echo "$NAME: FAILED"
