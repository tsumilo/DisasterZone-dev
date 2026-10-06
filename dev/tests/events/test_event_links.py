"""Events in the rest of the addon: share links (event:<occ>, edef:<id>, the events / season pages), the Home calendar
(dots and agenda rows), the player tooltip's title and season lines.
Run: luaenv\\Scripts\\python.exe tests\\events\\test_event_links.py [-k name]   (from dev)"""
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "boot-ui"))
from _common import World, Client, case, run_all  # noqa: E402

DAY = 86400


def strip_codes(s):
    return re.sub(r"\|T.-\|t|\|c[0-9a-fA-F]{8}|\|r", "", s or "")


def one(name="Gina", rank=0):
    w = World()
    c = Client(w, name, guild_rank=rank, class_file="ROGUE")
    c.load_addon()
    w.tick(3)
    return w, c


def scheduled(c, days=2):
    """A saved starter event and a calendar event of it `days` from now: def id, occ id, its start."""
    return c.eval_py("""
        local d = ns.Events:NewDef(true); d.name = 'Gina cup'; ns.Events:SaveDef(d)
        local at = GetServerTime() + ... * 86400
        local occ = ns.Events:Schedule(d.id, at, { where = 'Ring of Trials' })
        return { d.id, occ, at }""", days)


@case
def event_links_describe_open_and_come_back_as_the_current_place():
    w, c = one()
    def_id, occ, at = scheduled(c)
    ref = "event:" + occ
    assert c.eval("return ns.Share:EventRef(...)", occ) == ref
    d = c.eval_py("local d = ns.Share:Describe(...); return { d.known, d.label }", ref)
    assert d[0] is True and d[1].startswith("Gina cup · "), d
    token = c.eval("return ns.Share:Text(...)", ref)
    assert token.startswith("[DisasterZone: Gina cup · ") and token.endswith("#" + ref + "]"), token
    assert c.eval("return (ns.Share:Open(...))", ref) is True
    w.tick(0.3)
    assert c.eval("return ns.EventsUI:GetView()") == "event"
    assert c.eval("return ns.Share:CurrentRef()") == ref
    # the library's event opens in the builder
    dref = c.eval("return ns.Share:EventDefRef(...)", def_id)
    assert c.eval("return ns.Share:Describe(...).label", dref) == "Event: Gina cup"
    assert c.eval("return (ns.Share:Open(...))", dref) is True
    assert c.eval("return ns.EventBuilder:IsShown()")
    # pages
    c.eval("ns.EventBuilder:Close()")
    assert c.eval("return (ns.Share:Open('season'))") is True
    assert c.eval("return ns.EventsUI:GetView()") == "season"
    assert c.eval("return ns.Share:CurrentRef()") == "season"
    assert c.eval("return (ns.Share:Open('events'))") is True
    # unknown ones say so
    assert c.eval("return (ns.Share:Open('event:nope'))") is False
    assert c.eval("return ns.Share:Describe('edef:nope').known") is None
    w.assert_no_errors()


@case
def the_tooltip_of_an_event_link_says_when_who_hosts_and_the_sign_ups():
    w, c = one()
    _, occ, _ = scheduled(c)
    c.eval("ns.Events:SignUp(..., true)", occ)
    lines = c.eval_py("""
        local tt = CreateFrame('GameTooltip', 'DZLinkTip', UIParent, 'GameTooltipTemplate')
        tt:SetOwner(UIParent, 'ANCHOR_NONE')
        ns.Share:FillTooltip(tt, 'event:' .. ...)
        local out = {}
        for i = 1, tt:NumLines() do out[#out + 1] = _G['DZLinkTipTextLeft' .. i]:GetText() end
        return out""", occ)
    text = [strip_codes(t) for t in lines]
    assert text[0] == "Gina cup", text
    assert any(t.startswith("Hosted by Gina") for t in text), text
    assert "1 signed up" in text and "You're signed up" in text, text
    w.assert_no_errors()


@case
def the_home_calendar_shows_the_event_on_its_day():
    w, c = one()
    _, occ, at = scheduled(c, days=1)
    c.slash("/dz")
    w.tick(0.5)
    key = c.eval("return tonumber(date('%Y%m%d', ...))", at)
    cell = c.eval("""
        local key = ...
        for _, cell in ipairs(ns.Dashboard:GetPanel().calCard.cells) do if cell.key == key then return cell end end""", key)
    assert cell is not None
    dots = c.eval("local cell = ...; local n = 0; for _, d in ipairs(cell.dots) do if d:IsShown() then n = n + 1 end end; "
                  "return n", cell)
    assert dots == 1, dots
    c.click(cell)
    w.tick(0.3)
    rows = c.eval_py("""
        local out = {}
        for _, r in ipairs(ns.Dashboard:GetPanel().calCard.agenda) do
          if r:IsShown() then out[#out + 1] = (r.l1:GetText() or '') .. ' | ' .. (r.l2:GetText() or '') end
        end
        return out""")
    rows = [strip_codes(t) for t in rows]
    # (the host is signed up to their own event)
    assert len(rows) == 1 and rows[0].startswith("Gina cup | ") and rows[0].endswith("Gina · you're signed up"), rows
    # its thumbnail: the event's art, cropped (in game the row showed an empty box: the crop was lost)
    r = c.eval("for _, r in ipairs(ns.Dashboard:GetPanel().calCard.agenda) do if r:IsShown() then return r end end")
    thumb = c.eval_py("local r = ...; local l, t = r.thumb:GetTexCoord(); return { r.thumb:IsShown(), "
                      "r.thumb:GetTexture(), l, t }", r)
    assert thumb[0] is True and "LoadScreen" in thumb[1] and thumb[2] is not None and thumb[3] > 0.2, thumb
    # a click opens its page
    c.click(r)
    w.tick(0.3)
    assert c.eval("return ns.EventsUI:GetView()") == "event"
    w.assert_no_errors()


@case
def a_player_tooltip_shows_their_title_and_season():
    w, c = one()
    lines = c.eval_py("""
        local E = ns.Events
        E.GetTitle = function() return 'Duel Champion' end
        E.BadgesOf = function() return { {}, {}, {} } end
        E.RankOf = function() return 2 end
        local tt = CreateFrame('GameTooltip', 'DZUnitTip', UIParent, 'GameTooltipTemplate')
        tt:SetOwner(UIParent, 'ANCHOR_NONE')
        ns.Tooltip:AddEventLines(tt, 'Bert-Thunderstrike')
        local out = {}
        for i = 1, tt:NumLines() do out[#out + 1] = _G['DZUnitTipTextLeft' .. i]:GetText() end
        return out""")
    text = [strip_codes(t) for t in lines]
    season = c.eval("return ns.Events:GetSeason().n")
    assert text == ["Duel Champion", "DisasterZone events: #2 in %s · 3 badges" % season], text
    # nothing to say: no lines
    n = c.eval("""
        local E = ns.Events
        E.GetTitle = function() return nil end
        E.BadgesOf = function() return {} end
        E.RankOf = function() return nil end
        local tt = DZUnitTip
        tt:ClearLines()
        tt:SetOwner(UIParent, 'ANCHOR_NONE')
        return (ns.Tooltip:AddEventLines(tt, 'Bert-Thunderstrike')) and 1 or 0""")
    assert n == 0
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()
