"""In-game updates, part 1: the primitives and the boot loader (Core/Sha256.lua, Core/Boot.lua, Core/Init.lua).

Covers: SHA-256 / Adler-32 / printable encoding / signature parity between the addon and dev/tools/patchlib.py;
manifest parsing and its refusals; and every way a stored patch can meet the loader: none, applied (changed, new
and deleted files), another build, kill switch, damaged text, syntax error, load error (safe mode), startup errors
(rollback offer), a client that ignores LoadSavedVariablesFirst, the development copy, and a patch that replaces
every file.

Run: luaenv\\Scripts\\python.exe tests\\patch\\test_patch_boot.py [-k name]
"""
import hashlib
import os
import random
import sys
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from _patchkit import (case, run_all, World, Client, patchlib, release, key, source_copy, release_of, make,  # noqa: E402
                       staged, simple_pair, boot_state, member, read, write, append, replace, toc_add, toc_remove,
                       guard, set_version, SOURCE)


def lua_bytes(c, code, *args):
    v = c.eval(code, *args)
    return v if isinstance(v, bytes) else v.encode("latin-1")


def hexarg(b):
    return b.hex()


UNHEX = "local function unhex(h) return (h:gsub('..', function(x) return string.char(tonumber(x, 16)) end)) end "


def dev_client():
    w = World(addon_dir=source_copy("dev"))
    c = Client(w, "Alice")
    c.load_addon()
    w.tick(1)
    return w, c


# ---------------------------------------------------------------------------------------------------------------
# Primitives
# ---------------------------------------------------------------------------------------------------------------

@case
def sha256_matches_hashlib():
    w, c = dev_client()
    rng = random.Random(1)
    lengths = list(range(0, 70)) + [119, 120, 127, 128, 129, 255, 256, 1000, 4096, 4097, 20000]
    for n in lengths:
        data = bytes(rng.getrandbits(8) for _ in range(n))
        got = c.eval(UNHEX + "return ns.Sha256.Hex(ns.Sha256.Sum(unhex(...)))", hexarg(data))
        assert got == hashlib.sha256(data).hexdigest(), n
    assert c.eval("return ns.Sha256.Hex(ns.Sha256.Sum('abc'))") == \
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    # incremental, fed in odd slices
    data = bytes(rng.getrandbits(8) for _ in range(5000))
    got = c.eval(UNHEX + """local s = unhex(...)
      local st = ns.Sha256.New()
      local pos, step = 1, 1
      while pos <= #s do
        ns.Sha256.Update(st, s:sub(pos, pos + step - 1))
        pos = pos + step
        step = (step * 7) % 97 + 1
      end
      return ns.Sha256.Hex(ns.Sha256.Final(st))""", hexarg(data))
    assert got == hashlib.sha256(data).hexdigest()
    assert c.eval("return ns.Sha256.Hex(ns.Sha256.FromHex('00ff10'))") == "00ff10"
    assert c.eval("return ns.Sha256.FromHex('0g')") is None
    w.assert_no_errors()


@case
def adler32_matches_zlib():
    w, c = dev_client()
    rng = random.Random(2)
    for n in [0, 1, 2, 7, 8, 9, 15, 16, 17, 100, 5552, 5553, 70000]:
        data = bytes(rng.getrandbits(8) for _ in range(n))
        got = c.eval(UNHEX + "return DisasterZoneBoot.Adler32(unhex(...))", hexarg(data))
        assert got == (zlib.adler32(data) & 0xFFFFFFFF), n
    worst = b"\xff" * 300000        # largest sums: no precision loss
    assert c.eval("return DisasterZoneBoot.Adler32(string.rep('\\255', 300000))") == (zlib.adler32(worst) & 0xFFFFFFFF)
    w.assert_no_errors()


@case
def print_encoding_matches_libdeflate():
    w, c = dev_client()
    rng = random.Random(3)
    for n in list(range(0, 20)) + [255, 1000, 3001]:
        data = bytes(rng.getrandbits(8) for _ in range(n))
        enc = patchlib.encode_for_print(data)
        got = c.eval(UNHEX + "return LibStub('LibDeflate'):EncodeForPrint(unhex(...))", hexarg(data))
        assert got == enc, n
        assert patchlib.decode_for_print(enc) == data
        if n != 0:
            back = c.eval("local s = LibStub('LibDeflate'):DecodeForPrint(...) "
                          "return (s:gsub('.', function(ch) return string.format('%02x', ch:byte()) end))", enc)
            assert back == data.hex(), n
    # the addon inflates what Python deflated
    src = read(SOURCE, "Core/Util.lua").encode("utf-8")
    z = patchlib.encode_for_print(patchlib.deflate_raw(src))
    n, adler = c.eval("local L = LibStub('LibDeflate') local s = L:DecompressDeflate(L:DecodeForPrint(...)) "
                      "return #s, DisasterZoneBoot.Adler32(s)", z)
    assert n == len(src) and adler == patchlib.adler32(src)
    w.assert_no_errors()


