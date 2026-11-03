#!/usr/bin/env python3
"""PC Engine CD for Analogue Pocket: a CD+G test disc, made here so that CD+G can
be tried with no karaoke disc to hand.

    tools/cdg-test-disc.py [folder]            write the discs (build/cdg-test)
    tools/cdg-test-disc.py --check [folder]    read them back as a player does

Three CUEs of 30 seconds, two tracks each, a beep on each second:

    CDG Test.cue          audio in a .bin, its graphics in CDG Test.sub (CloneCD's
                          form, what MiSTer reads)
    CDG Test Track.cue    one TRACK CDG, 2448 a sector, the graphics in its sectors
    CDG Test Plain.cue    the first disc's audio with no .sub, so the drive makes up
                          subcode Q and the GRAPHICS screen has no pictures to show

The screen says CD+G, the track and the seconds, the seconds changing on the beep.
The subcode is true to the standard: packs of 24 six-bit symbols at 300 a second,
Reed-Solomon over GF(64) with x^6+x+1, symbols 1/18, 2/5 and 3/23 swapped, and each
symbol i put off by i mod 8 packs. --check undoes that, tests the parity and writes
the packs as a .cdg, for ffmpeg's own decoder to draw.
"""
import math, os, struct, sys

SECTOR = 2352
SECONDS = (20, 10)      # the two tracks
FRAMES = sum(SECONDS) * 75
PACKS_A_SECTOR = 4
PACK = 24

# ------------------------------------------------------------------ GF(64)
EXP, LOG = [0] * 126, [0] * 64
x = 1
for i in range(63):
    EXP[i] = EXP[i + 63] = x
    LOG[x] = i
    x <<= 1
    if x & 64:
        x ^= 0b1000011  # x^6 + x + 1


def mul(a, b):
    return EXP[LOG[a] + LOG[b]] if a and b else 0


def generator(n):
    """(x - a^0)(x - a^1)...(x - a^(n-1)), highest power first."""
    g = [1]
    for i in range(n):
        out = g + [0]
        for j, c in enumerate(g):
            out[j + 1] ^= mul(c, EXP[i])
        g = out
    return g


def parity(symbols, n):
    """What makes symbols + parity a codeword of the code with n checks."""
    g, rem = generator(n), list(symbols) + [0] * n
    for i in range(len(symbols)):
        c = rem[i]
        if c:
            for j, k in enumerate(g):
                rem[i + j] ^= mul(c, k)
    return rem[-n:]


def syndromes_clear(symbols, n):
    for i in range(n):
        s = 0
        for c in symbols:
            s = mul(s, EXP[i]) ^ c
        if s:
            return False
    return True


# ---------------------------------------------------------------- the packs
def pack(instruction, data=()):
    """One TV graphics pack, before scrambling: mode 1 item 1."""
    data = (list(data) + [0] * 16)[:16]
    head = [0x09, instruction & 63]
    q = parity(head, 2)
    body = head + q + [d & 63 for d in data]
    return body + parity(body, 4)


def scramble(p):
    p = list(p)
    for a, b in ((1, 18), (2, 5), (3, 23)):
        p[a], p[b] = p[b], p[a]
    return p


def preset(colour):
    # sent a few times, as discs do, for a player that misses one
    return [pack(1, [colour, r]) for r in range(8)] + [pack(2, [colour])]


def palette(colours):
    """Colours as 12-bit RGB, 16 of them, in the two packs that load them."""
    out = []
    for instruction, part in ((30, colours[:8]), (31, colours[8:16])):
        data = []
        for rgb in part:
            data += [(rgb >> 6) & 63, rgb & 63]
        out.append(pack(instruction, data))
    return out


def tile(row, col, colour0, colour1, rows):
    return pack(6, [colour0, colour1, row, col] + list(rows))


