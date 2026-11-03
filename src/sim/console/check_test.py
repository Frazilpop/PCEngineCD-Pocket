"""What the test card's run says: tools/sim.sh runs this after its default run.

    python3 -I check_test.py <out dir> <palette.hex>

The card turns the backdrop green when every check has passed and leaves it red if not
(tools/testcard.py), which the first pixel in frames.txt shows. The picture stays alive:
a sprite crosses it and a counter counts. The sound is the PSG's 440 Hz, and after the
PLAY the disc's 880 Hz on the left and 1320 Hz on the right, each measured by its power
in the WAV against a tone that isn't there.
"""
import json
import math
import struct
import sys
import wave

out, palette = sys.argv[1], sys.argv[2]
colours = [int(l, 16) for l in open(palette)]
GREEN, RED = colours[0x1C0], colours[0x038]     # the card's colours through main.sv's palette: {g, r, b}

rows = [l.split() for l in open(f'{out}/frames.txt')]
corner = [int(r[3], 16) for r in rows]
bad = []
if not rows:
    sys.exit('no frames at all')
last = corner[-1]
state = 'green: every check passed' if last == GREEN else 'red: a check failed, see the last frame' if last == RED else f'{last:06x}: neither'
print(f'The card says {state}')
if last != GREEN:
    bad.append('checks')
green_from = next((i + 1 for i, c in enumerate(corner) if c == GREEN), None)
if green_from:
    print(f'All good from frame {green_from}')
crcs = {r[2] for r in rows[-60:]}
print(f'The last 60 frames hold {len(crcs)} different pictures')
if len(crcs) < 20:
    bad.append('picture')

w = wave.open(f'{out}/audio.wav')
hz = w.getframerate()
pcm = struct.unpack('<%dh' % (w.getnframes() * 2), w.readframes(w.getnframes()))
left, right = pcm[0::2], pcm[1::2]


def power(samples, freq):
    """Goertzel: how much of freq there is in these samples."""
    k = 2 * math.cos(2 * math.pi * freq / hz)
    a = b = 0.0
    for s in samples:
        a, b = s + k * a - b, a
    return (a * a + b * b - k * a * b) / max(len(samples), 1) ** 2


tail = hz // 2      # the last half second, well after the PLAY
l, r = left[-tail:], right[-tail:]
quiet_l, quiet_r = power(l, 700), power(r, 700)
for name, samples, freq, floor in (('PSG 440 Hz, left', l, 440, quiet_l), ('CD 880 Hz, left', l, 880, quiet_l), ('CD 1320 Hz, right', r, 1320, quiet_r)):
    p = power(samples, freq)
    ok = p > 100 * max(floor, 1)
    print(f'{name}: {"there" if ok else "NOT there"} ({p:.0f} against {floor:.0f})')
    if not ok:
        bad.append(name)

run = json.load(open(f'{out}/run.json'))
print(f'{run["frames"]} frames, {run["seconds"]:.0f} s, {run["mhz"]} MHz of 42.95')
if bad:
    sys.exit('FAILED: ' + ', '.join(bad))
print('Passed')
