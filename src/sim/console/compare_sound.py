"""The simulation's sound beside MAME's, each chip apart.

    python3 -I src/sim/console/compare_sound.py SIM_DIR MAME_DIR

SIM_DIR is a tools/sim.sh run's (its sources.wav and audio.wav), MAME_DIR a tools/mame-frames.sh
run's with --wav MAME_DIR/audio.wav --sources MAME_DIR/src. Each chip's own output is taken
before either mix: the PSG's, CD audio's and ADPCM's. For each, its stretches of sound in the
two, paired in turn, with when each starts, how long it lasts and the time from the stretch
before (so the sim's lag behind MAME, the drive's seeks, doesn't count against a later one), its
level against CD audio's full scale (the mixes add PSG and CD audio as they come, MiSTer's and
MAME's alike), its pitch, and how alike the two waveforms are once lined up, over the first
half second. Then each mix: what PSG and ADPCM are worth in it against CD audio, by least
squares on the chips' outputs. All of it from the left channel.

When the sim's card was tools/testcard.py's sound.pce, its ADPCM is also checked against the
tone the card holds, decoded by the MSM5205's rules (MAME 0.289's ADPCM is no reference: it
plays the card's 16 kHz at 2 kHz, leaves ADPCM out of its mix and never ends a play). Each play
is found by its rate, lined up to the sample, and compared, decoded sample for sample; and the
PSG's pitch through one period of its LFO is set beside MAME's. Only the standard library, so it is slow: a minute or two.
"""
import json
import math
import os
import sys
import wave
from array import array
from operator import mul

RATE = 48000
BLOCK = 480                 # 10 ms, the envelope's step


def wav(path):
    w = wave.open(path)
    n, ch = w.getnframes(), w.getnchannels()
    a = array('h')
    a.frombytes(w.readframes(n))
    if sys.byteorder != 'little':
        a.byteswap()
    return [array('d', (v / 32768 for v in a[c::ch])) for c in range(ch)]


def f32(path, ch):
    a = array('f')
    with open(path, 'rb') as f:
        a.frombytes(f.read())
    if sys.byteorder != 'little':
        a.byteswap()
    return [array('d', a[c::ch]) for c in range(ch)]


def to48k(x, rate):
    """Linear steps from rate to 48 kHz."""
    n = int(len(x) * RATE / rate)
    step = rate / RATE
    out = array('d', bytes(8 * n))
    last = len(x) - 1
    for i in range(n):
        p = i * step
        k = int(p)
        if k >= last:
            out[i] = x[last]
        else:
            f = p - k
            out[i] = x[k] + (x[k + 1] - x[k]) * f
    return out


def halve(x):
    return array('d', ((x[i] + x[i + 1]) / 2 for i in range(0, len(x) - 1, 2)))


def envelope(x):
    """Each 10 ms block's RMS about its own mean, so a held level (an idle ADPCM) is silence."""
    env = []
    for k in range(0, len(x) - BLOCK + 1, BLOCK):
        b = x[k:k + BLOCK]
        m = sum(b) / BLOCK
        env.append(math.sqrt(max(sum(map(mul, b, b)) / BLOCK - m * m, 0)))
    return env


def stretches(env):
    """Where it sounds: 30 dB under its loudest block and above -80 dB, gaps under 60 ms closed."""
    top = max(env) if env else 0
    if top <= 0:
        return []
    floor = max(top * 10 ** (-30 / 20), 10 ** (-80 / 20))
    on = [e > floor for e in env]
    out, start, quiet = [], None, 0
    for i, v in enumerate(on + [False] * 7):
        if v:
            if start is None:
                start = i
            quiet = 0
        elif start is not None:
            quiet += 1
            if quiet > 6:
                end = i - quiet + 1
                if end - start >= 3:
                    out.append((start, end))
                start, quiet = None, 0
    return out


def db(v):
    return 20 * math.log10(v) if v > 0 else -999


def rms(x):
    if not x:
        return 0
    m = sum(x) / len(x)
    return math.sqrt(max(sum(map(mul, x, x)) / len(x) - m * m, 0))


