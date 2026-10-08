"""WMO buildings / caves for the Azeromon world: root + group geometry from the installed client (casc_local) and
the transform from a MODF placement into the world grid (adt_tools: gx east, gy south, TS yards a tile).

load(fid) -> {groups: [{name, flags, verts, tris, mopy, portals...}], portals, portal_refs}
place(w, verts) -> [(gx, gy, z)] in fractional tiles / world z yards."""
import math
import struct

import adt_tools as A
import casc_local as C
import wmo_tools as WT

_CACHE = {}


def load(fid):
    if fid in _CACHE:
        return _CACHE[fid]
    d = C.read_fid(fid)
    out = {"fid": fid, "groups": [], "portals": [], "portal_refs": [], "gfid": [], "doodads": [], "sets": [],
           "doodad_names": b""}
    gnames = b""
    ginfo = []
    for name, off, size in WT.chunks(d):
        if name == "MOHD":
            v = struct.unpack_from("<9I", d, off)
            out["n_groups"], out["n_portals"] = v[1], v[2]
            out["bbox"] = struct.unpack_from("<6f", d, off + 36)
        elif name == "MOGN":
            gnames = d[off:off + size]
        elif name == "MOGI":
            for i in range(size // 32):
                fl, x0, y0, z0, x1, y1, z1, no = struct.unpack_from("<I6fi", d, off + i * 32)
                ginfo.append((fl, (x0, y0, z0, x1, y1, z1), no))
        elif name == "MOPV":
            pv = struct.unpack_from("<%df" % (size // 4), d, off)
            out["portal_verts"] = [pv[i:i + 3] for i in range(0, len(pv), 3)]
        elif name == "MOPT":
            for i in range(size // 20):
                start, count = struct.unpack_from("<2H", d, off + i * 20)
                plane = struct.unpack_from("<4f", d, off + i * 20 + 4)
                out["portals"].append((start, count, plane))
        elif name == "MOPR":
            for i in range(size // 8):
                pi, gi, side = struct.unpack_from("<2Hh", d, off + i * 8)
                out["portal_refs"].append((pi, gi, side))
        elif name == "GFID":
            out["gfid"] = list(struct.unpack_from("<%dI" % (size // 4), d, off))
        elif name == "MODS":
            for i in range(size // 32):
                nm = d[off + i * 32:off + i * 32 + 20].split(b"\0")[0].decode("ascii", "replace")
                start, count = struct.unpack_from("<2I", d, off + i * 32 + 20)
                out["sets"].append((nm, start, count))
        elif name == "MODI":
            out["doodad_fids"] = list(struct.unpack_from("<%dI" % (size // 4), d, off))
        elif name == "MODD":
            for i in range(size // 40):
                v = struct.unpack_from("<I3f4ff4B", d, off + i * 40)
                out["doodads"].append({"name": v[0] & 0xFFFFFF, "pos": v[1:4], "rot": v[4:8], "scale": v[8]})
    for i, (fl, bb, no) in enumerate(ginfo):
        nm = gnames[no:gnames.index(b"\0", no)].decode("ascii", "replace") if no >= 0 and no < len(gnames) else ""
        g = {"index": i, "flags": fl, "bbox": bb, "name": nm, "verts": [], "tris": [], "mopy": []}
        if i < len(out["gfid"]) and out["gfid"][i]:
            try:
                gd = C.read_fid(out["gfid"][i])
                for cname, coff, csize in WT.chunks(gd):
                    if cname != "MOGP":
                        continue
                    g["gflags"] = struct.unpack_from("<I", gd, coff + 8)[0]
                    g["portal_start"], g["portal_count"] = struct.unpack_from("<2H", gd, coff + 36)
                    for sub, soff, ssize in WT.chunks(gd, coff + 68, coff + csize):
                        if sub == "MOPY":
                            g["mopy"] = [struct.unpack_from("<BB", gd, soff + k * 2) for k in range(ssize // 2)]
                        elif sub == "MOVI":
                            idx = struct.unpack_from("<%dH" % (ssize // 2), gd, soff)
                            g["tris"] = [idx[k:k + 3] for k in range(0, len(idx), 3)]
                        elif sub == "MOVT":
                            v = struct.unpack_from("<%df" % (ssize // 4), gd, soff)
                            g["verts"] = [v[k:k + 3] for k in range(0, len(v), 3)]
                        elif sub == "MOTV" and "uvs" not in g:
                            v = struct.unpack_from("<%df" % (ssize // 4), gd, soff)
                            g["uvs"] = [v[k:k + 2] for k in range(0, len(v), 2)]
                        elif sub == "MODR":
                            g["doodad_refs"] = list(struct.unpack_from("<%dH" % (ssize // 2), gd, soff))
                        elif sub == "MLIQ" and ssize >= 30:
                            g["liquid"] = WT.read_mliq(gd, soff, ssize)
            except (KeyError, ValueError):
                pass
        out["groups"].append(g)
    _CACHE[fid] = out
    return out


def transform_of(pos, rot, scale=1.0):
    """A placement (MODF / MDDF position + rotation in degrees) -> function local (x, y, z) -> (gx, gy, z).
    Model space (x, y, z up) goes to placement space as (x, z, -y), turned about the vertical by rot.y - 90 degrees
    (Noggit's convention). Checked 2026-10-08: the transformed root boxes of 81 of Elwynn's 93 WMOs land on their
    MODF extents within 1 yd; the rest are tilted (rot.x / rot.z, ignored here: a few degrees) or symmetric."""
    a = math.radians(rot[1] - 90.0)
    ca, sa = math.cos(a), math.sin(a)
    px, py, pz = pos

    def f(v):
        x, y, z = v[0] * scale, v[1] * scale, v[2] * scale
        return ((px + x * ca - y * sa) / A.TS, (pz - x * sa - y * ca) / A.TS, py + z)
    return f


def transform(w):
    fid, pos, rot, ext, flags, dset, scale, uid = w
    return transform_of(pos, rot, scale)
