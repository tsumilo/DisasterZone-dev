#!/usr/bin/env python
"""Offline WoW (TBC Anniversary 2.5.x) client simulator for DisasterZone tests.

    from harness import World, Client
    w = World()
    a = Client(w, "Alice", guild_rank=1, class_file="PALADIN")
    b = Client(w, "Bob", class_file="MAGE")
    for c in w.clients: c.load_addon()
    w.make_raid([a, b], master_looter=a)
    w.tick(5)
    w.assert_no_errors()

Each Client is its own lupa Lua 5.1 runtime with the mock client (tools/wowmock/*.lua) installed. The World owns
the virtual clock, the addon-message bus, chat, guild/group/instance state and SavedVariables across relogs.
Run `python tools/harness.py` for a smoke test that loads DisasterZone on three clients and prints the reports.
"""
import hashlib
import heapq
import itertools
import json
import os
import re
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
_SITE = os.path.join(os.path.dirname(HERE), "luaenv", "Lib", "site-packages")
if os.name == "nt" and os.path.isdir(_SITE) and _SITE not in sys.path:  # (the Windows venv; WSL has its own)
    sys.path.insert(0, _SITE)
from lupa import lua51  # noqa: E402

# DISASTERZONE_ADDON_DIR points the whole harness at another copy of the addon (tools/patched_run.py: a base release
# tree whose saved DisasterZonePatchDB, named by DISASTERZONE_PATCH_SV, carries the current source as an in-game update).
ADDON_DIR = os.environ.get("DISASTERZONE_ADDON_DIR") or r"C:\World of Warcraft\_anniversary_\Interface\AddOns\DisasterZone"
PATCH_SV_FILE = os.environ.get("DISASTERZONE_PATCH_SV") or None
ADDON_NAME = "DisasterZone"
# The 3D room data is an addon of its own, loaded on demand (DisasterZone_Rooms, next to the addon folder): the mock's
# LoadAddOn runs its files when the addon asks (Render3D/Rooms.lua R3.LoadData), with a namespace of its own.
# DISASTERZONE_ROOMS_DIR points at another copy; a copy of the addon without one next to it (a staged release tree)
# uses the live one.
ROOMS_NAME = "DisasterZone_Rooms"
ROOMS_DIR = os.environ.get("DISASTERZONE_ROOMS_DIR") or os.path.join(
    os.path.dirname(os.path.normpath(r"C:\World of Warcraft\_anniversary_\Interface\AddOns\DisasterZone")), ROOMS_NAME)
# Of it, the strategy board's rooms (Rooms/<Raid>_<Boss>.lua, ~12 MB of packed text) are left out unless LOAD_ROOMS is
# on (env DISASTERZONE_ROOMS=1, or a suite that needs them sets harness.LOAD_ROOMS = True before its clients load
# them): 60 mock clients holding them each run out of memory. Without them the board acts as after an update that
# brought new files: no 2D / 3D switch. The Raid Trainer's own floors (*Floor.lua) and the stand-ins always load.
LOAD_ROOMS = os.environ.get("DISASTERZONE_ROOMS") == "1"


# tf_e/run_all.py splits its longest suites into shards run side by side: DZ_SHARD="i/n" makes a suite's runner keep
# only the cases whose position (among the cases its -k filter selected) is i mod n. Unset: every case runs.
_SHARD = os.environ.get("DZ_SHARD") or ""


def in_shard(position):
    if "/" not in _SHARD:
        return True
    i, n = _SHARD.split("/", 1)
    return position % int(n) == int(i)


def is_board_room(rel):
    """A strategy board room file of DisasterZone_Rooms (Rooms/<Raid>_<Boss>.lua)."""
    rel = rel.replace("\\", "/")
    return rel.startswith("Rooms/") and "_" in rel.rsplit("/", 1)[-1]


def rooms_dir_for(addon_dir):
    """The DisasterZone_Rooms folder that goes with an addon folder: next to it, else ROOMS_DIR."""
    if os.environ.get("DISASTERZONE_ROOMS_DIR"):
        return ROOMS_DIR
    sib = os.path.join(os.path.dirname(os.path.normpath(addon_dir)), ROOMS_NAME)
    return sib if _exists(sib) else ROOMS_DIR


# Each minigame is an addon of its own, a game pack (dev/docs/GAME_PACKS.md): DisasterZone_<Game> next to the addon
# folder, "## Dependencies: DisasterZone" and "## X-DZ-Pack: <id>" in its TOC. The client loads them after
# DisasterZone (its ADDON_LOADED first), in name order, each with a namespace of its own (Client._run_pack).
# PACK_ORDER "early" (default): the packs' files run right after DisasterZone's, before its ADDON_LOADED, so pre-loaded
# clients hold them too (a boot stays as fast as before the split); their modules then start with DisasterZone's own
# (Core/Init.lua RunInit). "real" (env DZ_PACK_ORDER=real, or Client(pack_order="real")): after ADDON_LOADED, as the
# client does, and ns:PackLoaded starts them (tests/games/test_packs.py covers that order).
PACK_ORDER = os.environ.get("DZ_PACK_ORDER") or "early"
_PACKS = {}


def packs_for(addon_dir):
    """{name: folder} of the game packs installed next to an addon folder, in the order the client loads them."""
    parent = os.path.dirname(os.path.normpath(addon_dir))
    try:
        names = sorted(_listdir(parent))
    except OSError:
        return {}
    key = (parent, tuple(names))
    if key not in _PACKS:
        out = {}
        for name in names:
            if not name.startswith(ADDON_NAME + "_") or name == ROOMS_NAME:
                continue
            folder = os.path.join(parent, name)
            if _exists(os.path.join(folder, name + ".toc")) and "x-dz-pack" in parse_toc(folder, name)[0]:
                out[name] = folder
        _PACKS[key] = out
    return dict(_PACKS[key])


MOCK_DIR = os.path.join(HERE, "wowmock")
MODULES = ("core.lua", "objects.lua", "ui.lua", "game.lua")
DEFAULT_RANKS = ["Guild Master", "Officer", "Raider", "Member", "Initiate"]
lua_type = lua51.lua_type


class LuaErrorsFound(AssertionError):
    """Raised by World.assert_no_errors() with every recorded Lua traceback."""


class LuaEvalError(RuntimeError):
    """Raised by Client.eval() when the evaluated Lua code errors."""


# ------------------------------------------------------------------------------------------------------------------
# cached files
# ------------------------------------------------------------------------------------------------------------------
_CACHE = {}


def _read(path, binary=False):
    key = (path, binary)
    if key not in _CACHE:
        with open(path, "rb" if binary else "r", **({} if binary else {"encoding": "utf-8"})) as fh:
            _CACHE[key] = fh.read()
    return _CACHE[key]


def _mock_sources():
    return {m: _mock_chunk(m) for m in MODULES}


def _mock_chunk(name):
    """A wowmock file as bytecode (compiled once, like the addon's files below), or its source if it does not compile."""
    key = ("mockbc", name)
    if key not in _CACHE:
        src = _read(os.path.join(MOCK_DIR, name), binary=True)
        _CACHE[key] = (BC_CACHE_ON and _compile(src, "@wowmock/" + name)) or src
    return _CACHE[key]


# Addon files as Lua 5.1 bytecode. Compiling the addon (~17 MB of source) was two thirds of every client boot, and a
# suite boots dozens of clients. A file is compiled once (in a private runtime) and every client after that loads its
# bytecode: string.dump keeps the chunk name, line numbers and local names, so errors and tracebacks read the same.
# Keyed by (path, mtime, size) in memory, so another agent's edit is picked up by the next boot, and by a hash of
# (chunk name, source) on disk (dev/.luacache/), shared by every test process. A file that fails to compile is handed
# over as source so the mock records the syntax error as before. DISASTERZONE_NO_BCCACHE=1 turns it off.
BC_CACHE_DIR = os.path.join(os.path.dirname(HERE), ".luacache")
BC_CACHE_ON = os.environ.get("DISASTERZONE_NO_BCCACHE") != "1"
_CHUNKS = {}  # (path, chunkname, strip_bom) -> ((mtime_ns, size), bytes to hand to M.load_file)
_COMPILER = None


def _compile(src, chunkname):
    """Bytecode for src, or None when it does not compile."""
    global _COMPILER
    h = hashlib.sha1(chunkname.encode("utf-8") + b"\0" + src).hexdigest()
    disk = os.path.join(BC_CACHE_DIR, h[:2], h + ".luac")
    try:
        with open(disk, "rb") as fh:
            bc = fh.read()
        os.utime(disk)  # recently used: tools/testmap.prune() deletes what nothing used for a week
        return bc
    except OSError:
        pass
    if _COMPILER is None:
        _COMPILER = lua51.LuaRuntime(encoding=None)
        _COMPILER.execute(b"function __dz_compile(src, name) local f = loadstring(src, name) "
                          b"if f then return string.dump(f) end end")
    bc = _COMPILER.globals()[b"__dz_compile"](src, chunkname.encode("utf-8"))
    if bc is None:
        return None
    try:
        os.makedirs(os.path.dirname(disk), exist_ok=True)
        tmp = "%s.%d.tmp" % (disk, os.getpid())
        with open(tmp, "wb") as fh:
            fh.write(bc)
        os.replace(tmp, disk)
    except OSError:
        pass
    return bc


# Each boot re-checks every file it loads (agents edit while tests run), but a stat per file opens it on Windows
# (~0.1 ms, a tenth of a boot for ~270 files): a folder is listed once per boot instead, and its entries' times and
# sizes are what _chunk compares. Client.load_addon / load_files / LoadAddOn start a new boot (_BOOT += 1).
_BOOT = 0
_LISTINGS = {}  # normcase(folder) -> (boot, {normcase(name): (mtime_ns, size)} or None)
_LISTING = False  # tools/testmap_rec.py: these listings are not dependencies (the files' coverage is)


def _new_boot():
    global _BOOT
    _BOOT += 1


# Under WSL (tools/wsl/) the addon folder is a 9P mount: a stat costs ~0.6 ms there, and a listing does not carry the
# times. A file's time is read once per process instead, and forgotten when this process writes, renames, removes or
# touches it (audit hook below), so a test that edits a file and boots again sees its edit. Someone else's edit while
# the suite runs shows in its next run (tools/testmap_rec.py records what the suite read).
_STAMP_ONCE = os.name != "nt"
_STAMPS = {}  # abspath -> (mtime_ns, size) or None


def _forget_stamp(path):
    if isinstance(path, bytes):
        path = os.fsdecode(path)
    if isinstance(path, str) and _STAMPS:
        _STAMPS.pop(os.path.abspath(path), None)


def _stamp_audit(event, args):
    if event == "open":
        mode, flags = args[1], args[2]
        if (isinstance(mode, str) and any(c in mode for c in "wax+")) or (mode is None and isinstance(flags, int)
                                                                          and flags & (os.O_WRONLY | os.O_RDWR)):
            _forget_stamp(args[0])
    elif event in ("os.rename", "shutil.copyfile", "os.link", "os.symlink"):
        _forget_stamp(args[0])
        _forget_stamp(args[1])
    elif event in ("os.remove", "os.utime", "os.truncate", "os.rmdir"):
        _forget_stamp(args[0])


if _STAMP_ONCE:
    sys.addaudithook(_stamp_audit)


def _stamp(path):
    """(mtime_ns, size) of a file as this boot sees it, or None when it does not exist."""
    global _LISTING
    if _STAMP_ONCE:
        key = os.path.abspath(path)
        if key not in _STAMPS:
            try:
                st = os.stat(path)
                _STAMPS[key] = (st.st_mtime_ns, st.st_size)
            except OSError:
                _STAMPS[key] = None
        return _STAMPS[key]
    folder, name = os.path.split(path)
    fkey = os.path.normcase(folder)
    hit = _LISTINGS.get(fkey)
    if hit is None or hit[0] != _BOOT:
        entries = {}
        _LISTING = True
        try:
            with os.scandir(folder) as it:
                for e in it:
                    try:
                        if e.is_file():
                            st = e.stat()
                            entries[os.path.normcase(e.name)] = (st.st_mtime_ns, st.st_size)
                    except OSError:
                        pass
        except OSError:
            entries = None
        finally:
            _LISTING = False
        hit = _LISTINGS[fkey] = (_BOOT, entries)
    found = hit[1] and hit[1].get(os.path.normcase(name))
    if found:
        return found
    try:  # not in the listing: gone, or a name the listing spells differently
        st = os.stat(path)
    except OSError:
        return None
    return (st.st_mtime_ns, st.st_size)


# Under WSL a boot's other reads of the addon folder (TOCs, XML includes, its listing, "is it there") cost a 9P
# round trip each, and eight suites booting at once queued up behind them (a load of 100+): once per process too,
# by the same file times as the chunks.
_TEXTS = {}     # path -> (stamp, open() keywords, text)
_LISTS = {}     # folder -> names


def _text(path, **kw):
    if not _STAMP_ONCE:
        with open(path, **kw) as fh:
            return fh.read()
    st = _stamp(path)
    if st is None:
        raise FileNotFoundError(path)
    hit = _TEXTS.get(path)
    if hit and hit[0] == st and hit[1] == kw:
        return hit[2]
    with open(path, **kw) as fh:
        data = fh.read()
    _TEXTS[path] = (st, kw, data)
    return data


def _exists(path):
    return _stamp(path) is not None if _STAMP_ONCE else os.path.exists(path)


def _listdir(folder):
    if not _STAMP_ONCE:
        return os.listdir(folder)
    if folder not in _LISTS:
        _LISTS[folder] = os.listdir(folder)
    return _LISTS[folder]


def _chunk(path, chunkname, strip_bom=True):
    """What M.load_file gets for an addon file: cached bytecode, or the source (cache off / syntax error).
    None when the file does not exist."""
    stamp = _stamp(path)
    if stamp is None:
        return None
    key = (path, chunkname, strip_bom)
    hit = _CHUNKS.get(key)
    if hit and hit[0] == stamp:
        return hit[1]
    cover = bool(COVER_FILE and chunkname.startswith(COVER_PREFIX))
    ident = None if _STAMP_ONCE else _identity(path)     # (WSL: one look per file and process already, over 9P)
    if ident is not None:
        ident = (ident, chunkname, strip_bom, cover)
        out = _CHUNKS_BY_ID.get(ident)
        if out is not None:
            _CHUNKS[key] = (stamp, out)
            return out
    native = _native_path(path, chunkname, strip_bom, stamp, cover)
    out = native and _native_get(native, chunkname, cover)
    if out is not None:
        _CHUNKS[key] = (stamp, out)
        return out
    global _READING_CHUNK
    _READING_CHUNK = chunkname.startswith(COVER_PREFIX)  # tools/testmap_rec.py: counted per function, not per file
    try:
        with open(path, "rb") as fh:
            src = fh.read()
    finally:
        _READING_CHUNK = False
    if strip_bom and src.startswith(b"\xef\xbb\xbf"):
        src = src[3:]
    h = hashlib.sha1(src).hexdigest()
    if cover:
        src = _cover_source(chunkname, src)
    out = (BC_CACHE_ON and _compile(src, chunkname)) or src
    _CHUNKS[key] = (stamp, out)
    if ident is not None:
        _CHUNKS_BY_ID[ident] = out
    if native:
        _native_put(native, h, out)
    return out


