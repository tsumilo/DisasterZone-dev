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
import heapq
import itertools
import json
import os
import re
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
_SITE = os.path.join(os.path.dirname(HERE), "luaenv", "Lib", "site-packages")
if os.path.isdir(_SITE) and _SITE not in sys.path:
    sys.path.insert(0, _SITE)
from lupa import lua51  # noqa: E402

# DISASTERZONE_ADDON_DIR points the whole harness at another copy of the addon (tools/patched_run.py: a base release
# tree whose saved DisasterZonePatchDB, named by DISASTERZONE_PATCH_SV, carries the current source as an in-game update).
ADDON_DIR = os.environ.get("DISASTERZONE_ADDON_DIR") or r"C:\World of Warcraft\_anniversary_\Interface\AddOns\DisasterZone"
PATCH_SV_FILE = os.environ.get("DISASTERZONE_PATCH_SV") or None
ADDON_NAME = "DisasterZone"
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
    return {m: _read(os.path.join(MOCK_DIR, m)) for m in MODULES}


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
    with open(path, encoding="utf-8-sig") as fh:
        for raw in fh:
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
        text = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return out
    for m in re.finditer(r'<(Script|Include)\s+file\s*=\s*"([^"]+)"', text):
        f = os.path.normpath(os.path.join(base, m.group(2).replace("\\", "/"))).replace("\\", "/")
        if m.group(1) == "Include" or f.lower().endswith(".xml"):
            out.extend(_xml_scripts(addon_dir, f))
        else:
            out.append(f)
    return out


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
                 zone="Shattrath City", fail_fast=False, other_addons=(), server_time=1790000000):
        """officer_rank: guild rank index <= this can read OFFICER chat / officer notes.
        roster_delay: seconds after PLAYER_ENTERING_WORLD until the guild roster is available (None/0 = immediate).
        addon_throttle: simulate the per-prefix server rate limit (10 msg burst, 1/s regen) on SendAddonMessage.
        onupdate_hidden: also run OnUpdate for hidden frames (WoW only runs it for visible frames).
        other_addons: addon names that IsAddOnLoaded reports as loaded (e.g. "LoonBestInSlot")."""
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
        self.server_time0 = server_time
        self.now = 0.0
        self.clients = []
        self.offline_members = []
        self.notes = {}
        self.guild_texts = {}
        self.auto_accept_invites = True   # invited online clients accept after `latency` (InviteUnit)
        self.invite_log = []              # {time, by, target, result}
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
            return
        if not self.auto_accept_invites:
            entry["result"] = "pending"
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
        self._enqueue(self.latency, None, "call", accept)

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
                 addon_dir=None, other_addons=(), bank_requires_open=True, sv_before_files=None):
        """One simulated player = one Lua runtime. Created online (runtime ready, addon not yet loaded) unless
        online=False (call .login() later). legacy_globals=True defines deprecation-gated globals (GetItemInfo,
        GetContainer*, GetAddOnMetadata, GuildRoster, GetLootMethod). permissive_fields=True makes unknown frame
        fields return auto-created mock frames instead of nil. items_uncached=True makes item data load
        asynchronously (first query returns nil + GET_ITEM_INFO_RECEIVED/ITEM_DATA_LOAD_RESULT next tick).
        sv_before_files: when SavedVariables are assigned. None (default) follows the TOC: before the addon files
        run with "## LoadSavedVariablesFirst: 1", else after them, right before ADDON_LOADED (WoW's classic order).
        True / False force one order (False = a client that ignores the directive)."""
        self.world = world
        self.name = name
        self.realm = realm or world.realm
        self.class_file = class_file
        self.guild = guild
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
        self.index = next(Client._index)
        self.time_offset = 1000.0 + 137.25 * self.index
        self.online = bool(online)
        self.runtime = None
        self.M = None
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
        py = rt.table_from({
            "send_addon": self._py_send_addon, "send_chat": self._py_send_chat,
            "set_guild_info_text": self._py_set_guild_info_text, "set_note": self._py_set_note,
            "give_master_loot": self._py_give_master_loot, "item_lookup": self._py_item_lookup,
            "random_roll": self._py_random_roll,
            "set_raid_target": lambda guid, idx: self.world.set_raid_target(self, guid, idx),
            "invite": lambda name: self.world.invite(self, name),
            "convert_to_raid": lambda: self.world.convert_to_raid(self),
            "set_raid_subgroup": lambda i, g: self.world.set_raid_subgroup(self, i, g),
            "swap_raid_subgroup": lambda a, b: self.world.swap_raid_subgroup(self, a, b),
        })
        sources = rt.table_from(_mock_sources())
        res = rt.globals().loadstring(_read(os.path.join(MOCK_DIR, "mock.lua")), "@wowmock/mock.lua")
        fn = res[0] if isinstance(res, tuple) else res
        if fn is None:
            raise RuntimeError("wowmock/mock.lua failed to compile: %s" % (res[1],))
        self.M = fn(cfg, py, sources)
        self.M.load_items(_read(os.path.join(MOCK_DIR, "items.lua")))
        for iid in self.world.custom_items:
            self._define_item(iid)
        self._push_state()
        if self.preload_lua:
            self.eval(self.preload_lua)

    def _define_item(self, iid):
        name, q, loc, cls, sub, icon, ilvl, minlvl, bind, stack = self.world.custom_items[iid]
        self.M.define_item(iid, name, q, loc, cls, sub, icon, ilvl, minlvl, bind, stack)

    def _push_state(self):
        if self.runtime is None:
            return
        self.M.set_world(to_lua(self.runtime, self.world._state_for(self)))

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
            tocs = [f[:-4] for f in os.listdir(self.addon_dir) if f.lower().endswith(".toc")]
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
        headers, files = self.toc()
        self._set_time()
        self.M.set_toc_meta(self.addon_name, to_lua(self.runtime, headers))
        sv_first = self.sv_before_files
        if sv_first is None:
            sv_first = (headers.get("loadsavedvariablesfirst") or "").lower() in ("1", "true")
        if PATCH_SV_FILE and self.addon_name == ADDON_NAME and "DisasterZonePatchDB" not in self.world.saved.get(self.full_name, {}):
            with open(PATCH_SV_FILE, encoding="utf-8") as fh:
                self.world.saved.setdefault(self.full_name, {})["DisasterZonePatchDB"] = fh.read()
        for name, src in self.other_saved.items():
            self.M.apply_saved(name, src)
        if sv_first:
            self._apply_saved(headers)
        missing = []
        for rel in files:
            if rel.lower().endswith(".xml"):
                if not os.path.exists(os.path.join(self.addon_dir, rel)):
                    missing.append(rel)
                    continue
                for lua in _xml_scripts(self.addon_dir, rel):
                    self._load_one(lua, missing)
            else:
                self._load_one(rel, missing)
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
        self.M.addon_loaded(self.addon_name)
        self.M.login_events(not reload, bool(reload), self.world.roster_delay or 0)
        self.loaded = True
        if self.world.fail_fast:
            self.world.assert_no_errors()
        return self

    def _apply_saved(self, headers):
        for sv in self._sv_names(headers):
            src = self.world.saved.get(self.full_name, {}).get(sv)
            if src is not None:
                self.M.apply_saved(sv, src)

    def set_saved_variable(self, name, lua_source):
        """Pre-seed a SavedVariable (Lua table constructor source, e.g. '{ settings = { debug = true } }') that
        the next load_addon()/login() will assign."""
        self.world.saved.setdefault(self.full_name, {})[name] = lua_source

    def _load_one(self, rel, missing):
        path = os.path.join(self.addon_dir, rel)
        if not os.path.exists(path):
            missing.append(rel)
            return
        with open(path, "rb") as fh:  # not cached: other agents edit the addon while tests run
            src = fh.read()
        if src.startswith(b"\xef\xbb\xbf"):
            src = src[3:]
        self._set_time()
        self.M.load_file(src, "@Interface/AddOns/%s/%s" % (self.addon_name, rel.replace("\\", "/")), self.addon_name)

    def load_files(self, files, fire_login=False, addon_name=ADDON_NAME):
        """Load specific files (relative to the addon folder, or absolute) with (addon_name, ns). With
        fire_login=True also fire ADDON_LOADED + login events afterwards."""
        missing = []
        if PATCH_SV_FILE and addon_name == ADDON_NAME and not self.eval("return DisasterZonePatchDB ~= nil"):
            # patched run: the stored update must be there before the first file, as load_addon() arranges
            with open(PATCH_SV_FILE, encoding="utf-8") as fh:
                self.M.apply_saved("DisasterZonePatchDB", fh.read())
        for f in files:
            if os.path.isabs(f):
                if not os.path.exists(f):
                    missing.append(f)
                    continue
                src = open(f, "rb").read()
                self._set_time()
                self.M.load_file(src, "@" + f.replace("\\", "/"), addon_name)
            else:
                self._load_one(f.replace("\\", "/"), missing)
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

    def login(self, load=True):
        self.online = True
        self._new_runtime()
        self.world._sync(roster_changed=True, guild=self.guild)
        self._notify_guild("|Hplayer:%s|h[%s]|h has come online." % (self.name, self.name))
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

    def accept_popup(self, name, text=None):
        """Click button1 (OnAccept) of the visible StaticPopup `name`; text fills its edit box first."""
        if not self._call("popup_act", name, 1, text):
            raise AssertionError("%s: no visible StaticPopup %r (visible: %s)" % (self.full_name, name, self.popups()))

    def cancel_popup(self, name):
        if not self._call("popup_act", name, 2, None):
            raise AssertionError("%s: no visible StaticPopup %r" % (self.full_name, name))

    def escape_popups(self):
        """Press Escape in the game world: StaticPopup_EscapePressed (what ToggleGameMenu runs first). Every shown
        hideOnEscape popup gets OnCancel(dialog, data, "clicked") unless noCancelOnEscape. True if one closed."""
        return bool(self._call("popup_escape"))

    def set_ml_refusal(self, member, kind="inv_full"):
        """Make the server refuse this client's GiveMasterLoot to `member` (client, ExtraMember or 'Name[-Realm]'):
        kind "inv_full" | "unique" | "other" | "not_found" -> UI_ERROR_MESSAGE, item stays; None = accept again."""
        m = self.world._member(member)
        full = m.full_name if m is not None else str(member)
        self._call("set_ml_refusal", full, kind)

    def popups(self):
        return self.eval_py("""
            local out = {}
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
