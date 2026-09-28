# Decodes the character map of WoW's cached Slug font files (_anniversary_\Fonts\*.slug).
# Header (reverse-engineered): u32s at 0x50: [8, 0x70, dirCount, dirOff, blockOff, glyphCount, ...],
# offsets relative to 0x50. Directory: dirCount x u16, index = codepoint >> 8, value = block (0xFFFF none).
# Block: 256 x u32 glyph index for (codepoint & 0xFF); 0 = no glyph. Verified on Latin-1/cp1252/MacRoman.
import struct, sys, os, unicodedata
FONTS = r"C:\World of Warcraft\_anniversary_\Fonts"
NAMES = {"615960.slug": "FRIZQT__ (Friz Quadrata TT, roman)", "615971.slug": "FRIZQT___CYR (russian)",
         "615968.slug": "2002 (korean)", "615965.slug": "ARKai_T (simplifiedchinese)",
         "615974.slug": "bKAI00M (traditionalchinese)"}
class Slug:
    def __init__(self, fn):
        self.d = open(os.path.join(FONTS, fn), "rb").read(8 * 1024 * 1024)
        f = struct.unpack("<8I", self.d[0x50:0x70])
        self.count, self.dir, self.blocks, self.glyphs = f[2], 0x50 + f[3], 0x50 + f[4], f[5]
    def glyph(self, cp):
        hi = cp >> 8
        if hi >= self.count: return 0
        b = struct.unpack("<H", self.d[self.dir + 2 * hi:self.dir + 2 * hi + 2])[0]
        if b == 0xFFFF: return 0
        o = self.blocks + b * 0x400 + (cp & 0xFF) * 4
        return struct.unpack("<I", self.d[o:o + 4])[0]
if __name__ == "__main__":
    chars = sys.argv[1] if len(sys.argv) > 1 else "·×—–…→▾★✓✔•§"
    fonts = [(fn, Slug(fn)) for fn in NAMES]
    print("%-8s %-3s " % ("cp", "ch") + " | ".join(NAMES[fn].split(" ")[0] for fn, _ in fonts))
    for c in chars:
        print("U+%04X %-3s " % (ord(c), c) + " | ".join("%8s" % ("yes" if s.glyph(ord(c)) else "NO") for _, s in fonts)
              + "   " + unicodedata.name(c, "?"))