# The same file under another name (a hard-linked copy: the patch suites stage whole release trees that way, every
# case) is the same chunk: kept by identity (volume, file id, size, time) too, so a copy's boot costs a stat per file
# instead of an open (on Windows the first open of each new name is a virus scan) and a cache lookup.
_CHUNKS_BY_ID = {}


def _identity(path):
    try:
        st = os.stat(path)
    except OSError:
        return None
    return (st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns) if st.st_ino else None


# Under WSL, _chunk's result is also kept on the Linux disk (NATIVE_DIR), by file path, chunk name, time, size and
# coverage on/off: reading the addon's source and bytecode over 9P (~37 MB) took ~3 s per suite, a stat per file is
# what is left. The entry starts with the source's sha1 (testmap's record of what the suite ran, in coverage mode).
NATIVE_DIR = os.environ.get("DZ_NATIVE_CACHE") or ("/var/cache/dz-bc" if _STAMP_ONCE else None)


def _native_path(path, chunkname, strip_bom, stamp, cover):
    if not NATIVE_DIR or not BC_CACHE_ON:
        return None
    h = hashlib.sha1(repr((os.path.abspath(path), chunkname, strip_bom, stamp, cover)).encode("utf-8")).hexdigest()
    return os.path.join(NATIVE_DIR, h[:2], h)


def _native_get(native, chunkname, cover):
    try:
        with open(native, "rb") as fh:
            data = fh.read()
    except OSError:
        return None
    h, _, out = data.partition(b"\n")
    if len(h) != 40 or not out:
        return None
    if cover:
        h = h.decode("ascii")
        if COVER_SRC and not os.path.exists(os.path.join(COVER_SRC, h + ".lua")):
            return None                     # (testmap pruned the copy: the slow path writes it again)
        rel = chunkname[len(COVER_PREFIX):]
        _COVER_FILES[rel] = h
        _COVER_TAGS[hashlib.sha1(rel.encode("utf-8")).hexdigest()[:10]] = rel
    return out


def _native_put(native, h, out):
    try:
        os.makedirs(os.path.dirname(native), exist_ok=True)
        tmp = "%s.%d.tmp" % (native, os.getpid())
        with open(tmp, "wb") as fh:
            fh.write(h.encode("ascii") + b"\n" + out)
        os.replace(tmp, native)
    except OSError:
        pass


# Coverage for tf_e/run_all.py's change-based selection (tools/testmap.py). With DZ_COVER set, each addon function
# body starts with a table write (`__DZC_<tag>[<line>]=true`, put after the parameter list on the same line, so line
# numbers stay as they are); the first write of a line in a runtime reports (file, line the function starts on) to
# Python. A debug.sethook call hook did the same at 6x the run time; this costs next to nothing. tools/testmap_rec.py
# writes _COVER_FILES / _COVER_FUNCS out at exit; each source a suite ran is kept in DZ_COVER_SRC/<sha1>.lua, so a
# later run can diff today's file against the exact version the suite saw.
COVER_FILE = os.environ.get("DZ_COVER") or None
COVER_SRC = os.environ.get("DZ_COVER_SRC") or None
COVER_PREFIX = "@Interface/AddOns/%s/" % ADDON_NAME
_COVER_FUNCS = {}  # rel -> set(linedefined)
_COVER_FILES = {}  # rel -> sha1
_COVER_TAGS = {}  # tag -> rel
_READING_CHUNK = False
_LUA_TOKEN = re.compile(rb"""
    (--\[(=*)\[.*?\]\2\])                     # long comment
  | (--[^\n]*)                                # comment
  | (\[(=*)\[.*?\]\5\])                       # long string
  | ("(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*')  # string
  | ([A-Za-z_][A-Za-z0-9_]*)                  # name
  | ([()])
""", re.S | re.X)


def _instrument(src, tag):
    """src with `__DZC_<tag>[line]=true ` after every function's parameter list."""
    if b"function" not in src:
        return src
    out, last, state, line, pos_line, fn_line = [], 0, 0, 1, 0, 0
    for m in _LUA_TOKEN.finditer(src):
        name, paren = m.group(7), m.group(8)
        if state == 0:
            if name == b"function":
                line += src.count(b"\n", pos_line, m.start())
                pos_line = m.start()
                fn_line, state = line, 1
        elif paren == b"(" and state == 1:
            state = 2
        elif paren == b")" and state == 2:
            out.append(src[last:m.end()])
            out.append(b" __DZC_%s[%d]=true " % (tag.encode(), fn_line))
            last, state = m.end(), 0
    out.append(src[last:])
    return b"".join(out)


def _cover_source(chunkname, src):
    """Records the source a suite ran (hash + a copy in COVER_SRC) and returns it instrumented."""
    rel = chunkname[len(COVER_PREFIX):]
    h = hashlib.sha1(src).hexdigest()
    _COVER_FILES[rel] = h
    if COVER_SRC:
        path = os.path.join(COVER_SRC, h + ".lua")
        if not os.path.exists(path):
            try:
                os.makedirs(COVER_SRC, exist_ok=True)
                tmp = "%s.%d.tmp" % (path, os.getpid())
                with open(tmp, "wb") as fh:
                    fh.write(src)
                os.replace(tmp, path)
            except OSError:
                pass
    tag = hashlib.sha1(rel.encode("utf-8")).hexdigest()[:10]
    _COVER_TAGS[tag] = rel
    return _instrument(src, tag)


def _cover_report(tag, line):
    _COVER_FUNCS.setdefault(_COVER_TAGS[tag], set()).add(int(line))


def _cover_tables(rt):
    """Lua function(tag) that creates the global __DZC_<tag> table in this runtime (once)."""
    return rt.execute("""
        local report = ...
        return function(tag)
          local name = "__DZC_" .. tag
          if rawget(_G, name) then return end
          rawset(_G, name, setmetatable({}, { __newindex = function(t, k, v) rawset(t, k, v) report(tag, k) end }))
        end
    """, _cover_report)


def _known_events():
    if "events" not in _CACHE:
        p = os.path.join(HERE, "known_globals.json")
        ev = []
        if os.path.exists(p):
            with open(p, encoding="utf-8") as fh:
                ev = sorted(json.load(fh).get("events", {}).keys())
        _CACHE["events"] = ev
    return _CACHE["events"]


def _fallback_items():
    if "fallback" not in _CACHE:
        p = os.path.join(MOCK_DIR, "items_fallback.json")
        d = {}
        if os.path.exists(p):
            with open(p, encoding="utf-8") as fh:
                d = json.load(fh)
        _CACHE["fallback"] = d
    return _CACHE["fallback"]


def normalize_realm(realm):
    return re.sub(r"[\s\-]", "", realm or "")


def make_guid(name, realm):
    h = zlib.crc32(("%s-%s" % (name, normalize_realm(realm))).encode("utf-8")) & 0xFFFFFFFF
    return "Player-4467-%08X" % h


def parse_toc(addon_dir, addon_name=ADDON_NAME):
    """Return (headers {lowercase key: value}, [relative file paths in load order])."""
    path = os.path.join(addon_dir, addon_name + ".toc")
    headers, files = {}, []
    for raw in _text(path, encoding="utf-8-sig").splitlines():
        line = raw.strip()
        if line.startswith("##"):
            k, _, v = line[2:].partition(":")
            headers[k.strip().lower()] = v.strip()
        elif not line or line.startswith("#"):
            continue
        else:
            files.append(line.replace("\\", "/"))
    return headers, files


def _xml_scripts(addon_dir, rel):
    """Lua files referenced by an XML file (<Script file=..>, <Include file=..>), recursively."""
    out = []
    path = os.path.join(addon_dir, rel)
    base = os.path.dirname(rel)
    try:
        text = _text(path, encoding="utf-8", errors="replace")
    except OSError:
        return out
    for m in re.finditer(r'<(Script|Include)\s+file\s*=\s*"([^"]+)"', text):
        f = os.path.normpath(os.path.join(base, m.group(2).replace("\\", "/"))).replace("\\", "/")
        if m.group(1) == "Include" or f.lower().endswith(".xml"):
            out.extend(_xml_scripts(addon_dir, f))
        else:
            out.append(f)
    return out


# C rand() as the Windows C runtime has it (MSVCRT / UCRT: 15-bit, one state for the whole process), for the mock's
# math.random (wowmock/core.lua): Lua 5.1's math.random is the C library's rand(), which differs on Linux (WSL), and
# the per-client seeds then gave other ids, orders and outcomes there. Checked against lupa's own on Windows.
_RAND = [1]


def _crt_rand():
    s = (_RAND[0] * 214013 + 2531011) & 0xFFFFFFFF
    _RAND[0] = s
    return (s >> 16) & 0x7FFF


def _crt_srand(seed):
    _RAND[0] = int(seed) & 0xFFFFFFFF


def warm(addon_dir=None, addon_name=ADDON_NAME):
    """Fill this process's file caches (the addon's bytecode, the mock's) without running anything, so processes
    forked from it (tools/forkrun.py) start with them: under WSL a cold boot reads ~540 files over 9P (~2 s)."""
    addon_dir = addon_dir or ADDON_DIR
    for m in MODULES + ("mock.lua", "items.lua"):
        _mock_chunk(m)
    _known_events()
    try:
        _, files = parse_toc(addon_dir, addon_name)
    except OSError:
        return
    for rel in files:
        for lua in (_xml_scripts(addon_dir, rel) if rel.lower().endswith(".xml") else [rel]):
            _chunk(os.path.join(addon_dir, lua), "@Interface/AddOns/%s/%s" % (addon_name, lua.replace("\\", "/")))


# -- pre-loaded clients ----------------------------------------------------------------------------------------------
# A boot was 55-75 % of a suite: ~130 ms of its ~180 ms is running the addon's ~390 files, and they come out the same
# for every client, because while they load they read next to nothing about who is playing. build_templates() runs
# them once per Client.index (whose GetTime offset is fixed), before tools/testserver.py or tools/forkrun.py fork, and
# Client.load_addon takes over that runtime instead of running them again when the client would have run them the
# same way (Client._template_mismatch): first login of a default client, nothing saved, at the template's time,
# nothing done to its runtime before. What the files read while the template loaded is recorded and checked:
#   - the player (the mock's world state, M.W): only at a line listed in TEMPLATE_NAME_CHECKS, else no client takes
#     the template (a new file-time read of the player shows as "the files read the player's ..." in the notes)
#   - saved variables: the client must have none; the clock: its boot time must be the template's
#   - items: the client's world must not redefine one they asked about
# DZ_TEMPLATES=n (forkrun builds n for its suite) / tools/testserver.py; DZ_TEMPLATE_LOG=<file> logs each decision.
TEMPLATE_NAME_CHECKS = {
    # Core/Perf.lua: the Performance page is on from the first file for the developer's character
    ("Core/Perf.lua", 'local isDev = (UnitName and UnitName("player")) == DEV'): "Tsumil",
}
_TEMPLATES = {}          # Client.index -> pre-loaded Client (taken by the first client of that index to load)
_TEMPLATES_BUILT = False  # (once per process: a process that used them all up does not build more)
TEMPLATE_NOTES = {}      # why -> count: "taken", or why a client loaded its files itself
_TEMPLATE_LOG = os.environ.get("DZ_TEMPLATE_LOG") or None
_TPL_RECORDER = r"""
local SVN = ...
local M = __MOCK
local rec = {}
local function site()
  for lvl = 3, 40 do
    local i = debug.getinfo(lvl, "Sl")
    if not i then break end
    local rel = i.source and i.source:match("^@Interface/AddOns/[^/]+/(.+)$")
    if rel then return rel .. ":" .. tostring(i.currentline) end
  end
  return "?"
end
local function note(k) rec[#rec + 1] = { k, site() } end
-- the player and the world: M.W through a proxy that notes every read
local realW = M.W
local function proxy(real, path)
  return setmetatable({}, {
    __index = function(_, k)
      note("W." .. path .. tostring(k))
      local v = real[k]
      if type(v) == "table" then return proxy(v, path .. tostring(k) .. ".") end
      return v
    end,
    __newindex = function(_, k, v) note("W=" .. path .. tostring(k)); real[k] = v end,
  })
end
M.W = proxy(realW, "")
-- the clock
local now, st = rawget(M, "now"), rawget(M, "server_time")
local oldMT = getmetatable(M)
rawset(M, "now", nil); rawset(M, "server_time", nil)
setmetatable(M, {
  __index = function(t, k)
    if k == "now" then note("now"); return now elseif k == "server_time" then note("now"); return st end
    local oi = oldMT and oldMT.__index
    if type(oi) == "function" then return oi(t, k) elseif oi then return oi[k] end
  end,
  __newindex = function(t, k, v)
    if k == "now" then now = v elseif k == "server_time" then st = v else rawset(t, k, v) end
  end,
})
-- saved variables
local sv = {}
for _, n in ipairs(SVN) do sv[n] = true end
local oldG = getmetatable(_G)
local gi, gn = oldG and oldG.__index, oldG and oldG.__newindex
local newG = {}
if oldG then for k, v in pairs(oldG) do newG[k] = v end end
newG.__index = function(t, k)
  if sv[k] then note("sv." .. k) end
  if type(gi) == "function" then return gi(t, k) elseif gi then return gi[k] end
end
newG.__newindex = function(t, k, v)
  if sv[k] then note("sv=" .. k) end
  if type(gn) == "function" then return gn(t, k, v) elseif gn then gn[k] = v else rawset(t, k, v) end
end
setmetatable(_G, newG)
-- items asked about
local wrapped = {}
local function wrap(tbl, k)
  local f = rawget(tbl, k)
  if type(f) ~= "function" then return end
  wrapped[#wrapped + 1] = { tbl, k, f }
  rawset(tbl, k, function(item, ...) note("item." .. tostring(item)); return f(item, ...) end)
end
for k, v in pairs(_G) do
  if type(k) == "string" and type(v) == "function" and k:find("Item") then wrap(_G, k) end
end
if type(rawget(_G, "C_Item")) == "table" then for k in pairs(C_Item) do wrap(C_Item, k) end end
function __DZ_TPL_DONE()
  for _, w in ipairs(wrapped) do rawset(w[1], w[2], w[3]) end
  setmetatable(_G, oldG)
  setmetatable(M, oldMT)
  rawset(M, "now", now); rawset(M, "server_time", st)
  M.W = realW
  __DZ_TPL_DONE = nil
  return rec
end
"""


def _loading_hooks():
    """The harness functions a boot's first half goes through: a suite that replaces one (to load other code) must
    not get files that ran without it."""
    mod = sys.modules[__name__]
    return tuple(getattr(mod, n, None) for n in ("_chunk", "_compile", "_cover_source", "_instrument", "_mock_chunk",
                                                  "_mock_sources", "_xml_scripts", "parse_toc", "_read", "_text")) + \
        tuple(getattr(Client, n, None) for n in ("_load_one", "_run_files", "_new_runtime", "toc", "_apply_saved")) + \
        (MOCK_DIR, MODULES, ROOMS_DIR, BC_CACHE_ON, bool(COVER_FILE))


def _template_note(why):
    TEMPLATE_NOTES[why] = TEMPLATE_NOTES.get(why, 0) + 1
    if _TEMPLATE_LOG:
        try:
            with open(_TEMPLATE_LOG, "a", encoding="utf-8") as fh:
                fh.write("%s\t%s\n" % (why, os.path.basename(sys.argv[0] if sys.argv else "?")))
        except OSError:
            pass