def pitch(x):
    """By autocorrelation, 50 Hz to 2.4 kHz; None where nothing repeats."""
    x = x[:2048]
    if len(x) < 2048:
        return None
    m = sum(x) / len(x)
    x = array('d', (v - m for v in x))
    e = sum(map(mul, x, x))
    if e <= 0:
        return None
    n = 1024
    head = array('d', x[:n])
    eh = sum(map(mul, head, head))
    cs = []
    for k in range(20, 960):
        w = x[k:k + n]
        cs.append(sum(map(mul, head, w)) / max(eh * sum(map(mul, w, w)), 1e-30) ** 0.5)
    top = max(cs)
    if top < 0.6:
        return None
    # the first peak near the best, not a multiple of the period
    for i in range(1, len(cs) - 1):
        if cs[i] >= 0.8 * top and cs[i] >= cs[i - 1] and cs[i] >= cs[i + 1]:
            a, b, c = cs[i - 1], cs[i], cs[i + 1]
            d = a - 2 * b + c
            return RATE / (i + 20 + (0.5 * (a - c) / d if d else 0))
    return None


def likeness(a, b):
    """The two lined up within 10 ms of each other over half a second: the best correlation and its lag."""
    n = min(RATE // 2, len(a) - 480, len(b) - 960)
    if n < 2400:
        return None, None
    a = a[480:480 + n]
    ma = sum(a) / n
    a = array('d', (v - ma for v in a))
    ea = sum(map(mul, a, a))
    best, at = -2, 0
    for lag in range(0, 961):
        w = b[lag:lag + n]
        mb = sum(w) / n
        eb = sum(map(mul, w, w)) - mb * mb * n
        if ea <= 0 or eb <= 0:
            continue
        c = (sum(map(mul, a, w)) - mb * sum(a)) / math.sqrt(ea * eb)
        if c > best:
            best, at = c, lag - 480
    return (best, at) if best > -2 else (None, None)


def mix_shares(mix, chips, lags=range(-12, 13)):
    """mix = sum of g * chip, by least squares over every third sample, at the best common lag."""
    best = None
    names = list(chips)
    n = min(len(mix), *(len(c) for c in chips.values())) - 20
    for lag in lags:
        idx = range(10, n, 3)
        xs = [[chips[k][i + lag] for i in idx] for k in names]
        y = [mix[i] for i in idx]
        m = len(names)
        A = [[sum(map(mul, xs[r], xs[c])) for c in range(m)] for r in range(m)]
        bv = [sum(map(mul, xs[r], y)) for r in range(m)]
        keep = [r for r in range(m) if A[r][r] > 1e-9]
        g = solve([[A[r][c] for c in keep] for r in keep], [bv[r] for r in keep])
        if g is None:
            continue
        gains = dict.fromkeys(names, 0.0)
        for r, v in zip(keep, g):
            gains[names[r]] = v
        res = sum(map(mul, y, y)) - 2 * sum(gains[names[r]] * bv[r] for r in range(m)) + \
            sum(gains[names[r]] * gains[names[c]] * A[r][c] for r in range(m) for c in range(m))
        if best is None or res < best[0]:
            best = (res, lag, gains, sum(map(mul, y, y)))
    return best


def solve(A, b):
    n = len(A)
    M = [row[:] + [b[i]] for i, row in enumerate(A)]
    for c in range(n):
        p = max(range(c, n), key=lambda r: abs(M[r][c]))
        if abs(M[p][c]) < 1e-15:
            return None
        M[c], M[p] = M[p], M[c]
        for r in range(n):
            if r != c:
                f = M[r][c] / M[c][c]
                M[r] = [x - f * y for x, y in zip(M[r], M[c])]
    return [M[i][n] / M[i][i] for i in range(n)]


def tone_check(adpcm, stretches_):
    """The sim's ADPCM against sound.pce's tone: its two plays, at 16 kHz and 6.4 kHz."""
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', '..', 'tools'))
    sys.dont_write_bytecode = True     # (no __pycache__ left in tools/)
    import testcard
    want = testcard.msm5205_decode(testcard.ADPCM_TONE)
    print('\nADPCM against sound.pce\'s tone, decoded by the MSM5205\'s rules:')
    for (a, b), rate in zip(stretches_, (16000, 32000 / 5)):
        seg = adpcm[max(a - 2, 0) * BLOCK:(b + 2) * BLOCK]
        p = pitch(seg[len(seg) // 2 - 1024:])
        if not p:
            print(f'  the {rate / 1000:g} kHz play: no tone in it')
            continue
        r = 16000 * p / 1000           # the tone was made 1 kHz at 16 kHz, so its pitch gives the rate
        # the first 0.1 s of it, lined up by its start to a 48th of a millisecond
        n = 4800
        best = None
        for t0 in range(0, 4 * BLOCK):
            idx = [int((i - t0) * r / RATE) for i in range(t0, t0 + n)]
            if idx[-1] >= len(want):
                break
            w = [want[k] for k in idx]
            x = seg[t0:t0 + n]
            mw, mx = sum(w) / n, sum(x) / n
            sw = sum(map(mul, w, w)) - n * mw * mw
            sx = sum(map(mul, x, x)) - n * mx * mx
            if sw <= 0 or sx <= 0:
                continue
            c = (sum(map(mul, w, x)) - n * mw * mx) / math.sqrt(sw * sx)
            if best is None or c > best[0]:
                best = (c, t0, math.sqrt(sx / sw))
        if best is None:
            print(f'  the {rate / 1000:g} kHz play: could not be lined up')
            continue
        c, t0, g = best
        print(f'  the {rate / 1000:g} kHz play: {(b - a) / 100:.2f} s, {len(want) / r:.2f} s if all 8192 nibbles, '
              f'at {r:.0f} Hz ({(r / rate - 1) * 100:+.2f}%), alike {c:.4f}, '
              f'a 12-bit step worth {g * 32768:.2f} of the 16-bit output')


def pitch_track(x):
    """Each cycle's pitch from rising zero crossings, with what is slower than 200 Hz taken out."""
    w = RATE // 200
    run = sum(x[:w])
    hp = array('d', bytes(8 * len(x)))
    for i in range(len(x)):
        if i + w // 2 < len(x) and i >= w // 2:
            hp[i] = x[i] - run / w
            if i + w // 2 + 1 < len(x):
                run += x[i + w // 2 + 1] - x[i - w // 2]
    out, last = [], None
    for i in range(len(hp) - 1):
        if hp[i] < 0 <= hp[i + 1]:
            z = i + hp[i] / (hp[i] - hp[i + 1])
            if last is not None:
                out.append((z / RATE, RATE / (z - last)))
            last = z
    return out


def lfo_check(sim_psg, mame_psg):
    """sound.pce's LFO at depth 1: the first channel's pitch over one of its periods, step by step."""
    print('\nThe PSG\'s LFO at depth 1 (sound.pce: the second channel a saw, 0 to 31), the pitch over one period:')
    rows = {}
    for name, x in (('sim', sim_psg), ('MAME', mame_psg)):
        tr = pitch_track(x)
        off = [abs(f - 440.4) > 3 for t, f in tr]
        start = next((tr[i][0] for i in range(len(tr) - 10) if all(off[i:i + 10])), None)
        if start is None:
            print(f'  {name}: no LFO found')
            return
        period = 32 * 16 * 2 * 1024 / 7159090          # 32 steps, each 16 x 2 x 0x400 clocks of 7.16 MHz
        t0 = start + 0.02
        bins = [[] for _ in range(32)]
        for t, f in tr:
            if t0 <= t < t0 + 3 * period:
                bins[int((t - t0) / period * 32) % 32].append(f)
        rows[name] = [sorted(b)[len(b) // 2] if b else 0 for b in bins]     # the median: a step's jump can make a stray crossing
    a, b = rows['sim'], rows['MAME']
    shift = min(range(32), key=lambda k: sum(abs(a[i] - b[(i + k) % 32]) for i in range(32)))
    b = [b[(i + shift) % 32] for i in range(32)]
    print('  sim: ' + ' '.join(f'{v:.0f}' for v in a))
    print('  MAME:' + ' '.join(f'{v:.0f}' for v in b))
    print(f'  {max(abs(x - y) for x, y in zip(a, b)):.1f} Hz apart at most, lined up')


def main():
    sim_dir, mame_dir = sys.argv[1], sys.argv[2]
    s = wav(f'{sim_dir}/sources.wav')
    # the left channel of each: CD audio's tones differ by side, and a mono sum's pitch is neither
    sim = {'PSG': s[0], 'CD audio': s[2], 'ADPCM': s[4]}
    src = f'{mame_dir}/src'
    mame = {'PSG': to48k(f32(f'{src}/psg.f32', 2)[0], 3579545 / 75),
            'CD audio': to48k(f32(f'{src}/cdda.f32', 2)[0], 44100),
            'ADPCM': halve(f32(f'{src}/adpcm.f32', 1)[0])}
    print(f'sim {len(sim["PSG"]) / RATE:.2f} s, MAME {len(mame["PSG"]) / RATE:.2f} s')
    for chip in sim:
        es, em = envelope(sim[chip]), envelope(mame[chip])
        ss, ms = stretches(es), stretches(em)
        print(f'\n{chip}: {len(ss)} stretches in the sim, {len(ms)} in MAME')
        if not ss and not ms:
            continue
        print('   sim: start   long  after last   level   pitch  |  MAME: start   long  after last   level   pitch  |  alike, lag')
        for i in range(max(len(ss), len(ms))):
            cols = []
            parts = []
            for st, x, prev in ((ss, sim[chip], ss), (ms, mame[chip], ms)):
                if i < len(st):
                    a, b = st[i]
                    seg = x[a * BLOCK:b * BLOCK]
                    gap = f'{(a - prev[i - 1][0]) / 100:7.2f} s' if i else '        -'
                    p = pitch(seg[len(seg) // 2 - 1024:]) if len(seg) > 4096 else pitch(seg)
                    cols.append(f'{a / 100:7.2f} s {(b - a) / 100:5.2f} s {gap} {db(rms(seg)):6.1f} dB {(f"{p:6.1f} Hz" if p else "       -")}')
                    parts.append(x[a * BLOCK:])
                else:
                    cols.append(' ' * 53)
            like = ''
            if len(parts) == 2:
                c, lag = likeness(parts[0], parts[1])
                if c is not None:
                    like = f'{c:5.3f}, {lag / 48:+.2f} ms'
            print(f'  {cols[0]}  |  {cols[1]}  |  {like}')
    try:
        card = json.load(open(f'{sim_dir}/run.json')).get('card', '')
    except (OSError, ValueError):
        card = ''
    if os.path.basename(card) == 'sound.pce':
        tone_check(sim['ADPCM'], stretches(envelope(sim['ADPCM'])))
        lfo_check(sim['PSG'], mame['PSG'])
    print('\nThe mixes, each chip against CD audio (MiSTer\'s adds the three as they come, then 5/16):')
    w_sim = wav(f'{sim_dir}/audio.wav')[0]
    w_mame = wav(f'{mame_dir}/audio.wav')[0]
    for name, mix, chips in (('sim', w_sim, sim), ('MAME', w_mame, mame)):
        best = mix_shares(mix, chips)
        if best is None:
            print(f'  {name}: no fit')
            continue
        res, lag, g, total = best
        cd = g['CD audio']
        each = ', '.join(f'{k} x {v:.4f}' + (f' ({v / cd:.3f} of CD audio\'s)' if cd > 1e-3 and k != 'CD audio' else '')
                         for k, v in g.items())
        print(f'  {name}: {each}; lag {lag}, {db(math.sqrt(max(res, 0) / max(total, 1e-30))):.1f} dB left over')


main()
