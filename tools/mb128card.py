"""A card for the simulation that talks to the Memory Base 128 as a game's driver does.

    python3 -I tools/mb128card.py build/sim/mb128/card.pce

HuC6280 code by hand, the repo's own to commit (no system card or game), on the pad port through the
real chips. Each access is the protocol in full: 0xA8 and two more clocks, the answer
looked at, a read or write bit, 10 bits of 128-byte sector, 20 bits of length, the data,
the trailing clocks. Bits go at about 30 CPU cycles each at 7.16 MHz, and one sector at
10 cycles a bit, faster than any driver would.

It looks first at sector 3, then says by the backdrop's colour:

  green    the MB128 answered and read clear, and sectors 3, 5 and 1023 took what was
           written and gave it back
  blue     sectors 3 and 1023 already held the pattern: it came back from the save
  purple   no MB128 answered (as with the Core Setting off)
  white    sector 3 was neither clear nor the pattern
  red      what was written didn't come back

tools/mb128-test.sh runs it with each kind of save and looks at the colours and the files.
"""
import struct
import sys

COLOURS = {'working': 0x040, 'green': 0x1C0, 'blue': 0x007, 'purple': 0x03F, 'white': 0x1FF, 'red': 0x038}
KEY3, KEY1023, KEY5 = 0x5A, 0xC3, 0xFF
VAL, KEY, MASK, BAD, SEC, SEC_H, CNT = 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16
PORT = 0x1000


class Asm:
    def __init__(self, org):
        self.org, self.b, self.labels, self.fix = org, bytearray(), {}, []

    def label(self, name):
        self.labels[name] = self.org + len(self.b)

    def op(self, *bytes_):
        self.b += bytes(bytes_)

    def abs(self, op, target):
        self.b.append(op)
        if isinstance(target, str):
            self.fix.append((len(self.b), target, 'word'))
            self.b += b'\0\0'
        else:
            self.b += struct.pack('<H', target)

    def rel(self, op, target):
        self.b.append(op)
        self.fix.append((len(self.b), target, 'rel'))
        self.b.append(0)

    def link(self):
        for at, name, kind in self.fix:
            v = self.labels[name]
            if kind == 'word':
                self.b[at:at + 2] = struct.pack('<H', v)
            else:
                d = v - (self.org + at + 1)
                assert -128 <= d <= 127, f'branch to {name}: {d}'
                self.b[at] = d & 0xFF

    def lda(self, v): self.op(0xA9, v)
    def ldx(self, v): self.op(0xA2, v)
    def ldy(self, v): self.op(0xA0, v)
    def lda_z(self, z): self.op(0xA5, z)
    def sta_z(self, z): self.op(0x85, z)
    def sta_a(self, a): self.abs(0x8D, a)
    def lda_a(self, a): self.abs(0xAD, a)
    def jsr(self, t): self.abs(0x20, t)
    def jmp(self, t): self.abs(0x4C, t)
    def rts(self): self.op(0x60)
    def beq(self, t): self.rel(0xF0, t)
    def bne(self, t): self.rel(0xD0, t)
    def bra(self, t): self.rel(0x80, t)
    def dex(self): self.op(0xCA)
    def iny(self): self.op(0xC8)
    def cpy(self, v): self.op(0xC0, v)


def colour(a, name):
    """Both palettes' first colour, whichever the VCE is showing, then nothing more."""
    v = COLOURS[name]
    for hi in (0, 1):
        a.lda(0); a.sta_a(0x0402); a.lda(hi); a.sta_a(0x0403)
        a.lda(v & 0xFF); a.sta_a(0x0404); a.lda(v >> 8); a.sta_a(0x0405)


def bad_goes_to(a, target):
    """To target if BAD isn't 0, however far."""
    label = f'near{len(a.b)}'
    a.lda_z(BAD); a.beq(label); a.jmp(target); a.label(label)


def stop(a, name):
    colour(a, name)
    label = f'stop{len(a.b)}'
    a.label(label)
    a.bra(label)


