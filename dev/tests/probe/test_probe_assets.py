"""The loose-model probe files (dev/generators/gen_probe.py) and the model writer / validator behind them
(dev/generators/m2_write.py), against the installed client's own files (casc_local).

Covers: the generator writes every probe file and each passes the strict validator from disk; the copy is the
client's spells/unitcube.m2 byte for byte; the writer reproduces Blizzard's files byte for byte (skins re-written,
a skin built from the unit cube's mesh, static models re-laid out); the probe geometry (the box's size and outward
faces, the checkerboard's 32 cells, the depth square, its material and exactly-white texture); the legacy file's
texture name resolving in the client's root; the validator refusing broken files (offsets, counts, alignment,
indices, ranges, bounds, chunks, skins, sizes, centre bones, coordinate combos, Blizzard's LOD layout) and noting
bytes nothing points at; nothing written when a check fails; release.py leaving the probe out of releases.

Run: luaenv\\Scripts\\python.exe tests\\probe\\test_probe_assets.py [-k name]
Needs the installed client (C:\\World of Warcraft, product wow_anniversary); without it every case is skipped.
"""
import os
import shutil
import struct
import sys
import tempfile
import time
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
DEV = os.path.dirname(os.path.dirname(HERE))
for p in (os.path.join(DEV, "generators"), os.path.join(DEV, "tools")):
    if p not in sys.path:
        sys.path.insert(0, p)

import casc_local  # noqa: E402
import m2_write as W  # noqa: E402
import gen_probe as G  # noqa: E402

_CASES = []
TMP = tempfile.mkdtemp(prefix="dz_probe_")
_BUILT = {}


def case(fn):
    _CASES.append(fn)
    return fn


def built():
    """The generator's output in a temp folder (once per run): {name: bytes read back from disk}."""
    if not _BUILT:
        out = os.path.join(TMP, "Probe")
        G.generate(out)
        for name in os.listdir(out):
            with open(os.path.join(out, name), "rb") as fh:
                _BUILT[name] = fh.read()
    return _BUILT


def game(fid):
    return casc_local.read_fid(fid)


def problems(data, skins=None, game_file=game):
    return W.validate_m2(data, loose_skins=skins, game_file=game_file).problems


def refused(data, needle, skins=None):
    p = problems(data, skins)
    assert p, "the validator accepted a broken file (expected %r)" % needle
    assert any(needle in x for x in p), "expected a problem mentioning %r, got %s" % (needle, p)


def md_off(data):
    """File offset of the MD20 block (8 in a chunked file)."""
    return 8 if data[:4] == b"MD21" else 0


def poke(data, off, fmt, *vals):
    b = bytearray(data)
    struct.pack_into("<" + fmt, b, off, *vals)
    return bytes(b)


# ---------------------------------------------------------------------------------------------------------------
# The generator's files
# ---------------------------------------------------------------------------------------------------------------

@case
def generator_writes_every_file_and_each_passes_from_disk():
    files = built()
    assert sorted(files) == sorted(G.NAMES), sorted(files)
    skins = {"probe_box_noskin.m2": {0: files["probe_box_noskin00.skin"]},
             "probe_box_md20.m2": {0: files["probe_box_md2000.skin"]}}
    for name in G.NAMES:
        if not name.endswith(".m2"):
            continue
        rep = W.validate_m2(files[name], loose_skins=skins.get(name), game_file=game, label=name)
        assert rep.ok, rep.problems
    text = files["manifest.txt"].decode("ascii")
    for name in G.NAMES[:-1]:
        assert name in text, name
    assert "bounds x 0..3, y 0..1, z 0..2" in text and "bounds x 0..4, y 0..4, z 0..0" in text


@case
def copy_is_the_clients_unit_cube_byte_for_byte():
    assert built()["probe_copy.m2"] == game(G.UNITCUBE)
    assert casc_local.build_name() in built()["manifest.txt"].decode("ascii")


