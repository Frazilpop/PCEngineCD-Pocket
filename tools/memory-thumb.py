# The Pocket's thumbnail at a Memory's end: " IPA", width, height (16-bit LE), then 4 bytes a dot.
# python3 -I tools/memory-thumb.py MEMORY.sta out.png (the .sta as the card has it)
import sys, zlib, struct
src, dst = sys.argv[1:]
t = open(src, 'rb').read()[-52764:]
w, h = struct.unpack('<HH', t[4:8]); px = t[8:]
rows = b"".join(b"\0" + bytes(c for x in range(w) for c in px[(x*h+y)*4:(x*h+y)*4+3]) for y in range(h))
def chunk(k, d): return struct.pack('>I', len(d)) + k + d + struct.pack('>I', zlib.crc32(k + d))
open(dst, 'wb').write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b''))
