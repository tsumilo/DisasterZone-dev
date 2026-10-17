"""Council helpers shared by the DisasterZone suites (Addendum E: picked council, no Guild Info tag).

Imported by every suite's common module (tests/boot-ui/_common.py, tests/sync/common.py,
tests/loot-roll/lr_common.py) and by the council / group-rules suites. Nothing here changes the addon or the
harness itself; the one harness shim (seed_guild_council) only acts on worlds that opt in.

The council model (Addendum E §29):
  * the Guild Master (rank index 0 in the live roster) is always council;
  * the guild council list the GM picks (CG on GUILD), stored by every client in db.council.guild;
  * in a raid: the raid leader and the raid council list that leader picks (CR on RAID, memory only).

Helpers:
  seed_guild_council(w, names, ...)  every client of the world has the GM's list stored (SavedVariables), as if
                                     it was received earlier. This replaces the old ambient "CDL{r1}" tag of the
                                     scenario worlds: applied when a client loads (and to loaded clients at once).
  gm_pick(w, gm, names, phase)       the GM saves the guild list through the real Guild:SetGuildCouncil path
                                     (CG on GUILD) and the world ticks until it is delivered.
  raid_pick(w, leader, names)        the raid leader saves his raid list (Guild:SetMyRaidList -> CR on RAID).
  key(name, realm)                   "Name-Realm" key.
  GUILD_INFO_SPY                     preload_lua that counts every Guild Information text API call.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.path.join(os.path.dirname(HERE), "tools")
if TOOLS not in sys.path:
    sys.path.insert(0, TOOLS)

import harness  # noqa: E402

REALM = "Thunderstrike"
GUILD = "Casual Disaster"
# Seeded lists are "older" than anything a GM saves during a scenario (a live SetGuildCouncil rev is the
# server time), so a GM change always wins over the seed, and a relog never brings the seed back.
SEED_REV_OFFSET = 86400


def key(name, realm=REALM):
    if "-" in name:
        return name
    return "%s-%s" % (name, harness.normalize_realm(realm))


def _keys(names, realm=REALM):
    out = []
    for n in names or ():
        if isinstance(n, (harness.Client, harness.ExtraMember)):
            out.append(n.full_name)
        else:
            out.append(key(n, realm))
    return out


# ------------------------------------------------------------------------------------------------------------------
# Stored guild council (SavedVariables seed)
# ------------------------------------------------------------------------------------------------------------------
SEED_LUA = r"""
local members, phase, by, rev, recvAt, gk = ...
if type(DisasterZoneDB) ~= "table" then DisasterZoneDB = {} end
local db = DisasterZoneDB
if type(db.council) ~= "table" then db.council = {} end
local c = db.council
local set = {}
for _, k in ipairs(members) do set[k] = true end
local rec = { rev = rev, members = set, phase = phase, by = by, recvAt = recvAt, g = gk }
local cur = c.guild
if type(cur) == "table" and cur.g ~= nil and cur.g ~= gk then
  -- the stored list belongs to another guild (account-wide SavedVariables): seed this guild's parked slot
  if type(c.otherGuilds) ~= "table" then c.otherGuilds = {} end
  local parked = c.otherGuilds[gk]
  if type(parked) == "table" and (tonumber(parked.rev) or 0) >= rev then return false end
  c.otherGuilds[gk] = rec
  return true
