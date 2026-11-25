# Writes small synthetic DICOM files covering the cases FDRepair must handle. Plain Python 3.
import struct, os, sys
out = sys.argv[1] if len(sys.argv) > 1 else "samples"
os.makedirs(out, exist_ok=True)
U = 0xFFFFFFFF
LONG = {b"OB",b"OD",b"OF",b"OL",b"OV",b"OW",b"SQ",b"UC",b"UN",b"UR",b"UT",b"SV",b"UV"}

def el(g, e, vr, val, implicit=False, big=False, length=None):
    o = ">" if big else "<"
    n = len(val) if length is None else length
    if implicit: return struct.pack(o+"HHI", g, e, n) + val
    if vr in LONG: return struct.pack(o+"HH", g, e) + vr + b"\0\0" + struct.pack(o+"I", n) + val
    return struct.pack(o+"HH", g, e) + vr + struct.pack(o+"H", n) + val

def dl(e, big=False):  # FFFE delimiters / item headers
    return struct.pack((">" if big else "<")+"HHI", 0xFFFE, e, 0)
def item(val, big=False, undefined=False):
    o = ">" if big else "<"
    return struct.pack(o+"HHI", 0xFFFE, 0xE000, U if undefined else len(val)) + val

def meta(ts):
    t = ts.encode(); t += b"\0" * (len(t) % 2)
    body = el(2, 1, b"OB", b"\0\1") + el(2, 0x10, b"UI", t)
    return b"\0"*128 + b"DICM" + el(2, 0, b"UL", struct.pack("<I", len(body))) + body

def ds(implicit=False, big=False, close_item=True, close_seq=True, pixel=False, close_pixel=True):
    k = dict(implicit=implicit, big=big)
    s = el(0x0008, 0x0060, b"CS", b"MR", **k) + el(0x0010, 0x0010, b"PN", b"TEST^ONE", **k)
    inner = el(0x0008, 0x0100, b"SH", b"CODE01", **k)
    s += el(0x0008, 0x1140, b"SQ", b"", length=U, **k)
    s += item(inner, big=big)                       # defined-length item
    s += item(inner, big=big, undefined=True)       # undefined-length item
    if close_item: s += dl(0xE00D, big)
    if close_seq: s += dl(0xE0DD, big)
    if pixel:
        s += el(0x7FE0, 0x0010, b"OB", b"", length=U, **k) + item(b"", big=big) + item(b"\xff\xd8\xff\xd9", big=big)
        if close_pixel: s += dl(0xE0DD, big)
    return s

E, I, B = "1.2.840.10008.1.2.1", "1.2.840.10008.1.2", "1.2.840.10008.1.2.2"
files = {
  "ok_explicit.dcm": meta(E)+ds(),
  "ok_implicit.dcm": meta(I)+ds(implicit=True),
  "ok_big.dcm": meta(B)+ds(big=True),
  "fix_seq_explicit.dcm": meta(E)+ds(close_seq=False),
  "fix_seq_implicit.dcm": meta(I)+ds(implicit=True, close_seq=False),
  "fix_seq_big.dcm": meta(B)+ds(big=True, close_seq=False),
  "fix_item_seq.dcm": meta(E)+ds(close_item=False, close_seq=False),
  "fix_pixel.dcm": meta("1.2.840.10008.1.2.4.50")+ds(pixel=True, close_pixel=False),
  "ok_pixel.dcm": meta("1.2.840.10008.1.2.4.50")+ds(pixel=True),
  "fix_un.dcm": meta(E)+el(8,0x60,b"CS",b"MR")+el(0x0029,0x1010,b"UN",b"",length=U)+item(el(8,0x100,b"SH",b"AB",implicit=True),undefined=True)+dl(0xE00D),
  "truncated.dcm": (meta(E)+ds())[:-3],
  "noprefix_ok.dcm": ds(implicit=True),
  "noprefix_fix.dcm": ds(implicit=True, close_seq=False),
  "notdicom.txt": b"hello world, this is not a DICOM file at all\n",
  "deflated.dcm": meta("1.2.840.10008.1.2.1.99")+b"\x01\x02",
}
for name, data in files.items():
    open(os.path.join(out, name), "wb").write(data)
print(len(files), "files in", out)
