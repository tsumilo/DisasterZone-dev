"""Read-only reader for the installed client's CASC storage (C:/World of Warcraft/Data, product wow_anniversary): a game
file by FileDataID, exactly as the user's client has it. The wago.tools downloads are not tied to one build, so they
mixed builds: Karazhan's WMO root had 133 materials against the client's 135, shifted from the 30th on, so its groups'
material numbers pointed at the wrong textures; Sunwell's root had 115 against 113. (The client's own groups are also
cut into more triangles than the downloads, over the same area.) From the 2026-10-05 depth research; caches its tables
under dev/art/casc, per build."""
import os, struct, zlib, pickle

BASE = r"C:\World of Warcraft"
DATA = os.path.join(BASE, "Data")
HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, "..", "art", "casc")      # (pickled encoding / root tables of the installed build)
os.makedirs(CACHE, exist_ok=True)


def build_config(product="wow_anniversary"):
    lines = open(os.path.join(BASE, ".build.info"), encoding="utf-8").read().splitlines()
    head = [h.split("!")[0] for h in lines[0].split("|")]
    for ln in lines[1:]:
        row = dict(zip(head, ln.split("|")))
        if row.get("Product") == product:
            bk = row["Build Key"]
            cfg = {}
            for l in open(os.path.join(DATA, "config", bk[:2], bk[2:4], bk), encoding="utf-8"):
                if "=" in l:
                    k, v = l.split("=", 1)
                    cfg[k.strip()] = v.split()
            return cfg
    raise SystemExit("no product")


def build_name(product="wow_anniversary"):
    """The installed build, e.g. 2.5.6.69795 (the caches are per build: a patch changes every table)."""
    lines = open(os.path.join(BASE, ".build.info"), encoding="utf-8").read().splitlines()
    head = [h.split("!")[0] for h in lines[0].split("|")]
    for ln in lines[1:]:
        row = dict(zip(head, ln.split("|")))
        if row.get("Product") == product:
            return row.get("Version", "unknown")
    return "unknown"


_IDX = None