VERIFY = UNHEX + """local msg, sig, seed, root, h = ...
  local leaf = ns.Patch.VerifySignature(unhex(msg), unhex(sig), { seed = seed, root = root, h = h })
  return leaf"""


@case
def signature_verifies_and_rejects():
    w, c = dev_client()
    k = key()
    msg = b"CDLP1\nseq=3\nversion=1.2.3\n"
    for leaf in (0, 1, 7, 15):
        sig = patchlib.sign(k, leaf, msg)
        assert len(sig) == patchlib.sig_len(k["height"])
        assert patchlib.verify(k["seed"], k["root"], k["height"], msg, sig)
        assert c.eval(VERIFY, msg.hex(), sig.hex(), k["seed"], k["root"], k["height"]) == leaf
    sig = patchlib.sign(k, 5, msg)

    def lua_ok(m, s, kk=k):
        return c.eval(VERIFY, m.hex(), s.hex(), kk["seed"], kk["root"], kk["height"]) is not None
    assert lua_ok(msg, sig)
    assert not lua_ok(msg + b" ", sig)                                # other message
    assert not lua_ok(msg[:-1] + b"X", sig)
    for pos in (0, 3, 4, 40, 4 + 66 * 32 + 5, 4 + 67 * 32 + 1, len(sig) - 1):   # leaf, chains, auth path
        bad = bytearray(sig)
        bad[pos] ^= 1
        assert not lua_ok(msg, bytes(bad)), pos
        assert not patchlib.verify(k["seed"], k["root"], k["height"], msg, bytes(bad)), pos
    assert not lua_ok(msg, sig[:-1])                                  # truncated
    assert not lua_ok(msg, sig + b"\0")
    other = key("other")
    assert not lua_ok(msg, patchlib.sign(other, 5, msg))              # signed with another key
    assert not lua_ok(msg, sig, other)
    # a signature made for one leaf does not pass as another leaf's
    forged = bytearray(sig)
    forged[3] = 6
    assert not lua_ok(msg, bytes(forged))
    w.assert_no_errors()


def manifest_lines(**over):
    f = "F\tCore/Util.lua\t10\t123\t20\t" + "a" * 64
    lines = ["CDLP1", "seq=2", "version=1.0.1", "base=abcdef0123456789", "pack=1", f]
    return lines


@case
def manifest_parsing():
    w, c = dev_client()

    def parse(text):
        return c.eval_py("local m, why = ns.Patch.ParseManifest(...) return { m = m, why = why }", text)
    good = "\n".join(manifest_lines() + ["N\tCore/New.lua\t5\t9\t8\t" + "b" * 64 + "\tCore/Util.lua",
                                         "N\tCore/Tail.lua\t5\t9\t8\t" + "c" * 64 + "\t", "D\tCore/Old.lua"]) + "\n"
    r = parse(good)["m"]
    assert r["seq"] == 2 and r["version"] == "1.0.1" and r["base"] == "abcdef0123456789" and r["pack"] == 1
    assert [e["k"] for e in r["entries"]] == ["F", "N", "N", "D"]
    assert len(r["items"]) == 3 and r["items"][1]["b"] == "Core/Util.lua" and r["items"][2]["b"] == ""
    assert r["items"][0]["n"] == 1 and r["total"] == 20

    def bad(lines, why=None):
        res = parse("\n".join(lines) + "\n")
        assert res.get("m") is None, lines
    base = manifest_lines()
    bad(["CDLP2"] + base[1:])
    bad(base[:1] + ["seq=0"] + base[2:])
    bad(base[:1] + ["seq=x"] + base[2:])
    bad(base[:2] + ["version=1.0 beta"] + base[3:])
    bad(base[:3] + ["base=ab-cd"] + base[4:])
    bad(base[:4] + ["pack=-1"] + base[5:])
    bad(base[:5] + ["X\tCore/Util.lua"])
    bad(base[:5] + ["F\tCore/Util.lua\t10\t123\t20\t" + "A" * 64])          # hash must be lowercase hex
    bad(base[:5] + ["F\tCore/Util.lua\t10\t123\t20\t" + "a" * 63])
    bad(base[:5] + ["F\tCore/Util.lua\t10\t123\t0\t" + "a" * 64])           # empty encoding
    bad(base[:5] + ["F\tCore/Util.lua\t9999999\t123\t20\t" + "a" * 64])     # over the per-file cap
    bad(base[:5] + ["F\tCore/Util.lua\t1e3\t123\t20\t" + "a" * 64])
    bad(base[:5] + ["F\t../evil.lua\t10\t123\t20\t" + "a" * 64])
    bad(base[:5] + ["F\tCore\\Util.lua\t10\t123\t20\t" + "a" * 64])
    bad(base[:5] + ["F\t/Core/Util.lua\t10\t123\t20\t" + "a" * 64])
    bad(base[:5] + ["F\tCore//Util.lua\t10\t123\t20\t" + "a" * 64])
    bad(base[:5] + ["F\tCore/Util.txt\t10\t123\t20\t" + "a" * 64])
    bad(base[:5] + ["F\tCore/Boot.lua\t10\t123\t20\t" + "a" * 64])          # the loader is never patched
    bad(base[:5] + ["F\tCore/BuildInfo.lua\t10\t123\t20\t" + "a" * 64])
    bad(base[:5] + ["F\tLibs/LibStub/LibStub.lua\t10\t123\t20\t" + "a" * 64])
    bad(base + [base[5]])                                                    # same path twice
    bad(base + ["D\tCore/Util.lua"])
    bad(base[:5] + ["D\tCore/Old.lua\textra"])
    bad(base[:5] + ["N\tCore/New.lua\t5\t9\t8\t" + "b" * 64])               # N needs its slot field
    bad(base[:5] + ["N\tCore/New.lua\t5\t9\t8\t" + "b" * 64 + "\t../x.lua"])
    bad(base[:4])
    assert parse("\n".join(base)).get("m") is None                           # not terminated by a newline
    assert parse("\n".join(base[:5]) + "\n")["m"]["entries"] in ([], {})     # an update with no files is valid
    w.assert_no_errors()


