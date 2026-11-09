"""A PC Engine CD test card and test disc of its own, for the simulation (tools/sim.sh).

    python3 -I tools/testcard.py build/sim/test

Makes build/sim/test/card.pce and Test Disc.cue with its two files, and sound.pce (below). Made here, a few
hundred bytes of HuC6280 code written out by hand, so the sim has a card and a disc that
are the repo's own to commit (a system card and the games are never committed). It stands where a
system card does and asks the drive what a game's boot does:

- the CPU runs from the card (the reset vector, MPR7 on page 0), the VDC and VCE are set
  up, the tiles copied by TIA, text drawn on the background; a sprite crosses the screen
  and a counter counts on the VDC's vertical interrupt, so a frame shows both are alive;
- the drive is reset (0x1804), which is what makes the firmware load the disc, and asked
  TEST UNIT READY until it's ready, through the real SCSI phases, a byte at a time;
- GET DIR INFO gives the first and last track, the disc's length, a track's start and
  type, each checked against what this file made;
- READ(6) of one sector by hand into RAM, and three by the auto-ACK of 0x1808 into CD RAM
  from further down the disc, so a seek and the read cache's buffers come into it, each
  sector's bytes summed against the sum made here;
- CD audio: track 2 plays (SAPSP, SAPEP) at 880 Hz left, 1320 Hz right, READ SUBQ follows
  it; the PSG's first channel sounds at about 440 Hz throughout, so the WAV shows each by pitch;
- the ADPCM chip's memory, each way a game reaches it: bytes written by the CPU and read back
  at both ends of the 64K, a sector by its DMA read back and summed, and that sector played
  to its end, so the sound of it is in the WAV for one run to be compared with another;
- Populous's 32K of cartridge RAM: 0x1F26 of the card spells POPULOUS, which main.sv looks
  for, and the RAM takes a pattern, mirrors and keeps apart;
- the pad: RUN appears at the bottom of the screen while Run is held.

The backdrop turns green when every check has passed and stays red if one fails, so the
first pixel of each line of frames.txt says how it went (tools/sim.sh looks). The line for
each check is on the screen, and the first failing one is where it stops.

sound.pce is the same card with no checks, to set the simulation's sound beside MAME's
(src/sim/console/compare_sound.py), as MAME stops the checks at ADPCM CPU. Over the PSG's
440 Hz it resets the drive, writes 4K to the ADPCM chip's memory by the CPU, a 1 kHz tone
in the MSM5205's own code (from the card's second 8K), and plays it at 16 kHz and then at
6.4 kHz, where it is 400 Hz; sweeps the PSG's first channel with the LFO, the second channel
a saw at volume 0, at each of the LFO's first two depths; and plays track 2. Its lines on the
screen say which part is sounding.
"""
import math
import os
import struct
import sys

CARD_SIZE = 0x40000
FONT_5X7 = {
    ' ': '0000000000', '0': '3E5149453E', '1': '00427F4000', '2': '4261514946', '3': '2141454B31',
    '4': '1814127F10', '5': '2745454539', '6': '3C4A494930', '7': '0171090503', '8': '3649494936',
    '9': '064949291E', 'A': '7E1111117E', 'B': '7F49494936', 'C': '3E41414122', 'D': '7F4141221C',
    'E': '7F49494941', 'F': '7F09090901', 'G': '3E4149497A', 'H': '7F0808087F', 'I': '00417F4100',
    'J': '2040413F01', 'K': '7F08142241', 'L': '7F40404040', 'M': '7F020C027F', 'N': '7F0408107F',
    'O': '3E4141413E', 'P': '7F09090906', 'Q': '3E4151215E', 'R': '7F09192946', 'S': '4649494931',
    'T': '01017F0101', 'U': '3F4040403F', 'V': '1F2040201F', 'W': '3F4038403F', 'X': '6314081463',
    'Y': '0708700807', 'Z': '6151494543', ':': '0036360000', '-': '0808080808',
}
CHARS = ' 0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ:-'

# the disc
DATA_SECTORS = 300
AUDIO_SECONDS = 20
AUDIO_PREGAP = 150                     # the audio track's PREGAP: on the disc, not in its file
READ1_LBA, READ3_LBA = 0x10, 0x100     # the sectors read, the second past the read cache's reach
DMA_LBA = 0x20                         # the sector that goes to the ADPCM chip's memory


def sector(lba):
    """A data sector: its LBA, then a pattern that differs by sector."""
    s = bytearray((i * 7 + lba * 13) & 0xFF for i in range(2048))
    s[0:3] = lba.to_bytes(3, 'big')
    return bytes(s)


def write_disc(out):
    name = 'Test Disc'
    with open(os.path.join(out, f'{name} (Track 1).bin'), 'wb') as f:
        for lba in range(DATA_SECTORS):
            f.write(sector(lba))
    frames = AUDIO_SECONDS * 75
    n = frames * 588
    audio = bytearray()
    for i in range(n):
        audio += struct.pack('<hh', int(8000 * math.sin(2 * math.pi * 880 * i / 44100)),
                             int(8000 * math.sin(2 * math.pi * 1320 * i / 44100)))
    with open(os.path.join(out, f'{name} (Track 2).bin'), 'wb') as f:
        f.write(audio)
    with open(os.path.join(out, f'{name}.cue'), 'w') as f:
        f.write(f'FILE "{name} (Track 1).bin" BINARY\n  TRACK 01 MODE1/2048\n    INDEX 01 00:00:00\n'
                f'FILE "{name} (Track 2).bin" BINARY\n  TRACK 02 AUDIO\n    PREGAP 00:02:00\n    INDEX 01 00:00:00\n')
    total = DATA_SECTORS + AUDIO_PREGAP + frames
    return total


def msf(lba):
    lba += 150
    return lba // 4500, (lba // 75) % 60, lba % 75


