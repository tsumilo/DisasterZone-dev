"""Shared setup for the loot-roll scenario tests (DisasterZone, real addon code, mocked multi-client WoW).

Not a test file itself. Every test_*.py in this folder imports it:
    from lr_common import *
"""
import os
import re
import sys
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
SCRATCH = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(SCRATCH, "tools"))
sys.path.insert(0, os.path.join(SCRATCH, "tests"))

from harness import World, Client, ExtraMember, LuaErrorsFound, LuaEvalError, in_shard  # noqa: E402,F401
from cdl_council import gm_pick, raid_pick, seed_guild_council  # noqa: E402,F401

# ---------------------------------------------------------------------------------------------------------------
# Item ids (Karazhan / Prince Malchezaar unless noted)
# ---------------------------------------------------------------------------------------------------------------
PRINCE_NPC = 15690
PRINCE_GUID = "Creature-0-1-2-3-15690-000ABC"
PRINCE_ENCOUNTER = 661
RUBY_DRAPE = 28766          # cloak (caster)
FARSTRIDER = 28764          # cloak (hunter)
JADE_RING = 28763           # ring
THOUSAND_MARKS = 28757      # ring
MINDBLADE = 28770           # dagger
LIGHTS_JUSTICE = 28771      # mace
HELM_CHAMPION = 29760       # token: PALADIN, ROGUE, SHAMAN
HELM_DEFENDER = 29761       # token: WARRIOR, PRIEST, DRUID
HELM_HERO = 29759           # token: HUNTER, MAGE, WARLOCK
JUSTICAR_DIADEM = 29061     # PALADIN head (Champion token)
NETHERBLADE_MASK = 29044    # ROGUE head (Champion token)
CYCLONE_HEADDRESS = 29028   # SHAMAN head (Champion token)
WARBRINGER_HELM = 29011     # WARRIOR head (Defender token)
COLLAR_ALDOR = 29076        # MAGE head (Hero token)
DEMON_STALKER_HELM = 29081  # HUNTER head (Hero token)
MURU_NPC = 25741            # Sunwell M'uru
MURU_GUID = "Creature-0-1-2-3-25741-000DEF"
FALTERED_ROBES = 34233      # M'uru drop (cloth robe), Sunmote upgrade base
GHOSTLY_ROBES = 34399       # upgraded (Robes of Faltered Light + Sunmote)
HARBINGER_BANDS = 28477     # Attumen

# DisasterZone slot ids
SID_HEAD, SID_NECK, SID_BACK, SID_CHEST = 1, 2, 4, 5
SID_RING1, SID_RING2, SID_MH = 11, 12, 15

REALM = "Thunderstrike"


def key(name):
    return "%s-%s" % (name, REALM)


# ---------------------------------------------------------------------------------------------------------------
# Tiny runner
# ---------------------------------------------------------------------------------------------------------------
class Runner:
    def __init__(self, title):
        self.title = title
        self.results = []

    def case(self, fn):
        """Decorator: register a case function(ctx) -> None (asserts)."""
        self.results.append((fn.__name__, fn))
        return fn

    def run(self, only=None):
        failed = 0
        print("== %s ==" % self.title)
        picked = [(n, f) for n, f in self.results if not only or only in n]
        picked = [nf for i, nf in enumerate(picked) if in_shard(i)]
        for name, fn in picked:
            try:
                fn()
                print("PASS %s" % name)
            except Exception as e:  # noqa: BLE001 - report everything
                failed += 1
                print("FAIL %s: %s" % (name, _short(e)))
                tb = traceback.format_exc()
                print("     " + "\n     ".join(tb.strip().splitlines()[-25:]))
        total = len(picked)
        print("-- %s: %d case(s), %d passed, %d failed" % (self.title, total, total - failed, failed))
        return 1 if failed else 0


def _short(e):
    s = str(e)
    return s if len(s) < 1500 else s[:1500] + " ..."


def main(runner):
    only = None
    if len(sys.argv) > 2 and sys.argv[1] == "-k":
        only = sys.argv[2]
    sys.exit(runner.run(only))


# ---------------------------------------------------------------------------------------------------------------
# World setup
# ---------------------------------------------------------------------------------------------------------------
# name, class, guild rank. Council (Addendum E): the Guild Master (rank 0) plus the guild council list the GM
# picks; Raid() has the GM pick every rank-1 member (what the old default "r1" made council), see setup_council.
ROSTER = [
    ("Alice", "PALADIN", 0),   # GM, council, raid leader + master looter
    ("Bob", "MAGE", 1),        # officer, council (not ML)
    ("Carol", "WARRIOR", 3),
    ("Dave", "PRIEST", 3),
    ("Erin", "ROGUE", 3),
    ("Frank", "HUNTER", 2),
    ("Gina", "SHAMAN", 3),
]