# ---------------------------------------------------------------------------------------------------------------
# Boot loader
# ---------------------------------------------------------------------------------------------------------------

@case
def no_patch_runs_from_disk():
    base_dir, record, new_dir = simple_pair()
    w = World(addon_dir=base_dir)
    c = member(w, "Alice", base_dir)
    c.load_addon()
    w.tick(2)
    s = boot_state(c)
    assert s["state"] == "none" and s["applied"] is None and s["build"] == record["build"]
    assert s["version"] == s["disk"] and s["init"] and s["loggedIn"]
    assert s["sv"] is None                       # nothing was saved before this session: not known yet
    assert c.eval("return ns.Util.PATCH_MARK") is None
    assert c.eval("return ns.assetPack") == 1 and c.eval("return ns:HasAssets(1)") is True
    assert c.eval("return ns:HasAssets(2)") is False
    c.relog()
    w.tick(2)
    assert boot_state(c)["sv"] is True           # saved variables were there before the files ran
    w.assert_no_errors()


@case
def client_that_ignores_the_directive():
    base_dir, record, new_dir = simple_pair()
    bundle = make(record, new_dir)
    w = World(addon_dir=base_dir)
    c = member(w, "Alice", base_dir, sv=staged(bundle), sv_before_files=False)
    c.load_addon()
    w.tick(2)
    s = boot_state(c)
    assert s["applied"] is None and s["version"] == s["disk"], s      # the stored patch could not be seen in time
    assert s["sv"] is False
    assert c.eval("return ns.Util.PATCH_MARK") is None
    # the saved table the client assigned afterwards is the one that is written to (nothing is lost)
    assert c.eval("return DisasterZonePatchDB.active.seq") == 1
    st = c.eval_py("return ns.Patch:GetStatus()")
    assert st.get("ready") is None                                     # no "reload to use it" when it cannot apply
    lines = c.eval_py("return DisasterZoneBoot.StatusLines()")
    assert any("cannot apply" in l for l in lines), lines
    c.relog()
    w.tick(2)
    assert boot_state(c)["sv"] is False and c.eval("return DisasterZonePatchDB.active.seq") == 1
    w.assert_no_errors()


@case
def patch_applies_and_survives_relog():
    base_dir, record, new_dir = simple_pair(mark="v2", version="9.9.9")
    bundle = make(record, new_dir)
    assert [(i["kind"], i["path"]) for i in bundle["items"]] == [("F", "Core/Util.lua")]
    w = World(addon_dir=base_dir)
    c = member(w, "Alice", base_dir, sv=staged(bundle))
    c.load_addon()
    w.tick(2)
    s = boot_state(c)
    assert s["state"] == "applied" and s["applied"]["seq"] == 1 and s["applied"]["files"] == 1, s
    assert s["version"] == "9.9.9" and s["disk"] == record["version"]
    assert c.eval("return ns.Util.PATCH_MARK") == "v2"
    assert s["init"] and s["loggedIn"] and s["errors"] == 0
    assert any("in-game update" in l for l in c.chat_frame), c.chat_frame[-5:]
    assert c.eval("return DisasterZonePatchDB.lastLoad.seq") == 1
    for how in (True, False):
        c.relog(reload=how)
        w.tick(2)
        assert boot_state(c)["state"] == "applied" and c.eval("return ns.Util.PATCH_MARK") == "v2"
    # peers see the patched version
    b = member(w, "Bob", base_dir)
    b.load_addon()
    w.tick(40)
    assert b.eval("for _, e in ipairs(ns.Sync:GetVersions()) do if e.key:find('Alice') then return e.v end end") == "9.9.9"
    w.assert_no_errors()


