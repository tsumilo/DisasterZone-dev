"""DisasterZone in-game update ("hot patch") primitives shared by release.py and the tests.

Everything here has a Lua twin in the addon (Core/Sha256.lua, Core/Patch.lua, Core/Boot.lua); the test suite
tests/patch/ checks the two against each other.

Signature scheme: W-OTS (w = 16, SHA-256, 67 chains) under a Merkle tree of 2^h one-time keys. Only hashing is
needed to verify, so the addon needs no big-number code. A leaf (= manifest seq) must sign one manifest only.

    F(seed, leaf, chain, step, x) = SHA256(seed16 || "C" || u32(leaf) || u8(chain) || u8(step) || x32)   (55 bytes)
    leaf node                     = SHA256(seed16 || "L" || u32(leaf) || pk_0 .. pk_66)
    inner node                    = SHA256(seed16 || "N" || u8(height) || u32(index) || left || right)
    message digest                = SHA256(seed16 || "M" || u32(leaf) || message)
"""
import hashlib
import json
import os
import struct
import zlib

W = 16
LEN1 = 64
LEN2 = 3
LEN = LEN1 + LEN2
N = 32
SEED_LEN = 16

MANIFEST_MAGIC = "CDLP1"
CHUNK = 236            # encoded bytes per chunk message (Core/Patch.lua CHUNK)

# Caps enforced by the addon before it downloads anything (Core/Patch.lua). The builder refuses to exceed them.
MAX_FILES = 300
MAX_FILE_LEN = 1024 * 1024
MAX_TOTAL_LEN = 4 * 1024 * 1024
MAX_TOTAL_ZLEN = 1536 * 1024
MAX_MANIFEST_LEN = 48 * 1024


def sha256(b):
    return hashlib.sha256(b).digest()


def adler32(b):
    return zlib.adler32(b) & 0xFFFFFFFF


def deflate_raw(b):
    c = zlib.compressobj(9, zlib.DEFLATED, -15)
    return c.compress(b) + c.flush()


def inflate_raw(b):
    return zlib.decompress(b, -15)


_ALPHABET = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789()"
_DECODE = {c: i for i, c in enumerate(_ALPHABET)}


def encode_for_print(b):
    """Byte-identical to LibDeflate:EncodeForPrint (little-endian 6-bit groups, no padding)."""
    out = []
    n = len(b)
    i = 0
    while i + 2 < n:
        cache = b[i] | (b[i + 1] << 8) | (b[i + 2] << 16)
        out.append(_ALPHABET[cache & 63] + _ALPHABET[(cache >> 6) & 63]
                   + _ALPHABET[(cache >> 12) & 63] + _ALPHABET[(cache >> 18) & 63])
        i += 3
    cache = 0
    bits = 0
    while i < n:
        cache |= b[i] << bits
        bits += 8
        i += 1
    while bits > 0:
        out.append(_ALPHABET[cache & 63])
        cache >>= 6
        bits -= 6
    return "".join(out)


def decode_for_print(s):
    out = bytearray()
    n = len(s)
    i = 0
    while i + 3 < n:
        cache = _DECODE[s[i]] | (_DECODE[s[i + 1]] << 6) | (_DECODE[s[i + 2]] << 12) | (_DECODE[s[i + 3]] << 18)
        out += bytes((cache & 255, (cache >> 8) & 255, (cache >> 16) & 255))
        i += 4
    cache = 0
    bits = 0
    while i < n:
        cache |= _DECODE[s[i]] << bits
        bits += 6
        i += 1
    while bits >= 8:
        out.append(cache & 255)
        cache >>= 8
        bits -= 8
    return bytes(out)


# ---------------------------------------------------------------------------------------------------------------
# W-OTS + Merkle
# ---------------------------------------------------------------------------------------------------------------

def _f(seed, leaf, chain, step, x):
    return sha256(seed + b"C" + struct.pack(">IBB", leaf, chain, step) + x)


def _chain(seed, leaf, chain, x, start, steps):
    for s in range(start, start + steps):
        x = _f(seed, leaf, chain, s, x)
    return x


def _sk(secret, leaf, chain):
    return sha256(secret + b"S" + struct.pack(">IB", leaf, chain))


def _leaf_node(seed, leaf, pks):
    return sha256(seed + b"L" + struct.pack(">I", leaf) + b"".join(pks))


def _inner(seed, height, index, left, right):
    return sha256(seed + b"N" + struct.pack(">BI", height, index) + left + right)


def _digits(seed, leaf, message):
    d = sha256(seed + b"M" + struct.pack(">I", leaf) + message)
    digits = []
    for byte in d:
        digits.append(byte >> 4)
        digits.append(byte & 15)
    csum = sum(W - 1 - x for x in digits)
    digits += [(csum >> 8) & 15, (csum >> 4) & 15, csum & 15]
    return digits


