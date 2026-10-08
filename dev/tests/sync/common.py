"""Shared helpers for the DisasterZone sync / ledger scenario tests (tests/sync/test_*.py).

Nothing here modifies the addon or the harness: everything the harness lacks is shimmed from the test side.
"""
import os
import sys
import time
import traceback
from collections import Counter, defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
SCRATCH = os.path.abspath(os.path.join(HERE, "..", ".."))
TOOLS = os.path.join(SCRATCH, "tools")
if TOOLS not in sys.path:
    sys.path.insert(0, TOOLS)
TESTS = os.path.join(SCRATCH, "tests")
if TESTS not in sys.path:
    sys.path.insert(0, TESTS)

from harness import World, Client, ExtraMember, LuaErrorsFound, LuaEvalError, ADDON_DIR, in_shard  # noqa: E402,F401
from cdl_council import seed_guild_council, gm_pick, raid_pick, council_of  # noqa: E402,F401

REALM = "Thunderstrike"
GUILD = "Casual Disaster"
# Addendum E: the loot council is the Guild Master plus the guild council list the GM picked (no Guild Info tag).
# Scenario worlds start with that list stored on every client of the guild: the officers of these scenarios
# (what the old default tag "CDL{r1 p1}" made council by rank). Names not in a world's roster are ignored.
COUNCIL = ("Councila", "Councilb", "Councilc", "Councild", "Officerx", "Mainofficer")


def key(name, realm=REALM):
    return "%s-%s" % (name, realm)


# ----------------------------------------------------------------------------------------------------------------
# Tiny runner
# ----------------------------------------------------------------------------------------------------------------
class Runner:
    def __init__(self, title):
        self.title = title
        self.cases = []
        self.notes = []

    def case(self, fn):
        self.cases.append(fn)
        return fn

    def note(self, text):
        self.notes.append(text)
        print("   NOTE: " + text)

    def run(self):
        try:
            sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        except Exception:  # noqa: BLE001
            pass
        flt = None
        if "-k" in sys.argv:
            flt = sys.argv[sys.argv.index("-k") + 1]
        passed, failed = [], []
        print("== %s ==" % self.title)
        picked = [fn for fn in self.cases if not flt or flt in fn.__name__]
        for fn in [fn for i, fn in enumerate(picked) if in_shard(i)]:
            t0 = time.time()
            try:
                fn()
            except Exception as e:  # noqa: BLE001 - report every failure and keep going
                failed.append(fn.__name__)
                print("FAIL %s (%.1fs)" % (fn.__name__, time.time() - t0))
                tb = traceback.format_exc()
                # keep the output readable: cap very long Lua traceback dumps
                if len(tb) > 6000:
                    tb = tb[:6000] + "\n... (truncated)"
                print("     " + tb.replace("\n", "\n     "))
            else:
                passed.append(fn.__name__)
                print("PASS %s (%.1fs)" % (fn.__name__, time.time() - t0))
        print("-- %s: %d passed, %d failed%s" % (self.title, len(passed), len(failed),
                                                 (" (" + ", ".join(failed) + ")") if failed else ""))
        sys.exit(1 if failed else 0)


# ----------------------------------------------------------------------------------------------------------------
# World helpers
# ----------------------------------------------------------------------------------------------------------------
def new_world(council=COUNCIL, phase=1, **kw):
    """A world whose guild council list (Addendum E) is `council`, stored on every client of the guild as if the
    GM picked it earlier (cdl_council.seed_guild_council). council=None: no list (only a GM would be council)."""
    w = World(**kw)
    if council is not None:
        seed_guild_council(w, council, phase=phase)
    return w


def up(c):
    """Load the addon on an online client (fresh runtime)."""
    c.load_addon()
    return c


def settle(w, seconds=40):
    w.tick(seconds, 0.1)


def wipe_saved(w, c):
    """Simulate a reinstall / deleted WTF folder: forget every SavedVariable of this character."""
    w.saved.pop(c.full_name, None)


def snapshot_saved(w, c):
    return dict(w.saved.get(c.full_name, {}))


def restore_saved(w, c, snap):
    w.saved[c.full_name] = dict(snap)


def assert_no_lua_errors(w):
    w.assert_no_errors()


# ----------------------------------------------------------------------------------------------------------------
# Addon state helpers (run in the client's Lua)
# ----------------------------------------------------------------------------------------------------------------
PICK_LUA = r"""
local sid, n, class = ...
local c = ns.ItemDB:GetCandidates(sid, { maxPhase = 5, class = class })
local out = {}
for i = 1, #c do
  if ns.ItemDB:FitsSlot(c[i].itemID, sid) then out[#out + 1] = c[i].itemID end
  if #out >= n then break end
end
return out
"""


def candidates(c, sid, n=6):
    return c.eval_py(PICK_LUA, sid, n, c.class_file) or []