@case
def boxes_are_3_by_1_by_2_with_outward_faces():
    files = built()
    for name, skins in (("probe_box_md21.m2", None), ("probe_box_noskin.m2", {0: files["probe_box_noskin00.skin"]}),
                        ("probe_box_md20.m2", {0: files["probe_box_md2000.skin"]})):
        rep = W.validate_m2(files[name], loose_skins=skins, game_file=game)
        assert rep.info["box"] == (0.0, 0.0, 0.0, 3.0, 1.0, 2.0), rep.info["box"]
        pts = rep.info["points"]
        assert sorted(set(pts)) == sorted({(x, y, z) for x in (0.0, 3.0) for y in (0.0, 1.0) for z in (0.0, 2.0)})
        tris = rep.info["skin_reports"][0].info["triangles_list"]
        assert len(tris) == 12
        for a, b, c in tris:
            p, q, r = pts[a], pts[b], pts[c]
            u = [q[k] - p[k] for k in range(3)]
            v = [r[k] - p[k] for k in range(3)]
            n = (u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0])
            mid = [(p[k] + q[k] + r[k]) / 3 - (1.5, 0.5, 1.0)[k] for k in range(3)]
            assert sum(n[k] * mid[k] for k in range(3)) > 0, (name, (a, b, c))
    md21 = W.M2.parse(files["probe_box_md21.m2"])
    assert md21.file_ids("SFID") == [G.UNITCUBE_SKIN] and md21.file_ids("TXID") == [G.WHITE1]
    noskin = W.M2.parse(files["probe_box_noskin.m2"])
    assert [t for t, _ in noskin.chunks] == ["MD21", "TXAC", "LDV1", "TXID"]
    assert noskin.md == md21.md                         # the same body; only the SFID chunk is gone
    assert files["probe_box_md20.m2"][:4] == b"MD20"
    md20 = W.M2.parse(files["probe_box_md20.m2"])
    assert md20.legacy and md20.version == 274
    assert [v.pos for v in md20.vertices()] == [v.pos for v in md21.vertices()]


@case
def own_skins_differ_from_the_cubes_only_in_the_box_geometry():
    files = built()
    cube = W.Skin.parse(game(G.UNITCUBE_SKIN))
    own = W.Skin.parse(files["probe_box_noskin00.skin"])
    assert files["probe_box_noskin00.skin"] == files["probe_box_md2000.skin"]
    assert (own.lookup, own.indices, own.bones, own.batches, own.shadows) == (
        cube.lookup, cube.indices, cube.bones, cube.batches, cube.shadows)
    s = own.sections[0]
    assert s.center == (1.5, 0.5, 1.0) and s.sort_center == (1.5, 0.5, 1.0)
    assert abs(s.sort_radius - (3 ** 2 + 1 + 2 ** 2) ** 0.5 / 2) < 1e-6
    assert s._replace(center=0, sort_center=0, sort_radius=0) == cube.sections[0]._replace(
        center=0, sort_center=0, sort_radius=0)


