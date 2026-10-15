#!/usr/bin/env python
"""Nameplates in the UI looks (UI/Plates.lua, UI/PlateLooks.lua): the mockup claude.ai/artifact/TxPbRME3GQ9ACQ88e74evf.

Covers: the game's own plates while the part wears Blizzard (as it comes); ours on every plate in a look (the
game's UnitFrame see-through, kept so when the game sets its alpha) and handed back when the look goes back to
Blizzard; every look drawing a plate with a cast, debuffs, a mark, the execute tick, as target and not; what a plate
reads (name, level ?? for bosses, health, mark, target, the others at 60%); casts (kickable or not, channels running
backwards, every caster or the target only); my debuffs only, the raid's armor and curse debuffs with the option;
threat (a tank's bar colours: mine, slipping, another main tank, lost; a damage dealer's glow in a group only, the
bar-for-everyone option, off); execute range for paladins; friendly players by name until hurt; stacking (the
game's CVar set out of combat, put back as it was); the demo (Try it, demo mode) in every look; Settings >
Interface > Looks > Nameplates with its sample, options and Try it.

Run: luaenv\\Scripts\\python.exe tests\\plates\\test_plates.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "boot-ui"))
sys.path.insert(0, os.path.join(HERE, "..", "..", "tools"))

from _common import case, run_all, solo  # noqa: E402

LOOKS = ("flat", "halo", "sigil", "slate", "gilded", "classic")


class Plates:
    """Alice (paladin) with nameplates in `look` and Blindeye the Seer's plate on screen."""

    def __init__(self, look="halo", cls="PALADIN", hammer=True, **opts):
        w, c = solo("Alice", class_file=cls, guild_rank=0)
        if hammer:
            c.eval("__MOCK.known_spells[27180] = true")       # Hammer of Wrath (rank 4)
        if look:
            c.eval("ns.DB:SetSetting('ui.plates.look', ...)", look)
        for k, v in opts.items():
            c.eval("ns.DB:SetSetting(...)", "ui.plates." + k, v)
        w.tick(0.3)
        self.w, self.c = w, c
        self.mob = w.spawn_npc(18836, "Blindeye the Seer")
        self.token = c.show_nameplate(self.mob)
        w.tick(0.2)

    def step(self, n=1, dt=0.05):
        for _ in range(n):
            self.c.eval("ns.Plates:Step(...)", dt)

    def p(self, key):
        return self.c.eval("local r = ns.Plates.recs[(...)]; return r and r.p[select(2, ...)]", self.token, key)

    def rec(self):
        return self.c.eval("return ns.Plates.recs[...] ~= nil", self.token)

    def game_alpha(self):
        return self.c.eval("return __MOCK.plate_frame(...).UnitFrame:GetAlpha()", self.token)

    def regions(self):
        return self.c.eval("local r = ns.Plates.recs[...]; if not r then return 0 end; local n = 0; "
                           "for _, k in ipairs({ 'fs', 'tx', 'ln', 'ic', 'cd' }) do n = n + r.host.shown[k] end; return n",
                           self.token)

    def cast(self, name, start=-1.0, length=3.0, kick=True, channel=False, icon=136243):
        self.c.eval("local now = GetTime() * 1000; __MOCK.npc_casts = __MOCK.npc_casts or {}; "
                    "__MOCK.npc_casts[...] = { select(2, ...), now + select(3, ...) * 1000, "
                    "now + (select(3, ...) + select(4, ...)) * 1000, 33152, not select(5, ...), select(7, ...), "
                    "channel = select(6, ...) }; ns.Plates.recs[select(8, ...)].dirty = true",
                    self.mob, name, start, length, kick, channel, icon, self.token)

    def debuffs(self, *auras):
        """auras: (name, spellId, caster, stacks)"""
        rows = []
        for a in auras:
            rows.append("{ '%s', %d, 20, GetTime() + 12, '%s', %d, 135978 }" % (a[0], a[1], a[2], a[3] if len(a) > 3 else 0))
        self.c.eval("__MOCK.unit_auras = __MOCK.unit_auras or {}; __MOCK.unit_auras['Blindeye the Seer'] = { %s }; "
                    "ns.Plates.recs[...].dirty = true" % ", ".join(rows), self.token)


