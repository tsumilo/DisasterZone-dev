"""Damage + threat meters (Core/Meter.lua, Core/Threat.lua, UI/MeterWindow.lua, UI/ThreatWindow.lua,
UI/MeterDetail.lua, Settings > Meters).

Covers: both off by default (the combat log not even listened to); damage done counted as amount - overkill + absorbed
for every group member, with crits, glancing hits and misses, never for hits on the group or for players outside it;
pets and totems for their owner (SPELL_SUMMON), unknown pets left out; effective healing, overhealing and shields
(both SPELL_ABSORBED forms); damage taken including hits a shield took whole; fights starting on the first hit and
ending once the group is out of combat, empty ones dropped; boss fights (a trash fight right before the pull becomes
the boss fight), kill / wipe with the boss's health; trash adding up between bosses (split = boss); Whole raid adding
every fight up and starting over in a new instance; deaths with a recap of the last 10 s naming the killing blow,
feign death ignored; interrupts and dispels; the spec from signature spells; fights past meters.keep dropped; a
/reload mid-fight saved as cut short; the window (shown in a group, bars in order, my bar pinned below the fold, the
mode / fight menus, a click opening the breakdown and in Deaths mode the recap); the threat table (rows, my pull
point, the warning with one sound, tank view, which enemy); the threat window; the Settings section dimming its rows;
demo mode; nothing ever sent.

Run: luaenv\\Scripts\\python.exe tests\\meters\\test_meters.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))

from _common import World, Client, case, run_all  # noqa: E402
from harness import ExtraMember  # noqa: E402

ME_FLAGS = 0x511
RAID_FLAGS = 0x514
RAID_PET = 0x1114
RAID_GUARD = 0x2114
OUTSIDER = 0x548
BOSS_FLAGS = 0xA48

FILES = ["Core/Meter.lua", "Core/Threat.lua", "Core/MeterDemo.lua", "UI/MeterWindow.lua", "UI/ThreatWindow.lua",
         "UI/MeterDetail.lua"]


class Raid:
    """Gina (me) in a raid with a few others, inside Tempest Keep, with the meters on (unless told otherwise)."""

    def __init__(self, dmg=True, thr=False, instance=True, extra=None):
        w = World()
        w.auto_session = False
        cl = Client(w, "Gina", class_file="PALADIN", guild_rank=3)
        cl.load_addon()
        w.tick(3)
        if dmg:
            cl.eval("ns.DB:SetSetting('meters.dmg', true)")
        if thr:
            cl.eval("ns.DB:SetSetting('meters.thr', true)")
        if instance:
            w.enter_instance("Tempest Keep", 550, "raid", 25, difficulty_id=4)
        self.others = extra or [ExtraMember("Victhar", "WARRIOR"), ExtraMember("Pugsy", "PRIEST"),
                                ExtraMember("Hunt", "HUNTER")]
        w.make_raid([cl], extra_members=self.others)
        w.tick(1)
        self.w, self.cl = w, cl
        self.me = cl.eval("return UnitGUID('player')")
        self.g = {m.name: m.guid for m in self.others}
        self.g["Gina"] = self.me
        self.boss = w.spawn_npc(19516, "Void Reaver")
        self.add = w.spawn_npc(20040, "Crystalcore Devastator")

    def ev(self, sub, src, src_name, src_flags, dst, dst_name, dst_flags, *rest):
        self.cl.combat_log(self.cl.eval("return GetTime()"), sub, False, src or "", src_name or "", src_flags, 0,
                           dst or "", dst_name or "", dst_flags, 0, *rest)

    def flags(self, name):
        return ME_FLAGS if name == "Gina" else RAID_FLAGS

    def hit(self, who, amount, spell=35395, name=None, dst=None, dst_name="Void Reaver", overkill=-1, absorbed=None,
            crit=False, sub="SPELL_DAMAGE"):
        name = name or self.spell(spell)
        self.ev(sub, self.g[who], who, self.flags(who), dst or self.boss, dst_name, BOSS_FLAGS,
                spell, name, 1, amount, overkill, 1, None, None, absorbed, crit, False, False)

    def swing(self, who, amount, glancing=False, crit=False, dst=None, dst_name="Void Reaver"):
        self.ev("SWING_DAMAGE", self.g[who], who, self.flags(who), dst or self.boss, dst_name, BOSS_FLAGS,
                amount, -1, 1, None, None, None, crit, glancing, False, False)

    def boss_hits(self, who, amount, spell=34172, absorbed=None, overkill=-1):
        self.ev("SPELL_DAMAGE", self.boss, "Void Reaver", BOSS_FLAGS, self.g[who], who, self.flags(who),
                spell, self.spell(spell), 64, amount, overkill, 64, None, None, absorbed, False, False, False)

    def heal(self, who, target, amount, over=0, spell=25213):
        self.ev("SPELL_HEAL", self.g[who], who, self.flags(who), self.g[target], target, self.flags(target),
                spell, self.spell(spell), 2, amount, over, None, False)

    def spell(self, sid):
        return self.cl.eval("return (GetSpellInfo(...))", sid)

    def tick(self, s):
        self.w.tick(s)

    def combat(self, on, *names):
        self.cl.set_combat(on)
        self.cl.eval("__MOCK.combat_names = {}; for _, n in ipairs({...}) do __MOCK.combat_names[n] = true end",
                     *(names if on else ()))

    def end_fight(self):
        self.combat(False)
        self.tick(3)

    def segs(self):
        return self.cl.eval("return #ns.Meter:Data().segs")

    def seg(self, expr="cur"):
        return self.cl.eval_py("return ns.Meter:GetSegment(...)", expr)

    def actor(self, name, sel="cur"):
        return self.cl.eval_py("local s = ns.Meter:GetSegment(...); return s and s.actors[select(2, ...)]",
                               sel, self.g[name])


def num(x):
    return x or 0


@case
def off_by_default_records_nothing():
    r = Raid(dmg=False)
    assert r.cl.eval("return ns.Meter:IsEnabled()") is False
    assert r.cl.eval("return ns.Threat:IsEnabled()") is False
    assert r.cl.eval("return ns.Meter._State().listening") is False
    r.hit("Gina", 1000)
    r.tick(1)
    assert r.segs() == 0
    assert not r.cl.eval("local f = _G.DisasterZoneMeter; return f and f:IsShown()")
    assert not r.cl.eval("local f = _G.DisasterZoneThreat; return f and f:IsShown()")


@case
def nothing_is_ever_sent():
    import harness
    for rel in FILES:
        src = open(os.path.join(harness.ADDON_DIR, *rel.split("/")), encoding="utf-8").read()
        for word in ("SendAddonMessage", "SendChatMessage", "ns.Comm", "Comm:", "Outbox", "C_ChatInfo"):
            assert word not in src, (rel, word)


@case
def damage_counts_like_my_log():
    r = Raid()
    r.combat(True, "Victhar", "Pugsy", "Hunt")
    r.hit("Gina", 1000)
    r.hit("Gina", 2000, crit=True)
    r.hit("Gina", 1500, absorbed=300)                        # the shield's part counts
    r.hit("Gina", 900, overkill=400, dst=r.add, dst_name="Crystalcore Devastator")   # overkill does not
    r.swing("Gina", 800, glancing=True)
    r.ev("SWING_MISSED", r.me, "Gina", ME_FLAGS, r.boss, "Void Reaver", BOSS_FLAGS, "DODGE", False, None)
    r.swing("Victhar", 600)
    # an outsider and a hit on the group never count as damage done
    r.ev("SPELL_DAMAGE", "Player-4000-0BEEF099", "Stranger", OUTSIDER, r.boss, "Void Reaver", BOSS_FLAGS,
         27209, "Shadow Bolt", 32, 9999, -1, 32, None, None, None, False, False, False)
    r.ev("SPELL_DAMAGE", r.me, "Gina", ME_FLAGS, r.me, "Gina", ME_FLAGS, 31893, "Seal of Blood", 1, 120, -1, 1,
         None, None, None, False, False, False)
    r.tick(1)
    a = r.actor("Gina")
    assert a["d"] == 1000 + 2000 + 1800 + 500 + 800, a["d"]
    cs = a["sp"][35395]
    assert cs["n"] == 4 and cs["c"] == 1 and cs["ca"] == 2000, cs        # the overkill hit on the add too
    melee = a["sp"][0]
    assert melee["n"] == 1 and melee["g"] == 1 and melee["m"]["DODGE"] == 1, melee
    assert a["tg"]["Crystalcore Devastator"] == 500
    assert a["t"] == 120                                     # Seal of Blood's self damage is taken, not done
    assert r.actor("Victhar")["d"] == 600
    stranger = r.cl.eval("for g, a in pairs(ns.Meter:GetSegment('cur').actors) do if a.n == 'Stranger' then return true end end return false")
    assert stranger is False
    rows = r.cl.eval_py("local rows = ns.Meter:Rows(ns.Meter:GetSegment('cur'), 'damage'); "
                        "local o = {}; for i, x in ipairs(rows) do o[i] = x.a.n end; return o")
    assert rows[:2] == ["Gina", "Victhar"], rows


@case
def pets_and_totems_count_for_their_owner():
    r = Raid()
    r.combat(True, "Hunt")
    pet = "Pet-0-4000-550-100-17252-0100AB0001"
    totem = "Creature-0-4000-550-100-15439-0000AB2222"
    r.ev("SPELL_SUMMON", r.g["Hunt"], "Hunt", RAID_FLAGS, pet, "Wolf", RAID_PET, 883, "Call Pet", 1)
    r.hit("Hunt", 500, spell=75)
    r.ev("SWING_DAMAGE", pet, "Wolf", RAID_PET, r.boss, "Void Reaver", BOSS_FLAGS,
         300, -1, 1, None, None, None, False, False, False, False)
    # a totem summoned by the pet's owner's pet chain still counts; an unknown pet does not
    r.ev("SPELL_SUMMON", pet, "Wolf", RAID_PET, totem, "Searing Totem", RAID_GUARD, 25533, "Searing Totem", 4)
    r.ev("SPELL_DAMAGE", totem, "Searing Totem", RAID_GUARD, r.boss, "Void Reaver", BOSS_FLAGS,
         25530, "Attack", 4, 100, -1, 4, None, None, None, False, False, False)
    r.ev("SWING_DAMAGE", "Pet-0-4000-550-100-1-0100AB9999", "Cat", RAID_PET, r.boss, "Void Reaver", BOSS_FLAGS,
         9999, -1, 1, None, None, None, False, False, False, False)
    r.tick(1)
    a = r.actor("Hunt")
    assert a["d"] == 900, a["d"]
    assert a["sp"]["p0"]["a"] == 300 and a["pn"]["p0"] == "Wolf"
    assert a["sp"]["p25530"]["a"] == 100


@case
def healing_overhealing_and_shields():
    r = Raid()
    r.combat(True, "Pugsy", "Victhar")
    r.hit("Gina", 100)                                       # starts the fight
    r.heal("Pugsy", "Victhar", 3000, over=1000)
    r.heal("Pugsy", "Victhar", 2000)
    # a shield absorbing a swing (caster at 12) and a spell (caster at 15)
    r.ev("SPELL_ABSORBED", r.boss, "Void Reaver", BOSS_FLAGS, r.g["Victhar"], "Victhar", RAID_FLAGS,
         r.g["Pugsy"], "Pugsy", RAID_FLAGS, 0, 25218, "Power Word: Shield", 2, 700)
    r.ev("SPELL_ABSORBED", r.boss, "Void Reaver", BOSS_FLAGS, r.g["Victhar"], "Victhar", RAID_FLAGS,
         34172, "Arcane Orb", 64, r.g["Pugsy"], "Pugsy", RAID_FLAGS, 0, 25218, "Power Word: Shield", 2, 500)
    r.tick(1)
    a = r.actor("Pugsy")
    assert a["h"] == 2000 + 2000 + 1200, a["h"]
    assert a["oh"] == 1000
    assert a["hs"][25213]["a"] == 4000 and a["hs"][25213]["oh"] == 1000
    assert a["hs"][25218]["sh"] is True and a["hs"][25218]["a"] == 1200
    rows = r.cl.eval_py("local rows = ns.Meter:Rows(ns.Meter:GetSegment('cur'), 'healing'); return { rows[1].a.n, rows[1].ext }")
    assert rows == ["Pugsy", 1000], rows


@case
def damage_taken_with_shields_and_falls():
    r = Raid()
    r.combat(True, "Victhar")
    r.ev("SWING_DAMAGE", r.boss, "Void Reaver", BOSS_FLAGS, r.g["Victhar"], "Victhar", RAID_FLAGS,
         4000, -1, 1, None, None, 500, False, False, False, False)
    r.ev("SWING_MISSED", r.boss, "Void Reaver", BOSS_FLAGS, r.g["Victhar"], "Victhar", RAID_FLAGS, "ABSORB", False, 3000)
    r.ev("ENVIRONMENTAL_DAMAGE", "", "", 0, r.g["Victhar"], "Victhar", RAID_FLAGS, "FALLING", 800, -1, 1, None, None, None)
    r.tick(1)
    a = r.actor("Victhar")
    assert a["t"] == 4500 + 3000 + 800, a["t"]
    assert a["ts"]["mVoid Reaver"]["a"] == 7500 and a["ts"]["eFALLING"]["a"] == 800


@case
def a_fight_starts_on_the_first_hit_and_ends_out_of_combat():
    r = Raid()
    r.heal("Pugsy", "Victhar", 500)                          # healing alone starts nothing
    assert r.segs() == 0
    r.combat(True, "Victhar")                                # (entering combat starts one: dropped if nobody hits)
    r.hit("Gina", 700, dst=r.add, dst_name="Crystalcore Devastator")
    r.hit("Victhar", 300, dst="Creature-0-4000-550-100-20041-0000000001", dst_name="Tempest-Smith")
    assert r.cl.eval("return ns.Meter:IsRecording()") is True
    r.tick(5)
    assert r.cl.eval("return ns.Meter:IsRecording()") is True    # the group is still fighting
    r.end_fight()
    assert r.cl.eval("return ns.Meter:IsRecording()") is False
    s = r.seg()
    assert s["kind"] == "trash" and not s.get("live") and s["dur"] >= 5, s
    assert r.cl.eval("return ns.Meter:SegName(ns.Meter:GetSegment('cur'))") == "Crystalcore Devastator +1"


@case
def boss_fights_take_over_the_pull_and_note_kill_or_wipe():
    r = Raid()
    r.combat(True, "Victhar")
    r.hit("Victhar", 500)                                    # the pull: a trash fight for a moment
    r.tick(1)
    r.cl.fire("ENCOUNTER_START", 731, "Void Reaver", 4, 25)
    r.hit("Gina", 1000)
    r.tick(2)
    assert r.segs() == 1
    s = r.seg()
    assert s["kind"] == "boss" and s["name"] == "Void Reaver" and s["live"] is True
    r.cl.fire("ENCOUNTER_END", 731, "Void Reaver", 4, 25, 1)
    s = r.seg()
    assert s["kill"] is True and not s.get("live")
    assert r.actor("Victhar")["d"] == 500 and r.actor("Gina")["d"] == 1000
    # a wipe keeps the boss's health
    r.tick(5)
    r.cl.fire("ENCOUNTER_START", 731, "Void Reaver", 4, 25)
    r.hit("Gina", 1000)
    r.cl.eval("__MOCK.target_npc = nil")
    r.cl.fire("ENCOUNTER_END", 731, "Void Reaver", 4, 25, 0)
    s = r.seg()
    assert s["kill"] is False and r.segs() == 2


@case
def trash_adds_up_between_bosses_when_asked():
    r = Raid()
    r.cl.eval("ns.DB:SetSetting('meters.split', 'boss')")
    for _ in range(2):
        r.combat(True, "Victhar")
        r.hit("Gina", 1000, dst=r.add, dst_name="Crystalcore Devastator")
        r.tick(3)
        r.end_fight()
    assert r.segs() == 1
    assert r.actor("Gina")["d"] == 2000
    r.cl.fire("ENCOUNTER_START", 731, "Void Reaver", 4, 25)
    r.hit("Gina", 1000)
    r.cl.fire("ENCOUNTER_END", 731, "Void Reaver", 4, 25, 1)
    r.tick(5)
    r.combat(True, "Victhar")
    r.hit("Gina", 1000, dst=r.add, dst_name="Crystalcore Devastator")
    r.end_fight()
    assert r.segs() == 3                                     # trash, the boss, then new trash


@case
def whole_raid_adds_every_fight_and_starts_over_in_a_new_instance():
    r = Raid()
    for amount in (1000, 2500):
        r.combat(True, "Victhar")
        r.hit("Gina", amount, dst=r.add, dst_name="Crystalcore Devastator")
        r.tick(4)
        r.end_fight()
    a = r.actor("Gina", "all")
    assert a["d"] == 3500
    all_ = r.seg("all")
    assert all_["kind"] == "all" and all_["dur"] >= 8
    assert r.cl.eval("return ns.Meter:SegName(ns.Meter:GetSegment('all'))") == "Whole raid"
    r.w.enter_instance("Serpentshrine Cavern", 548, "raid", 25, difficulty_id=4)
    r.tick(1)
    r.combat(True, "Victhar")
    r.hit("Gina", 400, dst=r.add, dst_name="Coilfang Guardian")
    r.end_fight()
    assert r.actor("Gina", "all")["d"] == 400


@case
def deaths_keep_the_last_ten_seconds():
    r = Raid()
    r.combat(True, "Victhar", "Pugsy")
    r.hit("Gina", 100)
    r.boss_hits("Victhar", 1000)                             # too old for the recap
    r.tick(12)
    r.boss_hits("Victhar", 2000)
    r.tick(1)
    r.heal("Pugsy", "Victhar", 1500, over=200)
    r.tick(1)
    r.boss_hits("Victhar", 3000, overkill=700)
    r.ev("UNIT_DIED", "", "", 0, r.g["Victhar"], "Victhar", RAID_FLAGS)
    r.tick(1)
    d = r.cl.eval_py("return ns.Meter:GetSegment('cur').deaths[1]")
    assert d["n"] == "Victhar" and d["by"] == 34172, d
    ev = d["ev"]
    assert [e[1] for e in ev] == ["d", "h", "d"], ev
    assert ev[-1][6] == 700 and ev[1][3] == 1300 and ev[1][6] == 200, ev       # heals: effective + overheal
    assert ev[0][0] < ev[1][0] < ev[2][0] <= 0
    assert r.cl.eval("return ns.Meter:IsDead(ns.Meter:GetSegment('cur'), ...)", r.g["Victhar"]) is True
    # my own feign death is not a death
    r.cl.eval("__MOCK.feigning = true")
    r.ev("UNIT_DIED", "", "", 0, r.me, "Gina", ME_FLAGS)
    r.cl.eval("__MOCK.feigning = false")
    assert r.cl.eval("return #ns.Meter:GetSegment('cur').deaths") == 1
    rows = r.cl.eval_py("local rows = ns.Meter:Rows(ns.Meter:GetSegment('cur'), 'deaths'); return { #rows, rows[1].a.n }")
    assert rows == [1, "Victhar"]


@case
def interrupts_and_dispels():
    r = Raid()
    r.combat(True, "Victhar")
    r.hit("Gina", 100)
    r.ev("SPELL_INTERRUPT", r.g["Victhar"], "Victhar", RAID_FLAGS, r.add, "Astromancer", BOSS_FLAGS,
         6554, "Pummel", 1, 37135, "Domination", 32)
    r.ev("SPELL_DISPEL", r.g["Pugsy"], "Pugsy", RAID_FLAGS, r.g["Victhar"], "Victhar", RAID_FLAGS,
         988, "Dispel Magic", 2, 37135, "Domination", 32, "DEBUFF")
    r.tick(1)
    v, p = r.actor("Victhar"), r.actor("Pugsy")
    assert v["k"] == 1 and v["ks"][6554] == 1 and v["kx"][37135] == 1
    assert p["dp"] == 1 and p["ds"][988] == 1


@case
def spec_comes_from_signature_spells():
    r = Raid()
    r.combat(True, "Victhar")
    r.hit("Victhar", 900, spell=23922)                       # Shield Slam: Protection
    r.tick(1)
    assert r.actor("Victhar")["s"] == "Protection"
    assert r.cl.eval("return ns.Meter:SpecOf('Victhar')") == "Protection"


@case
def old_fights_drop_off_past_keep():
    r = Raid()
    r.cl.eval("ns.DB:SetSetting('meters.keep', 10)")
    for i in range(12):
        r.combat(True, "Victhar")
        r.hit("Gina", 100 + i, dst=r.add, dst_name="Crystalcore Devastator")
        r.end_fight()
    assert r.segs() == 10
    assert r.actor("Gina")["d"] == 111


@case
def a_reload_mid_fight_is_kept_as_cut_short():
    r = Raid()
    r.combat(True, "Victhar")
    r.hit("Gina", 1000)
    r.tick(4)
    r.cl.relog()
    r.w.tick(3)
    s = r.cl.eval_py("local d = DisasterZoneMeterDB; return d.segs[#d.segs]")
    assert s["cut"] is True and not s.get("live") and s["dur"] >= 3, s


@case
def the_window_shows_bars_in_order_and_keeps_mine_in_view():
    extra = [ExtraMember("P%02d" % i, "ROGUE") for i in range(14)]
    r = Raid(extra=extra)
    r.combat(True)
    r.hit("Gina", 50)
    for i, m in enumerate(extra):
        r.hit(m.name, 1000 + i * 10)
    r.tick(1)
    assert r.cl.eval("return _G.DisasterZoneMeter:IsShown()") is True
    info = r.cl.eval_py("""
        local rows = ns.MeterWindow._Rows()
        local me = rows[UnitGUID('player')]
        local top = rows[select(1, ...)]
        return { me.rank:GetText(), me.pinLine:IsShown(), me.you:IsShown(), me.ty, top.ty, top.rank:GetText() }
    """, r.g["P13"])
    rank, pinned, you, my_y, top_y, top_rank = info
    assert rank == "15" and pinned is True and you is True, info
    assert top_y == 0 and top_rank == "1", info
    assert my_y < 0 and my_y > -10 * 22, info               # inside the window, on its last row
    assert r.cl.eval("return _G.DisasterZoneMeter.totValue:GetText()") != "0"


@case
def menus_switch_the_mode_and_the_fight():
    r = Raid()
    r.combat(True, "Victhar")
    r.hit("Gina", 500)
    r.end_fight()
    r.combat(True, "Victhar")
    r.hit("Victhar", 700)
    r.tick(1)
    r.cl.click(r.cl.eval("return _G.DisasterZoneMeter.head.mode"))
    menu = r.cl.last_menu()
    labels = [c["text"] for c in menu["children"] if c["kind"] == "radio"]
    assert len(labels) == 8, labels
    dps = [t for t in labels if t.endswith("DPS")][0]
    r.cl.menu_select(dps)
    assert r.cl.eval("return ns.DB:GetSetting('meters.mode')") == "dps"
    r.cl.click(r.cl.eval("return _G.DisasterZoneMeter.head.seg"))
    menu = r.cl.last_menu()
    fights = [c for c in menu["children"] if c["kind"] == "radio"]
    assert len(fights) == 3, [c["text"] for c in fights]    # current, the earlier fight, Whole raid
    r.cl.menu_select(fights[1]["text"])
    sel = r.cl.eval("return ns.DB:GetSetting('meters.seg')")
    assert isinstance(sel, (int, float)), sel
    r.cl.eval("ns.MeterWindow:Draw()")
    assert r.cl.eval("return _G.DisasterZoneMeter.head.segText:GetText()") == "Void Reaver"


@case
def a_click_opens_the_breakdown_and_the_recap():
    r = Raid()
    r.combat(True, "Victhar", "Pugsy")
    r.hit("Gina", 1000)
    r.hit("Gina", 400, spell=20424)
    r.boss_hits("Victhar", 3000)
    r.ev("UNIT_DIED", "", "", 0, r.g["Victhar"], "Victhar", RAID_FLAGS)
    r.tick(1)
    r.cl.eval("ns.MeterWindow:Draw()")
    r.cl.click(r.cl.eval("return ns.MeterWindow._Rows()[UnitGUID('player')]"))
    assert r.cl.eval("return _G.DisasterZoneMeterDetail:IsShown()") is True
    assert r.cl.eval("return _G.DisasterZoneMeterDetail.banner.name:GetText()") == "Gina"
    assert r.cl.eval("return _G.DisasterZoneMeterDetail.cards[1].num:GetText()") == "1,400"
    n = r.cl.eval("local n = 0; for _, x in ipairs(_G.DisasterZoneMeterDetail.rows) do if x:IsShown() then n = n + 1 end end; return n")
    assert n == 2
    r.cl.eval("_G.DisasterZoneMeterDetail:Hide(); ns.DB:SetSetting('meters.mode', 'deaths'); ns.MeterWindow:Draw()")
    row = r.cl.eval("for k, row in pairs(ns.MeterWindow._Rows()) do if row:IsShown() then return row end end")
    r.cl.click(row)
    assert r.cl.eval("return ns.MeterDetail:GetState().view") == "death"
    assert r.cl.eval("return _G.DisasterZoneMeterDetail.banner.name:GetText()") == "Victhar"
    assert r.cl.eval("return _G.DisasterZoneMeterDetail.evRows[1]:IsShown()") is True


def threat(r, table):
    r.cl.eval("__MOCK.threat = {}")
    for name, t in table.items():
        r.cl.eval("local n, a, b, c, d, e = ...; __MOCK.threat[n] = { a, b, c, d, e }", name, *t)
    r.cl.eval("ns.Threat._Poll()")
    return r.cl.eval_py("local s = ns.Threat:GetState(); local o = { pull = s.pull, hot = s.hot, tv = s.tankView, "
                        "names = {} }; for i, x in ipairs(s.view or {}) do o.names[i] = x.name end; return o")


@case
def the_threat_table_reads_the_game():
    r = Raid(dmg=False, thr=True)
    r.combat(True, "Victhar")
    assert r.cl.eval("return ns.Threat:Mob()") is None
    r.cl.target_npc(r.boss)
    assert r.cl.eval("return ns.Threat:Mob()") == "target"
    s = threat(r, {"Victhar": (True, 3, 100, 100, 200000), "Gina": (False, 1, 62, 68, 136000),
                   "Hunt": (False, 0, 40, 52, 104000)})
    assert s["names"] == ["Victhar", "Gina", "Hunt"] and s["pull"] == 110 and not s["hot"], s
    sounds = r.cl.eval("return #__MOCK.sounds")
    s = threat(r, {"Victhar": (True, 3, 100, 100, 200000), "Gina": (False, 2, 88, 96.8, 193600)})
    assert s["hot"] is True
    threat(r, {"Victhar": (True, 3, 100, 100, 200000), "Gina": (False, 2, 90, 99, 198000)})
    assert r.cl.eval("return #__MOCK.sounds") == sounds + 1          # one sound per crossing
    # while I tank: the others by their own pull point
    s = threat(r, {"Gina": (True, 3, 100, 100, 200000), "Victhar": (False, 1, 70, 77, 154000),
                   "Hunt": (False, 1, 80, 104, 208000)})
    assert s["tv"] is True and s["names"] == ["Hunt", "Victhar"], s
    assert r.cl.eval("return _G.DisasterZoneThreat:IsShown()") is True


@case
def the_settings_section_dims_what_is_off():
    r = Raid(dmg=False)
    r.cl.eval("ns.MainFrame:Open('settings'); ns.SettingsUI:SelectSection('meters')")
    r.w.tick(0.5)
    assert r.cl.eval("return ns.SettingsUI.sections.meters:IsShown()") is True
    texts = r.cl.find_text("Show the damage meter")
    assert texts, "no damage meter switch"
    a = r.cl.eval("for _, row in ipairs(ns.SettingsUI.sections.meters.rows) do if row.title:GetText() == 'Fights to keep' then return row:GetAlpha() end end")
    assert a < 0.5, a
    r.cl.eval("ns.DB:SetSetting('meters.dmg', true); ns.SettingsUI:Refresh()")
    a = r.cl.eval("for _, row in ipairs(ns.SettingsUI.sections.meters.rows) do if row.title:GetText() == 'Fights to keep' then return row:GetAlpha() end end")
    assert a == 1, a


@case
def demo_mode_fills_both_windows():
    r = Raid(dmg=False, instance=False)
    r.cl.eval("ns.Demo:SetEnabled(true)")
    r.w.tick(1)
    assert r.cl.eval("return #ns.Meter:Data().segs") == 6
    assert r.cl.eval("return ns.Meter:SegName(ns.Meter:GetSegment('cur'))") == "Void Reaver"
    assert r.cl.eval("return _G.DisasterZoneMeter and _G.DisasterZoneMeter:IsShown()") is True
    assert r.cl.eval("return _G.DisasterZoneThreat and _G.DisasterZoneThreat:IsShown()") is True
    assert r.cl.eval("return ns.Threat:GetState().pull") == 110
    gina = r.cl.eval_py("for g, a in pairs(ns.Meter:GetSegment('cur').actors) do if a.n == 'Gina' then return a end end")
    assert gina["d"] == 1190 * 222
    assert r.cl.eval("return #ns.Meter:GetSegment('cur').deaths") == 2


if __name__ == "__main__":
    run_all()
