"""What tools/mb128-test.sh's five runs say: the card's colour in each, the save files'
sizes and layout, and the PSRAM's timing faults.

    python3 -I check_mb128.py <its folder> <palette.hex>
"""
import json
import sys

t, palette = sys.argv[1], sys.argv[2]
colours = [int(l, 16) for l in open(palette)]
NAMES = {colours[0x1C0]: 'green', colours[0x007]: 'blue', colours[0x03F]: 'purple', colours[0x1FF]: 'white',
         colours[0x038]: 'red', colours[0x040]: 'working'}
bad = []


def check(ok, what):
    print(('ok    ' if ok else 'WRONG ') + what)
    if not ok:
        bad.append(what)


def read(name):
    return open(f'{t}/{name}', 'rb').read()


def pattern(key, mask=0xFF):
    return bytes((y & mask) ^ key for y in range(128))


def sector(save, n):
    return save[0x800 + n * 128:0x800 + (n + 1) * 128]


want = {'fresh': 'green', 'kept': 'blue', 'old': 'green', 'off': 'purple', 'offbig': 'purple'}
for run, colour in want.items():
    rows = [l.split() for l in open(f'{t}/{run}/frames.txt')]
    last = NAMES.get(int(rows[-1][3], 16), rows[-1][3]) if rows else 'no frames'
    check(last == colour, f'{run}: the card says {last}, wanted {colour}')
    j = json.load(open(f'{t}/{run}/run.json'))
    check(j['psram_ok'], f'{run}: the PSRAM read back its test words')
    check(j['psram_violations'] == 0, f"{run}: {j['psram_violations']} PSRAM timing faults")

fresh, kept, old, off, offbig, old2k = (read(n + '.sav') for n in ('fresh', 'kept', 'old', 'off', 'offbig', 'old2k'))
check(len(fresh) == 0x20800, f'fresh: 2K + 128K, {len(fresh)} bytes')
check(fresh[:4] == b'HUBM', 'fresh: the backup RAM has its header, at the file\'s start')
check(sector(fresh, 3) == pattern(0x5A), 'fresh: sector 3 where MiSTer\'s layout has it, lowest bit first')
check(sector(fresh, 1023) == pattern(0xC3), 'fresh: sector 1023, the last in the file')
check(sector(fresh, 5) == bytes(128), 'fresh: sector 5 cleared at 10 cycles a bit')
check(sum(any(sector(fresh, n)) for n in range(1024)) == 2, 'fresh: nothing else was touched')
check(kept == fresh, 'kept: comes out as it went in')
check(len(old) == 0x20800 and old[:0x800] == old2k, 'old: the 2K kept, in a file now 130K')
check(sum(any(sector(old, n)) for n in range(1024)) == 2, 'old: the MB128 was clear, not whatever the chip held')
check(off == old2k, 'off: the file stays the 2K it was')
check(offbig == fresh, 'offbig: 130K in, 130K out, with the setting off')

print('All good' if not bad else f'{len(bad)} wrong')
sys.exit(1 if bad else 0)
