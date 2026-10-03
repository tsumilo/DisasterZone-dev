"""Read WMO root / group files (Blizzard's building geometry) far enough to get floor heights.

Used by gen_trainer_heights.py. Chunk names are stored reversed in the file ('MOHD' is b'DHOM').
"""
import struct


def chunks(data, start=0, end=None):
    pos, end = start, len(data) if end is None else end
    while pos + 8 <= end:
        name = data[pos:pos + 4][::-1].decode("ascii", "replace")
        size = struct.unpack_from("<I", data, pos + 4)[0]
        yield name, pos + 8, size
        pos += 8 + size


def read_root(path):
    data = open(path, "rb").read()
    out = {"groups": [], "gfid": []}
    for name, off, size in chunks(data):
        if name == "MOHD":
            (n_tex, n_groups, n_portals, n_lights, n_models, n_doodads, n_sets, amb, wmo_id) = struct.unpack_from("<9I", data, off)
            out["n_groups"], out["wmo_id"] = n_groups, wmo_id
            out["bbox"] = struct.unpack_from("<6f", data, off + 36)
        elif name == "MOGN":
            out["names"] = data[off:off + size]
        elif name == "MOGI":
            for i in range(size // 32):
                flags, x0, y0, z0, x1, y1, z1, name_ofs = struct.unpack_from("<I6fi", data, off + i * 32)
                out["groups"].append({"index": i, "flags": flags, "bbox": (x0, y0, z0, x1, y1, z1), "name_ofs": name_ofs})
        elif name == "GFID":
            out["gfid"] = list(struct.unpack_from("<%dI" % (size // 4), data, off))
    for g in out["groups"]:
        o = g["name_ofs"]
        if o >= 0 and "names" in out:
            g["name"] = out["names"][o:out["names"].index(b"\0", o)].decode("ascii", "replace")
    return out


def read_group(path):
    """-> { verts: [(x, y, z)], tris: [(a, b, c)], flags: [per-triangle MOPY flags] }"""
    data = open(path, "rb").read()
    out = {"verts": [], "tris": [], "flags": [], "mats": []}
    for name, off, size in chunks(data):
        if name != "MOGP":
            continue
        # MOGP header is 68 bytes, then sub-chunks
        out["group_flags"] = struct.unpack_from("<I", data, off + 8)[0]
        out["bbox"] = struct.unpack_from("<6f", data, off + 12)
        for sub, soff, ssize in chunks(data, off + 68, off + size):
            if sub == "MOPY":
                for i in range(ssize // 2):
                    f, m = struct.unpack_from("<BB", data, soff + i * 2)
                    out["flags"].append(f)
                    out["mats"].append(m)
            elif sub == "MOVI":
                idx = struct.unpack_from("<%dH" % (ssize // 2), data, soff)
                out["tris"] = [idx[i:i + 3] for i in range(0, len(idx), 3)]
            elif sub == "MOVT":
                v = struct.unpack_from("<%df" % (ssize // 4), data, soff)
                out["verts"] = [v[i:i + 3] for i in range(0, len(v), 3)]
    return out