@case
def checkerboard_fills_32_cells_of_half_a_yard():
    rep = W.validate_m2(built()["probe_checker.m2"], game_file=game)
    assert rep.ok, rep.problems
    pts = rep.info["points"]
    tris = rep.info["skin_reports"][0].info["triangles_list"]
    cells = {}
    for a, b, c in tris:
        p, q, r = pts[a], pts[b], pts[c]
        area = ((q[0] - p[0]) * (r[1] - p[1]) - (q[1] - p[1]) * (r[0] - p[0])) / 2
        if area == 0 and p == q == r:
            continue
        assert area > 0 and p[2] == q[2] == r[2] == 0.0, (p, q, r)
        cx = sum(x[0] for x in (p, q, r)) / 3
        cy = sum(x[1] for x in (p, q, r)) / 3
        cell = (int(cx // 0.5), int(cy // 0.5))
        assert all(cell[0] * 0.5 <= x[0] <= cell[0] * 0.5 + 0.5 and cell[1] * 0.5 <= x[1] <= cell[1] * 0.5 + 0.5
                   for x in (p, q, r)), (cell, p, q, r)
        cells[cell] = cells.get(cell, 0.0) + area
    want = {(i, j) for i in range(8) for j in range(8) if (i + j) % 2 == 0}
    assert set(cells) == want, sorted(set(cells) ^ want)
    assert all(abs(a - 0.25) < 1e-9 for a in cells.values()), cells
    m = W.M2.parse(built()["probe_checker.m2"])
    assert m.file_ids("SFID") == [G.CHECKER_SKIN] and m.file_ids("TXID") == W.M2.parse(game(G.CHECKER_MODEL)).file_ids("TXID")
    assert m.arr("coll_indices") == (0, 0) and m.materials() == [(0x4, 0)]
    assert not any("not referenced" in n for n in rep.notes), rep.notes      # (re-laid out after the collision went)
    assert len(m.md) < len(W.M2.parse(game(G.CHECKER_MODEL)).md)


@case
def depth_square_is_unlit_mod_over_an_exactly_white_texture():
    files = built()
    rep = W.validate_m2(files["probe_depth.m2"], game_file=game)
    assert rep.ok, rep.problems
    assert rep.info["materials"] == [(0x7, 5)]          # unlit, unfogged, two-sided; 0x8 / 0x10 clear: depth on
    assert rep.info["textures_files"] == [G.WHITE]
    assert rep.info["box"] == (0.0, 0.0, 0.0, 4.0, 4.0, 0.0)
    assert G.white_texels(game(G.WHITE))
    assert not G.white_texels(game(G.WHITE1))           # (spells/white1.blp is 255, 251, 255: not colour-neutral)
    pts = rep.info["points"]
    drawn = [(a, b, c) for a, b, c in rep.info["skin_reports"][0].info["triangles_list"]
             if len({pts[a], pts[b], pts[c]}) == 3]
    assert len(drawn) == 2
    assert {pts[i] for t in drawn for i in t} == {(0.0, 0.0, 0.0), (4.0, 0.0, 0.0), (4.0, 4.0, 0.0), (0.0, 4.0, 0.0)}


@case
def legacy_texture_name_resolves_in_the_clients_root():
    hashes = G.root_name_hashes([G.WHITE1, G.UNITCUBE, G.UNITCUBE_SKIN])
    assert G.name_hash("spells/unitcube.m2") in hashes[G.UNITCUBE]
    assert G.name_hash("spells/unitcube00.skin") in hashes[G.UNITCUBE_SKIN]
    assert G.name_hash(G.WHITE1_NAME) in hashes[G.WHITE1]
    rep = W.validate_m2(built()["probe_box_md20.m2"], loose_skins={0: built()["probe_box_md2000.skin"]})
    assert rep.info["textures_files"] == [G.WHITE1_NAME] and rep.info["chunks"] == []


# ---------------------------------------------------------------------------------------------------------------
# The writer against Blizzard's own files
# ---------------------------------------------------------------------------------------------------------------

@case
def skins_rewrite_byte_for_byte():
    for fid in (G.UNITCUBE_SKIN, G.CHECKER_SKIN, 494450):
        data = game(fid)
        assert W.Skin.parse(data).to_bytes() == data, fid


@case
def skin_built_from_the_unit_cubes_mesh_is_blizzards():
    cube = W.M2.parse(game(G.UNITCUBE))
    template = W.Skin.parse(game(G.UNITCUBE_SKIN))
    skin = W.single_mesh_skin(cube, G.triangles(template), template)
    assert skin.to_bytes() == game(G.UNITCUBE_SKIN)


@case
def static_models_relayout_byte_for_byte():
    for fid in (G.UNITCUBE, G.CHECKER_MODEL, 189641, 166046, 2199509, 219356):
        data = game(fid)
        assert W.relayout(W.M2.parse(data)).to_bytes() == data, fid
    cube = W.M2.parse(game(G.UNITCUBE))
    bigger = W.relayout(cube, vertices=cube.vertices() * 2)          # a new vertex count moves everything after
    assert bigger.arr("vertices")[0] == 48
    rep = W.validate_m2(bigger.to_bytes())                            # (no skin check: the cube's skin is borrowed)
    assert rep.ok, rep.problems


@case
def reference_models_pass_the_validator():
    for fid in (G.UNITCUBE, G.CHECKER_MODEL, 189641):
        rep = W.validate_m2(game(fid), game_file=game, label=str(fid))
        assert rep.ok, rep.problems
        assert not rep.notes, rep.notes


@case
def writer_refuses_what_it_cannot_place():
    cube = W.M2.parse(game(G.UNITCUBE))
    for fn, needle in ((lambda: cube.set_vertices(cube.vertices()[:-1]), "relayout"),
                       (lambda: cube.set_material(3, 0, 0), "no material"),
                       (lambda: cube.set_material(0, 0, 9), "blend"),
                       (lambda: cube.drop_chunk("SKID"), "no SKID"),
                       (lambda: cube.set_chunk("AFID", b""), "adds none"),
                       (lambda: W.legacy_md20(cube, []), "one name per texture")):
        try:
            fn()
        except W.M2Error as e:
            assert needle in str(e), (needle, str(e))
        else:
            raise AssertionError("accepted: " + needle)
    creature = W.M2.parse(game(G.CHECKER_MODEL))
    struct.pack_into("<I", creature.md, creature.arr("bones")[1] + 16 + 4, 1)     # a translation key slot
    try:
        W.relayout(creature)
    except W.M2Error as e:
        assert "animated" in str(e)
    else:
        raise AssertionError("relayout accepted animated bones")


# ---------------------------------------------------------------------------------------------------------------
# The validator refuses broken files
# ---------------------------------------------------------------------------------------------------------------

@case
def validator_refuses_broken_headers_and_chunks():
    box = built()["probe_box_md21.m2"]
    o = md_off(box)
    refused(box[:-3], "runs past the end")
    refused(b"MD22" + box[4:], "neither MD21 nor MD20")
    refused(poke(box, o + 4, "I", 273), "version 273")
    refused(poke(box, o + W.ARRAY["vertices"][0], "2I", 24, 500), "not on 16 bytes")
    refused(poke(box, o + W.ARRAY["vertices"][0], "2I", 2000, 496), "runs past the block")
    refused(poke(box, o + W.ARRAY["materials"][0], "2I", 1, 1648), "overlaps")
    refused(poke(box, o + W.ARRAY["particles"][0], "2I", 1, 1808), "never ships")
    refused(poke(box, o + 0x10, "I", 0x202088), "extended header")
    sfid = box.index(b"SFID")
    refused(box[:sfid] + b"SKID" + box[sfid + 4:], "never produces")
    txac = box.index(b"TXAC")
    refused(box[:txac] + b"TXAC\x04\0\0\0\0\0\0\0" + box[txac + 10:], "TXAC holds 4 bytes for 1 materials")
    refused(poke(box, txac + 4, "I", 4000), "runs past the end of the file")
    ldv = box.index(b"LDV1")
    refused(poke(box, ldv + 10, "H", 2), "LDV1 says 2 LODs")
    refused(poke(box, sfid + 8, "I", 999999999), "not in this client")
    refused(poke(box, box.index(b"TXID") + 8, "I", G.UNITCUBE), "not a BLP")
    m = W.M2.parse(box)                                 # (the writer itself refuses such a block: built by hand)
    md = bytes(m.md[:-8])
    rest = b"".join(t.encode() + struct.pack("<I", len(p)) + p for t, p in m.chunks if t != "MD21")
    refused(b"MD21" + struct.pack("<I", len(md)) + md + rest, "multiple of 16")
    try:
        m.md = m.md[:-8]
        m.to_bytes()
    except W.M2Error as e:
        assert "multiple of 16" in str(e)
    else:
        raise AssertionError("the writer wrote a block of %d bytes" % len(m.md))


@case
def validator_refuses_bad_contents():
    box = built()["probe_box_md21.m2"]
    o = md_off(box)
    vo = o + W.M2.parse(box).arr("vertices")[1]
    refused(poke(box, vo + 12, "4B", 200, 0, 0, 0), "add up to 200")
    refused(poke(box, vo, "f", float("nan")), "not finite")
    refused(poke(box, vo + 20, "3f", 0.0, 0.0, 2.0), "normal length")
    refused(poke(box, o + W.OFF_BOX, "6f", 0, 0, 0, 2.5, 1, 2), "does not hold every vertex")
    refused(poke(box, o + W.OFF_RADIUS, "f", 1.0), "radius")
    seq = o + W.M2.parse(box).arr("sequences")[1]
    refused(poke(box, seq + 12, "I", 0x800), "flag 0x20")
    refused(poke(box, seq + 32, "6f", 0, 0, 0, 1, 1, 1), "do not hold the vertices")
    mat = o + W.M2.parse(box).arr("materials")[1]
    refused(poke(box, mat, "HH", 0x4, 8), "blend mode 8")
    refused(poke(box, mat, "HH", 0x804, 0), "flags 0x804")
    tl = o + W.M2.parse(box).arr("tex_lookup")[1]
    refused(poke(box, tl, "h", 3), "tex_lookup[0] = 3")
    bl = o + W.M2.parse(box).arr("bone_lookup")[1]
    refused(poke(box, bl, "h", 1), "bone_lookup[0] = 1")
    bone = o + W.M2.parse(box).arr("bones")[1]
    refused(poke(box, bone + 8, "h", 0), "parent 0")
    tex = o + W.M2.parse(box).arr("textures")[1]
    refused(poke(box, tex + 4, "I", 0x10), "flags 0x10")
    refused(poke(box, o + W.ARRAY["textures"][0], "2I", 2, 1648), "TXID holds 4 bytes for 2 textures")


@case
def validator_refuses_bad_skins():
    files = built()
    noskin, skin = files["probe_box_noskin.m2"], files["probe_box_noskin00.skin"]
    assert not problems(noskin, {0: skin})
    refused(noskin, "no loose skin 00")
    refused(files["probe_box_md21.m2"], "loose skins given", skins={0: skin})
    s = W.Skin.parse(skin)

    def with_skin(**kw):
        new = W.Skin(**dict(dict(lookup=s.lookup, indices=s.indices, bones=s.bones, sections=s.sections,
                                 batches=s.batches, shadows=s.shadows, bone_count_max=s.bone_count_max), **kw))
        return {0: new.to_bytes()}

    refused(noskin, "the model has 24 vertices", skins=with_skin(lookup=[24] + s.lookup[1:]))
    refused(noskin, "the lookup has 24 entries", skins=with_skin(indices=[24] + s.indices[1:]))
    refused(noskin, "not whole triangles", skins=with_skin(indices=s.indices[:-1]))
    refused(noskin, "past the lookup", skins=with_skin(sections=[s.sections[0]._replace(vertex_count=30)]))
    refused(noskin, "indices 0..39", skins=with_skin(sections=[s.sections[0]._replace(index_count=39)]))
    refused(noskin, "outside its vertices", skins=with_skin(sections=[s.sections[0]._replace(vertex_count=20)]))
    refused(noskin, "sort radius", skins=with_skin(sections=[s.sections[0]._replace(sort_radius=1.0)]))
    refused(noskin, "material 1 of 1", skins=with_skin(batches=[s.batches[0]._replace(material=1)]))
    refused(noskin, "submesh 1 of 1", skins=with_skin(batches=[s.batches[0]._replace(section=1)]))
    refused(noskin, "past the texture lookup", skins=with_skin(batches=[s.batches[0]._replace(texture_count=2)]))
    refused(noskin, "transparency 1 of 1", skins=with_skin(batches=[s.batches[0]._replace(weight_combo=1)]))
    refused(noskin, "colour 0 of 0", skins=with_skin(batches=[s.batches[0]._replace(color=0)]))
    refused(noskin, "shadow batches", skins=with_skin(shadows=[]))
    refused(noskin, "1 bone entries for 24", skins=with_skin(bones=s.bones[:1]))
    refused(noskin, "boneCountMax", skins=with_skin(bone_count_max=64))
    refused(noskin, "multiple of 16", skins={0: skin[:-4]})
    refused(noskin, "magic", skins={0: b"NIKS" + skin[4:]})
    refused(noskin, "out of place", skins={0: poke(skin, 12, "2I", 36, 120)})
    refused(noskin, "centre bone 1 of 1", skins=with_skin(sections=[s.sections[0]._replace(center_bone=1)]))
    # the coordinate combo table is empty (as in every client model): 0 or 65535 only
    refused(noskin, "texture coordinate combo 1", skins=with_skin(batches=[s.batches[0]._replace(coord_combo=1)]))
    assert not problems(noskin, with_skin(batches=[s.batches[0]._replace(coord_combo=0xFFFF)]))


@case
def validator_notes_dead_bytes_and_refuses_lod_layouts():
    sup = W.M2.parse(game(G.CHECKER_MODEL))
    sup.clear_collision()
    rep = W.validate_m2(sup.to_bytes(), game_file=game)
    assert rep.ok and any("not referenced" in n for n in rep.notes), (rep.problems, rep.notes)
    rep = W.validate_m2(W.relayout(sup).to_bytes(), game_file=game)
    assert rep.ok and not any("not referenced" in n for n in rep.notes), (rep.problems, rep.notes)
    refused(game(192637), "Blizzard's LOD layout")       # (one skin profile, SFID + 3 LOD skins)


@case
def nothing_is_written_when_a_check_fails():
    out = os.path.join(TMP, "refused")
    real = G.build

    def broken():
        files, about, facts = real()
        b = bytearray(files["probe_checker.m2"])
        struct.pack_into("<f", b, 8 + W.OFF_RADIUS, 0.5)          # a radius too small for the board
        files["probe_checker.m2"] = bytes(b)
        return files, about, facts

    G.build = broken
    try:
        G.generate(out)
    except G.ProbeError as e:
        assert "probe_checker.m2" in str(e) and "radius" in str(e), str(e)
    else:
        raise AssertionError("the generator wrote a broken file")
    finally:
        G.build = real
    assert not os.path.exists(out) or not os.listdir(out)


@case
def release_leaves_the_probe_out():
    import release
    probe = os.path.join(TMP, "addon")
    os.makedirs(os.path.join(probe, "Media", "Probe"))
    os.makedirs(os.path.join(probe, "Core"))
    for rel in ("Media/Probe/probe_copy.m2", "Media/Probe/manifest.txt", "Core/A.lua", "Media/Other.blp"):
        with open(os.path.join(probe, *rel.split("/")), "wb") as fh:
            fh.write(b"x")
    assert release.all_files(probe) == ["Core/A.lua", "Media/Other.blp"], release.all_files(probe)
    assert not any(f.startswith("Media/Probe/") for f in release.all_files(release.ADDON_DIR))


def run_all(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    flt = argv[argv.index("-k") + 1] if "-k" in argv else None
    if not os.path.exists(os.path.join(casc_local.BASE, ".build.info")):
        print("SKIP every case: no installed client at %s" % casc_local.BASE)
        print("-- probe assets: 0 case(s), 0 passed, 0 failed (skipped)")
        return 0
    failed, passed, t_all = [], 0, time.time()
    try:
        for fn in _CASES:
            if flt and flt not in fn.__name__:
                continue
            t0 = time.time()
            try:
                fn()
            except Exception as e:  # noqa: BLE001 - report every failure, keep going
                failed.append(fn.__name__)
                print("FAIL %s (%.2fs)" % (fn.__name__, time.time() - t0))
                msg = "".join(traceback.format_exception(type(e), e, e.__traceback__))
                print("    " + msg.replace("\n", "\n    ").rstrip())
            else:
                passed += 1
                print("PASS %s (%.2fs)" % (fn.__name__, time.time() - t0))
    finally:
        shutil.rmtree(TMP, ignore_errors=True)
    print("-- probe assets: %d case(s), %d passed, %d failed (%.1fs)" % (
        passed + len(failed), passed, len(failed), time.time() - t_all))
    if failed:
        print("-- failed: " + ", ".join(failed))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(run_all())
