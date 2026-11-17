#!/bin/bash
# The Analogizer (src/fpga/core/pocket_analogizer.sv) in the simulation, checked: the whole
# console with the module in front of the line buffer as core_top.v has it, PC Engine pads
# at the slot (src/sim/console/sim_top.sv), checked by src/sim/console/anz.py.
#
#   bash tools/anz-test.sh            every run below, two at a time; about 25 minutes
#   bash tools/anz-test.sh nofile     one of them: nofile, dot0, dot1, dot2, snac
#
#   nofile  the test card with no analogizer.bin: frames, sound and drive the same as the
#           build without the Analogizer (tools/sim.sh's own run of it), and the slot as the
#           core had it before on every clock
#   dot0, dot1, dot2   the test card at 5.37, 7.16 and 10.74 MHz dots (tools/testcard.py's
#           card.pce, card_dot1.pce, card_dot2.pce): each video mode of the file in turn, the
#           pins over two frames of each against the Pocket's frames, then the Pocket's
#           screen black with the adapter's picture going
#   snac    a 2-button pad, a 6-button pad and a multitap of four, every button and every
#           assignment, Run reaching the console (RUN on the card's screen); a word with the
#           Analogizer off and one with a PlayStation pad leave the Pocket's controls
#
# Builds in build/sim_anz (SIM_VFLAGS=-DANZ) and build/sim; runs into build/anz/<run>.
set -euo pipefail
cd "$(dirname "$0")/.."
B=$PWD/build/sim_anz
O=$PWD/build/anz
T=$B/test
mkdir -p "$O" "$T"
python3 -I tools/testcard.py "$T" > /dev/null
DISC="$T/Test Disc.cue"

ANZ_ON=$((0x20))
word() {  # video, then optional: snac type, assignment, the Pocket's screen black
  printf '%x' $(( ANZ_ON | ${2:-0} | ${3:-0} << 6 | $1 << 10 | ${4:-0} << 14 ))
}

sim_anz() {  # out, then the run's arguments
  local out=$1; shift
  mkdir -p "$O/$out"
  SIM_BUILD=$B SIM_OUT=$O/$out SIM_VFLAGS=-DANZ NO_BUILD=1 bash tools/sim.sh "$@" > "$O/$out/log.txt" 2>&1
}

run_nofile() {
  # the same run on both builds: tools/sim.sh's own (its default arguments)
  local args=(--card "$T/card.pce" --disc "$DISC" --frames 240 --every 30 --press 200:run:20)
  mkdir -p "$O/plain"
  SIM_OUT=$O/plain NO_BUILD=1 bash tools/sim.sh "${args[@]}" > "$O/plain/log.txt" 2>&1
  sim_anz nofile "${args[@]}"
  local ok=1
  for f in frames.txt audio.wav sources.wav f_00240.png; do
    if cmp -s "$O/plain/$f" "$O/nofile/$f"; then echo "nofile: $f the same as the build without the Analogizer"
    else echo "nofile: FAILED: $f differs"; ok=0; fi
  done
  if cmp -s "$O/plain/drive.log" "$O/nofile/drive.log"; then echo "nofile: drive.log the same"; else echo "nofile: FAILED: drive.log differs"; ok=0; fi
  python3 -I src/sim/console/check_test.py "$O/nofile" "$B/gen/palette.hex" | tail -1
  python3 -I src/sim/console/anz.py "$O/nofile" || ok=0
  [ $ok = 1 ]
}

run_dot() {  # 0, 1 or 2
  local d=$1 card=card.pce
  [ "$d" = 0 ] || card=card_dot$d.pce
  local a=() f=150
  for v in 0 1 2 3 4 5 6 7 8 9; do a+=(--anz "$f:$(word $v)"); f=$((f + 4)); done
  a+=(--anz "$f:$(word 0 0 0 1)")
  sim_anz dot$d --card "$T/$card" --disc "$DISC" --frames $((f + 6)) --every 0 --anz-dump "${a[@]}"
  python3 -I src/sim/console/anz.py "$O/dot$d"
}

