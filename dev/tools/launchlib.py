"""DisasterZone launcher: what release.py publishes for the desktop launcher (launcher/ in the repo root).

A published release is a folder tree (the public releases repository on GitHub, or any folder for tests):

  channels/<channel>.json       the manifest: version, build, art pack, every file of both addon folders
                                (path -> sha256, size, gzip size)
  channels/<channel>.json.sig   Ed25519 signature over the manifest's exact bytes: {"key": <key id>, "sig": <hex>}
  objects/<sha[:2]>/<sha>.gz    each file's content, gzip, named by the sha256 of the uncompressed bytes

The launcher fetches the manifest and its signature, checks the signature against the public key built into it,
compares the files with what is installed and downloads only the objects it is missing. Objects never change once
written (their name is their hash), so a new release adds only the files that changed.

The signing key is a plain Ed25519 seed (dev/keys/launcher_key.json, never committed). It is a different key from
the in-game update key (patch_key.json): that one is a hash-based one-time scheme the client can check in Lua; the
launcher can use a normal signature. Ed25519 is implemented here in pure Python (RFC 8032), so the dev kit needs no
crypto package; it signs one manifest per publish, so speed does not matter.
"""
import gzip
import hashlib
import io
import json
import os
import zipfile

FORMAT = 1
CHANNELS = ("stable", "beta")

# ---------------------------------------------------------------------------------------------------------------
# Ed25519 (RFC 8032, section 6 reference implementation)
# ---------------------------------------------------------------------------------------------------------------

_P = 2 ** 255 - 19
_L = 2 ** 252 + 27742317777372353535851937790883648493


def _inv(x):
    return pow(x, _P - 2, _P)


