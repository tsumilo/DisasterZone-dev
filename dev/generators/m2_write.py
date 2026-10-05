"""Writes model files (.m2 and .skin) the TBC Anniversary client (2.5.6.69795) can load, and checks them strictly
before anything reaches the game folder: a malformed model can crash the client.

What the client's own files look like (read with casc_local from the installed build, all 14,770 models and 14,826
skins, 2026-10-05):
  * Every model is chunked: an 'MD21' chunk (at file offset 8) holding the classic MD20 block, then TXAC, LDV1, SFID,
    TXID (10,836 models; others add EXP2/PGD1). No chunk padding: each chunk header follows the previous payload.
  * The MD20 block is version 274 (37 old ones say 272). Its header is 0x130 bytes (global flag 0x8 would add 8).
    Every array starts on a 16-byte boundary counted from the MD20 start and the block's length is a multiple of 16.
  * Array order (every file): global loops, sequences, sequence lookup, bones, key bone lookup, attachments, name,
    vertices, colours, textures (+ their file names, each on 16 bytes), texture weights, texture transforms,
    replaceable texture lookup, materials, bone / texture / transparency / uv-animation lookups, collision indices,
    positions, normals, events, ... An animation track's two outer arrays follow the array that owns it; the key
    frames themselves come last, each on 16 bytes.
  * SFID holds one skin FileDataID per skin profile (num_skin_profiles), TXID one texture FileDataID per texture (0
    for the replaceable ones), TXAC two bytes per material plus per particle emitter, LDV1 16 bytes (its lod count =
    skins). Six models use a LOD layout instead: one skin profile, LDV1 saying 3 or 4 LODs and SFID listing the LOD
    skins after it (skins + lods - 1 entries); the writer never produces that and the validator refuses it.
  * 58 models have no TXID and name their textures in the MD20 block instead ('WORLD\\...\\X.BLP', NUL included):
    textures by file name still load in this client. The root file carries a name hash for every file
    ('spells/white1.blp' hashes to 167204), which is how such names resolve.
  * Skins: 'SKIN', six M2Arrays (vertex lookup, indices, bone indices (4 bytes per lookup entry), submeshes (48 bytes),
    batches (24 bytes)), boneCountMax (0 in 14,807 skins), shadow batches (12 bytes each); a 64-byte header, then the
    arrays in that order, each on 16 bytes; the file's length a multiple of 16.
  * A submesh's centre bone indexes the model's bones (the bone lookup would be too short in 656 submeshes). Every
    model's texture coordinate combo table is empty; its batches then say 0 (65,535 in 9 batches).
  * A shadow batch exists for each batch whose material is opaque or alpha-keyed (13,823 of 13,843 skins match
    exactly): flags = batch flags, flags2 = two-sided 1 | opaque 2 | (material 0x80) 4 | (material 0x400) 6, then 0,
    the submesh, the looked-up texture, the colour and the looked-up transparency.
  * Bounds: the header box is the vertices' min / max; the radius is the farthest vertex from the box's centre. Each
    sequence carries the same box and radius in a static model. A submesh's centre is its vertices' mean, its sort
    centre their box's centre, its sort radius the farthest vertex from the sort centre. Front faces wind
    counter-clockwise seen from outside (cross(b - a, c - a) points along the normals).

So the writer never invents: it patches a Blizzard model in place (vertices, bounds, materials, chunks), re-lays one
out in the order above only when it is static (no bone animation, no attachments, events, lights, cameras, ribbons or
particles), and writes skins in Blizzard's layout. relayout() and Skin.to_bytes() reproduce the client's own files
byte for byte (dev/tests/probe/test_probe_assets.py checks that; a sweep on 2026-10-05 matched 8,385 of the client's
8,439 static models and all 14,826 skins; the other 54 differ only where Blizzard shares one key frame array between
sequences or keeps an offset for zero vertices).

validate_m2() / validate_skin() are a separate, stricter reader (no parsing code shared with the writer; only the
shadow-batch formula, itself checked against the client's skins): magic, version, every offset and count in range and
16-byte aligned, no two arrays overlapping, every index in range (skin indices < vertices, submesh / batch ranges,
materials, textures, lookups, bones), bounds holding every vertex, chunk sizes, file sizes. They refuse what the
writer never produces (particles, lights, cameras, ribbons, events, attachments, external .anim sequences,
combiner-table shaders) rather than half-check it. The same sweep passed 8,400 of the 8,439 static client models
(the rest: no vertices, zero normals, an empty texture name, sequence bounds that miss vertices).
"""
import math
import struct
from collections import namedtuple

VERSION = 274
VERSIONS = (272, 274)                      # what the client's own files carry
HEADER_SIZE = 0x130
SKIN_HEADER_SIZE = 0x40
ALIGN = 16

# Every M2Array in the version 264+ header: (name, header offset, element size).
ARRAYS = (
    ("name", 0x08, 1), ("global_loops", 0x14, 4), ("sequences", 0x1C, 64), ("seq_lookup", 0x24, 2),
    ("bones", 0x2C, 88), ("key_bone_lookup", 0x34, 2), ("vertices", 0x3C, 48), ("colors", 0x48, 40),
    ("textures", 0x50, 16), ("tex_weights", 0x58, 20), ("tex_transforms", 0x60, 60), ("repl_tex_lookup", 0x68, 2),
    ("materials", 0x70, 4), ("bone_lookup", 0x78, 2), ("tex_lookup", 0x80, 2), ("tex_unit_lookup", 0x88, 2),
    ("transp_lookup", 0x90, 2), ("uvanim_lookup", 0x98, 2), ("coll_indices", 0xD8, 2), ("coll_positions", 0xE0, 12),
    ("coll_normals", 0xE8, 12), ("attachments", 0xF0, 40), ("attach_lookup", 0xF8, 2), ("events", 0x100, 36),
    ("lights", 0x108, 156), ("cameras", 0x110, 116), ("camera_lookup", 0x118, 2), ("ribbons", 0x120, 176),
    ("particles", 0x128, 492),
)
ARRAY = {name: (off, size) for name, off, size in ARRAYS}
OFF_VERSION, OFF_FLAGS, OFF_NSKIN = 0x04, 0x10, 0x44
OFF_BOX, OFF_RADIUS, OFF_CBOX, OFF_CRADIUS = 0xA0, 0xB8, 0xBC, 0xD4

# Animation tracks inside an array's elements: (offset in the element, size of one key value).
TRACKS = {
    "bones": ((16, 12), (36, 8), (56, 12)),             # translation, compressed rotation, scale
    "colors": ((0, 12), (20, 2)),                        # colour, alpha
    "tex_weights": ((0, 2),),
    "tex_transforms": ((0, 12), (20, 16), (40, 12)),    # translation, rotation, scale
}
# Static layout: the order of the client's own files, for the arrays relayout() can place.
STATIC_ORDER = ("global_loops", "sequences", "seq_lookup", "bones", "key_bone_lookup", "name", "vertices", "colors",
                "textures", "tex_weights", "tex_transforms", "repl_tex_lookup", "materials", "bone_lookup",
                "tex_lookup", "tex_unit_lookup", "transp_lookup", "uvanim_lookup", "coll_indices", "coll_positions",
                "coll_normals")
NOT_STATIC = ("attachments", "attach_lookup", "events", "lights", "cameras", "camera_lookup", "ribbons", "particles")