# ------------------------------------------------------------------------------------------------------------------
@case
def the_games_plates_while_the_part_wears_blizzard():
    t = Plates(look=None)
    assert t.c.eval("return ns.Plates:IsOn()") is False
    assert not t.rec()
    assert t.game_alpha() == 1
    assert t.c.eval("return GetCVar('nameplateMotion')") == "0"
    t.w.assert_no_errors()


@case
def a_reused_piece_gets_its_cut_back():
    # (in game a piece that once drew a turned shape came back with the whole texture where a slice was asked for:
    # Halo's plates showed square ends; turning resets the cut in the client, and the mock does it too)
    w, c = solo("Alice", class_file="PALADIN", guild_rank=0)
    coords = c.eval_py("""local Pen = ns.CTPen; local h = Pen:Host(10); local out = {}
        local c = Pen:Begin(h, 0, 0); c:Img(Pen.WHITE, 0, 0, 6, 6, nil, 1, 0, 1, 0, 1, 0.7); Pen:End()
        for i = 1, 2 do
            c = Pen:Begin(h, 0, 0); c:Img(Pen.PEN .. 'pill', 3, 0, 6, 12, nil, 1, 0, 0.125, 0, 1); Pen:End()
            local a, b, _, _, e = h.tx[1]:GetTexCoord(); out[i] = { a, e }
        end
        return out""")
    for left, right in coords:
        assert left == 0 and abs(right - 0.125) < 1e-6, coords
    w.assert_no_errors()


@case
def ours_on_every_plate_and_the_games_handed_back():
    t = Plates("halo")
    assert t.rec()
    t.step(2)
    assert t.game_alpha() == 0
    assert t.regions() >= 4
    # (the game's mouse-over highlight ignores its parent's alpha: made to follow it while ours are on)
    hl = "return __MOCK.plate_frame(...).UnitFrame.selectionHighlight:IsIgnoringParentAlpha()"
    assert t.c.eval(hl, t.token) is False
    # (the game setting its plate's alpha again: kept see-through)
    t.c.eval("__MOCK.plate_frame(...).UnitFrame:SetAlpha(1)", t.token)
    assert t.game_alpha() == 0
    # (the game's plate hidden, and hidden again when the game shows it)
    shown = "return __MOCK.plate_frame(...).UnitFrame:IsShown()"
    assert t.c.eval(shown, t.token) is False
    t.c.eval("__MOCK.plate_frame(...).UnitFrame:Show()", t.token)
    assert t.c.eval(shown, t.token) is False
    assert t.c.eval("return GetCVar('nameplateMotion')") == "1"
    t.c.eval("ns.DB:SetSetting('ui.plates.look', 'blizzard')")
    t.w.tick(0.2)
    assert not t.rec()
    assert t.game_alpha() == 1
    assert t.c.eval("return GetCVar('nameplateMotion')") == "0"
    assert t.c.eval(hl, t.token) is True
    assert t.c.eval(shown, t.token) is True
    # a look for everything brings them back
    t.c.eval("ns.Look:UseEverywhere('sigil'); if ns.Popup then ns.Popup:HideAll() end")
    t.w.tick(0.2)
    assert t.rec()
    assert t.c.eval("return ns.Plates:LookKey()") == "sigil"
    t.c.hide_nameplate(t.mob)
    assert not t.rec()
    t.w.assert_no_errors()


@case
def every_look_draws_a_full_plate():
    for look in LOOKS:
        t = Plates(look)
        t.c.eval("__MOCK.npcs[...].hp = 15; __MOCK.set_marks({ [select(2, ...)] = 8 })", t.mob, t.mob)
        t.c.target_npc(t.mob)
        t.c.eval("__MOCK.npc_combat = { [...] = true }", t.mob)
        t.debuffs(("Judgement of the Crusader", 27159, "player"), ("Sunder Armor", 25225, "raid2", 5))
        t.cast("Prayer of Healing")
        t.step(3)
        assert t.regions() > 10, look
        assert t.p("target") is True
        assert t.p("execReady") is True, look
        # not the target, no cast: still drawn
        t.c.target_npc(None)
        t.c.eval("__MOCK.npc_casts = {}")
        t.step(3)
        assert t.regions() > 4, look
        t.w.assert_no_errors()