@case
def new_and_deleted_files():
    order = "DisasterZoneTestOrder = DisasterZoneTestOrder or {} DisasterZoneTestOrder[#DisasterZoneTestOrder + 1] = "

    def base_mods(root):
        write(root, "Core/TestOld.lua", guard("Core/TestOld.lua") + "-- test\n" + order + "'old'\n")
        toc_add(root, "Core/TestOld.lua", "Core/Util.lua")

    def new_mods(root):
        toc_remove(root, "Core/TestOld.lua")
        os.remove(os.path.join(root, "Core", "TestOld.lua"))
        write(root, "Core/TestNewA.lua", guard("Core/TestNewA.lua") + "-- test\nlocal name, ns = ...\n"
              + order + "'A:' .. tostring(name) .. ':' .. tostring(ns.Util ~= nil) .. ':' .. tostring(ns.Dungeon ~= nil)\n")
        toc_add(root, "Core/TestNewA.lua", "Core/Util.lua")           # runs right before Core/Perf.lua (the file after Core/Util.lua)
        write(root, "Core/TestNewB.lua", guard("Core/TestNewB.lua") + "-- test\nlocal name, ns = ...\n"
              + order + "'B:' .. tostring(ns.AzeroUI ~= nil)\n")
        toc_add(root, "Core/TestNewB.lua", "UI/PatchUI.lua")
        # after every other patchable file: only the end marker can run it
        write(root, "Core/TestNewZ.lua", guard("Core/TestNewZ.lua") + "-- test\nlocal name, ns = ...\n"
              + order + "'Z:' .. tostring(ns.AzeroUI ~= nil)\n")
        toc_add(root, "Core/TestNewZ.lua", "Games/Azeromon/UI.lua")
    base_dir, record, new_dir = simple_pair(base_mods=base_mods, new_mods=new_mods)
    bundle = make(record, new_dir)
    kinds = {i["path"]: (i["kind"], i.get("before")) for i in bundle["items"]}
    assert kinds["Core/TestOld.lua"][0] == "D"
    assert kinds["Core/TestNewA.lua"] == ("N", "Core/Perf.lua"), kinds
    assert kinds["Core/TestNewB.lua"][0] == "N" and kinds["Core/TestNewB.lua"][1].startswith("Games/")
    assert kinds["Core/TestNewZ.lua"] == ("N", ""), kinds

    w = World(addon_dir=base_dir)
    plain = member(w, "Plain", base_dir)
    plain.load_addon()
    assert plain.eval_py("return DisasterZoneTestOrder") == ["old"]
    c = member(w, "Alice", base_dir, sv=staged(bundle))
    c.load_addon()
    w.tick(2)
    assert boot_state(c)["state"] == "applied"
    # the deleted file did not run; A ran after Util and before Dungeon; B after the UI; Z after everything
    assert c.eval_py("return DisasterZoneTestOrder") == ["A:DisasterZone:true:false", "B:false", "Z:true"], c.eval_py("return DisasterZoneTestOrder")
    assert c.eval("return ns.Util.PATCH_MARK") == "v2"
    w.assert_no_errors()


@case
def patch_for_another_build_is_ignored_then_dropped():
    base_dir, record, new_dir = simple_pair()
    bundle = make(record, new_dir)
    # the member replaced the addon folder with a different release since the patch was stored
    other_src = source_copy("other", lambda root: append(root, "Core/Util.lua", "\n-- another release\n"))
    other_dir, other_record = release_of(other_src)
    assert other_record["build"] != record["build"]
    w = World(addon_dir=other_dir)
    c = member(w, "Alice", other_dir, sv=staged(bundle))
    c.load_addon()
    w.tick(2)
    s = boot_state(c)
    assert s["state"] == "base" and s["applied"] is None and s["version"] == s["disk"]
    assert c.eval("return ns.Util.PATCH_MARK") is None
    assert c.eval("return DisasterZonePatchDB.active") is None          # dropped at login: it can never apply here
    assert c.eval("return DisasterZonePatchDB.seq") == 1                # the replay floor stays
    w.assert_no_errors()


@case
def kill_switch():
    base_dir, record, new_dir = simple_pair()
    bundle = make(record, new_dir)
    w = World(addon_dir=base_dir)
    c = member(w, "Alice", base_dir, sv=staged(bundle))
    c.load_addon()
    w.tick(2)
    assert boot_state(c)["state"] == "applied"
    c.slash("/dzpatch off")
    assert boot_state(c)["state"] == "applied"          # nothing changes until the reload
    c.relog()
    w.tick(2)
    s = boot_state(c)
    assert s["state"] == "off" and s["applied"] is None and c.eval("return ns.Util.PATCH_MARK") is None
    assert c.eval("return DisasterZonePatchDB.active.seq") == 1   # kept: switching back on needs no download
    c.slash("/dzpatch")                                 # status prints without errors
    assert any("switched off" in l for l in c.chat_frame[-8:]), c.chat_frame[-8:]
    c.slash("/dzpatch on")
    c.relog()
    w.tick(2)
    assert boot_state(c)["state"] == "applied" and c.eval("return ns.Util.PATCH_MARK") == "v2"
    w.assert_no_errors()