EMPTY_BOX = (1e7, 1e7, 1e7, -1e7, -1e7, -1e7)            # a model without collision (spells/unitcube.m2)
BLEND_NAMES = ("opaque", "alpha key", "alpha", "no alpha add", "add", "mod", "mod2x", "blend add")

Vertex = namedtuple("Vertex", "pos weights bones normal uv0 uv1")
SkinSection = namedtuple("SkinSection", "section_id level vertex_start vertex_count index_start index_count "
                                        "bone_count bone_combo bone_influences center_bone center sort_center "
                                        "sort_radius")
Batch = namedtuple("Batch", "flags priority shader_id section geoset color material layer texture_count "
                            "texture_combo coord_combo weight_combo transform_combo")
ShadowBatch = namedtuple("ShadowBatch", "flags flags2 unknown section texture color transparency")


class M2Error(Exception):
    pass


def align(n, a=ALIGN):
    return (n + a - 1) // a * a


def f32(x):
    """x as the client stores it (a 32-bit float)."""
    return struct.unpack("<f", struct.pack("<f", x))[0]


# ---------------------------------------------------------------------------------------------------------------
# Geometry helpers (shared by the writer and, independently recomputed, checked by the validator)
# ---------------------------------------------------------------------------------------------------------------

def bounds(points):
    """(min x, min y, min z, max x, max y, max z), radius: Blizzard's header box and bounding sphere radius (the
    farthest point from the box's centre)."""
    if not points:
        raise M2Error("no points")
    mn = [f32(min(p[k] for p in points)) for k in range(3)]
    mx = [f32(max(p[k] for p in points)) for k in range(3)]
    c = [(mn[k] + mx[k]) / 2.0 for k in range(3)]
    r = max(math.sqrt(sum((p[k] - c[k]) ** 2 for k in range(3))) for p in points)
    return tuple(mn + mx), f32(r)


def submesh_geometry(points):
    """centre (the mean), sort centre (the box's centre), sort radius, as a skin's submesh stores them."""
    n = float(len(points))
    mean = tuple(f32(sum(p[k] for p in points) / n) for k in range(3))
    mn = [min(p[k] for p in points) for k in range(3)]
    mx = [max(p[k] for p in points) for k in range(3)]
    sc = tuple(f32((mn[k] + mx[k]) / 2.0) for k in range(3))
    sr = max(math.sqrt(sum((p[k] - sc[k]) ** 2 for k in range(3))) for p in points)
    return mean, sc, f32(sr)


def shadow_flags2(material_flags, blend):
    return ((1 if material_flags & 0x4 else 0) | (2 if blend == 0 else 0) | (4 if material_flags & 0x80 else 0)
            | (6 if material_flags & 0x400 else 0))


# ---------------------------------------------------------------------------------------------------------------
# The writer's model
# ---------------------------------------------------------------------------------------------------------------