_D = -121665 * _inv(121666) % _P
_SQRT_M1 = pow(2, (_P - 1) // 4, _P)


def _recover_x(y, sign):
    if y >= _P:
        return None
    x2 = (y * y - 1) * _inv(_D * y * y + 1)
    if x2 == 0:
        return None if sign else 0
    x = pow(x2, (_P + 3) // 8, _P)
    if (x * x - x2) % _P != 0:
        x = x * _SQRT_M1 % _P
    if (x * x - x2) % _P != 0:
        return None
    if (x & 1) != sign:
        x = _P - x
    return x


_GY = 4 * _inv(5) % _P
_GX = _recover_x(_GY, 0)
_G = (_GX, _GY, 1, _GX * _GY % _P)


def _add(p, q):
    a = (p[1] - p[0]) * (q[1] - q[0]) % _P
    b = (p[1] + p[0]) * (q[1] + q[0]) % _P
    c = 2 * p[3] * q[3] * _D % _P
    d = 2 * p[2] * q[2] % _P
    e, f, g, h = b - a, d - c, d + c, b + a
    return (e * f % _P, g * h % _P, f * g % _P, e * h % _P)


def _mul(s, p):
    q = (0, 1, 1, 0)
    while s > 0:
        if s & 1:
            q = _add(q, p)
        p = _add(p, p)
        s >>= 1
    return q


def _equal(p, q):
    return (p[0] * q[2] - q[0] * p[2]) % _P == 0 and (p[1] * q[2] - q[1] * p[2]) % _P == 0


def _compress(p):
    zinv = _inv(p[2])
    x, y = p[0] * zinv % _P, p[1] * zinv % _P
    return int.to_bytes(y | ((x & 1) << 255), 32, "little")


def _decompress(s):
    if len(s) != 32:
        return None
    y = int.from_bytes(s, "little")
    sign = y >> 255
    y &= (1 << 255) - 1
    x = _recover_x(y, sign)
    if x is None:
        return None
    return (x, y, 1, x * y % _P)


def _expand(seed):
    h = hashlib.sha512(seed).digest()
    a = int.from_bytes(h[:32], "little")
    a &= (1 << 254) - 8
    a |= 1 << 254
    return a, h[32:]


def public_key(seed):
    return _compress(_mul(_expand(seed)[0], _G))


def sign(seed, msg):
    a, prefix = _expand(seed)
    pub = _compress(_mul(a, _G))
    r = int.from_bytes(hashlib.sha512(prefix + msg).digest(), "little") % _L
    big_r = _compress(_mul(r, _G))
    h = int.from_bytes(hashlib.sha512(big_r + pub + msg).digest(), "little") % _L
    return big_r + int.to_bytes((r + h * a) % _L, 32, "little")


def verify(pub, msg, sig):
    if len(pub) != 32 or len(sig) != 64:
        return False
    a = _decompress(pub)
    r = _decompress(sig[:32])
    if a is None or r is None:
        return False
    s = int.from_bytes(sig[32:], "little")
    if s >= _L:
        return False
    h = int.from_bytes(hashlib.sha512(sig[:32] + pub + msg).digest(), "little") % _L
    return _equal(_mul(s, _G), _add(r, _mul(h, a)))


# ---------------------------------------------------------------------------------------------------------------
# Key file
# ---------------------------------------------------------------------------------------------------------------

def key_id(pub):
    """Short name of a public key (first 8 bytes of its sha256), written next to each signature so a launcher can
    tell a manifest signed with a newer key from a forged one."""
    return hashlib.sha256(pub).hexdigest()[:16]


def keygen():
    seed = os.urandom(32)
    pub = public_key(seed)
    return {"seed": seed.hex(), "public": pub.hex(), "id": key_id(pub)}


def save_key(path, key):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(key, fh, indent=1)
    os.replace(tmp, path)


def load_key(path):
    with open(path, encoding="utf-8") as fh:
        key = json.load(fh)
    if public_key(bytes.fromhex(key["seed"])).hex() != key["public"]:
        raise ValueError("%s: the public key does not belong to the seed" % path)
    return key


# ---------------------------------------------------------------------------------------------------------------
# Manifest
# ---------------------------------------------------------------------------------------------------------------

def gz(data):
    """Deterministic gzip (no file name, mtime 0): the same file always gives the same object bytes."""
    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode="wb", compresslevel=9, mtime=0) as fh:
        fh.write(data)
    return buf.getvalue()


def object_path(sha):
    return "objects/%s/%s.gz" % (sha[:2], sha)


def read_zip_tree(zip_path, folders):
    """{folder: {path inside the folder: bytes}} for the addon folders of a release zip (anything else in the zip
    is an error: the launcher installs exactly what the manifest lists)."""
    out = {name: {} for name in folders}
    with zipfile.ZipFile(zip_path) as zf:
        for info in zf.infolist():
            if info.is_dir():
                continue
            top, _, rel = info.filename.partition("/")
            if top not in out or not rel:
                raise ValueError("%s: unexpected entry %s" % (zip_path, info.filename))
            out[top][rel] = zf.read(info)
    return {k: v for k, v in out.items() if v}


def build_manifest(tree, channel, seq, record, zip_info=None, notes=None, published=None):
    """The manifest (a dict) and {sha: gzip bytes} for every file of `tree` ({folder: {path: bytes}}).
    record: the release record from release.py full (version, build, assetPack, commit)."""
    if channel not in CHANNELS:
        raise ValueError("channel must be one of %s" % ", ".join(CHANNELS))
    objects, folders = {}, {}
    for folder in sorted(tree):
        files = {}
        for rel in sorted(tree[folder]):
            data = tree[folder][rel]
            sha = hashlib.sha256(data).hexdigest()
            if sha not in objects:
                objects[sha] = gz(data)
            files[rel] = {"sha256": sha, "size": len(data), "gz": len(objects[sha])}
        folders[folder] = files
    manifest = {
        "format": FORMAT,
        "name": "DisasterZone",
        "channel": channel,
        "seq": seq,
        "version": record["version"],
        "build": record["build"],
        "assetPack": record["assetPack"],
        "commit": record.get("commit", ""),
        "published": published or "",
        "notes": notes or {},
        "folders": folders,
    }
    if zip_info:
        manifest["zip"] = zip_info
    return manifest, objects


def manifest_bytes(manifest):
    """The exact bytes that are signed and published (sorted keys, one file per line for readable git diffs)."""
    return (json.dumps(manifest, indent=1, sort_keys=True, ensure_ascii=True) + "\n").encode("ascii")


def signature_bytes(key, data):
    sig = sign(bytes.fromhex(key["seed"]), data)
    return (json.dumps({"key": key["id"], "sig": sig.hex()}, sort_keys=True) + "\n").encode("ascii")


def check_signature(pub_hex, data, sig_bytes):
    meta = json.loads(sig_bytes.decode("ascii"))
    pub = bytes.fromhex(pub_hex)
    return meta.get("key") == key_id(pub) and verify(pub, data, bytes.fromhex(meta.get("sig", "")))


def write_tree(out_dir, manifest, objects, key):
    """Write objects (only the missing ones), the manifest and its signature under out_dir.
    Returns (objects written, bytes written for them)."""
    written, size = 0, 0
    for sha, data in sorted(objects.items()):
        path = os.path.join(out_dir, *object_path(sha).split("/"))
        if os.path.exists(path):
            continue
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "wb") as fh:
            fh.write(data)
        os.replace(tmp, path)
        written += 1
        size += len(data)
    data = manifest_bytes(manifest)
    chan = os.path.join(out_dir, "channels")
    os.makedirs(chan, exist_ok=True)
    base = os.path.join(chan, manifest["channel"] + ".json")
    for path, blob in ((base + ".tmp", data), (base + ".sig.tmp", signature_bytes(key, data))):
        with open(path, "wb") as fh:
            fh.write(blob)
    # the signature goes in first: a reader that sees the new manifest must never find the old signature
    os.replace(base + ".sig.tmp", base + ".sig")
    os.replace(base + ".tmp", base)
    return written, size


def verify_tree(out_dir, channel, pub_hex):
    """What a launcher checks, done in Python: signature, every object present and matching its hash.
    Returns a list of problems (empty = good)."""
    problems = []
    base = os.path.join(out_dir, "channels", channel + ".json")
    with open(base, "rb") as fh:
        data = fh.read()
    with open(base + ".sig", "rb") as fh:
        sig = fh.read()
    if not check_signature(pub_hex, data, sig):
        return ["%s: bad signature" % base]
    manifest = json.loads(data.decode("ascii"))
    for folder, files in manifest["folders"].items():
        for rel, f in files.items():
            path = os.path.join(out_dir, *object_path(f["sha256"]).split("/"))
            if not os.path.exists(path):
                problems.append("%s/%s: object missing" % (folder, rel))
                continue
            with open(path, "rb") as fh:
                blob = gzip.decompress(fh.read())
            if hashlib.sha256(blob).hexdigest() != f["sha256"] or len(blob) != f["size"]:
                problems.append("%s/%s: object does not match" % (folder, rel))
    return problems