def build_templates(n):
    """Pre-loads clients for indexes 0..n-1 (see above). Returns how many it built. The process's random state and
    client numbering are left as they were, so what forks from it starts like a fresh process."""
    global _TEMPLATES_BUILT
    if PATCH_SV_FILE or n <= 0:
        return 0
    _TEMPLATES_BUILT = True
    saved_index, saved_rand = Client._index, _RAND[0]
    built = 0
    try:
        w = World()
        for i in range(n):
            if i in _TEMPLATES:
                continue
            Client._index = itertools.count(i)
            c = Client(w, "Pretemplate%d" % i)
            c._preload()
            _TEMPLATES[i] = c
            built += 1
    finally:
        Client._index = saved_index
        _RAND[0] = saved_rand
    return built


def to_lua(rt, obj):
    """Convert Python dict/list/tuple (recursively) into fresh Lua tables; lists/tuples become 1-based arrays.
    (lupa's table_from with recursion can alias sub-tables when the same Python object appears twice.)"""
    if isinstance(obj, dict):
        t = rt.table()
        for k, v in obj.items():
            if v is None:
                continue
            t[k] = to_lua(rt, v)
        return t
    if isinstance(obj, (list, tuple)):
        t = rt.table()
        for i, v in enumerate(obj, 1):
            if v is not None:
                t[i] = to_lua(rt, v)
        return t
    return obj


class EmptyTable(list):
    """An empty Lua table: compares equal to both [] and {} and supports the read-only dict API."""

    def __eq__(self, other):
        return other == [] or other == {} or (isinstance(other, EmptyTable))

    __hash__ = None

    def get(self, key, default=None):
        return default

    def keys(self):
        return []

    def values(self):
        return []

    def items(self):
        return []

    def __repr__(self):
        return "EmptyTable()"


def _conv(v):
    """Convert an M.export()ed Lua value into Python: arrays (keys 1..n, holes allowed if dense) -> list (None in
    holes), other tables -> dict, {__bytes=hex} -> bytes, empty table -> EmptyTable (== [] and == {})."""
    if lua_type(v) != "table":
        return v
    keys = list(v.keys())
    if not keys:
        return EmptyTable()
    if keys == ["__bytes"]:
        return bytes.fromhex(v["__bytes"])
    if all(isinstance(k, int) and not isinstance(k, bool) and k >= 1 for k in keys):
        mx = max(keys)
        if mx <= 2 * len(keys):
            return [_conv(v[i]) if i in v.keys() else None for i in range(1, mx + 1)] if mx != len(keys) else                 [_conv(v[i]) for i in range(1, mx + 1)]
    return {k: _conv(v[k]) for k in keys}


class ExtraMember:
    """A raid/guild member without its own client runtime (does not receive messages)."""

    def __init__(self, name, class_file="WARRIOR", realm=None, level=70, online=True, race="Human",
                 faction="Alliance", guild=None, guild_rank=4, sex=2):
        self.name, self.class_file, self.realm, self.level = name, class_file, realm, level
        self.online, self.race, self.faction, self.guild, self.guild_rank, self.sex = online, race, faction, guild, guild_rank, sex

    @property
    def full_name(self):
        return "%s-%s" % (self.name, normalize_realm(self.realm))

    @property
    def guid(self):
        return make_guid(self.name, self.realm)

    runtime = None