class M2:
    """An .m2 file as the writer edits it: its chunks in file order and the MD20 block (bytearray)."""

    def __init__(self, md, chunks=None, legacy=False):
        self.md = bytearray(md)
        self.chunks = [list(c) for c in (chunks or [])]      # [tag, payload]; MD21's payload is self.md
        self.legacy = legacy

    @classmethod
    def parse(cls, data):
        data = bytes(data)
        if data[:4] == b"MD20":
            return cls(data, [], legacy=True)
        if data[:4] != b"MD21":
            raise M2Error("not a model file (%r)" % data[:4])
        chunks, pos, md = [], 0, None
        while pos < len(data):
            if pos + 8 > len(data):
                raise M2Error("truncated chunk header at %d" % pos)
            tag = data[pos:pos + 4].decode("latin1")
            n = struct.unpack_from("<I", data, pos + 4)[0]
            if pos + 8 + n > len(data):
                raise M2Error("chunk %s runs past the end" % tag)
            payload = data[pos + 8:pos + 8 + n]
            if tag == "MD21":
                md = payload
                chunks.append(["MD21", b""])
            else:
                chunks.append([tag, payload])
            pos += 8 + n
        if md is None or md[:4] != b"MD20":
            raise M2Error("no MD20 block")
        return cls(md, chunks)

    # -- header ------------------------------------------------------------------------------------------------
    def arr(self, name):
        off, _ = ARRAY[name]
        return struct.unpack_from("<2I", self.md, off)

    def set_arr(self, name, n, off):
        struct.pack_into("<2I", self.md, ARRAY[name][0], n, off)

    @property
    def version(self):
        return struct.unpack_from("<I", self.md, OFF_VERSION)[0]

    @property
    def global_flags(self):
        return struct.unpack_from("<I", self.md, OFF_FLAGS)[0]

    @property
    def skin_count(self):
        return struct.unpack_from("<I", self.md, OFF_NSKIN)[0]

    def elements(self, name):
        n, off = self.arr(name)
        size = ARRAY[name][1]
        return [bytes(self.md[off + i * size:off + (i + 1) * size]) for i in range(n)]

    # -- chunks ------------------------------------------------------------------------------------------------
    def chunk(self, tag):
        for t, payload in self.chunks:
            if t == tag:
                return payload
        return None

    def set_chunk(self, tag, payload):
        for c in self.chunks:
            if c[0] == tag:
                c[1] = bytes(payload)
                return
        raise M2Error("the model has no %s chunk (the writer adds none)" % tag)

    def drop_chunk(self, tag):
        if tag == "MD21":
            raise M2Error("MD21 is the model")
        before = len(self.chunks)
        self.chunks = [c for c in self.chunks if c[0] != tag]
        if len(self.chunks) == before:
            raise M2Error("no %s chunk to drop" % tag)

    def file_ids(self, tag):
        payload = self.chunk(tag)
        return list(struct.unpack("<%dI" % (len(payload) // 4), payload)) if payload else []

    def set_file_id(self, tag, index, fid):
        ids = self.file_ids(tag)
        ids[index] = fid
        self.set_chunk(tag, struct.pack("<%dI" % len(ids), *ids))

    # -- vertices, materials -----------------------------------------------------------------------------------
    def vertices(self):
        out = []
        for e in self.elements("vertices"):
            pos = struct.unpack_from("<3f", e, 0)
            w = struct.unpack_from("<4B", e, 12)
            b = struct.unpack_from("<4B", e, 16)
            nrm = struct.unpack_from("<3f", e, 20)
            uv0 = struct.unpack_from("<2f", e, 32)
            uv1 = struct.unpack_from("<2f", e, 40)
            out.append(Vertex(pos, w, b, nrm, uv0, uv1))
        return out

    def set_vertices(self, verts):
        """Rewrite the vertices in place (the count cannot change here: the skin indexes them)."""
        n, off = self.arr("vertices")
        if len(verts) != n:
            raise M2Error("set_vertices: %d vertices for a model of %d (use relayout for a new count)" % (len(verts), n))
        for i, v in enumerate(verts):
            for x in tuple(v.pos) + tuple(v.normal) + tuple(v.uv0) + tuple(v.uv1):
                if not math.isfinite(x):
                    raise M2Error("vertex %d is not finite" % i)
            struct.pack_into("<3f4B4B3f2f2f", self.md, off + 48 * i, *(tuple(v.pos) + tuple(v.weights) +
                             tuple(v.bones) + tuple(v.normal) + tuple(v.uv0) + tuple(v.uv1)))

    def materials(self):
        return [struct.unpack("<HH", e) for e in self.elements("materials")]

    def set_material(self, index, flags, blend):
        n, off = self.arr("materials")
        if not 0 <= index < n:
            raise M2Error("no material %d" % index)
        if not 0 <= blend < len(BLEND_NAMES):
            raise M2Error("blend mode %d" % blend)
        struct.pack_into("<HH", self.md, off + 4 * index, flags, blend)

    # -- bounds ------------------------------------------------------------------------------------------------
    def bones_static(self):
        """True when no bone has key frames (the vertices never move, so every sequence has the header's bounds)."""
        for e in self.elements("bones"):
            for toff, _ in TRACKS["bones"]:
                if struct.unpack_from("<I", e, toff + 4)[0] or struct.unpack_from("<I", e, toff + 12)[0]:
                    return False
        return True

    def update_bounds(self):
        """Header box + radius from the vertices, and the same into every sequence (static models only)."""
        if not self.bones_static():
            raise M2Error("update_bounds: the bones are animated; sequence bounds would need the animation")
        box, r = bounds([v.pos for v in self.vertices()])
        struct.pack_into("<6f", self.md, OFF_BOX, *box)
        struct.pack_into("<f", self.md, OFF_RADIUS, r)
        n, off = self.arr("sequences")
        for i in range(n):
            struct.pack_into("<6ff", self.md, off + 64 * i + 32, *(box + (r,)))
        return box, r

    def clear_collision(self):
        """No collision mesh (as spells/unitcube.m2): the counts and offsets 0, the old data zeroed, the empty box.
        The zeroed bytes stay in the block with nothing pointing at them (the validator notes them): relayout() the
        model afterwards to close the gap (a static model)."""
        for name in ("coll_indices", "coll_positions", "coll_normals"):
            n, off = self.arr(name)
            size = ARRAY[name][1]
            self.md[off:off + n * size] = bytes(n * size)
            self.set_arr(name, 0, 0)
        struct.pack_into("<6ff", self.md, OFF_CBOX, *(EMPTY_BOX + (0.0,)))

    # -- output ------------------------------------------------------------------------------------------------
    def to_bytes(self):
        if len(self.md) % ALIGN:
            raise M2Error("the MD20 block is not a multiple of 16 bytes")
        if self.legacy:
            return bytes(self.md)
        out = bytearray()
        for tag, payload in self.chunks:
            body = bytes(self.md) if tag == "MD21" else payload
            out += tag.encode("latin1") + struct.pack("<I", len(body)) + body
        return bytes(out)


# ---------------------------------------------------------------------------------------------------------------
# Re-laying out a static model (new vertex count, texture file names)
# ---------------------------------------------------------------------------------------------------------------

def relayout(m2, vertices=None, texture_names=None):
    """A new MD20 block for a static model in the client's own order (see the module notes): `vertices` replaces the
    vertex array (any count), `texture_names` gives texture i the file name texture_names[i] (None or '' = none).
    Returns a new M2 with the same chunks. Refuses models it cannot place exactly (animated bones, attachments,
    events, lights, cameras, ribbons, particles, the extended header)."""
    src = m2.md
    if m2.global_flags & 0x8:
        raise M2Error("relayout: global flag 0x8 (extended header) is not handled")
    for name in NOT_STATIC:
        if m2.arr(name)[0]:
            raise M2Error("relayout: the model has %s" % name)
    if not m2.bones_static():
        raise M2Error("relayout: animated bones are not handled")
    out = bytearray(src[:HEADER_SIZE])
    for name, off, size in ARRAYS:
        struct.pack_into("<2I", out, off, 0, 0)
    tail = []                       # key frames, placed last: (where their M2Array sits in `out`, bytes, count)

    def place(blob):
        start = align(len(out))
        out.extend(bytes(start - len(out)))
        out.extend(blob)
        return start

    for name in STATIC_ORDER:
        size = ARRAY[name][1]
        if name == "vertices" and vertices is not None:
            elems = [struct.pack("<3f4B4B3f2f2f", *(tuple(v.pos) + tuple(v.weights) + tuple(v.bones) +
                                                   tuple(v.normal) + tuple(v.uv0) + tuple(v.uv1))) for v in vertices]
        else:
            elems = m2.elements(name)
        if name == "textures" and texture_names is not None and len(texture_names) != len(elems):
            raise M2Error("relayout: %d texture names for %d textures" % (len(texture_names), len(elems)))
        if not elems:
            continue
        start = place(b"".join(elems))
        struct.pack_into("<2I", out, ARRAY[name][0], len(elems), start)
        if name == "textures":
            for i, e in enumerate(elems):
                nn, no = struct.unpack_from("<2I", e, 8)
                if texture_names is not None:
                    text = texture_names[i]
                    blob = (text.encode("ascii") + b"\0") if text else b""
                else:
                    blob = bytes(src[no:no + nn])
                pos = place(blob) if blob else 0
                struct.pack_into("<2I", out, start + 16 * i + 8, len(blob), pos)
        for i in range(len(elems)):
            for toff, vsize in TRACKS.get(name, ()):
                base = start + size * i + toff
                for k, key_size in ((4, 4), (12, vsize)):      # timestamps (uint32 each), then values
                    n_outer, o_outer = struct.unpack_from("<2I", src, m2.arr(name)[1] + size * i + toff + k)
                    if not n_outer:
                        struct.pack_into("<2I", out, base + k, 0, 0)
                        continue
                    outer = bytearray(src[o_outer:o_outer + 8 * n_outer])
                    pos = place(outer)
                    struct.pack_into("<2I", out, base + k, n_outer, pos)
                    for j in range(n_outer):
                        cnt, o = struct.unpack_from("<2I", outer, 8 * j)
                        tail.append((pos + 8 * j, bytes(src[o:o + cnt * key_size]) if cnt else b"", cnt))
    for at, blob, cnt in tail:
        pos = place(blob) if cnt else 0
        struct.pack_into("<2I", out, at, cnt, pos)
    out.extend(bytes(align(len(out)) - len(out)))
    return M2(out, [list(c) for c in m2.chunks], legacy=m2.legacy)


def legacy_md20(m2, texture_names):
    """The model as a non-chunked MD20 file (pre-Legion layout): no SFID (skins are found by name, '<name>00.skin'),
    no TXID (textures by the file names given), no TXAC/LDV1."""
    if len(texture_names) != m2.arr("textures")[0]:
        raise M2Error("legacy_md20: one name per texture")
    new = relayout(m2, texture_names=texture_names)
    return M2(new.md, [], legacy=True)


# ---------------------------------------------------------------------------------------------------------------
# Skins
# ---------------------------------------------------------------------------------------------------------------

class Skin:
    def __init__(self, lookup, indices, bones, sections, batches, shadows, bone_count_max=0):
        self.lookup = list(lookup)
        self.indices = list(indices)
        self.bones = [tuple(b) for b in bones]
        self.sections = list(sections)
        self.batches = list(batches)
        self.shadows = list(shadows)
        self.bone_count_max = bone_count_max

    @classmethod
    def parse(cls, data):
        if data[:4] != b"SKIN":
            raise M2Error("not a skin (%r)" % data[:4])
        (nl, ol, ni, oi, nb, ob, ns, os_, nbt, obt, bcm, nsh, osh) = struct.unpack_from("<13I", data, 4)
        lookup = struct.unpack_from("<%dH" % nl, data, ol)
        indices = struct.unpack_from("<%dH" % ni, data, oi)
        bones = [struct.unpack_from("<4B", data, ob + 4 * i) for i in range(nb)]
        sections = []
        for i in range(ns):
            f = struct.unpack_from("<10H7f", data, os_ + 48 * i)
            sections.append(SkinSection(*(f[:10] + (f[10:13], f[13:16], f[16]))))
        batches = [Batch(*struct.unpack_from("<BbHHHHHHHHHHH", data, obt + 24 * i)) for i in range(nbt)]
        shadows = [ShadowBatch(*struct.unpack_from("<BBHHHHH", data, osh + 12 * i)) for i in range(nsh)]
        return cls(lookup, indices, bones, sections, batches, shadows, bcm)

    def to_bytes(self):
        blobs = [
            struct.pack("<%dH" % len(self.lookup), *self.lookup),
            struct.pack("<%dH" % len(self.indices), *self.indices),
            b"".join(struct.pack("<4B", *b) for b in self.bones),
            b"".join(struct.pack("<10H7f", *(tuple(s[:10]) + tuple(s.center) + tuple(s.sort_center) +
                                             (s.sort_radius,))) for s in self.sections),
            b"".join(struct.pack("<BbHHHHHHHHHHH", *b) for b in self.batches),
            b"".join(struct.pack("<BBHHHHH", *s) for s in self.shadows),
        ]
        counts = (len(self.lookup), len(self.indices), len(self.bones), len(self.sections), len(self.batches),
                  len(self.shadows))
        out = bytearray(SKIN_HEADER_SIZE)
        offs = []
        for blob, n in zip(blobs, counts):
            if not n:
                offs.append(0)
                continue
            start = align(len(out))
            out.extend(bytes(start - len(out)))
            offs.append(start)
            out.extend(blob)
        out.extend(bytes(align(len(out)) - len(out)))
        struct.pack_into("<4s", out, 0, b"SKIN")
        struct.pack_into("<10I", out, 4, *[x for pair in zip(counts[:5], offs[:5]) for x in pair])
        struct.pack_into("<3I", out, 44, self.bone_count_max, counts[5], offs[5])
        return bytes(out)


def shadow_batches(m2, batches):
    """One shadow batch per opaque / alpha-key batch, as the client's skins carry them."""
    mats = m2.materials()
    tex = [struct.unpack("<H", e)[0] for e in m2.elements("tex_lookup")]
    transp = [struct.unpack("<H", e)[0] for e in m2.elements("transp_lookup")]
    out = []
    for b in batches:
        flags, blend = mats[b.material]
        if blend > 1:
            continue
        out.append(ShadowBatch(b.flags & 0xFF, shadow_flags2(flags, blend), 0, b.section, tex[b.texture_combo],
                               b.color, transp[b.weight_combo]))
    return out


def single_mesh_skin(m2, triangles, template):
    """A skin for a static model drawn as one submesh with one batch: every vertex in order, `triangles` as given
    (front faces counter-clockwise). The submesh's and batch's other fields come from `template` (a Skin of a
    Blizzard model of the same kind); the geometry fields and the shadow batches are recomputed."""
    verts = m2.vertices()
    if len(template.sections) != 1 or len(template.batches) != 1:
        raise M2Error("single_mesh_skin: the template must have one submesh and one batch")
    if len(verts) > 0xFFFF:
        raise M2Error("single_mesh_skin: a skin indexes at most 65,535 vertices")
    flat = [i for t in triangles for i in t]
    if any(not 0 <= i < len(verts) for i in flat):
        raise M2Error("single_mesh_skin: a triangle uses a vertex the model does not have")
    if len(flat) > 0xFFFF:
        raise M2Error("single_mesh_skin: one submesh holds at most 65,535 indices")
    t = template.sections[0]
    mean, sc, sr = submesh_geometry([v.pos for v in verts])
    sec = t._replace(vertex_start=0, vertex_count=len(verts), index_start=0, index_count=len(flat), center=mean,
                     sort_center=sc, sort_radius=sr)
    batch = template.batches[0]
    return Skin(range(len(verts)), flat, [template.bones[0]] * len(verts), [sec], [batch],
                shadow_batches(m2, [batch]), template.bone_count_max)


# ---------------------------------------------------------------------------------------------------------------
# Validator: a separate, strict reader with its own tables (a writer bug cannot hide behind a shared parser).
# ---------------------------------------------------------------------------------------------------------------

class ValidationError(Exception):
    pass


class _Buf:
    """Bounds-checked little-endian reads; every miss is a problem, never an exception from struct."""

    def __init__(self, data, label):
        self.d = bytes(data)
        self.label = label

    def ok(self, off, size):
        return 0 <= off and off + size <= len(self.d)

    def u(self, fmt, off):
        size = struct.calcsize("<" + fmt)
        if not self.ok(off, size):
            raise ValidationError("%s: read of %d bytes at %d past the end (%d)" % (self.label, size, off, len(self.d)))
        return struct.unpack_from("<" + fmt, self.d, off)


class Report:
    def __init__(self, label):
        self.label = label
        self.problems = []
        self.notes = []
        self.info = {}

    def bad(self, msg, *a):
        self.problems.append(msg % a if a else msg)

    def note(self, msg, *a):
        self.notes.append(msg % a if a else msg)

    @property
    def ok(self):
        return not self.problems

    def raise_if_bad(self):
        if self.problems:
            raise ValidationError("%s:\n  %s" % (self.label, "\n  ".join(self.problems)))


_V_ARRAYS = (   # the validator's own table: name, header offset, element size, allowed in what we ship
    ("name", 8, 1, True), ("global_loops", 20, 4, True), ("sequences", 28, 64, True), ("seq_lookup", 36, 2, True),
    ("bones", 44, 88, True), ("key_bone_lookup", 52, 2, True), ("vertices", 60, 48, True), ("colors", 72, 40, True),
    ("textures", 80, 16, True), ("tex_weights", 88, 20, True), ("tex_transforms", 96, 60, True),
    ("repl_tex_lookup", 104, 2, True), ("materials", 112, 4, True), ("bone_lookup", 120, 2, True),
    ("tex_lookup", 128, 2, True), ("tex_unit_lookup", 136, 2, True), ("transp_lookup", 144, 2, True),
    ("uvanim_lookup", 152, 2, True), ("coll_indices", 216, 2, True), ("coll_positions", 224, 12, True),
    ("coll_normals", 232, 12, True), ("attachments", 240, 40, False), ("attach_lookup", 248, 2, False),
    ("events", 256, 36, False), ("lights", 264, 156, False), ("cameras", 272, 116, False),
    ("camera_lookup", 280, 2, False), ("ribbons", 288, 176, False), ("particles", 296, 492, False),
)
_V_TRACKS = {"bones": ((16, 12), (36, 8), (56, 12)), "colors": ((0, 12), (20, 2)), "tex_weights": ((0, 2),),
             "tex_transforms": ((0, 12), (20, 16), (40, 12))}
_V_CHUNKS = ("MD21", "TXAC", "EXP2", "PGD1", "LDV1", "SFID", "TXID")      # what our files may carry, in this order
_V_MATERIAL_FLAGS = 0x1F         # unlit, unfogged, two-sided, no depth test, no depth write: all we ever set
_EPS = 1e-4


def _finite(*xs):
    return all(math.isfinite(x) for x in xs)


def validate_m2(data, loose_skins=None, game_file=None, label="model"):
    """Check an .m2 file's bytes. loose_skins: {lod index: skin bytes} shipped next to it (needed when there is no
    SFID: the client then looks for '<name>00.skin'); game_file(fid) -> bytes or None reads the installed client's
    files (casc_local.read_fid) to check that SFID / TXID entries exist and to check a borrowed skin against this
    model. Returns a Report (problems = reasons not to ship)."""
    rep = Report(label)
    try:
        _validate_m2(data, loose_skins or {}, game_file, rep)
    except ValidationError as e:
        rep.bad(str(e))
    return rep


def _validate_m2(data, loose_skins, game_file, rep):
    data = bytes(data)
    rep.info["size"] = len(data)
    chunks = {}
    if data[:4] == b"MD21":
        pos, order = 0, []
        while pos < len(data):
            if pos + 8 > len(data):
                rep.bad("a chunk header is cut off at %d", pos)
                return
            tag = data[pos:pos + 4].decode("latin1")
            size = struct.unpack_from("<I", data, pos + 4)[0]
            if pos + 8 + size > len(data):
                rep.bad("chunk %s (%d bytes at %d) runs past the end of the file (%d)", tag, size, pos, len(data))
                return
            if tag in chunks:
                rep.bad("chunk %s twice", tag)
            chunks[tag] = data[pos + 8:pos + 8 + size]
            order.append(tag)
            pos += 8 + size
        if order[:1] != ["MD21"]:
            rep.bad("the first chunk is %s, not MD21", order[:1])
            return
        unknown = [t for t in order if t not in _V_CHUNKS]
        if unknown:
            rep.bad("chunks the writer never produces: %s", unknown)
        known = [t for t in order if t in _V_CHUNKS]
        if known != sorted(known, key=_V_CHUNKS.index):
            rep.bad("chunk order %s differs from the client's (%s)", known, ", ".join(_V_CHUNKS))
        md = chunks["MD21"]
        rep.info["chunks"] = order
    elif data[:4] == b"MD20":
        md = data
        rep.info["chunks"] = []
    else:
        rep.bad("magic %r is neither MD21 nor MD20", data[:4])
        return
    b = _Buf(md, "MD20")
    if md[:4] != b"MD20":
        rep.bad("the model block's magic is %r", md[:4])
        return
    if len(md) < HEADER_SIZE:
        rep.bad("the MD20 block (%d bytes) is shorter than its header", len(md))
        return
    version, = b.u("I", 4)
    rep.info["version"] = version
    if version not in VERSIONS:
        rep.bad("version %d (the client's files are %s)", version, VERSIONS)
    if len(md) % 16:
        rep.bad("the MD20 block is %d bytes, not a multiple of 16 (every client file is)", len(md))
    gflags, = b.u("I", 16)
    if gflags & 0x8:
        rep.bad("global flag 0x8 (extended header) set")
    arrays = {}
    regions = []                                          # (start, end, what)
    for name, off, size, allowed in _V_ARRAYS:
        n, o = b.u("2I", off)
        arrays[name] = (n, o, size)
        if not n:
            if o and o > len(md):
                rep.bad("%s: empty but its offset %d is outside the block", name, o)
            continue
        if not allowed:
            rep.bad("%s: %d present (the writer never ships these)", name, n)
        if o < HEADER_SIZE:
            rep.bad("%s: offset %d inside the header", name, o)
        if o % 16:
            rep.bad("%s: offset %d not on 16 bytes", name, o)
        if n > 0x7FFFFFFF // max(size, 1) or o + n * size > len(md):
            rep.bad("%s: %d x %d bytes at %d runs past the block (%d)", name, n, size, o, len(md))
            arrays[name] = (0, 0, size)
            continue
        regions.append((o, o + n * size, name))
    nseq = arrays["sequences"][0]
    nbones = arrays["bones"][0]
    nverts = arrays["vertices"][0]
    ntex = arrays["textures"][0]
    nmat = arrays["materials"][0]
    nglob = arrays["global_loops"][0]
    nskin, = b.u("I", OFF_NSKIN)
    rep.info.update(sequences=nseq, bones=nbones, vertices=nverts, textures=ntex, materials=nmat, skins=nskin)
    if nseq < 1:
        rep.bad("no sequence (the client needs Stand)")
    if nbones < 1:
        rep.bad("no bone")
    if nbones > 256:
        rep.bad("%d bones (at most 256)", nbones)
    if not 1 <= nverts <= 0xFFFF:
        rep.bad("%d vertices (skins index 1..65,535)", nverts)
    if not 1 <= nskin <= 4:
        rep.bad("%d skin profiles", nskin)

    def lookup(name, limit, allow_neg=True):
        n, o, size = arrays[name]
        vals = b.u("%dh" % n, o) if n else ()
        for i, v in enumerate(vals):
            if v == -1 and allow_neg:
                continue
            if not 0 <= v < limit:
                rep.bad("%s[%d] = %d, not below %d", name, i, v, limit)
        return vals

    # name
    n, o, _ = arrays["name"]
    if n and md[o + n - 1:o + n] != b"\0":
        rep.bad("the model name is not NUL-terminated")
    # sequences
    n, o, _ = arrays["sequences"]
    for i in range(n):
        sid, var, dur = b.u("HHI", o + 64 * i)
        flags, = b.u("I", o + 64 * i + 12)
        box = b.u("7f", o + 64 * i + 32)
        nxt, alias = b.u("hH", o + 64 * i + 60)
        if not flags & 0x20:
            rep.bad("sequence %d (id %d) is not inside the file (flag 0x20): the client would look for an .anim", i, sid)
        if not (nxt == -1 or 0 <= nxt < n):
            rep.bad("sequence %d: next variation %d", i, nxt)
        if not _finite(*box):
            rep.bad("sequence %d: bounds not finite", i)
        rep.info.setdefault("sequence_bounds", []).append(box)
    lookup("seq_lookup", max(nseq, 1))
    lookup("key_bone_lookup", max(nbones, 1))
    lookup("bone_lookup", max(nbones, 1), allow_neg=False)
    # tracks (bones, colours, texture weights, texture transforms)
    for owner, tracks in _V_TRACKS.items():
        n, o, size = arrays[owner]
        for i in range(n):
            for toff, vsize in tracks:
                at = o + size * i + toff
                interp, gseq = b.u("Hh", at)
                if interp > 3:
                    rep.bad("%s %d: interpolation %d", owner, i, interp)
                if not (gseq == -1 or 0 <= gseq < nglob):
                    rep.bad("%s %d: global sequence %d of %d", owner, i, gseq, nglob)
                outer = []
                for k, key_size in ((4, 4), (12, vsize)):
                    on, oo = b.u("2I", at + k)
                    outer.append(on)
                    if not on:
                        continue
                    if on > max(nseq, 1) and gseq == -1:
                        rep.bad("%s %d: a track with %d sequence slots for %d sequences", owner, i, on, nseq)
                    if oo % 16 or oo < HEADER_SIZE or oo + 8 * on > len(md):
                        rep.bad("%s %d: track arrays at %d (%d) out of place", owner, i, oo, on)
                        continue
                    regions.append((oo, oo + 8 * on, "%s %d track" % (owner, i)))
                    for j in range(on):
                        cnt, co = b.u("2I", oo + 8 * j)
                        if not cnt:
                            continue
                        if co % 16 or co < HEADER_SIZE or co + cnt * key_size > len(md):
                            rep.bad("%s %d: key frames at %d (%d x %d) out of place", owner, i, co, cnt, key_size)
                            continue
                        regions.append((co, co + cnt * key_size, "%s %d keys" % (owner, i)))
                if outer[0] != outer[1]:
                    rep.bad("%s %d: %d timestamp slots but %d value slots", owner, i, outer[0], outer[1])
    # bones
    n, o, _ = arrays["bones"]
    for i in range(n):
        key, flags, parent, sub = b.u("iIhH", o + 88 * i)
        pivot = b.u("3f", o + 88 * i + 76)
        if not (parent == -1 or 0 <= parent < i):
            rep.bad("bone %d: parent %d (must be -1 or an earlier bone)", i, parent)
        if not (key == -1 or 0 <= key < arrays["key_bone_lookup"][0]):
            rep.bad("bone %d: key bone %d", i, key)
        if not _finite(*pivot):
            rep.bad("bone %d: pivot not finite", i)
    # vertices
    n, o, _ = arrays["vertices"]
    pts = []
    for i in range(n):
        p = b.u("3f", o + 48 * i)
        w = b.u("4B", o + 48 * i + 12)
        bi = b.u("4B", o + 48 * i + 16)
        nrm = b.u("3f", o + 48 * i + 20)
        uv = b.u("4f", o + 48 * i + 32)
        if not _finite(*(p + nrm + uv)):
            rep.bad("vertex %d not finite", i)
            continue
        if sum(w) != 255:
            rep.bad("vertex %d: bone weights add up to %d, not 255", i, sum(w))
        for wk, bk in zip(w, bi):
            if wk and bk >= nbones:
                rep.bad("vertex %d: bone %d of %d", i, bk, nbones)
        ln = math.sqrt(sum(x * x for x in nrm))
        if abs(ln - 1.0) > 0.01:
            rep.bad("vertex %d: normal length %.4f", i, ln)
        pts.append(p)
    rep.info["points"] = pts
    # bounds
    box = b.u("6f", OFF_BOX)
    radius, = b.u("f", OFF_RADIUS)
    rep.info["box"], rep.info["radius"] = box, radius
    if not _finite(*(box + (radius,))):
        rep.bad("header bounds not finite")
    elif pts:
        for k in range(3):
            if box[k] > box[k + 3]:
                rep.bad("header box min > max on axis %d", k)
        lo = [min(p[k] for p in pts) for k in range(3)]
        hi = [max(p[k] for p in pts) for k in range(3)]
        for k in range(3):
            if lo[k] < box[k] - _EPS or hi[k] > box[k + 3] + _EPS:
                rep.bad("the header box %s does not hold every vertex (axis %d: %.5f..%.5f)", box, k, lo[k], hi[k])
        c = [(box[k] + box[k + 3]) / 2 for k in range(3)]
        far = max(math.sqrt(sum((p[k] - c[k]) ** 2 for k in range(3))) for p in pts)
        if radius < far - _EPS * max(1.0, far):
            rep.bad("radius %.5f is less than the farthest vertex (%.5f)", radius, far)
        # with no bone key frames the vertices never move: every sequence's bounds must hold them as they are
        static = all(not b.u("I", arrays["bones"][1] + 88 * j + toff + k)[0]
                     for j in range(nbones) for toff, _ in _V_TRACKS["bones"] for k in (4, 12))
        rep.info["static"] = static
        for i, sb in enumerate(rep.info.get("sequence_bounds", []) if static else []):
            if any(lo[k] < sb[k] - _EPS or hi[k] > sb[k + 3] + _EPS for k in range(3)):
                rep.bad("sequence %d's bounds %s do not hold the vertices", i, sb[:6])
            sc = [(sb[k] + sb[k + 3]) / 2 for k in range(3)]
            sfar = max(math.sqrt(sum((p[k] - sc[k]) ** 2 for k in range(3))) for p in pts)
            if sb[6] < sfar - _EPS * max(1.0, sfar):
                rep.bad("sequence %d's radius %.5f is below the farthest vertex %.5f", i, sb[6], sfar)
    # collision
    cbox = b.u("6f", OFF_CBOX)
    cr, = b.u("f", OFF_CRADIUS)
    ni, _, _ = arrays["coll_indices"]
    npos, _, _ = arrays["coll_positions"]
    nnorm, _, _ = arrays["coll_normals"]
    if not (ni or npos or nnorm):
        if tuple(cbox) != EMPTY_BOX or cr != 0.0:
            if not (cbox[0] <= cbox[3] and _finite(*cbox)):
                rep.bad("no collision mesh but a malformed collision box %s", cbox)
    else:
        if ni % 3 or nnorm != ni // 3:
            rep.bad("collision: %d indices, %d normals", ni, nnorm)
        n, o, _ = arrays["coll_indices"]
        for i, v in enumerate(b.u("%dH" % n, o)):
            if v >= npos:
                rep.bad("collision index %d = %d of %d positions", i, v, npos)
                break
        n, o, _ = arrays["coll_positions"]
        for i in range(n):
            p = b.u("3f", o + 12 * i)
            if any(p[k] < cbox[k] - _EPS or p[k] > cbox[k + 3] + _EPS for k in range(3)):
                rep.bad("collision position %d outside the collision box", i)
                break
    # textures (+ TXID), materials, lookups
    txid = None
    if "TXID" in chunks:
        if len(chunks["TXID"]) != 4 * ntex:
            rep.bad("TXID holds %d bytes for %d textures", len(chunks["TXID"]), ntex)
        else:
            txid = struct.unpack("<%dI" % ntex, chunks["TXID"])
    n, o, _ = arrays["textures"]
    tex_files = []
    for i in range(n):
        ttype, tflags, nn, no = b.u("4I", o + 16 * i)
        if tflags & ~0x3:
            rep.bad("texture %d: flags 0x%x (only wrap x / y expected)", i, tflags)
        name = None
        if nn:
            if no % 16 or no < HEADER_SIZE or no + nn > len(md):
                rep.bad("texture %d: file name at %d (%d) out of place", i, no, nn)
            else:
                regions.append((no, no + nn, "texture %d name" % i))
                raw = md[no:no + nn]
                if raw[-1:] != b"\0" or b"\0" in raw[:-1]:
                    rep.bad("texture %d: file name not one NUL-terminated string", i)
                else:
                    try:
                        name = raw[:-1].decode("ascii")
                    except UnicodeDecodeError:
                        rep.bad("texture %d: file name not ASCII", i)
                    if name is not None and not name.lower().endswith(".blp"):
                        rep.bad("texture %d: file name %r is not a .blp", i, name)
        fid = txid[i] if txid else 0
        if ttype == 0:
            if fid and name:
                rep.bad("texture %d: both a TXID and a file name (the client wants the name zeroed for TXID)", i)
            if not fid and not name:
                rep.bad("texture %d: hard-coded texture with neither a TXID nor a file name", i)
            if fid and game_file is not None:
                blob = _safe_read(game_file, fid)
                if blob is None or blob[:4] != b"BLP2":
                    rep.bad("texture %d: FileDataID %d is not a BLP in this client", i, fid)
        elif fid or name:
            rep.bad("texture %d: replaceable type %d with a file", i, ttype)
        tex_files.append(fid or name)
    rep.info["textures_files"] = tex_files
    mats = []
    n, o, _ = arrays["materials"]
    for i in range(n):
        mflags, blend = b.u("HH", o + 4 * i)
        if blend > 7:
            rep.bad("material %d: blend mode %d", i, blend)
        if mflags & ~_V_MATERIAL_FLAGS:
            rep.bad("material %d: flags 0x%x outside 0x%x", i, mflags, _V_MATERIAL_FLAGS)
        mats.append((mflags, blend))
    rep.info["materials"] = mats
    tex_lookup = lookup("tex_lookup", max(ntex, 1), allow_neg=False)
    transp_lookup = lookup("transp_lookup", max(arrays["tex_weights"][0], 1), allow_neg=False)
    uv_lookup = lookup("uvanim_lookup", max(arrays["tex_transforms"][0], 1))
    lookup("tex_unit_lookup", 2)                          # a vertex's two uv sets (-1: environment mapped)
    lookup("repl_tex_lookup", max(ntex, 1))
    if arrays["tex_lookup"][0] and not ntex:
        rep.bad("a texture lookup without textures")
    # chunks besides MD21
    if "TXAC" in chunks and len(chunks["TXAC"]) != 2 * (nmat + arrays["particles"][0]):
        rep.bad("TXAC holds %d bytes for %d materials", len(chunks["TXAC"]), nmat)
    if "LDV1" in chunks:
        if len(chunks["LDV1"]) != 16:
            rep.bad("LDV1 is %d bytes, not 16", len(chunks["LDV1"]))
        elif struct.unpack_from("<H", chunks["LDV1"], 2)[0] != nskin:
            rep.bad("LDV1 says %d LODs, the header %d skins", struct.unpack_from("<H", chunks["LDV1"], 2)[0], nskin)
    for t in ("EXP2", "PGD1"):
        if t in chunks:
            rep.bad("chunk %s (particles) in a model without particles", t)
    # the regions must not overlap (Blizzard's exporter shares one key frame array between sequence slots that hold
    # the same keys: the very same span referenced twice is fine)
    regions = sorted(set((s, e, w) for s, e, w in regions))
    regions = [r for i, r in enumerate(regions)
               if not (i and r[:2] == regions[i - 1][:2] and r[2].endswith("keys") and regions[i - 1][2].endswith("keys"))]
    for (s0, e0, w0), (s1, e1, w1) in zip(regions, regions[1:]):
        if s1 < e0:
            rep.bad("%s (%d..%d) overlaps %s (%d..%d)", w0, s0, e0, w1, s1, e1)
    # bytes nothing points at, beyond the 16-byte alignment: harmless to the client, but only 13 of its 9,103 models
    # of the kinds we ship carry any, so in ours it means an edit left old data behind (clear_collision before
    # relayout). A model with particles, cameras and the like is refused above and noted here too (their own
    # sub-arrays are not followed).
    end = HEADER_SIZE
    for s, e, w in regions:
        if s - end >= ALIGN:
            rep.note("MD20 bytes %d..%d are not referenced (before %s)", end, s, w)
        end = max(end, e)
    if regions and len(md) - end >= ALIGN:
        rep.note("MD20 bytes %d..%d at the end are not referenced", end, len(md))
    # skins
    skins = {}
    if "SFID" in chunks:
        lods = struct.unpack_from("<H", chunks["LDV1"], 2)[0] if len(chunks.get("LDV1", b"")) == 16 else 1
        if lods > nskin and len(chunks["SFID"]) == 4 * (nskin + lods - 1):
            rep.bad("SFID lists %d LOD skins after %d skin profile(s): Blizzard's LOD layout, which the writer never "
                    "produces", lods - 1, nskin)
        elif len(chunks["SFID"]) != 4 * nskin:
            rep.bad("SFID holds %d bytes for %d skins", len(chunks["SFID"]), nskin)
        sfid = struct.unpack("<%dI" % (len(chunks["SFID"]) // 4), chunks["SFID"])
        rep.info["sfid"] = sfid
        for i, fid in enumerate(sfid[:nskin]):
            if not fid:
                rep.bad("SFID %d is 0", i)
            elif game_file is not None:
                blob = _safe_read(game_file, fid)
                if blob is None:
                    rep.bad("skin FileDataID %d is not in this client", fid)
                else:
                    skins[i] = (blob, "game skin %d" % fid, False)
        if loose_skins:
            rep.bad("loose skins given for a model whose SFID names game skins (the client ignores them)")
    else:
        for i in range(nskin):
            if i not in loose_skins:
                rep.bad("no SFID and no loose skin %02d next to the model", i)
            else:
                skins[i] = (loose_skins[i], "skin %02d" % i, True)
    model = {"vertices": nverts, "bones": nbones, "materials": mats, "tex_lookup": tex_lookup,
             "transp_lookup": transp_lookup, "uv_lookup": uv_lookup, "colors": arrays["colors"][0],
             "bone_lookup": arrays["bone_lookup"][0], "points": pts, "textures": ntex,
             "tex_weights": arrays["tex_weights"][0], "coord_lookup": arrays["tex_unit_lookup"][0]}
    rep.info["skin_reports"] = {}
    for i, (blob, what, ours) in sorted(skins.items()):
        sr = validate_skin(blob, model, ours=ours, label=what)
        rep.info["skin_reports"][i] = sr
        for p in sr.problems:
            rep.bad("%s: %s", what, p)
        for p in sr.notes:
            rep.note("%s: %s", what, p)


def _safe_read(game_file, fid):
    try:
        return game_file(fid)
    except Exception:  # noqa: BLE001 - a missing file is the finding, not a crash
        return None


def validate_skin(data, model, ours=True, label="skin"):
    """Check a skin against the model it is drawn with (`model`: what validate_m2 gathered). ours=False for a
    Blizzard skin we borrow (its shadow batches were made for its own model's materials: a mismatch is a note)."""
    rep = Report(label)
    try:
        _validate_skin(bytes(data), model, ours, rep)
    except ValidationError as e:
        rep.bad(str(e))
    return rep


def _validate_skin(d, model, ours, rep):
    b = _Buf(d, "skin")
    if d[:4] != b"SKIN":
        rep.bad("magic %r", d[:4])
        return
    if len(d) < SKIN_HEADER_SIZE:
        rep.bad("%d bytes: shorter than the header", len(d))
        return
    if len(d) % 16:
        rep.bad("%d bytes, not a multiple of 16", len(d))
    if d[56:64] != bytes(8):
        rep.bad("header bytes 56..63 not zero")
    names = (("lookup", 4, 2), ("indices", 12, 2), ("bones", 20, 4), ("submeshes", 28, 48), ("batches", 36, 24),
             ("shadow batches", 48, 12))
    arr = {}
    regions = []
    for name, off, size in names:
        n, o = b.u("2I", off)
        arr[name] = (n, o)
        if not n:
            continue
        if o % 16 or o < SKIN_HEADER_SIZE or o + n * size > len(d):
            rep.bad("%s: %d x %d bytes at %d out of place (file %d)", name, n, size, o, len(d))
            arr[name] = (0, 0)
            continue
        regions.append((o, o + n * size, name))
    regions.sort()
    for (s0, e0, w0), (s1, e1, w1) in zip(regions, regions[1:]):
        if s1 < e0:
            rep.bad("%s overlaps %s", w0, w1)
    if regions and align(regions[-1][1]) != len(d):
        rep.bad("the file is %d bytes; its last array ends at %d", len(d), regions[-1][1])
    bcm, = b.u("I", 44)
    nl, ol = arr["lookup"]
    lk = b.u("%dH" % nl, ol) if nl else ()
    for i, v in enumerate(lk):
        if v >= model["vertices"]:
            rep.bad("lookup[%d] = %d, the model has %d vertices", i, v, model["vertices"])
            break
    ni, oi = arr["indices"]
    if ni % 3:
        rep.bad("%d indices: not whole triangles", ni)
    idx = b.u("%dH" % ni, oi) if ni else ()
    for i, v in enumerate(idx):
        if v >= nl:
            rep.bad("index %d = %d, the lookup has %d entries", i, v, nl)
            break
    nb, ob = arr["bones"]
    if nb != nl:
        rep.bad("%d bone entries for %d lookup entries", nb, nl)
    nsec, osec = arr["submeshes"]
    secs = []
    for s in range(nsec):
        f = b.u("10H7f", osec + 48 * s)
        sid, lvl, vs, vc, ist, ic, bc, bci, binf, cb = f[:10]
        vs, ist = vs | (lvl << 16), ist | (lvl << 16)
        secs.append(f)
        if lvl:
            rep.bad("submesh %d: level %d (more than 65,535 indices are not written)", s, lvl)
        if vs + vc > nl:
            rep.bad("submesh %d: vertices %d..%d past the lookup (%d)", s, vs, vs + vc, nl)
        if ist + ic > ni or ic % 3:
            rep.bad("submesh %d: indices %d..%d (of %d)", s, ist, ist + ic, ni)
        else:
            for v in idx[ist:ist + ic]:
                if not vs <= v < vs + vc:
                    rep.bad("submesh %d: a triangle uses lookup entry %d outside its vertices %d..%d", s, v, vs,
                            vs + vc)
                    break
        if bci + bc > model["bone_lookup"]:
            rep.bad("submesh %d: bones %d..%d past the bone lookup (%d)", s, bci, bci + bc, model["bone_lookup"])
        if binf > 4:
            rep.bad("submesh %d: %d bone influences", s, binf)
        if cb >= model["bones"]:
            rep.bad("submesh %d: centre bone %d of %d bones", s, cb, model["bones"])
        for k in range(vs, min(vs + vc, nb)):
            for x in b.u("4B", ob + 4 * k):
                if x >= max(bc, 1):
                    rep.bad("submesh %d: vertex bone %d of %d", s, x, bc)
                    break
        if not _finite(*f[10:]):
            rep.bad("submesh %d: centre / radius not finite", s)
        elif vc and model["points"]:
            pts = [model["points"][lk[k]] for k in range(vs, min(vs + vc, nl)) if lk[k] < len(model["points"])]
            if pts:
                sc, sr = f[13:16], f[16]
                far = max(math.sqrt(sum((p[k] - sc[k]) ** 2 for k in range(3))) for p in pts)
                if sr < far - _EPS * max(1.0, far):
                    msg = "submesh %d: sort radius %.4f below its farthest vertex %.4f" % (s, sr, far)
                    if ours:
                        rep.bad(msg)
                    else:
                        rep.note(msg + " (borrowed skin: used for sorting only)")
    nbt, obt = arr["batches"]
    batches = []
    for k in range(nbt):
        bt = b.u("BbHHHHHHHHHHH", obt + 24 * k)
        flags, prio, shader, sec, geo, color, mat, layer, tcount, tcombo, coord, tw, tt = bt
        batches.append(bt)
        if sec >= nsec:
            rep.bad("batch %d: submesh %d of %d", k, sec, nsec)
        if mat >= len(model["materials"]):
            rep.bad("batch %d: material %d of %d", k, mat, len(model["materials"]))
        if not 1 <= tcount <= 4:
            rep.bad("batch %d: %d textures", k, tcount)
        if tcombo + tcount > len(model["tex_lookup"]):
            rep.bad("batch %d: textures %d..%d past the texture lookup (%d)", k, tcombo, tcombo + tcount,
                    len(model["tex_lookup"]))
        if tw >= len(model["transp_lookup"]):
            rep.bad("batch %d: transparency %d of %d", k, tw, len(model["transp_lookup"]))
        if not model["coord_lookup"]:
            if coord not in (0, 0xFFFF):
                rep.bad("batch %d: texture coordinate combo %d with an empty combo table (the client's say 0 or "
                        "65535)", k, coord)
        elif coord + tcount > model["coord_lookup"]:
            rep.bad("batch %d: texture coordinate combos %d..%d past the table (%d)", k, coord, coord + tcount,
                    model["coord_lookup"])
        if tt != 0xFFFF and tt >= max(len(model["uv_lookup"]), 1):
            rep.bad("batch %d: uv animation %d of %d", k, tt, len(model["uv_lookup"]))
        if color != 0xFFFF and color >= model["colors"]:
            rep.bad("batch %d: colour %d of %d", k, color, model["colors"])
        if layer > 7:
            rep.bad("batch %d: material layer %d", k, layer)
        if shader & 0x8000:
            rep.bad("batch %d: shader 0x%x from the combiner table (the writer never sets that)", k, shader)
    nsh, osh = arr["shadow batches"]
    got = [b.u("BBHHHHH", osh + 12 * k) for k in range(nsh)]
    want = []
    for bt in batches:
        mat = bt[6]
        if mat >= len(model["materials"]) or bt[9] >= len(model["tex_lookup"]) or bt[11] >= len(model["transp_lookup"]):
            continue
        mflags, blend = model["materials"][mat]
        if blend > 1:
            continue
        want.append((bt[0] & 0xFF, shadow_flags2(mflags, blend), 0, bt[3], model["tex_lookup"][bt[9]], bt[5],
                     model["transp_lookup"][bt[11]]))
    for k, g in enumerate(got):
        if g[3] >= nsec:
            rep.bad("shadow batch %d: submesh %d of %d", k, g[3], nsec)
        if g[4] >= model["textures"]:
            rep.bad("shadow batch %d: texture %d of %d", k, g[4], model["textures"])
        if g[5] != 0xFFFF and g[5] >= model["colors"]:
            rep.bad("shadow batch %d: colour %d of %d", k, g[5], model["colors"])
        if g[6] >= model["tex_weights"]:
            rep.bad("shadow batch %d: transparency %d of %d", k, g[6], model["tex_weights"])
    if [tuple(g) for g in got] != want:
        msg = "shadow batches %s, the client's rule gives %s" % (got, want)
        if ours:
            rep.bad(msg)
        else:
            rep.note(msg + " (borrowed skin, made for its own model's materials)")
    if bcm and ours:
        rep.bad("boneCountMax %d (the client's static skins carry 0)", bcm)
    rep.info.update(lookup=nl, triangles=ni // 3, submeshes=nsec, batches=nbt, triangles_list=[
        (lk[idx[i]], lk[idx[i + 1]], lk[idx[i + 2]]) for i in range(0, ni - ni % 3, 3)
        if idx[i] < nl and idx[i + 1] < nl and idx[i + 2] < nl])


def check(data, loose_skins=None, game_file=None, label="model"):
    """validate_m2, raising ValidationError with every problem."""
    rep = validate_m2(data, loose_skins, game_file, label)
    rep.raise_if_bad()
    return rep