def tamper(sv, old, new):
    assert sv.count(old) >= 1, old
    return sv.replace(old, new, 1)


@case
def damaged_text_is_rejected():
    base_dir, record, new_dir = simple_pair()
    bundle = make(record, new_dir)
    sv = tamper(staged(bundle), 'Util.PATCH_MARK = \\"v2\\"', 'Util.PATCH_MARK = \\"vX\\"')
    w = World(addon_dir=base_dir)
    c = member(w, "Alice", base_dir, sv=sv)
    c.load_addon()
    w.tick(2)
    s = boot_state(c)
    assert s["state"] == "rejected" and "checksum" in s["detail"], s
    assert s["applied"] is None and s["version"] == s["disk"] and s["init"]
    assert c.eval("return ns.Util.PATCH_MARK") is None
    assert "checksum" in c.eval("return DisasterZonePatchDB.bad[1]")
    c.relog()
    w.tick(2)
    assert boot_state(c)["state"] == "none"             # the bad patch was dropped at the first login
    assert c.eval("return DisasterZonePatchDB.bad[1]") is not None
    w.assert_no_errors()


@case
def malformed_store_is_ignored():
    base_dir, record, new_dir = simple_pair()
    w = World(addon_dir=base_dir)
    for i, sv in enumerate(["{ active = 5 }", "{ active = { seq = 'x' } }", "{ active = { seq = 1, version = '1' } }",
                            "{ active = { seq = 1, version = '1', base = '%s', files = {}, sums = {}, list = { 7 } } }" % record["build"],
                            "{ active = { seq = 1, version = '1', base = '%s', files = {}, sums = {}, "
                            "list = { { k = 'F', p = 'Core/Util.lua' } } } }" % record["build"],
                            "{ bad = 3, active = { seq = 1, version = '1', base = '%s', files = {}, sums = {}, "
                            "list = { { k = 'Q', p = 'Core/Util.lua' } } } }" % record["build"],
                            "{ seq = 'x', partial = 9, off = false }"]):
        c = member(w, "M%d" % i, base_dir, sv=sv)
        c.load_addon()
        w.tick(2)
        s = boot_state(c)
        assert s["applied"] is None and s["init"] and s["loggedIn"] and s["version"] == s["disk"], (sv, s)
        assert c.eval("return DisasterZonePatchDB.active") is None, sv
    w.assert_no_errors()


@case
def syntax_error_rejects_the_whole_patch():
    def new_mods(root):
        append(root, "Core/Dungeon.lua", "\nlocal x = = 1\n")
    base_dir, record, new_dir = simple_pair(new_mods=new_mods)
    # the tool refuses it ...
    try:
        make(record, new_dir)
        raise AssertionError("release.py accepted a syntax error")
    except release.ReleaseError as e:
        assert "syntax" in str(e)
    # ... so build the bundle by hand, as a publisher with a broken tool would
    entries = [{"kind": "F", "path": p, "src": read(new_dir, p).encode("utf-8")} for p in ("Core/Util.lua", "Core/Dungeon.lua")]
    bundle = patchlib.build_bundle(1, "9.9.9", record["build"], 1, entries, key())
    w = World(addon_dir=base_dir)
    c = member(w, "Alice", base_dir, sv=staged(bundle))
    c.load_addon()
    w.tick(2)
    s = boot_state(c)
    assert s["state"] == "rejected" and "syntax" in s["detail"], s
    assert c.eval("return ns.Util.PATCH_MARK") is None          # not even the good file of that patch ran
    assert s["init"] and s["version"] == s["disk"]
    w.assert_no_errors()