def set_slot(c, phase, sid, item, which="main"):
    ok = c.eval("return ns.BiS:SetSlot(...)", phase, sid, which, item)
    assert ok, "%s: SetSlot(%s,%s,%s,%s) refused" % (c.full_name, phase, sid, which, item)


def edit(c, variant=0, phase=1, sid=1, commit=False):
    """Make a real list change (pick candidate #variant for the slot). commit=True commits right away (as the
    main window's OnHide does), otherwise the 8s debounce commits it."""
    items = candidates(c, sid, variant + 1)
    assert len(items) > variant, "%s: not enough candidates for sid %d" % (c.full_name, sid)
    set_slot(c, phase, sid, items[variant])
    if commit:
        c.eval("ns.BiS:Commit()")
    return items[variant]


def own(c):
    return c.eval_py("""
      local r = ns.BiS:GetRecord()
      return { rev = r.rev, hash = r.hash, hsr = r.highestSeenRev, ts = r.ts,
               live = ns.Util.Hash(r.data), dirty = ns.BiS:IsDirty() and true or false }""")


def cached(c, owner_key):
    """(rev, hash, via) of the council cache on c for owner_key, or None."""
    r = c.eval_py("""
      local r = ns.Store:GetCached(...)
      if not r then return nil end
      return { rev = r.rev, hash = r.hash, via = r.via, live = ns.Util.Hash(r.data) }""", owner_key)
    return r


def cached_rev(c, owner_key):
    r = cached(c, owner_key)
    return r["rev"] if r else 0


def ledger_ids(c, include_void=True):
    return sorted(c.eval_py("""
      local out = {}
      for id in pairs(ns.db.ledger) do out[#out + 1] = id end
      return out""") or [])


def ledger_raw(c):
    return c.eval_py("return ns.db.ledger") or {}


def ledger_view(c, include_void=True):
    """The de-duplicated view as a list of (id, vd) newest first."""
    rows = c.eval_py("""
      local out = {}
      for _, e in ipairs(ns.Ledger:GetEntries({ includeVoid = ... })) do
        out[#out + 1] = { e.id, e.vd and true or false }
      end
      return out""", include_void) or []
    return [tuple(r) for r in rows]


def is_council(c, k=None):
    if k is None:
        return bool(c.eval("return ns.Guild:AmICouncil(true)"))
    return bool(c.eval("return ns.Guild:IsCouncil(..., true)", k))


def online_council_peers(c):
    return list(c.eval_py("return ns.Sync:GetOnlineCouncilPeers()") or [])


def status_text(c):
    return c.eval("return ns.Sync:GetStatusText()")


def printed(c):
    """Everything the client printed: print() output and chat frame lines (ns:Print goes to the chat frame)."""
    return [str(p) for p in c.printed] + [str(p) for p in c.chat_frame]


# ----------------------------------------------------------------------------------------------------------------
# Wire decoding (addon_log -> logical DisasterZone messages)
# ----------------------------------------------------------------------------------------------------------------
_decoder = None

DECODE_LUA = r"""
local text = ...
local LD, LS = LibStub("LibDeflate"), LibStub("LibSerialize")
local out = { major = text:sub(1, 1) }
local d = LD:DecodeForWoWAddonChannel(text:sub(2))
if not d then out.err = "decode" return out end
local inf = LD:DecompressDeflate(d)
if type(inf) ~= "string" then out.err = "inflate" return out end
out.inflated = #inf
local ok, v = LS:Deserialize(inf)
if not ok then out.err = "deserialize" return out end
out.msg = v
return out
"""


def _get_decoder():
    global _decoder
    if _decoder is None:
        dw = World()
        dc = Client(dw, "Decoder", guild=None)
        dc.load_files(["Libs/LibStub/LibStub.lua", "Libs/LibDeflate/LibDeflate.lua", "Libs/LibSerialize/LibSerialize.lua"])
        _decoder = dc
    return _decoder


def decode_text(text):
    return _get_decoder().eval_py(DECODE_LUA, text)


# Create the decoder runtime now: the mock seeds math.random (process-global C rand in Lua 5.1) whenever a
# runtime is created, so creating it lazily in the middle of a scenario would change that scenario's random draws.
_get_decoder()


CDL_PREFIXES = ("CDLc", "CDLd", "CDLa")


