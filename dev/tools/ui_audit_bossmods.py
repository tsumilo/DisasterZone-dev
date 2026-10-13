"""Boss mods views for tools/ui_audit.py (UI/BossModUI.lua): the Try it Gruul pull (5 s countdown, then the fight)
frozen at a moment in each look, over Gruul's Lair's loading screen in a named box (AuditBMBox: ui_look crops to named
frames) the size of the mockup's stage, the four spots at their default places, as on the mockup
(claude.ai/artifact/66LY12B41hTyqt7e8GEXEM).
    "Boss mods - <look> <moment>"   moments: pull (the countdown at 3), slam (Ground Slam: the warning, the range
                                    frame crowded), cave (Cave In on you, the raid spreading), soon (Shatter's last
                                    seconds), growth (the stack warning)
    "Boss mods - <look> learn", "Boss mods - learn page [developer]", "Boss mods - learned pop-up [developer]":
                                    learning (UI/BossLearnUI.lua): see learn_states below
"""
import ui_audit_states as S

LOOKS = ("flat", "halo", "sigil", "slate", "gilded", "classic")
MOMENTS = (("pull", 2.6), ("growth", 5 + 3.4), ("slam", 5 + 7.4), ("cave", 5 + 11.0), ("soon", 5 + 13.8))

SETUP = ("ns.MainFrame:Close(); __MOCK.real_geometry = true; if ns.Popup then ns.Popup:HideAll() end; "
         "ns.DB:SetSetting('ui.bossmods.look', ...); "
         "local k = UIParent:GetHeight() / 540; "
         "local bx = _G.AuditBMBox or CreateFrame('Frame', 'AuditBMBox', UIParent); bx:SetFrameStrata('BACKGROUND'); "
         "bx:ClearAllPoints(); bx:SetPoint('TOP', UIParent, 'TOP', 0, 0); bx:SetSize(940 * k, 540 * k); "
         "if not bx.bg then bx.bg = bx:CreateTexture(nil, 'BACKGROUND'); bx.bg:SetAllPoints(bx); "
         "bx.bg:SetTexture(131842); bx.bg:SetTexCoord(19 / 2048, 1777 / 2048, 530 / 2048, 1540 / 2048); "
         "bx.dim = bx:CreateTexture(nil, 'BORDER'); bx.dim:SetAllPoints(bx); bx.dim:SetColorTexture(0.03, 0.02, 0.055, 0.6) end; "
         "bx:Show(); "
         # (the mock names every spell "Spell <id>" with a cog: Gruul's real names and icons, as the client gives them)
         "local N = { [36300] = { 'Growth', 136129 }, [33525] = { 'Ground Slam', 135237 }, [33654] = { 'Shatter', 132091 }, "
         "[36240] = { 'Cave In', 132153 }, [36297] = { 'Reverberation', 135925 }, [33813] = { 'Hurtful Strike', 136235 } }; "
         "if not __bmNames then __bmNames = true; local gsi, gst = GetSpellInfo, GetSpellTexture; "
         "GetSpellInfo = function(id, ...) local e = N[id]; if e then return e[1], nil, e[2] end; return gsi(id, ...) end; "
         "GetSpellTexture = function(id, ...) local e = N[id]; if e then return e[2] end; return gst(id, ...) end end; "
         "ns.BossModUI:Rescale(); ns.BossModUI:TryIt()")


def view(look, t):
    def fn(w, c):
        g = c["Gina"]
        S.demo_off(w, c)
        S.close_all(g)
        g.eval(SETUP, look)
        w.tick(t)
        g.eval("ns.BossModUI:Draw(0)")
        return g
    return fn


# (the renderer draws a scroll frame at its top: the cards above Boss mods are hidden for the picture)
ABOVE = ("local cv = ns.SettingsUI.CardVisible; if not __bmCV then __bmCV = cv; ns.SettingsUI.CardVisible = function(self, k) "
         "if k == 'meters' then return false end; return __bmCV(self, k) end end; ns.SettingsUI:LayoutCards(); ")


def settings(lua):
    return S.opened("settings", lua + "; " + ABOVE)


def _shift(g):
    # (the options hidden and the raid list laid out from the card's top: the renderer draws no scrolled content)
    g.eval("local SU = ns.SettingsUI; local sec = SU.sections.bossmods; for _, r in ipairs(sec.rows) do r:Hide() end; "
           "for _, d in ipairs({ sec:GetRegions() }) do if d.GetText then d:Hide() end end; "
           "sec.top = 8; SU:LayoutBossMods()")
    return g


def _states():
    return [("Boss mods - %s %s" % (look, m), view(look, t)) for look in LOOKS for m, t in MOMENTS] + [
        ("Settings - Boss mods", settings("ns.SettingsUI:SelectSection('bossmods')")),
        ("Settings - Boss mods on, Gruul open", settings("ns.DB:SetSetting('bossmods.on', true); "
                                                          "ns.SettingsUI:OpenBossMods('GruulsLair')")),
        ("Settings - Looks - Boss mods", settings("ns.SettingsUI:SelectSection('look.bossmods')")),
        # (the raid list under the options: the card moved up past them, as a scroll would)
        ("Settings - Boss mods raids", lambda w, c: _shift(settings("ns.DB:SetSetting('bossmods.on', true); "
                                                                   "ns.SettingsUI:OpenBossMods('GruulsLair')")(w, c))),
    ]


