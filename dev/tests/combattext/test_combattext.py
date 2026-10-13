#!/usr/bin/env python
"""Combat text (Core/CombatText.lua, UI/CombatText.lua, UI/CombatTextLooks.lua, UI/CombatTextPen.lua): the numbers of
the mockup claude.ai/artifact/LeZxS4KRZhKGsQXUbLRCiE in the six UI looks.

Covers: off by default whatever look everything wears (its own switch, ui.sct.on; the combat log not read, the game's
combat text left alone), on with Blizzard as its look wearing Classic; my hits as numbers after the merge wait, with
crit, school, icon and overkill; Windfury's extra swing joining the hit before it ("Melee + Windfury", counting up);
periodic ticks and ground spells (Consecration) as one tick group per spell and mob; misses on the mob and on me;
hits taken with partial resists; heals on me with the healer (overhealing left out, Hide heals under); my heals on
others; procs (short buffs in combat, my own long ones left out); the fight's biggest hit as Slate's scale; low health
once until it recovers; reactive spells lighting up; the nameplate anchor (66 px under the plate) and the target spot
without one or in Columns mode; filters (auto attacks, Hide hits under); the game's own combat text (this client's
_v2 CVars and the text over your head) hidden at once, also in combat, and put back as it was; Edit layout's three
spots and their preview; the demo pull (Try it, also while off; demo mode) in every look with no errors and the
pool reused; Settings > UI's Combat text card with its switch and Try it.

Run: luaenv\\Scripts\\python.exe tests\\combattext\\test_combattext.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "boot-ui"))
sys.path.insert(0, os.path.join(HERE, "..", "..", "tools"))

from _common import case, run_all, solo  # noqa: E402

ME_FLAGS = 0x511
BOSS_FLAGS = 0xA48
LOOKS = ("flat", "halo", "sigil", "slate", "gilded", "classic")


class Pull:
    """Alice (paladin) with combat text in `look`, a Void Reaver to hit; every event the stage gets is logged."""

    def __init__(self, look="flat", plate=False, **opts):
        w, c = solo("Alice", class_file="PALADIN", guild_rank=0)
        c.eval("__MOCK.real_geometry = true; ns.DB:SetSetting('ui.sct.look', ...); ns.DB:SetSetting('ui.sct.on', true)",
               look)
        for k, v in opts.items():
            c.eval("ns.DB:SetSetting(...)", "ui.sct." + k, v)
        w.tick(0.5)
        c.eval("__ctlog = {}; local CT = ns.CombatTextUI; local emit = CT.Emit; "
               "CT.Emit = function(self, ev) __ctlog[#__ctlog + 1] = ev; return emit(self, ev) end")
        self.w, self.c = w, c
        self.me = c.eval("return UnitGUID('player')")
        self.boss = w.spawn_npc(19516, "Void Reaver")
        if plate:
            self.token = c.show_nameplate(self.boss)
        c.set_combat(True)
        w.tick(0.1)

    def ev(self, sub, src, src_name, src_flags, dst, dst_name, dst_flags, *rest):
        self.c.combat_log(self.c.eval("return GetTime()"), sub, False, src or "", src_name or "", src_flags, 0,
                          dst or "", dst_name or "", dst_flags, 0, *rest)

    def swing(self, amount, crit=False, overkill=-1):
        self.ev("SWING_DAMAGE", self.me, "Alice", ME_FLAGS, self.boss, "Void Reaver", BOSS_FLAGS,
                amount, overkill, 1, None, None, None, crit, False, False, False)

    def spell(self, sid, name, amount, crit=False, school=2, sub="SPELL_DAMAGE", overkill=-1):
        self.ev(sub, self.me, "Alice", ME_FLAGS, self.boss, "Void Reaver", BOSS_FLAGS,
                sid, name, school, amount, overkill, school, None, None, None, crit, False, False)

    def taken(self, amount, sid=None, name=None, resisted=None, school=1):
        if sid:
            self.ev("SPELL_DAMAGE", self.boss, "Void Reaver", BOSS_FLAGS, self.me, "Alice", ME_FLAGS,
                    sid, name, school, amount, -1, school, resisted, None, None, False, False, False)
        else:
            self.ev("SWING_DAMAGE", self.boss, "Void Reaver", BOSS_FLAGS, self.me, "Alice", ME_FLAGS,
                    amount, -1, 1, resisted, None, None, False, False, False, False)

    def heal(self, amount, over=0, src="Player-1-00000099", src_name="Brightsong", dst=None, sid=25213):
        self.ev("SPELL_HEAL", src, src_name, 0x514, dst or self.me, "Alice", ME_FLAGS,
                sid, "Greater Heal", 2, amount, over, None, False)

    def tick(self, s=0.2):
        self.w.tick(s)

    def log(self):
        out = self.c.eval_py("local o = {}; for i, e in ipairs(__ctlog) do o[i] = { k = e.k, amt = e.amt, "
                              "spell = e.spell, crit = e.crit, group = e.group, gname = e.gname, gkey = e.gkey, "
                              "school = e.school, overkill = e.overkill, who = e.who, "
                              "resist = e.resist, what = e.what, mine = e.mine, pct = e.pct, dur = e.dur, "
                              "peak = e.peak, icon = e.icon, hit = e.hit and e.hit.id } end; return o")
        keys = ("k", "amt", "spell", "crit", "group", "gname", "gkey", "school", "record", "overkill", "who", "resist",
                "what", "mine", "pct", "dur", "peak", "icon", "hit")
        return [{k: e.get(k) for k in keys} for e in (out or [])]

    def kinds(self):
        return [e["k"] for e in self.log()]

    def sprites(self):
        return self.c.eval("return #ns.CombatTextUI.st.sprites")


# ------------------------------------------------------------------------------------------------------------------
@case
def off_by_default_whatever_look_everything_wears():
    w, c = solo("Alice", class_file="PALADIN", guild_rank=0)
    assert c.eval("return ns.CombatTextUI:IsOn()") is False
    c.eval("ns.Look:UseEverywhere('gilded'); if ns.Popup then ns.Popup:HideAll() end")
    w.tick(0.5)
    assert c.eval("return ns.CombatTextUI:IsOn()") is False
    assert c.eval("return ns.CombatText:IsListening()") is False
    assert c.eval("return ns.CombatLog:IsSubscribed('combattext')") is False
    assert c.eval("return GetCVar('floatingCombatTextCombatDamage_v2')") == "1"
    assert c.eval("return GetCVar('enableFloatingCombatText')") == "1"
    c.eval("ns.CombatTextUI:Emit({ k = 'out', amt = 100 })")
    assert c.eval("return #ns.CombatTextUI.st.sprites") == 0
    # Try it shows the look even while off
    assert c.eval("return ns.CombatTextUI:TryIt()") is True
    w.tick(2)
    assert c.eval("return #ns.CombatTextUI.st.sprites") > 0
    w.assert_no_errors()


@case
def turned_on_with_blizzard_as_its_look_it_wears_classic():
    w, c = solo("Alice", class_file="PALADIN", guild_rank=0)
    c.eval("ns.DB:SetSetting('ui.sct.on', true)")
    w.tick(0.5)
    assert c.eval("return ns.Look:Key('sct')") == "blizzard"
    assert c.eval("return ns.CombatTextUI:IsOn()") is True
    assert c.eval("return ns.CombatTextUI:LookKey()") == "classic"
    assert c.eval("return ns.CombatLog:IsSubscribed('combattext')") is True
    w.assert_no_errors()

@case
def on_it_hides_the_games_combat_text_at_once_and_puts_it_back_off():
    p = Pull("halo")
    c = p.c
    c.eval("ns.DB:SetSetting('ui.sct.on', false)")
    c.eval("SetCVar('floatingCombatTextPetMeleeDamage_v2', '0')")     # (one the player had off already)
    c.eval("ns.DB:SetSetting('ui.sct.on', true)")                       # (turned on in combat: at once)
    assert c.eval("return InCombatLockdown()") is True
    assert c.eval("return ns.CombatLog:IsSubscribed('combattext')") is True
    for cv in ("floatingCombatTextCombatDamage_v2", "floatingCombatTextCombatHealing_v2",
               "floatingCombatTextCombatLogPeriodicSpells_v2", "floatingCombatTextPetSpellDamage_v2",
               "enableFloatingCombatText"):
        assert c.eval("return GetCVar(...)", cv) == "0", cv
    c.eval("ns.DB:SetSetting('ui.sct.on', false)")
    p.tick(0.5)
    assert c.eval("return ns.CombatLog:IsSubscribed('combattext')") is False
    for cv in ("floatingCombatTextCombatDamage_v2", "floatingCombatTextCombatHealing_v2",
               "floatingCombatTextCombatLogPeriodicSpells_v2", "floatingCombatTextPetSpellDamage_v2",
               "enableFloatingCombatText"):
        assert c.eval("return GetCVar(...)", cv) == "1", cv
    assert c.eval("return GetCVar('floatingCombatTextPetMeleeDamage_v2')") == "0"
    # Hide the game's numbers off: they stay as they are
    c.eval("ns.DB:SetSetting('ui.sct.hideGame', false); ns.DB:SetSetting('ui.sct.on', true)")
    p.tick(0.5)
    assert c.eval("return GetCVar('floatingCombatTextCombatDamage_v2')") == "1"
    p.w.assert_no_errors()

@case
def my_hit_waits_for_the_merge_then_shows_with_its_crit_school_and_icon():
    p = Pull("flat")
    p.spell(35395, "Crusader Strike", 3412, crit=True, school=1)
    assert p.log() == []                            # (the merge wait: another hit of the spell may join)
    p.tick(0.3)
    e = p.log()[0]
    assert (e["k"], e["amt"], e["spell"], e["crit"], e["school"]) == ("out", 3412, "Crusader Strike", True, "phys"), e
    assert e["icon"] is not None and e["group"] is None
    assert e["hit"] == "spot"                       # (no nameplate: the target spot)
    assert p.sprites() >= 1
    p.w.assert_no_errors()


@case
def windfurys_extra_swing_joins_the_hit_before_it_and_counts_up():
    p = Pull("flat")
    p.swing(1190)
    p.ev("SPELL_EXTRA_ATTACKS", p.me, "Alice", ME_FLAGS, p.me, "Alice", ME_FLAGS, 25584, "Windfury Attack", 1, 1)
    p.swing(1233)
    p.tick(0.5)
    out = [e for e in p.log() if e["k"] == "out"]
    assert len(out) == 2, out
    assert {e["group"] for e in out} == {"multi"} and out[0]["gkey"] == out[1]["gkey"]
    assert out[0]["gname"] == "Melee" and out[1]["gname"] == "Melee + Windfury", out
    g = p.c.eval_py("local g = ns.CombatTextUI.st.groups[...]; return { n = g.n, total = g.total }", out[0]["gkey"])
    assert g == {"n": 2, "total": 2423}, g
    p.w.assert_no_errors()


@case
def ticks_and_ground_spells_count_up_in_one_group_per_spell():
    p = Pull("halo")
    p.c.eval("__MOCK.SPELL_NAMES[26573] = 'Consecration'; ns.CombatText:LearnSpells()")
    for amt in (214, 221, 209):
        p.spell(27173, "Consecration", amt)         # (a ground spell: hits without a cast)
        p.tick(1)
    p.spell(25368, "Shadow Word: Pain", 400, school=32, sub="SPELL_PERIODIC_DAMAGE")
    p.tick(0.1)
    ticks = [e for e in p.log() if e["k"] == "tick"]
    cons = [e for e in ticks if e["spell"] == "Consecration"]
    assert len(cons) == 3 and len({e["gkey"] for e in cons}) == 1 and cons[0]["group"] == "tick", ticks
    swp = [e for e in ticks if e["spell"] == "Shadow Word: Pain"]
    assert swp and swp[0]["school"] == "shadow"
    g = p.c.eval_py("local g = ns.CombatTextUI.st.groups[...]; return { n = g.n, total = g.total }", cons[0]["gkey"])
    assert g == {"n": 3, "total": 644}, g
    p.w.assert_no_errors()


@case
def classic_shows_each_tick_like_the_game():
    p = Pull("classic")
    p.c.eval("__MOCK.SPELL_NAMES[26573] = 'Consecration'; ns.CombatText:LearnSpells()")
    p.spell(27173, "Consecration", 214)
    p.spell(27173, "Consecration", 221)
    p.tick(0.1)
    assert [(e["k"], e["group"]) for e in p.log()] == [("out", None), ("out", None)], p.log()
    p.w.assert_no_errors()


@case
def misses_hits_taken_and_heals_on_me():
    p = Pull("sigil")
    p.ev("SWING_MISSED", p.me, "Alice", ME_FLAGS, p.boss, "Void Reaver", BOSS_FLAGS, "PARRY", False)
    p.ev("SWING_MISSED", p.boss, "Void Reaver", BOSS_FLAGS, p.me, "Alice", ME_FLAGS, "DODGE", False)
    p.taken(3150, 34190, "Arcane Orb", resisted=812, school=64)
    p.taken(2410)
    p.heal(2104, over=0)
    p.heal(500, over=500)                           # (all overhealing: nothing)
    p.tick(0.2)
    log = p.log()
    assert [(e["k"], e["what"], e["mine"]) for e in log if e["k"] == "miss"] == [("miss", "Parry", None), ("miss", "Dodge", True)]
    taken = [e for e in log if e["k"] == "taken"]
    assert (taken[0]["amt"], taken[0]["resist"], taken[0]["school"], taken[0]["spell"]) == (3150, 812, "arcane", "Arcane Orb")
    assert (taken[1]["spell"], taken[1]["icon"] is not None) == ("Melee", True)
    heals = [e for e in log if e["k"] == "heal"]
    assert [(e["amt"], e["who"]) for e in heals] == [(2104, "Brightsong")], heals
    p.c.eval("ns.DB:SetSetting('ui.sct.minHeal', 1000)")
    p.heal(800)
    p.tick(0.1)
    assert len([e for e in p.log() if e["k"] == "heal"]) == 1
    p.w.assert_no_errors()


@case
def my_heals_on_others_show_as_green_numbers():
    p = Pull("gilded")
    p.ev("SPELL_HEAL", p.me, "Alice", ME_FLAGS, "Player-1-00000077", "Victhar", 0x514, 27136, "Holy Light", 2, 2600, 300,
         None, True)
    p.tick(0.1)
    e = p.log()[0]
    assert (e["k"], e["amt"], e["school"], e["crit"]) == ("out", 2300, "heal", True), e
    p.w.assert_no_errors()


@case
def short_buffs_in_combat_show_as_procs_long_ones_of_mine_do_not():
    p = Pull("flat")
    p.c.eval("UnitBuff = function(u, i) local b = { { 'Bloodlust', 40, 2825 }, { 'Seal of Command', 30, 20375 }, "
             "{ 'Blessing of Might', 600, 27140 } }; local x = b[i]; if not x then return nil end; "
             "return x[1], 136000, 0, nil, x[2], GetTime() + x[2], 'player', nil, nil, x[3] end")
    shaman = "Player-1-00000055"
    p.ev("SPELL_AURA_APPLIED", shaman, "Kaelyn", 0x514, p.me, "Alice", ME_FLAGS, 2825, "Bloodlust", 8, "BUFF")
    p.ev("SPELL_AURA_APPLIED", p.me, "Alice", ME_FLAGS, p.me, "Alice", ME_FLAGS, 20375, "Seal of Command", 2, "BUFF")
    p.ev("SPELL_AURA_APPLIED", shaman, "Kaelyn", 0x514, p.me, "Alice", ME_FLAGS, 27140, "Blessing of Might", 2, "BUFF")
    p.tick(0.1)
    procs = [(e["spell"], e["dur"]) for e in p.log() if e["k"] == "proc"]
    assert procs == [("Bloodlust", 40)], procs
    p.w.assert_no_errors()


@case
def overkill_marks_the_killing_hit_and_nothing_sums_the_fight_up():
    p = Pull("slate")
    p.swing(1284)
    p.spell(35395, "Crusader Strike", 3412, crit=True, school=1)
    p.tick(0.3)
    p.spell(27180, "Hammer of Wrath", 5921, crit=True, overkill=1380)
    p.ev("UNIT_DIED", "", "", 0, p.boss, "Void Reaver", BOSS_FLAGS)
    p.tick(0.3)
    p.c.set_combat(False)
    p.tick(0.3)
    log = p.log()
    kb = [e for e in log if e["spell"] == "Hammer of Wrath"][0]
    assert kb["overkill"] == 1380
    assert [e["peak"] for e in log if e["k"] == "out"] == [1284, 3412, 5921]     # (Slate's scale: the fight's biggest)
    assert {e["k"] for e in log} == {"out"}, log
    assert p.c.eval("return ns.db.sct == nil") is True                          # (no bests are kept)
    p.w.assert_no_errors()

@case
def low_health_once_until_it_recovers():
    p = Pull("halo")
    for hp in (30, 25, 60, 20):
        p.c.eval("__MOCK.player_hp = ...; ns.CombatText:CheckLow('player')", hp)
    low = [e["pct"] for e in p.log() if e["k"] == "lowhp"]
    assert low == [30, 20], low
    p.w.assert_no_errors()


@case
def a_reactive_spell_lighting_up_in_combat_alerts_once():
    p = Pull("classic")
    c = p.c
    c.eval("__usable = false; IsUsableSpell = function() return __usable end; IsSpellKnown = function(id) return id == 27180 end; "
           "GetSpellInfo = function(id) if id == 27180 or id == 'Hammer of Wrath' then return 'Hammer of Wrath', nil, 135000 end end; "
           "UnitExists = function() return true end; UnitCanAttack = function() return true end; "
           "GetSpellCooldown = function() return 0, 0 end; ns.CombatText:LearnSpells()")
    c.eval("ns.CombatText:CheckAlerts()")
    c.eval("__usable = true; ns.CombatText:CheckAlerts(); ns.CombatText:CheckAlerts()")
    alerts = [e["spell"] for e in p.log() if e["k"] == "alert"]
    assert alerts == ["Hammer of Wrath"], alerts
    p.w.assert_no_errors()


@case
def hits_ride_the_mobs_nameplate_and_columns_keep_them_at_the_spot():
    p = Pull("flat", plate=True)
    p.spell(35395, "Crusader Strike", 3412, school=1)
    p.tick(0.3)
    e = p.log()[-1]
    assert e["hit"] == p.boss, e
    pos = p.c.eval_py("local CT = ns.CombatTextUI; local a = CT:HitAnchor(...); a.fr = nil; "
                      "local p = C_NamePlate.GetNamePlateForUnit(CT.plates[...]); return { a:Pos(CT.st) }", p.boss, p.boss)
    assert pos and len(pos) == 2
    p.c.eval("ns.DB:SetSetting('ui.sct.place', 'columns')")
    p.spell(35395, "Crusader Strike", 3000, school=1)
    p.tick(0.3)
    assert p.log()[-1]["hit"] == "spot"
    p.w.assert_no_errors()


@case
def filters_auto_attacks_and_small_hits():
    p = Pull("flat", autoAttacks=False, minHit=500)
    p.swing(1500)
    p.spell(20424, "Seal of Command", 300)
    p.spell(20424, "Seal of Command", 300, crit=True)
    p.tick(0.3)
    out = [(e["spell"], e["crit"]) for e in p.log() if e["k"] == "out"]
    assert out == [("Seal of Command", True)], out
    p.w.assert_no_errors()


@case
def the_demo_pull_plays_in_every_look_and_reuses_its_regions():
    for look in LOOKS:
        w, c = solo("Alice", class_file="PALADIN", guild_rank=0)
        c.eval("__MOCK.real_geometry = true; ns.DB:SetSetting('ui.sct.look', ...)", look)
        w.tick(0.5)
        assert c.eval("return ns.CombatTextUI:TryIt()") is True
        seen = 0
        for _ in range(80):
            w.tick(0.2)
            seen = max(seen, c.eval("return #ns.CombatTextUI.st.sprites"))
        assert seen >= 3, (look, seen)
        assert c.eval("return #ns.CombatTextUI.st.sprites") == 0, look
        assert c.eval("return ns.CombatTextUI:IsAwake()") is False, look
        n1, h1 = c.eval_py("return { ns.CTPen:Count() }")
        for _ in range(2):
            c.eval("ns.CombatTextUI:TryIt()")
            for _ in range(80):
                w.tick(0.2)
        n3, h3 = c.eval_py("return { ns.CTPen:Count() }")
        # (the hosts come back from the pool, each keeping the most regions of each kind it ever needed)
        assert h3 == h1 and n3 <= n1 * 2.5, (look, n1, h1, n3, h3)
        w.assert_no_errors()


@case
def demo_mode_plays_the_pull():
    w, c = solo("Alice", class_file="PALADIN", guild_rank=0)
    c.eval("ns.DB:SetSetting('ui.sct.look', 'gilded'); ns.DB:SetSetting('ui.sct.on', true)")
    w.tick(0.5)
    c.slash("/dz demo on")
    w.tick(1)
    assert c.eval("return #ns.CombatTextUI.st.queue + #ns.CombatTextUI.st.sprites") > 0
    w.assert_no_errors()


@case
def edit_layout_has_the_three_spots_and_previews_the_pull():
    p = Pull("sigil")
    c = p.c
    for key in ("you", "target", "alerts"):
        assert c.eval("return ns.Layout:Item(...) ~= nil", "sct." + key) is True, key
        assert c.eval("return ns.Layout:Frame(...) ~= nil", "sct." + key) is True, key
    c.eval("ns.Layout:Item('sct.you').preview(true)")
    p.tick(14)
    assert c.eval("return ns.CombatTextUI.previewing") is True
    assert c.eval("return #ns.CombatTextUI.st.queue + #ns.CombatTextUI.st.sprites") > 0   # (again and again)
    c.eval("ns.Layout:Item('sct.you').preview(false)")
    assert c.eval("return #ns.CombatTextUI.st.sprites + #ns.CombatTextUI.st.queue") == 0
    p.w.assert_no_errors()


@case
def settings_ui_has_the_combat_text_card_with_try_it():
    w, c = solo("Alice", class_file="PALADIN", guild_rank=0)
    c.eval("ns.DB:SetSetting('ui.sct.look', 'flat')")
    c.slash("/dz settings")
    w.tick(0.5)
    VISIBLE = ("local o = {}; local function walk(f) for _, r in ipairs({ f:GetRegions() }) do "
               "if r.GetText and r:IsVisible() and r:GetText() then o[#o + 1] = r:GetText() end end; "
               "for _, k in ipairs({ f:GetChildren() }) do walk(k) end end; walk(UIParent); return o")
    # off (as it comes): its page is one box with Switch on and Try it, its switch in the head
    c.eval("ns.SettingsUI:SelectSection('look.sct')")      # (Settings > Interface > Looks > Combat text)
    w.tick(0.5)
    texts = c.eval_py(VISIBLE)
    for t in ("Combat text", "Combat text is off", "Switch on", "Try it"):
        assert t in texts, t
    assert "Where numbers go" not in texts
    c.eval("ns.DB:SetSetting('ui.sct.on', true); if ns.Popup then ns.Popup:HideAll() end; ns.SettingsUI:Refresh()")
    w.tick(0.5)
    texts = c.eval_py(VISIBLE)
    for t in ("Combat text", "Where numbers go", "Hide the game's numbers", "Try it", "More options"):
        assert t in texts, t
    for t in ("New bests", "Fight summary"):
        assert t not in texts, t
    w.assert_no_errors()


@case
def every_look_draws_each_event_kind():
    for look in LOOKS:
        p = Pull(look)
        c = p.c
        c.eval("local CT = ns.CombatTextUI; for _, row in ipairs({ { 0, 'out', 100, 'X' }, { 0, 'miss', nil, nil, nil, nil, "
               "{ what = 'Dodge', mine = true } }, { 0, 'lowhp', nil, nil, nil, nil, { pct = 20, mana = true } } }) do "
               "CT:Emit(CT.PullEvent(row)) end")
        c.eval("ns.CombatTextUI:QueuePull(false)")
        for _ in range(70):
            c.eval("ns.CombatTextUI:Tick(0.2)")
        p.w.assert_no_errors()


if __name__ == "__main__":
    run_all()