def _leaf_pk(secret, seed, leaf):
    return _leaf_node(seed, leaf, [_chain(seed, leaf, c, _sk(secret, leaf, c), 0, W - 1) for c in range(LEN)])


def keygen(height=10, secret=None, seed=None):
    """Returns a key dict (JSON-serialisable). 2^height signatures."""
    secret = secret or os.urandom(32)
    seed = seed or os.urandom(SEED_LEN)
    leaves = [_leaf_pk(secret, seed, i) for i in range(1 << height)]
    key = {"secret": secret.hex(), "seed": seed.hex(), "height": height,
           "leaves": [x.hex() for x in leaves], "next": 1}
    key["root"] = _tree(seed, leaves)[-1][0].hex()
    return key


def _tree(seed, leaves):
    levels = [leaves]
    h = 0
    while len(levels[-1]) > 1:
        h += 1
        prev = levels[-1]
        levels.append([_inner(seed, h, i, prev[2 * i], prev[2 * i + 1]) for i in range(len(prev) // 2)])
    return levels


def sign(key, leaf, message):
    """Signature bytes: u32(leaf) || 67 chain values || `height` auth-path nodes."""
    height = key["height"]
    if not 0 <= leaf < (1 << height):
        raise ValueError("leaf %d outside the key (2^%d signatures)" % (leaf, height))
    secret = bytes.fromhex(key["secret"])
    seed = bytes.fromhex(key["seed"])
    digits = _digits(seed, leaf, message)
    parts = [struct.pack(">I", leaf)]
    for c, d in enumerate(digits):
        parts.append(_chain(seed, leaf, c, _sk(secret, leaf, c), 0, d))
    levels = _tree(seed, [bytes.fromhex(x) for x in key["leaves"]])
    idx = leaf
    for h in range(height):
        parts.append(levels[h][idx ^ 1])
        idx >>= 1
    return b"".join(parts)


def sig_len(height):
    return 4 + (LEN + height) * N


def verify(seed_hex, root_hex, height, message, sig):
    seed = bytes.fromhex(seed_hex)
    if len(sig) != sig_len(height):
        return False
    leaf = struct.unpack(">I", sig[:4])[0]
    if leaf >= (1 << height):
        return False
    digits = _digits(seed, leaf, message)
    pks = []
    for c, d in enumerate(digits):
        x = sig[4 + c * N: 4 + (c + 1) * N]
        pks.append(_chain(seed, leaf, c, x, d, W - 1 - d))
    node = _leaf_node(seed, leaf, pks)
    idx = leaf
    off = 4 + LEN * N
    for h in range(height):
        sib = sig[off + h * N: off + (h + 1) * N]
        node = _inner(seed, h + 1, idx >> 1, sib, node) if idx & 1 else _inner(seed, h + 1, idx >> 1, node, sib)
        idx >>= 1
    return node.hex() == root_hex


# ---------------------------------------------------------------------------------------------------------------
# Patch bundle
# ---------------------------------------------------------------------------------------------------------------

def normalize_source(b):
    """The text that travels and runs: CRLF -> LF (line numbers unchanged), no BOM. NUL bytes and invalid UTF-8
    are refused (SavedVariables must round-trip the text byte for byte)."""
    if b.startswith(b"\xef\xbb\xbf"):
        b = b[3:]
    b = b.replace(b"\r\n", b"\n")
    if b"\r" in b:
        raise ValueError("bare CR in source")
    if b"\x00" in b:
        raise ValueError("NUL byte in source")
    b.decode("utf-8")
    return b


def build_bundle(seq, version, base, pack, entries, key):
    """entries: ordered list of dicts {kind: 'F'|'N'|'D', path, src (bytes, F/N), before (N; '' = end)}.
    Returns the bundle dict the addon consumes (Outbox / tests):
      {seq, version, base, pack, manifest (str), sig (bytes), z0 (str), items: [{kind, path, before, src, z}]}"""
    if len(entries) > MAX_FILES:
        raise ValueError("too many files (%d > %d)" % (len(entries), MAX_FILES))
    lines = [MANIFEST_MAGIC, "seq=%d" % seq, "version=%s" % version, "base=%s" % base, "pack=%d" % pack]
    items = []
    total = ztotal = 0
    for e in entries:
        kind, path = e["kind"], e["path"]
        if "\t" in path or "\n" in path or "\\" in path:
            raise ValueError("bad path %r" % path)
        if kind == "D":
            lines.append("D\t%s" % path)
            items.append({"kind": "D", "path": path})
            continue
        src = normalize_source(e["src"])
        if len(src) > MAX_FILE_LEN:
            raise ValueError("%s is too large (%d bytes)" % (path, len(src)))
        z = encode_for_print(deflate_raw(src))
        total += len(src)
        ztotal += len(z)
        fields = [kind, path, str(len(src)), str(adler32(src)), str(len(z)), sha256(z.encode("ascii")).hex()]
        if kind == "N":
            fields.append(e.get("before") or "")
        elif kind != "F":
            raise ValueError("bad kind %r" % kind)
        lines.append("\t".join(fields))
        items.append({"kind": kind, "path": path, "before": e.get("before") or "", "src": src, "z": z})
    if total > MAX_TOTAL_LEN or ztotal > MAX_TOTAL_ZLEN:
        raise ValueError("patch too large (%d bytes, %d encoded); ship a full release" % (total, ztotal))
    manifest = "\n".join(lines) + "\n"
    if len(manifest) > MAX_MANIFEST_LEN:
        raise ValueError("manifest too large")
    sig = sign(key, seq, manifest.encode("utf-8"))
    z0 = encode_for_print(sig + manifest.encode("utf-8"))
    return {"seq": seq, "version": version, "base": base, "pack": pack, "manifest": manifest, "sig": sig,
            "z0": z0, "items": items, "total": total, "ztotal": ztotal}


def lua_long_string(b):
    """A Lua long-bracket literal for bytes/str that contains no CR (level chosen so it cannot close early)."""
    s = b.decode("utf-8") if isinstance(b, bytes) else b
    level = 0
    while ("]" + "=" * level + "]") in s or s.endswith("]" + "=" * level):
        level += 1
    eq = "=" * level
    # a leading newline right after the opening bracket is skipped by Lua, so always emit one
    return "[" + eq + "[\n" + s + "]" + eq + "]"


def lua_quoted(s):
    out = ['"']
    for ch in s:
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\t":
            out.append("\\t")
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def outbox_lua(bundle):
    """Core/Outbox.lua for the publisher's client: the encoded blobs only (the addon derives everything else
    from them through the same verification path a downloaded patch takes)."""
    parts = ["-- DisasterZone: generated by dev/tools/release.py. The in-game update waiting to be published with",
             "-- /dz publish (seq %d, version %s, base %s). Not part of a release." % (
                 bundle["seq"], bundle["version"], bundle["base"]),
             "DisasterZoneOutbox = {",
             "    seq = %d," % bundle["seq"],
             "    z0 = %s," % lua_quoted(bundle["z0"]),
             "    z = {"]
    for it in bundle["items"]:
        if it["kind"] != "D":
            parts.append("        %s," % lua_quoted(it["z"]))
    parts += ["    },", "}", ""]
    return "\n".join(parts)


OUTBOX_STUB = ("-- DisasterZone: placeholder. On the publisher's machine dev/tools/release.py writes the in-game update\n"
               "-- that /dz publish sends here; in a release this file stays empty.\n")


def staged_sv(bundle, extra=None):
    """Lua source of a DisasterZonePatchDB holding `bundle` fully downloaded and staged (what Core/Patch.lua writes
    once a download completes). Used by the tests and by the patched-mode test run."""
    files, sums, order, z = [], [], [], []
    for it in bundle["items"]:
        if it["kind"] == "D":
            order.append('{ k = "D", p = %s }' % lua_quoted(it["path"]))
            continue
        files.append("[%s] = %s" % (lua_quoted(it["path"]), lua_quoted(it["src"].decode("utf-8"))))
        sums.append("[%s] = %d" % (lua_quoted(it["path"]), adler32(it["src"])))
        if it["kind"] == "N":
            order.append('{ k = "N", p = %s, b = %s }' % (lua_quoted(it["path"]), lua_quoted(it["before"])))
        else:
            order.append('{ k = "F", p = %s }' % lua_quoted(it["path"]))
        z.append(lua_quoted(it["z"]))
    active = ("{ seq = %d, version = %s, base = %s, pack = %d, z0 = %s, files = { %s }, sums = { %s }, "
              "list = { %s }, z = { %s } }") % (
        bundle["seq"], lua_quoted(bundle["version"]), lua_quoted(bundle["base"]), bundle["pack"],
        lua_quoted(bundle["z0"]), ", ".join(files), ", ".join(sums), ", ".join(order), ", ".join(z))
    more = ""
    if extra:
        more = ", " + extra
    return "{ seq = %d, active = %s%s }" % (bundle["seq"], active, more)


def load_key(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def save_key(path, key):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(key, fh)
    os.replace(tmp, path)