@case
def a_plate_reads_the_unit():
    t = Plates("flat")
    t.c.eval("__MOCK.npcs[...].hp = 62; __MOCK.npcs[...].level = -1; __MOCK.npc_class = { [...] = 'worldboss' }",
             t.mob, t.mob, t.mob)
    t.c.eval("__MOCK.set_marks({ [...] = 8 })", t.mob)
    t.step(2)
    assert t.p("name") == "Blindeye the Seer"
    assert t.p("lvl") == "??"
    assert t.p("boss") is True
    assert abs(t.p("hpTarget") - 0.62) < 0.001
    assert t.p("mark") == 8
    assert t.p("target") is False and t.p("dim") is False       # (no target: every plate full)
    other = t.w.spawn_npc(18835, "Kiggler the Crazed")
    t.c.show_nameplate(other)
    t.c.target_npc(other)
    t.step(2)
    assert t.p("dim") is True
    t.c.eval("ns.DB:SetSetting('ui.plates.dim', false)")
    t.w.tick(0.1)
    t.step(2)
    assert t.p("dim") is False
    t.w.assert_no_errors()


@case
def the_health_bar_slides_and_the_hit_lingers():
    t = Plates("flat")
    t.w.tick(0.2)
    assert t.p("hp") == 1 and t.p("trail") is None
    t.c.eval("__MOCK.npcs[...].hp = 60; ns.Plates:MarkAll()", t.mob)
    t.w.tick(0.04)
    hp, trail = t.p("hp"), t.p("trail")
    assert 0.6 < hp < 1 and trail is not None and trail > hp          # (sliding, the chunk behind it)
    [t.w.tick(0.03) for _ in range(10)]
    assert abs(t.p("hp") - 0.6) < 0.01                                # (the bar there within a third of a second)
    assert t.p("trail") is not None and t.p("trail") > 0.9            # (the chunk still held)
    [t.w.tick(0.03) for _ in range(50)]
    assert t.p("trail") is None                                       # (then drained)
    # off: the bar jumps
    t.c.eval("ns.DB:SetSetting('ui.plates.animate', false)")
    t.w.tick(0.1)
    t.c.eval("__MOCK.npcs[...].hp = 30; ns.Plates:MarkAll()", t.mob)
    t.w.tick(0.04)
    assert abs(t.p("hp") - 0.3) < 0.001 and t.p("trail") is None
    t.w.assert_no_errors()


@case
def casts_kickable_or_not_and_channels_run_backwards():
    t = Plates("sigil")
    t.cast("Prayer of Healing", start=-1.0, length=4.0, kick=True)
    t.step(2)
    cast = t.c.eval_py("local p = ns.Plates.recs[...].p; return p.cast", t.token)
    assert cast["spell"] == "Prayer of Healing" and cast["kick"] is True
    assert 0.2 < cast["prog"] < 0.3, cast
    t.cast("Whirlwind", start=-5.0, length=15.0, kick=False, channel=True)
    t.step(2)
    cast = t.c.eval_py("local p = ns.Plates.recs[...].p; return p.cast", t.token)
    assert cast["spell"] == "Whirlwind" and cast["kick"] is False
    assert 0.6 < cast["prog"] < 0.7, cast                 # (a channel: 5 s of 15 gone, two thirds left)
    # target only: a caster that isn't the target shows none
    t.c.eval("ns.DB:SetSetting('ui.plates.casts', 'target')")
    t.w.tick(0.1)
    t.step(2)
    assert t.c.eval("return ns.Plates.recs[...].p.cast == nil", t.token)
    t.w.assert_no_errors()