# Letters of five by seven, a tile a dot. A tile is 6 x 12 pixels and the screen's
# safe part 48 x 16 of them.
FONT = {
    'C': '01110 10001 10000 10000 10000 10001 01110',
    'D': '11110 10001 10001 10001 10001 10001 11110',
    '+': '00000 00100 00100 11111 00100 00100 00000',
    'G': '01110 10001 10000 10111 10001 10001 01110',
    'T': '11111 00100 00100 00100 00100 00100 00100',
    '0': '01110 10001 10011 10101 11001 10001 01110',
    '1': '00100 01100 00100 00100 00100 00100 01110',
    '2': '01110 10001 00001 00110 01000 10000 11111',
    '3': '11110 00001 00001 01110 00001 00001 11110',
    '4': '00010 00110 01010 10010 11111 00010 00010',
    '5': '11111 10000 11110 00001 00001 10001 01110',
    '6': '00110 01000 10000 11110 10001 10001 01110',
    '7': '11111 00001 00010 00100 01000 01000 01000',
    '8': '01110 10001 10001 01110 10001 10001 01110',
    '9': '01110 10001 10001 01111 00001 00010 01100',
    ' ': '00000 00000 00000 00000 00000 00000 00000',
}
BG, WHITE, RED, GREEN, BLUE, YELLOW = 0, 1, 2, 3, 4, 5
COLOURS = [0x002, 0xFFF, 0xF22, 0x2C2, 0x25F, 0xFD2] + [0] * 10
SOLID = [63] * 12


def text(s, row, col, colour, on_clear=False):
    """on_clear: the screen has just been cleared, so only the dots that are on."""
    out = []
    for n, ch in enumerate(s):
        for y, line in enumerate(FONT[ch].split()):
            for x, dot in enumerate(line):
                if dot == '1' or not on_clear:
                    out.append(tile(row + y, col + n * 6 + x, BG, colour, SOLID if dot == '1' else [0] * 12))
    return out


def screen(track, second):
    """Everything but the seconds, so that a seek or a late start gets there soon."""
    return (palette(COLOURS) + (preset(BG) if second == 0 else []) + bars()
            + text('CD+G', 1, 12, WHITE, True) + text('T%d' % track, 9, 9, YELLOW, True))


