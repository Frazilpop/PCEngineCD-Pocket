"""The Analogizer in the simulation (tools/anz-test.sh runs it), checked against the Pocket's
own frames of the same run.

    python3 -I src/sim/console/anz.py DIR [--keys PRESSES]

For each anz_vNN_FFFFF.raw in DIR (the cartridge pins at every clk_sys edge over two
frames, main.cpp's --anz-dump) it takes a whole frame and holds it against the Pocket's
frames saved beside it (f_NNNNN.png), by the mode the word had on. The console's picture
is 2160 clocks of a 2730-clock line, a dot every 4, 6 or 8 clocks (anz_*.txt's div + 1);
the Pocket's frame is the part of it the VDC draws, so it sits inside with black round it,
at a place found from RGBS and held to for the other modes.

  0 RGBS, 1 RGsB  csync (active low) on the sync pin the mode uses, the other pin high;
                  each line's picture where /blank is high, 2160 clocks; the Pocket's frame
                  at 6 bits inside it and black round it; nothing lit in the blanking
  2 YPbPr         Y, Pb and Pr against vga_out's arithmetic on the same, csync on the sync pin
  3, 4 Y/C        the luma against yc_out's sum on the same; the colour burst on every line,
                  its frequency (NTSC's 3.579545 or PAL's 4.43361875 MHz at 42.954545 MHz)
                  and where it lies: after hsync's end and clear of the picture's start
  5-9 the scandoubler  hsync at twice the line's rate, every line twice at half a dot, one
                  of the two dimmed by the scanlines' factor (0, 25, 50, 75 %; 9 as 5)
  a word with [14] set: the Pocket's frames black and the pins' picture lit

anz_idle.txt: no clock with the Analogizer off found the slot other than as it was.

--keys PRESSES (a file of 'F:PAD:buttons:N' lines, as given to --anz-press): anz_keys.txt,
each frame's key1 to key4, against what the word in effect, the pads' type and the buttons
held make of them (openFPGA_Pocket_Analogizer_SNAC.sv's mapping and pocket_analogizer.sv's
assignment), on every frame that held the same buttons as the one before. And RUN on the
screen (the test card's row 15) in the Pocket's frames while Run is held on SNAC pad 1.

Prints a line a check and exits non-zero if any fails.
"""
import glob, math, os, re, struct, sys, zlib

D = sys.argv[1]
KEYS = sys.argv[sys.argv.index('--keys') + 1] if '--keys' in sys.argv else None
LINE = 2730
CLK = 315e6 / 88 * 12                   # 42.954545 MHz
fail = 0


def bad(msg):
    global fail
    fail += 1
    print('  FAILED:', msg)


