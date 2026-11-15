#!/bin/bash
# Saves asked across a moment, through the Pocket's side with the card held from each ask to
# its end (SIM_POCKET_HOLD=0), as the Pocket is taken to do: does every one get its clean point,
# or does the engine refuse it at 2 s? Only the saving run, stopped at the outcome.
# SWEEP_SIM=build/DIR runs a simulation built there (tools/sim.sh's SIM_BUILD) instead of build/sim.
#   bash tools/park-sweep.sh [--card CARD --disc CUE] [--hold N] [--name NAME] US...
# US: when to ask, in microseconds from power-on (drive.log's card waits give them); FROM:TO:STEP
# for a range. --hold N: the card held from N frames before (the Pocket's menu) instead.
# With no card, the test card and disc (tools/testcard.py). Out in build/park_sweep/NAME, a
# line a save in results.txt. Runs build/sim as tools/sim.sh last built it.
set -uo pipefail
cd "$(dirname "$0")/.."
CARD=""; DISC=""; HOLD=0; NAME=sweep; TIMES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --card) CARD=$2; shift 2 ;; --disc) DISC=$2; shift 2 ;; --hold) HOLD=$2; shift 2 ;;
    --name) NAME=$2; shift 2 ;;
    *:*:*) IFS=: read a b c <<< "$1"; for ((t = a; t <= b; t += c)); do TIMES+=("$t"); done; shift ;;
    *) TIMES+=("$1"); shift ;;
  esac
done
B=$PWD/${SWEEP_SIM:-build/sim}
if [ -z "$CARD" ]; then
  mkdir -p "$B/test"; python3 -I tools/testcard.py "$B/test" > /dev/null
  CARD=$B/test/card.pce; DISC="$B/test/Test Disc.cue"
fi
abs() { echo "$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; }
CARD=$(abs "$CARD"); [ -z "$DISC" ] || DISC=$(abs "$DISC")
DARGS=(--card "$CARD"); [ -z "$DISC" ] || DARGS+=(--disc "$DISC")
D=$PWD/build/park_sweep/$NAME
mkdir -p "$D"; : > "$D/results.txt"
n=${#TIMES[@]}; k=0; refused=0
cd "$B/gen"
for us in "${TIMES[@]}"; do
  k=$((k + 1))
  F=$((us * 60 / 1000000))			# the frame it falls in, near enough for the run's length
  O=$D/$us; rm -rf "$O"; mkdir -p "$O"
  SIM_STOP_AT_POINT=1 SIM_SAVE_US=$us SIM_POCKET_HOLD=$HOLD SIM_SDRAM_STRICT=1 \
    "$B/obj/Vsim_top" "${DARGS[@]}" --out "$O" --every 0 --frames $((F + 300)) --state-save "$F" "$O/state" --pocket \
    > "$O/run.log" 2>&1
  if grep -q "frozen at its point" "$O/run.log"; then
    a=$(grep -h "save asked at clock" "$O/run.log" | sed 's/.*clock \([0-9]*\).*/\1/')
    z=$(grep -h "frozen at its point at clock" "$O/run.log" | sed 's/.*clock \([0-9]*\).*/\1/')
    r="parked $(awk -v a="$a" -v z="$z" 'BEGIN { printf "%.2f", (z - a) / 42954.545 }') ms after the ask"
  elif grep -q "an error" "$O/run.log"; then r="REFUSED"; refused=$((refused + 1))
  else r="no outcome"; refused=$((refused + 1)); fi
  w=$(grep -h "a park asked" "$O/drive.log" | head -1 | sed 's/^[0-9]* [0-9]* //')
  echo "$us us: $r${w:+ ($w)}" | tee -a "$D/results.txt"
  echo "$k of $n"
done
echo "$((n - refused)) of $n saves got their point, $refused refused" | tee -a "$D/results.txt"
