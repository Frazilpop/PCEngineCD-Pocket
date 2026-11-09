"""Two save states compared region by region (docs/SAVESTATES.md, The format).

    python3 -I tools/state-dump.py A.state B.state     what differs between them
    python3 -I tools/state-dump.py A.state             the header, and which regions hold anything

The header's frame number (0x24) and the save's ask (0x2C to 0x37: the Pocket's menu then, the
frames from the ask to the freeze, the Savestate queries and the last other host command before
it) are left out: a state read straight back after a load has
the load's frame and its own ask. The last line is "N bytes differ" with N 0 when the two are the same.
"""
import struct
import sys

REGIONS = [
    ('header', 0x00000, 0x00100),
    ('CPU chain', 0x00100, 0x00180),
    ('PSG chain', 0x00180, 0x00200),
    ('VDC chain', 0x00200, 0x00280),
    ('VCE chain', 0x00280, 0x00300),
    ('CD chain', 0x00300, 0x00380),
    ('Arcade Card chain', 0x00380, 0x00400),
    ('MPU link chain', 0x00400, 0x00480),
    ('the rest chain', 0x00480, 0x00800),
    ('drive block', 0x00800, 0x01000),
    ('PSG waves', 0x01000, 0x01100),
    ('SAT', 0x01100, 0x01400),
    ('palette', 0x01400, 0x01800),
    ('subcode FIFO', 0x01800, 0x02000),
    ('CPU RAM', 0x02000, 0x04000),
    ('SCSI FIFO', 0x04000, 0x05000),
    ('CD-DA FIFO', 0x05000, 0x06000),
    ('backup RAM', 0x06000, 0x08000),
    ('VRAM', 0x08000, 0x18000),
    ('ADPCM', 0x18000, 0x28000),
    ('CD RAM', 0x28000, 0x70000),
    ('MB128', 0x70000, 0x90000),
    ('Arcade Card RAM', 0x90000, 0x290000),
]
FRAME = set(range(0x24, 0x28)) | set(range(0x2C, 0x38))


def header(d):
    be16 = lambda o: struct.unpack('>H', d[o:o + 2])[0]
    be32 = lambda o: struct.unpack('>I', d[o:o + 4])[0]
    return (f'{d[0:4].decode(errors="replace")} version {be16(4)}, flags {be16(6):04x}, {be32(8)} bytes, '
            f'system card {be32(0x0C)} bytes sum {be32(0x10):08x}, frame {be32(0x24)}, '
            f'raster line {be16(0x28)} clock {be16(0x2A)}; at the ask the menu {"open" if be16(0x2C) >> 15 else "closed"}, '
            f'{"seen" if be16(0x2C) >> 14 & 1 else "never seen"} open, {be16(0x2C) & 0x3FFF} frames since it closed, '
            f'{be16(0x2E)} frames to the freeze; '
            f'a Savestate query {"seen, " + str(be16(0x30) & 0x7FFF) + " lines before" if be16(0x30) >> 15 else "never seen"}, '
            f'{be16(0x32)} since the last ask; the last other command {be16(0x34):04x}, {be16(0x36)} frames before')


def main():
    a = open(sys.argv[1], 'rb').read()
    if len(sys.argv) == 2:
        print(header(a))
        for name, lo, hi in REGIONS:
            if lo < len(a) and any(a[lo:min(hi, len(a))]):
                print(f'  {name}: {sum(1 for x in a[lo:min(hi, len(a))] if x)} bytes not 0')
        return
    b = open(sys.argv[2], 'rb').read()
    print('A:', header(a))
    print('B:', header(b))
    if len(a) != len(b):
        print(f'sizes differ: {len(a)} and {len(b)}')
    total = 0
    for name, lo, hi in REGIONS:
        hi = min(hi, len(a), len(b))
        if lo >= hi:
            continue
        diff = [o for o in range(lo, hi) if a[o] != b[o] and o not in FRAME]
        if diff:
            total += len(diff)
            first = ', '.join(f'{o:05x}: {a[o]:02x} {b[o]:02x}' for o in diff[:6])
            print(f'  {name}: {len(diff)} bytes differ ({first}{" ..." if len(diff) > 6 else ""})')
    print(f'{total} bytes differ')


main()
