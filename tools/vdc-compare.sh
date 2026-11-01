#!/bin/sh
# PC Engine CD for Analogue Pocket: the VDC and VCE, old against new, in GHDL.
#
#   tools/vdc-compare.sh [commit]   commit's chips (default 460d0b2, 0.3.0) against the tree's
#
# For the common display modes it prints, per mode and chip, what the Pocket's line
# buffer would take: pixels a line, where the display starts after HSync, how many
# lines. src/sim/vdc/tb.vhd holds the modes' registers. A change to huc6260.vhd or
# huc6270.vhd must leave the pixels a line alone, or core/linebuffer.v needs a look.
# Takes about eight minutes.

set -eu
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
old=${1:-460d0b2}
image=pce-ghdl:1
work=$repo/build/vdc-compare
rm -rf "$work"; mkdir -p "$work/old" "$work/new"
for f in huc6260.vhd huc6270.vhd; do
    git -C "$repo" show "$old:src/fpga/core/rtl/$f" > "$work/old/$f"
    cp "$repo/src/fpga/core/rtl/$f" "$work/new/$f"
done
# A reset value of two bits for a four-bit field: Quartus lets it by, GHDL doesn't.
sed -i '' "s/'0',\"00\",'0','0',\"00\",/'0',\"0000\",'0','0',\"00\",/" "$work/old/huc6270.vhd" "$work/new/huc6270.vhd"
# Registers power up at 0 on the FPGA and undefined in GHDL; the old VCE's counters have no reset.
perl -pi -e "s/^(\s*signal\s+[\w,\s]+:\s*(?:std_logic_vector|unsigned)\s*\([^;:]*\))\s*;/\$1 := (others => '0');/; s/^(\s*signal\s+[\w,\s]+:\s*std_logic)\s*;/\$1 := '0';/" "$work/old/huc6260.vhd" "$work/old/huc6270.vhd" "$work/new/huc6260.vhd" "$work/new/huc6270.vhd"
cp "$repo/src/sim/vdc/dut_old.vhd" "$work/old/dut.vhd"
cp "$repo/src/sim/vdc/dut_new.vhd" "$work/new/dut.vhd"

# name dot hsr hdr
modes='256x240,0,0x0202,0x031F 240x240,0,0x0302,0x051D 272x240,0,0x0202,0x0121 336x240,1,0x0503,0x0629 352x240,1,0x0303,0x062B 512x240,2,0x0B02,0x0E3F'

# Native, as the firmware's image is: ghdl/ghdl has only amd64, emulated it takes hours.
if ! docker image inspect "$image" >/dev/null 2>&1; then
    echo "== making the $image Docker image, once; a minute or two"
    printf 'FROM ubuntu:24.04\nRUN apt-get update -qq && apt-get install -y -qq --no-install-recommends ghdl gcc libc6-dev zlib1g-dev >/dev/null && rm -rf /var/lib/apt/lists/*\n' \
        | docker build -q -t "$image" -
fi

docker run --rm -v "$repo":/r -w /r/build/vdc-compare "$image" sh -c "
set -e
total=$(( $(echo "$modes" | wc -w) * 2 ))
n=0
for side in old new; do
    (cd \$side
     ghdl -a --std=08 -fsynopsys -fexplicit -frelaxed ../../../src/sim/vdc/stubs.vhd huc6260.vhd huc6270.vhd dut.vhd ../../../src/sim/vdc/tb.vhd 2>&1 | grep -E 'error' || true
     ghdl -e --std=08 -fsynopsys -fexplicit -frelaxed tb)
    for m in $modes; do
        IFS=, read name dot hsr hdr <<X
\$m
X
        (cd \$side; ./tb -gDOT=\$dot -gHSR=\$((hsr)) -gHDR=\$((hdr)) -gNAME=\$side:\$name --ieee-asserts=disable --stop-time=80ms > ../\$side-\$name.txt) &
    done
    wait
    n=\$((n+$(echo "$modes" | wc -w)))
    echo \"\$n of \$total\"
done
"
python3 -I - "$work" <<'PY'
import glob, os, re, sys, collections
work = sys.argv[1]
modes = {}
for path in sorted(glob.glob(os.path.join(work, '*-*.txt'))):
    side, name = os.path.basename(path)[:-4].split('-')
    rows = []
    for line in open(path):
        vals = re.findall(r'(\w+) (-?\d+)', line.split(':', 1)[1])
        rows.append({k: int(v) for k, v in vals})
    modes.setdefault(name, {})[side] = rows
fmt = '{:9} {:4} {:>6} {:>7} {:>7} {:>8} {:>9} {:>9} {:>9} {:>7}'
print(fmt.format('mode', 'chip', 'lines', 'clocks', 'writes', 'colour', '1stcolour', '1stwrite', 'borderoff', 'hbloff'))
bad = 0
for name in sorted(modes, key=lambda n: int(n.split('x')[0])):
    summary = {}
    for side in ('old', 'new'):
        rows = modes[name].get(side, [])
        shown = [r for r in rows if r['writes'] > 0]
        common = lambda k: collections.Counter(r[k] for r in shown).most_common(1)[0][0] if shown else 0
        summary[side] = {k: common(k) for k in ('clocks', 'writes', 'colour', 'firstcolour', 'firstwrite', 'borderoff', 'hbloff')}
        summary[side]['lines'] = len(shown)
        s = summary[side]
        print(fmt.format(name, side, s['lines'], s['clocks'], s['writes'], s['colour'], s['firstcolour'], s['firstwrite'], s['borderoff'], s['hbloff']))
    if summary['old']['writes'] != summary['new']['writes'] or summary['old']['lines'] != summary['new']['lines']:
        bad += 1
print('same pixels a line and lines in every mode' if not bad else f'{bad} mode(s) differ in pixels a line or lines')
PY