def bars():
    out = []
    for col in range(48):
        colour = (RED, GREEN, BLUE, YELLOW)[col // 12]
        out.append(tile(0, col, BG, colour, SOLID))
        out.append(tile(16, col, BG, colour, SOLID))
    return out


def counter(second):
    return text('%02d' % second, 9, 27, YELLOW)


def all_packs():
    """Every pack of the disc, 4 a sector, each drawn from the second it belongs to."""
    packs = [None] * (FRAMES * PACKS_A_SECTOR)
    start = 0
    for track, seconds in enumerate(SECONDS, 1):
        for second in range(seconds):
            at = (start + second) * 75 * PACKS_A_SECTOR
            # the seconds, and the rest of the screen every five
            for n, p in enumerate((screen(track, second) if second % 5 == 0 else []) + counter(second)):
                assert packs[at + n] is None and n < 300
                packs[at + n] = p
        start += seconds
    return [p or [0] * PACK for p in packs]


def interleave(packs):
    """The packs as they lie on a disc."""
    out = [0] * ((len(packs) + 8) * PACK)
    for n, p in enumerate(packs):
        for i, s in enumerate(scramble(p)):
            out[(n + i % 8) * PACK + i] = s
    return out[:len(packs) * PACK]


def deinterleave(symbols):
    packs = []
    total = len(symbols) // PACK
    for n in range(total - 8):
        p = [symbols[(n + i % 8) * PACK + i] for i in range(PACK)]
        packs.append(scramble(p))   # its own inverse
    return packs


# ---------------------------------------------------------------- subcode Q
def bcd(v):
    return ((v // 10) << 4) | (v % 10)


def msf(frames):
    return bcd(frames // 75 // 60), bcd(frames // 75 % 60), bcd(frames % 75)


def crc(data):
    c = 0
    for b in data:
        c ^= b << 8
        for _ in range(8):
            c = ((c << 1) ^ 0x1021) & 0xFFFF if c & 0x8000 else (c << 1) & 0xFFFF
    return c ^ 0xFFFF


def subcode_q(lba):
    start, track = 0, 1
    for n, seconds in enumerate(SECONDS, 1):
        if lba < (start + seconds) * 75:
            track = n
            break
        start += seconds
    q = bytes([0x01, bcd(track), 0x01, *msf(lba - start * 75), 0, *msf(lba + 150)])
    return q + struct.pack('>H', crc(q))


def sector_symbols(lba, symbols):
    """The 96 bytes of a sector, a symbol each: P in bit 7 down to W in bit 0."""
    q = subcode_q(lba)
    at = lba * 96
    out = bytearray(96)
    for i in range(96):
        bit = (q[i >> 3] >> (7 - (i & 7))) & 1
        out[i] = (bit << 6) | symbols[at + i]
    return bytes(out)


def to_sub(sym):
    """The same as a .sub has it: twelve bytes of each channel in turn."""
    out = bytearray(96)
    for i, code in enumerate(sym):
        for j in range(8):
            if code & (0x80 >> j):
                out[j * 12 + (i >> 3)] |= 0x80 >> (i & 7)
    return bytes(out)


def from_sub(sub):
    out = bytearray(96)
    for i in range(96):
        code = 0
        for j in range(8):
            code |= ((sub[j * 12 + (i >> 3)] >> (7 - (i & 7))) & 1) << (7 - j)
        out[i] = code
    return bytes(out)


# -------------------------------------------------------------------- audio
def audio_sector(lba):
    """Quiet but for a tenth of a second's beep on the second, higher on track 2."""
    start = 0
    freq = 880
    for n, seconds in enumerate(SECONDS):
        if lba < (start + seconds) * 75:
            freq = (880, 1320)[n]
            break
        start += seconds
    out = bytearray(SECTOR)
    for s in range(SECTOR // 4):
        t = (lba * (SECTOR // 4) + s) / 44100
        into = t % 1
        v = int(6000 * math.sin(2 * math.pi * freq * into)) if into < 0.1 else 0
        struct.pack_into('<hh', out, s * 4, v, v)
    return bytes(out)


CUE = '''FILE "%s" BINARY
  TRACK 01 %s
    INDEX 01 00:00:00
  TRACK 02 %s
    INDEX 01 %02d:%02d:00
'''


def write(folder):
    os.makedirs(folder, exist_ok=True)
    symbols = interleave(all_packs())
    first = SECONDS[0]
    with open(os.path.join(folder, 'CDG Test.bin'), 'wb') as b, \
            open(os.path.join(folder, 'CDG Test.sub'), 'wb') as s, \
            open(os.path.join(folder, 'CDG Test Track.bin'), 'wb') as t:
        for lba in range(FRAMES):
            sector, sym = audio_sector(lba), sector_symbols(lba, symbols)
            b.write(sector)
            s.write(to_sub(sym))
            t.write(sector + sym)
            if lba % 225 == 0:
                print('%d of %d' % (lba, FRAMES), flush=True)
    for name, data, kind in (('CDG Test', 'CDG Test.bin', 'AUDIO'),
                             ('CDG Test Plain', 'CDG Test.bin', 'AUDIO'),
                             ('CDG Test Track', 'CDG Test Track.bin', 'CDG')):
        with open(os.path.join(folder, name + '.cue'), 'w', newline='\n') as c:
            c.write(CUE % (data, kind, kind, first // 60, first % 60))
    print('%d of %d' % (FRAMES, FRAMES))
    print('written: %s' % folder)


def check(folder):
    bad = 0
    subs = open(os.path.join(folder, 'CDG Test.sub'), 'rb').read()
    track = open(os.path.join(folder, 'CDG Test Track.bin'), 'rb').read()
    for name, get in (('.sub', lambda lba: from_sub(subs[lba * 96:lba * 96 + 96])),
                      ('CDG track', lambda lba: track[lba * 2448 + 2352:lba * 2448 + 2448])):
        symbols, q_bad = [], 0
        for lba in range(FRAMES):
            s = get(lba)
            symbols += [c & 63 for c in s]
            q = bytearray(12)
            for i in range(96):
                if s[i] & 0x40:
                    q[i >> 3] |= 0x80 >> (i & 7)
            if struct.pack('>H', crc(bytes(q[:10]))) != bytes(q[10:]):
                q_bad += 1
        packs = deinterleave(symbols)
        p_bad = sum(1 for p in packs if not syndromes_clear(p, 4))
        q2_bad = sum(1 for p in packs if not syndromes_clear(p[:4], 2))
        full = sum(1 for p in packs if p[0] == 0x09)
        print('%s: %d packs, %d with graphics, parity bad P %d Q %d, subcode Q checksum bad %d'
              % (name, len(packs), full, p_bad, q2_bad, q_bad))
        bad += p_bad + q2_bad + q_bad
        if name == '.sub':
            with open(os.path.join(folder, 'check.cdg'), 'wb') as out:
                for p in packs:
                    out.write(bytes(p))
    print('bad: %d' % bad)
    return bad


def main():
    args = sys.argv[1:]
    checking = '--check' in args
    args = [a for a in args if a != '--check']
    here = os.path.dirname(os.path.abspath(__file__))
    folder = args[0] if args else os.path.join(here, '..', 'build', 'cdg-test')
    if checking:
        sys.exit(1 if check(folder) else 0)
    write(folder)


if __name__ == '__main__':
    main()