def logical_messages(w, start=0):
    """Reassemble AceComm multipart messages from w.addon_log[start:] (DisasterZone prefixes only) and decode them.
    Returns a list of dicts: time, sender, prefix, chat_type, target, parts, bytes, t, msg, err, delivered."""
    out = []
    pending = {}
    for e in w.addon_log[start:]:
        if e["prefix"] not in CDL_PREFIXES:
            continue
        text = e["text"]
        k = (e["sender"], e["prefix"], e["chat_type"], e.get("target") or "")
        ctrl = text[:1]
        if ctrl == b"\x01":
            pending[k] = {"time": e["time"], "entries": [e], "buf": text[1:]}
            continue
        if ctrl == b"\x02":
            p = pending.get(k)
            if p:
                p["entries"].append(e)
                p["buf"] += text[1:]
            continue
        if ctrl == b"\x03":
            p = pending.pop(k, None)
            if not p:
                continue
            p["entries"].append(e)
            p["buf"] += text[1:]
            entries, body, t0 = p["entries"], p["buf"], p["time"]
        elif ctrl == b"\x04":
            entries, body, t0 = [e], text[1:], e["time"]
        else:
            entries, body, t0 = [e], text, e["time"]
        rec = {"time": t0, "sender": e["sender"], "prefix": e["prefix"], "chat_type": e["chat_type"],
               "target": e.get("target"), "parts": len(entries), "bytes": sum(len(x["text"]) for x in entries),
               "delivered": entries[-1].get("delivered", []), "t": None, "msg": None, "err": None}
        try:
            d = decode_text(body)
        except Exception as ex:  # noqa: BLE001
            d = {"err": "python: %s" % ex}
        if d.get("err"):
            rec["err"] = d["err"]
        else:
            m = d.get("msg")
            rec["msg"] = m
            rec["t"] = m.get("t") if isinstance(m, dict) else None
        out.append(rec)
    return out


def traffic(w, start=0):
    """Summary of DisasterZone traffic in w.addon_log[start:]: wire messages/bytes and logical message counts."""
    wire = [e for e in w.addon_log[start:] if e["prefix"] in CDL_PREFIXES]
    msgs = logical_messages(w, start)
    by_type = Counter(m["t"] for m in msgs)
    by_type_parts = Counter()
    for m in msgs:
        by_type_parts[m["t"]] += m["parts"]
    return {"wire": len(wire), "bytes": sum(len(e["text"]) for e in wire), "logical": len(msgs),
            "by_type": dict(by_type), "parts_by_type": dict(by_type_parts), "msgs": msgs}


def fmt_traffic(t):
    types = ", ".join("%s=%d(%dp)" % (k, v, t["parts_by_type"].get(k, 0)) for k, v in sorted(t["by_type"].items(),
                                                                                          key=lambda kv: str(kv[0])))
    return "%d wire msgs / %d bytes / %d logical [%s]" % (t["wire"], t["bytes"], t["logical"], types)


def throttled(c):
    """Messages the simulated server throttle rejected for this client (current runtime)."""
    try:
        return int(c.eval("return __MOCK.throttled or 0") or 0)
    except Exception:  # noqa: BLE001
        return 0


def hello_times(w, who_key):
    return [m["time"] for m in logical_messages(w) if m["t"] == "H" and m["sender"] == who_key]


def wait_hello_after(w, who_key, after, limit=60.0):
    end = w.now + limit
    while w.now < end:
        w.tick(0.1)
        hs = [t for t in hello_times(w, who_key) if t > after]
        if hs:
            return hs[0]
    raise AssertionError("no HELLO from %s after %.1f" % (who_key, after))


def quick_double_reload(w, c, window=20.0, attempts=16, pause=6.0):
    """Wait for c's HELLO in the current session, let the council's replies arrive (`pause` s), /reload, and
    repeat until the new session's automatic HELLO lands less than `window` seconds after the previous one (the
    council's per-sender S/M reply rate limit). Returns the gap between the two HELLOs.
    Harness shim: the mock seeds math.random from the character name, so every session of a character draws the
    same HELLO delay; a different seed per attempt (preload_lua) varies it like real sessions do."""
    t1 = wait_hello_after(w, c.full_name, w.now - 0.01)
    old_preload = c.preload_lua
    try:
        for i in range(attempts):
            w.tick(max(0.0, t1 + pause - w.now) + 0.05)
            c.preload_lua = "math.randomseed(%d)" % (1000 + 7919 * i)
            c.relog()
            t2 = wait_hello_after(w, c.full_name, t1)
            if t2 - t1 < window:
                return t2 - t1
            t1 = t2
    finally:
        c.preload_lua = old_preload
    raise AssertionError("could not produce two HELLOs within %.0fs" % window)


def slow_roster_preload(delay):
    """Harness shim (preload_lua): the mock answers C_GuildInfo.GuildRoster() on the next tick, so the addon's own
    roster request at login defeats World.roster_delay. This delays the server answer by `delay` seconds after the
    runtime starts, like a slow server after login."""
    return """
      local readyAt = GetTime() + %f
      local orig = C_GuildInfo.GuildRoster
      C_GuildInfo.GuildRoster = function(...)
        local d = readyAt - GetTime()
        if d > 0 then
          __MOCK.after(d, function() orig() end, "slow guild roster")
          return
        end
        return orig(...)
      end""" % float(delay)


def login_with_slow_roster(w, c, delay):
    old_pre, old_delay = c.preload_lua, w.roster_delay
    c.preload_lua = slow_roster_preload(delay)
    w.roster_delay = delay
    try:
        c.login()
    finally:
        c.preload_lua, w.roster_delay = old_pre, old_delay
