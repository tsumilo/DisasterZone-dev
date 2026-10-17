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

FILES = ["Core/Meter.lua", "Core/Threat.lua", "Core/MeterDemo.lua", "UI/MeterWindow.lua", "UI/MeterPanels.lua",
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
    assert not r.cl.eval("local f = _G.DisasterZoneMeters; return f and f:IsShown()")


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
    r.hit("Gina", 900, overkill=400, dst=r.add, dst_name="Crystalcore Devastator")   # overkill counts (Details)
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
    assert a["d"] == 1000 + 2000 + 1800 + 900 + 800, a["d"]
    cs = a["sp"][35395]
    assert cs["n"] == 4 and cs["c"] == 1 and cs["ca"] == 2000, cs        # the overkill hit on the add too
    melee = a["sp"][0]
    assert melee["n"] == 1 and melee["g"] == 1 and melee["m"]["DODGE"] == 1, melee
    assert a["tg"]["Crystalcore Devastator"] == 900
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
    assert r.cl.eval("return ns.Meter:IsRecording()") is True
    r.tick(5)
    r.hit("Victhar", 300, dst="Creature-0-4000-550-100-20041-0000000001", dst_name="Tempest-Smith")
    assert r.cl.eval("return ns.Meter:IsRecording()") is True    # the group is still fighting
    r.end_fight()
    assert r.cl.eval("return ns.Meter:IsRecording()") is False
    s = r.seg()
    assert s["kind"] == "trash" and not s.get("live") and 4.9 <= s["dur"] <= 5.3, s   # first hit to last hit
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
def a_dot_tick_after_the_boss_keeps_the_boss_fight_shown():
    # feedback #34 (2026-10-16, SSC): after a kill, every lingering tick on a player started a trash fight that showed
    # and was dropped two seconds later: the panels flipped trash / last fight / trash
    r = Raid()
    r.combat(True, "Victhar")
    r.cl.fire("ENCOUNTER_START", 731, "Void Reaver", 4, 25)
    r.hit("Gina", 1000)
    r.cl.fire("ENCOUNTER_END", 731, "Void Reaver", 4, 25, 1)
    boss_id = r.seg()["id"]
    for _ in range(3):
        r.boss_hits("Victhar", 300)                          # the boss's DoT ticks on after the kill
        assert r.cl.eval("return ns.Meter:IsRecording()") is True
        assert r.seg()["id"] == boss_id                      # the panels keep the boss
        assert r.cl.eval("return ns.Meter:GetFights()[1].id") == boss_id
        r.end_fight()
        assert r.seg()["id"] == boss_id and r.segs() == 1     # dropped: nobody hit anything
        r.combat(True, "Victhar")
    # real trash: shown as soon as someone hits it
    r.hit("Gina", 700, dst=r.add, dst_name="Crystalcore Devastator")
    assert r.seg()["kind"] == "trash" and r.seg()["id"] != boss_id
    r.w.assert_no_errors()


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
        r.hit("Gina", 0, dst=r.add, dst_name="Crystalcore Devastator")
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
def the_panel_shows_bars_in_order_and_keeps_mine_in_view():
    extra = [ExtraMember("P%02d" % i, "ROGUE") for i in range(14)]
    r = Raid(extra=extra)
    r.combat(True)
    r.hit("Gina", 50)
    for i, m in enumerate(extra):
        r.hit(m.name, 1000 + i * 10)
    r.tick(1)
    assert r.cl.eval("return _G.DisasterZoneMeters:IsShown()") is True
    info = r.cl.eval_py("""
        ns.MeterPanels:Draw()
        local pf = ns.MeterPanels._Panel('damage')
        local me = pf.rowsByKey[UnitGUID('player')]
        local top = pf.rowsByKey[select(1, ...)]
        local n = 0; for _ in pairs(pf.rowsByKey) do n = n + 1 end
        return { me.name:GetText(), me.pinLine:IsShown(), me.you:IsShown(), me.ty, top.ty, top.name:GetText(), n,
                 pf:GetHeight(), pf.totV:GetText() }
    """, r.g["P13"])
    rank, pinned, you, my_y, top_y, top_rank, n, h, tot = info
    assert rank.startswith("Gina") and rank.endswith("15th|r") and pinned is True and you is True, info   # no list numbers;
    assert top_y == 0 and top_rank == "P13", info                                                       # my place named
    assert n == 8 and my_y == -7 * 20, info                 # 8 rows by default, mine on the last
    assert h == 24 + 18 + 3 * 2 + 8 * 19 + 7, info           # header, fight line, then as tall as its rows
    assert tot and tot != "", info


@case
def an_empty_panel_is_just_its_header():
    r = Raid(thr=True)
    r.tick(1)
    info = r.cl.eval_py("""
        ns.MeterPanels:Draw()
        local t, d = ns.MeterPanels._Panel('threat'), ns.MeterPanels._Panel('damage')
        return { t:GetHeight(), t.note.text:GetText(), d:GetHeight(), d.note.text:GetText(), t.pi, d.pi }
    """)
    assert info[0] == 24 and info[1] == "no target", info
    assert info[2] == 24 and info[3] == "no fights yet", info
    assert info[4] == 1 and info[5] == 2, info                # one stack: Threat over Damage done


@case
def the_view_menu_switches_the_mode_and_the_fight():
    r = Raid()
    r.combat(True, "Victhar")
    r.hit("Gina", 500)
    r.end_fight()
    r.combat(True, "Victhar")
    r.hit("Victhar", 700)
    r.tick(1)
    r.cl.click(r.cl.eval("return ns.MeterPanels._Panel('damage').mode"))
    menu = r.cl.last_menu()
    labels = [c["text"] for c in menu["children"] if c["kind"] == "radio"]
    assert len(labels) == 9 and labels[-1].endswith("Threat"), labels
    assert any(c.get("text") == "Fight" for c in menu["children"])
    r.cl.menu_select([t for t in labels if t.endswith("DPS")][0])
    assert r.cl.eval("return ns.MeterPanels.Layout().stacks[1].panels[1].tabs[1].view") == "dps"
    r.cl.eval("local pf = ns.MeterPanels._Panel('dps'); ns.MeterPanels:FightMenu(pf, pf.fl.lab)")
    keys = r.cl.eval_py(LIST_KEYS)
    assert len(keys) == 3, keys                               # Whole raid, then both fights
    r.cl.eval(PICK_OLDER)
    r.cl.eval("ns.MeterPanels:Draw()")
    name = r.cl.eval("return ns.MeterPanels._Panel('dps').fl.name:GetText()")
    assert name.startswith("Void Reaver"), name               # an older fight is named in the fight line
    # a new fight brings the panel back to it
    r.end_fight()
    r.combat(True, "Victhar")
    r.hit("Victhar", 100, dst=r.add, dst_name="Crystalcore Devastator")
    assert r.cl.eval("return ns.MeterPanels.Layout().stacks[1].panels[1].tabs[1].seg") == "cur"


@case
def a_click_opens_the_breakdown_and_the_recap():
    r = Raid()
    r.combat(True, "Victhar", "Pugsy")
    r.hit("Gina", 1000)
    r.hit("Gina", 400, spell=20424)
    r.boss_hits("Victhar", 3000)
    r.ev("UNIT_DIED", "", "", 0, r.g["Victhar"], "Victhar", RAID_FLAGS)
    r.tick(1)
    r.cl.eval("ns.MeterPanels:Draw()")
    r.cl.click(r.cl.eval("return ns.MeterPanels._Panel('damage').rowsByKey[UnitGUID('player')]"))
    assert r.cl.eval("return _G.DisasterZoneMeterDetail:IsShown()") is True
    assert r.cl.eval("return _G.DisasterZoneMeterDetail.banner.name:GetText()") == "Gina"
    assert r.cl.eval("return _G.DisasterZoneMeterDetail.cards[1].num:GetText()") == "1,400"
    # the window (and what is drawn in it) sits above the HIGH main window, as in 1.3.5
    assert r.cl.eval("return _G.DisasterZoneMeterDetail:GetFrameStrata()") == "DIALOG"
    assert r.cl.eval("return _G.DisasterZoneMeterDetail.rows[1]:GetFrameStrata()") == "DIALOG"
    n = r.cl.eval("local n = 0; for _, x in ipairs(_G.DisasterZoneMeterDetail.rows) do if x:IsShown() then n = n + 1 end end; return n")
    assert n == 2
    r.cl.eval("_G.DisasterZoneMeterDetail:Hide(); ns.MeterPanels.Layout().stacks[1].panels[1].tabs[1].view = 'deaths'; ns.MeterPanels:Draw()")
    row = r.cl.eval("for k, row in pairs(ns.MeterPanels._Panel('deaths').rowsByKey) do if row:IsShown() then return row end end")
    r.cl.click(row)
    assert r.cl.eval("return ns.MeterDetail:GetState().view") == "death"
    assert r.cl.eval("return _G.DisasterZoneMeterDetail.banner.name:GetText()") == "Victhar"
    assert r.cl.eval("return _G.DisasterZoneMeterDetail.evRows[1]:IsShown()") is True


# the fight list's clickable things, top to bottom: "row:<key>" (whole raid, bosses) and "dot:<key>" (trash pulls)
LIST_KEYS = """
    local f = ns.MeterPanels._FightList()
    local o = {}
    for _, row in ipairs(f.rows) do
        if row:IsShown() then
            if row.sel_key then o[#o + 1] = "row:" .. tostring(row.sel_key) end
            for _, d in ipairs(row.dots) do if d:IsShown() then o[#o + 1] = "dot:" .. tostring(d.sel_key) end end
        end
    end
    return o"""
# clicks the first fight in the list that is neither the current one nor the whole raid
PICK_OLDER = """
    local f = ns.MeterPanels._FightList()
    for _, row in ipairs(f.rows) do
        if row:IsShown() then
            if row.sel_key and row.sel_key ~= "cur" and row.sel_key ~= "all" then row:Click() return end
            for _, d in ipairs(row.dots) do if d:IsShown() and d.sel_key ~= "cur" then d:Click() return end end
        end
    end"""


def layout(r):
    return r.cl.eval_py("""
        local out = {}
        for i, s in ipairs(ns.MeterPanels.Layout().stacks) do
            local ps = {}
            for j, p in ipairs(s.panels) do
                local ts = {}
                for k, t in ipairs(p.tabs) do ts[k] = t.view end
                ps[j] = table.concat(ts, "+")
            end
            out[i] = table.concat(ps, "/")
        end
        return out""")


@case
def panels_spawn_dock_tab_detach_and_close():
    r = Raid(thr=True)
    r.cl.eval("ns.EditMode:Open()")
    r.tick(0.5)
    assert layout(r) == ["threat/damage"]
    # + : a panel of its own beside the stack
    r.cl.eval("ns.MeterPanels:Spawn(ns.MeterPanels._Panel('damage'), 'healing')")
    assert layout(r) == ["threat/damage", "healing"]
    # dropped at the first stack's bottom edge: it joins the stack (MeterPanels.FindTarget decides; see below)
    r.cl.eval("""
        local MP = ns.MeterPanels
        __MOCK.mouse_down = true
        MP:StartDrag(2)
        MP._SetTarget({ kind = "below", stack = MP.Layout().stacks[1] })
        __MOCK.mouse_down = false
        MP:EndDrag()
    """)
    assert layout(r) == ["threat/damage/healing"]
    # a lower header dragged out: a stack of its own again
    r.cl.eval("__MOCK.mouse_down = true; ns.MeterPanels:Detach(1, 3)")
    assert layout(r) == ["threat/damage", "healing"]
    # dropped on Damage done's header: a tab there
    r.cl.eval("""
        local MP = ns.MeterPanels
        MP._SetTarget({ kind = "tab", stack = MP.Layout().stacks[1], panel = MP.Layout().stacks[1].panels[2] })
        __MOCK.mouse_down = false
        MP:EndDrag()
    """)
    assert layout(r) == ["threat/damage+healing"]
    tabs = r.cl.eval_py("local pf = ns.MeterPanels._Panel('healing'); return { pf.tabs[1]:IsShown(), pf.tabs[2]:IsShown(), pf.mode:IsShown() }")
    assert tabs == [True, True, False], tabs
    # a tab dragged out
    r.cl.eval("__MOCK.mouse_down = true; ns.MeterPanels:Detach(1, 2, 1); __MOCK.mouse_down = false; ns.MeterPanels:EndDrag()")
    assert layout(r) == ["threat/healing", "damage"]
    # x closes a panel; the last one of a stack takes the stack with it
    r.cl.eval("ns.MeterPanels:Close(ns.MeterPanels._Panel('damage'))")
    assert layout(r) == ["threat/healing"]


@case
def where_a_dragged_stack_goes():
    """MeterPanels.FindTarget: over a header = a tab; at a stack's bottom / top edge = into the stack; beside it = lined
    up; elsewhere nothing. (Frame units: y grows upward, t = top.)"""
    r = Raid()
    res = r.cl.eval_py("""
        local F = ns.MeterPanels.FindTarget
        local A = { name = "A" }
        local others = { { A, 100, 500, 300, 120, heads = { { "pA1", 100, 500, 400, 476 }, { "pA2", 100, 440, 400, 416 } } } }
        local function k(m, cx, cy)
            local t = F(m, cx, cy, others)
            if t and t.stack ~= A then return "no stack" end
            return t and (t.kind .. (t.panel and (":" .. t.panel) or "")) or "none"
        end
        return {
            k({ 600, 300, 200, 80 }, 150, 430),     -- cursor over A's second header
            k({ 110, 372, 300, 80 }, 900, 900),     -- top 8 px under A's bottom (380)
            k({ 90, 592, 300, 80 }, 900, 900),      -- bottom 8 px over A's top
            k({ 410, 505, 200, 80 }, 900, 900),     -- beside A's right edge
            k({ -95, 495, 200, 80 }, 900, 900),     -- beside A's left edge
            k({ 900, 100, 200, 80 }, 900, 900),     -- far away
        }""")
    assert res == ["tab:pA2", "below", "above", "right", "left", "none"], res


@case
def a_meter_turned_off_hides_its_panels_and_brings_them_back():
    r = Raid(thr=True)
    r.tick(0.5)
    assert r.cl.eval("return ns.MeterPanels._Panel('threat') ~= nil") is True
    r.cl.eval("ns.DB:SetSetting('meters.thr', false)")
    r.tick(0.5)
    assert r.cl.eval("return ns.MeterPanels._Panel('threat') == nil") is True
    assert layout(r) == ["threat/damage"]                     # kept for later
    r.cl.eval("ns.DB:SetSetting('meters.thr', true)")
    r.tick(0.5)
    assert r.cl.eval("return ns.MeterPanels._Panel('threat') ~= nil") is True
    # the last one closed: turning it off and on gives it a panel again
    r.cl.eval("ns.MeterPanels:Close(ns.MeterPanels._Panel('threat')); ns.DB:SetSetting('meters.thr', false); ns.DB:SetSetting('meters.thr', true)")
    assert layout(r) == ["threat/damage"]


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
    assert r.cl.eval("return _G.DisasterZoneMeters:IsShown() and ns.MeterPanels._Panel('threat') ~= nil") is True
    # someone else holding aggro while I'm in tank view: on top, the 100% the rest are measured against, not red
    # (in-game report 2026-10-11: it was last, found only by scrolling)
    r.cl.eval("ns.DB:SetSetting('meters.tankView', 'always')")
    s = threat(r, {"Victhar": (True, 3, 100, 100, 200000), "Gina": (False, 2, 60, 66, 132000),
                   "Hunt": (False, 1, 80, 104, 208000)})
    assert s["tv"] is True and s["names"] == ["Victhar", "Hunt"], s
    r.cl.eval("ns.MeterPanels:Draw()")
    top = r.cl.eval_py("""
        local pf = ns.MeterPanels._Panel('threat')
        for _, row in pairs(pf.trowsByKey) do
            if row.name:GetText() == 'Victhar' then local cr, cg, cb = row.fill:GetVertexColor(); return { row.ty, cr, cg } end
        end""")
    assert top[0] == 0 and not (top[1] == 1 and abs(top[2] - 0.35) < 0.01), top


@case
def threat_polls_that_change_nothing_redraw_nothing():
    """Performance page 2026-10-11: the threat poll (5 a second, always on) marked every meter panel for a redraw each
    time, ~5 MB of garbage a minute standing around. Now only a scan that would draw differently tells the panels."""
    r = Raid(dmg=False, thr=True)
    r.cl.eval("__TCH = 0; ns.Threat:OnChange(function() __TCH = __TCH + 1 end)")
    n = lambda: r.cl.eval("return __TCH")
    r.cl.eval("ns.Threat._Poll()")
    base = n()
    for _ in range(5):
        r.cl.eval("ns.Threat._Poll()")
    assert n() == base, (n(), base)                                   # nothing to follow: quiet
    r.combat(True, "Victhar")
    r.cl.target_npc(r.boss)
    table = {"Victhar": (True, 3, 100, 100, 200000), "Gina": (False, 1, 62, 68, 136000)}
    s = threat(r, table)
    assert n() == base + 1 and s["names"] == ["Victhar", "Gina"], (n(), s)
    threat(r, table)
    threat(r, table)
    assert n() == base + 1                                            # the same numbers: no redraw
    s = threat(r, {"Victhar": (True, 3, 100, 100, 200000), "Gina": (False, 1, 63, 69, 138000)})
    assert n() == base + 2                                            # a number moved
    r.cl.eval("ns.DB:SetSetting('meters.warn', 60)")
    r.cl.eval("ns.Threat._Poll()")
    assert n() == base + 3 and r.cl.eval("return ns.Threat:GetState().hot") is True   # the warning line moved
    r.cl.eval("__MOCK.threat = {}")
    r.cl.eval("ns.Threat._Poll()")
    assert n() == base + 4 and r.cl.eval("return #ns.Threat:GetState().rows") == 0     # the rows went
    # tank view flips with no enemy around: the next poll still notices
    r.cl.eval("ns.Threat.Mob = function() return nil end; ns.Threat._Poll()")
    k = n()
    r.cl.eval("ns.DB:SetSetting('meters.tankView', 'always'); ns.Threat._Poll()")
    assert n() == k + 1 and r.cl.eval("return ns.Threat:GetState().tankView") is True
    r.cl.eval("ns.Threat._Poll(); ns.Threat._Poll()")
    assert n() == k + 1


@case
def the_settings_page_hides_what_is_off():
    """Settings > Combat > Meters: a meter's options are hidden (not greyed) while it is off; the rest of them sit
    under More options."""
    r = Raid(dmg=False)
    r.cl.eval("ns.MainFrame:Open('settings'); ns.SettingsUI:SelectSection('meters'); "
              "ns.SettingsUI:SetMoreOpen(ns.SettingsUI.sections.meters, true)")
    r.w.tick(0.5)
    assert r.cl.eval("return ns.SettingsUI.sections.meters:IsShown()") is True
    texts = r.cl.find_text("Show the damage meter")
    assert texts, "no damage meter switch"
    SHOWN = ("for _, row in ipairs(ns.SettingsUI.sections.meters.rows) do if row.title:GetText() == 'Fights to keep' "
             "then return row:IsShown() and row:GetAlpha() end end")
    assert r.cl.eval(SHOWN) is False
    r.cl.eval("ns.DB:SetSetting('meters.dmg', true); ns.SettingsUI:Refresh()")
    assert r.cl.eval(SHOWN) == 1


@case
def demo_mode_fills_both_windows():
    r = Raid(dmg=False, instance=False)
    r.cl.eval("ns.Demo:SetEnabled(true)")
    r.w.tick(1)
    assert not r.cl.eval("local f = _G.DisasterZoneMeters; return f and f:IsShown()")   # only fills panels that are on
    r.cl.eval("ns.DB:SetSetting('meters.dmg', true); ns.DB:SetSetting('meters.thr', true)")
    r.w.tick(1)
    assert r.cl.eval("return #ns.Meter:Data().segs") == 6
    assert r.cl.eval("return ns.Meter:SegName(ns.Meter:GetSegment('cur'))") == "Void Reaver"
    assert r.cl.eval("return _G.DisasterZoneMeters:IsShown()") is True
    assert r.cl.eval("return ns.MeterPanels._Panel('damage') ~= nil and ns.MeterPanels._Panel('threat') ~= nil") is True
    assert r.cl.eval("return ns.Threat:GetState().pull") == 110
    gina = r.cl.eval_py("for g, a in pairs(ns.Meter:GetSegment('cur').actors) do if a.n == 'Gina' then return a end end")
    assert gina["d"] == 1190 * 222
    assert r.cl.eval("return #ns.Meter:GetSegment('cur').deaths") == 2


@case
def numbers_match_details_on_a_short_fight():
    """The fight Tsumil checked in game against Details (2026-10-10): Crusader Strike, two swings and a Seal of Command
    crit that killed the mob with overkill. Details: 6.6k damage, 1.8k DPS (by active time), SoC 2.9k."""
    r = Raid()
    r.cl.eval("ns.DB:SetSetting('meters.rate', 'active')")          # (Details' activity time, the option)
    r.combat(True)
    r.hit("Gina", 1314, spell=35395)
    r.tick(0.4)
    r.swing("Gina", 1212)
    r.tick(3.27)
    r.swing("Gina", 1212)
    r.hit("Gina", 2900, spell=20424, crit=True, overkill=1297)
    r.cl.eval("__MOCK.combat = false")
    r.end_fight()
    a = r.actor("Gina")
    assert a["d"] == 1314 + 1212 * 2 + 2900, a["d"]
    assert a["sp"][20424]["a"] == 2900
    dps = r.cl.eval("local s = ns.Meter:GetSegment('cur'); local rows = ns.Meter:Rows(s, 'dps'); return rows[1].v")
    assert 1750 <= dps <= 1900, dps
    sub = r.cl.eval("ns.MeterPanels:Draw(); return ns.MeterPanels._Panel('damage').rowsByKey[UnitGUID('player')].sub:GetText()")
    assert sub == "%d" % 0 or sub.replace(",", "").isdigit(), sub
    assert 1750 <= int(sub.replace(",", "")) <= 1900, sub


@case
def solo_header_and_bar_agree_and_chart_labels_leave_with_the_chart():
    """Reported in game 2026-10-10: the header said 696/s while the only bar said 811 (fight time vs active time),
    and the Over time chart's numbers stayed on the Targets tab."""
    r = Raid()
    r.combat(True)
    r.hit("Gina", 2000)
    r.tick(2)
    r.swing("Gina", 1500)
    r.tick(4)
    r.hit("Gina", 1445)
    r.end_fight()
    info = r.cl.eval_py("""
        ns.MeterPanels:Draw()
        local pf = ns.MeterPanels._Panel('damage')
        return { pf.tot:GetText(), pf.rowsByKey[UnitGUID('player')].sub:GetText() }""")
    assert info[0] == info[1] + "/s", info
    r.cl.eval("ns.MeterDetail:Open('cur', UnitGUID('player'), 'damage'); ns.MeterDetail:GetState().tab = 'time'; ns.MeterDetail:Draw()")
    shown = "local n = 0; for _, l in ipairs(_G.DisasterZoneMeterDetail.chart.pool.ylab or {}) do if l:IsShown() then n = n + 1 end end; return n"
    assert r.cl.eval(shown) > 0
    r.cl.eval("ns.MeterDetail:GetState().tab = 'targets'; ns.MeterDetail:Draw()")
    assert r.cl.eval(shown) == 0


@case
def whole_raid_dps_lies_between_the_fights():
    """Reported in game 2026-10-10: fights of 800-1000 DPS added up to 1,134 in All fights (casts counted as activity
    in a fight but not in the whole)."""
    r = Raid()
    dps = []
    for amount in (900, 1300):
        r.combat(True)
        r.hit("Gina", amount, dst=r.add, dst_name="Crystalcore Devastator")
        r.tick(3)                                            # (a 6 s gap only the cast bridges)
        r.ev("SPELL_CAST_SUCCESS", r.me, "Gina", ME_FLAGS, "", "", 0, 20375, r.spell(20375), 1)
        r.tick(3)
        r.hit("Gina", amount, dst=r.add, dst_name="Crystalcore Devastator")
        r.end_fight()
        dps.append(r.cl.eval("local s = ns.Meter:GetSegment('cur'); return ns.Meter:Rows(s, 'dps')[1].v"))
        r.tick(10)
    whole = r.cl.eval("local s = ns.Meter:GetSegment('all'); return ns.Meter:Rows(s, 'dps')[1].v")
    assert min(dps) <= whole <= max(dps), (dps, whole)


@case
def stacks_grow_away_from_the_screen_edge_and_hold_still_in_a_fight():
    """Asked 2026-10-10: engaging a target, does Threat grow upward or push Damage done down? Low on the screen a
    stack is held by its bottom edge (Threat grows upward, Damage done stays put); in a fight panels only grow."""
    r = Raid(thr=True)
    r.tick(0.5)
    p = r.cl.eval_py("local f = ns.MeterPanels._Stacks()[1]; local a, _, b = f:GetPoint(); "
                     "local s = ns.MeterPanels.Layout().stacks[1]; return { a, b, s.b ~= nil, s.y == nil, f.up }")
    assert p == ["BOTTOMLEFT", "BOTTOMLEFT", True, True, True], p
    r.cl.target_npc(r.boss)
    r.combat(True, "Victhar")
    r.hit("Gina", 100)
    threat(r, {"Victhar": (True, 3, 100, 100, 200000), "Gina": (False, 1, 62, 68, 136000),
               "Hunt": (False, 0, 40, 52, 104000)})
    h = r.cl.eval("ns.MeterPanels:Draw(); return ns.MeterPanels._Panel('threat'):GetHeight()")
    assert h > 24, h
    threat(r, {})                                            # the target died: nobody has threat
    h2 = r.cl.eval("ns.MeterPanels:Draw(); return ns.MeterPanels._Panel('threat'):GetHeight()")
    assert h2 == h, (h, h2)                                  # holds still while the fight goes on
    r.end_fight()
    h3 = r.cl.eval("ns.MeterPanels:Draw(); return ns.MeterPanels._Panel('threat'):GetHeight()")
    assert h3 == 24, h3                                      # just its header once the fight is over


@case
def an_older_layout_low_on_the_screen_switches_to_its_bottom_edge_in_place():
    r = Raid()
    r.cl.eval("ns.DB:SetSetting('meters.layout', { v = 1, stacks = { { x = 900, y = 260, w = 300, panels = { "
              "{ tabs = { { view = 'damage', seg = 'cur' } } } } } } }); ns.MeterPanels:Rebuild()")
    s = r.cl.eval_py("local s = ns.MeterPanels.Layout().stacks[1]; return { s.y, s.b, ns.MeterPanels.Layout().v }")
    assert s[0] is None and s[1] == 260 - 24 and s[2] >= 2, s


@case
def ticks_that_cannot_crit_stay_out_of_the_crit_chance():
    """Asked 2026-10-10: Ignite skewed the breakdown's crit card (a fire mage at ~33% showed 18%). Periodic ticks,
    damage shields and Consecration cannot crit in TBC: marked, and left out of the crit chance."""
    r = Raid()
    r.combat(True)
    for i in range(4):
        r.hit("Gina", 2000, spell=27070, crit=(i % 2 == 0))                          # Fireball: 2 of 4 crit
    for _ in range(10):
        r.hit("Gina", 300, spell=12654, sub="SPELL_PERIODIC_DAMAGE")                 # Ignite ticks
    r.ev("DAMAGE_SHIELD", r.me, "Gina", ME_FLAGS, r.boss, "Void Reaver", BOSS_FLAGS,
         27150, "Retribution Aura", 2, 80, -1, 2, None, None, None, False, False, False)
    r.tick(1)
    a = r.actor("Gina")
    assert a["sp"][12654].get("nc") is True and a["sp"][27150].get("nc") is True and not a["sp"][27070].get("nc")
    r.cl.eval("ns.MeterDetail:Open('cur', UnitGUID('player'), 'damage')")
    assert r.cl.eval("return _G.DisasterZoneMeterDetail.cards[4].num:GetText()") == "50.0%"
    subs = r.cl.eval_py("local o = {}; for _, x in ipairs(_G.DisasterZoneMeterDetail.rows) do if x:IsShown() then "
                        "o[#o + 1] = x.sub:GetText() end end; return o")
    assert any(s.endswith("can't crit") for s in subs), subs


@case
def interrupts_dispels_and_active_time_have_their_own_breakdown_and_short_lists_no_scroll_bar():
    """Reported 2026-10-10: those three modes opened the damage breakdown, and the death recap showed a scroll bar
    with nothing to scroll."""
    r = Raid(dmg=False, instance=False)
    r.cl.eval("ns.DB:SetSetting('meters.dmg', true); ns.Demo:SetEnabled(true)")
    find = "local g; for k, a in pairs(ns.Meter:GetSegment('all').actors) do if a.n == '%s' then g = k end end; "
    r.cl.eval(find % "Shadowmelder" + "ns.MeterDetail:Open('all', g, 'kicks')")
    f = "_G.DisasterZoneMeterDetail"
    assert r.cl.eval("return %s.cards[1].lab:GetText()" % f) == "Interrupts"
    assert r.cl.eval("return %s.cards[1].num:GetText()" % f) == "14"
    names = r.cl.eval_py("local o = {}; for _, x in ipairs(%s.rows) do if x:IsShown() then o[#o + 1] = x.name:GetText() end end; return o" % f)
    assert names[0] == "Spells they used" and "What they interrupted" in names, names
    # (the tabs sit in the tool window's tool row now, beside the pager: no tab is shown)
    assert r.cl.eval("local t = %s.tabs; return t:GetTab('abilities'):IsShown() or t:GetTab('targets'):IsShown() "
                     "or t:GetTab('time'):IsShown()" % f) is False
    r.cl.eval(find % "Brightmend" + "ns.MeterDetail:Open('all', g, 'dispels')")
    assert r.cl.eval("return %s.cards[1].lab:GetText()" % f) == "Dispels"
    r.cl.eval(find.replace("'all'", "'cur'") % "Gina" + "ns.MeterDetail:Open('cur', g, 'active')")
    assert r.cl.eval("return %s.cards[1].lab:GetText()" % f) == "Active time"
    assert r.cl.eval("return %s.chart:IsShown()" % f) is True
    r.cl.eval("ns.MeterDetail:OpenDeath('cur', ns.Meter:GetSegment('cur').deaths[1])")
    assert r.cl.eval("return %s.events.ScrollBar:IsShown()" % f) is False


@case
def charts_run_from_the_first_second_to_the_last():
    """Reported 2026-10-10: the Over time line started ~2.5 s in and stopped ~1-2 s early (points at step middles)."""
    r = Raid(dmg=False, instance=False)
    r.cl.eval("ns.DB:SetSetting('meters.dmg', true); ns.Demo:SetEnabled(true)")
    for mode, tab in (("damage", "time"), ("active", "abilities")):
        span = r.cl.eval_py("ns.MeterDetail:Open('cur', ns.MeterDemo.ME, '%s'); ns.MeterDetail:GetState().tab = '%s'; "
                            "ns.MeterDetail:Draw(); local o = _G.DisasterZoneMeterDetail.chart.opts; local p = o.series[1].points; "
                            "return { p[1][1], p[#p][1], o.x1 }" % (mode, tab))
        assert span[0] == 0 and span[1] == span[2], (mode, span)
    w = r.cl.eval("ns.MeterDetail:Open('cur', ns.MeterDemo.ME, 'damage'); return _G.DisasterZoneMeterDetail.banner.fight:GetWidth()")
    assert 120 <= w <= 260, w


@case
def per_second_ranks_like_the_totals_by_default():
    """Reported in game 2026-10-10 (Maulgar): bars by damage, but per second by each player's active time, so higher
    damage showed lower DPS (a 3.6 s two-hander's swing gaps fell out of active time, Auto Shot kept a hunter active
    all fight). By default per second is the fight's length for everyone; active time is the option."""
    extra = [ExtraMember("Ret", "PALADIN"), ExtraMember("Hunt", "HUNTER")]
    r = Raid(extra=extra)
    r.combat(True, "Ret", "Hunt")
    for i in range(10):                                      # Ret: big swings 4.5 s apart; Hunt: small shots every 1.5 s
        if i % 3 == 0:
            r.hit("Ret", 3000, spell=20424)
        r.hit("Hunt", 800, spell=75)
        r.tick(1.5)
    r.end_fight()
    order = r.cl.eval_py("local s = ns.Meter:GetSegment('cur'); local o = {}; for i, x in ipairs(ns.Meter:Rows(s, 'dps')) do "
                         "o[i] = x.a.n end; return o")
    dmg = r.cl.eval_py("local s = ns.Meter:GetSegment('cur'); local o = {}; for i, x in ipairs(ns.Meter:Rows(s, 'damage')) do "
                       "o[i] = x.a.n end; return o")
    assert order == dmg, (order, dmg)
    r.cl.eval("ns.DB:SetSetting('meters.rate', 'active')")
    act = r.cl.eval("local s = ns.Meter:GetSegment('cur'); for _, a in pairs(s.actors) do if a.n == 'Ret' then return a.act end end")
    assert act >= 13, act                                    # 4.5 s gaps count as active now (cut-off 5 s)


@case
def the_corner_changes_rows_only_by_how_far_it_is_dragged():
    """Reported 2026-10-10: Threat showed one player in a raid. The stack hangs from its bottom, so its corner is on
    Threat, which out of combat is just a header: touching the corner set it to 1 row (measured from the panel's own
    edge). Rows now change by the drag's distance; layouts left at 1 row get their default back."""
    r = Raid(thr=True)
    r.cl.eval("ns.EditMode:Open()")
    r.tick(0.5)
    rows = lambda: r.cl.eval("return ns.MeterPanels.Layout().stacks[1].panels[1].rows")
    drag = """
        local MP = ns.MeterPanels
        local f = MP._Stacks()[1]
        local sc = f:GetEffectiveScale()
        __MOCK.mouse_down = true
        __MOCK.cursor = { 500 * sc, 300 * sc }
        MP:StartResize(f)
        __MOCK.cursor = { 520 * sc, (300 + %d) * sc }
        MP:Draw(); ns.MeterPanels._Holder():GetScript('OnUpdate')(ns.MeterPanels._Holder(), 0.02)
        __MOCK.mouse_down = false
        MP:EndResize()
        __MOCK.cursor = nil"""
    assert r.cl.eval("return ns.MeterPanels._Stacks()[1].up") is True
    r.cl.eval(drag % 4)                                      # a width drag (4 px up): rows untouched
    assert rows() is None, rows()
    r.cl.eval(drag % 61)                                     # three rows' worth upward: 8 -> 11
    assert rows() == 11, rows()
    r.cl.eval("local L = ns.MeterPanels.Layout(); L.v = 2; L.stacks[1].panels[1].rows = 1; ns.MeterPanels:Rebuild()")
    assert rows() is None and r.cl.eval("return ns.MeterPanels.Layout().v") == 3


@case
def the_mouse_wheel_scrolls_a_panel_past_its_last_row():
    extra = [ExtraMember("P%02d" % i, "ROGUE") for i in range(14)]
    r = Raid(extra=extra)
    r.combat(True)
    r.hit("Gina", 50)
    for i, m in enumerate(extra):
        r.hit(m.name, 1000 + i * 10)
    r.tick(1)
    shown = """
        ns.MeterPanels:Draw()
        local pf = ns.MeterPanels._Panel('damage')
        local o = {}
        for _, row in pairs(pf.rowsByKey) do if row:IsShown() then o[#o + 1] = { -row.ty, row.data.a.n } end end
        table.sort(o, function(a, b) return a[1] < b[1] end)
        local names = {}
        for i, x in ipairs(o) do names[i] = x[2] end
        return { names, pf.thumb:IsShown(), pf.offset }"""
    names, thumb, off = r.cl.eval_py(shown)
    assert names[0] == "P13" and names[-1] == "Gina" and thumb is True and off == 0, (names, thumb, off)
    r.cl.eval("local pf = ns.MeterPanels._Panel('damage'); pf:GetScript('OnMouseWheel')(pf, -3)")
    names, thumb, off = r.cl.eval_py(shown)
    assert off == 3 and names[0] == "P10" and names[-1] == "Gina", (names, off)     # I stay pinned at the bottom
    r.cl.eval("local pf = ns.MeterPanels._Panel('damage'); pf:GetScript('OnMouseWheel')(pf, -50)")
    names, thumb, off = r.cl.eval_py(shown)
    assert off == 15 - 8 and names[-1] == "Gina" and "P00" in names, (names, off)   # the bottom: me in my own place
    r.end_fight()
    r.combat(True)
    r.hit("Gina", 10, dst=r.add, dst_name="Crystalcore Devastator")
    assert r.cl.eval("return ns.MeterPanels._Panel('damage').offset") == 0      # a new fight starts at the top


@case
def a_drag_lasts_until_the_button_is_let_go_even_if_the_client_never_reports_it_down():
    """Reported in game 2026-10-11: panels would not dock. The drag ended whenever IsMouseButtonDown("LeftButton")
    said no, which this client may say all along: every drag ended on its first frame. Now the stack follows the
    cursor itself and the drag ends on OnDragStop / GLOBAL_MOUSE_UP, or on IsMouseButtonDown only after it said yes."""
    r = Raid(thr=True)
    r.cl.eval("ns.EditMode:Open(); __MOCK.mouse_down = false")
    r.tick(0.5)
    r.cl.eval("local pf = ns.MeterPanels._Panel('threat'); pf.head:GetScript('OnDragStart')(pf.head)")
    r.cl.eval("__MOCK.cursor = { 700, 500 }")
    r.tick(0.3)                                              # OnUpdate runs: the API never says the button is down
    assert r.cl.eval("return ns.MeterPanels._Dragging()") is True
    moved = r.cl.eval_py("local f = ns.MeterPanels._Stacks()[1]; local p, rel, rp, x, y = f:GetPoint(); return { p, rp }")
    assert moved == ["TOPLEFT", "BOTTOMLEFT"], moved                        # it follows the cursor
    r.cl.eval("local pf = ns.MeterPanels._Panel('threat'); pf.head:GetScript('OnDragStop')(pf.head)")
    assert r.cl.eval("return ns.MeterPanels._Dragging()") is False
    # where the API does report the button: down, then up ends it
    r.cl.eval("local pf = ns.MeterPanels._Panel('threat'); __MOCK.mouse_down = true; pf.head:GetScript('OnDragStart')(pf.head)")
    r.tick(0.1)
    r.cl.eval("__MOCK.mouse_down = false; __MOCK.cursor = nil")
    r.tick(0.1)
    assert r.cl.eval("return ns.MeterPanels._Dragging()") is False


@case
def docking_is_easy_to_hit_and_a_row_moves_as_one():
    """Reported in game 2026-10-11: the gold line showed beside a stack but never at its top or bottom (it was drawn
    under the stacks), and a drop beside a stack only lined it up. Now over a stack's lower / upper half (or just past
    that edge) it joins under / over it, a row (dropped beside) moves together, and Shift takes one out of it."""
    r = Raid(thr=True)
    res = r.cl.eval_py("""
        local F = ns.MeterPanels.FindTarget
        local A = { name = "A" }
        local others = { { A, 100, 500, 300, 120, heads = { { "pA1", 100, 500, 400, 476 } } } }
        local function k(m, sides)
            local t = F(m, 900, 900, others, sides)
            if t and t.stack ~= A then return "no stack" end
            return t and t.kind or "none"
        end
        return {
            k({ 120, 420, 300, 80 }),            -- over A's lower half (A runs 500 down to 380)
            k({ 80, 560, 300, 100 }),            -- over A's upper half
            k({ 130, 350, 300, 80 }),            -- 30 px under A's bottom
            k({ 120, 300, 300, 80 }),            -- too far under
            k({ 120, 420, 300, 80 }, true),      -- a whole row moving: never into a stack
            k({ 420, 470, 200, 80 }, true),      -- beside, 20 px off, lower down: A's row
        }""")
    assert res == ["below", "above", "below", "none", "none", "right"], res

    r.cl.eval("ns.EditMode:Open()")
    r.tick(0.5)
    r.cl.eval("ns.MeterPanels:Spawn(ns.MeterPanels._Panel('damage'), 'healing')")
    assert layout(r) == ["threat/damage", "healing"]
    # dropped beside the first stack: one row, flush (their borders overlap), held by the same edge
    r.cl.eval("""
        local MP = ns.MeterPanels
        local L = MP.Layout()
        L.stacks[1].x, L.stacks[1].y, L.stacks[1].b, L.stacks[1].w = 200, 700, nil, 300
        __MOCK.mouse_down = true
        MP:StartDrag(2)
        MP._SetTarget({ kind = "right", stack = L.stacks[1] })
        __MOCK.mouse_down = false
        MP:EndDrag()
    """)
    row = r.cl.eval_py("""
        local L = ns.MeterPanels.Layout()
        local a, c = L.stacks[1], L.stacks[2]
        return { a.g ~= nil and a.g == c.g, c.x, c.y or -1, c.b or -1 }""")
    assert row == [True, 499, 700, -1], row
    # the stacks keep their places: dragging one takes the other along
    r.cl.eval("__MOCK.mouse_down = true; ns.MeterPanels:StartDrag(1)")
    assert r.cl.eval("return ns.MeterPanels._DragRow()") == 1
    r.cl.eval("__MOCK.mouse_down = false; ns.MeterPanels:EndDrag()")
    # a wider left stack pushes the right one along
    r.cl.eval("local L = ns.MeterPanels.Layout(); L.stacks[1].w = 360; ns.MeterPanels:Rebuild()")
    assert r.cl.eval("local L = ns.MeterPanels.Layout(); return L.stacks[2].x - L.stacks[1].x") == 359
    # Shift on the right one's header: it alone, out of the row (a row of one is no row)
    r.cl.eval("""
        local MP = ns.MeterPanels
        __MOCK.mouse_down = true
        MP:StartDrag(2, true)
    """)
    assert r.cl.eval("return ns.MeterPanels._DragRow()") == 0
    r.cl.eval("__MOCK.mouse_down = false; ns.MeterPanels:EndDrag()")
    assert r.cl.eval_py("local L = ns.MeterPanels.Layout(); return { L.stacks[1].g or 0, L.stacks[2].g or 0 }") == [0, 0]
    assert layout(r) == ["threat/damage", "healing"]


@case
def a_real_drag_onto_a_stack_docks_it():
    """Reported in game 2026-10-11: the outline showed but the drop did nothing. FindTarget read o.stack where the
    stack is o[1], so every target had no stack and EndDrag failed. This drag goes the whole way: header pressed,
    cursor moved (UpdateDrag finds the target), button let go."""
    r = Raid(thr=True)
    r.cl.eval("ns.EditMode:Open(); __MOCK.mouse_down = false")
    r.tick(0.5)
    r.cl.eval("ns.MeterPanels:Detach(1, 1); ns.MeterPanels:EndDrag()")
    assert layout(r) == ["damage", "threat"]
    r.cl.eval("local pf = ns.MeterPanels._Panel('threat'); __MOCK.cursor = { 320, 690 }; pf.head:GetScript('OnDragStart')(pf.head)")
    r.cl.eval("__MOCK.cursor = { 330, 430 }")
    r.tick(0.2)
    assert r.cl.eval("local t = ns.MeterPanels._Target(); return t and t.stack ~= nil") is True
    r.cl.eval("local pf = ns.MeterPanels._Panel('threat'); pf.head:GetScript('OnDragStop')(pf.head); __MOCK.cursor = nil")
    assert len(layout(r)) == 1 and sorted(layout(r)[0].split("/")) == ["damage", "threat"], layout(r)


@case
def tabs_stay_put_between_draws():
    """Reported in game 2026-10-11: hovering an icon-only tab flickered its tooltip and clicks to switch tabs barely
    registered. Every draw hid all tabs and showed them again (a hidden frame loses the mouse and a half-done click).
    Now a tab in use is never hidden by a draw, and its clickable area reaches into the gap beside it."""
    r = Raid(thr=True)
    r.cl.eval("ns.EditMode:Open()")
    r.tick(0.5)
    r.cl.eval("""
        local MP = ns.MeterPanels
        local L = MP.Layout()
        L.stacks[1].panels[2].tabs[2] = { view = "healing", seg = "cur" }
        MP:Rebuild()
        __HIDES = 0
        local pf = MP._Panel('damage')
        for _, b in ipairs(pf.tabs) do b:SetScript("OnHide", function() __HIDES = __HIDES + 1 end) end
        for _ = 1, 5 do MP:Draw() end
    """)
    assert r.cl.eval("return __HIDES") == 0
    assert r.cl.eval_py("local pf = ns.MeterPanels._Panel('damage'); return { pf.tabs[1]:IsShown(), pf.tabs[2]:IsShown() }") == [True, True]
    # down to one tab: the tabs go, the view button is back
    r.cl.eval("local MP = ns.MeterPanels; MP.Layout().stacks[1].panels[2].tabs[2] = nil; MP.Layout().stacks[1].panels[2].active = 1; MP:Rebuild()")
    assert r.cl.eval_py("local pf = ns.MeterPanels._Panel('damage'); return { pf.tabs[1]:IsShown(), pf.mode:IsShown() }") == [False, True]


@case
def a_tab_switch_grows_the_bars_in_place():
    """Asked 2026-10-11: the tab switch animation could be more elegant. Players in both views slid between places
    and the rest flew in from below. Now every row starts in its place, empty and clear, and grows in (row after
    row), and live updates keep their glide."""
    r = Raid()
    r.hit("Gina", 900)
    r.tick(0.5)
    r.cl.eval("""
        local MP = ns.MeterPanels
        local p = MP.Layout().stacks[1].panels[1]
        p.tabs[2] = { view = "healing", seg = "cur" }
        p.tabs[3] = { view = "dps", seg = "cur" }
        MP:Rebuild()
    """)
    r.tick(1)
    r.cl.eval("local MP = ns.MeterPanels; MP.Layout().stacks[1].panels[1].active = 3; MP:Draw()")
    st = r.cl.eval_py("""
        local pf = ns.MeterPanels._Panel('dps')
        local o = {}
        for _, row in pairs(pf.rowsByKey) do o[#o + 1] = { row.anim ~= nil, row:GetAlpha(), row.w, row.y == row.ty } end
        return o""")
    assert st and all(s[0] and s[1] == 0 and s[2] == 0 and s[3] for s in st), st
    r.tick(1)
    st = r.cl.eval_py("""
        local pf = ns.MeterPanels._Panel('dps')
        local o = {}
        for _, row in pairs(pf.rowsByKey) do o[#o + 1] = { row.anim ~= nil, row:GetAlpha(), math.abs(row.w - row.tw) < 0.01 } end
        return o""")
    assert all((not s[0]) and s[1] == 1 and s[2] for s in st), st
    # a plain redraw (same view) starts nothing
    r.cl.eval("ns.MeterPanels:Draw()")
    assert r.cl.eval("for _, row in pairs(ns.MeterPanels._Panel('dps').rowsByKey) do if row.anim then return true end end return false") is False


@case
def the_fight_line_steps_through_fights_for_the_whole_panel():
    """Asked 2026-10-11 (the user's pick A of the fight picker mockup): a line under the header names the panel's
    fight; the arrows and the wheel step to older / newer fights (past the newest: the whole raid), the name opens the
    list. The fight belongs to the panel: all its tabs show it. Threat panels have no line."""
    r = Raid(thr=True)
    r.combat(True, "Victhar")
    r.hit("Gina", 500, dst_name="Void Reaver")
    r.end_fight()
    r.combat(True, "Victhar")
    r.hit("Gina", 300, dst=r.add, dst_name="Crystalcore Devastator")
    r.end_fight()
    r.tick(1)
    r.cl.eval("""
        local MP = ns.MeterPanels
        local p = MP.Layout().stacks[1].panels[2]
        p.tabs[2] = { view = "healing", seg = "cur" }
        MP:Rebuild()
    """)
    line = lambda: r.cl.eval_py("""
        local pf = ns.MeterPanels._Panel('damage')
        local tabs = {}
        for i, t in ipairs(pf.layout.tabs) do tabs[i] = t.seg end
        return { pf.fl:IsShown(), pf.fl.name:GetText(), pf.fl.meta:GetText(), pf.fl.prev:IsEnabled(), pf.fl.next:IsEnabled(),
                 table.concat(tabs, ",") }""")
    shown, name, meta, older, newer, segs = line()
    assert shown and name.startswith("Crystalcore") and "2 of 2" in meta and older and newer and segs == "cur,cur", line()
    r.cl.eval("local pf = ns.MeterPanels._Panel('damage'); pf.fl.prev:Click()")
    shown, name, meta, older, newer, segs = line()
    assert name == "Void Reaver" and "1 of 2" in meta and not older and newer, line()
    assert segs.split(",")[0] == segs.split(",")[1] != "cur", segs            # both tabs on that fight
    # the wheel: up = newer, twice = past the newest, the whole raid (the end of the line)
    r.cl.eval("local fl = ns.MeterPanels._Panel('damage').fl; fl:GetScript('OnMouseWheel')(fl, 1); fl:GetScript('OnMouseWheel')(fl, 1)")
    shown, name, meta, older, newer, segs = line()
    assert segs == "all,all" and "all fights" in meta and older and not newer, line()
    # threat: no line
    assert r.cl.eval("return ns.MeterPanels._Panel('threat').fl:IsShown()") is False
    # a narrow panel: the name gives way to "Fight n", never cut off
    r.cl.eval("local fl = ns.MeterPanels._Panel('damage').fl; fl.prev:Click()")
    r.cl.eval("local L = ns.MeterPanels.Layout(); L.stacks[1].w = 170; ns.MeterPanels:Rebuild()")
    assert r.cl.eval("return ns.MeterPanels._Panel('damage').fl.name:GetText()") in ("Fight 2", "Crystalcore Devastator")


@case
def the_fight_list_is_short_bosses_as_rows_trash_as_squares():
    """Asked 2026-10-11 (the user's pick C of the fight list mockup): the list was one line per pull, 25 lines on a
    night of trash. Now: the whole raid on top, a heading per zone, bosses as rows with Kill / Wipe, and each run of
    trash between them as one row of squares (oldest to newest). A pick shows that fight and closes the list."""
    r = Raid()
    for _ in range(3):                                       # three trash pulls
        r.combat(True, "Victhar")
        r.hit("Gina", 300, dst=r.add, dst_name="Crystalcore Devastator")
        r.tick(3)
        r.end_fight()
    r.tick(5)
    r.cl.fire("ENCOUNTER_START", 731, "Void Reaver", 4, 25)  # a wipe, then a kill
    r.hit("Gina", 1000)
    r.cl.eval("__MOCK.target_npc = nil")
    r.cl.fire("ENCOUNTER_END", 731, "Void Reaver", 4, 25, 0)
    r.tick(5)
    r.cl.fire("ENCOUNTER_START", 731, "Void Reaver", 4, 25)
    r.hit("Gina", 1000)
    r.cl.fire("ENCOUNTER_END", 731, "Void Reaver", 4, 25, 1)
    r.tick(5)
    r.combat(True, "Victhar")                                # trash again, now
    r.hit("Gina", 300, dst=r.add, dst_name="Crystalcore Devastator")
    r.end_fight()
    r.tick(1)
    r.cl.eval("local pf = ns.MeterPanels._Panel('damage'); pf.fl.lab:Click()")
    assert r.cl.eval("return ns.MeterPanels._FightList():IsShown()") is True
    keys = r.cl.eval_py(LIST_KEYS)
    assert keys[0] == "row:all" and keys[1] == "dot:cur", keys                # whole raid; the newest trash run
    assert [k.split(":")[0] for k in keys[2:]] == ["row", "row", "dot", "dot", "dot"], keys
    lines = r.cl.eval_py("""
        local f = ns.MeterPanels._FightList()
        local o = {}
        for _, row in ipairs(f.rows) do
            if row:IsShown() then
                local icon = row.stIcon:IsShown() and tostring(row.stIcon:GetTexture()) or ""
                o[#o + 1] = (row.name:GetText() or "") .. "|" .. icon .. "|" .. (row.small:GetText() or "")
            end
        end
        return o""")
    shown = len(lines)
    assert shown <= 8, lines                                  # 7 fights + whole raid in 7 lines (+ separator)
    # results as icons (asked 2026-10-11): a kill the ready-check tick, a wipe the skull
    assert any(l.startswith("Void Reaver|") and "ReadyCheck-Ready" in l for l in lines), lines
    assert any(l.startswith("Void Reaver|") and "UI-TargetingFrame-Skull" in l for l in lines), lines
    # a square: that pull, and the list closes
    r.cl.eval(PICK_OLDER)
    assert r.cl.eval("return ns.MeterPanels._FightList():IsShown()") is False
    seg = r.cl.eval("return ns.MeterPanels._Panel('damage').layout.tabs[1].seg")
    assert seg not in ("cur", "all"), seg
    # a second click on the name closes it again; Escape too
    r.cl.eval("local pf = ns.MeterPanels._Panel('damage'); pf.fl.lab:Click(); pf.fl.lab:Click()")
    assert r.cl.eval("return ns.MeterPanels._FightList():IsShown()") is False
    r.cl.eval("local pf = ns.MeterPanels._Panel('damage'); pf.fl.lab:Click(); local f = ns.MeterPanels._FightList(); f:GetScript('OnKeyDown')(f, 'ESCAPE')")
    assert r.cl.eval("return ns.MeterPanels._FightList():IsShown()") is False


@case
def a_threat_bar_is_as_long_as_its_number():
    """Reported in game 2026-10-11: the tank at 100% looked like ~60%: the bars ran to 135% on one scale. Now the track
    is 0-100% (the tank's bar is full, 68% fills 68%), a short pull zone after it runs from 100% to my pull point and
    ends in the gold line; my row has the gold edge; the header says "You 68%  · pull at 110%"."""
    r = Raid(dmg=False, thr=True)
    r.cl.eval("ns.DB:SetSetting('meters.tankView', 'never')")
    r.combat(True, "Victhar")
    r.cl.target_npc(r.boss)
    threat(r, {"Victhar": (True, 3, 100, 100, 200000), "Gina": (False, 1, 62, 68, 136000),
               "Hunt": (False, 2, 95, 105, 210000)})
    r.tick(0.5)
    r.cl.eval("ns.MeterPanels:Draw()")
    got = r.cl.eval_py("""
        local pf = ns.MeterPanels._Panel('threat')
        local o = { track = 0, tot = pf.totV:GetText() .. " " .. pf.tot:GetText() }
        for _, row in pairs(pf.trowsByKey) do
            local n = row.name:GetText()
            o[n] = row.tw
            o[n .. "_me"] = row.you:IsShown()
            o.track = row.track:GetWidth()
        end
        local _, _, _, x = pf.pull:GetPoint()
        o.line = x + 1
        o.tankLine = pf.tankLine:IsShown()
        return o""")
    W = got["track"]
    assert abs(got["Victhar"] - W) < 0.01, got                              # the tank: a full bar
    assert abs(got["Gina"] - 0.68 * W) < 0.5, got                           # 68%: 68% of the track
    assert W < got["Hunt"] <= W + 26, got                                    # past 100%: into the pull zone
    assert got["Gina_me"] is True and got["Victhar_me"] is False, got       # my row: the gold edge
    assert got["tankLine"] is False, got                                     # one line, the gold one
    assert got["tot"].startswith("You 68%") and "pull at 110%" in got["tot"], got


def themed(r, theme, **over):
    """Set a meter theme (and overrides), draw, and read the damage panel's rows."""
    r.cl.eval("ns.DB:SetSetting('meters.theme', ...)", theme)
    for k, v in over.items():
        r.cl.eval("ns.DB:SetSetting('meters.' .. select(1, ...), select(2, ...))", k, v)
    r.tick(0.2)
    return r.cl.eval_py("""
        ns.MeterPanels:Draw()
        local pf = ns.MeterPanels._Panel('damage')
        local o = { h = pf:GetHeight(), head = pf.head:GetHeight(), label = pf.mode.text:GetText(), rows = {} }
        for g, row in pairs(pf.rowsByKey) do
            local fr, fg, fb, fa = row.fill:GetVertexColor()
            local nr, ng, nb = row.name:GetTextColor()
            o.rows[row.data.a.n] = { h = row:GetHeight(), icon = row.icon:IsShown(), rank = row.rank:IsShown() and row.rank:GetText(),
                sub = row.sub:IsShown(), value = row.value:GetText(), fill = { fr, fg, fb, fa }, name = { nr, ng, nb },
                you = row.you:IsShown(), caps = row.capR and row.capR:IsShown() or false }
        end
        local s1 = ns.MeterPanels._Stacks()[1]
        local _, _, _, a = s1.fill:GetVertexColor()
        o.bg = a
        o.corners = s1.gilt and s1.gilt.cornerTex[1]:IsShown() or false     -- (Gilded's worked gold, UI/Look.lua)
        o.edge9 = s1.e9 and s1.e9.on or false                                -- (Classic's tooltip edge)
        return o""")


def fight_for_themes():
    r = Raid()
    r.combat(True)
    r.hit("Gina", 380112)
    r.hit("Victhar", 200000)
    r.hit("Hunt", 120000)
    r.tick(1)
    return r


@case
def every_meter_theme_draws_its_own_rows():
    """Settings > Meters > Look (UI/MeterTheme.lua): each theme sets its row height, icon, bar and text; the panel is as
    tall as the theme's header, fight line and rows; a theme change restyles the rows already made."""
    r = fight_for_themes()
    heights = r.cl.eval_py("local o = {}; for _, t in ipairs(ns.MeterTheme.THEMES) do o[t.key] = { t.row, t.head, t.fl, t.gap, t.pad } end; return o")
    for key, (row_h, head, fl, gap, pad) in heights.items():
        got = themed(r, key)
        n = len(got["rows"])
        assert n == 3, (key, got)
        assert all(x["h"] == row_h for x in got["rows"].values()), (key, got)
        assert got["head"] == head, (key, got)
        assert got["h"] == head + fl + pad * 2 + n * row_h + (n - 1) * gap, (key, got)
        gina = got["rows"]["Gina"]
        if key == "pips":                                     # dense: rank numbers, no icons, no per-second column
            assert gina["rank"] == "1" and gina["icon"] is False and gina["sub"] is False, got
        else:
            assert gina["icon"] is True and gina["rank"] is False and gina["sub"] is True, (key, got)
        assert gina["caps"] is (key == "halo"), (key, got)    # the pill's round ends
        assert gina["you"] is (key in ("flat", "pips")), (key, got)   # (the others mark my row their own way)
        if key == "slate":                                    # names in class colour
            assert abs(gina["name"][0] - 0.96) < 0.01 and abs(gina["name"][1] - 0.55) < 0.01, got
        if key == "sigil":
            assert got["label"] == "DAMAGE DONE", got
        else:
            assert got["label"] == "Damage done", (key, got)
        assert got["corners"] is (key == "gilded"), (key, got)
        assert got["edge9"] is (key == "classic"), (key, got)


@case
def meter_overrides_sit_on_top_of_the_theme():
    r = fight_for_themes()
    base = themed(r, "flat")
    assert base["rows"]["Gina"]["value"] == "380.1k", base
    got = themed(r, "flat", numbers="full", barColor="one", icons="none", rowSize="roomy", bg=50)
    gina = got["rows"]["Gina"]
    assert gina["value"] == "380,112", got
    assert gina["icon"] is False and gina["h"] == 22, got
    fills = {tuple(round(c, 2) for c in x["fill"][:3]) for x in got["rows"].values()}
    assert len(fills) == 1, got                               # one colour for everyone
    assert abs(got["bg"] - 0.5) < 0.01, got
    got = themed(r, "flat", numbers="round", barColor="role", icons="theme", rowSize="theme", bg="theme")
    assert got["rows"]["Gina"]["value"] == "380k" and got["rows"]["Gina"]["icon"] is True, got
    assert abs(got["bg"] - 0.66) < 0.01, got
    # role colours: Victhar (Protection) a tank, Hunt damage
    r.cl.eval("for _, a in pairs(ns.Meter:GetSegment('cur').actors) do if a.n == 'Victhar' then a.s = 'Protection' end end")
    got = themed(r, "flat")
    assert got["rows"]["Victhar"]["fill"][2] > got["rows"]["Victhar"]["fill"][0], got     # blue
    assert got["rows"]["Hunt"]["fill"][0] > got["rows"]["Hunt"]["fill"][2], got           # red


@case
def pointing_at_a_theme_tile_previews_it_on_the_panels():
    r = fight_for_themes()
    themed(r, "flat")
    # (Settings > Interface > Looks > Meters: the theme tiles' page)
    r.cl.eval("ns.MainFrame:Open('settings'); ns.SettingsUI:SelectSection('look.meters')")
    r.tick(0.3)
    names = r.cl.eval_py("""local o = {}
        for _, t in ipairs(ns.MeterTheme.THEMES) do o[#o + 1] = t.name end; return o""")
    assert names == ["Flat", "Halo", "Sigil", "Slate", "Gilded", "Pips", "Classic"], names
    for n in names:
        assert r.cl.find_text(n), n                            # a tile per theme, named
    h = r.cl.eval("""ns.MeterTheme:SetPreview('pips'); ns.MeterPanels:Draw()
        local pf = ns.MeterPanels._Panel('damage'); local _, row = next(pf.rowsByKey); return row:GetHeight()""")
    assert h == 13, h
    h = r.cl.eval("""ns.MeterTheme:SetPreview(nil); ns.MeterPanels:Draw()
        local pf = ns.MeterPanels._Panel('damage'); local _, row = next(pf.rowsByKey); return row:GetHeight()""")
    assert h == 19, h
    assert r.cl.eval("return ns.DB:GetSetting('meters.theme')") == "flat"


if __name__ == "__main__":
    run_all()