end
if type(cur) == "table" and (tonumber(cur.rev) or 0) >= rev then return false end
c.guild = rec
return true
"""


def _seed_client(c):
    seeds = getattr(c.world, "cdl_council_seed", None) or {}
    s = seeds.get(c.guild) if c.guild else None
    if not s or c.runtime is None:
        return False
    gk = "%s-%s" % (c.guild, harness.normalize_realm(c.realm))
    fn = c.runtime.eval("function(src, ...) return loadstring(src)(...) end")
    return bool(fn(SEED_LUA, c.runtime.table(*s["members"]), s["phase"], s["by"], s["rev"], s["recvAt"], gk))


def seed_guild_council(w, names, phase=1, guild=GUILD, by=None, realm=REALM):
    """Every client of `guild` in world `w` has the GM's guild council list stored (db.council.guild), as if the
    GM had picked `names` some time ago and the list reached everyone. Applied to each client when it loads
    (clients created later, relogs with an older copy: World.on_saved_applied) and right away to clients already
    loaded (followed by a roster refresh, so CONFIG_UPDATED fires as it would for an accepted CG). `by` = the GM's
    name, if any."""
    seeds = getattr(w, "cdl_council_seed", None)
    if seeds is None:
        seeds = {}
        w.cdl_council_seed = seeds
        w.on_saved_applied.append(_seed_client)
    rev = int(w.server_time0) - SEED_REV_OFFSET
    prev = seeds.get(guild)
    if prev and prev["rev"] >= rev:
        rev = prev["rev"] + 1
    seeds[guild] = {"members": _keys(names, realm), "phase": int(phase), "by": key(by, realm) if by else None,
                    "rev": rev, "recvAt": int(w.server_time)}
    for c in w.clients:
        if c.guild == guild and c.runtime is not None and c.loaded:
            if _seed_client(c):
                c.fire("GUILD_ROSTER_UPDATE", False)
    w.tick(0)
    return rev


# ------------------------------------------------------------------------------------------------------------------
# Live picks through the addon (CG / CR on the wire)
# ------------------------------------------------------------------------------------------------------------------
def gm_pick(w, gm, names, phase=None, tick=1.0, realm=REALM):
    """The Guild Master `gm` (a loaded rank-0 client) saves the guild council list `names` (+ phase) through
    ns.Guild:SetGuildCouncil; the world then ticks `tick` seconds so the CG reaches every online member."""
    keys = _keys(names, realm)
    res = gm.eval_py("""
      local keys, phase = ...
      local set = {}
      for _, k in ipairs(keys) do set[k] = true end
      local ok, err = ns.Guild:SetGuildCouncil(set, phase)
      return { ok = ok, err = err }""", keys, phase)
    assert res.get("ok") is True, "%s: SetGuildCouncil refused: %r" % (gm.full_name, res.get("err"))
    if tick:
        w.tick(tick)
    return gm.eval("return ns.Guild:GetGuildCouncilRev()")


def raid_pick(w, leader, names, tick=1.0, realm=REALM):
    """`leader` saves his raid council list (Guild:SetMyRaidList); while he leads a raid it is shared (CR)."""
    keys = _keys(names, realm)
    res = leader.eval_py("""
      local keys = ...
      local set = {}
      for _, k in ipairs(keys) do set[k] = true end
      local ok, err = ns.Guild:SetMyRaidList(set)
      return { ok = ok, err = err }""", keys)
    assert res.get("ok") is True, "%s: SetMyRaidList refused: %r" % (leader.full_name, res.get("err"))
    if tick:
        w.tick(tick)


def council_of(c):
    """Sorted council members as c sees them (real data only)."""
    return sorted(c.eval_py("""
      local out = {}
      for _, k in ipairs(ns.Guild:GetCouncilMembers()) do
        if ns.Guild:IsCouncil(k, true) then out[#out + 1] = k end
      end
      return out""") or [])


# ------------------------------------------------------------------------------------------------------------------
# Guild Information API spy (Addendum E §33/§34: DisasterZone never reads or writes the Guild Info text)
# ------------------------------------------------------------------------------------------------------------------
GUILD_INFO_SPY = r"""
__GI_SPY = { calls = {} }
local function wrap(tbl, name, label)
  local orig = tbl[name]
  tbl[name] = function(...)
    __GI_SPY.calls[#__GI_SPY.calls + 1] = label
    if orig then return orig(...) end
  end
end
wrap(_G, "GetGuildInfoText", "GetGuildInfoText")
wrap(_G, "SetGuildInfoText", "SetGuildInfoText")
if type(C_GuildInfo) == "table" then
  wrap(C_GuildInfo, "GetInfoText", "C_GuildInfo.GetInfoText")
  wrap(C_GuildInfo, "SetInfoText", "C_GuildInfo.SetInfoText")
end
"""


def guild_info_calls(c):
    """Guild Information API calls recorded by GUILD_INFO_SPY in c's current runtime."""
    return list(c.eval_py("return __GI_SPY and __GI_SPY.calls or {}") or [])
