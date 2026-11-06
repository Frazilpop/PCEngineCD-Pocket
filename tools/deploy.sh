#!/bin/bash
# PC Engine CD for Analogue Pocket: put the core on the card.
#
#   tools/deploy.sh [/Volumes/NAME]   copy the core onto the Pocket's card
#   tools/deploy.sh --status          is the current build on the card?
#
# Copies dist/Cores/frazilpop.PCEngineCD (the bitstream tools/build.sh made and
# the core's JSONs), replacing the folder whole, and the MPU's firmware into
# Assets/pcecd/frazilpop.PCEngineCD, and checks both byte for byte. The card is
# the volume with Analogue_Pocket.json at its root, in the Mac's reader or the
# Pocket's own over USB.
#
# The games and the system cards are the card's own: every PC Engine CD core
# reads Assets/pcecd/common, and Mazamars312's core stays as it was beside this one.
# Nothing there is moved, written over or added. Platforms/pcecd.json is copied only
# when the card has none, and so is its image until the banner has been made
# (art/pcecd-banner.png); from then on the image goes on whenever the card's differs,
# and every PC Engine CD core on the card shows it.
#
# A bitstream older than BITSTREAM_NOT_BEFORE isn't deployed: each Mac builds its
# own, so one can have this firmware and a bitstream from before a change between
# the two. Set it when such a change goes in. The last, 6 Nov 2026 at 17:15: a
# Memory's load answered once its file is in, not once the drive has read the card
# again, as this firmware's park no longer waits on a read; with an older bitstream a
# load waits on the card while the Pocket waits on the load. Before it, 6 Nov 2026: the
# first bitstream that offers save states, whose engine tells this firmware a park is
# for a load (CORE_INPUT[6]); with an older one the Pocket offers no Memories at all.
# Before that, 4 Nov 2026: the save slot holds the MB128 in the PSRAM, and this
# firmware makes it 130K when asked, which an older bitstream would fill with nonsense.
#
# One copy to the card at a time, under /tmp/pocket-card.lock (shared with the
# other cores' deploy scripts). Nothing ejects the card.
# Each verified copy is recorded in build/deployed.txt.

set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
CORE="frazilpop.PCEngineCD"
DIST="$REPO/dist"
BIN="$DIST/Cores/$CORE/bitstream.rbf_r"
FW="$DIST/Assets/pcecd/$CORE/pce_mpu_bios.bin"
RECORD="$REPO/build/deployed.txt"
BITSTREAM_NOT_BEFORE="2026-11-06 17:15"
[ -f "$BIN" ] || { echo "no $BIN - run tools/build.sh first"; exit 1; }

VOL="" STATUS=0
for a in "$@"; do
	case "$a" in --status) STATUS=1 ;; *) VOL="$a" ;; esac
done

built() { stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$BIN"; }
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
find_card() {
	local v
	for v in /Volumes/*; do
		[ -f "$v/Analogue_Pocket.json" ] && { VOL="$v"; return 0; }
	done
	return 1
}

if [ $STATUS = 1 ]; then
	s=$(sha "$BIN")
	echo "Build:   $(built), SHA-256 ${s:0:12}"
	last=$(sed -n 's/^sha256 //p' "$RECORD" 2>/dev/null || true)
	if [ -z "$last" ]; then
		echo "Card:    no deploy recorded"
	else
		echo "Card:    got the build of $(sed -n 's/^built //p' "$RECORD") at $(sed -n 's/^deployed //p' "$RECORD"), SHA-256 ${last:0:12}"
	fi
	if [ -n "$VOL" ] || find_card; then
		f="$VOL/Cores/$CORE/bitstream.rbf_r"
		[ -f "$f" ] && last=$(sha "$f") || last=none
		echo "         (checked on the mounted card, $VOL: ${last:0:12})"
	fi
	# the firmware goes on with the bitstream and isn't in it, so a firmware-only
	# change leaves the bitstream's hash as it was
	fw=$(sha "$FW")
	lastfw=$(sed -n 's/^firmware //p' "$RECORD" 2>/dev/null || true)
	if [ -n "$VOL" ] && [ -f "$VOL/Assets/pcecd/$CORE/pce_mpu_bios.bin" ]; then lastfw=$(sha "$VOL/Assets/pcecd/$CORE/pce_mpu_bios.bin"); fi
	echo "Firmware: this one ${fw:0:12}, on the card ${lastfw:0:12}"
	if [ "$last" != "$s" ]; then echo "NOT ON THE CARD - the current build has not been deployed: tools/deploy.sh"; exit 1; fi
	if [ "$lastfw" != "$fw" ]; then echo "NOT ON THE CARD - the current firmware has not been deployed: tools/deploy.sh"; exit 1; fi
	echo "UP TO DATE - the card has the current build and firmware"
	exit 0
fi

if [ "$(stat -f %m "$BIN")" -lt "$(date -j -f '%Y-%m-%d %H:%M' "$BITSTREAM_NOT_BEFORE" +%s)" ]; then
	echo "This Mac's bitstream, built $(built), is older than this firmware needs ($BITSTREAM_NOT_BEFORE). Build first: tools/build.sh"
	exit 1
fi

[ -n "$VOL" ] || find_card || { echo "No Analogue Pocket SD card found (no volume with Analogue_Pocket.json)"; exit 1; }
[ -f "$VOL/Analogue_Pocket.json" ] || { echo "$VOL is not the Pocket's card"; exit 1; }

LOCK=/tmp/pocket-card.lock
release() {
	[ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ] && rm -rf "$LOCK"
	return 0
}
trap release EXIT
until mkdir "$LOCK" 2>/dev/null; do
	holder=$(cat "$LOCK/pid" 2>/dev/null || true)
	if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then rm -rf "$LOCK"; continue; fi
	[ -n "${told:-}" ] || { echo "Waiting for another deploy to the card (pid ${holder:-?})..."; told=1; }
	sleep 1
done
echo $$ >"$LOCK/pid"

# the core: its folder replaced whole
rm -rf "$VOL/Cores/$CORE"
mkdir -p "$VOL/Cores"
cp -R "$DIST/Cores/$CORE" "$VOL/Cores/"
cmp -s "$BIN" "$VOL/Cores/$CORE/bitstream.rbf_r" || { echo "the bitstream on the card differs from the build"; exit 1; }
echo "Copied the core ($CORE) to $VOL"

# the MPU's firmware
mkdir -p "$VOL/Assets/pcecd/$CORE"
cp "$FW" "$VOL/Assets/pcecd/$CORE/"
cmp -s "$FW" "$VOL/Assets/pcecd/$CORE/pce_mpu_bios.bin" || { echo "the firmware on the card differs from the build"; exit 1; }
echo "Copied the firmware, $(wc -c < "$FW" | tr -d ' ') bytes"

# the platform's name, only when the card has none; its image, also when the repo has a
# banner of its own and the card's differs
mkdir -p "$VOL/Platforms/_images" "$VOL/Assets/pcecd/common"
[ -f "$VOL/Platforms/pcecd.json" ] || cp "$DIST/Platforms/pcecd.json" "$VOL/Platforms/"
if [ ! -f "$VOL/Platforms/_images/pcecd.bin" ] || { [ -f "$REPO/art/pcecd-banner.png" ] && ! cmp -s "$DIST/Platforms/_images/pcecd.bin" "$VOL/Platforms/_images/pcecd.bin"; }; then
	cp "$DIST/Platforms/_images/pcecd.bin" "$VOL/Platforms/_images/"
	echo "Copied the banner (every PC Engine CD core on the card shows it)"
fi

mkdir -p "$(dirname "$RECORD")"
{
	echo "sha256 $(sha "$BIN")"
	echo "firmware $(sha "$FW")"
	echo "built $(built)"
	echo "commit $(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo '?')"
	echo "deployed $(date '+%Y-%m-%d %H:%M')"
	echo "card $VOL"
} >"$RECORD"
echo "Done - the card is left mounted; eject it before taking it out."