# ------------------------------------------------------------------------------------------------------------------
# World
# ------------------------------------------------------------------------------------------------------------------
class World:
    def __init__(self, addon_dir=ADDON_DIR, realm="Thunderstrike", officer_rank=1, latency=0.1,
                 guild_ranks=None, addon_throttle=True, onupdate_hidden=False, roster_delay=0.5,
                 zone="Shattrath City", fail_fast=False, other_addons=(), server_time=1790000000,
                 prebuild_pages=False):
        """officer_rank: guild rank index <= this can read OFFICER chat / officer notes.
        roster_delay: seconds after PLAYER_ENTERING_WORLD until the guild roster is available (None/0 = immediate).
        addon_throttle: simulate the per-prefix server rate limit (10 msg burst, 1/s regen) on SendAddonMessage.
        onupdate_hidden: also run OnUpdate for hidden frames (WoW only runs it for visible frames).
        other_addons: addon names that IsAddOnLoaded reports as loaded (e.g. "LoonBestInSlot").
        prebuild_pages: the main window builds every other page in the background after it first opens, as in the
        game (UI/MainFrame.lua). Off: a page is built when first shown (building them all was most of a UI suite's
        time; tests/boot-ui/test_broad.py runs with it on)."""
        self.addon_dir = addon_dir
        self.realm = realm
        self.officer_rank = officer_rank
        self.latency = latency
        self.guild_ranks = {}
        self.default_ranks = list(guild_ranks or DEFAULT_RANKS)
        self.addon_throttle = addon_throttle
        self.onupdate_hidden = onupdate_hidden
        self.roster_delay = roster_delay
        self.zone = zone
        self.fail_fast = fail_fast
        self.other_addons = list(other_addons)
        self.prebuild_pages = prebuild_pages
        self.server_time0 = server_time
        self.now = 0.0
        self.clients = []
        self.offline_members = []
        self.notes = {}
        self.guild_texts = {}
        self.auto_accept_invites = True   # invited online clients accept after `latency` (InviteUnit)
        self.invite_log = []              # {time, by, target, result}
        self.pending_invites = {}         # id(target client) -> (invite_log entry, accept) while auto_accept is off
        self.group = None
        self.instance = None
        self.instance_members = set()
        self.saved = {}
        self.custom_items = {}
        self.chat_log = []
        self.roll_log = []
        self.addon_log = []
        self.warnings = []
        self._queue = []
        self._seq = itertools.count()
        self._warned_missing = set()
        self._archived_reports = []
        # fn(client) called right after a client's saved variables are assigned (before the addon's files with
        # LoadSavedVariablesFirst): a test helper storing data as an earlier session would have (tests/cdl_council.py
        # seed_guild_council). Its clients load their files themselves (pre-loaded ones ran without it).
        self.on_saved_applied = []

    # -- time ----------------------------------------------------------------------------------------------------
    @property
    def server_time(self):
        return self.server_time0 + self.now

    def tick(self, seconds=0.05, step=0.05, check=None):
        """Advance the virtual clock by `seconds` in steps of `step`. Each step: deliver due messages, then per
        client run deferred events, internal timers, C_Timer callbacks, OnUpdate(elapsed) of visible frames and
        animations. tick(0) runs one zero-length step (flushes deferred events)."""
        n = int(seconds // step + 1e-9)
        steps = [step] * n
        rest = seconds - n * step
        if rest > 1e-9 or not steps:
            steps.append(max(rest, 0.0))
        for dt in steps:
            self.now += dt
            self._deliver_due()
            for c in list(self.clients):
                if c.runtime is not None:
                    c._step(dt)
        if check or (check is None and self.fail_fast):
            self.assert_no_errors()

    def run_until(self, predicate, timeout=30.0, step=0.05):
        """Tick until predicate() is true; returns elapsed seconds or raises TimeoutError."""
        start = self.now
        while self.now - start < timeout:
            if predicate():
                return self.now - start
            self.tick(step, step)
        if predicate():
            return self.now - start
        raise TimeoutError("run_until: condition not met after %.1fs" % timeout)

    # -- clients -------------------------------------------------------------------------------------------------
    def add_client(self, name, **kw):
        return Client(self, name, **kw)

    def _register(self, c):
        self.clients.append(c)

    def find_client(self, name, default_realm=None):
        if not name:
            return None
        n, _, r = name.partition("-")
        realm = normalize_realm(r) if r else normalize_realm(default_realm or self.realm)
        for c in self.clients:
            if c.name.lower() == n.lower() and normalize_realm(c.realm).lower() == realm.lower():
                return c
        return None

    def _member(self, x):
        if isinstance(x, (Client, ExtraMember)):
            return x
        if isinstance(x, str):
            c = self.find_client(x)
            if c:
                return c
            if self.group:
                for m in self.group["members"]:
                    if m.name.lower() == x.split("-")[0].lower():
                        return m
            return ExtraMember(x.split("-")[0], realm=(x.split("-", 1)[1] if "-" in x else self.realm))
        raise TypeError("expected Client, ExtraMember or name, got %r" % (x,))

    # -- guild ---------------------------------------------------------------------------------------------------
    def ranks_for(self, guild):
        return self.guild_ranks.get(guild, self.default_ranks)

    def add_offline_member(self, name, class_file="WARRIOR", rank=3, level=70, realm=None, public_note="",
                           officer_note="", guild="Casual Disaster", race="Human"):
        m = ExtraMember(name, class_file=class_file, realm=realm or self.realm, level=level, online=False, race=race,
                        guild=guild, guild_rank=rank)
        self.offline_members.append(m)
        if public_note or officer_note:
            self.notes[m.full_name] = {"public": public_note, "officer": officer_note}
        self._sync(roster_changed=True)
        return m

    def set_note(self, full_name, public=None, officer=None):
        n = self.notes.setdefault(full_name, {"public": "", "officer": ""})
        if public is not None:
            n["public"] = public
        if officer is not None:
            n["officer"] = officer
        self._sync(roster_changed=True)

    def guild_info_text(self, guild="Casual Disaster"):
        return self.guild_texts.get(guild, "")

    def set_guild_info_text(self, text, guild="Casual Disaster"):
        self.guild_texts[guild] = text
        self._sync(roster_changed=True)

    def _guild_members(self, guild):
        out = [c for c in self.clients if c.guild == guild]
        out += [m for m in self.offline_members if m.guild == guild]
        return out

    def _is_online(self, m):
        if isinstance(m, Client):
            return m.online and m.runtime is not None
        return m.online

    # -- group ---------------------------------------------------------------------------------------------------
    def make_raid(self, clients, master_looter=None, leader=None, assistants=(), extra_members=(), loot_method=None,
                  loot_threshold=2, kind="raid"):
        """Put the given clients (+ optional ExtraMember/name strings) in one raid. master_looter sets loot
        method Master Looter (2); otherwise loot_method (default Group Loot = 3)."""
        members = [self._member(c) for c in clients] + [self._member(e) if not isinstance(e, dict) else ExtraMember(**e)
                                                         for e in extra_members]
        if kind == "party" and len(members) > 5:
            raise ValueError("a party has at most 5 members")
        if len(members) > 40:
            raise ValueError("a raid has at most 40 members")
        old = self.group["members"] if self.group else []
        ml = self._member(master_looter) if master_looter is not None else None
        self.group = {
            "kind": kind, "members": members, "leader": self._member(leader) if leader is not None else members[0],
            "assistants": [self._member(a) for a in assistants], "ml": ml,
            "loot_method": 2 if ml is not None else (loot_method if loot_method is not None else 3),
            "threshold": loot_threshold,
            "subgroups": {id(m): (i // 5 + 1 if kind == "raid" else 1) for i, m in enumerate(members)},
        }
        self._sync()
        for c in self._group_clients(old + members):
            c._fire("GROUP_ROSTER_UPDATE")
            if ml is not None:
                c._fire("PARTY_LOOT_METHOD_CHANGED")
        if kind == "raid" and self.auto_session:
            self.start_raid_session()
        return self.group

    # DisasterZone 1.2: in a raid, loot distribution and rolls are off until the raid's authority starts a raid
    # session. Most suites are about what happens in a running raid, so make_raid starts one (loot + rolls, no BiS
    # lock) on the authority's client. Suites about the session itself set `w.auto_session = False` first.
    auto_session = True

    def start_raid_session(self, features="{ loot = true, rolls = true, lock = false }"):
        """The raid's loot authority (if it runs the addon) starts a raid session. Returns the client or None."""
        for c in self._group_clients(self.group["members"] if self.group else []):
            try:
                if c.eval("local GR = ns and ns.GroupRules; if not (GR and GR.SetSession and ns.loggedIn and IsInRaid() "
                          "and GR:IsAuthority()) then return false end; "
                          "return GR:GetSession() ~= nil or (GR:SetSession(true, nil, %s)) == true" % features):
                    return c
            except Exception:
                pass
        return None

    def make_party(self, clients, leader=None, extra_members=()):
        return self.make_raid(clients, leader=leader, extra_members=extra_members, kind="party", loot_method=3)

    def set_master_looter(self, member, loot_method=2):
        if not self.group:
            raise RuntimeError("no group")
        self.group["ml"] = self._member(member) if member is not None else None
        self.group["loot_method"] = loot_method if member is not None else 3
        self._sync()
        for c in self._group_clients(self.group["members"]):
            c._fire("PARTY_LOOT_METHOD_CHANGED")

    def disband(self):
        old = self.group["members"] if self.group else []
        self.group = None
        self._sync()
        for c in self._group_clients(old):
            c._fire("GROUP_ROSTER_UPDATE")

    def _group_clients(self, members):
        seen, out = set(), []
        for m in members:
            if isinstance(m, Client) and m.runtime is not None and id(m) not in seen:
                seen.add(id(m))
                out.append(m)
        return out

    def group_members(self):
        return list(self.group["members"]) if self.group else []

    def subgroup_of(self, who):
        """Raid subgroup (1..8) of a group member, or None."""
        m = self._member(who)
        if not self.group:
            return None
        for x in self.group["members"]:
            if x is m:
                return self.group["subgroups"].get(id(x), 1) if self.group["kind"] == "raid" else 1
        return None

    def _roster_changed_group(self, extra=()):
        self._sync()
        for c in self._group_clients((self.group["members"] if self.group else []) + list(extra)):
            c._fire("GROUP_ROSTER_UPDATE")

    # -- enemy NPCs and raid marks (strategy board encounter helpers) ------------------------------------------------
    def spawn_npc(self, npc_id, name):
        """An enemy NPC every client knows (a unit once it has a nameplate / is targeted). Returns its GUID
        ("Creature-0-4000-564-100-<npcID>-<spawn>", npc id in field 6 like WoW)."""
        if not hasattr(self, "npcs"):
            self.npcs, self.marks, self.mark_log = {}, {}, []
        self._npc_seq = getattr(self, "_npc_seq", 0) + 1
        guid = "Creature-0-4000-564-100-%d-%010X" % (int(npc_id), 0x1000 + self._npc_seq)
        self.npcs[guid] = {"name": name, "npc_id": int(npc_id), "dead": False}
        self._push_npcs()
        return guid

    def kill_npc(self, guid):
        self.npcs[guid]["dead"] = True
        self._push_npcs()

    def set_npc_hp(self, guid, pct):
        """An NPC's health in percent (UnitHealth / UnitHealthMax of its units on every client)."""
        self.npcs[guid]["hp"] = int(pct)
        self._push_npcs()

    def _push_npcs(self):
        for c in self.clients:
            if c.runtime is not None:
                c._call("set_npcs", c._to_lua(self.npcs))

    def set_raid_target(self, c, guid, idx):
        """SetRaidTarget from client c: leader / assist in a raid (anyone in a party); a mark is on one unit at a
        time; 0 clears. Every group client gets the marks (+ RAID_TARGET_UPDATE)."""
        if not hasattr(self, "marks"):
            self.npcs, self.marks, self.mark_log = {}, {}, []
        g = self.group
        if not g or not any(m is c for m in g["members"]):
            # solo: a player may mark their own target; only they see it
            idx = int(idx)
            mine = getattr(c, "solo_marks", {})
            for other, i in list(mine.items()):
                if i == idx or other == guid:
                    del mine[other]
            if 1 <= idx <= 8:
                mine[guid] = idx
            c.solo_marks = mine
            self.mark_log.append({"by": c.full_name, "guid": guid, "idx": idx, "solo": True, "time": round(self.now, 3)})
            c._call("set_marks", c._to_lua(mine))
            return
        if g["kind"] == "raid" and not self._can_lead(c):
            self.mark_log.append({"by": c.full_name, "guid": guid, "idx": idx, "refused": "not leader / assist"})
            return
        idx = int(idx)
        for other, i in list(self.marks.items()):
            if i == idx or other == guid:
                del self.marks[other]
        if 1 <= idx <= 8:
            self.marks[guid] = idx
        self.mark_log.append({"by": c.full_name, "guid": guid, "idx": idx, "time": round(self.now, 3)})
        for x in self._group_clients(g["members"]):
            x._call("set_marks", x._to_lua(self.marks))

    def set_mark_by_other(self, guid, idx):
        """Another addon / player (e.g. DBM on the leader's client) changes a mark: no permission checks."""
        if not hasattr(self, "marks"):
            self.npcs, self.marks, self.mark_log = {}, {}, []
        for other, i in list(self.marks.items()):
            if i == idx or other == guid:
                del self.marks[other]
        if idx:
            self.marks[guid] = idx
        for x in self._group_clients(self.group["members"] if self.group else []):
            x._call("set_marks", x._to_lua(self.marks))

    def cleu_group(self, *args):
        """One combat log event to every group client (everyone in range sees the raid's casts)."""
        for x in self._group_clients(self.group["members"] if self.group else []):
            x.combat_log(*args)

    def _can_lead(self, c, assist_ok=True):
        g = self.group
        if not g or not any(m is c for m in g["members"]):
            return False
        return g["leader"] is c or (assist_ok and g["kind"] == "raid" and any(a is c for a in g["assistants"]))

    # InviteUnit from client `by` (like WoW: the leader, or a raid assistant, or someone not in a group). The target
    # accepts after `latency` when auto_accept_invites is on; a full party or an offline / grouped target refuses.
    # With auto_accept_invites off the invite waits: the target's client gets PARTY_INVITE_REQUEST (UIParent shows
    # Blizzard's pop-up) and its AcceptGroup / DeclineGroup answers it (accept_group / decline_group).
    # -- guild invites and the friends list (recruitment, 1.6) ------------------------------------------------------
    def guild_invite(self, by, name):
        """GuildInvite(name): the enUS answers WoW sends the inviter; the target gets GUILD_INVITE_REQUEST."""
        self.guild_invite_log = getattr(self, "guild_invite_log", [])
        target = self.find_client(str(name).split("-")[0])
        entry = {"time": round(self.now, 3), "by": by.full_name, "target": str(name), "result": None}
        self.guild_invite_log.append(entry)
        if not by.guild:
            entry["result"] = "not in a guild"
            self._enqueue(0.0, by, "system", "You are not in a guild.")
            return
        if target is None or not self._is_online(target) or target.faction != by.faction:
            entry["result"] = "not found"
            self._enqueue(0.0, by, "system", '"%s" not found.' % str(name).split("-")[0])
            return
        if target.guild:
            entry["result"] = "in a guild"
            self._enqueue(self.latency, by, "system", "%s is already in a guild." % target.name)
            return
        entry["result"] = "invited"
        target.guild_invite_from = by
        self._enqueue(0.0, by, "system", "You have invited %s to join your guild." % target.name)

        def ask():
            if target.runtime is not None:
                target.fire("GUILD_INVITE_REQUEST", by.name, by.guild)
        self._enqueue(self.latency, None, "call", ask)

    def accept_guild(self, c):
        by, c.guild_invite_from = c.guild_invite_from, None
        if by is None or not by.guild:
            return
        c.guild = by.guild
        c.guild_rank = len(self.ranks_for(by.guild)) - 1
        self._sync(roster_changed=True, guild=c.guild)
        for m in self.clients:
            if m.guild == c.guild and m.runtime is not None and m.online:
                self._enqueue(self.latency, m, "system", "%s has joined the guild." % c.name)

    def decline_guild(self, c):
        by, c.guild_invite_from = c.guild_invite_from, None
        if by is not None:
            self._enqueue(self.latency, by, "system", "%s declines your guild invitation." % c.name)

    def friend_rows(self, c):
        rows = []
        for f in c.friends:
            t = self.find_client(f["name"].split("-")[0])
            on = t is not None and self._is_online(t)
            rows.append({"name": f["name"].split("-")[0], "connected": on, "level": t.level if t else 0,
                         "area": (getattr(t, "zone", None) or "Shattrath City") if on else None,
                         "className": (t.class_file.capitalize() if t else "Unknown"), "notes": f.get("note") or ""})
        return rows

    def add_friend(self, c, name, note):
        full = str(name)
        if any(f["name"].split("-")[0].lower() == full.split("-")[0].lower() for f in c.friends):
            self._enqueue(0.0, c, "system", "%s is already your friend." % full.split("-")[0])
            return
        if len(c.friends) >= 100:
            self._enqueue(0.0, c, "system", "Your friends list is full.")
            return
        c.friends.append({"name": full, "note": note or ""})
        self._enqueue(0.0, c, "system", "%s added to friends." % full.split("-")[0])
        self._enqueue(0.0, None, "call", lambda: c.runtime is not None and c.fire("FRIENDLIST_UPDATE"))

    def remove_friend(self, c, name):
        n = str(name).split("-")[0].lower()
        before = len(c.friends)
        c.friends = [f for f in c.friends if f["name"].split("-")[0].lower() != n]
        if len(c.friends) != before:
            self._enqueue(0.0, c, "system", "%s removed from friends." % str(name).split("-")[0])
            self._enqueue(0.0, None, "call", lambda: c.runtime is not None and c.fire("FRIENDLIST_UPDATE"))

    def _notify_friends(self, who, text):
        for c in self.clients:
            if c is not who and c.runtime is not None and any(
                    f["name"].split("-")[0] == who.name for f in getattr(c, "friends", [])):
                self._enqueue(self.latency, c, "system", text)
                self._enqueue(self.latency, None, "call", lambda c=c: c.runtime is not None and c.fire("FRIENDLIST_UPDATE"))

    def invite(self, by, name):
        target = self.find_client(str(name).split("-")[0])
        entry = {"time": round(self.now, 3), "by": by.full_name, "target": str(name), "result": None}
        self.invite_log.append(entry)
        g = self.group
        if g and any(m is by for m in g["members"]) and not self._can_lead(by):
            entry["result"] = "not leader"
            return
        if target is None or not self._is_online(target):
            entry["result"] = "offline"
            self._enqueue(0.0, by, "system", "Cannot find player '%s'." % str(name))
            return
        if g and any(m is target for m in g["members"]):
            entry["result"] = "already in group"
            if not any(m is by for m in g["members"]):
                # (in somebody else's group: WoW tells the inviter, ERR_ALREADY_IN_GROUP_S)
                self._enqueue(self.latency, by, "system", "%s is already in a group." % target.name)
            return

        def accept():
            gg = self.group
            if gg and any(m is target for m in gg["members"]):
                entry["result"] = "already in group"
                return
            if gg is None:
                self.group = {"kind": "party", "members": [by, target], "leader": by, "assistants": [], "ml": None,
                              "loot_method": 3, "threshold": 2, "subgroups": {id(by): 1, id(target): 1}}
            elif not any(m is by for m in gg["members"]):
                entry["result"] = "inviter left"
                return
            else:
                if gg["kind"] == "party" and len(gg["members"]) >= 5:
                    entry["result"] = "party full"
                    self._enqueue(0.0, by, "system", "Your party is full.")
                    return
                if len(gg["members"]) >= 40:
                    entry["result"] = "raid full"
                    return
                sub = 1
                if gg["kind"] == "raid":
                    counts = {}
                    for m in gg["members"]:
                        s = gg["subgroups"].get(id(m), 1)
                        counts[s] = counts.get(s, 0) + 1
                    sub = next(s for s in range(1, 9) if counts.get(s, 0) < 5)
                gg["members"].append(target)
                gg["subgroups"][id(target)] = sub
            entry["result"] = "joined"
            self._roster_changed_group()
        if self.auto_accept_invites:
            self._enqueue(self.latency, None, "call", accept)
            return
        entry["result"] = "pending"
        self.pending_invites[id(target)] = (entry, accept)
        shown = by.name if by.realm == target.realm else by.full_name

        def ask():
            if self.pending_invites.get(id(target), (None,))[0] is entry and target.runtime is not None:
                target.fire("PARTY_INVITE_REQUEST", shown, False, False, False, by.realm != target.realm, False,
                            by.guid)
        self._enqueue(self.latency, None, "call", ask)

    # AcceptGroup / DeclineGroup from client `c`: answers the invite waiting for it (auto_accept_invites off).
    def accept_group(self, c):
        pending = self.pending_invites.pop(id(c), None)
        if pending:
            self._enqueue(self.latency, None, "call", pending[1])

    def decline_group(self, c):
        pending = self.pending_invites.pop(id(c), None)
        if pending:
            entry = pending[0]
            entry["result"] = "declined"
            by = self.find_client(entry["by"].split("-")[0])
            if by is not None:
                self._enqueue(self.latency, by, "system", "%s declines your group invitation." % c.name)

    # PromoteToLeader from client `by` (the leader): the named member leads now. Like WoW, the roster stays the same
    # (members see GROUP_ROSTER_UPDATE with the same names) and everyone gets PARTY_LEADER_CHANGED.
    def promote(self, by, name):
        g = self.group
        if not g or g["leader"] is not by:
            return
        base = str(name).split("-")[0]
        target = next((m for m in g["members"] if m.name == base), None)
        if target is None or target is by:
            return
        self.set_leader(target)

    def set_leader(self, member):
        """The group's lead passes to `member` (a client in the group): PARTY_LEADER_CHANGED + GROUP_ROSTER_UPDATE."""
        g = self.group
        g["leader"] = self._member(member)
        g["assistants"] = [a for a in g["assistants"] if a is not g["leader"]]
        self._sync()
        for c in self._group_clients(g["members"]):
            c._fire("PARTY_LEADER_CHANGED")
            c._fire("GROUP_ROSTER_UPDATE")

    # UninviteUnit from client `by` (like WoW: the leader, or a raid assistant): the member leaves the group at once.
    def uninvite(self, by, name):
        g = self.group
        if not g or not any(m is by for m in g["members"]) or not self._can_lead(by):
            return
        base = str(name).split("-")[0]
        target = next((m for m in g["members"] if m.name == base), None)
        if target is None or target is by:
            return
        g["members"] = [m for m in g["members"] if m is not target]
        g["subgroups"].pop(id(target), None)
        if g.get("ml") is target:
            g["ml"] = None
        self._roster_changed_group(extra=[target])

    def convert_to_raid(self, by):
        g = self.group
        if not g or g["kind"] != "party" or g["leader"] is not by:
            return
        g["kind"] = "raid"
        for i, m in enumerate(g["members"]):
            g["subgroups"][id(m)] = 1
        self._enqueue(self.latency, None, "call", self._roster_changed_group)

    def set_raid_subgroup(self, by, index, sub):
        g = self.group
        if not g or g["kind"] != "raid" or not self._can_lead(by):
            return
        index, sub = int(index), int(sub)
        if not (1 <= index <= len(g["members"])) or not (1 <= sub <= 8):
            return
        m = g["members"][index - 1]
        if sum(1 for x in g["members"] if g["subgroups"].get(id(x)) == sub and x is not m) >= 5:
            return   # WoW refuses a move into a full group
        g["subgroups"][id(m)] = sub
        self._enqueue(self.latency, None, "call", self._roster_changed_group)

    def swap_raid_subgroup(self, by, i1, i2):
        g = self.group
        if not g or g["kind"] != "raid" or not self._can_lead(by):
            return
        i1, i2 = int(i1), int(i2)
        if not (1 <= i1 <= len(g["members"])) or not (1 <= i2 <= len(g["members"])):
            return
        a, b = g["members"][i1 - 1], g["members"][i2 - 1]
        g["subgroups"][id(a)], g["subgroups"][id(b)] = g["subgroups"].get(id(b), 1), g["subgroups"].get(id(a), 1)
        self._enqueue(self.latency, None, "call", self._roster_changed_group)

    # -- instance / encounters -----------------------------------------------------------------------------------
    def enter_instance(self, name="Karazhan", instance_id=532, instance_type="raid", max_players=10,
                       difficulty_id=3, difficulty_name=None, clients=None):
        self.instance = {"name": name, "type": instance_type, "instanceID": instance_id, "maxPlayers": max_players,
                         "difficultyID": difficulty_id,
                         "difficultyName": difficulty_name or ("%d Player" % max_players if instance_type == "raid" else "Normal")}
        targets = clients if clients is not None else (
            [m for m in self.group["members"] if isinstance(m, Client)] if self.group else list(self.clients))
        self.instance_members = {c.full_name for c in targets}
        self._sync()
        for c in targets:
            if c.runtime is not None:
                c._fire("PLAYER_ENTERING_WORLD", False, False)
                c._fire("ZONE_CHANGED_NEW_AREA")
                c._fire("UPDATE_INSTANCE_INFO")

    def leave_instance(self, clients=None):
        targets = clients if clients is not None else [c for c in self.clients if c.full_name in self.instance_members]
        for c in targets:
            self.instance_members.discard(c.full_name)
        if not self.instance_members:
            self.instance = None
        self._sync()
        for c in targets:
            if c.runtime is not None:
                c._fire("PLAYER_ENTERING_WORLD", False, False)
                c._fire("ZONE_CHANGED_NEW_AREA")

    def set_dead(self, who, dead=True, ghost=False):
        """Mark a member dead (corpse) or a ghost (released) for UnitIsDeadOrGhost / UnitIsGhost; alive with
        dead=False."""
        m = self._member(who)
        m.dead, m.ghost = bool(dead) and not ghost, bool(ghost)
        self._sync()

    def set_position(self, who, map_id=None, x=None, y=None, subzone=None):
        """Where a member stands in the open world: uiMapID (wowmock M.outdoor_maps, e.g. 1951 Nagrand) and 0..1 map
        coordinates (x east, y south), plus the subzone (GetSubZoneText). Every client sees it: C_Map for the player,
        CheckInteractDistance between two players. map_id=None: nowhere known (as before)."""
        m = self._member(who)
        m.pos = None if map_id is None else {"map": int(map_id), "x": float(x), "y": float(y)}
        if subzone is not None or map_id is None:
            m.subzone = subzone
        self._sync()

    def encounter(self, encounter_id, name, success=True, difficulty_id=None, group_size=None, clients=None):
        """Fire ENCOUNTER_START, then ENCOUNTER_END (+ BOSS_KILL on success) on the given/grouped clients."""
        targets = clients if clients is not None else (
            self._group_clients(self.group["members"]) if self.group else [c for c in self.clients if c.runtime])
        diff = difficulty_id or (self.instance or {}).get("difficultyID", 3)
        size = group_size or (len(self.group["members"]) if self.group else 1)
        for c in targets:
            c._fire("ENCOUNTER_START", encounter_id, name, diff, size)
        for c in targets:
            c._fire("ENCOUNTER_END", encounter_id, name, diff, size, 1 if success else 0)
            if success:
                c._fire("BOSS_KILL", encounter_id, name)

    # -- loot ----------------------------------------------------------------------------------------------------
    def broadcast_loot_received(self, winner, item_id, count=1, clients=None, give_item=False):
        """Fire CHAT_MSG_LOOT on every raid member: 'You receive loot: ...' for the winner, '<Name> receives
        loot: ...' for everyone else. Returns {client full name: text}."""
        w = self._member(winner)
        if clients is None:
            if self.group:
                clients = self._group_clients(self.group["members"])
            else:
                clients = [w] if isinstance(w, Client) and w.runtime is not None else []
        out = {}
        for c in clients:
            if c.runtime is None:
                continue
            is_self = c is w
            display = w.name if normalize_realm(w.realm) == normalize_realm(c.realm) else w.full_name
            out[c.full_name] = c._call("loot_message", display, w.full_name, w.guid, int(item_id), int(count), is_self)
        if give_item and isinstance(w, Client) and w.runtime is not None:
            w._call("give_item", int(item_id), int(count))
        return out

    def define_item(self, item_id, name, quality=4, equip_loc="INVTYPE_NON_EQUIP_IGNORE", class_id=15, subclass_id=0,
                    ilvl=0, icon=None, min_level=0, bind=1, stack=1):
        """Add/override an item in every client's item DB (current and future runtimes)."""
        self.custom_items[int(item_id)] = (name, quality, equip_loc, class_id, subclass_id, icon, ilvl, min_level, bind, stack)
        for c in self.clients:
            if c.runtime is not None:
                c._define_item(int(item_id))

    # -- bus -----------------------------------------------------------------------------------------------------
    def _enqueue(self, delay, recipient, kind, payload):
        heapq.heappush(self._queue, (self.now + delay, next(self._seq), recipient, kind, payload))

    def _deliver_due(self):
        while self._queue and self._queue[0][0] <= self.now + 1e-9:
            _, _, rc, kind, payload = heapq.heappop(self._queue)
            if kind == "call":
                payload()
                continue
            if rc is None or rc.runtime is None or not rc.online:
                if kind == "addon":
                    payload[-1].setdefault("dropped", []).append(rc.full_name if rc else "?")
                continue
            if kind == "addon":
                prefix, text, chat_type, sender, target, logged, entry = payload
                ok = rc._call("deliver_addon", prefix, text, chat_type, sender, target, logged)
                entry.setdefault("delivered" if ok else "unregistered", []).append(rc.full_name)
            elif kind == "chat":
                rc._call("deliver_chat", *payload)
            elif kind == "whisper_inform":
                rc._call("deliver_whisper_inform", *payload)
            elif kind == "system":
                rc._call("system_message", payload)

    def _route_addon(self, sender, prefix, text, chat_type, target, logged):
        entry = {"time": round(self.now, 3), "sender": sender.full_name, "prefix": prefix, "text": text,
                 "chat_type": chat_type, "target": target, "logged": logged}
        self.addon_log.append(entry)
        recips = self._recipients(sender, chat_type, target, entry)
        entry["recipients"] = [c.full_name for c in recips]
        fault = getattr(self, "addon_fault", None)
        for c in recips:
            tgt = c.full_name if chat_type == "WHISPER" else ""
            payload_text = text
            if fault is not None:
                # fault injection (tests): addon_fault(entry, recipient) -> None deliver / False lose / bytes replace
                res = fault(entry, c)
                if res is False:
                    entry.setdefault("lost", []).append(c.full_name)
                    continue
                if isinstance(res, (bytes, str)):
                    payload_text = res
            self._enqueue(self.latency, c, "addon", (prefix, payload_text, chat_type, sender.full_name, tgt, logged, entry))
        return 0

    def _recipients(self, sender, chat_type, target, entry):
        online = [c for c in self.clients if c.online and c.runtime is not None]
        if chat_type == "WHISPER":
            tc = self.find_client(target, sender.realm)
            if tc is None or not tc.online or tc.runtime is None:
                entry["error"] = "target offline/unknown"
                self._enqueue(self.latency, sender, "system", "No player named '%s' is currently playing." % target)
                return []
            return [tc]
        if chat_type in ("GUILD", "OFFICER"):
            if not sender.guild:
                return []
            out = [c for c in online if c.guild == sender.guild]
            if chat_type == "OFFICER":
                if sender.guild_rank > self.officer_rank:
                    entry["error"] = "sender is not an officer"
                    return []
                out = [c for c in out if c.guild_rank <= self.officer_rank]
            return out
        if chat_type in ("RAID", "PARTY", "INSTANCE_CHAT", "BATTLEGROUND", "RAID_WARNING"):
            g = self.group
            if not g or not any(m is sender for m in g["members"]):
                entry["error"] = "sender not in group"
                return []
            members = g["members"]
            if chat_type == "PARTY" and g["kind"] == "raid":
                sub = self._subgroup_of(sender)
                members = [m for i, m in enumerate(members) if i // 5 + 1 == sub]
            return [m for m in members if isinstance(m, Client) and m.online and m.runtime is not None]
        if chat_type in ("SAY", "YELL", "EMOTE"):
            return online
        entry["error"] = "chat type %s not routed by the mock" % chat_type
        return []

    def _subgroup_of(self, member):
        for i, m in enumerate(self.group["members"]):
            if m is member:
                return i // 5 + 1
        return None

    def player_roll(self, who, value=None, lo=1, hi=100):
        """Simulate /roll by `who` (Client, ExtraMember or name). Every group client (or just the roller when
        solo) receives CHAT_MSG_SYSTEM RANDOM_ROLL_RESULT "Name rolls N (lo-hi)" after `latency`.
        `value` None = deterministic pseudo-random from self._roll_rng. Returns the rolled value."""
        import random as _random
        m = self._member(who)
        if m is None:
            raise ValueError("player_roll: unknown member %r" % (who,))
        if not hasattr(self, "_roll_rng"):
            self._roll_rng = _random.Random(4242)
        if value is None:
            value = self._roll_rng.randint(int(lo), int(hi))
        recips = self._group_clients(self.group["members"]) if self.group and any(x is m for x in self.group["members"]) else []
        if isinstance(m, Client) and m.runtime is not None and m not in recips:
            recips.append(m)
        for c in recips:
            display = m.name if normalize_realm(m.realm) == normalize_realm(c.realm) else m.full_name
            text = "%s rolls %d (%d-%d)" % (display, int(value), int(lo), int(hi))
            self._enqueue(self.latency, c, "system", text)
        self.roll_log.append({"time": round(self.now, 3), "who": m.full_name, "value": int(value), "lo": int(lo), "hi": int(hi)})
        return int(value)

    def _route_chat(self, sender, text, chat_type, language, target):
        entry = {"time": round(self.now, 3), "sender": sender.full_name, "chat_type": chat_type,
                 "text": text.decode("utf-8", "replace"), "target": target}
        self.chat_log.append(entry)
        if chat_type in ("RAID", "RAID_WARNING") and not self.group:
            self._enqueue(0.0, sender, "system", "You are not in a raid group")
            return
        recips = self._recipients(sender, chat_type, target, entry)
        entry["recipients"] = [c.full_name for c in recips]
        is_leader = bool(self.group) and self.group["leader"] is sender
        for c in recips:
            display = sender.name if normalize_realm(sender.realm) == normalize_realm(c.realm) else sender.full_name
            self._enqueue(self.latency, c, "chat", (chat_type, text, sender.full_name, display, sender.guid, is_leader))
        if chat_type == "WHISPER" and recips:
            tc = recips[0]
            tdisp = tc.name if normalize_realm(tc.realm) == normalize_realm(sender.realm) else tc.full_name
            self._enqueue(self.latency, sender, "whisper_inform", (text, tc.full_name, tdisp, tc.guid))

    # -- state sync ----------------------------------------------------------------------------------------------
    def _base_record(self, m):
        guild = getattr(m, "guild", None)
        ranks = self.ranks_for(guild) if guild else []
        rank = getattr(m, "guild_rank", None) if guild else None
        notes = self.notes.get(m.full_name, {})
        in_inst = self.instance is not None and m.full_name in self.instance_members
        return {
            "name": m.name, "realm": m.realm, "full": m.full_name, "class": m.class_file, "level": m.level,
            "guid": m.guid, "online": self._is_online(m), "race": m.race, "sex": getattr(m, "sex", 2),
            "faction": m.faction, "guild": guild, "guild_rank": rank,
            "guild_rank_name": ranks[rank] if guild and rank is not None and rank < len(ranks) else None,
            "public_note": notes.get("public", ""), "officer_note": notes.get("officer", ""),
            "zone": self.instance["name"] if in_inst else self.zone,
            "dead": bool(getattr(m, "dead", False)), "ghost": bool(getattr(m, "ghost", False)),
            "pos": getattr(m, "pos", None), "subzone": getattr(m, "subzone", None),
        }

    def _state_for(self, c):
        me = self._base_record(c)
        group = None
        if self.group and any(m is c for m in self.group["members"]):
            g = self.group
            members = []
            ml_index = None
            for i, m in enumerate(g["members"]):
                r = self._base_record(m)
                r["group_rank"] = 2 if m is g["leader"] else (1 if any(a is m for a in g["assistants"]) else 0)
                r["subgroup"] = (g.get("subgroups") or {}).get(id(m), i // 5 + 1) if g["kind"] == "raid" else 1
                r["isML"] = m is g["ml"]
                r["raid_index"] = i + 1
                if m is g["ml"]:
                    ml_index = i + 1
                members.append(r)
                if m is c:
                    me = r
            group = {"kind": g["kind"], "members": members, "loot_method": g["loot_method"], "ml_index": ml_index,
                     "threshold": g["threshold"]}
        guild = None
        if c.guild:
            roster = [self._base_record(m) for m in self._guild_members(c.guild)]
            roster.sort(key=lambda r: (not r["online"], r["name"].lower()))
            guild = {"name": c.guild, "ranks": self.ranks_for(c.guild), "roster": roster,
                     "info_text": self.guild_texts.get(c.guild, ""), "officer_rank": self.officer_rank, "motd": ""}
        inst = self.instance if (self.instance and c.full_name in self.instance_members) else None
        players = [self._base_record(x) for x in self.clients if x is not c and x.online and x.runtime is not None]
        return {"self": me, "realm": normalize_realm(c.realm), "realm_display": c.realm, "guild": guild,
                "group": group, "instance": inst, "zone": self.zone, "players": players,
                "loaded_addons": list(self.other_addons) + list(c.other_addons)}

    def _sync(self, roster_changed=False, guild=None):
        for c in self.clients:
            if c.runtime is not None:
                c._push_state()
                if roster_changed and (guild is None or c.guild == guild):
                    if c._pristine and not c.loaded:
                        # (before its login the mock has no roster to update: a no-op that keeps it pristine)
                        c._M.set_time(c.time_offset + self.now, self.server_time)
                        c._M.roster_changed()
                    else:
                        c._call("roster_changed")

    # -- persistence ---------------------------------------------------------------------------------------------
    def saved_variables(self, client_or_name):
        c = client_or_name if isinstance(client_or_name, Client) else self.find_client(client_or_name)
        return dict(self.saved.get(c.full_name, {}))

    # -- diagnostics ---------------------------------------------------------------------------------------------
    def errors(self):
        out = []
        for c in self.clients:
            for e in c.errors:
                out.append("[%s] %s" % (c.full_name, e))
        return out

    def assert_no_errors(self):
        errs = self.errors()
        if errs:
            raise LuaErrorsFound("%d Lua error(s):\n\n%s" % (len(errs), "\n\n".join(errs)))

    def clear_errors(self):
        for c in self.clients:
            c.clear_errors()

    def _reports(self):
        agg = {"fields": {}, "methods": {}, "globals": {}, "events": {}, "templates": {}}
        sources = list(self._archived_reports)
        for c in self.clients:
            if c.runtime is not None:
                sources.append(c._report_tables())
        for rep in sources:
            for label, key, where, count in rep.get("fields", []):
                e = agg["fields"].setdefault((label, key), [where, 0])
                e[1] += int(count)
            for label, key, where, count in rep.get("methods", []):
                e = agg["methods"].setdefault((label, key), [where, 0])
                e[1] += int(count)
            for name, where, count in rep.get("globals", []):
                e = agg["globals"].setdefault(name, [where, 0])
                e[1] += int(count)
            for name, where in rep.get("events", []):
                agg["events"].setdefault(name, where)
            for name, where in rep.get("templates", []):
                agg["templates"].setdefault(name, where)
        return agg

    @staticmethod
    def _addon_site(where):
        """True for locations in the addon's own code (Interface/AddOns/..., excluding embedded Libs/)."""
        return isinstance(where, str) and "Interface/AddOns/" in where and "/Libs/" not in where

    def report_unknown_fields(self, addon_only=True, lowercase=False):
        """Unknown FIELD reads on mock frames (they returned nil): which template children the addon assumed.
        Only CamelCase keys (template-child style, e.g. .TitleText) are listed by default; lowercase keys are
        usually the addon's own not-yet-assigned fields (lowercase=True lists them too)."""
        agg = self._reports()["fields"]
        lines, hidden = [], 0
        for (label, key), (where, count) in sorted(agg.items()):
            if addon_only and not self._addon_site(where):
                continue
            if not lowercase and not key[:1].isupper():
                hidden += 1
                continue
            lines.append("%-45s .%-24s x%-4d first at %s" % (label, key, count, where))
        if hidden:
            lines.append("(+%d lowercase field read(s) hidden; report_unknown_fields(lowercase=True) lists them)" % hidden)
        return "\n".join(lines) if lines else "(no unknown field reads)"

    def report_unknown_methods(self, addon_only=True):
        """Method calls absorbed by the catch-all (no-op returning nil)."""
        agg = self._reports()["methods"]
        lines = []
        for (label, key), (where, count) in sorted(agg.items()):
            if addon_only and not self._addon_site(where):
                continue
            lines.append("%-45s :%-28s x%-4d first at %s" % (label, key, count, where))
        return "\n".join(lines) if lines else "(no unknown method calls)"

    def report_missing_globals(self, addon_only=True):
        """Reads of globals that the mock does not define (nil at runtime)."""
        agg = self._reports()["globals"]
        lines = []
        for name, (where, count) in sorted(agg.items()):
            if addon_only and not self._addon_site(where):
                continue
            lines.append("%-40s x%-4d first at %s" % (name, count, where))
        return "\n".join(lines) if lines else "(no missing globals)"

    def report_unknown_events(self):
        agg = self._reports()["events"]
        return "\n".join("%-40s first at %s" % (k, v) for k, v in sorted(agg.items())) or "(no unknown events)"

    def report_warnings(self):
        seen, lines = set(), []
        for w in self.warnings:
            if w not in seen:
                seen.add(w)
                lines.append(w)
        for c in self.clients:
            for w in c.warnings:
                if w not in seen:
                    seen.add(w)
                    lines.append(w)
        return "\n".join(lines) if lines else "(no warnings)"

    def report(self):
        return "\n".join([
            "== errors ==", "\n\n".join(self.errors()) or "(none)",
            "== warnings ==", self.report_warnings(),
            "== unknown template fields ==", self.report_unknown_fields(),
            "== unknown methods ==", self.report_unknown_methods(),
            "== missing globals ==", self.report_missing_globals(),
            "== unknown events ==", self.report_unknown_events(),
        ])


# ------------------------------------------------------------------------------------------------------------------
# Client
# ------------------------------------------------------------------------------------------------------------------
class Client:
    _index = itertools.count()

    def __init__(self, world, name, realm=None, class_file="PALADIN", guild="Casual Disaster", guild_rank=3,
                 online=True, level=70, race="Human", faction="Alliance", sex=2, talents=(41, 20, 0),
                 legacy_globals=False, permissive_fields=False, items_uncached=False, preload_lua=None,
                 addon_dir=None, other_addons=(), bank_requires_open=True, sv_before_files=None, lod_addons=None,
                 packs=None, packs_off=(), pack_order=None):
        """One simulated player = one Lua runtime. Created online (runtime ready, addon not yet loaded) unless
        online=False (call .login() later). legacy_globals=True defines deprecation-gated globals (GetItemInfo,
        GetContainer*, GetAddOnMetadata, GuildRoster, GetLootMethod). permissive_fields=True makes unknown frame
        fields return auto-created mock frames instead of nil. items_uncached=True makes item data load
        asynchronously (first query returns nil + GET_ITEM_INFO_RECEIVED/ITEM_DATA_LOAD_RESULT next tick).
        sv_before_files: when SavedVariables are assigned. None (default) follows the TOC: before the addon files
        run with "## LoadSavedVariablesFirst: 1", else after them, right before ADDON_LOADED (WoW's classic order).
        True / False force one order (False = a client that ignores the directive).
        lod_addons: {name: folder} of the load-on-demand addons installed next to it (default: DisasterZone_Rooms,
        rooms_dir_for(addon_dir)); {} = not installed.
        packs: {name: folder} of the game packs installed (default: every pack next to the addon folder, packs_for);
        {} = none. packs_off: names of installed packs switched off in the AddOn list (they don't load).
        pack_order: "early" | "real" (default PACK_ORDER)."""
        self.world = world
        self.name = name
        self.realm = realm or world.realm
        self.class_file = class_file
        self.guild = guild
        self.friends = []                    # the game's friends list: [{"name": full name, "note": text}]
        self.guild_invite_from = None        # a guild invite waiting for AcceptGuild / DeclineGuild
        self.guild_rank = guild_rank
        self.level = level
        self.race = race
        self.faction = faction
        self.sex = sex
        self.talents = list(talents)
        self.legacy_globals = legacy_globals
        self.permissive_fields = permissive_fields
        self.items_uncached = items_uncached
        self.preload_lua = preload_lua
        self.addon_dir = addon_dir or world.addon_dir
        self._addon_name = None
        # {global name: Lua source}: saved variables of OTHER addons this client has loaded (they load before ours,
        # e.g. the old "CDLoot" next to DisasterZone); written back at logout like the client would
        self.other_saved = {}
        self.other_addons = list(other_addons)
        self.bank_requires_open = bank_requires_open
        self.sv_before_files = sv_before_files
        self.lod_addons = dict(lod_addons) if lod_addons is not None else {ROOMS_NAME: rooms_dir_for(self.addon_dir)}
        self.packs = dict(packs) if packs is not None else packs_for(self.addon_dir)
        self.packs_off = frozenset(packs_off or ())
        self.pack_order = pack_order or PACK_ORDER
        self._load_rooms = None                      # (load_addon: LOAD_ROOMS at login; None: as it is now)
        self.index = next(Client._index)
        self.time_offset = 1000.0 + 137.25 * self.index
        self.online = bool(online)
        self.runtime = None
        self._M = None
        self._pristine = False
        self.loaded = False
        self.load_warnings = []
        self._old_errors = []
        self._old_warnings = []
        self._old_printed = []
        self._old_chat = []
        if world.find_client(self.full_name):
            raise ValueError("duplicate client %s" % self.full_name)
        world._register(self)
        if self.online:
            self._new_runtime()
        world._sync()

    # -- identity ------------------------------------------------------------------------------------------------
    @property
    def full_name(self):
        return "%s-%s" % (self.name, normalize_realm(self.realm))

    @property
    def guid(self):
        return make_guid(self.name, self.realm)

    def __repr__(self):
        return "<Client %s>" % self.full_name

    # -- runtime -------------------------------------------------------------------------------------------------
    def _new_runtime(self):
        rt = lua51.LuaRuntime(unpack_returned_tuples=True, register_eval=False, register_builtins=False)
        self.runtime = rt
        w = self.world
        cfg = to_lua(rt, {
            "name": self.name, "realm": normalize_realm(self.realm), "realm_display": self.realm,
            "class_file": self.class_file, "level": self.level, "guid": self.guid,
            "talents": self.talents, "legacy_globals": self.legacy_globals,
            "permissive_fields": self.permissive_fields, "items_uncached": self.items_uncached,
            "addon_throttle": w.addon_throttle, "onupdate_hidden": w.onupdate_hidden,
            "time_offset": self.time_offset + w.now, "server_time": w.server_time,
            "known_events": _known_events(), "bank_requires_open": self.bank_requires_open,
        })
        # The callbacks reach the client through `o` (not `self`): a pre-loaded client's runtime (build_templates)
        # changes hands when a client takes it over.
        o = self._owner = [self]
        py = rt.table_from({
            "send_addon": lambda *a: o[0]._py_send_addon(*a), "send_chat": lambda *a: o[0]._py_send_chat(*a),
            "set_guild_info_text": lambda *a: o[0]._py_set_guild_info_text(*a),
            "set_note": lambda *a: o[0]._py_set_note(*a),
            "give_master_loot": lambda *a: o[0]._py_give_master_loot(*a),
            "item_lookup": lambda *a: o[0]._py_item_lookup(*a),
            "random_roll": lambda *a: o[0]._py_random_roll(*a),
            "set_raid_target": lambda guid, idx: o[0].world.set_raid_target(o[0], guid, idx),
            "invite": lambda name: o[0].world.invite(o[0], name),
            "accept_group": lambda: o[0].world.accept_group(o[0]),
            "promote": lambda name: o[0].world.promote(o[0], name),
            "decline_group": lambda: o[0].world.decline_group(o[0]),
            "uninvite": lambda name: o[0].world.uninvite(o[0], name),
            "guild_invite": lambda name: o[0].world.guild_invite(o[0], name),
            "accept_guild": lambda: o[0].world.accept_guild(o[0]),
            "decline_guild": lambda: o[0].world.decline_guild(o[0]),
            "friends": lambda: to_lua(o[0].runtime, o[0].world.friend_rows(o[0])),
            "add_friend": lambda name, note: o[0].world.add_friend(o[0], name, note),
            "remove_friend": lambda name: o[0].world.remove_friend(o[0], name),
            "convert_to_raid": lambda: o[0].world.convert_to_raid(o[0]),
            "set_raid_subgroup": lambda i, g: o[0].world.set_raid_subgroup(o[0], i, g),
            "swap_raid_subgroup": lambda a, b: o[0].world.swap_raid_subgroup(o[0], a, b),
            "load_lod": lambda name: o[0]._py_load_lod(name),
            "rand": _crt_rand, "srand": _crt_srand,
        })
        self._lua_gc = rt.globals().collectgarbage
        sources = rt.table_from(_mock_sources())
        res = rt.globals().loadstring(_mock_chunk("mock.lua"), "@wowmock/mock.lua")
        fn = res[0] if isinstance(res, tuple) else res
        if fn is None:
            raise RuntimeError("wowmock/mock.lua failed to compile: %s" % (res[1],))
        self._M = fn(cfg, py, sources)
        self._cover_table = _cover_tables(rt) if COVER_FILE else None
        self._M.load_items(_mock_chunk("items.lua"))
        for iid in self.world.custom_items:
            self._define_item(iid)
        self._push_state()
        if self.preload_lua:
            self.eval(self.preload_lua)
        # nothing but the harness has touched this runtime yet: load_addon may swap in a pre-loaded one
        self._pristine = not self.preload_lua

    # The mock's control table. Going through `M` marks the runtime as touched (a test's own set-up before
    # load_addon): such a client loads its files itself instead of taking a pre-loaded runtime (build_templates).
    @property
    def M(self):
        self._pristine = False
        return self._M

    @M.setter
    def M(self, value):
        self._M = value

    def _define_item(self, iid):
        name, q, loc, cls, sub, icon, ilvl, minlvl, bind, stack = self.world.custom_items[iid]
        self._M.define_item(iid, name, q, loc, cls, sub, icon, ilvl, minlvl, bind, stack)

    def _push_state(self):
        if self.runtime is None:
            return
        self._M.set_world(to_lua(self.runtime, self.world._state_for(self)))

    def _set_time(self):
        self.M.set_time(self.time_offset + self.world.now, self.world.server_time)

    def _call(self, fname, *args):
        if self.runtime is None:
            raise RuntimeError("%s is offline (no runtime)" % self.full_name)
        self._set_time()
        return self.M[fname](*args)

    def _step(self, dt):
        self.M.step(self.time_offset + self.world.now, self.world.server_time, dt)

    def _fire(self, event, *args):
        if self.runtime is not None:
            self._call("fire", event, *[self._to_lua(a) for a in args])

    def _to_lua(self, v):
        if isinstance(v, (dict, list, tuple)):
            return to_lua(self.runtime, v)
        return v

    # -- python callbacks (called from Lua) ------------------------------------------------------------------------
    def _py_send_addon(self, prefix, hexpayload, chat_type, target, logged):
        return self.world._route_addon(self, prefix, bytes.fromhex(hexpayload), chat_type, target, bool(logged))

    def _py_send_chat(self, hextext, chat_type, language, target):
        self.world._route_chat(self, bytes.fromhex(hextext), chat_type, language, target)

    def _py_set_guild_info_text(self, hextext):
        text = bytes.fromhex(hextext)
        if len(text) > 500:
            self.world.warnings.append("SetGuildInfoText: %d bytes truncated to 500 (WoW limit)" % len(text))
            text = text[:500]
        self.world.guild_texts[self.guild] = text.decode("utf-8", "replace")
        self.world._sync(roster_changed=True, guild=self.guild)

    def _py_set_note(self, full, kind, hexnote):
        note = bytes.fromhex(hexnote).decode("utf-8", "replace")
        if len(note.encode("utf-8")) > 31:
            self.world.warnings.append("guild %s note for %s longer than 31 bytes: truncated like WoW" % (kind, full))
            note = note.encode("utf-8")[:31].decode("utf-8", "ignore")
        n = self.world.notes.setdefault(full, {"public": "", "officer": ""})
        n["public" if kind == "public" else "officer"] = note
        self.world._sync(roster_changed=True, guild=self.guild)

    def _py_random_roll(self, lo, hi):
        lo = int(lo) if lo is not None else 1
        hi = int(hi) if hi is not None else 100
        self.world.player_roll(self, None, lo, hi)

    def _py_give_master_loot(self, full, item_id, count):
        w = self.world

        def deliver():
            winner = w._member(full)
            w.broadcast_loot_received(winner, int(item_id), int(count), give_item=True)
        w._enqueue(0.2, None, "call", deliver)

    def _py_item_lookup(self, item_id):
        r = _fallback_items().get(str(int(item_id)))
        if not r:
            return None
        return tuple(r)

    # -- lifecycle -----------------------------------------------------------------------------------------------
    @property
    def addon_name(self):
        """The addon this client runs: the name of the folder's .toc (an old-version fixture is still "CDLoot")."""
        name = self._addon_name
        if name is None:
            tocs = [f[:-4] for f in _listdir(self.addon_dir) if f.lower().endswith(".toc")]
            name = self._addon_name = ADDON_NAME if (ADDON_NAME in tocs or not tocs) else sorted(tocs)[0]
        return name

    def toc(self):
        return parse_toc(self.addon_dir, self.addon_name)

    def load_addon(self, reload=False):
        """Parse DisasterZone.toc, run every listed file with ("DisasterZone", ns), apply SavedVariables, then fire
        ADDON_LOADED, VARIABLES_LOADED, SPELLS_CHANGED, PLAYER_LOGIN, PLAYER_ENTERING_WORLD(true, false)
        (or (false, true) when reload=True)."""
        if self.runtime is None:
            raise RuntimeError("%s is offline; call login()" % self.full_name)
        _new_boot()
        # A boot allocates ~55 MB (the files' bytecode, data tables) and keeps ~30: the collector running while the
        # heap grows was a quarter of the boot. One full collection after the login events (~17 ms) instead; only
        # restarting would leave the garbage in place (an idle client allocates too little to finish a cycle), and 60
        # clients a process each holding 25 MB more slowed the whole machine.
        self._lua_gc("stop")
        self._took_template = False
        try:
            return self._load_addon(reload)
        finally:
            gc = self._lua_gc              # (the pre-loaded runtime's when the client took one over)
            gc("restart")
            # A pre-loaded runtime was collected after its files ran (build_templates), and the login events only
            # queue events: nothing to collect. In a forked process a full collection would also copy every page of
            # the heap (the marks), ~50 ms a client.
            if not self._took_template:
                gc("collect")

    def _load_addon(self, reload):
        headers, files = self.toc()
        sv_first = self.sv_before_files
        if sv_first is None:
            sv_first = (headers.get("loadsavedvariablesfirst") or "").lower() in ("1", "true")
        if self._take_template(reload, headers):
            missing = list(self._tpl_missing)
        else:
            missing = self._run_files(headers, files, sv_first)
        if missing:
            self.load_warnings.append("skipped %d missing file(s): %s" % (len(missing), ", ".join(missing)))
            key = tuple(missing)
            if key not in self.world._warned_missing:
                self.world._warned_missing.add(key)
                print("wowmock: %s.toc lists %d missing file(s), skipped: %s" % (self.addon_name, len(missing), ", ".join(missing)),
                      file=sys.stderr)
        # WoW order: SavedVariables are assigned after the files ran and right before ADDON_LOADED
        if not sv_first:
            self._apply_saved(headers)
        self._hook_popups()
        if not self.world.prebuild_pages:        # (World(prebuild_pages=True): as in the game)
            self.eval("local MF = ns and rawget(ns, 'MainFrame') if type(MF) == 'table' then MF.prebuild = false end")
        self.M.addon_loaded(self.addon_name)
        for name in self._active_packs():
            if self.pack_order == "real":
                missing = self._run_pack(name)
                if missing:
                    self.load_warnings.append("%s: skipped %d missing file(s): %s" % (name, len(missing),
                                                                                     ", ".join(missing)))
            self.M.addon_loaded(name)
        self.M.login_events(not reload, bool(reload), self.world.roster_delay or 0)
        self.loaded = True
        if self.world.fail_fast:
            self.world.assert_no_errors()
        return self

    def _active_packs(self):
        """The game packs that load (packs_for minus packs_off), in the client's order."""
        if self.addon_name != ADDON_NAME:
            return []
        return [n for n in self.packs if n not in self.packs_off]

    def _run_pack(self, name):
        """Runs a game pack's files with a namespace of its own (its Load.lua makes it a window onto DisasterZone).
        Returns the files that were not there."""
        folder = self.packs[name]
        _, files = parse_toc(folder, name)
        ns = self.runtime.table()
        missing = []
        for rel in files:
            self._load_one(rel, missing, addon=name, folder=folder, ns=ns)
        return missing

    def _run_files(self, headers, files, sv_first, before_files=None):
        """The first half of a boot: TOC metadata, saved variables when they come first, every listed file.
        Returns the files that were not there."""
        self._set_time()
        self.M.set_toc_meta(self.addon_name, to_lua(self.runtime, headers))
        self._load_rooms = LOAD_ROOMS                # (LOAD_ROOMS as it was when this client logged in)
        if self.addon_name == ADDON_NAME:
            for name, folder in self.lod_addons.items():        # (installed: GetAddOnInfo knows it, not loaded)
                if _exists(os.path.join(folder, name + ".toc")):
                    self.M.set_toc_meta(name, to_lua(self.runtime, parse_toc(folder, name)[0]))
            for name, folder in self.packs.items():             # (installed; they load after ADDON_LOADED)
                self.M.set_toc_meta(name, to_lua(self.runtime, parse_toc(folder, name)[0]))
            if self.packs_off:
                self.M.disabled_addons = to_lua(self.runtime, {n: True for n in self.packs_off})
        if PATCH_SV_FILE and self.addon_name == ADDON_NAME and "DisasterZonePatchDB" not in self.world.saved.get(self.full_name, {}):
            with open(PATCH_SV_FILE, encoding="utf-8") as fh:
                self.world.saved.setdefault(self.full_name, {})["DisasterZonePatchDB"] = fh.read()
        for name, src in self.other_saved.items():
            self.M.apply_saved(name, src)
        if sv_first:
            self._apply_saved(headers)
        if before_files:
            before_files()
        missing = []
        for rel in files:
            if rel.lower().endswith(".xml"):
                if not _exists(os.path.join(self.addon_dir, rel)):
                    missing.append(rel)
                    continue
                for lua in _xml_scripts(self.addon_dir, rel):
                    self._load_one(lua, missing)
            else:
                self._load_one(rel, missing)
        if self.pack_order == "early":           # (see PACK_ORDER: pre-loaded clients hold the packs too)
            for name in self._active_packs():
                missing.extend(name + "/" + rel for rel in self._run_pack(name))
        return missing

    # -- pre-loaded clients ----------------------------------------------------------------------------------------
    def _template_mismatch(self, t, headers):
        """Why this client cannot take over pre-loaded client t, or None. The files ran in t with nothing saved, at
        t's boot time, as a default client of a default world: the client must be one that would have run them the
        same way (tools/README: pre-loaded clients)."""
        w, tw = self.world, t.world
        if not self._pristine:
            return "touched before load_addon"
        if os.path.normcase(os.path.abspath(self.addon_dir)) != os.path.normcase(os.path.abspath(t.addon_dir)) \
                or self.addon_name != t.addon_name:
            return "another addon folder"
        if self.lod_addons != t.lod_addons:
            return "other load-on-demand addons"
        if self.packs != t.packs or self.packs_off != t.packs_off or self.pack_order != t.pack_order:
            return "other game packs"
        if (self.preload_lua or self.legacy_globals or self.permissive_fields or self.items_uncached
                or not self.bank_requires_open or self.other_addons or self.other_saved or w.other_addons
                or self.sv_before_files is not None):
            return "client options"
        if (w.addon_throttle, w.onupdate_hidden) != (tw.addon_throttle, tw.onupdate_hidden):
            return "world options"
        if w.on_saved_applied:
            return "the world stores data with the saved variables"
        if self.time_offset + w.now != t.time_offset + tw.now or w.server_time != tw.server_time:
            return "boots at another time"
        saved = w.saved.get(self.full_name, {})
        if any(n in saved for n in self._sv_names(headers)):
            return "saved variables"
        if _loading_hooks() != t._tpl_hooks:
            return "the suite changed how the harness loads files"
        if self.toc() != t._tpl_toc or self._toc_stamps(t._tpl_toc[1]) != t._tpl_stamps:
            return "the addon's files changed since they were pre-loaded"
        if t._tpl_items & set(w.custom_items):
            return "redefines an item the files read"
        for dev in t._tpl_name_checks:
            if (self.name == dev) != (t.name == dev):
                return "the files compare the name with " + dev
        return None

    def _preload(self):
        """build_templates: runs the addon's files in this (fresh, default) client, noting what they read, and stops
        there (load_addon's second half runs in the client that takes it over)."""
        _new_boot()
        gc = self._lua_gc
        gc("stop")
        headers, files = self.toc()
        sv_first = (headers.get("loadsavedvariablesfirst") or "").lower() in ("1", "true")
        try:
            missing = self._run_files(headers, files, sv_first,
                                      before_files=lambda: self.eval(_TPL_RECORDER, self._sv_names(headers)))
            reads = self.eval_py("return __DZ_TPL_DONE()") or []
        finally:
            gc("restart")
            gc("collect")
        self._tpl_missing, self._tpl_items, self._tpl_name_checks, self._tpl_bad = missing, set(), set(), None
        self._tpl_toc = (headers, files)
        self._tpl_stamps = self._toc_stamps(files)
        self._tpl_hooks = _loading_hooks()
        lines = {}
        for key, where in reads:
            if key == "now" or key.startswith(("sv.", "sv=")):
                continue                     # (checked per client: same boot time, nothing saved)
            if key.startswith("item."):
                v = key[5:]
                self._tpl_items.add(int(v) if v.isdigit() else v)
                continue
            rel, _, line = where.rpartition(":")
            if key.startswith("W.") and rel and line.isdigit():
                if rel not in lines:
                    try:
                        lines[rel] = _text(os.path.join(self.addon_dir, rel), encoding="utf-8",
                                           errors="replace").splitlines()
                    except OSError:
                        lines[rel] = []
                n = int(line)
                text = lines[rel][n - 1].strip() if 0 < n <= len(lines[rel]) else ""
                dev = TEMPLATE_NAME_CHECKS.get((rel, text))
                if dev is not None:
                    self._tpl_name_checks.add(dev)
                    continue
            self._tpl_bad = self._tpl_bad or "the files read the player's %s at %s" % (key[2:], where)
        self._pristine = False

    def _toc_stamps(self, files):
        """(time, size) of every file a boot runs (XML includes and their scripts), as this process sees them."""
        out = []
        for rel in files:
            if rel.lower().endswith(".xml"):
                out.append(_stamp(os.path.join(self.addon_dir, rel)))
                rels = _xml_scripts(self.addon_dir, rel)
            else:
                rels = [rel]
            out.extend(_stamp(os.path.join(self.addon_dir, r)) for r in rels)
        if self.pack_order == "early":               # (the packs' files are pre-loaded too)
            for name in self._active_packs():
                folder = self.packs[name]
                out.extend(_stamp(os.path.join(folder, r)) for r in parse_toc(folder, name)[1])
        return out

    def _take_template(self, reload, headers):
        """Takes over the pre-loaded client for this index (build_templates) when nothing would differ: its runtime
        has the addon's files run already. True when it did."""
        if reload or not _TEMPLATES:
            return False
        t = _TEMPLATES.get(self.index)
        why = "no pre-loaded client for index %d" % self.index if t is None else (t._tpl_bad or
                                                                               self._template_mismatch(t, headers))
        if why:
            _template_note(why)
            return False
        del _TEMPLATES[self.index]
        t._owner[0] = self
        self.runtime, self._M, self._owner, self._lua_gc = t.runtime, t._M, t._owner, t._lua_gc
        self._cover_table = t._cover_table
        self._tpl_missing = t._tpl_missing
        self.load_warnings.extend(t.load_warnings)
        t.runtime = t._M = None
        self._lua_gc("stop")
        self._M["talents"] = to_lua(self.runtime, self.talents)      # (the one identity field the mock keeps itself)
        for iid in self.world.custom_items:
            self._define_item(iid)
        self._push_state()
        self._set_time()
        self._load_rooms = LOAD_ROOMS
        self._took_template = True
        _template_note("taken")
        return True

    def _hook_popups(self):
        """The addon's own dialogs (UI/Popup.lua, 1.3.5) are logged in __MOCK.popup_log like StaticPopups, so tests
        read what was asked either way."""
        self.eval("""
            local P = ns and ns.Popup
            if not P or P.__logged then return end
            P.__logged = true
            local show = P.Show
            P.Show = function(self, which, t1, t2, data)
              local f = show(self, which, t1, t2, data)
              if f then
                __MOCK.popup_log = __MOCK.popup_log or {}
                __MOCK.popup_log[#__MOCK.popup_log + 1] = { which = which, text = f.text:GetText(), data = data }
              end
              return f
            end""")

    def _apply_saved(self, headers):
        for sv in self._sv_names(headers):
            src = self.world.saved.get(self.full_name, {}).get(sv)
            if src is not None:
                self.M.apply_saved(sv, src)
        for fn in self.world.on_saved_applied:
            fn(self)

    def set_saved_variable(self, name, lua_source):
        """Pre-seed a SavedVariable (Lua table constructor source, e.g. '{ settings = { debug = true } }') that
        the next load_addon()/login() will assign."""
        self.world.saved.setdefault(self.full_name, {})[name] = lua_source

    def _load_one(self, rel, missing, addon=None, folder=None, ns=None):
        addon, folder = addon or self.addon_name, folder or self.addon_dir
        chunkname = "@Interface/AddOns/%s/%s" % (addon, rel.replace("\\", "/"))
        if addon == ADDON_NAME and rel.replace("\\", "/") == "Core/DevPlan.lua":
            # (the developer's own plan is git-ignored and changes as they plan: tests get the shipped stub, empty)
            self._set_time()
            self.M.load_file("", chunkname, addon, ns)
            return
        src = _chunk(os.path.join(folder, rel), chunkname)  # re-checked per boot: agents edit while tests run
        if src is None:
            missing.append(rel)
            return
        if self._cover_table is not None:
            tag = rel.replace("\\", "/") if addon == self.addon_name else addon + "/" + rel.replace("\\", "/")
            self._cover_table(hashlib.sha1(tag.encode("utf-8")).hexdigest()[:10])
        self._set_time()
        self.M.load_file(src, chunkname, addon, ns)

    def _py_load_lod(self, name):
        """The mock's LoadAddOn for an addon not loaded yet: (true) after its files ran with a namespace of their own
        and ADDON_LOADED fired, or (false, reason). DisasterZone_Rooms leaves out the board's rooms unless LOAD_ROOMS."""
        folder = self.lod_addons.get(name)
        if not folder or not _exists(os.path.join(folder, name + ".toc")):
            return False, "MISSING"
        _new_boot()
        headers, files = parse_toc(folder, name)
        if name == ROOMS_NAME and not (LOAD_ROOMS if self._load_rooms is None else self._load_rooms):
            files = [f for f in files if not is_board_room(f)]
        ns = self.runtime.table()
        missing = []
        for rel in files:
            self._load_one(rel, missing, addon=name, folder=folder, ns=ns)
        if missing:
            self.load_warnings.append("%s: skipped %d missing file(s): %s" % (name, len(missing), ", ".join(missing)))
        self.M.addon_loaded(name)
        return True, None

    def load_files(self, files, fire_login=False, addon_name=ADDON_NAME):
        """Load specific files (relative to the addon folder, or absolute) with (addon_name, ns). With
        fire_login=True also fire ADDON_LOADED + login events afterwards."""
        _new_boot()
        missing = []
        if PATCH_SV_FILE and addon_name == ADDON_NAME and not self.eval("return DisasterZonePatchDB ~= nil"):
            # patched run: the stored update must be there before the first file, as load_addon() arranges
            with open(PATCH_SV_FILE, encoding="utf-8") as fh:
                self.M.apply_saved("DisasterZonePatchDB", fh.read())
        for f in files:
            if os.path.isabs(f):
                chunkname = "@" + f.replace("\\", "/")
                src = _chunk(f, chunkname, strip_bom=False)
                if src is None:
                    missing.append(f)
                    continue
                self._set_time()
                self.M.load_file(src, chunkname, addon_name)
            else:
                rel = f.replace("\\", "/")
                pack, _, inner = rel.partition("/")
                if pack in self.packs and inner:
                    # a game pack's file ("DisasterZone_Chess/Chess.lua"): from its folder, with its name (one
                    # namespace per pack, shared by the files of one load_files call)
                    nss = self.__dict__.setdefault("_pack_ns", {})
                    if pack not in nss:     # (what the pack's Load.lua makes of it: a window onto DisasterZone)
                        nss[pack] = self.runtime.eval(
                            "setmetatable({}, { __index = function(_, k) return DisasterZone and DisasterZone[k] end,"
                            " __newindex = function(_, k, v) DisasterZone[k] = v end })")
                    self._load_one(inner, missing, addon=pack, folder=self.packs[pack], ns=nss[pack])
                else:
                    self._load_one(rel, missing)
        if missing:
            raise FileNotFoundError("load_files: missing %s" % ", ".join(missing))
        if fire_login:
            self.M.addon_loaded(addon_name)
            self.M.login_events(True, False, self.world.roster_delay or 0)
        return self

    def login_events(self, reload=False):
        self._set_time()
        self.M.login_events(not reload, bool(reload), self.world.roster_delay or 0)

    def _sv_names(self, headers=None):
        if headers is None:
            headers, _ = self.toc()
        names = []
        for key in ("savedvariables", "savedvariablespercharacter"):
            for n in (headers.get(key) or "").split(","):
                n = n.strip()
                if n:
                    names.append(n)
        return names

    def saved_variables(self):
        """Current serialization (Lua source) of every SavedVariable, without logging out."""
        out = {}
        for sv in self._sv_names():
            s = self._call("serialize_global", sv)
            if s is not None:
                out[sv] = s
        return out

    def _shutdown(self, save=True):
        if self.runtime is None:
            return
        self._set_time()
        self.M.logout_events()
        if save:
            store = self.world.saved.setdefault(self.full_name, {})
            for sv in self._sv_names():
                s = self.M.serialize_global(sv)
                if s is None or s == "nil":
                    store.pop(sv, None)
                else:
                    store[sv] = s
            for name in list(self.other_saved):
                s = self.M.serialize_global(name)
                if s is not None and s != "nil":
                    self.other_saved[name] = s
        self._old_errors.extend(self._current_errors())
        self._old_warnings.extend(self._current_warnings())
        self._old_printed.extend(self._lua_list("printed"))
        self._old_chat.extend(self._lua_list("chat_lines"))
        self.world._archived_reports.append(self._report_tables())
        self.runtime = None
        self.M = None
        self.loaded = False

    def relog(self, reload=True):
        """/reload (default) or logout+login (reload=False): fires PLAYER_LEAVING_WORLD/PLAYER_LOGOUT, saves
        SavedVariables as Lua source, builds a FRESH runtime with the same identity and loads the addon again."""
        if reload:
            self._shutdown(save=True)
            self._new_runtime()
            self.world._sync()
            self.load_addon(reload=True)
        else:
            self.logout()
            self.login()
        return self

    def logout(self):
        self._shutdown(save=True)
        self.online = False
        self._notify_guild("%s has gone offline." % self.name)
        self.world._sync(roster_changed=True, guild=self.guild)
        self.world._notify_friends(self, "%s has gone offline." % self.name)

    def login(self, load=True):
        self.online = True
        self._new_runtime()
        self.world._sync(roster_changed=True, guild=self.guild)
        self._notify_guild("|Hplayer:%s|h[%s]|h has come online." % (self.name, self.name))
        self.world._notify_friends(self, "|Hplayer:%s|h[%s]|h has come online." % (self.name, self.name))
        if load:
            self.load_addon(reload=False)
        return self

    def _notify_guild(self, text):
        if not self.guild:
            return
        for c in self.world.clients:
            if c is not self and c.guild == self.guild and c.runtime is not None:
                self.world._enqueue(0.0, c, "system", text)

    # -- events / eval ---------------------------------------------------------------------------------------------
    def fire(self, event, *args):
        """Dispatch an event to every frame that registered it: OnEvent(frame, event, ...)."""
        self._fire(event, *args)

    def eval(self, code, *args):
        """Run Lua code in this client (`return` is optional for expressions). `ns` is the addon namespace.
        Returns None / a value / a tuple; tables come back as lupa LuaTables (use to_py / eval_py)."""
        self._set_time()
        res = self._eval_fn()(code, *[self._to_lua(a) for a in args])
        if not isinstance(res, tuple):
            res = (res,)
        if not res[0]:
            raise LuaEvalError("%s: %s" % (self.full_name, res[1]))
        vals = tuple(self._fix_bytes(v) for v in res[1:])
        if not vals:
            return None
        return vals[0] if len(vals) == 1 else vals

    def eval_py(self, code, *args):
        v = self.eval(code, *args)
        if isinstance(v, tuple):
            return tuple(self.to_py(x) for x in v)
        return self.to_py(v)

    def to_py(self, v):
        if lua_type(v) == "table":
            return _conv(self.M.export(v))
        return v

    def _fix_bytes(self, v):
        if lua_type(v) == "table":
            try:
                keys = list(v.keys())
            except Exception:
                return v
            if keys == ["__bytes"]:
                return bytes.fromhex(v["__bytes"])
        return v

    def _eval_fn(self):
        f = getattr(self, "_evalf", None)
        if f is None or getattr(self, "_evalf_rt", None) is not self.runtime:
            f = self.runtime.execute("""
                local M = __MOCK
                return function(code, ...)
                  local f, err = loadstring("return " .. code, "@eval")
                  if not f then f, err = loadstring(code, "@eval") end
                  if not f then return false, M.safe_str(err) end
                  setfenv(f, setmetatable({ ns = M.ns, addonName = "DisasterZone" }, { __index = _G, __newindex = _G }))
                  local n = select("#", ...)
                  local args = { ... }
                  local res = { xpcall(function() return f(unpack(args, 1, n)) end,
                                      function(e) return debug.traceback(tostring(e), 2) end) }
                  if not res[1] then return false, M.safe_str(res[2]) end
                  local m = table.maxn(res)
                  for i = 2, m do
                    local v = res[i]
                    if type(v) == "string" and not M.is_utf8(v) then res[i] = { __bytes = M.hex(v) } end
                  end
                  return unpack(res, 1, m)
                end""")
            self._evalf, self._evalf_rt = f, self.runtime
        return f

    # -- diagnostics -----------------------------------------------------------------------------------------------
    def _lua_list(self, key):
        if self.M is None:
            return []
        v = self.M[key]
        if v is None:
            return []
        return _conv(self.M.export(v)) or []

    def _current_errors(self):
        if self.M is None:
            return []
        return list(self.M.get_errors().values())

    def _current_warnings(self):
        return [str(x) for x in self._lua_list("warnings")]

    def _report_tables(self):
        return _conv(self.M.export(self.M.report_tables()))

    @property
    def errors(self):
        return self._old_errors + self._current_errors()

    @property
    def warnings(self):
        return self._old_warnings + self._current_warnings() + ["[load] " + w for w in self.load_warnings]

    def clear_errors(self):
        self._old_errors = []
        if self.M is not None:
            self.M.errors = self.runtime.table()

    @property
    def printed(self):
        """Everything passed to print() (all runtimes of this client)."""
        return self._old_printed + self._lua_list("printed")

    @property
    def chat_frame(self):
        """Every line added to DEFAULT_CHAT_FRAME (print, AddMessage, system messages)."""
        return self._old_chat + self._lua_list("chat_lines")

    @property
    def ui_errors(self):
        return self._lua_list("ui_errors")

    @property
    def raid_notices(self):
        return self._lua_list("raid_notices")

    @property
    def sounds(self):
        return self._lua_list("sounds")

    @property
    def inserted_links(self):
        return self._lua_list("inserted_links")

    @property
    def chat_shown(self):
        """CHAT_MSG_* lines as the chat frames show them (after the message event filters): {event, text, author}."""
        return self._lua_list("chat_shown")

    @property
    def opened_chat(self):
        """The text the chat box was last opened with (ChatFrameUtil.OpenChat), or None."""
        return self.M["opened_chat"] if self.M is not None else None

    def click_link(self, link, text="", button="LeftButton"):
        """Click a hyperlink in the chat frame (link = the |H data, e.g. "addon:DisasterZone:raids")."""
        self._call("click_hyperlink", link, text, button)

    def hover_link(self, link, text=""):
        self._call("hover_hyperlink", link, text)

    def leave_link(self):
        self._call("leave_hyperlink")

    @property
    def sent_addon(self):
        return [e for e in self.world.addon_log if e["sender"] == self.full_name]

    @property
    def received_addon(self):
        return [e for e in self.world.addon_log if self.full_name in e.get("delivered", [])]

    # -- game helpers ----------------------------------------------------------------------------------------------
    def equip(self, slots):
        """{invSlot: itemID or None}; fires PLAYER_EQUIPMENT_CHANGED(slot, isEmpty) + UNIT_INVENTORY_CHANGED."""
        self._call("equip", to_lua(self.runtime, {int(k): (int(v) if v else 0) for k, v in slots.items()}))

    def _bag_table(self, content):
        rows = []
        for (bag, slot), v in sorted(content.items()):
            iid, cnt = (v if isinstance(v, (tuple, list)) else (v, 1))
            rows.append([int(bag), int(slot), int(iid or 0), int(cnt)])
        return to_lua(self.runtime, rows)

    def set_bags(self, content):
        """{(bag, slot): itemID or (itemID, count)} for bags 0..4 (replaces their contents); fires BAG_UPDATE(bag)
        per touched bag + BAG_UPDATE_DELAYED."""
        self._call("set_bags", self._bag_table(content), False)

    def set_bank(self, content):
        """{(bag, slot): itemID} for BANK_CONTAINER (-1) and bank bags 5..11; opens the bank (BANKFRAME_OPENED)
        and fires PLAYERBANKSLOTS_CHANGED(slot) / BAG_UPDATE(bag) + BAG_UPDATE_DELAYED."""
        self._call("set_bags", self._bag_table(content), True)

    def open_bank(self):
        self._call("open_bank")

    def close_bank(self):
        self._call("close_bank")

    def give_item(self, item_id, count=1):
        return self._call("give_item", int(item_id), int(count))

    def open_trade(self, partner):
        """Open the trade window with a group member (a Client / ExtraMember or a name). Fires TRADE_SHOW."""
        self._call("open_trade", partner if isinstance(partner, str) else partner.name)

    def complete_trade(self):
        """Both sides accept: my trade items leave my bags (TRADE_ACCEPT_UPDATE, TRADE_CLOSED, 'Trade complete.').
        Returns the item ids given."""
        return list((self._call("complete_trade") or {}).values())

    def cancel_trade(self):
        self._call("cancel_trade")

    def receive_item_message(self, item_id):
        """'You receive item: [..]' on this client (an item received in a trade)."""
        return self._call("loot_message", self.name, self.full_name, self.guid, int(item_id), 1, True, True)

    def open_loot(self, items, source_guid="Creature-0-1-2-3-15690-000ABC"):
        """items: [(itemID, quality)] or [(itemID, quality, count)] or [itemID]. quality None = from item DB.
        Fires LOOT_READY(false) then LOOT_OPENED(false, false)."""
        rows = []
        for it in items:
            if isinstance(it, int):
                it = (it, None)
            iid, q = it[0], it[1] if len(it) > 1 else None
            cnt = it[2] if len(it) > 2 else 1
            row = {1: int(iid), 3: int(cnt)}
            if q is not None:
                row[2] = int(q)
            rows.append(row)
        self._call("open_loot", to_lua(self.runtime, rows), source_guid)

    def close_loot(self):
        self._call("close_loot")

    def start_loot_roll(self, item_id, quality=None, roll_id=None, roll_time=60000, count=1):
        roll_id = roll_id if roll_id is not None else (100 + next(self.world._seq))
        self._call("start_roll", int(roll_id), int(item_id), quality, int(count), int(roll_time))
        return roll_id

    def cancel_loot_roll(self, roll_id):
        self._call("cancel_roll", int(roll_id))

    def show_tooltip_item(self, item_id):
        """GameTooltip:SetOwner + SetItemByID (fires OnTooltipSetItem hooks); returns [(left, right)] lines."""
        lines = _conv(self.M.export(self._call("show_tooltip_item", int(item_id))))
        return [(l[0] if len(l) > 0 else "", l[1] if len(l) > 1 else None) for l in (lines or [])]

    def _addon_popup_act(self, name, index, text):
        """Button `index` of the addon's own dialog `name` (UI/Popup.lua); False when none is shown."""
        return self.eval("""
            local which, i, text = ...
            local P = ns and ns.Popup
            local f = P and P:FindVisible(which)
            if not f then return false end
            if text ~= nil then f.editBox:SetText(text) end
            P:Click(f, i)
            return true""", name, index, text) is True

    def accept_popup(self, name, text=None):
        """Click button1 (OnAccept) of the visible dialog `name` (the addon's own, or a StaticPopup); text fills its
        edit box first."""
        if not self._addon_popup_act(name, 1, text) and not self._call("popup_act", name, 1, text):
            raise AssertionError("%s: no visible popup %r (visible: %s)" % (self.full_name, name, self.popups()))

    def cancel_popup(self, name):
        if not self._addon_popup_act(name, 2, None) and not self._call("popup_act", name, 2, None):
            raise AssertionError("%s: no visible popup %r" % (self.full_name, name))

    def popup_button(self, name, index):
        """Click button `index` (1..3) of the visible dialog `name`."""
        if not self._addon_popup_act(name, index, None) and not self._call("popup_act", name, index, None):
            raise AssertionError("%s: no visible popup %r (visible: %s)" % (self.full_name, name, self.popups()))

    def popup_text(self, name):
        """The text of the visible dialog `name` (the addon's own or a StaticPopup), or None."""
        return self.eval("""
            local which = ...
            local f = ns and ns.Popup and ns.Popup:FindVisible(which)
            if not f and StaticPopup_FindVisible then f = StaticPopup_FindVisible(which) end
            return f and f.text:GetText() or nil""", name)

    def escape_popups(self):
        """Press Escape in the game world: the addon's top dialog closes (it takes the key), else
        StaticPopup_EscapePressed (what ToggleGameMenu runs first). Every shown hideOnEscape popup gets
        OnCancel(dialog, data, "clicked") unless noCancelOnEscape. True if one closed."""
        if self.eval("return ns and ns.Popup and ns.Popup:EscapePressed() or false") is True:
            return True
        return bool(self._call("popup_escape"))

    def set_ml_refusal(self, member, kind="inv_full"):
        """Make the server refuse this client's GiveMasterLoot to `member` (client, ExtraMember or 'Name[-Realm]'):
        kind "inv_full" | "unique" | "other" | "not_found" -> UI_ERROR_MESSAGE, item stays; None = accept again."""
        m = self.world._member(member)
        full = m.full_name if m is not None else str(member)
        self._call("set_ml_refusal", full, kind)

    def popups(self):
        """The names of the visible dialogs: the addon's own (UI/Popup.lua), then StaticPopups."""
        return self.eval_py("""
            local out = {}
            for i = 1, 4 do
              local f = _G["DisasterZonePopup" .. i]
              if f and f:IsShown() then out[#out + 1] = f.which end
            end
            for i = 1, STATICPOPUP_NUMDIALOGS do
              local f = __MOCK.popup_frames[i]
              if f and f:IsShown() then out[#out + 1] = f.which end
            end
            return out""") or []

    def last_menu(self):
        """The last menu opened via MenuUtil.CreateContextMenu / dropdown:OpenMenu(), as nested dicts
        {kind, text, enabled, selected?, children}."""
        return _conv(self.M.export(self._call("menu_export"))) if self.M.last_menu is not None else None

    def menu_select(self, text):
        """Invoke the entry with this text in the last menu (button callback / checkbox+radio setSelected)."""
        return self._call("menu_select", text)

    def dropdown_menu(self, dropdown):
        """Generate + open a WowStyle1DropdownTemplate dropdown (frame or global name); returns last_menu()."""
        f = self._frame_arg(dropdown)
        self.eval("local d = ...; d:OpenMenu()", f)
        return self.last_menu()

    def _frame_arg(self, f):
        if isinstance(f, str):
            g = self.runtime.globals()[f]
            if g is None:
                raise KeyError("no global frame %r" % f)
            return g
        return f

    def frame(self, name):
        return self.runtime.globals()[name]

    def click(self, frame, button="LeftButton"):
        self._call("click", self._frame_arg(frame), button)

    def hover(self, frame):
        self._call("hover", self._frame_arg(frame))

    def leave(self, frame):
        self._call("leave", self._frame_arg(frame))

    def type_text(self, editbox, text, enter=False):
        self._call("type_text", self._frame_arg(editbox), text, bool(enter))

    def press_enter(self, editbox):
        self._call("press_enter", self._frame_arg(editbox))

    def press_escape(self, editbox):
        self._call("press_escape", self._frame_arg(editbox))

    def slash(self, line):
        """Run a slash command, e.g. client.slash('/dz sync'). Returns False if no handler matched."""
        return bool(self._call("slash", line))

    def dump_ui(self, frame=None, depth=6, textures=False):
        """Text tree of a frame (default UIParent): kind, name/template, [hidden], text/label, checked, value."""
        return self._call("dump", self._frame_arg(frame) if frame is not None else None, depth, textures)

    def find_text(self, pattern, visible_only=True, plain=True):
        """Regions/widgets whose text contains `pattern` (plain substring by default)."""
        return list(self._call("find_text", pattern, visible_only, plain).values())

    def set_modifiers(self, shift=False, ctrl=False, alt=False):
        self._call("set_modifiers", shift, ctrl, alt)

    def set_combat(self, in_combat):
        self._call("set_combat", bool(in_combat))

    def set_target(self, name):
        self._call("set_target", name)

    def show_nameplate(self, guid):
        """The NPC's nameplate appears on this client (NAME_PLATE_UNIT_ADDED). Returns the unit token."""
        return self._call("add_nameplate", guid)

    def hide_nameplate(self, guid):
        self._call("remove_nameplate", guid)

    def target_npc(self, guid):
        self._call("set_npc_target", guid)

    def mouseover_npc(self, guid):
        self._call("set_mouseover_npc", guid)

    def set_cursor_item(self, item_id):
        self._call("set_cursor_item", item_id)

    def set_talents(self, points):
        self.talents = list(points)
        self.eval("local a, b, c = ...; __MOCK.talents = {a, b, c}", *self.talents)
        self._fire("CHARACTER_POINTS_CHANGED", 0)

    def combat_log(self, *args):
        self._call("combat_log", *args)

    def define_item(self, item_id, name, quality=4, equip_loc="INVTYPE_NON_EQUIP_IGNORE", class_id=15, subclass_id=0,
                    ilvl=0, icon=None):
        self._call("define_item", int(item_id), name, quality, equip_loc, class_id, subclass_id, icon, ilvl)


# ------------------------------------------------------------------------------------------------------------------
# smoke run
# ------------------------------------------------------------------------------------------------------------------
def _smoke():
    w = World()
    a = Client(w, "Alice", class_file="PALADIN", guild_rank=0)
    b = Client(w, "Bob", class_file="MAGE", guild_rank=1)
    c = Client(w, "Carol", class_file="WARRIOR", guild_rank=3)
    w.add_offline_member("Dave", "ROGUE", 3)
    for x in w.clients:
        x.load_addon()
    w.make_raid([a, b, c], master_looter=a)
    w.tick(3)
    print(w.report())
    print("-- addon messages sent: %d" % len(w.addon_log))
    return 1 if w.errors() else 0


if __name__ == "__main__":
    sys.exit(_smoke())
