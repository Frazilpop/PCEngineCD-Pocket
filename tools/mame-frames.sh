#!/bin/bash
# The reference for the simulation: MAME's PC Engine on the same card and disc, its
# frames snapshotted into build/mame_pce/f_NNNNN.png, to set beside tools/sim.sh's.
#   bash tools/mame-frames.sh <frame> [frame ...]                   the test card and test disc
#   bash tools/mame-frames.sh --card CARD --disc CUE <frame> [...]  a system card and a game
# MAME_OUT: somewhere else. MAME's frames are its own count from power-on; the sim's first
# frame comes as the console leaves reset.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v mame >/dev/null || { echo "MAME is not on this Mac: brew install mame (the page's Install what's missing has it)"; exit 1; }
CARD=""; DISC=""; FRAMES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --card) CARD=$2; shift 2 ;;
    --disc) DISC=$2; shift 2 ;;
    *) FRAMES+=("$1"); shift ;;
  esac
done
[ ${#FRAMES[@]} -ge 1 ] || { echo "usage: bash tools/mame-frames.sh [--card CARD --disc CUE] <frame> [frame ...]"; exit 2; }
if [ -z "$CARD" ]; then
  mkdir -p build/sim/test
  python3 -I tools/testcard.py build/sim/test
  CARD=$PWD/build/sim/test/card.pce
  DISC="$PWD/build/sim/test/Test Disc.cue"
fi
OUT=${MAME_OUT:-build/mame_pce}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
rm -rf "$OUT"; mkdir -p "$OUT"
SORTED=$(printf '%s\n' "${FRAMES[@]}" | sort -n | tr '\n' ' ')
LAST=$(printf '%s\n' "${FRAMES[@]}" | sort -n | tail -1)
cat > "$TMP/snap.lua" <<LUA
local want, n = {}, 0
for f in string.gmatch("$SORTED", "%d+") do want[tonumber(f)] = true end
emu.register_frame_done(function()
  n = n + 1
  if want[n] then manager.machine.video:snapshot() end
  if n >= $LAST then manager.machine:exit() end
end)
LUA
ARGS=(pce -cart "$CARD")
[ -z "$DISC" ] || ARGS+=(-cdrom "$DISC")
# (its cfg and nvram, which it writes where it runs, kept in the temp folder too)
mame "${ARGS[@]}" -rompath "$TMP" -video none -sound none -nothrottle -skip_gameinfo -window \
  -cfg_directory "$TMP/cfg" -nvram_directory "$TMP/nvram" -snapshot_directory "$TMP/snap" -snapname 's/%i' -autoboot_script "$TMP/snap.lua" > "$TMP/mame.log" 2>&1 \
  || { tail -5 "$TMP/mame.log"; exit 1; }
i=0
for f in $SORTED; do
  printf -v src "$TMP/snap/s/%04d.png" $i
  printf -v dst "$OUT/f_%05d.png" "$f"
  [ -f "$src" ] && mv "$src" "$dst"
  i=$((i+1))
done
echo "$(ls "$OUT" | wc -l | tr -d ' ') frames in $OUT"
