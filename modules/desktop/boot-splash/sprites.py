"""Render the hex-dump splash: every image fireproof.script shows, and the data it reads.

Usage: sprites.py OUTDIR FONT.bdf, with the colours as RRGGBB in the environment (bg, bgAlt, ui,
uiAlt, muted, fgAlt, fg, accent, band, accentHi).

The dump is an `xxd -a` listing of a LUKS2 header (binary header, JSON, secondary header, JSON
copy) down to keyslot 0, then a btrfs superblock in the data segment, both encrypted and plain.
The layout, offsets and parameters are real; salts, UUIDs and checksums come from a fixed seed.
Each line is a PNG of one text row: 16 bytes in xxd's columns, 8x16 glyphs at 2x. Writes
data.script, a Plymouth-script prelude with the listing's shape and the bytes the script needs
for cursor knockouts.
"""

import json
import os
import random
import struct
import sys
from pathlib import Path

from PIL import Image

PX, FW, FH = 2, 8, 16
CW, CH = FW * PX, FH * PX
N = 16  # bytes per line
HEX0, ASC0 = 10, 10 + N // 2 * 5 + 1  # first hex and first ASCII column
COLS = ASC0 + N
SLOT = 0x8000  # keyslot 0's area
SLOT_LINES = 40
KEY_LINES = 4  # lines a passphrase can select, 64 bytes
SB = 0x1010000  # btrfs superblock: 16 MiB segment offset + 64 KiB
SEG_ROWS, MAGIC_ROW = 17, 8
SEG_BASE = SB + 0x40 - MAGIC_ROW * 16  # puts _BHRfS_M on the middle row
SEEK_STEPS, NOISE, FRONT = 8, 18, 4
LABELS = {
    "passphrase": "passphrase",
    "pin": "security key PIN",
    "recovery": "recovery key",
    "touch": "touch security key",
}


def colour(name):
    h = os.environ[name]
    return tuple(int(h[i : i + 2], 16) for i in (0, 2, 4))