def load_indices():
    global _IDX
    if _IDX is not None:
        return _IDX
    best = {}
    for f in os.listdir(os.path.join(DATA, "data")):
        if f.endswith(".idx"):
            b, v = int(f[:2], 16), int(f[2:10], 16)
            if b not in best or v > best[b][0]:
                best[b] = (v, f)
    idx = {}
    for b, (v, f) in best.items():
        d = open(os.path.join(DATA, "data", f), "rb").read()
        hsize = struct.unpack_from("<I", d, 0)[0]
        pos = 8 + hsize
        pos = (pos + 15) & ~15
        esize = struct.unpack_from("<I", d, pos)[0]
        pos += 8
        for i in range(esize // 18):
            o = pos + i * 18
            key = d[o:o + 9]
            hi = d[o + 9]
            lo = struct.unpack_from(">I", d, o + 10)[0]
            size = struct.unpack_from("<I", d, o + 14)[0]
            arch = (hi << 2) | (lo >> 30)
            off = lo & 0x3FFFFFFF
            if key not in idx:
                idx[key] = (arch, off, size)
    _IDX = idx
    return idx


def blte(data):
    assert data[:4] == b"BLTE", data[:4]
    hs = struct.unpack_from(">I", data, 4)[0]
    out = []
    if hs == 0:
        chunks = [(len(data) - 8, None)]
        pos = 8
    else:
        n = struct.unpack_from(">I", data, 8)[0] & 0xFFFFFF
        chunks = []
        for i in range(n):
            cs, ds = struct.unpack_from(">II", data, 12 + i * 24)
            chunks.append((cs, ds))
        pos = hs
    for cs, ds in chunks:
        c = data[pos:pos + cs]
        pos += cs
        m = c[:1]
        if m == b"N":
            out.append(c[1:])
        elif m == b"Z":
            out.append(zlib.decompress(c[1:]))
        elif m == b"F":
            out.append(blte(c[1:]))
        elif m == b"E":
            raise ValueError("encrypted chunk")
        else:
            raise ValueError("chunk mode %r" % m)
    return b"".join(out)


def read_ekey(ekey_hex_or_bytes):
    ek = bytes.fromhex(ekey_hex_or_bytes) if isinstance(ekey_hex_or_bytes, str) else ekey_hex_or_bytes
    idx = load_indices()
    ent = idx.get(ek[:9])
    if not ent:
        raise KeyError("ekey not local: " + ek.hex())
    arch, off, size = ent
    with open(os.path.join(DATA, "data", "data.%03d" % arch), "rb") as fh:
        fh.seek(off)
        raw = fh.read(size)
    return blte(raw[30:])


_ENC = None
_ROOT = None


def _save(obj, path):
    """Pickles a table whole or not at all (parallel generator jobs may build the same one at once)."""
    part = "%s.part%d" % (path, os.getpid())
    with open(part, "wb") as fh:
        pickle.dump(obj, fh)
    try:
        os.replace(part, path)
    except OSError:                              # (another job's copy is in place and open: the same table)
        os.remove(part)


def encoding():
    global _ENC
    if _ENC is not None:
        return _ENC
    cache = os.path.join(CACHE, "enc_%s.pickle" % build_name())
    if os.path.exists(cache):
        _ENC = pickle.load(open(cache, "rb"))
        return _ENC
    cfg = build_config()
    d = read_ekey(cfg["encoding"][1])
    assert d[:2] == b"EN"
    ckl, ekl = d[3], d[4]
    cps, eps = struct.unpack_from(">HH", d, 5)
    cpc, epc = struct.unpack_from(">II", d, 9)
    espec = struct.unpack_from(">I", d, 18)[0]
    pos = 22 + espec + cpc * 32
    m = {}
    for p in range(cpc):
        page = d[pos:pos + cps * 1024]
        pos += cps * 1024
        o = 0
        while o + 6 + ckl <= len(page):
            kc = page[o]
            if kc == 0:
                break
            ck = page[o + 6:o + 6 + ckl]
            ek = page[o + 6 + ckl:o + 6 + ckl + ekl]
            m[ck] = ek
            o += 6 + ckl + ekl * kc
    _ENC = m
    _save(m, cache)
    return m


_NAMES = None


def root():
    """FileDataID -> content key, every file of the installed build."""
    global _ROOT
    if _ROOT is not None:
        return _ROOT
    cache = os.path.join(CACHE, "root_%s.pickle" % build_name())
    if os.path.exists(cache):
        _ROOT = pickle.load(open(cache, "rb"))
        return _ROOT
    _ROOT = _read_root()[0]
    return _ROOT


def names():
    """Name hash (name_hash) -> FileDataID: the root lists every file's path hashed (all 289,547 entries of
    2.5.6.69795 have one), so a path finds its ID offline."""
    global _NAMES
    if _NAMES is not None:
        return _NAMES
    cache = os.path.join(CACHE, "names_%s.pickle" % build_name())
    if os.path.exists(cache):
        _NAMES = pickle.load(open(cache, "rb"))
        return _NAMES
    _NAMES = _read_root()[1]
    return _NAMES


def _read_root():
    """The root table, parsed once per build into both caches: (FileDataID -> content key, name hash -> ID)."""
    cfg = build_config()
    enc = encoding()
    d = read_ekey(enc[bytes.fromhex(cfg["root"][0])])
    pos, version, named_total = 0, 0, 1
    if d[:4] == b"TSFM":
        a, b = struct.unpack_from("<II", d, 4)
        if a == 0x18:
            version = b
            total, named = struct.unpack_from("<II", d, 12)
            pos = a
        else:
            total, named = a, b
            pos = 12
        named_total = named
    out, hashes = {}, {}
    while pos < len(d):
        n = struct.unpack_from("<I", d, pos)[0]
        if version >= 2:
            loc, u1, u2, u3 = struct.unpack_from("<IIIB", d, pos + 4)
            cflags = u1 | u2 | (u3 << 17)
            pos += 17
        else:
            cflags, loc = struct.unpack_from("<II", d, pos + 4)
            pos += 12
        deltas = struct.unpack_from("<%di" % n, d, pos)
        pos += 4 * n
        fid = -1
        fids = []
        for dl in deltas:
            fid = fid + 1 + dl
            fids.append(fid)
        ck = [d[pos + i * 16:pos + i * 16 + 16] for i in range(n)]
        pos += 16 * n
        if named_total and not (cflags & 0x10000000):      # (0x10000000: a block without name hashes)
            for f, h in zip(fids, struct.unpack_from("<%dQ" % n, d, pos)):
                hashes.setdefault(h, f)
            pos += 8 * n
        for f, c in zip(fids, ck):                         # (every locale's block; enUS (0x2) wins a file it shares)
            if f not in out or (loc & 0x2):
                out[f] = c
    _save(out, os.path.join(CACHE, "root_%s.pickle" % build_name()))
    _save(hashes, os.path.join(CACHE, "names_%s.pickle" % build_name()))
    return out, hashes


def _rot32(x, k):
    return ((x << k) | (x >> (32 - k))) & 0xFFFFFFFF


def _hashlittle2(data):
    """Bob Jenkins' lookup3 hashlittle2 (seeds 0): -> (c, b), the two 32-bit halves CASC keeps of a path."""
    M = 0xFFFFFFFF
    n = len(data)
    a = b = c = (0xDEADBEEF + n) & M
    i = 0
    while n > 12:
        a = (a + struct.unpack_from("<I", data, i)[0]) & M
        b = (b + struct.unpack_from("<I", data, i + 4)[0]) & M
        c = (c + struct.unpack_from("<I", data, i + 8)[0]) & M
        a = ((a - c) & M) ^ _rot32(c, 4)         # (lookup3's mix)
        c = (c + b) & M
        b = ((b - a) & M) ^ _rot32(a, 6)
        a = (a + c) & M
        c = ((c - b) & M) ^ _rot32(b, 8)
        b = (b + a) & M
        a = ((a - c) & M) ^ _rot32(c, 16)
        c = (c + b) & M
        b = ((b - a) & M) ^ _rot32(a, 19)
        a = (a + c) & M
        c = ((c - b) & M) ^ _rot32(b, 4)
        b = (b + a) & M
        n -= 12
        i += 12
    if n == 0:
        return c, b
    t = data[i:] + b"\0" * (12 - n)              # (the last 1..12 bytes; zeros add nothing, as the C switch)
    a = (a + struct.unpack_from("<I", t, 0)[0]) & M
    b = (b + struct.unpack_from("<I", t, 4)[0]) & M
    c = (c + struct.unpack_from("<I", t, 8)[0]) & M
    c = ((c ^ b) - _rot32(b, 14)) & M            # (lookup3's final)
    a = ((a ^ c) - _rot32(c, 11)) & M
    b = ((b ^ a) - _rot32(a, 25)) & M
    c = ((c ^ b) - _rot32(b, 16)) & M
    a = ((a ^ c) - _rot32(c, 4)) & M
    b = ((b ^ a) - _rot32(a, 14)) & M
    c = ((c ^ b) - _rot32(b, 24)) & M
    return c, b


def name_hash(path):
    """A path's hash as the root stores it: lookup3 over the path in capitals with backslashes, c << 32 | b."""
    c, b = _hashlittle2(path.upper().replace("/", "\\").encode("ascii"))
    return (c << 32) | b


def fdid_of(path):
    """A file's ID by its path in the installed build, or None (not in this build). Checked against the 134 paths
    gen_rooms.py had looked up on wago.tools: all the same IDs; only the 20 HD character models (not in 2.5.6) miss."""
    return names().get(name_hash(path))


def read_fid(fid):
    """A file's bytes by its ID. KeyError: not in this build or not on this disk; ValueError: encrypted."""
    ck = root()[fid]
    return read_ekey(encoding()[ck])


if __name__ == "__main__":
    import sys
    for a in sys.argv[1:]:
        b = read_fid(int(a))
        print(a, len(b), b[:4])
