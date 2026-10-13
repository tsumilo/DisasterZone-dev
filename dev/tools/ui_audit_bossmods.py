"""Boss mods views for tools/ui_audit.py (UI/BossModUI.lua): the Try it Gruul pull (5 s countdown, then the fight)
frozen at a moment in each look, over Gruul's Lair's loading screen in a named box (AuditBMBox: ui_look crops to named
frames) the size of the mockup's stage, the four spots at their default places, as on the mockup
(claude.ai/artifact/66LY12B41hTyqt7e8GEXEM).
    "Boss mods - <look> <moment>"   moments: pull (the countdown at 3), slam (Ground Slam: the warning, the range
                                    frame crowded), cave (Cave In on you, the raid spreading), soon (Shatter's last
                                    seconds), growth (the stack warning)
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


# (Boss mods is a page of its own: Settings > Combat > Boss mods)
def settings(lua):
    return S.opened("settings", lua)


def _shift(g):
    # (the options hidden and the raid list laid out from the card's top: the renderer draws no scrolled content)
    g.eval("local SU = ns.SettingsUI; local sec = SU.sections.bossmods; for _, r in ipairs(sec.rows) do r:Hide() end; "
           "for _, d in ipairs({ sec:GetRegions() }) do if d.GetText then d:Hide() end end; "
           "if sec.fold then sec.fold:Hide() end; sec.top = 8; SU:LayoutBossMods()")
    return g


def states():
    return [("Boss mods - %s %s" % (look, m), view(look, t)) for look in LOOKS for m, t in MOMENTS] + [
        ("Settings - Boss mods", settings("ns.SettingsUI:SelectSection('bossmods')")),
        ("Settings - Boss mods on, Gruul open", settings("ns.DB:SetSetting('bossmods.on', true); "
                                                          "ns.SettingsUI:OpenBossMods('GruulsLair')")),
        ("Settings - Looks - Boss mods", settings("ns.SettingsUI:SelectSection('look.bossmods')")),
        # (the raid list under the options: the card moved up past them, as a scroll would)
        ("Settings - Boss mods raids", lambda w, c: _shift(settings("ns.DB:SetSetting('bossmods.on', true); "
                                                                   "ns.SettingsUI:OpenBossMods('GruulsLair')")(w, c))),
    ]