def main():
    a = Asm(0xE000)
    a.label('reset')
    a.op(0x78, 0xD4, 0xD8)              # SEI, CSH (7.16 MHz), CLD
    a.ldx(0xFF); a.op(0x9A)             # TXS
    a.lda(0xFF); a.op(0x53, 0x01)       # MPR0: the I/O page
    a.lda(0xF8); a.op(0x53, 0x02)       # MPR1: RAM, the zero page and stack
    a.lda(0); a.sta_a(0x0C01)
    a.lda(0x07); a.sta_a(0x1402)        # no interrupts
    a.lda(0); a.sta_a(0x0400)           # 5.37 MHz dots
    colour(a, 'working')
    for reg, val in ((0x05, 0x0000), (0x06, 0), (0x07, 0), (0x08, 0), (0x09, 0x0000), (0x0A, 0x0202), (0x0B, 0x031F),
                     (0x0C, 0x0F02), (0x0D, 0x00EF), (0x0E, 0x0004), (0x0F, 0x0010)):
        a.op(0x03, reg, 0x13, val & 0xFF, 0x23, val >> 8)   # ST0, ST1, ST2
    a.op(0x03, 5, 0x13, 0x00, 0x23, 0)  # nothing on the screen but the colour

    # What sector 3 holds: the pattern, nothing, or neither
    a.lda(KEY3); a.sta_z(KEY); a.lda(0xFF); a.sta_z(MASK)
    a.lda(3); a.sta_z(SEC); a.lda(0); a.sta_z(SEC_H)
    a.jsr('read')
    bad_goes_to(a, 'notkept')
    a.lda(KEY1023); a.sta_z(KEY)
    a.lda(0xFF); a.sta_z(SEC); a.lda(3); a.sta_z(SEC_H)
    a.jsr('read')
    bad_goes_to(a, 'rwfail')
    stop(a, 'blue')

    a.label('notkept')
    a.lda(0); a.sta_z(KEY); a.sta_z(MASK)
    a.lda(3); a.sta_z(SEC); a.lda(0); a.sta_z(SEC_H)
    a.jsr('read')
    bad_goes_to(a, 'notclear')
    a.jmp('clear')
    a.label('notclear')
    stop(a, 'white')

    a.label('noanswer')
    stop(a, 'purple')

    a.label('rwfail')
    stop(a, 'red')

    a.label('clear')
    # sectors 3, 1023 and 5 take a pattern each
    a.lda(0xFF); a.sta_z(MASK)
    for key, sector in ((KEY3, 3), (KEY1023, 1023), (KEY5, 5)):
        a.lda(key); a.sta_z(KEY); a.lda(sector & 0xFF); a.sta_z(SEC); a.lda(sector >> 8); a.sta_z(SEC_H)
        a.jsr('write')
    # sector 5 goes back to nothing, at 10 cycles a bit
    a.lda(5); a.sta_z(SEC); a.lda(0); a.sta_z(SEC_H)
    a.lda(0); a.jsr('begin')
    a.ldx(2); a.ldy(0)                  # 1024 bits of 0: STY the clock low, STX high, 8 a time
    a.lda(128); a.sta_z(CNT)
    a.label('tight')
    for _ in range(8):
        a.abs(0x8C, PORT); a.abs(0x8E, PORT)
    a.op(0xC6, CNT)                     # DEC zp
    a.bne('tight')
    a.lda(5); a.sta_z(CNT)
    a.label('tighttrail')
    a.jsr('clock0')
    a.op(0xC6, CNT)
    a.bne('tighttrail')
    # and all of them read back
    for key, mask, sector in ((KEY3, 0xFF, 3), (KEY1023, 0xFF, 1023), (0, 0, 5)):
        a.lda(key); a.sta_z(KEY); a.lda(mask); a.sta_z(MASK)
        a.lda(sector & 0xFF); a.sta_z(SEC); a.lda(sector >> 8); a.sta_z(SEC_H)
        a.jsr('read')
        bad_goes_to(a, 'rwfail')
    stop(a, 'green')

    # ---- one clock of 0, for the trailing ones
    a.label('clock0')
    a.lda(0); a.sta_a(PORT); a.lda(2); a.sta_a(PORT)
    a.rts()

    # ---- VAL's low X bits, first bit first
    a.label('send')
    a.lda_z(VAL); a.op(0x29, 1)         # AND #1
    a.sta_a(PORT); a.op(0x09, 2)        # ORA #2: the clock's rise takes the bit
    a.sta_a(PORT)
    a.op(0x46, VAL)                     # LSR zp
    a.dex(); a.bne('send')
    a.rts()

    # ---- the ident and the request; A: 1 read, 0 write. Pad lines left with the clock high.
    a.label('begin')
    a.op(0x48)                          # PHA
    a.lda(0xA8); a.sta_z(VAL); a.ldx(8); a.jsr('send')
    a.lda(1); a.sta_z(VAL); a.ldx(1); a.jsr('send')
    a.lda_a(PORT); a.op(0x29, 0x0F); a.bne('beginbad')  # the first answer: nothing
    a.lda(1); a.sta_z(VAL); a.ldx(1); a.jsr('send')
    a.lda_a(PORT); a.op(0x29, 0x0F); a.op(0xC9, 4); a.bne('beginbad')  # the second: bit 2, what was sent
    a.op(0x68); a.sta_z(VAL); a.ldx(1); a.jsr('send')   # PLA: read or write
    a.lda_z(SEC); a.sta_z(VAL); a.ldx(8); a.jsr('send')
    a.lda_z(SEC_H); a.sta_z(VAL); a.ldx(2); a.jsr('send')
    a.lda(0); a.sta_z(VAL); a.ldx(8); a.jsr('send')     # 1024 bits, 20 of them
    a.lda(0x04); a.sta_z(VAL); a.ldx(8); a.jsr('send')
    a.lda(0); a.sta_z(VAL); a.ldx(4); a.jsr('send')
    a.rts()
    a.label('beginbad')
    a.jmp('noanswer')

    # ---- 128 bytes in, BAD counting those that aren't (y & MASK) ^ KEY
    a.label('read')
    a.lda(0); a.sta_z(BAD)
    a.lda(1); a.jsr('begin')
    a.ldy(0)
    a.label('readbyte')
    a.ldx(8)
    a.label('readbit')
    a.lda(0); a.sta_a(PORT); a.lda(2); a.sta_a(PORT)
    a.lda_a(PORT); a.op(0x4A); a.op(0x66, VAL)          # LSR A, ROR zp
    a.dex(); a.bne('readbit')
    a.op(0x98); a.op(0x25, MASK); a.op(0x45, KEY)       # TYA, AND zp, EOR zp
    a.op(0xC5, VAL); a.beq('readgood')                  # CMP zp
    a.op(0xE6, BAD)                     # INC zp
    a.label('readgood')
    a.iny(); a.cpy(128); a.bne('readbyte')
    a.lda(3); a.sta_z(CNT)
    a.label('readtrail')
    a.jsr('clock0')
    a.op(0xC6, CNT)
    a.bne('readtrail')
    a.rts()

    # ---- 128 bytes out, (y & MASK) ^ KEY
    a.label('write')
    a.lda(0); a.jsr('begin')
    a.ldy(0)
    a.label('writebyte')
    a.op(0x98); a.op(0x25, MASK); a.op(0x45, KEY); a.sta_z(VAL)
    a.ldx(8); a.jsr('send')
    a.iny(); a.cpy(128); a.bne('writebyte')
    a.lda(5); a.sta_z(CNT)
    a.label('writetrail')
    a.jsr('clock0')
    a.op(0xC6, CNT)
    a.bne('writetrail')
    a.rts()

    a.link()
    assert len(a.b) < 0x1FF0
    rom = bytearray(0x40000)
    rom[:len(a.b)] = a.b
    for at in range(0x1FF6, 0x2000, 2):
        rom[at:at + 2] = struct.pack('<H', a.labels['reset'])
    with open(sys.argv[1], 'wb') as f:
        f.write(rom)


main()