run_snac() {
  local a=() p=()
  # a 2-button pad, SNAC 1 to player 1: each button alone; then to player 2
  a+=(--anz "150:$(word 0 4 0)" --anz-pad 150:1)
  local f=152
  for b in up right down left i ii select run; do p+=(--anz-press "$f:0:$b"); f=$((f + 6)); done
  a+=(--anz "200:$(word 0 4 1)"); p+=(--anz-press "202:0:i+up")
  # a 6-button pad: III to VI alone, then the rest together
  a+=(--anz "208:$(word 0 5 0)" --anz-pad 208:2)
  f=210
  for b in iii iv v vi i+ii+run+left; do p+=(--anz-press "$f:0:$b"); f=$((f + 6)); done
  # a multitap of four 2-button pads: every pad at once, under assignments 5, 4, 3 and 2
  a+=(--anz "240:$(word 0 6 5)" --anz-pad 240:3)
  p+=(--anz-press 242:0:up --anz-press 242:1:right+ii --anz-press 242:2:run --anz-press 242:3:select+left)
  a+=(--anz "248:$(word 0 6 4)"); p+=(--anz-press 250:0:i --anz-press 250:1:down)
  a+=(--anz "256:$(word 0 6 3)"); p+=(--anz-press 258:0:ii --anz-press 258:1:up)
  a+=(--anz "264:$(word 0 6 2)"); p+=(--anz-press 266:0:select --anz-press 266:1:i)
  # the Analogizer off with the multitap's type, then on with a PlayStation pad's: the Pocket's
  a+=(--anz "272:$(printf '%x' $(( 6 | 5 << 6 )))"); p+=(--anz-press 274:0:i+run)
  a+=(--anz "280:$(word 0 16 0)" --anz-pad 280:1); p+=(--anz-press 282:0:ii+run)
  printf '%s\n' "${p[@]}" | grep -v -- --anz-press > "$O/snac_presses.txt" || true
  sim_anz snac --card "$T/card.pce" --disc "$DISC" --frames 290 --every 0 --save 186,187,190,191,196,197,282,283 "${a[@]}" "${p[@]}"
  python3 -I src/sim/console/anz.py "$O/snac" --keys "$O/snac_presses.txt"
}

echo "Building (build/sim and build/sim_anz)"
SIM_OUT=$O/build-plain bash tools/sim.sh --card "$T/card.pce" --disc "$DISC" --frames 1 > "$O/build-plain.log" 2>&1 || { tail -5 "$O/build-plain.log"; exit 1; }
SIM_BUILD=$B SIM_OUT=$O/build-anz SIM_VFLAGS=-DANZ bash tools/sim.sh --card "$T/card.pce" --disc "$DISC" --frames 1 > "$O/build-anz.log" 2>&1 || { tail -5 "$O/build-anz.log"; exit 1; }
rm -rf "$O/build-plain" "$O/build-anz"

if [ $# -gt 0 ]; then
  for r in "$@"; do case $r in nofile) run_nofile ;; dot[012]) run_dot "${r#dot}" ;; snac) run_snac ;; *) echo "what is $r?"; exit 2 ;; esac; done
  exit
fi
# two at a time
fails=0
total=5; done_n=0
pair() {
  local r
  for r in "$@"; do
    ( case $r in nofile) run_nofile ;; dot[012]) run_dot "${r#dot}" ;; snac) run_snac ;; esac ) > "$O/$r.check.txt" 2>&1 &
  done
  wait || true
  for r in "$@"; do
    done_n=$((done_n + 1))
    echo "$done_n of $total runs: $r"
    sed 's/^/  /' "$O/$r.check.txt"
    grep -q 'FAILED\|checks failed' "$O/$r.check.txt" && fails=$((fails + 1)) || true
  done
}
pair nofile dot0
pair dot1 dot2
pair snac
[ $fails = 0 ] && echo "anz-test: every run right" || { echo "anz-test: $fails runs failed"; exit 1; }