# P1 BiS lists seeded through the addon's own BiS API: (phase, sid, which, itemID)
BIS = {
    "Alice": [(1, SID_HEAD, "main", JUSTICAR_DIADEM), (1, SID_RING1, "main", JADE_RING)],
    "Bob": [(1, SID_BACK, "main", RUBY_DRAPE), (1, SID_HEAD, "main", COLLAR_ALDOR)],
    "Carol": [(1, SID_RING1, "main", THOUSAND_MARKS), (1, SID_HEAD, "main", WARBRINGER_HELM)],
    "Dave": [(1, SID_BACK, "alt", RUBY_DRAPE), (1, SID_RING1, "main", JADE_RING)],
    "Erin": [(1, SID_HEAD, "main", NETHERBLADE_MASK), (1, SID_RING1, "alt", THOUSAND_MARKS)],
    "Frank": [(1, SID_BACK, "main", FARSTRIDER), (1, SID_HEAD, "main", DEMON_STALKER_HELM)],
    "Gina": [(1, SID_HEAD, "main", CYCLONE_HEADDRESS)],
}

EXTRA = [ExtraMember("Zed", "WARRIOR", guild="Casual Disaster", guild_rank=4),   # guildie without the addon
         ExtraMember("Yuri", "DRUID")]                                         # pug without the addon


class Raid:
    """A loaded, synced raid: r.w (World), r.c['Alice'] ... (Clients), r.extra (ExtraMembers)."""

    def __init__(self, roster=ROSTER, bis=BIS, extra=EXTRA, ml="Alice", sync=True, instance=True,
                 encounter=True, client_kw=None, world_kw=None, raid=True, loot_method=None, extra_bis=None):
        self.w = World(**(world_kw or {}))
        self.c = {}
        for name, cls, rank in roster:
            kw = dict((client_kw or {}).get(name, {}))
            self.c[name] = Client(self.w, name, class_file=cls, guild_rank=rank, **kw)
        for cl in self.c.values():
            cl.load_addon()
        install_probes(self.c.values())
        self.w.tick(2)
        setup_council(self.w, self.c, roster)
        self.ml = ml
        self.extra = [ExtraMember(e.name, e.class_file, realm=e.realm or REALM, guild=e.guild, guild_rank=e.guild_rank)
                      for e in extra]
        for e in self.extra:
            if e.guild:
                # the roster only lists clients + offline members; make the extra an online guild member
                self.w.offline_members.append(e)
        self.w._sync(roster_changed=True)
        self.w.tick(1)
        self.loot_method = loot_method
        if raid:
            self.form_raid(list(self.c.values()))
        for name, entries in list((bis or {}).items()) + list((extra_bis or {}).items()):
            if name in self.c:
                seed_bis(self.c[name], entries)
        if sync:
            self.sync()
        if instance and raid:
            self.w.enter_instance("Karazhan", 532)
            self.w.tick(1)
        if encounter and raid:
            self.w.encounter(PRINCE_ENCOUNTER, "Prince Malchezaar")
            self.w.tick(0.5)

    def form_raid(self, members, tick=1):
        """(Re)form the raid with these clients + the extras (leader Alice, ML self.ml unless it left)."""
        ml = self.c.get(self.ml) if self.ml else None
        if ml is not None and ml not in members:
            ml = None
        self.w.make_raid(members, master_looter=ml, leader=members[0], extra_members=self.extra,
                         loot_method=self.loot_method)
        self.w.tick(tick)

    def leave_raid(self, name, tick=1):
        """`name` leaves the raid (everybody else stays grouped)."""
        rest = [c for c in self.w.group_members() if hasattr(c, "runtime") and c.runtime is not None
                and getattr(c, "loaded", False) and c.name != name]
        self.form_raid(rest, tick)

    def sync(self, seconds=45):
        for cl in self.c.values():
            cl.eval("ns.BiS:Commit()")
        self.w.tick(1)
        for cl in self.c.values():
            cl.slash("/dz sync")
            self.w.tick(0.3)
        self.w.tick(seconds)

    @property
    def clients(self):
        return list(self.c.values())

    def __getitem__(self, name):
        return self.c[name]


def set_features(r, loot=True, rolls=True, lock=False, by="Alice", tick=3):
    """The running raid session's features (1.2): loot council, rolls, BiS lock; set by the raid's authority. 1.3:
    loot=False makes rolls plain and takes the master looter off the raid's council."""
    res = r[by].eval_py("local ok, e = ns.GroupRules:SetSessionFeatures(...); return { ok = ok, e = e }",
                        {"loot": loot, "rolls": rolls, "lock": lock})
    assert res.get("ok") is True, "SetSessionFeatures refused: %r" % (res,)
    r.w.tick(tick)


