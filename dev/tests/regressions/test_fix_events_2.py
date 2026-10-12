"""Regression cases for three Polls / Events look and text fixes of the 1.4 refactor (fix-events-2):

- the poll pop-up's kicker keeps the asker's class colour ("NEW POLL · FROM " + the name in its class colour, as
  1.3.5): UI:Toast capitalises the kicker around its colour escapes instead of over them
- the poll sheet's preview banner shows the question on up to two lines (banner opts.titleLines), not cut to one
- the event tracker's Whisper (the wait card) strips only my own realm: a player from another realm is whispered as
  Name-Realm

Run: luaenv\\Scripts\\python.exe tests\\regressions\\test_fix_events_2.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))

from _common import World, Client, case, run_all, solo, no_errors  # noqa: E402


@case
def toast_kicker_capitalises_around_a_colour_escape():
    w, c = solo("Gina", guild_rank=0, tick=2)
    out = c.eval_py("""
        local UI = ns.UI
        local t = UI:Toast({ key = "fe2", kicker = "New poll · from |cffa330c9Grumpykat|r", title = "Q?",
                             duration = 0, combat = false })
        t = t or UI:GetToast("fe2")
        local plain = UI:Toast({ key = "fe2b", kicker = "Answered · yes", title = "Q?", duration = 0, combat = false })
        plain = plain or UI:GetToast("fe2b")
        return { k = t and t.kick:GetText(), p = plain and plain.kick:GetText() }""")
    assert out["k"] == "NEW POLL · FROM |cffa330c9GRUMPYKAT|r", out
    assert out["p"] == "ANSWERED · YES", out
    no_errors(w)


@case
def the_poll_pop_up_names_the_asker_in_their_class_colour():
    w = World()
    g = Client(w, "Gina", guild_rank=0, class_file="WARLOCK")
    b = Client(w, "Brakka", guild_rank=3, class_file="MAGE")
    for c in (g, b):
        c.load_addon()
    w.tick(50)
    pid = g.eval("""
        local id, why = ns.Polls:Create({ q = "Pop-up?", k = "yn", a = { { "p", ... } }, cl = GetServerTime() + 3600,
                                          rv = "vote", ch = true, mx = 0 })
        return id or ("ERR " .. tostring(why))""", b.eval("return ns.Util.PlayerKey()"))
    assert pid and not str(pid).startswith("ERR"), pid
    w.tick(5)
    out = b.eval_py("""
        local p = ns.Polls:GetPoll(...)
        ns.PollsUI:ShowToast(p)
        local t = ns.PollsUI:GetToast()
        local r, g, bb = ns.UI:ClassColor(ns.EventUI:ClassOf(p.by))
        return { k = t and t.kick:GetText(),
                 hex = ("%02x%02x%02x"):format(math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5),
                                               math.floor(bb * 255 + 0.5)) }""", pid)
    assert out["k"] == "NEW POLL · FROM |cff" + out["hex"] + "GINA|r", out
    w.assert_no_errors()


@case
def a_banner_title_wraps_onto_title_lines():
    w, c = solo("Gina", guild_rank=0, tick=2)
    out = c.eval_py("""
        local UI = ns.UI
        local host = CreateFrame("Frame", nil, UIParent)
        host:SetSize(800, 600)
        local q = "Which nights can you raid SSC next week?"
        local b = UI:CreatePageBanner(host, { size = 66, width = 250, title = q, kicker = "Pick days",
                                             sub = "3 people asked", icon = 134400, titleLines = 2 })
        local one = UI:CreatePageBanner(host, { size = 66, width = 250, title = q, kicker = "Pick days",
                                               sub = "3 people asked", icon = 134400 })
        local short = UI:CreatePageBanner(host, { size = 66, width = 250, title = "Raid?", titleLines = 2 })
        local long = UI:CreatePageBanner(host, { size = 66, width = 250, titleLines = 2,
                                                title = string.rep("Which nights can you raid ", 6) })
        local function top(r) local _, _, _, _, y = r:GetPoint(1); return y end
        return { text = b.title:GetText(), h = b.title:GetHeight(), oneText = one.title:GetText(),
                 subBelow = top(b.sub) <= top(b.title) - b.title:GetHeight(),
                 subIn = -top(b.sub) + 11 <= 66,
                 shortText = short.title:GetText(), shortH = short.title:GetHeight(),
                 longText = long.title:GetText(), longH = long.title:GetHeight() }""")
    # two lines, the whole question; without titleLines the title is still cut to one line
    assert out["text"] == "Which nights can you raid SSC next week?" and out["h"] == 30, out
    assert out["oneText"].endswith("..."), out
    assert out["subBelow"] and out["subIn"], out
    assert out["shortText"] == "Raid?" and out["shortH"] == 15, out
    assert out["longText"].endswith("...") and out["longH"] == 30, out
    no_errors(w)


@case
def the_poll_preview_shows_the_whole_question():
    w, c = solo("Gina", guild_rank=0, tick=50)
    out = c.eval_py("""
        ns.MainFrame:Open("polls")
        ns.PollsUI:OpenNew()
        ns.PollsUI:SetDraft({ q = "Which nights can you raid SSC next week?", k = "days" })
        local v = ns.PollsUI:GetPanel().sheet
        local ban = v and v.pvBan
        return { text = ban and ban.title:GetText(), lines = ban and ban.opts.titleLines }""")
    assert out["text"] == "Which nights can you raid SSC next week?" and out["lines"] == 2, out
    no_errors(w)


@case
def the_tracker_whispers_a_player_from_another_realm_by_name_realm():
    w, c = solo("Gina", guild_rank=0, tick=2)
    out = c.eval_py("""
        local said = {}
        local real1, real2 = ChatFrame_OpenChat, ChatFrameUtil
        ChatFrameUtil = nil
        ChatFrame_OpenChat = function(text) said[#said + 1] = text end
        local me = ns.Util.PlayerKey()
        local own = ns.Util.GetPlayerRealm()
        local T = ns.EventTracker
        for _, opp in ipairs({ "Bob-OtherRealm", "Cora-" .. own }) do
            T:ShowWait("practice", {}, { noshow = 300 }, { a = me, b = opp })
            local f = _G.DisasterZoneEventWait
            f.wh:Click()
            f:Hide()
        end
        ChatFrame_OpenChat, ChatFrameUtil = real1, real2
        return said""")
    assert out == ["/w Bob-OtherRealm ", "/w Cora "], out
    no_errors(w)


if __name__ == "__main__":
    run_all()