@case
def load_error_enters_safe_mode():
    def new_mods(root):
        append(root, "Core/Dungeon.lua", "\nerror('boom from the patch')\n")
    base_dir, record, new_dir = simple_pair(new_mods=new_mods)
    bundle = make(record, new_dir)
    w = World(addon_dir=base_dir)
    c = member(w, "Alice", base_dir, sv=staged(bundle))
    c.set_saved_variable("DisasterZoneDB", "{ marker = 42 }")
    c.load_addon()
    w.tick(3)
    s = boot_state(c)
    assert s["state"] == "safemode" and s["safe"]["path"] == "Core/Dungeon.lua", s
    assert "boom from the patch" in s["safe"]["err"]
    assert not s["init"] and not s["loggedIn"]                   # nothing started
    assert c.eval("return ns.DB") is None                        # files after the failing one did not run
    assert c.eval("return DisasterZoneDB.marker") == 42                # saved data untouched
    errs = [e for e in c.errors if "boom from the patch" in str(e)]
    assert len(errs) == 1, c.errors                              # reported once (BugSack sees it), nothing else
    assert len(c.errors) == 1, c.errors
    w.clear_errors()
    assert c.eval("return DisasterZoneBootDialog:IsShown()") is True
    assert "failed to load" in c.eval("return DisasterZoneBootDialog.text:GetText()")
    c.slash("/dz")                                              # the main command only explains
    assert any("failed to load" in l for l in c.chat_frame[-3:]), c.chat_frame[-3:]
    c.slash("/dzpatch")                                         # status still works
    assert any("SAFE MODE" in l for l in c.chat_frame[-6:]), c.chat_frame[-6:]
    # events do not reach the half-loaded addon
    c.fire("GROUP_ROSTER_UPDATE")
    c.fire("PLAYER_REGEN_ENABLED")
    w.tick(2)
    w.assert_no_errors()
    # the Reload button reloads; afterwards the installed version runs and the patch is gone
    c.click(c.eval("return DisasterZoneBootDialog.accept"))
    assert c.eval("return __MOCK.reload_requested") is True
    c.relog()
    w.tick(3)
    s = boot_state(c)
    assert s["state"] == "bad" and s["applied"] is None and s["init"] and s["loggedIn"] and s["version"] == s["disk"], s
    assert c.eval("return DisasterZoneDB.marker") == 42
    assert c.eval("return DisasterZonePatchDB.active") is None
    assert "Dungeon.lua" in c.eval("return DisasterZonePatchDB.bad[1]")
    assert c.eval("return DisasterZoneBootDialog") is None
    c.relog()
    w.tick(2)
    assert boot_state(c)["state"] == "none"
    w.assert_no_errors()


@case
def load_error_in_a_new_file_enters_safe_mode():
    def new_mods(root):
        write(root, "Core/TestNew.lua", guard("Core/TestNew.lua") + "-- test\nlocal t = nil\nlocal x = t.field\n")
        toc_add(root, "Core/TestNew.lua", "Core/Constants.lua")
    base_dir, record, new_dir = simple_pair(new_mods=new_mods)
    bundle = make(record, new_dir)
    w = World(addon_dir=base_dir)
    c = member(w, "Alice", base_dir, sv=staged(bundle))
    c.load_addon()
    w.tick(2)
    s = boot_state(c)
    assert s["state"] == "safemode" and s["safe"]["path"] == "Core/TestNew.lua", s
    assert c.eval("return ns.Data") is None and not s["init"]
    assert len(c.errors) == 1
    w.clear_errors()
    c.relog()
    w.tick(2)
    assert boot_state(c)["state"] == "bad" and boot_state(c)["init"]
    w.assert_no_errors()


@case
def startup_errors_offer_a_rollback():
    def new_mods(root):
        append(root, "Core/Dungeon.lua", "\nlocal T = ns:NewModule('PatchTestBroken')\n"
               "function T:OnInit() error('init boom') end\nfunction T:OnLogin() error('login boom') end\n")
    base_dir, record, new_dir = simple_pair(new_mods=new_mods)
    bundle = make(record, new_dir)
    w = World(addon_dir=base_dir)
    c = member(w, "Alice", base_dir, sv=staged(bundle))
    c.load_addon()
    w.tick(2)
    s = boot_state(c)
    assert s["state"] == "applied" and s["errors"] == 2 and s["init"] and s["loggedIn"], s
    assert len(c.errors) == 2, c.errors
    w.clear_errors()
    assert c.eval("return DisasterZonePatchDB.lastLoad.errors") == 2
    assert c.eval("return DisasterZoneBootDialog:IsShown()") is True
    assert "2 error(s) while starting" in c.eval("return DisasterZoneBootDialog.text:GetText()")
    # "Keep it" just closes
    c.click(c.eval("return DisasterZoneBootDialog.cancel"))
    assert c.eval("return DisasterZoneBootDialog:IsShown()") is False
    assert c.eval("return DisasterZonePatchDB.bad") is None
    c.relog()
    w.tick(2)
    assert boot_state(c)["state"] == "applied"
    w.clear_errors()
    # "Roll back + reload"
    c.click(c.eval("return DisasterZoneBootDialog.accept"))
    assert c.eval("return __MOCK.reload_requested") is True
    c.relog()
    w.tick(2)
    s = boot_state(c)
    assert s["state"] == "bad" and s["errors"] == 0 and s["version"] == s["disk"] and s["init"], s
    assert c.eval("return ns.PatchTestBroken") is None
    w.assert_no_errors()


