#!/bin/bash
# PC Engine CD for the Analogue Pocket: the release zip.
#
#   tools/release.sh            build/release/pcenginecd-VERSION.zip
#
# One zip with Cores/, Platforms/ and Assets/ at its root, as it goes onto the
# card: dist/ as git tracks it (no .gitkeep, no .DS_Store, the platform banner
# included) and the bitstream in dist/, which git doesn't track and which is
# refused unless its SHA-256 is the one below: the bitstream played through on
# the Pocket. The firmware is dist/'s, tracked, and held to its SHA-256 too, as
# the two go together. VERSION is core.json's. The zip's dates are the commit's,
# so the same commit makes the same zip.
#
# Refused too: changes to dist/ not committed, a core folder whose name isn't
# core.json's author.shortname exactly (the name the Pocket and the library
# look for), and a core.json whose date_release isn't the commit's day.
# Afterwards the zip is unpacked into an empty folder and held against dist/,
# file by file.

set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
BITSTREAM_SHA256=52d259fd7b8d9800c0a937fda58fea7a2147c472bf5ff3ab33d18edbbd03ab3a
FIRMWARE_SHA256=c087f589f7ce18356653d31ca65344ad725ff007d03b5fe3242cc5b2c1507b3c
OUT="$REPO/build/release"
cd "$REPO"

die() { echo "release: $*" >&2; exit 1; }
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

[ -z "$(git status --porcelain -- dist)" ] || die "dist/ has changes not committed"
cores=$(git ls-files dist/Cores | cut -d/ -f3 | sort -u)
[ "$(echo "$cores" | wc -l | tr -d ' ')" = 1 ] || die "expected one core in dist/Cores, found: $cores"
BIN="dist/Cores/$cores/bitstream.rbf_r"
FW="dist/Assets/pcecd/$cores/pce_mpu_bios.bin"
[ -f "$BIN" ] || die "no $BIN"
[ "$(sha "$BIN")" = "$BITSTREAM_SHA256" ] || die "$BIN is not the released bitstream (SHA-256 $(sha "$BIN"), expected $BITSTREAM_SHA256)"
[ "$(sha "$FW")" = "$FIRMWARE_SHA256" ] || die "$FW is not the released firmware (SHA-256 $(sha "$FW"), expected $FIRMWARE_SHA256)"

JSON="dist/Cores/$cores/core.json"
read -r AUTHOR SHORT VERSION DATE < <(python3 -I -c '
import json, sys
m = json.load(open(sys.argv[1]))["core"]["metadata"]
print(m["author"], m["shortname"], m["version"], m["date_release"])' "$JSON")
[ "$cores" = "$AUTHOR.$SHORT" ] || die "the core folder is $cores but core.json makes it $AUTHOR.$SHORT"
DAY=$(TZ=UTC git log -1 --format=%cd --date=format-local:%Y-%m-%d)
[ "$DATE" = "$DAY" ] || die "core.json's date_release is $DATE, the commit's day $DAY"

mkdir -p "$OUT"
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/pcecd-release.XXXXXX")
CHECK=$(mktemp -d "${TMPDIR:-/tmp}/pcecd-release-check.XXXXXX")
trap 'rm -rf "$STAGE" "$CHECK"' EXIT

# dist/ as tracked; a .gitkeep only says its folder belongs in the zip
git ls-files -z dist | while IFS= read -r -d '' f; do
	rel=${f#dist/}
	mkdir -p "$STAGE/$(dirname "$rel")"
	case "$(basename "$rel")" in .gitkeep|.keep|.DS_Store) continue ;; esac
	cp "$f" "$STAGE/$rel"
done
cp "$BIN" "$STAGE/Cores/$cores/bitstream.rbf_r"

STAMP=$(TZ=UTC git log -1 --format=%cd --date=format-local:%Y%m%d%H%M.%S)
find "$STAGE" -exec env TZ=UTC touch -t "$STAMP" {} +
ZIP="$OUT/pcenginecd-$VERSION.zip"
rm -f "$ZIP"
(cd "$STAGE" && find Assets Cores Platforms | LC_ALL=C sort | TZ=UTC zip -X -q "$ZIP" -@)

# the stranger's look: unpacked into an empty folder, held against dist/
unzip -q "$ZIP" -d "$CHECK"
[ "$(ls "$CHECK" | tr '\n' ' ')" = "Assets Cores Platforms " ] || die "the zip's root is $(ls "$CHECK" | tr '\n' ' ')"
[ -d "$CHECK/Assets/pcecd/common" ] || die "the zip has no Assets/pcecd/common"
n=0
while IFS= read -r -d '' f; do
	rel=${f#dist/}
	case "$(basename "$rel")" in .gitkeep|.keep) continue ;; esac
	cmp -s "$f" "$CHECK/$rel" || die "$rel differs from dist/"
	n=$((n + 1))
done < <(git ls-files -z dist)
cmp -s "$BIN" "$CHECK/Cores/$cores/bitstream.rbf_r" || die "the bitstream differs"
extra=$(cd "$CHECK" && find . -type f | sed 's|^\./||' | LC_ALL=C sort | grep -vxF -f <(git -C "$REPO" ls-files dist | sed 's|^dist/||'; echo "Cores/$cores/bitstream.rbf_r") || true)
[ -z "$extra" ] || die "the zip holds files dist/ doesn't: $extra"

echo "$ZIP"
echo "  $cores $VERSION ($DATE), $((n + 1)) files, the bitstream ${BITSTREAM_SHA256:0:12}, the firmware ${FIRMWARE_SHA256:0:12}"
echo "  SHA-256 $(sha "$ZIP")"