def mix(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def load_bdf(path):
    """{codepoint: 16 rows of 8-bit ints} for a cell-sized BDF font."""
    glyphs, ascent, code, bbx, rows = {}, None, None, None, None
    for line in Path(path).read_text().splitlines():
        word, _, rest = line.partition(" ")
        if word == "FONT_ASCENT":
            ascent = int(rest)
        elif word == "ENCODING":
            code = int(rest)
        elif word == "BBX":
            bbx = list(map(int, rest.split()))
        elif word == "BITMAP":
            rows = []
        elif word == "ENDCHAR":
            w, h, xo, yo = bbx
            cell = [0] * FH
            top = ascent - (yo + h)
            for j, v in enumerate(rows):
                if 0 <= top + j < FH:
                    cell[top + j] = v >> xo if xo >= 0 else v << -xo
            glyphs[code] = cell
            rows = None
        elif rows is not None:
            rows.append(int(word, 16) >> (len(word) * 4 - 8))
    return glyphs


class Painter:
    def __init__(self, font):
        self.font, self.cache = font, {}

    def glyph(self, code, rgb):
        key = (code, rgb)
        if key not in self.cache:
            img = Image.new("RGBA", (FW, FH), rgb + (0,))
            px = img.load()
            for j, v in enumerate(self.font.get(code, [0] * FH)):
                for i in range(FW):
                    if (v >> (FW - 1 - i)) & 1:
                        px[i, j] = rgb + (255,)
            self.cache[key] = img.resize((CW, CH), Image.Resampling.NEAREST)
        return self.cache[key]

    def text(self, img, col, s, rgb):
        for i, ch in enumerate(s):
            g = self.glyph(ord(ch), rgb)
            img.alpha_composite(g, ((col + i) * CW, 0))


def hc(k):
    return HEX0 + k // 2 * 5 + k % 2 * 2


def asc(b):
    return chr(b) if 32 <= b < 127 else "."


def row(p, addr, data, off, hx, ac, band=None):
    """One xxd line: offset (when off is set), hex groups, ASCII gutter; band fills both byte
    areas behind the text, as a selection does."""
    img = Image.new("RGBA", (COLS * CW, CH), (0, 0, 0, 0))
    if band:
        img.paste(band + (255,), (hc(0) * CW, 0, (hc(N - 1) + 2) * CW, CH))
        img.paste(band + (255,), (ASC0 * CW, 0, (ASC0 + N) * CW, CH))
    if data is None:  # a squeezed run of zero lines
        p.text(img, 0, "*", hx)
        return img
    if off and addr is not None:
        p.text(img, 0, f"{addr:08x}:", off)
    for k, b in enumerate(data):
        p.text(img, hc(k), f"{b:02x}", hx)
        p.text(img, ASC0 + k, asc(b), ac)
    return img


def luks_header(buf, at, magic, offset, rng):
    """cryptsetup's luks2_hdr_disk: magic, version, hdr_size, seqid, label, csum_alg, salt, uuid,
    subsystem, hdr_offset, csum."""
    buf[at : at + 6] = magic
    struct.pack_into(">HQQ", buf, at + 6, 2, 0x4000, 7)
    buf[at + 0x48 : at + 0x4E] = b"sha256"
    buf[at + 0x68 : at + 0xA8] = rng.randbytes(64)
    buf[at + 0xA8 : at + 0xA8 + 36] = UUID.encode()
    struct.pack_into(">Q", buf, at + 0x100, offset)
    buf[at + 0x1C0 : at + 0x1E0] = rng.randbytes(32)


rng = random.Random(1442)
UUID = "-".join(rng.randbytes(n).hex() for n in (4, 2, 2, 2, 6))
B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"


def b64():
    return "".join(rng.choice(B64) for _ in range(43)) + "="


METADATA = json.dumps(
    {
        "keyslots": {
            "0": {
                "type": "luks2",
                "key_size": 64,
                "af": {"type": "luks1", "stripes": 4000, "hash": "sha256"},
                "area": {"type": "raw", "offset": str(SLOT), "size": "258048",
                         "encryption": "aes-xts-plain64", "key_size": 64},
                "kdf": {"type": "argon2id", "time": 4, "memory": 1048576, "cpus": 4, "salt": b64()},
            }
        },
        "tokens": {},
        "segments": {"0": {"type": "crypt", "offset": "16777216", "size": "dynamic", "iv_tweak": "0",
                           "encryption": "aes-xts-plain64", "sector_size": 512}},
        "digests": {"0": {"type": "pbkdf2", "keyslots": ["0"], "segments": ["0"], "hash": "sha256",
                          "iterations": 180224, "salt": b64(), "digest": b64()}},
        "config": {"json_size": "12288", "keyslots_size": "16744448"},
    },
    separators=(",", ":"),
).encode()


def listing():
    """xxd -a over the header area: the first all-zero line prints, the rest of its run is '*'."""
    disk = bytearray(SLOT + SLOT_LINES * N)
    luks_header(disk, 0, b"LUKS\xba\xbe", 0, rng)
    disk[0x1000 : 0x1000 + len(METADATA)] = METADATA
    luks_header(disk, 0x4000, b"SKUL\xba\xbe", 0x4000, rng)
    disk[0x5000 : 0x5000 + len(METADATA)] = METADATA
    disk[SLOT:] = rng.randbytes(len(disk) - SLOT)
    lines, zeros = [], 0
    for a in range(0, len(disk), N):
        chunk = bytes(disk[a : a + N])
        zeros = zeros + 1 if not any(chunk) else 0
        if zeros == 2:
            lines.append((a, None))
        elif zeros < 2:
            lines.append((a, chunk))
    return lines


def superblock(size):
    """The head of a btrfs superblock for a filesystem of `size` bytes."""
    sb = bytearray(0x100)
    sb[0:4] = rng.randbytes(4)  # crc32c; the rest of the 32-byte csum stays zero
    sb[0x20:0x30] = rng.randbytes(16)  # fsid
    struct.pack_into("<QQ", sb, 0x30, 0x10000, 1)  # bytenr, flags (WRITTEN)
    sb[0x40:0x48] = b"_BHRfS_M"
    struct.pack_into("<QQQ", sb, 0x48, 0x2B3F1, 0x1D4C8E4000, 0x1504000)  # generation, root, chunk_root
    struct.pack_into("<QQQQ", sb, 0x70, size, size * 31 // 100, 6, 1)  # bytes, used, root dir, devices
    struct.pack_into("<IIIIIQ", sb, 0x90, 4096, 16384, 16384, 4096, 0x81, 0x2B3E0)
    struct.pack_into("<QQ", sb, 0xB4, 3, 0x371)  # compat_ro (free space tree), incompat
    struct.pack_into("<Q", sb, 0xC9, 1)  # dev_item.devid
    return bytes(sb)


def lit_at(d):
    """walldye's selection glow: 1, 0.6, 0.25 over the rows nearest the focus."""
    if d < 1:
        return 1 - 0.4 * d
    if d < 2:
        return 0.6 - 0.35 * (d - 1)
    if d < 3:
        return 0.25 - 0.25 * (d - 2)
    return 0


def smooth(e0, e1, x):
    t = min(1, max(0, (x - e0) / (e1 - e0)))
    return t * t * (3 - 2 * t)


def main():
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    p = Painter(load_bdf(sys.argv[2]))
    bg, bg_alt, ui, ui_alt = (colour(n) for n in ("bg", "bgAlt", "ui", "uiAlt"))
    muted, fg_alt, fg = (colour(n) for n in ("muted", "fgAlt", "fg"))
    accent, band, acc_hi = (colour(n) for n in ("accent", "band", "accentHi"))
    off = mix(bg_alt, ui, 0.6)

    def tone(lit):
        return mix(ui_alt, muted, lit * 0.8), mix(ui_alt, fg_alt, lit * 0.7)

    lines = listing()
    key = next(i for i, (a, _) in enumerate(lines) if a == SLOT)
    for i, (a, data) in enumerate(lines):
        row(p, a, data, off, *tone(0)).save(out / f"l-{i}-d.png")
        row(p, a, data, off, *tone(1)).save(out / f"l-{i}-l.png")
        if i < key and data:  # what the boot cursor has read
            row(p, a, data, off, mix(muted, fg_alt, 0.5), fg_alt).save(out / f"l-{i}-r.png")
    for j in range(KEY_LINES):
        data = lines[key + j][1]
        for name, ink in (("s", accent), ("h", acc_hi), ("f", mix(accent, fg, 0.6)), ("m", muted)):
            row(p, None, data, None, ink, ink, band).save(out / f"k-{j}-{name}.png")
    row(p, None, lines[0][1], None, accent, accent, band).save(out / "luks.png")

    total = round(275.6 * 2**30 / 4096) * 4096 - 16 * 2**20
    plain = bytes(SB - SEG_BASE) + superblock(total)
    plain = plain[: SEG_ROWS * N]
    cipher = rng.randbytes(len(plain))
    for r in range(SEG_ROWS):
        t = tone(lit_at(abs(r - MAGIC_ROW)))
        a = SEG_BASE + r * N
        row(p, a, cipher[r * N : (r + 1) * N], off, *t).save(out / f"c-{r}.png")
        row(p, a, plain[r * N : (r + 1) * N], off, *t).save(out / f"p-{r}.png")
    magic = plain[MAGIC_ROW * N : (MAGIC_ROW + 1) * N]
    row(p, None, magic, None, accent, accent, band).save(out / "magic.png")
    for v in range(FRONT):
        row(p, None, rng.randbytes(N), None, accent, accent).save(out / f"f-{v}.png")
    for v in range(NOISE):
        row(p, None, rng.randbytes(N), None, *tone(0)).save(out / f"n-{v}.png")
    # The seek's offset column, one image per step, with each row's edge fade baked in.
    for s in range(SEEK_STEPS):
        e = smooth(0, 1, s / (SEEK_STEPS - 1))
        base = round((SLOT + (SEG_BASE - SLOT) * e) / N) * N
        col = Image.new("RGBA", (9 * CW, SEG_ROWS * CH), (0, 0, 0, 0))
        for r in range(SEG_ROWS):
            edge = 1 - abs(r - MAGIC_ROW) / (MAGIC_ROW + 1)
            fade = 0.12 + 0.88 * smooth(0.03, 0.95, edge)
            line = Image.new("RGBA", (9 * CW, CH), (0, 0, 0, 0))
            p.text(line, 0, f"{base + r * N:08x}:", mix(bg, off, fade))
            col.alpha_composite(line, (0, r * CH))
        col.save(out / f"o-{s}.png")

    Image.new("RGBA", (2 * CW, CH), acc_hi + (255,)).save(out / "cur-h.png")
    Image.new("RGBA", (CW, CH), acc_hi + (255,)).save(out / "cur-a.png")
    for code in range(32, 127):
        img = Image.new("RGBA", (CW, CH), (0, 0, 0, 0))
        p.text(img, 0, chr(code), bg)
        img.save(out / f"g-{code}.png")
    for name, text in LABELS.items():
        img = Image.new("RGBA", (len(text) * CW, CH), (0, 0, 0, 0))
        p.text(img, 0, text, muted)
        img.save(out / f"label-{name}.png")

    data = [
        f"DUMP_LINES = {len(lines)};",
        f"KEY_LINE = {key};",
        f"KEY_LINES = {KEY_LINES};",
        f"SEG_ROWS = {SEG_ROWS};",
        f"MAGIC_ROW = {MAGIC_ROW};",
        f"SEEK_STEPS = {SEEK_STEPS};",
        f"NOISE = {NOISE};",
        f"FRONT = {FRONT};",
        f'MAGIC_HEX = "{magic.hex()}";',
    ]
    for i, (_, chunk) in enumerate(lines[: key + KEY_LINES]):
        data.append(f"dump_star[{i}] = 1;" if chunk is None else f'dump_hex[{i}] = "{chunk.hex()}";')
    (out / "data.script").write_text("\n".join(data) + "\n")


main()
