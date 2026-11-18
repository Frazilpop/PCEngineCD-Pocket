"""HuCards of the repo's own for the simulation and MAME: one for each way the core maps a card.

    python3 -I tools/hucard-test.py build/sim/hucards

Each 8K bank of a card's file carries its own number at 0x1000 in the bank (low, high, and the low
byte EOR 0xA5). The program, in the first bank (on MPR7 at reset, as every HuCard), maps every bank
of the card's 1 MB (0x00 to 0x7F) at 0x4000 in turn and reads the number there, against the bank
the card's size puts there on a real console (pce_top.vhd's table, and MAME's):

  128K and 256K and 512K   repeated through the 1 MB
  384K                     ABABCCCC: its first 256K twice, then its last 128K four times
  768K                     ABCDEFEF: its first 512K, then its last 256K twice
  1M                       as it is
  sf2                      2.5 MB: the first 512K always at 0x00 to 0x3F; a write to 0x1FF0 to
                           0x1FF3 chooses which of four 512K follows at 0x40, each checked
  header                   256K after a copier's 512-byte header, which the core skips
  populous                 512K with POPULOUS at 0x1F26: 0x40 to 0x43 are the card's 32K of RAM,
                           which takes a pattern and keeps its banks apart

The backdrop is green once every bank read right, red otherwise (the failing bank's number in
the zero page's 0x10), and from then on the check goes on every frame: SF2's card reads 0x40 with
its third 512K chosen, Populous's its RAM's pattern, the others bank 0x7F, so a state loaded with
any of these lost turns it red. Colour 0's blue counts frames, a picture that moves.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from testcard import Asm  # noqa: E402

BANK = 0x2000
MARK = 0x1000
FAIL, FRAME, PTR, PTR_H, LB, BAD = range(0x10, 0x16)


def file_bank(kind, size, L, rb=0):
    """The bank of the card's file that logical bank L reads (pce_top.vhd's ROM_A)."""
    a = L << 13                     # CPU_A(19..13), A20 = 0
    b = lambda n: (a >> n) & 1
    if kind == 'sf2':
        rb0, rb1 = rb & 1, rb >> 1
        hi = ((b(19) & rb0 & rb1) << 21) | ((b(19) & (rb0 ^ rb1)) << 20) | ((b(19) & (1 - rb0)) << 19)
        return (hi | (a & 0x7FFFF)) >> 13
    if size == 0x20000:
        return (a & 0x1FFFF) >> 13
    if size == 0x40000:
        return (a & 0x3FFFF) >> 13
    if size == 0x60000:
        return ((b(19) << 18) | ((b(17) & (1 - b(19))) << 17) | (a & 0x1FFFF)) >> 13
    if size == 0x80000:
        return (a & 0x7FFFF) >> 13
    if size == 0xC0000:
        return ((b(19) << 19) | ((b(18) & (1 - b(19))) << 18) | (a & 0x3FFFF)) >> 13
    return (a & 0xFFFFF) >> 13


def build(kind, size):
    a = Asm(0xE000)
    a.label('reset')
    a.op(0x78); a.op(0xD4); a.op(0xD8)          # SEI, CSH, CLD
    a.ldx(0xFF); a.op(0x9A)
    a.lda(0xFF); a.tam(0x01)                    # MPR0: I/O
    a.lda(0xF8); a.tam(0x02)                    # MPR1: RAM
    a.ldx(0)
    a.label('clearzp')
    a.op(0x74); a.b.append(0)                   # STZ zp,X
    a.inx(); a.bne('clearzp')
    a.lda(0); a.sta_a(0x0C01)                   # the timer off
    a.lda(0x07); a.sta_a(0x1402)                # every interrupt masked
    a.lda(0); a.sta_a(0x0400)                   # 5.37 MHz dots
    a.lda(0); a.sta_a(0x0402); a.sta_a(0x0403)
    a.lda(0x38); a.sta_a(0x0404); a.lda(0); a.sta_a(0x0405)        # colour 0: red until the checks pass
    for reg, val in ((0x05, 0x0000), (0x06, 0), (0x07, 0), (0x08, 0), (0x09, 0x0000), (0x0A, 0x0202), (0x0B, 0x031F),
                     (0x0C, 0x0F02), (0x0D, 0x00EF), (0x0E, 0x0004), (0x0F, 0x0010), (0x13, 0x7F00)):
        a.st0(reg); a.st1(val & 0xFF); a.st2(val >> 8)
    # tile 0x100 (VRAM 0x1000) all colour 0, and the map all of it
    a.st0(0); a.st1(0x00); a.st2(0x10); a.st0(2)
    a.ldx(16)
    a.label('tile')
    a.st1(0); a.st2(0)
    a.dex(); a.bne('tile')
    a.st0(0); a.st1(0); a.st2(0); a.st0(2)
    a.ldy(4)
    a.label('bat1')
    a.ldx(0)
    a.label('bat2')
    a.st1(0x00); a.st2(0x01)
    a.dex(); a.bne('bat2')
    a.dey(); a.bne('bat1')
    a.st0(5); a.st1(0x88); a.st2(0x00)          # the background on, and the vertical blank's flag (its interrupt masked in the CPU)

    def table(name):
        a.imm_lo(0xA9, name); a.sta_z(PTR)
        a.imm_hi(0xA9, name); a.sta_z(PTR_H)

    tables = []
    if kind == 'sf2':
        table('t_low'); a.lda(0x00); a.ldx(0x40); a.jsr('check')
        tables.append(('t_low', [file_bank('sf2', size, L) for L in range(0x40)]))
        for rb in range(4):
            a.sta_a(0xFFF0 + rb)                # the mapper's write: anything to 0x1FF0 + n
            table(f't_rb{rb}'); a.lda(0x40); a.ldx(0x40); a.jsr('check')
            tables.append((f't_rb{rb}', [file_bank('sf2', size, L, rb) for L in range(0x40, 0x80)]))
        a.sta_a(0xFFF2)                         # left on the third 512K for the frames' check
    elif kind == 'populous':
        table('t_low'); a.lda(0x00); a.ldx(0x40); a.jsr('check')
        tables.append(('t_low', [file_bank('rom', size, L) for L in range(0x40)]))
        # the RAM, 0x40 to 0x43 (MiSTer's goes on repeating to 0x7F, MAME's doesn't, and the
        # game uses these): the ends of 0x40, and 0x41 and 0x43 apart from it
        writes = ((0x40, 0x4000, 0x5A), (0x40, 0x5FFF, 0xC3), (0x41, 0x4000, 0x96), (0x43, 0x5FFF, 0x3C))
        for bank, addr, val in writes:
            a.lda(bank); a.tam(0x04); a.lda(val); a.sta_a(addr)
        for bank, addr, val in writes:
            a.lda(bank); a.tam(0x04); a.lda_a(addr); a.cmp(val)
            a.beq(f'p_{bank}_{addr}')
            a.lda(bank); a.sta_z(FAIL); a.lda(0xFF); a.sta_z(BAD)
            a.label(f'p_{bank}_{addr}')
    else:
        table('t_all'); a.lda(0x00); a.ldx(0x80); a.jsr('check')
        tables.append(('t_all', [file_bank('rom', size, L) for L in range(0x80)]))

    # every frame: the backdrop green (or red), its blue the frame count, and the one bank again
    a.label('frame')
    a.lda_a(0x0000); a.and_(0x20); a.beq('frame')   # the VDC's vertical blank
    a.inc_z(FRAME)
    if kind == 'sf2':
        table('t_rb2'); a.lda(0x40); a.ldx(1); a.jsr('check')
    elif kind == 'populous':
        a.lda(0x43); a.tam(0x04); a.lda_a(0x5FFF); a.cmp(0x3C); a.beq('pf_ok')
        a.lda(0x43); a.sta_z(FAIL); a.lda(0xFF); a.sta_z(BAD)
        a.label('pf_ok')
    else:
        table('t_last'); a.lda(0x7F); a.ldx(1); a.jsr('check')
        tables.append(('t_last', [file_bank('rom', size, 0x7F)]))
    a.lda(0); a.sta_a(0x0402); a.sta_a(0x0403)
    a.lda_z(FRAME); a.lsr_a(); a.lsr_a(); a.lsr_a(); a.and_(0x07)
    a.ldx_z(BAD); a.bne('red')
    a.ora(0xC0); a.sta_a(0x0404); a.lda(0x01); a.sta_a(0x0405)    # G 7
    a.bra('wait_end')
    a.label('red')
    a.ora(0x38); a.sta_a(0x0404); a.lda(0x00); a.sta_a(0x0405)    # R 7
    a.label('wait_end')
    a.jmp('frame')                              # reading the status cleared the flag

    # check: A the first bank, X how many, PTR the table: bank L at 0x4000, its number at 0x5000
    a.label('check')
    a.sta_z(LB)
    a.label('chk_next')
    a.lda_z(LB); a.tam(0x04)
    a.ldy(0)
    for off in (0x5000, 0x5001, 0x5002):
        a.lda_a(off); a.op(0xD1); a.b.append(PTR)   # CMP (PTR),Y
        a.bne('chk_bad')
        a.iny()
    a.lda_z(PTR); a.clc(); a.adc(3); a.sta_z(PTR)
    a.lda_z(PTR_H); a.adc(0); a.sta_z(PTR_H)
    a.inc_z(LB)
    a.dex(); a.bne('chk_next')
    a.rts()
    a.label('chk_bad')
    a.lda_z(LB); a.sta_z(FAIL)
    a.lda(0xFF); a.sta_z(BAD)
    a.rts()

    for name, banks in tables:
        a.label(name)
        for fb in banks:
            a.db(fb & 0xFF, fb >> 8, (fb & 0xFF) ^ 0xA5)
    a.link()
    code = bytes(a.b)
    assert len(code) < MARK, len(code)     # under bank 0's own number
    return code


def card(kind, size):
    img = bytearray(size)
    for fb in range(size // BANK):
        o = fb * BANK + MARK
        img[o:o + 3] = bytes((fb & 0xFF, fb >> 8, (fb & 0xFF) ^ 0xA5))
    code = build(kind, size)
    img[0:len(code)] = code
    if kind == 'populous':
        img[0x1F26:0x1F2E] = b'POPULOUS'
    # the vectors: reset, and the rest to it
    reset = 0xE000
    for v in range(0x1FF6, 0x2000, 2):
        img[v:v + 2] = reset.to_bytes(2, 'little')
    return bytes(img)


CARDS = [
    ('128k', 'rom', 0x20000), ('256k', 'rom', 0x40000), ('384k', 'rom', 0x60000), ('512k', 'rom', 0x80000),
    ('768k', 'rom', 0xC0000), ('1m', 'rom', 0x100000), ('sf2', 'sf2', 0x280000), ('populous', 'populous', 0x80000),
]


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else 'build/sim/hucards'
    os.makedirs(out, exist_ok=True)
    for name, kind, size in CARDS:
        with open(os.path.join(out, f'hu_{name}.pce'), 'wb') as f:
            f.write(card(kind, size))
    with open(os.path.join(out, 'hu_header.pce'), 'wb') as f:
        f.write(bytes(512) + card('rom', 0x40000))
    print(f'{len(CARDS) + 1} HuCards in {out}')


if __name__ == '__main__':
    main()