def setup_council(w, clients, roster):
    """The loot council of a scenario roster: the rank-0 client is the Guild Master and picks every rank-1 member
    (Guild:SetGuildCouncil -> CG on GUILD). Without a GM client the rank-1 members get the stored list directly."""
    picks = [name for name, _, rank in roster if rank == 1]
    gm = next((clients[name] for name, _, rank in roster if rank == 0 and name in clients), None)
    if gm is not None:
        gm_pick(w, gm, picks)
    elif picks:
        seed_guild_council(w, picks)
    return picks


def seed_bis(client, entries):
    for phase, sid, which, item in entries:
        ok = client.eval("return ns.BiS:SetSlot(...)", phase, sid, which, item)
        assert ok, "%s: SetSlot(%s, %s, %s, %s) refused" % (client.name, phase, sid, which, item)
    client.eval("ns.BiS:Commit()")


# ---------------------------------------------------------------------------------------------------------------
# Lua probes
# ---------------------------------------------------------------------------------------------------------------
def printed_lines(client):
    """Everything the client printed (ns:Print goes through DEFAULT_CHAT_FRAME:AddMessage)."""
    return [str(x) for x in client.chat_frame]


def strip_codes(s):
    s = re.sub(r"\|c[0-9a-fA-F]{8}", "", s)
    s = s.replace("|r", "")
    s = re.sub(r"\|H[^|]*\|h", "", s).replace("|h", "")
    s = re.sub(r"\|T[^|]*\|t", "*", s)
    return s


def wanter_keys(client, item_id, **opts):
    return client.eval_py("""
        local id, o = ...
        local out = {}
        for _, w in ipairs(ns.Store:GetWanters(id, o)) do out[#out + 1] = w.key .. ':' .. w.which end
        return out""", item_id, opts or {}) or []


def drop_history(client):
    return client.eval_py("return ns.Loot:GetHistory()") or []


def drops_fired(client):
    return client.eval_py("return __LR and __LR.drops or {}") or []


PROBE_LUA = r"""
__LR = __LR or { drops = {}, started = {}, updated = {} }
if not __LR.hooked then
  __LR.hooked = true
  ns:On("DROP", function(d)
    local items = {}
    for i, id in ipairs(d.i or {}) do items[i] = id end
    __LR.drops[#__LR.drops + 1] = { s = d.s, b = d.b, i = items, roll = d.roll and true or false,
      test = d.test and true or false, from = d.from }
  end)
  ns:On("ROLL_STARTED", function(s) __LR.started[#__LR.started + 1] = s.id end)
end
"""


def install_probes(clients):
    for c in clients:
        c.eval(PROBE_LUA)


def panel_blocks(client):
    """Visible drop-panel blocks: [{item, names:[short names in row order], sub, awarded, buttons:[labels],
    more:[the card's More menu entries: Announce, Disenchant, Guild bank, Award]}]."""
    return client.eval_py(r"""
        local DP = ns.DropPanel
        local out = {}
        if not (DP.frame and DP.frame:IsShown()) then return out end
        for _, b in ipairs(DP.blocks) do
          if b:IsShown() then
            local names = {}
            for _, r in ipairs(b.rows) do
              if r:IsShown() and r.data and r.data.key then names[#names + 1] = r.data.key end
            end
            local btns = {}
            for _, btn in ipairs(b.actionButtons) do
              if btn:IsShown() then btns[#btns + 1] = btn:GetText() or "?" end
            end
            local more = {}
            for _, e in ipairs(DP.GetMoreActions and DP:GetMoreActions(b) or {}) do more[#more + 1] = e.label end
            out[#out + 1] = { item = b.itemID, copy = b.copy, names = names, sub = b.sub:GetText() or "",
              awarded = b.awarded:GetText() or "", buttons = btns, more = more,
              none = b.none:IsShown() and b.none:GetText() or "" }
          end
        end
        return out""") or []


def toast_state(client):
    return client.eval_py(r"""
        local DP = ns.DropPanel
        local t = DP.toast
        local q = {}
        for i, e in ipairs(DP.toastQueue or {}) do q[i] = e.itemID end
        return { shown = (t and t:IsShown()) and true or false,
                 item = t and t.entry and t.entry.itemID or nil,
                 title = t and t.title and t.title:GetText() or nil,
                 kicker = t and t.kick and t.kick:GetText() or nil,
                 text = t and t.text and t.text:GetText() or nil,
                 queue = q }""")


def rollframe_state(client):
    return client.eval_py(r"""
        local RF = ns.RollFrame
        local f = RF.frame
        if not f then return { shown = false } end
        -- bis: the pill ("BiS" / "Alt" / "OS") and the line after it ("Head · P1"), or "Not on your BiS list"
        local pill = (f.bisPill and f.bisPill:IsShown()) and ((f.bisPill.fs:GetText() or "") .. " ") or ""
        return { shown = f:IsShown() and true or false, id = RF.sessionID,
                 status = f.status:GetText() or "", bis = pill .. (f.bis:GetText() or ""), name = f.name:GetText() or "",
                 rollShown = f.roll:IsShown() and true or false, passShown = f.pass:IsShown() and true or false }""")