@case
def slash_rollback_and_retry():
    base_dir, record, new_dir = simple_pair()
    bundle = make(record, new_dir)
    w = World(addon_dir=base_dir)
    c = member(w, "Alice", base_dir, sv=staged(bundle))
    c.load_addon()
    w.tick(2)
    c.slash("/dzpatch rollback")
    assert c.eval("return DisasterZonePatchDB.bad[1]") is not None
    c.slash("/dzpatch retry")                       # changed my mind before reloading
    assert c.eval("return DisasterZonePatchDB.bad") is None
    c.relog()
    w.tick(2)
    assert boot_state(c)["state"] == "applied"
    c.slash("/dzpatch rollback")
    c.relog()
    w.tick(2)
    assert boot_state(c)["state"] == "bad"
    c.slash("/dzpatch rollback")                    # nothing running: just says so
    assert any("no in-game update is running" in l for l in c.chat_frame[-2:])
    w.assert_no_errors()


@case
def development_copy_never_applies_unless_asked():
    base_dir, record, new_dir = simple_pair()
    bundle = make(record, new_dir)
    dev = source_copy("devtree")
    w = World(addon_dir=dev)
    c = member(w, "Alice", dev, sv=staged(bundle))
    c.load_addon()
    w.tick(2)
    s = boot_state(c)
    assert s["build"] == "dev" and s["state"] == "base" and s["applied"] is None
    assert c.eval("return DisasterZonePatchDB.active.seq") == 1            # kept: the publisher serves it
    assert c.eval_py("return ns.Patch:GetStatus()").get("ready") is None
    c.slash("/dzpatch try")
    c.relog()
    w.tick(2)
    assert boot_state(c)["state"] == "applied" and c.eval("return ns.Util.PATCH_MARK") == "v2"
    c.relog()                                                        # once only
    w.tick(2)
    assert boot_state(c)["state"] == "base" and c.eval("return ns.Util.PATCH_MARK") is None
    # a packaged release has no 'try'
    w2 = World(addon_dir=base_dir)
    m = member(w2, "Bob", base_dir)
    m.load_addon()
    m.slash("/dzpatch try")
    assert m.eval("return DisasterZonePatchDB.tryOnce") is None
    w.assert_no_errors()
    w2.assert_no_errors()


@case
def patching_init_and_the_patch_code_itself():
    def new_mods(root):
        append(root, "Core/Init.lua", "\nns.INIT_MARK = 'init2'\n")
        append(root, "Core/Patch.lua", "\nPatch.SELF_MARK = 'patch2'\n")
        append(root, "Core/Sha256.lua", "\nSha.SELF_MARK = 'sha2'\n")
        append(root, "UI/PatchUI.lua", "\nPatchUI.SELF_MARK = 'ui2'\n")
    base_dir, record, new_dir = simple_pair(new_mods=new_mods)
    bundle = make(record, new_dir)
    w = World(addon_dir=base_dir)
    c = member(w, "Alice", base_dir, sv=staged(bundle))
    c.load_addon()
    w.tick(2)
    assert boot_state(c)["state"] == "applied" and boot_state(c)["applied"]["files"] == 5
    assert c.eval_py("return { ns.INIT_MARK, ns.Patch.SELF_MARK, ns.Sha256.SELF_MARK, ns.PatchUI.SELF_MARK }") == \
        ["init2", "patch2", "sha2", "ui2"]
    assert c.eval("return ns.version") == "9.9.9"
    w.assert_no_errors()


@case
def asset_pack_notice():
    def new_mods(root):
        replace(root, "Core/BuildInfo.lua", "assetPack = 1", "assetPack = 2")
        append(root, "Core/Util.lua", "\nUtil.HAS_NEW_ART = ns:HasAssets(2)\n")
    base_dir, record, new_dir = simple_pair(new_mods=new_mods)
    bundle = make(record, new_dir)
    assert bundle["pack"] == 2
    w = World(addon_dir=base_dir)
    c = member(w, "Alice", base_dir, sv=staged(bundle))
    c.load_addon()
    w.tick(2)
    assert boot_state(c)["state"] == "applied"
    assert c.eval("return ns.Util.HAS_NEW_ART") is False             # code arrived, the art did not
    assert c.eval_py("return ns.Patch:GetStatus()")["newArt"] is True
    assert any("new art" in l for l in c.chat_frame), c.chat_frame[-6:]
    # a member who installed the full new release has the art
    full_dir, full_record = release_of(new_dir)
    f = member(w, "Bob", full_dir)
    f.load_addon()
    w.tick(2)
    assert f.eval("return ns.Util.HAS_NEW_ART") is True
    assert not any("new art" in l for l in f.chat_frame)
    w.assert_no_errors()


