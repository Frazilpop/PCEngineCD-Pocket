"""The simulation's frames beside MAME's (tools/mame-frames.sh), paired by what they show.

    python3 -I src/sim/console/compare.py [build/sim_pce] [build/mame_pce] [--sheet OUT.png]

MAME's picture is 1088 across, four to a dot at 5.37 MHz (three at 7.16, two at 10.74),
and its seeks take less time, so a sim frame's number says little about which of MAME's
it is. For each of the sim's f_NNNNN.png this looks through all of MAME's from where the
last match was, for the one that differs least, and prints it. Colours are compared as
the console's own 9 bits: main.sv's palette.mif turns those into the sim's colours
(build/sim/gen/palette.hex, read backwards here), and MAME's are the same 9 bits spread
evenly. At 5.37 MHz the sim's picture sits 9 dots right of MAME's left edge and 2 lines
above its top: the sim's top two lines aren't in MAME's picture, so aren't compared (the
other clocks' offsets are found on their first frame with something in it, and kept).
--sheet writes the pairs side by side.

A frame that differs a lot and has a big jump in MAME's number is worth looking at, and
fades give a few hundred pixels' difference without meaning anything. The exit is 1 if
some frame has no match within 2% of its pixels.
"""
import struct
import sys
import zlib
from array import array
from operator import ne
from pathlib import Path

MAME_W = 1088