def active_session(client):
    return client.eval_py(r"""
        local s = ns.Roll:GetActive()
        if not s then return nil end
        return { id = s.id, i = s.i, s = s.s, c = s.c, state = s.state, starter = s.starter }""")


def session_info(client, sid):
    return client.eval_py(r"""
        local s = ns.Roll:Get(...)
        if not s then return nil end
        local rolls = {}
        for k, r in pairs(s.rolls) do rolls[k] = { roll = r.roll, count = r.count, invalid = r.invalid, min = r.min, max = r.max } end
        local resp = {}
        for k, r in pairs(s.responses) do resp[k] = r end
        return { id = s.id, i = s.i, s = s.s, c = s.c, state = s.state, starter = s.starter, winner = s.winner,
                 given = s.given, rolls = rolls, responses = resp }""", sid)


def results(client, sid):
    return client.eval_py(r"""
        local out = {}
        for i, r in ipairs(ns.Roll:GetResults(...)) do
          out[i] = { key = r.key, roll = r.roll, tier = r.tier, invalid = r.invalid, count = r.count,
                     response = r.response, suggested = r.suggested, tie = r.tie, which = r.which,
                     inRaid = r.inRaid, cantUse = r.cantUse, wonCopy = r.wonCopy, lockChanged = r.lockChanged }
        end
        return out""", sid) or []


def ledger_visible(client, **flt):
    return client.eval_py(r"""
        local out = {}
        for i, e in ipairs(ns.Ledger:GetEntries(...)) do
          out[i] = { id = e.id, i = e.i, w = e.w, s = e.s, n = e.n, b = e.b, by = e.by, vd = e.vd }
        end
        return out""", flt or {}) or []


def ledger_raw(client):
    return client.eval_py(r"""
        local out = {}
        for id, e in pairs(ns.db.ledger) do out[#out + 1] = { id = id, i = e.i, w = e.w, s = e.s, n = e.n } end
        table.sort(out, function(a, b) return a.id < b.id end)
        return out""") or []


def chat_since(w, start):
    return w.chat_log[start:]


def popups_log(client):
    return client.eval_py(r"""
        local out = {}
        for i, p in ipairs(__MOCK.popup_log or {}) do out[i] = { which = p.which, text = p.text } end
        return out""") or []


def _ace_part(text):
    """(control, rest) of one AceComm wire text: control 1 = first part, 2 = next, 3 = last, 4 = an escaped single
    message, None = a plain single message (rest = the whole text)."""
    c = (text[0] if isinstance(text, bytes) else ord(text[0])) if text else None
    return (c, text[1:]) if c in (1, 2, 3, 4) else (None, text)


def msgs_of_type(w, t, start=0, whole=False):
    """Decode DisasterZone comm messages (prefix CDL*) of type t sent since addon_log index `start`, using a client's
    own LibDeflate/LibSerialize (any loaded client works). A message over 255 bytes leaves in AceComm parts, which
    don't decode on their own and are skipped. whole=True joins the parts: the message counts at its last part's log
    entry, and one whose first part went out before `start` is left out."""
    out = []
    dec = None
    partial = {}
    for e in w.addon_log[start:]:
        if not e["prefix"].startswith("CDL"):
            continue
        text = e["text"]
        if whole:
            ctl, rest = _ace_part(text)
            k = (e["sender"], e["prefix"], e["chat_type"], e.get("target") or "")
            if ctl == 1:
                partial[k] = [rest]
                continue
            if ctl in (2, 3):
                if k not in partial:
                    continue
                partial[k].append(rest)
                if ctl == 2:
                    continue
                text = rest[:0].join(partial.pop(k))
            elif ctl == 4:
                text = rest
        if dec is None:
            dec = next(c for c in w.clients if c.runtime is not None and c.loaded)
        m = decode_msg(dec, text)
        if m and m.get("t") == t:
            m["_sender"] = e["sender"]
            m["_chat_type"] = e["chat_type"]
            m["_time"] = e["time"]
            out.append(m)
    return out


def decode_msg(client, text):
    try:
        return client.eval_py(r"""
            local text = ...
            local LD = LibStub("LibDeflate")
            local LS = LibStub("LibSerialize")
            local body = text:sub(2)
            local d = LD:DecodeForWoWAddonChannel(body)
            if not d then return nil end
            local raw = LD:DecompressDeflate(d)
            if not raw then return nil end
            local ok, msg = LS:Deserialize(raw)
            if not ok then return nil end
            return msg""", text)
    except Exception:
        return None