# ------------------------------------------------------------------------------------------------------------------
# Learning (Core/BossLearn.lua, UI/BossLearnUI.lua; mockup cleanup_template.html section 3): Try it's recording line
# and the learned band in each look, Gruul's page after seven pulls for a player and for the developer (Tsumil: the
# review), and the "what we learned" pop-up after a pull.
#   "Boss mods - <look> learn"            Try it as the fight starts: the line over the bars, Ground Slam's band
#   "Boss mods - learn page"              Settings > Boss mods > Gruul, as a player sees it
#   "Boss mods - learn page developer"    the same for Tsumil: the fixes to review on top, Cave In never fired
#   "Boss mods - learned pop-up"          the note after a pull (player), "... developer" with its review lines
# ------------------------------------------------------------------------------------------------------------------
LEARN_NAMES = ("local N = { [36240] = { 'Cave In', 132153 }, [36241] = { 'Cave In', 132153 }, [33525] = { 'Ground Slam', "
               "135237 }, [36300] = { 'Growth', 136129 }, [33654] = { 'Shatter', 132091 }, [33813] = { 'Hurtful Strike', "
               "136235 }, [36297] = { 'Reverberation', 135925 }, [33572] = { \"Gronn Lord's Grasp\", 136130 } }; "
               "if not __blNames then __blNames = true; local gsi, gst = GetSpellInfo, GetSpellTexture; "
               "GetSpellInfo = function(id, ...) local e = N[id]; if e then return e[1], nil, e[2] end; return gsi(id, ...) end; "
               "GetSpellTexture = function(id, ...) local e = N[id]; if e then return e[2] end; return gst(id, ...) end end")

LEARN_SEED = """
local BL = ns.BossLearn
local ds = BL.Plan(ns.BossMod:Mod('GruulsLair:Gruul')).ds
local now = GetServerTime()
local slams = { 34.2, 35.0, 36.8, 35.4, 34.9, 36.1, 35.7 }
for i = 1, 7 do
  local s = slams[i]
  BL:AddPull('GruulsLair:Gruul', { id = 'GruulsLair:Gruul|Gina-Thunderstrike|' .. (now - 86400 + i * 600),
    at = now - 86400 + i * 600, leader = 'Gina-Thunderstrike', dur = 240, kill = i > 4, clean = true, ds = ds,
    av = ns.version, from = 'me', src = 1,
    o = { growth = { 30.1, 60.2, 90.1, 120.3, 150.2 }, slam = { s, s + 74 }, shatter = { s + 10.1, s + 84.1 },
          hurtful = i <= 2 and { 50, 58.2, 66.1 } or nil, reverb = { 106 + i % 3, 140 + i % 4 } },
    g = { shatter = { s, s + 74 } }, nf = { 'cavein' },
    u = { { id = 36241, n = 4, t = 50, name = 'Cave In' }, { id = 33572, n = 30, t = 2, name = "Gronn Lord's Grasp" } },
    y = i <= 3 and { { t = 1, n = 1, text = 'Come... and die.', kind = 'yell' } } or nil })
end
BL:Relearn('GruulsLair:Gruul')
"""


def tsumil(w, c):
    t = c.get("Tsumil")
    if t is None:
        from harness import Client
        t = Client(w, "Tsumil", guild_rank=0, class_file="PALADIN", preload_lua=c["Gina"].preload_lua or "")
        t.load_addon()
        S.teach_names(t)
        c["Tsumil"] = t
        w.tick(2)
    return t


def learn_client(w, c, dev):
    S.demo_off(w, c)
    g = tsumil(w, c) if dev else c["Gina"]
    S.close_all(g)
    g.eval("ns.BossModUI:StopTry(); " + LEARN_NAMES + "; ns.DB:SetSetting('bossmods.on', true)")
    if not g.eval("return __learnSeeded"):
        g.eval(LEARN_SEED + "; __learnSeeded = true")
        w.tick(0.3)
    return g


def learn_page(dev):
    def fn(w, c):
        g = learn_client(w, c, dev)
        S.tab(g, "settings")
        w.tick(0.3)
        g.eval("ns.SettingsUI:OpenBossMods('GruulsLair'); ns.BossLearnUI:Open('GruulsLair:Gruul')")
        w.tick(0.3)
        return g
    return fn


REPORT = ("local dev = ...; ns.Notify:SetWants('bossLearned', 'popup', true); "
          "ns.BossLearnUI:OnReport({ boss = 'GruulsLair:Gruul', changes = { "
          "{ key = 'slam', field = 'start', from = { 34, 37 }, to = { 34, 36 }, src = { 33, 40 } }, "
          "{ key = 'reverb', field = 'cd', to = { 33, 35 }, src = { 31, 48 } } }, "
          "review = dev and ns.BossLearn:Suggestions('GruulsLair:Gruul') or {} })")


def learn_popup(dev):
    def fn(w, c):
        g = learn_client(w, c, dev)
        g.eval("ns.MainFrame:Close(); local t = _G.DisasterZoneNotifyToast; if t then t:Hide() end")
        g.eval(REPORT, dev)
        w.tick(0.5)
        return g
    return fn


def learn_view(look):
    def fn(w, c):
        g = view(look, 5 + 0.1)(w, c)
        g.eval("ns.BossModUI:Draw(0)")
        return g
    return fn


def learn_states():
    return [("Boss mods - %s learn" % look, learn_view(look)) for look in LOOKS] + [
        ("Boss mods - learn page", learn_page(False)),
        ("Boss mods - learn page developer", learn_page(True)),
        ("Boss mods - learned pop-up", learn_popup(False)),
        ("Boss mods - learned pop-up developer", learn_popup(True)),
    ]


def states():
    return _states() + learn_states()
