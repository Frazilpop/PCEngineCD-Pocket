#!/bin/bash
# Save states in the simulation, proved (docs/SAVESTATES.md, The proofs): a save at
# frame F and the run going on; the state loaded into a fresh run and, before it lets
# go, read straight back out; then from the clock each lets go, the two compared frame
# by frame (the picture, and the chips' sound on every clock) for N frames.
# Out in build/state_test/NAME.
#   bash tools/state-test.sh --card CARD --disc CUE --at F [--frames N] [--name NAME] [--load-at F] [--press F:BUTTONS[:N]]... [--opt OPTION]...
# With no card, the test card and disc (tools/testcard.py). --press: in the saving run
# only, before F. --opt: an option of tools/sim.sh's for both runs, as --arcade or --mb128.
# Runs the simulation tools/sim.sh builds; NO_BUILD=1 to run two at once on that build.
set -uo pipefail
cd "$(dirname "$0")/.."
CARD=""; DISC=""; F=60; N=300; NAME=""; LOADAT=30; PRESS=(); OPT=()
while [ $# -gt 0 ]; do
  case "$1" in
    --card) CARD=$2; shift 2 ;; --disc) DISC=$2; shift 2 ;; --at) F=$2; shift 2 ;; --frames) N=$2; shift 2 ;;
    --name) NAME=$2; shift 2 ;; --load-at) LOADAT=$2; shift 2 ;;
    --press) PRESS+=(--press "$2"); shift 2 ;;
    --opt) OPT+=("$2"); shift 2 ;;
    *) echo "unknown option $1"; exit 2 ;;
  esac
done
B=$PWD/build/sim
[ -n "${NO_BUILD:-}" ] || SIM_OUT=$PWD/build/sim_pce bash tools/sim.sh --card "${CARD:-$B/test/card.pce}" --frames 1 > /dev/null 2>&1 || true
if [ -z "$CARD" ]; then
  mkdir -p "$B/test"; python3 -I tools/testcard.py "$B/test" > /dev/null
  CARD=$B/test/card.pce; DISC="$B/test/Test Disc.cue"
fi
abs() { echo "$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; }
CARD=$(abs "$CARD"); [ -z "$DISC" ] || DISC=$(abs "$DISC")
[ -n "$NAME" ] || NAME=$(basename "${DISC:-$CARD}" | sed 's/\.[^.]*$//' | tr ' ' '_')_$F
D=$PWD/build/state_test/$NAME
rm -rf "$D"; mkdir -p "$D/save" "$D/load"
DARGS=(--card "$CARD"); [ -z "$DISC" ] || DARGS+=(--disc "$DISC")
cd "$B/gen"				# bram.sv reads the palette's hex from here
echo "1 of 2 runs: saved at frame $F"
"$B/obj/Vsim_top" "${DARGS[@]}" --out "$D/save" --every 0 --frames $((F + 30 + N)) --state-save "$F" "$D/state" \
  ${PRESS[@]+"${PRESS[@]}"} ${OPT[@]+"${OPT[@]}"} > "$D/save.log" 2>&1
echo "2 of 2 runs: loaded at frame $LOADAT"
"$B/obj/Vsim_top" "${DARGS[@]}" --out "$D/load" --every 0 --frames $((LOADAT + 60 + N)) --state-load "$D/state" --load-at "$LOADAT" \
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
read p snd first <<< "$(awk '{ if ($3==$7) p++; if ($4==$8) s++; if (f=="" && ($3!=$7 || $4!=$8)) f=$1 } END { print p+0, s+0, (f=="" ? "-" : f) }' "$D/compare.txt")"
echo "after letting go: $n frames, the picture the same in $p, the sound in $snd (the first that differs: $first)"
[ "$n" -ge "$N" ] && [ "$p" -eq "$n" ] && [ "$snd" -eq "$n" ] || ok=0
[ $ok -eq 1 ] && echo "$NAME: ok" || echo "$NAME: FAILED"
