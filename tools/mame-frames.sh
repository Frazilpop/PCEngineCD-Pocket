#!/bin/bash
# The reference for the simulation: MAME's PC Engine on the same card and disc, its
# frames snapshotted into build/mame_pce/f_NNNNN.png, to set beside tools/sim.sh's.
#   bash tools/mame-frames.sh <frame> [frame ...]                   the repo's test card and test disc
#   bash tools/mame-frames.sh --card CARD --disc CUE <frame> [...]  a system card and a game
#   ... --press F:buttons[:N] ...                                   as tools/sim.sh's: pad 1 from frame F for N frames
#   ... --wav FILE                                                  MAME's sound too, as a 48 kHz WAV
#   ... --sources DIR                                               each sound chip's own output apart, as float32 in DIR:
#                                                                   cdda.f32 (44.1 kHz stereo), psg.f32 (3.58 MHz averaged by 75,
#                                                                   47727 Hz stereo), adpcm.f32 (the MSM5205's 96 kHz, mono),
#                                                                   before MAME's mix; for src/sim/console/compare_sound.py
#   ... --arcade                                                    as an Arcade Card Pro: the card has to be Japan's 3.0,
#                                                                   which MAME's software list names by its checksum
# MAME_OUT: somewhere else. MAME's frames are its own count from power-on; the sim's first
# frame comes as the console leaves reset.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v mame >/dev/null || { echo "MAME is not on this Mac: brew install mame (the page's Install what's missing has it)"; exit 1; }
CARD=""; DISC=""; FRAMES=(); PRESSES=(); ARCADE=""; WAV=""; SRCDIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --card) CARD=$2; shift 2 ;;
    --disc) DISC=$2; shift 2 ;;
    --press) PRESSES+=("$2"); shift 2 ;;
    --arcade) ARCADE=1; shift ;;
    --wav) WAV=$2; shift 2 ;;
    --sources) SRCDIR=$2; shift 2 ;;
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
local names = {up="P1 Up", down="P1 Down", left="P1 Left", right="P1 Right", i="P1 Button I", ii="P1 Button II", select="P1 Select", run="P1 Run"}
local presses = {}
for from, b, rest in string.gmatch("${PRESSES[*]:-}", "(%d+):([%a+]+):?(%d*)") do
  local list = {}
  for x in string.gmatch(b, "%a+") do list[#list + 1] = names[x] end
  table.insert(presses, {from = tonumber(from), to = tonumber(from) + (tonumber(rest) or 4), names = list})
end
local function field(name)
  for _, port in pairs(manager.machine.ioport.ports) do
    if port.fields[name] then return port.fields[name] end
  end
end
emu.register_frame_done(function()
  n = n + 1
  for _, p in ipairs(presses) do
    for _, name in ipairs(p.names) do
      local f = field(name)
      if f and n == p.from then f:set_value(1) end
      if f and n == p.to then f:clear_value() end
    end
  end
  if want[n] then manager.machine.video:snapshot() end
  if n >= $LAST then manager.machine:exit() end
end)
LUA
if [ -n "$SRCDIR" ]; then
  mkdir -p "$SRCDIR"; SRCDIR=$(cd "$SRCDIR" && pwd)
  cat >> "$TMP/snap.lua" <<LUA
local out = "$SRCDIR"
local f = { [':pce_cd:cdda']=io.open(out.."/cdda.f32","wb"), [':maincpu:psg']=io.open(out.."/psg.f32","wb"), [':pce_cd:msm5205']=io.open(out.."/adpcm.f32","wb") }
for tag,_ in pairs(f) do manager.machine.sounds[tag].hook=true end
local acc = {0,0}; local accn = 0
local pack = string.pack
emu.register_sound_update(function(t)
  for tag,v in pairs(t) do
    local h = f[tag]
    if h then
      if tag == ':maincpu:psg' then
        local l, r = v[1], v[2]; local buf = {}
        local al, ar, an = acc[1], acc[2], accn
        for i = 1, #l do
          al = al + l[i]; ar = ar + r[i]; an = an + 1
          if an == 75 then buf[#buf+1] = pack("<ff", al/75, ar/75); al, ar, an = 0, 0, 0 end
        end
        acc[1], acc[2], accn = al, ar, an
        h:write(table.concat(buf))
      elseif #v == 2 then
        local l, r = v[1], v[2]; local buf = {}
        for i = 1, #l do buf[i] = pack("<ff", l[i], r[i]) end
        h:write(table.concat(buf))
      else
        local l = v[1]; local buf = {}
        for i = 1, #l do buf[i] = pack("<f", l[i]) end
        h:write(table.concat(buf))
      end
    end
  end
end)
LUA
fi
ARGS=(pce -cart "$CARD")
if [ -n "$ARCADE" ]; then
  mkdir -p "$TMP/pce/acardpro"
  cp "$CARD" "$TMP/pce/acardpro/[cd] super cd-rom system (japan) (v3.0).pce"
  ARGS=(pce -cart acardpro -hashpath "$(brew --prefix)/share/mame/hash")
fi
[ -z "$DISC" ] || ARGS+=(-cdrom "$DISC")
# -wavwrite records the mix whatever -sound says, so -sound none stays (nothing is played aloud)
[ -z "$WAV" ] || { mkdir -p "$(dirname "$WAV")"; ARGS+=(-wavwrite "$(cd "$(dirname "$WAV")" && pwd)/$(basename "$WAV")" -samplerate 48000); }
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
echo "$(ls "$OUT" | grep -c '^f_') frames in $OUT"
[ -z "$WAV" ] || echo "sound in $WAV"