def load_png(path):
    d = open(path, 'rb').read()
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
    px, prev = [], bytearray(stride)
    for y in range(h):
        at = y * (stride + 1)
        f, row = raw[at], bytearray(raw[at + 1:at + 1 + stride])
        for x in range(stride):
            a = row[x - bpp] if x >= bpp else 0
            b = prev[x]
            c = prev[x - bpp] if x >= bpp else 0
            if f == 1:
                row[x] = (row[x] + a) & 255
            elif f == 2:
                row[x] = (row[x] + b) & 255
            elif f == 3:
                row[x] = (row[x] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                row[x] = (row[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        px.append([row[x] << 16 | row[x + 1] << 8 | row[x + 2] for x in range(0, stride, bpp)])
        prev = row
    return w, h, px


frames = {}
for f in glob.glob(D + '/f_*.png'):
    frames[int(os.path.basename(f)[2:7])] = load_png(f)


def pins(path):
    raw = open(path, 'rb').read()
    b3, b2, b1, m1 = raw[0::5], raw[1::5], raw[2::5], raw[3::5]
    return {'r': [x >> 2 for x in b3], 'hs': [x >> 1 & 1 for x in b3], 'vs': [x & 1 for x in b3],
            'g': [x & 63 for x in b2], 'blank': [x >> 6 & 1 for x in b2],
            'b': [(x & 31) << 1 | y >> 7 for x, y in zip(b1, b2)],
            'out': [x >> 5 == 7 for x in m1], 'n': len(b3)}


def runs(bits, val=1):
    """(start, length) of each run of val"""
    out, i, n = [], 0, len(bits)
    while i < n:
        if bits[i] == val:
            j = i
            while j < n and bits[j] == val:
                j += 1
            out.append((i, j - i))
            i = j
        else:
            i += 1
    return out


def frame_lines(starts):
    """the lines of the first whole frame: a run of starts a line apart, after a gap"""
    groups, cur = [], []
    for s in starts:
        if cur and s - cur[-1] > LINE * 3 // 2:
            groups.append(cur)
            cur = []
        cur.append(s)
    groups.append(cur)
    whole = groups[1:-1] or groups[1:] or groups
    return max(whole, key=len) if whole else []


def c6(p):
    return (p >> 18 & 63, p >> 10 & 63, p >> 2 & 63)


def ypbpr(p):
    r, g, b = p >> 16 & 255, p >> 8 & 255, p & 255
    def lim(v):
        return 0 if v & (1 << 18) else 255 if v & (1 << 16) else v >> 8 & 255
    y = lim(77 * r + 150 * g + 29 * b)
    pb = lim((32768 - 42 * r - 85 * g + 128 * b) & 0x7FFFF)
    pr = lim((32768 + 128 * r - 106 * g - 21 * b) & 0x7FFFF)
    return (pr >> 2, y >> 2, pb >> 2)


def luma(p):
    r, g, b = p >> 16 & 255, p >> 8 & 255, p & 255
    return ((306 * r + 601 * g + 117 * b) >> 10 & 255) >> 2


def embed(f, geo, conv):
    """the Pocket's frame f as the console's whole picture: its rows at geo's place, black round"""
    fw, fh, px = frames[f]
    W, Hp, x0, y0 = geo
    black = conv(0)
    out = []
    for y in range(Hp):
        row = [black] * W
        if y0 <= y < y0 + fh:
            src = px[y - y0]
            for x in range(max(0, x0), min(W, x0 + fw)):
                row[x] = conv(src[x - x0])
        out.append(tuple(row))
    return out


def find_lines(ends, delays, row_at, conv, near_f):
    """the line end, delay and Pocket frame for which row_at(s0, y) is the frame embedded,
    y over the whole picture, s0 a line end's picture start plus a delay; a row with more
    than one colour is tried first, so a wrong start is turned away at once"""
    if geo is None:
        return None
    for f in near_f:
        want = embed(f, geo, conv)
        yr = next((y for y in range(len(want)) if len(set(want[y])) > 1), 0)
        for e in ends:
            for delay in delays:
                s0 = e + porch + delay
                if s0 + geo[1] * LINE >= len(pp['r']):
                    return None
                if row_at(s0, yr) != want[yr]:
                    continue
                if all(row_at(s0, y) == want[y] for y in range(len(want))):
                    return (delay, f)
    return None


def near(f0):
    """the Pocket's frames saved around a recording's"""
    return [f for f in sorted(frames) if f0 - 2 <= f <= f0 + 3]


geo = None                              # (W, Hp, x0, y0), from RGBS
porch = None
for txt in sorted(glob.glob(D + '/anz_v*.txt'), key=lambda t: int(t[-9:-4])):
    m = re.match(r'video (\d+) word ([0-9a-f]+) frames (\d+) (\d+) div (\d+)', open(txt).read())
    v, word, f0, f1, div = int(m.group(1)), int(m.group(2), 16), int(m.group(3)), int(m.group(4)), int(m.group(5))
    dot = div + 1
    W = 2160 // dot
    p = pp = pins(txt[:-4] + '.raw')
    n = p['n']
    name = {0: 'RGBS', 1: 'RGsB', 2: 'YPbPr', 3: 'Y/C NTSC', 4: 'Y/C PAL'}.get(v, f'scandoubler {v}')
    off = word >> 14 & 1
    print(f'{os.path.basename(txt)[:-4]}: video {v} ({name}){", the Pocket black" if off else ""}, a dot every {dot} clocks, '
          f'{n} clocks')
    if not all(p['out']):
        bad('the video pins not outputs on every clock')
    near_f = near(f0)

    if off:
        lit = sum(1 for f in near_f for row in frames[f][2] for x in row if x)
        pic = sum(1 for i in range(n) if p['r'][i] or p['g'][i] or p['b'][i])
        print(f'  the Pocket\'s frames {near_f}: {lit} dots lit; the pins: {pic} clocks lit')
        if lit or not pic:
            bad('the Pocket\'s screen not black, or the adapter\'s picture not there')
        continue

    if v in (0, 1, 2):
        sync = p['hs'] if v == 0 else p['vs']
        other = p['vs'] if v == 0 else p['hs']
        if any(x != 1 for x in other):
            bad('the other sync pin not held high')
        falls = [s for s, _ in runs(sync, 0)]
        lines_ok = sum(1 for a, b in zip(falls, falls[1:]) if b - a == LINE)
        print(f'  csync: {len(falls)} pulses, {lines_ok} a line apart, widths {sorted(set(l for _, l in runs(sync, 0)))[:4]}')
        if lines_ok < 400:
            bad('csync not a pulse a line')
        ends = [s + l for s, l in runs(sync, 0) if l < 400]
        if v in (0, 1):
            pic = runs(p['blank'], 1)
            widths = sorted(set(l for _, l in pic))
            if widths != [2160]:
                bad(f'picture runs of {widths} clocks')
            lit_blank = sum(1 for i in range(n) if not p['blank'][i] and (p['r'][i] or p['g'][i] or p['b'][i]))
            if lit_blank:
                bad(f'{lit_blank} clocks lit in the blanking')
            starts = frame_lines([s for s, _ in pic])
            rows = [tuple((p['r'][s + k * dot + dot // 2], p['g'][s + k * dot + dot // 2], p['b'][s + k * dot + dot // 2])
                          for k in range(W)) for s in starts]
            pr = [s - max(e for e in ends if e <= s) for s in starts[:50] if any(e <= s for e in ends)]
            porch = min(pr) if pr else None
            # the place of the Pocket's frame in the picture: its first row with more than one
            # colour, found in the first picture row that has it
            found = None
            for f in near_f:
                fw, fh, px = frames[f]
                yr = next((y for y in range(fh) if len(set(px[y])) > 1), None)
                if yr is None:
                    continue
                want = tuple(c6(x) for x in px[yr])
                for yy, row in enumerate(rows):
                    # (a frame wider than the picture's window is cut by hblank, as the console's is)
                    for x0 in range(min(0, W - fw) - 32, max(0, W - fw) + 33):
                        a, b = max(0, x0), min(W, x0 + fw)
                        if b - a >= min(fw, W) - 32 and row[a:b] == want[a - x0:b - x0]:
                            g_ = (W, len(rows), x0, yy - yr)
                            if embed(f, g_, c6) == rows:
                                found = (f, g_)
                            break
                    if found:
                        break
                if found:
                    break
            if found and (geo is None or geo[0] != W):
                geo = found[1]
            print(f'  picture: {len(rows)} lines of {W} dots, ' +
                  (f'the Pocket\'s frame {found[0]} ({frames[found[0]][0]} x {frames[found[0]][1]}) at dot {found[1][2]}, '
                   f'line {found[1][3]}, every dot at 6 bits, black round it' +
                   (f' ({max(0, -found[1][2]) + max(0, found[1][2] + frames[found[0]][0] - W)} of its columns outside the window)'
                    if found[1][2] < 0 or found[1][2] + frames[found[0]][0] > W else '')
                   if found else 'no frame of the Pocket\'s matched') +
                  f'; hsync\'s end to the picture {porch} clocks')
            if not found:
                bad('the picture is not the Pocket\'s frame')
        else:
            row_at = lambda s0, y: tuple((p['r'][s0 + y * LINE + k * dot + dot // 2], p['g'][s0 + y * LINE + k * dot + dot // 2],
                                          p['b'][s0 + y * LINE + k * dot + dot // 2]) for k in range(W))
            got = find_lines(ends, range(0, 8), row_at, ypbpr, near_f)
            print('  Y, Pb, Pr: ' + (f'frame {got[1]}, every dot as vga_out makes it, {got[0]} clocks behind RGBS'
                                     if got else 'no frame matched'))
            if not got:
                bad('YPbPr is not the frame through vga_out')

    elif v in (3, 4):
        if any(x != 1 for x in p['vs']):
            bad('the other sync pin not held high')
        sync_runs = [(s, l) for s, l in runs(p['hs'], 0) if l < 400]
        fsc = 4.43361875e6 if v == 4 else 3.579545e6
        freqs, spans = [], []
        for j, (s, l) in enumerate(sync_runs[20:-2]):
            e = s + l
            c = [p['r'][i] - 32 for i in range(e, e + 400)]
            on = [i for i, x in enumerate(c) if abs(x) >= 3 and i < (porch or 400)]
            if not on:          # (vsync's lines have no burst)
                continue
            a, b = on[0], on[-1]
            spans.append((a, b))
            seg = c[a + 4:b - 3]
            if len(seg) < 40 or j % 8:
                continue
            mean = sum(seg) / len(seg)
            seg = [x - mean for x in seg]
            def power(fr):
                re_ = sum(x * math.cos(2 * math.pi * fr * i / CLK) for i, x in enumerate(seg))
                im_ = sum(x * math.sin(2 * math.pi * fr * i / CLK) for i, x in enumerate(seg))
                return re_ * re_ + im_ * im_
            grid = [fsc * (0.9 + 0.002 * k) for k in range(101)]
            k = max(range(101), key=lambda k: power(grid[k]))
            lo, hi = grid[max(k - 1, 0)], grid[min(k + 1, 100)]
            for _ in range(30):
                m1, m2 = hi - (hi - lo) * 0.618, lo + (hi - lo) * 0.618
                if power(m1) < power(m2):
                    lo = m1
                else:
                    hi = m2
            freqs.append((lo + hi) / 2)
        last = max(b for _, b in spans) if spans else None
        fr = sorted(freqs)[len(freqs) // 2] if freqs else 0
        print(f'  burst on {len(spans)} lines, {fr / 1e6:.4f} MHz on {len(freqs)} of them (wanted {fsc / 1e6:.6f}), '
              f'clocks {min(a for a, _ in spans) if spans else "-"} to {last} after hsync ends, the picture at {porch}')
        if abs(fr - fsc) / fsc > 0.002 or len(spans) < 400:
            bad('the burst is not the subcarrier on every line')
        if porch is None or last is None or last + 5 >= porch:
            bad('the burst runs into the picture')
        row_at = lambda s0, y: tuple(p['g'][s0 + y * LINE + k * dot + dot // 2] for k in range(W))
        got = find_lines([s + l for s, l in sync_runs], range(0, 16), row_at, luma, near_f)
        print('  luma: ' + (f'frame {got[1]}, every dot as yc_out sums it, {got[0]} clocks behind' if got else 'no frame matched'))
        if not got:
            bad('the luma is not the frame through yc_out')

    else:
        lines = {5: 0, 6: 1, 7: 2, 8: 3, 9: 0}[v]
        coeff = [0x40, 0x3a, 0x2e, 0x1a][lines]
        hs0, hs1 = runs(p['hs'], 0), runs(p['hs'], 1)
        pulses = hs0 if len(hs0) > len(hs1) and min(l for _, l in hs0) < 400 else hs1
        starts = [s for s, _ in pulses]
        half = sum(1 for a, b in zip(starts, starts[1:]) if abs(b - a - LINE / 2) <= 1)
        print(f'  hsync: {len(starts)} pulses, {half} half a line apart ({LINE / 2:.0f} clocks, '
              f'{CLK / (LINE / 2) / 1e3:.2f} kHz)')
        if half < 800:
            bad('hsync not at twice the line rate')
        hd = dot // 2
        sample = lambda s, o: tuple((p['r'][s + o + k * hd], p['g'][s + o + k * hd], p['b'][s + o + k * hd]) for k in range(W))
        dim = lambda row: tuple(tuple(c * coeff >> 6 for c in t) for t in row)
        got = None
        if geo is not None:
            for f in near_f:
                want = embed(f, geo, c6)
                wd = [dim(r) for r in want]
                yr = next((y for y in range(len(want)) if len(set(want[y])) > 1), None)
                # the offset in an output line: where a lit row of the frame is, as it is or dimmed
                for i, s in enumerate(starts[:-2]):
                    if s + LINE // 2 >= n:
                        break
                    for o in range(0, LINE // 2 - W * hd):
                        row = sample(s, o)
                        if row == want[yr] or row == wd[yr]:
                            # line i is the frame's row yr, once; the frame's first row 2 * yr earlier or
                            # one less, as the pair goes
                            for i0 in (i - 2 * yr, i - 2 * yr - 1):
                                if i0 < 0 or i0 + 2 * len(want) >= len(starts):
                                    continue
                                if all({(sample(starts[i0 + 2 * y], o), sample(starts[i0 + 2 * y + 1], o))} &
                                       {(want[y], wd[y]), (wd[y], want[y])} for y in range(len(want))):
                                    got = (f, o)
                                    break
                            break
                    if got or (yr is not None and i > 2 * len(want) + 4):
                        break
                if got:
                    break
        print('  picture: ' + (f'frame {got[0]}, every line twice at half a dot, one of each pair at {coeff}/64'
                              if got else 'no frame matched'))
        if not got:
            bad('the scandoubler\'s lines are not the frame\'s, each twice')

idle = open(D + '/anz_idle.txt').read().strip() if os.path.exists(D + '/anz_idle.txt') else None
print(f'anz_idle.txt: {idle}')
m = re.match(r'off (\d+) clocks, (\d+) not as before', idle or '')
if not m or int(m.group(2)):
    bad('the slot not as before with the Analogizer off')

if KEYS:
    NAMES = ['up', 'right', 'down', 'left', 'i', 'ii', 'select', 'run', 'iii', 'iv', 'v', 'vi']
    # SNAC: held order up, right, down, left, I, II, Select, Run, III to VI; the Pocket's: up,
    # down, left, right, A, B, X, Y, L1, R1, L2, R2, L3, R3, select, start
    def k2(h):
        return ((h & 1) | (h >> 2 & 1) << 1 | (h >> 3 & 1) << 2 | (h >> 1 & 1) << 3 | (h >> 4 & 3) << 4 |
                (h >> 6 & 1) << 14 | (h >> 7 & 1) << 15)
    def k6(h):
        return k2(h) | (h >> 8 & 15) << 6
    def expect(word, ptype, held):
        on, ctype, asg = word >> 5 & 1, word & 31, word >> 6 & 15
        ok = on and ctype in (1, 2, 3, 4, 5, 6, 9, 11)
        s = [0, 0, 0, 0]
        if ctype == 4 and ptype == 1:
            s[0] = k2(held[0])
        elif ctype == 5 and ptype == 2:
            s[0] = k6(held[0])
        elif ctype == 6 and ptype == 3:
            s = [k2(h) for h in held[:4]]
        sel = [0, 0, 0, 0]
        if ok:
            sel[0] = 1 if asg in (0, 2, 5) else 2 if asg == 3 else 0
            sel[1] = 1 if asg in (1, 3) else 2 if asg in (2, 5) else 0
            sel[2] = 1 if asg == 4 else 3 if asg == 5 and ctype == 6 else 0
            sel[3] = 2 if asg == 4 else 4 if asg == 5 and ctype == 6 else 0
        return [s[x - 1] if x else 0 for x in sel]
    rows = []
    for l in open(D + '/anz_keys.txt'):
        t = l.split()
        rows.append((int(t[0]), int(t[1], 16), int(t[2]), [int(x, 16) for x in t[3:8]], [int(x, 16) for x in t[8:12]], int(t[12])))
    checked = wrong = pressed = 0
    seen = set()
    for (f, w, pt, held, keys, _), prev in zip(rows[1:], rows):
        if held != prev[3] or w != prev[1] or pt != prev[2]:
            continue
        want = expect(w, pt, held)
        checked += 1
        if any(held):
            pressed += 1
            for pad, h in enumerate(held):
                for b in range(12):
                    if h >> b & 1:
                        seen.add((w & 31, w >> 6 & 15, pad, NAMES[b]))
        if keys != want:
            wrong += 1
            if wrong <= 6:
                print(f'  frame {f}: word {w:08x}, pads {pt}, held {[hex(h) for h in held]}: keys {[hex(k) for k in keys]}, '
                      f'wanted {[hex(k) for k in want]}')
    print(f'anz_keys.txt: {checked} steady frames checked, {pressed} with buttons held '
          f'({len(seen)} button, pad, controller and assignment together), {wrong} wrong')
    if wrong or not pressed:
        bad('SNAC\'s buttons not where the word puts them')
    # RUN on the test card's row 15 while Run is held on SNAC pad 1 for player 1
    run_frames = [f for (f, w, pt, held, keys, _), prev in zip(rows[1:], rows)
                  if held == prev[3] and keys[0] >> 15 & 1 and f in frames]
    idle_frames = [f for (f, w, pt, held, keys, _), prev in zip(rows[1:], rows)
                   if held == prev[3] and not keys[0] >> 15 & 1 and f in frames and w & 0x20]
    def row15(f):
        fw, fh, px = frames[f]
        return sum(1 for y in range(120, 128) for x in px[y] if x == 0xFFFFFF)
    rf, idl = [row15(f) for f in run_frames], [row15(f) for f in idle_frames]
    print(f'RUN on the screen: {rf} white dots on row 15 in frames {run_frames} with Run held on SNAC pad 1; '
          f'{sorted(set(idl))} in the {len(idle_frames)} frames saved without')
    if not rf or not all(rf) or any(idl):
        bad('the console did not see SNAC\'s Run')

print('every check right' if not fail else f'{fail} checks failed')
sys.exit(1 if fail else 0)
