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
        elif name == "MOMT":
            out["materials"] = []
            for i in range(size // 64):
                flags, shader, blend, tex1 = struct.unpack_from("<4I", data, off + i * 64)
                out["materials"].append({"flags": flags, "shader": shader, "blend": blend, "texture": tex1})
        elif name == "GFID":
            out["gfid"] = list(struct.unpack_from("<%dI" % (size // 4), data, off))
    for g in out["groups"]:
        o = g["name_ofs"]
        if o >= 0 and "names" in out:
            g["name"] = out["names"][o:out["names"].index(b"\0", o)].decode("ascii", "replace")
    return out


LIQUID_UNIT = 533.3333 / 128      # yd: a liquid tile (an ADT chunk's eighth)


def read_mliq(data, off, size):
    """A group's liquid (MLIQ): a grid of tiles LIQUID_UNIT apart from a corner (WMO local x, y), a height per vertex,
    per tile its flags (low 4 bits 15: no liquid there; else the legacy kind: 0 water, 1 ocean, 2 magma, 3 slime).
    -> { xverts, yverts, xtiles, ytiles, corner = (x, y, z), heights = [per vertex, row by row], tiles = [flags] }"""
    xv, yv, xt, yt = struct.unpack_from("<4i", data, off)
    corner = struct.unpack_from("<3f", data, off + 16)
    nv, nt = xv * yv, xt * yt
    if nv <= 0 or nt <= 0 or 30 + nv * 8 + nt > size:
        return None
    heights = [struct.unpack_from("<f", data, off + 30 + i * 8 + 4)[0] for i in range(nv)]
    tiles = list(data[off + 30 + nv * 8:off + 30 + nv * 8 + nt])
    return {"xverts": xv, "yverts": yv, "xtiles": xt, "ytiles": yt, "corner": corner, "heights": heights,
            "tiles": tiles}


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
        out["group_liquid"] = struct.unpack_from("<I", data, off + 52)[0]
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
            elif sub == "MOTV" and "uvs" not in out:
                v = struct.unpack_from("<%df" % (ssize // 4), data, soff)
                out["uvs"] = [v[i:i + 2] for i in range(0, len(v), 2)]
            elif sub == "MOCV" and "colors" not in out:
                out["colors"] = [struct.unpack_from("<4B", data, soff + i * 4) for i in range(ssize // 4)]   # b, g, r, a
            elif sub == "MLIQ" and ssize >= 30:
                out["liquid"] = read_mliq(data, soff, ssize)
    return out