@case
def my_debuffs_and_the_raids_with_the_option():
    t = Plates("halo")
    t.debuffs(("Judgement of the Crusader", 27159, "player"), ("Sunder Armor", 25225, "raid2", 5),
              ("Corruption", 27216, "raid3"))
    t.step(2)
    auras = t.c.eval_py("return ns.Plates.recs[...].p.auras", t.token)
    assert len(auras) == 1 and auras[0]["mine"] is True
    assert 11 < auras[0]["left"] <= 12
    t.c.eval("ns.DB:SetSetting('ui.plates.raidDebuffs', true)")
    t.w.tick(0.1)
    t.step(2)
    auras = t.c.eval_py("return ns.Plates.recs[...].p.auras", t.token)
    assert len(auras) == 2 and auras[0]["mine"] is True and auras[1]["stacks"] == 5   # (Corruption isn't a raid one)
    t.w.assert_no_errors()


@case
def threat_bar_colours_for_tanks_glow_for_the_others():
    t = Plates("flat")
    t.c.eval("__MOCK.npc_combat = { [...] = true }", t.mob)
    # a tank: holding it securely, then slipping
    t.c.eval("ns.DB:SetSetting('bossmods.role', 'tank'); __MOCK.threat = { Alice = { true, 3, 100, 100, 5000 } }; "
             "ns.Plates:MarkAll()")
    t.step(2)
    assert t.p("threat") == "mine"
    assert t.c.eval("return ns.Plates.recs[...].p.col == ns.Plates.TH.mine", t.token)
    t.c.eval("__MOCK.threat = { Alice = { true, 2, 100, 100, 5000 } }; ns.Plates:MarkAll()")
    t.step(2)
    assert t.p("threat") == "slip"
    # not on me, and no main tank has it: lost
    t.c.eval("__MOCK.threat = {}; ns.Plates:MarkAll()")
    t.step(2)
    assert t.p("threat") in ("lost", None)
    # damage: solo nothing glows; in a group 92% glows orange, tanking red
    t.c.eval("ns.DB:SetSetting('bossmods.role', 'dps'); __MOCK.threat = { Alice = { false, 1, 92, 92, 4000 } }")
    t.w.tick(0.1)
    t.step(2)
    assert t.p("glow") is None
    t.c.eval("IsInGroup = function() return true end")
    t.c.eval("ns.Plates:MarkAll()")
    t.step(2)
    assert t.p("threat") == "near"
    assert t.c.eval("return ns.Plates.recs[...].p.glow == ns.Plates.GLOW.near", t.token)
    t.c.eval("__MOCK.threat = { Alice = { true, 3, 100, 100, 5000 } }; ns.Plates:MarkAll()")
    t.step(2)
    assert t.p("threat") == "aggro"
    # bar colours for everyone
    t.c.eval("ns.DB:SetSetting('ui.plates.threat', 'bar')")
    t.w.tick(0.1)
    t.step(2)
    assert t.p("glow") is None
    assert t.c.eval("return ns.Plates.recs[...].p.col == ns.Plates.TH.lost", t.token)
    t.c.eval("ns.DB:SetSetting('ui.plates.threat', 'off')")
    t.w.tick(0.1)
    t.step(2)
    assert t.p("threat") is None
    t.w.assert_no_errors()


@case
def execute_range_only_for_classes_with_a_finisher():
    t = Plates("gilded")
    t.c.eval("__MOCK.npcs[...].hp = 25", t.mob)
    t.step(2)
    assert t.p("exec") is None                              # (out of a fight: no tick)
    t.c.eval("__MOCK.npc_combat = { [...] = true }; ns.Plates:MarkAll()", t.mob)
    t.step(2)
    assert t.p("exec") == 0.2 and t.p("execReady") is False
    t.c.eval("__MOCK.npcs[...].hp = 19; ns.Plates:MarkAll()", t.mob)
    t.step(2)
    assert t.p("execReady") is True
    t.c.eval("ns.DB:SetSetting('ui.plates.execute', false)")
    t.w.tick(0.1)
    t.step(2)
    assert t.p("exec") is None
    m = Plates("gilded", cls="MAGE")
    m.step(2)
    assert m.p("exec") is None
    t.w.assert_no_errors()