def bcd(v):
    return (v // 10) << 4 | v % 10


class Asm:
    def __init__(self, org):
        self.org, self.b, self.labels, self.fix = org, bytearray(), {}, []

    def pc(self):
        return self.org + len(self.b)

    def label(self, name):
        assert name not in self.labels, name
        self.labels[name] = self.pc()

    def db(self, *vals):
        for v in vals:
            if isinstance(v, str):
                self.fix.append((len(self.b), v, 'word'))
                self.b += b'\0\0'
            else:
                self.b.append(v & 0xFF)

    def rel(self, op, target):
        self.b.append(op)
        self.fix.append((len(self.b), target, 'rel'))
        self.b.append(0)

    def link(self):
        for at, name, kind in self.fix:
            v = self.labels[name]
            if kind == 'word':
                self.b[at:at + 2] = struct.pack('<H', v)
            elif kind == 'lo':
                self.b[at] = v & 0xFF
            elif kind == 'hi':
                self.b[at] = v >> 8
            else:
                d = v - (self.org + at + 1)
                assert -128 <= d <= 127, f'branch to {name} too far: {d}'
                self.b[at] = d & 0xFF

    # the instructions used. imm takes a number; abs a number or a label
    def imm(self, op, v):
        self.b += bytes((op, v & 0xFF))

    def abs(self, op, v):
        self.b.append(op)
        self.db(v) if isinstance(v, str) else self.b.extend(struct.pack('<H', v))

    def imm_lo(self, op, name):
        self.b.append(op)
        self.fix.append((len(self.b), name, 'lo'))
        self.b.append(0)

    def imm_hi(self, op, name):
        self.b.append(op)
        self.fix.append((len(self.b), name, 'hi'))
        self.b.append(0)

    def lda(self, v): self.imm(0xA9, v)
    def ldx(self, v): self.imm(0xA2, v)
    def ldy(self, v): self.imm(0xA0, v)
    def lda_a(self, v): self.abs(0xAD, v)
    def sta_a(self, v): self.abs(0x8D, v)
    def lda_z(self, v): self.imm(0xA5, v)
    def sta_z(self, v): self.imm(0x85, v)
    def ldx_z(self, v): self.imm(0xA6, v)
    def stx_z(self, v): self.imm(0x86, v)
    def sty_z(self, v): self.imm(0x84, v)
    def lda_iy(self, v): self.imm(0xB1, v)   # (zp),Y
    def sta_iy(self, v): self.imm(0x91, v)
    def lda_ax(self, v): self.abs(0xBD, v)
    def cmp(self, v): self.imm(0xC9, v)
    def cmp_z(self, v): self.imm(0xC5, v)
    def cpx(self, v): self.imm(0xE0, v)
    def cpy(self, v): self.imm(0xC0, v)
    def and_(self, v): self.imm(0x29, v)
    def ora(self, v): self.imm(0x09, v)
    def adc(self, v): self.imm(0x69, v)
    def adc_z(self, v): self.imm(0x65, v)
    def inc_z(self, v): self.imm(0xE6, v)
    def dec_z(self, v): self.imm(0xC6, v)
    def tam(self, mask): self.imm(0x53, mask)
    def st0(self, v): self.imm(0x03, v)
    def st1(self, v): self.imm(0x13, v)
    def st2(self, v): self.imm(0x23, v)
    def bne(self, t): self.rel(0xD0, t)
    def beq(self, t): self.rel(0xF0, t)
    def bpl(self, t): self.rel(0x10, t)
    def bmi(self, t): self.rel(0x30, t)
    def bcc(self, t): self.rel(0x90, t)
    def bcs(self, t): self.rel(0xB0, t)
    def bra(self, t): self.rel(0x80, t)
    def jmp(self, t): self.abs(0x4C, t)
    def jsr(self, t): self.abs(0x20, t)
    def op(self, code): self.b.append(code)
    def rts(self): self.op(0x60)
    def rti(self): self.op(0x40)
    def pha(self): self.op(0x48)
    def pla(self): self.op(0x68)
    def phx(self): self.op(0xDA)
    def plx(self): self.op(0xFA)
    def phy(self): self.op(0x5A)
    def ply(self): self.op(0x7A)
    def inx(self): self.op(0xE8)
    def iny(self): self.op(0xC8)
    def dex(self): self.op(0xCA)
    def dey(self): self.op(0x88)
    def clc(self): self.op(0x18)
    def lsr_a(self): self.op(0x4A)
    def asl_a(self): self.op(0x0A)
    def tax(self): self.op(0xAA)
    def tay(self): self.op(0xA8)
    def txa(self): self.op(0x8A)
    def tya(self): self.op(0x98)

    def tia(self, src, dst, n):
        self.op(0xE3)
        self.db(src)
        self.b += struct.pack('<HH', dst, n)


# zero page (physical 0x2000, MPR1 on RAM)
FRAME, CMDP, CMDP_H, DATAP, DATAP_H, TEXTP, TEXTP_H, ROW, COUNT, COUNT_H, STAT, MSG, SUM, SUM_H, SPRX, TRIES, PTR, PTR_H = range(0x10, 0x10 + 18)
CD_STAT, CD_DATA, CD_CTL, CD_FLAGS, CD_RST, CD_AUTO = 0x1800, 0x1801, 0x1802, 0x1803, 0x1804, 0x1808
BUF = 0x2800                # RAM: where GET DIR INFO's answers and a sector land


def sum_of(lba, n=1):
    return sum(sum(sector(lba + i)) for i in range(n)) & 0xFFFF


AD_OFFS_LO, AD_OFFS_HI, AD_DATA, AD_DMA, AD_STAT, AD_CTL, AD_RATE = 0x1808, 0x1809, 0x180A, 0x180B, 0x180C, 0x180D, 0x180E
KEY, HELD = 0x10 + 18, 0x10 + 19


def build(total, sound=False):
    a = Asm(0xE000)

    a.label('reset')
    a.op(0x78)                  # SEI
    a.op(0xD4)                  # CSH: 7.16 MHz
    a.op(0xD8)                  # CLD
    a.ldx(0xFF); a.op(0x9A)     # TXS
    a.lda(0xFF); a.tam(0x01)    # MPR0: the I/O page
    a.lda(0xF8); a.tam(0x02)    # MPR1: RAM, with the zero page and the stack
    a.lda(0x80); a.tam(0x04)    # MPR2: CD RAM
    # clear the zero page
    a.ldx(0)
    a.label('clearzp')
    a.op(0x74); a.b.append(0)   # STZ zp,X
    a.inx()
    a.bne('clearzp')
    # interrupts: the timer off and masked, only the VDC's let through
    a.lda(0); a.sta_a(0x0C01)
    a.lda(0x05); a.sta_a(0x1402)
    a.lda_a(0x0000)             # ack the VDC
    # the VCE: 5.37 MHz dots; the backdrop red, text white, sprite yellow
    a.lda(0); a.sta_a(0x0400)
    a.sta_a(0x0402); a.sta_a(0x0403)
    a.lda(0x38); a.sta_a(0x0404); a.lda(0x00); a.sta_a(0x0405)    # colour 0: red (G 0, R 7, B 0)
    a.lda(0xFF); a.sta_a(0x0404); a.lda(0x01); a.sta_a(0x0405)    # colour 1: white
    a.lda(0x00); a.sta_a(0x0402); a.lda(0x01); a.sta_a(0x0403)    # sprite colours
    a.lda(0x00); a.sta_a(0x0404); a.sta_a(0x0405)
    a.lda(0xF8); a.sta_a(0x0404); a.lda(0x01); a.sta_a(0x0405)    # yellow

    # the VDC's registers, as a card's start-up sets them for 256 x 240
    for reg, val in ((0x05, 0x0000), (0x06, 0), (0x07, 0), (0x08, 0), (0x09, 0x0000), (0x0A, 0x0202), (0x0B, 0x031F),
                     (0x0C, 0x0F02), (0x0D, 0x00EF), (0x0E, 0x0004), (0x0F, 0x0010), (0x13, 0x7F00)):
        a.st0(reg); a.st1(val & 0xFF); a.st2(val >> 8)
    # the tiles, at VRAM 0x1000: a glyph's tile is 0x100 + its place in CHARS
    a.st0(0); a.st1(0x00); a.st2(0x10); a.st0(2)
    a.tia('font', 0x0002, 32 * len(CHARS))
    # the sprite's pattern, 16 x 16 solid colour 1, at VRAM 0x2000
    a.st0(0); a.st1(0x00); a.st2(0x20); a.st0(2)
    a.ldx(16)
    a.label('spr')
    a.st1(0xFF); a.st2(0xFF)
    a.dex(); a.bne('spr')
    a.ldx(48)
    a.label('spr2')
    a.st1(0); a.st2(0)
    a.dex(); a.bne('spr2')
    # the background map: blanks. 32 x 32 at VRAM 0
    a.st0(0); a.st1(0); a.st2(0); a.st0(2)
    a.ldy(4)
    a.label('bat1')
    a.ldx(0)
    a.label('bat2')
    a.st1(0x00); a.st2(0x01)
    a.dex(); a.bne('bat2')
    a.dey(); a.bne('bat1')
    # the sprite table, at VRAM 0x7F00: sprite 0 in the bottom band, the rest off
    a.st0(0); a.st1(0x00); a.st2(0x7F); a.st0(2)
    a.st1(0x00); a.st2(0x01)                    # y: 256, the screen's 192
    a.st1(32); a.st2(0)                         # x
    a.st1(0x00); a.st2(0x01)                    # pattern
    a.st1(0x80); a.st2(0x00)                    # attributes: over the background
    a.ldx(63 * 4)
    a.label('sat')
    a.st1(0); a.st2(0)
    a.dex(); a.bne('sat')
    # on: background, sprites, the vertical interrupt
    a.st0(5); a.st1(0xC8); a.st2(0x00)
    a.lda(0xFF); a.sta_z(SPRX)
    a.op(0x58)                  # CLI

    # the PSG: channel 0 at about 440 Hz (3.58 MHz / 32 / 254), a triangle
    a.lda(0); a.sta_a(0x0800)
    a.lda(0xFF); a.sta_a(0x0801)
    a.lda(0xFE); a.sta_a(0x0802); a.lda(0x00); a.sta_a(0x0803)
    a.lda(0x40); a.sta_a(0x0804); a.lda(0x00); a.sta_a(0x0804)
    a.lda(0xFF); a.sta_a(0x0805)
    a.ldx(0)
    a.label('wave')
    a.txa(); a.cmp(16); a.bcc('waveup')
    a.op(0x49); a.b.append(0x1F)    # EOR #$1F
    a.label('waveup')
    a.sta_a(0x0806)
    a.inx(); a.cpx(32); a.bne('wave')
    a.lda(0x80 | 0x18); a.sta_a(0x0804)

    # ---- the checks ----
    def say(row, text):
        a.lda(row); a.sta_z(ROW)
        a.imm_lo(0xA9, 't' + text); a.sta_z(TEXTP)
        a.imm_hi(0xA9, 't' + text); a.sta_z(TEXTP_H)
        a.jsr('puts')
        strings.add(text)

    strings = set()
    if sound:
        sound_program(a, say)   # it ends in main, and the checks below are never reached
    say(1, 'PC ENGINE CD SIM TEST')

    # the drive's reset, which starts the firmware loading the disc
    a.lda(0x02); a.sta_a(CD_RST)
    a.jsr('wait_frame')
    a.lda(0x00); a.sta_a(CD_RST)
    a.jsr('wait_frame')

    # TEST UNIT READY until it says yes
    say(3, 'UNIT READY')
    a.lda(0); a.sta_z(TRIES)
    a.label('tur')
    a.inc_z(TRIES)
    a.lda_z(TRIES); a.cmp(120)
    a.bcc('tur1')
    a.jmp('fail')
    a.label('tur1')
    cmd(a, 'c_tur', 6, BUF)
    a.lda_z(STAT); a.beq('turok')
    a.jsr('wait_frame')
    a.bra('tur')
    a.label('turok')
    a.lda(3); a.sta_z(ROW)
    a.lda_z(TRIES)
    a.ldy(12); a.jsr('puthex')

    # GET DIR INFO: first and last track
    say(4, 'TRACKS')
    cmd(a, 'c_dir0', 10, BUF)
    check_mem(a, 0, 0x01)
    check_mem(a, 1, 0x02)
    show_bytes(a, 4, 12, 2)

    # the disc's length
    say(5, 'LENGTH')
    m, s, f = msf(total)
    cmd(a, 'c_dir1', 10, BUF)
    check_mem(a, 0, bcd(m))
    check_mem(a, 1, bcd(s))
    check_mem(a, 2, bcd(f))
    show_bytes(a, 5, 12, 3)

    # track 2: where the PREGAP puts it, and that it's audio
    say(6, 'TRACK 2')
    m, s, f = msf(DATA_SECTORS + AUDIO_PREGAP)
    cmd(a, 'c_dir2', 10, BUF)
    check_mem(a, 0, bcd(m))
    check_mem(a, 1, bcd(s))
    check_mem(a, 2, bcd(f))
    check_mem(a, 3, 0)
    show_bytes(a, 6, 12, 4)

    # track 1 is data
    say(7, 'TRACK 1')
    m, s, f = msf(0)
    cmd(a, 'c_dir3', 10, BUF)
    check_mem(a, 0, bcd(m))
    check_mem(a, 1, bcd(s))
    check_mem(a, 2, bcd(f))
    check_mem(a, 3, 4)
    show_bytes(a, 7, 12, 4)

    # one sector, by hand, into RAM
    say(8, 'READ HAND')
    cmd(a, 'c_read1', 6, BUF)
    a.lda_z(STAT); a.beq('r1ok'); a.jmp('fail')
    a.label('r1ok')
    a.lda(BUF & 0xFF); a.sta_z(PTR); a.lda(BUF >> 8); a.sta_z(PTR_H)
    a.lda(0x08); a.sta_z(COUNT_H); a.lda(0); a.sta_z(COUNT)
    a.jsr('sum')
    expect_sum(a, sum_of(READ1_LBA), 8)

    # three sectors, further down the disc, by the auto-ACK, into CD RAM
    say(9, 'READ AUTO')
    send_cmd(a, 'c_read3', 6)
    a.lda(0x00); a.sta_z(DATAP); a.lda(0x40); a.sta_z(DATAP_H)
    a.lda(0x18); a.sta_z(COUNT_H); a.lda(0); a.sta_z(COUNT)
    a.jsr('read_auto')
    a.jsr('finish_cmd')
    a.lda_z(STAT); a.beq('r3ok'); a.jmp('fail')
    a.label('r3ok')
    a.lda(0x00); a.sta_z(PTR); a.lda(0x40); a.sta_z(PTR_H)
    a.lda(0x18); a.sta_z(COUNT_H); a.lda(0); a.sta_z(COUNT)
    a.jsr('sum')
    expect_sum(a, sum_of(READ3_LBA, 3), 9)

    # The ADPCM chip's memory, by the CPU: two patterns at the 64K's two ends, each read back
    # after the other is written, then at once again
    say(16, 'ADPCM CPU')
    ad_set(a, 0xFF00, 0x03, 0x02)
    a.lda(0xA5); a.sta_z(KEY); a.jsr('ad_write')
    ad_set(a, 0x0100, 0x03, 0x02)
    a.lda(0x3C); a.sta_z(KEY); a.jsr('ad_write')
    ad_set(a, 0xFF00, 0x0C, 0x08)
    a.lda(0xA5); a.sta_z(KEY); a.jsr('ad_check')
    ad_set(a, 0x0100, 0x0C, 0x08)
    a.lda(0x3C); a.sta_z(KEY); a.jsr('ad_check')

    # by its DMA: one sector from the disc, read back by the CPU into CD RAM and summed
    say(17, 'ADPCM DMA')
    ad_set(a, 0x4000, 0x03, 0x02)
    send_cmd(a, 'c_readdma', 6)
    a.lda(0x03); a.sta_a(AD_DMA)
    a.label('dmawait')
    a.lda_a(CD_STAT); a.and_(0xF8); a.cmp(0xD8); a.bne('dmawait')
    a.lda(0); a.sta_a(AD_DMA)
    a.jsr('finish_cmd')
    a.lda_z(STAT); a.beq('dok'); a.jmp('fail')
    a.label('dok')
    ad_set(a, 0x4000, 0x0C, 0x08)
    a.lda_a(AD_DATA); a.jsr('ad_rdwait')        # the first read gives what was there before
    a.lda(0x00); a.sta_z(DATAP); a.lda(0x40); a.sta_z(DATAP_H)
    a.lda(0x08); a.sta_z(COUNT_H); a.lda(0); a.sta_z(COUNT)
    a.ldy(0)
    a.label('dmard')
    a.lda_a(AD_DATA); a.sta_iy(DATAP); a.jsr('ad_rdwait')
    a.inc_z(DATAP); a.bne('dmard1')
    a.inc_z(DATAP_H)
    a.label('dmard1')
    a.lda_z(COUNT); a.bne('dmard2')
    a.dec_z(COUNT_H)
    a.label('dmard2')
    a.dec_z(COUNT)
    a.lda_z(COUNT); a.bne('dmard')
    a.lda_z(COUNT_H); a.bne('dmard')
    a.lda(0x00); a.sta_z(PTR); a.lda(0x40); a.sta_z(PTR_H)
    a.lda(0x08); a.sta_z(COUNT_H); a.lda(0); a.sta_z(COUNT)
    a.jsr('sum')
    expect_sum(a, sum_of(DMA_LBA), 17)

    # that sector played at the fastest rate, to its end
    say(18, 'ADPCM PLAY')
    a.lda(0x0E); a.sta_a(AD_RATE)
    ad_set(a, 0x4000, 0x0C, 0x08)
    ad_offs(a, 0x0800)
    a.lda(0x10); a.sta_a(AD_CTL); a.lda(0x00); a.sta_a(AD_CTL)  # the length
    a.lda(0x60); a.sta_a(AD_CTL)                                # play, stopping at the end
    a.jsr('wait_frame')
    a.lda_a(AD_STAT); a.and_(0x08); a.bne('plgo'); a.jmp('fail')
    a.label('plgo')
    a.lda(60); a.sta_z(TRIES)
    a.label('plwait')
    a.jsr('wait_frame')
    a.lda_a(AD_STAT); a.and_(0x08); a.beq('pldone')
    a.dec_z(TRIES); a.bne('plwait')
    a.jmp('fail')
    a.label('pldone')
    a.lda_a(AD_STAT); a.and_(0x01); a.bne('plend'); a.jmp('fail')
    a.label('plend')
    a.lda(0x00); a.sta_a(AD_CTL)

    # Populous's RAM: bank 0x40 and bank 0x43, each its own, and 0x44 a mirror of 0x40
    say(19, 'POPULOUS RAM')
    a.lda(0x40); a.tam(0x08)
    a.lda(0x69); a.sta_z(KEY); a.jsr('pr_write')
    a.lda(0x43); a.tam(0x08)
    a.lda(0x96); a.sta_z(KEY); a.jsr('pr_write')
    a.jsr('pr_check')
    a.lda(0x40); a.tam(0x08)
    a.lda(0x69); a.sta_z(KEY); a.jsr('pr_check')
    a.lda(0x44); a.tam(0x08)
    a.jsr('pr_check')

    # CD audio: track 2 from its start, to the disc's end, in the background
    say(10, 'CD AUDIO')
    cmd(a, 'c_sapsp', 10, BUF)
    a.lda_z(STAT); a.beq('p1ok'); a.jmp('fail')
    a.label('p1ok')
    cmd(a, 'c_sapep', 10, BUF)
    a.lda_z(STAT); a.beq('p2ok'); a.jmp('fail')
    a.label('p2ok')
    a.ldx(30)
    a.label('wplay')
    a.jsr('wait_frame')
    a.dex(); a.bne('wplay')
    say(11, 'SUBQ')
    cmd(a, 'c_subq', 10, BUF)
    a.lda_z(STAT); a.beq('sqok'); a.jmp('fail')
    a.label('sqok')
    check_mem(a, 0, 0x00)       # playing
    check_mem(a, 2, 0x02)       # track 2
    show_bytes(a, 11, 12, 6)

    # all good: a green backdrop
    a.lda(0); a.sta_a(0x0402); a.sta_a(0x0403)
    a.lda(0xC0); a.sta_a(0x0404); a.lda(0x01); a.sta_a(0x0405)   # G 7, R 0, B 0
    say(13, 'ALL GOOD')
    a.jmp('main')

    a.label('fail')
    say(13, 'FAILED')
    a.label('main')
    # the counter and the pad, for ever
    a.jsr('wait_frame')
    a.lda(14); a.sta_z(ROW)
    a.lda_z(FRAME); a.ldy(12); a.jsr('puthex')
    # the pad's buttons: CLR high then low, SEL low
    a.lda(0x01); a.sta_a(0x1000)
    a.lda(0x03); a.sta_a(0x1000)
    a.lda(0x01); a.sta_a(0x1000)
    a.lda(0x00); a.sta_a(0x1000)
    a.op(0xEA); a.op(0xEA); a.op(0xEA); a.op(0xEA)
    a.lda_a(0x1000)
    a.and_(0x08)
    a.bne('norun')
    say(15, 'RUN')
    a.jmp('main')
    a.label('norun')
    say(15, '   ')
    a.jmp('main')

    # ---- subroutines ----
    # (the sprite moves here, not in the interrupt, which would cut into a write's register sequence)
    a.label('wait_frame')
    a.lda_z(FRAME)
    a.label('wf1')
    a.cmp_z(FRAME); a.beq('wf1')
    a.inc_z(SPRX)
    a.st0(0); a.st1(0x01); a.st2(0x7F)
    a.st0(2)
    a.lda_z(SPRX); a.sta_a(0x0002)
    a.lda(0); a.sta_a(0x0003)
    a.rts()

    a.label('irq')
    a.pha()
    a.lda_a(0x0000)             # ack the VDC
    a.inc_z(FRAME)
    a.pla()
    a.rti()

    a.label('nothing')
    a.rti()

    # the text at TEXTP on row ROW, from column 1. Bytes are tile numbers, 0xFF ends it
    a.label('puts')
    a.jsr('setrow')
    a.ldy(0)
    a.label('puts1')
    a.lda_iy(TEXTP)
    a.cmp(0xFF); a.beq('puts2')
    a.sta_a(0x0002)
    a.lda(0x01); a.sta_a(0x0003)
    a.iny()
    a.bra('puts1')
    a.label('puts2')
    a.rts()

    # MAWR to ROW's first column + Y (setrow: + 1)
    a.label('setrow')
    a.ldy(1)
    a.label('setrowy')
    a.st0(0)
    a.lda_z(ROW)
    # row * 32
    a.op(0x0A); a.op(0x0A); a.op(0x0A); a.op(0x0A); a.op(0x0A)    # ASL A x5: the low byte
    a.pha()
    a.tya(); a.clc()
    a.sta_z(COUNT)
    a.pla()
    a.adc_z(COUNT)
    a.sta_a(0x0002)
    a.lda_z(ROW); a.lsr_a(); a.lsr_a(); a.lsr_a()
    a.sta_a(0x0003)
    a.st0(2)
    a.rts()

    # A in hex at column Y of ROW
    a.label('puthex')
    a.pha()
    a.jsr('setrowy')
    a.pla()
    a.jmp('hex')
    a.label('hex')
    a.pha()
    a.lsr_a(); a.lsr_a(); a.lsr_a(); a.lsr_a()
    a.jsr('nibble')
    a.pla()
    a.and_(0x0F)
    a.label('nibble')
    a.clc(); a.adc(1)           # '0' is CHARS[1]
    a.sta_a(0x0002)
    a.lda(0x01); a.sta_a(0x0003)
    a.rts()

    # ---- the ADPCM chip's memory: 256 bytes of (y * 1) ^ KEY through the CPU's port ----
    a.label('ad_write')
    a.ldy(0)
    a.label('adw1')
    a.tya(); a.imm(0x45, KEY)   # EOR zp
    a.sta_a(AD_DATA)
    a.label('adw2')
    a.lda_a(AD_STAT); a.and_(0x04); a.bne('adw2')
    a.iny(); a.bne('adw1')
    a.rts()

    a.label('ad_rdwait')
    a.pha()
    a.label('adr0')
    a.lda_a(AD_STAT); a.and_(0x80); a.bne('adr0')
    a.pla()
    a.rts()

    a.label('ad_check')
    a.lda_a(AD_DATA); a.jsr('ad_rdwait')    # the first read gives what was there before
    a.ldy(0)
    a.label('adc1')
    a.lda_a(AD_DATA); a.sta_z(HELD); a.jsr('ad_rdwait')
    a.tya(); a.imm(0x45, KEY); a.cmp_z(HELD)
    a.beq('adc2')
    a.jmp('fail')
    a.label('adc2')
    a.iny(); a.bne('adc1')
    a.rts()

    # ---- 256 bytes at MPR3's bank ----
    a.label('pr_write')
    a.lda(0x00); a.sta_z(PTR); a.lda(0x60); a.sta_z(PTR_H)
    a.ldy(0)
    a.label('prw1')
    a.tya(); a.imm(0x45, KEY); a.sta_iy(PTR)
    a.iny(); a.bne('prw1')
    a.rts()

    a.label('pr_check')
    a.lda(0x00); a.sta_z(PTR); a.lda(0x60); a.sta_z(PTR_H)
    a.ldy(0)
    a.label('prc1')
    a.tya(); a.imm(0x45, KEY); a.imm(0xD1, PTR)     # CMP (zp),Y
    a.beq('prc2')
    a.jmp('fail')
    a.label('prc2')
    a.iny(); a.bne('prc1')
    a.rts()

    # ---- SCSI, as a system card's routines go ----
    # select the drive and send the command at CMDP, COUNT bytes
    a.label('send')
    a.lda(0x81); a.sta_a(CD_DATA); a.sta_a(CD_STAT)
    a.label('sbsy')
    a.lda_a(CD_STAT); a.bpl('sbsy')
    a.ldy(0)
    a.label('s1')
    a.lda_a(CD_STAT); a.and_(0xF8); a.cmp(0xD0); a.bne('s1')      # BSY REQ CD: command
    a.lda_iy(CMDP); a.sta_a(CD_DATA)
    a.jsr('ack')
    a.iny(); a.op(0xC4); a.b.append(COUNT)    # CPY zp
    a.bne('s1')
    a.rts()

    # ACK until REQ goes
    a.label('ack')
    a.lda_a(CD_CTL); a.ora(0x80); a.sta_a(CD_CTL)
    a.label('ack1')
    a.lda_a(CD_STAT); a.and_(0x40); a.bne('ack1')
    a.lda_a(CD_CTL); a.and_(0x7F); a.sta_a(CD_CTL)
    a.rts()

    # the phases after the command, to its message: data to DATAP, then STAT and MSG. BSY
    # is low between them, as the drive has yet to answer
    a.label('phases')
    a.label('p0')
    a.lda_a(CD_STAT)
    a.and_(0xF8)
    a.cmp(0xC8); a.beq('pdata')
    a.cmp(0xD8); a.beq('pstat')
    a.cmp(0xF8); a.beq('pmsg')
    a.bra('p0')
    a.label('pdata')
    a.lda_a(CD_DATA); a.ldy(0); a.sta_iy(DATAP)
    a.jsr('ack')
    a.inc_z(DATAP); a.bne('p0')
    a.inc_z(DATAP_H)
    a.bra('p0')
    a.label('pstat')
    a.lda_a(CD_DATA); a.sta_z(STAT)
    a.jsr('ack')
    a.bra('p0')
    a.label('pmsg')
    a.lda_a(CD_DATA); a.sta_z(MSG)
    a.jsr('ack')
    a.label('pdone')
    a.lda_a(CD_STAT); a.bmi('pdone')
    a.rts()

    a.label('finish_cmd')
    a.jmp('phases')

    # COUNT bytes through the auto-ACK: 0x1808 is read, the drive steps on
    a.label('read_auto')
    a.ldy(0)
    a.label('ra0')
    a.lda_a(CD_STAT); a.and_(0xF8); a.cmp(0xC8); a.bne('ra0')
    a.lda_a(CD_AUTO)
    a.sta_iy(DATAP)
    # a wait for the ACK's round trip, about what a TIN's 6 cycles a byte leave
    a.op(0xEA); a.op(0xEA); a.op(0xEA); a.op(0xEA)
    a.inc_z(DATAP); a.bne('ra1')
    a.inc_z(DATAP_H)
    a.label('ra1')
    a.lda_z(COUNT); a.bne('ra2')
    a.dec_z(COUNT_H)
    a.label('ra2')
    a.dec_z(COUNT)
    a.lda_z(COUNT); a.bne('ra0')
    a.lda_z(COUNT_H); a.bne('ra0')
    a.rts()

    # the 16-bit sum of COUNT bytes at PTR, into SUM
    a.label('sum')
    a.lda(0); a.sta_z(SUM); a.sta_z(SUM_H)
    a.ldy(0)
    a.label('sum1')
    a.lda_iy(PTR); a.clc(); a.adc_z(SUM); a.sta_z(SUM)
    a.lda_z(SUM_H); a.adc(0); a.sta_z(SUM_H)
    a.iny(); a.bne('sum2')
    a.inc_z(PTR_H)
    a.label('sum2')
    a.lda_z(COUNT); a.bne('sum3')
    a.dec_z(COUNT_H)
    a.label('sum3')
    a.dec_z(COUNT)
    a.lda_z(COUNT); a.bne('sum1')
    a.lda_z(COUNT_H); a.bne('sum1')
    a.rts()

    # ---- data ----
    def table(name, *bytes_):
        a.label(name)
        a.db(*bytes_)

    table('c_tur', 0, 0, 0, 0, 0, 0)
    table('c_dir0', 0xDE, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    table('c_dir1', 0xDE, 1, 0, 0, 0, 0, 0, 0, 0, 0)
    table('c_dir2', 0xDE, 2, 0x02, 0, 0, 0, 0, 0, 0, 0)
    table('c_dir3', 0xDE, 2, 0x01, 0, 0, 0, 0, 0, 0, 0)
    table('c_read1', 0x08, READ1_LBA >> 16, READ1_LBA >> 8 & 0xFF, READ1_LBA & 0xFF, 1, 0)
    table('c_read3', 0x08, READ3_LBA >> 16, READ3_LBA >> 8 & 0xFF, READ3_LBA & 0xFF, 3, 0)
    table('c_readdma', 0x08, DMA_LBA >> 16, DMA_LBA >> 8 & 0xFF, DMA_LBA & 0xFF, 1, 0)
    table('c_sapsp', 0xD8, 3, 0x02, 0, 0, 0, 0, 0, 0, 0x80)     # at track 2, playing
    table('c_sapep', 0xD9, 3, 0x03, 0, 0, 0, 0, 0, 0, 0x80)     # to the disc's end, no interrupt
    table('c_subq', 0xDD, 10, 0, 0, 0, 0, 0, 0, 0, 0)

    for text in sorted(strings):
        a.label('t' + text)
        a.db(*[CHARS.index(c) for c in text], 0xFF)

    a.label('font')
    for c in CHARS:
        cols = bytes.fromhex(FONT_5X7[c])
        rows = [0] * 8
        for x, col in enumerate(cols):
            for y in range(8):
                if col >> y & 1:
                    rows[y] |= 0x80 >> (x + 1)
        # planes 0 and 1 as words, then 2 and 3: colour 1 is plane 0 alone
        for y in range(8):
            a.db(rows[y], 0)
        a.db(*[0] * 16)

    a.link()
    code = bytes(a.b)
    assert len(code) <= 0x1F26, f'the code has outgrown its 8K page: {len(code)}'
    page = bytearray(code.ljust(0x2000, b'\xFF'))
    page[0x1F26:0x1F2E] = b'POPULOUS'   # main.sv's look at the card, which gives it the 32K
    for at, name in ((0x1FF6, 'nothing'), (0x1FF8, 'irq'), (0x1FFA, 'nothing'), (0x1FFC, 'nothing'), (0x1FFE, 'reset')):
        page[at:at + 2] = struct.pack('<H', a.labels[name])
    # (a system card's size, so the ROM's mirroring is a system card's)
    return bytes(page).ljust(CARD_SIZE, b'\xFF')


def sound_program(a, say):
    """sound.pce's: each chip in turn, with nothing that can stop it."""
    say(1, 'PC ENGINE CD SOUND TEST')
    a.lda(0x00); a.sta_a(0x180F)    # no fade, as a system card leaves it: MAME's ADPCM is silent until then
    a.lda(0x02); a.sta_a(CD_RST)
    a.jsr('wait_frame')
    a.lda(0x00); a.sta_a(CD_RST)
    a.jsr('wait_frame')
    say(3, 'UNIT READY')
    a.label('s_tur')
    a.jsr('wait_frame')
    cmd(a, 'c_tur', 6, BUF)
    a.lda_z(STAT); a.bne('s_tur')

    # the tone, 4K by the CPU from 0, out of the card's second 8K on MPR3
    say(4, 'ADPCM WRITE')
    a.lda(0x01); a.tam(0x08)
    a.lda(0x00); a.sta_z(PTR); a.lda(0x60); a.sta_z(PTR_H)
    ad_set(a, 0x0000, 0x03, 0x02)
    a.ldx(len(ADPCM_TONE) // 256)
    a.ldy(0)
    a.label('s_adw')
    a.lda_iy(PTR); a.sta_a(AD_DATA)
    a.label('s_adb')
    a.lda_a(AD_STAT); a.and_(0x04); a.bne('s_adb')
    a.iny(); a.bne('s_adw')
    a.inc_z(PTR_H)
    a.dex(); a.bne('s_adw')
    for row, rate, text in ((5, 0x0E, 'ADPCM 16K'), (6, 0x0B, 'ADPCM 6K4')):
        say(row, text)
        a.lda(rate); a.sta_a(AD_RATE)
        ad_set(a, 0x0000, 0x0C, 0x08)
        ad_offs(a, 0x1000)
        a.lda(0x10); a.sta_a(AD_CTL); a.lda(0x00); a.sta_a(AD_CTL)
        a.lda(0x60); a.sta_a(AD_CTL)
        a.lda(150); a.sta_z(TRIES)
        a.label(f's_adp{row}')
        a.jsr('wait_frame')
        a.lda_a(AD_STAT); a.and_(0x08); a.beq(f's_adq{row}')
        a.dec_z(TRIES); a.bne(f's_adp{row}')
        a.label(f's_adq{row}')
        a.lda(0x00); a.sta_a(AD_CTL)
        wait_frames(a, 10)

    # the LFO: the second channel a saw, 0 to 31, as the first channel's modulator
    a.lda(1); a.sta_a(0x0800)
    a.lda(0x40); a.sta_a(0x0804); a.lda(0x00); a.sta_a(0x0804)
    a.ldx(0)
    a.label('s_saw')
    a.txa(); a.sta_a(0x0806)
    a.inx(); a.cpx(32); a.bne('s_saw')
    a.lda(0x00); a.sta_a(0x0802); a.lda(0x04); a.sta_a(0x0803)
    a.lda(0x80); a.sta_a(0x0804); a.lda(0xFF); a.sta_a(0x0805)    # on at volume 0: it drives the LFO, unheard
    a.lda(0x10); a.sta_a(0x0808)
    for row, ctl, text in ((7, 0x01, 'LFO 1'), (8, 0x02, 'LFO 2')):
        say(row, text)
        a.lda(ctl); a.sta_a(0x0809)
        wait_frames(a, 40)
    a.lda(0x80); a.sta_a(0x0809)
    a.lda(1); a.sta_a(0x0800); a.lda(0x00); a.sta_a(0x0804)
    a.lda(0); a.sta_a(0x0800)
    wait_frames(a, 10)

    say(9, 'CD AUDIO')
    cmd(a, 'c_sapsp', 10, BUF)
    cmd(a, 'c_sapep', 10, BUF)
    wait_frames(a, 45)
    say(13, 'DONE')
    a.jmp('main')


MSM_STEPS = [int(16 * 1.1 ** i) for i in range(49)]
MSM_ADJUST = [-1, -1, -1, -1, 2, 4, 6, 8]


def msm5205_step(signal, index, n):
    """One nibble through the MSM5205 (OKI ADPCM): the new 12-bit signal and step index."""
    step = MSM_STEPS[index]
    d = step >> 3
    if n & 1: d += step >> 2
    if n & 2: d += step >> 1
    if n & 4: d += step
    v = signal - d if n & 8 else signal + d
    return max(-2048, min(2047, v)), max(0, min(48, index + MSM_ADJUST[n & 7]))


def msm5205_decode(data):
    """What the chip plays from data, high nibble first: compare_sound.py checks the sim by it."""
    signal, index, out = 0, 0, []
    for byte in data:
        for n in (byte >> 4, byte & 15):
            signal, index = msm5205_step(signal, index, n)
            out.append(signal)
    return out


def msm5205_tone(hz=1000, rate=16000, amp=600, nbytes=4096):
    """A sine in the MSM5205's ADPCM, each nibble the one whose decoded value comes nearest,
    so what the chip plays is a tone."""
    signal, index, nibbles = 0, 0, []
    for i in range(nbytes * 2):
        target = round(amp * math.sin(2 * math.pi * hz * i / rate))
        n = min(range(16), key=lambda n: abs(msm5205_step(signal, index, n)[0] - target))
        signal, index = msm5205_step(signal, index, n)
        nibbles.append(n)
    return bytes(nibbles[i] << 4 | nibbles[i + 1] for i in range(0, len(nibbles), 2))


ADPCM_TONE = msm5205_tone()


def wait_frames(a, n):
    a.ldx(n)
    label = f'wf{len(a.b)}'
    a.label(label)
    a.jsr('wait_frame')
    a.dex(); a.bne(label)


def ad_offs(a, value):
    a.lda(value & 0xFF); a.sta_a(AD_OFFS_LO); a.lda(value >> 8); a.sta_a(AD_OFFS_HI)


def ad_set(a, offs, up, down):
    """An address from the offset: its control bit's fall takes it. Up and down say which."""
    ad_offs(a, offs)
    a.lda(up); a.sta_a(AD_CTL); a.lda(down); a.sta_a(AD_CTL)
    a.lda(0); a.sta_a(AD_CTL)


def send_cmd(a, name, length):
    a.imm_lo(0xA9, name); a.sta_z(CMDP)
    a.imm_hi(0xA9, name); a.sta_z(CMDP_H)
    a.lda(length); a.sta_z(COUNT)
    a.jsr('send')


def cmd(a, name, length, to):
    """A whole command: it goes, its data lands at to, its status in STAT."""
    send_cmd(a, name, length)
    a.lda(to & 0xFF); a.sta_z(DATAP); a.lda(to >> 8); a.sta_z(DATAP_H)
    a.jsr('phases')


def check_mem(a, at, value):
    """BUF + at has to be value."""
    a.lda_a(BUF + at)
    a.cmp(value)
    label = f'cm{len(a.b)}'
    a.beq(label)
    a.jmp('fail')
    a.label(label)


def show_bytes(a, row, col, n):
    a.lda(row); a.sta_z(ROW)
    a.ldy(col); a.jsr('setrowy')
    for i in range(n):
        a.lda_a(BUF + i); a.jsr('hex')


def expect_sum(a, value, row):
    a.lda(row); a.sta_z(ROW)
    a.lda_z(SUM_H); a.ldy(12); a.jsr('puthex')
    a.lda_z(SUM); a.jsr('hex')
    a.lda_z(SUM_H); a.cmp(value >> 8)
    label = f'es{len(a.b)}'
    a.beq(label)
    a.jmp('fail')
    a.label(label)
    a.lda_z(SUM); a.cmp(value & 0xFF)
    label = f'es{len(a.b)}'
    a.beq(label)
    a.jmp('fail')
    a.label(label)


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    total = write_disc(out)
    with open(os.path.join(out, 'card.pce'), 'wb') as f:
        f.write(build(total))
    sound = bytearray(build(total, sound=True))
    sound[0x2000:0x2000 + len(ADPCM_TONE)] = ADPCM_TONE      # bank 1, which the sound program puts on MPR3
    with open(os.path.join(out, 'sound.pce'), 'wb') as f:
        f.write(sound)


if __name__ == '__main__':
    main()