@case
def every_file_from_the_patch():
    """The whole addon runs from stored text: each file on disk is replaced by a stub that fails if it runs."""
    src = source_copy("shadowsrc")
    files = release.patchable_files(src)
    assert len(files) > 80
    shadow = source_copy("shadow")
    for rel in files:
        if rel != "Core/PatchKey.lua":
            write(shadow, rel, guard(rel) + "\nerror('the disk copy of %s ran')\n" % rel)
    base_dir, record = release_of(shadow)
    new_dir = source_copy("shadownew", version="9.9.9")
    # (the whole addon is past one update's caps since 1.4, 13.6 MB: release.py selftest goes in parts. This case is
    # about every file running from the store, so its bundle is built past them: stored directly here, never sent.)
    caps = patchlib.MAX_TOTAL_LEN, patchlib.MAX_TOTAL_ZLEN
    patchlib.MAX_TOTAL_LEN = patchlib.MAX_TOTAL_ZLEN = 64 * 1024 * 1024
    try:
        bundle = make(record, new_dir)
    finally:
        patchlib.MAX_TOTAL_LEN, patchlib.MAX_TOTAL_ZLEN = caps
    assert len(bundle["items"]) == len(files) - 1
    w = World(addon_dir=base_dir)
    a = member(w, "Alice", base_dir, sv=staged(bundle), guild_rank=1)
    b = member(w, "Bob", base_dir, sv=staged(bundle), class_file="MAGE")
    for c in (a, b):
        c.load_addon()
    w.tick(5)
    for c in (a, b):
        s = boot_state(c)
        assert s["state"] == "applied" and s["applied"]["files"] == len(files) - 1 and s["errors"] == 0, s
        assert s["version"] == "9.9.9" and s["init"] and s["loggedIn"]
    a.slash("/dz")
    w.tick(1)
    w.make_raid([a, b], master_looter=a)
    w.tick(40)
    assert len(a.eval_py("return ns.Sync:GetVersions()")) >= 2
    a.relog()
    w.tick(5)
    assert boot_state(a)["state"] == "applied"
    w.assert_no_errors()


@case
def without_the_loader_the_addon_runs_as_before():
    """The documented way to switch the feature off in the code: take the four boot files out of the TOC."""
    def mods(root):
        for rel in ("Core/BuildInfo.lua", "Core/Boot.lua", "Core/Outbox.lua", "Core/BootEnd.lua"):
            toc_remove(root, rel)
        replace(root, "DisasterZone.toc", "## LoadSavedVariablesFirst: 1\n", "")
    tree = source_copy("noloader", mods)
    base_dir, record, new_dir = simple_pair()
    w = World(addon_dir=tree)
    # even with an update still sitting in the saved variables
    a = member(w, "Alice", tree, sv=staged(make(record, new_dir)), guild_rank=1)
    b = member(w, "Bob", tree, class_file="MAGE")
    for c in (a, b):
        c.load_addon()
    w.tick(60)
    for c in (a, b):
        assert c.eval("return DisasterZoneBoot") is None and c.eval("return ns.Boot") is None
        assert c.eval("return ns.initialized and ns.loggedIn") is True
        assert c.eval("return ns.version") == c.eval("return ns.diskVersion")
        assert c.eval("return ns.Util.PATCH_MARK") is None
        assert c.eval("return ns.assetPack") == 0 and c.eval("return ns:HasAssets(1)") is False
    assert [e for e in w.addon_log if e["prefix"].startswith("CDLp")] == []      # no update traffic at all
    a.slash("/dz update")                                                       # the command is simply not there
    assert any("unknown command 'update'" in l for l in a.chat_frame[-90:]), a.chat_frame[-90:]
    a.relog()
    w.tick(3)
    assert a.eval("return DisasterZonePatchDB.active.seq") == 1                        # the store is left alone
    w.assert_no_errors()


@case
def guards_cover_every_patchable_file():
    changed, problems = release.guards(SOURCE, "check")
    assert problems == [], problems
    assert release.check_tree(SOURCE) == [], release.check_tree(SOURCE)
    # add / remove are exact inverses and idempotent (on a copy)
    tree = source_copy("guards")
    before = {rel: read(tree, rel) for rel in release.patchable_files(tree)}
    assert release.guards(tree, "add") == ([], [])
    removed, _ = release.guards(tree, "remove")
    assert len(removed) == len(before)
    assert release.guards(tree, "remove")[0] == []
    assert len(release.guards(tree, "check")[1]) == len(before)
    for rel in before:
        assert not read(tree, rel).startswith("if DisasterZoneBoot"), rel
    # without guards (and with Boot still listed) the addon simply runs from disk
    w = World(addon_dir=tree)
    c = Client(w, "Alice")
    c.load_addon()
    w.tick(2)
    assert boot_state(c)["init"] and boot_state(c)["state"] == "none"
    w.assert_no_errors()
    added, _ = release.guards(tree, "add")
    assert len(added) == len(before)
    for rel, text in before.items():
        assert read(tree, rel) == text, rel
    # a guard naming another file is reported
    replace(tree, "Core/Util.lua", '"Core/Util.lua"', '"Core/Other.lua"')
    assert any("Core/Util.lua" in p for p in release.guards(tree, "check")[1])


if __name__ == "__main__":
    run_all()