@case
def execute_range_waits_for_the_finisher_to_be_learned():
    t = Plates("gilded", hammer=False)                      # a paladin under 44: no Hammer of Wrath yet
    t.c.eval("__MOCK.npcs[...].hp = 15; __MOCK.npc_combat = { [...] = true }; ns.Plates:MarkAll()", t.mob)
    t.step(2)
    assert t.p("exec") is None and t.p("execReady") is False
    t.c.eval("__MOCK.known_spells[24275] = true; __MOCK.fire('SPELLS_CHANGED')")   # learns rank 1
    t.step(2)
    assert t.p("exec") == 0.2 and t.p("execReady") is True
    t.w.assert_no_errors()


@case
def friendly_players_by_name_until_hurt():
    t = Plates("halo")
    p = t.c.eval_py("return ns.Plates:Read('player', {}, 'halo')")
    assert p["friend"] is True and p["nameOnly"] is True
    t.c.eval("__MOCK.player_hp = 60")
    p = t.c.eval_py("return ns.Plates:Read('player', {}, 'halo')")
    assert p["nameOnly"] is False
    t.c.eval("__MOCK.player_hp = nil; ns.DB:SetSetting('ui.plates.friendly', 'full')")
    p = t.c.eval_py("return ns.Plates:Read('player', {}, 'halo')")
    assert p["nameOnly"] is False
    t.w.assert_no_errors()


@case
def stacking_set_out_of_combat_and_put_back():
    w, c = solo("Alice", class_file="PALADIN", guild_rank=0)
    c.eval("SetCVar('nameplateMotion', '0')")
    c.set_combat(True)
    c.eval("ns.DB:SetSetting('ui.plates.look', 'flat')")
    w.tick(0.2)
    assert c.eval("return GetCVar('nameplateMotion')") == "0"            # (can't change in combat: waits)
    c.set_combat(False)
    w.tick(0.2)
    assert c.eval("return GetCVar('nameplateMotion')") == "1"
    c.eval("ns.DB:SetSetting('ui.plates.stack', false)")
    w.tick(0.2)
    assert c.eval("return GetCVar('nameplateMotion')") == "0"
    w.assert_no_errors()


@case
def the_demo_in_every_look():
    w, c = solo("Alice", class_file="PALADIN", guild_rank=0)
    for look in LOOKS + ("blizzard",):
        c.eval("ns.DB:SetSetting('ui.plates.look', ...)", look)
        w.tick(0.1)
        assert c.eval("return ns.Plates:TryIt()") is True
        w.tick(6)
        w.tick(5)
        assert c.eval("return ns.Plates:DemoRunning()") is True
        w.tick(5)
        assert c.eval("return ns.Plates:DemoRunning()") is False
    c.eval("ns:Fire('DEMO_TOGGLED', true)")
    w.tick(1)
    assert c.eval("return ns.Plates:DemoRunning()") is True
    c.eval("ns:Fire('DEMO_TOGGLED', false)")
    assert c.eval("return ns.Plates:DemoRunning()") is False
    w.assert_no_errors()


@case
def settings_has_the_nameplates_page():
    w, c = solo("Alice", class_file="PALADIN", guild_rank=0)
    c.eval("ns.DB:SetSetting('ui.plates.look', 'halo')")
    c.slash("/dz settings")
    w.tick(0.5)
    VISIBLE = ("local o = {}; local function walk(f) for _, r in ipairs({ f:GetRegions() }) do "
               "if r.GetText and r:IsVisible() and r:GetText() then o[#o + 1] = r:GetText() end end; "
               "for _, k in ipairs({ f:GetChildren() }) do walk(k) end end; walk(UIParent); return o")
    c.eval("ns.SettingsUI:SelectSection('look.plates')")
    w.tick(0.5)
    texts = c.eval_py(VISIBLE)
    for t in ("Nameplates", "Threat", "Friendly players", "Animated health", "Try it", "More options"):
        assert t in texts, t
    for look in LOOKS:
        c.eval("ns.DB:SetSetting('ui.plates.look', ...); ns.SettingsUI:Refresh()", look)
        w.tick(0.2)
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()