def load(p):
    d = p.read_bytes()
    i, idat = 8, []
    while i < len(d):
        n, t = struct.unpack('>I4s', d[i:i + 8])
        c = d[i + 8:i + 8 + n]
        i += 12 + n
        if t == b'IHDR':
            w, h, _, ctype = struct.unpack('>IIBB', c[:10])
        elif t == b'IDAT':
            idat.append(c)
    bpp = {2: 3, 6: 4}[ctype]
    raw, stride = zlib.decompress(b''.join(idat)), w * bpp
    rows, prev = [], bytearray(stride)
    for y in range(h):
        at = y * (stride + 1)
        f, row = raw[at], bytearray(raw[at + 1:at + 1 + stride])
        if f == 1:
            for x in range(bpp, stride):
                row[x] = (row[x] + row[x - bpp]) & 255
        elif f == 2:
            for x in range(stride):
                row[x] = (row[x] + prev[x]) & 255
        elif f == 3:
            for x in range(stride):
                row[x] = (row[x] + ((row[x - bpp] if x >= bpp else 0) + prev[x]) // 2) & 255
        elif f == 4:
            for x in range(stride):
                a, b, c = row[x - bpp] if x >= bpp else 0, prev[x], prev[x - bpp] if x >= bpp else 0
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                row[x] = (row[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(bytes(row))
        prev = row
    return w, h, bpp, rows


def dots(rows, w, bpp, step):
    """MAME's picture: each row as an array of 9-bit colours (r, g, b), from the middle of each dot."""
    out = []
    for row in rows:
        out.append(array('H', (((row[x * bpp] >> 5) << 6) | ((row[x * bpp + 1] >> 5) << 3) | (row[x * bpp + 2] >> 5)
                               for x in range(step // 2, w, step))))
    return out


def palette(path):
    """The sim's colour back to the same 9 bits. The table is indexed {g, r, b}."""
    back = {}
    for i, line in enumerate(open(path)):
        g, r, b = i >> 6, (i >> 3) & 7, i & 7
        back.setdefault(int(line, 16), (r << 6) | (g << 3) | b)
    return back


def sim_dots(rows, w, bpp, back):
    out = []
    for row in rows:
        out.append(array('H', (back.get((row[x] << 16) | (row[x + 1] << 8) | row[x + 2], 0) for x in range(0, w * bpp, bpp))))
    return out


def step_for(sim_w):
    # dots across at 5.37 (256ish), 7.16 (341ish), 10.74 (512ish)
    return 4 if sim_w < 300 else 3 if sim_w < 420 else 2


def align(sim, ref):
    """The offset of the sim's picture in MAME's that makes them agree most: a sparse search."""
    best = None
    h, w = len(sim), len(sim[0])
    ys = range(0, h, 7)
    xs = range(0, w, 3)
    for dy in range(-20, 21):
        for dx in range(-24, 25):
            same = n = 0
            for y in ys:
                ry = y + dy
                if not 0 <= ry < len(ref):
                    continue
                r, s = ref[ry], sim[y]
                for x in xs:
                    rx = x + dx
                    if 0 <= rx < len(r):
                        n += 1
                        same += s[x] == r[rx]
            if n and (best is None or same / n > best[0]):
                best = (same / n, dx, dy)
    return best[1], best[2]


def differ(sim, ref, dx, dy, stop):
    """How many dots differ, giving up once it's past stop."""
    d = 0
    for y, s in enumerate(sim):
        ry = y + dy
        if not 0 <= ry < len(ref):
            continue
        r = ref[ry]
        a, b = (s, r[dx:]) if dx >= 0 else (s[-dx:], r)
        n = min(len(a), len(b))
        if a[:n] != b[:n]:
            d += sum(map(ne, a[:n], b[:n]))
            if d >= stop:
                return d
    return d


def busy(rows):
    return len({v for r in rows for v in r[::2]}) > 4


def write_png(path, w, h, rows):
    def chunk(t, d):
        return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d))
    raw = b''.join(b'\0' + bytes(r) for r in rows)
    path.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
                     + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))


def rgb(v):
    return ((v >> 6) * 36, ((v >> 3) & 7) * 36, (v & 7) * 36)


def main():
    args, sheet = [], None
    it = iter(sys.argv[1:])
    for a in it:
        if a == '--sheet':
            sheet = Path(next(it))
        else:
            args.append(a)
    sim_dir = Path(args[0] if args else 'build/sim_pce')
    ref_dir = Path(args[1] if len(args) > 1 else 'build/mame_pce')
    refs = sorted(ref_dir.glob('f_*.png'))
    if not refs:
        print(f'no frames in {ref_dir}: tools/mame-frames.sh first')
        sys.exit(2)
    back = palette(sim_dir.parent / 'sim' / 'gen' / 'palette.hex')
    cache, offsets, pairs = {}, {4: (9, -2)}, []
    last, bad = 0, 0

    def ref_dots(i, step):
        if (i, step) not in cache:
            w, h, bpp, rows = load(refs[i])
            cache[i, step] = dots(rows, w, bpp, step)
        return cache[i, step]

    for f in sorted(sim_dir.glob('f_*.png')):
        n = int(f.stem[2:])
        w, h, bpp, rows = load(f)
        sim = sim_dots(rows, w, bpp, back)
        step = step_for(w)
        if step not in offsets and busy(sim):
            # against the MAME frame with the same sort of picture nearest in time
            guess = min(range(last, len(refs)), key=lambda i: abs(int(refs[i].stem[2:]) - n))
            offsets[step] = align(sim, ref_dots(guess, step))
        dx, dy = offsets.get(step, (0, 0))
        best = None
        for i in range(last, len(refs)):
            d = differ(sim, ref_dots(i, step), dx, dy, best[1] if best else w * h + 1)
            if best is None or d < best[1]:
                best = (i, d)
            if d == 0:
                break
        i, d = best
        last = i
        total = w * h
        m = int(refs[i].stem[2:])
        note = (' – the same' if d == 0 else '') + ('' if busy(sim) else ', and nearly blank, so it says little')
        print(f'frame {n}: MAME\'s {m} ({m - n:+d}), {d} of {total} dots differ{note}', flush=True)
        bad += d > total * 0.02
        if sheet:
            pairs.append((sim, ref_dots(i, step), dx, dy))
    if sheet and pairs:
        W, H, COLS = 256, 232, 4
        rows_out = []
        for c in range(0, len(pairs), COLS):
            row_pairs = pairs[c:c + COLS]
            for y in range(H):
                line = bytearray()
                for sim, ref, dx, dy in row_pairs:
                    for src, ox, oy in ((sim, 0, 0), (ref, dx, dy)):
                        ry = y + oy
                        r = src[ry] if 0 <= ry < len(src) else []
                        for x in range(W):
                            rx = x + ox
                            line += bytes(rgb(r[rx])) if 0 <= rx < len(r) else b'\x30\x30\x30'
                    line += b'\x60\x20\x60' * 2
                line += b'\x30\x30\x30' * ((2 * W + 2) * (COLS - len(row_pairs)))
                rows_out.append(line)
            rows_out.append(bytearray(b'\x60\x20\x60' * ((2 * W + 2) * COLS)))
        write_png(sheet, (2 * W + 2) * COLS, len(rows_out), rows_out)
        print(f'{len(pairs)} pairs in {sheet}: the sim\'s left, MAME\'s right')
    print(f'{offsets and "offsets (dx, dy) by dots-per-clock step: " + str(offsets) or ""}')
    sys.exit(1 if bad else 0)


main()
