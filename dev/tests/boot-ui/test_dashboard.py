"""The Home tab (UI/Dashboard.lua): the page the main window opens on.

Covers: Home is the default tab (and the fallback when a tab goes away), the "Open on: tab used last" setting,
empty states for a fresh raider, the greeting and the action chips (unanswered raid, empty BiS phase) that deep-link
into their tab (nothing to do shows no chips), the next raid's banner with one-click sign-up, my answer's pill and
its "can drop" line (picks of the raid's phase, filtered to its instance), the week's raids taking turns on the
banner (sliding on by themselves, held while the mouse is on it, picked by bar or arrow), the calendar
(planned raids, weekly ones beyond the Raids tab's two weeks, logged raids, the raids coming up; a day's raids open
in the Raids tab or the Raid log), recent loot (council: everyone's, raider: own), the readiness line in the
banner's foot for the council (not for a raider), and the countdown ticker / demo mode without Lua errors.

Run: luaenv\\Scripts\\python.exe tests\\boot-ui\\test_dashboard.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "raidplan"))

from _common import case, run_all, solo, no_errors, install_helpers, strip_codes  # noqa: E402
import rp_common as rp  # noqa: E402

DAY = 86400

# First usable candidate of a slot that drops in the given raid (ItemDB raid key).
PICK_FROM_RAID = """
local sid, raidKey, class = ...
for _, row in ipairs(ns.ItemDB:GetCandidates(sid, { class = class, usableOnly = true })) do
  for _, src in ipairs(ns.ItemDB:GetSources(row.itemID, "raids")) do
    if src.ref and src.ref.raid and src.ref.raid.key == raidKey and not src.via then return row.itemID end
  end
end
return nil"""


def selected(c):
    return c.eval("return ns.MainFrame:GetSelectedTab()")


def panel_texts(c):
    """Every visible text of the Home panel (codes stripped)."""
    lines = c.eval_py("""
      local out = {}
      local p = ns.Dashboard:GetPanel()
      if not p or not p:IsVisible() then return out end
      local function walk(f)
        for _, r in ipairs({ f:GetRegions() }) do
          if r.GetText and r:IsVisible() and r:GetText() and r:GetText() ~= "" then out[#out + 1] = r:GetText() end
        end
        for _, ch in ipairs({ f:GetChildren() }) do if ch:IsVisible() then walk(ch) end end
      end
      walk(p)
      return out""") or []
    return [strip_codes(l) for l in lines]


def has(c, text):
    return any(text in l for l in panel_texts(c))


def open_home(c):
    c.slash("/dz home")
    c.world.tick(0.5)
    assert selected(c) == "home", selected(c)


def chip(c, prefix):
    """The visible action chip whose text starts with prefix (frame handle) or None."""
    return c.eval("""
      local prefix = ...
      for _, ch in ipairs(ns.Dashboard:GetPanel().chips) do
        if ch:IsShown() and (ch.text:GetText() or ""):find(prefix, 1, true) then return ch end
      end
      return nil""", prefix)


def tip_lines(tip):
    """A tooltip's lines as plain text (a line may be { text, r, g, b })."""
    out = []
    for t in tip or []:
        if isinstance(t, (list, tuple)):
            t = t[0] if t else ""
        elif isinstance(t, dict):
            t = t.get(1, "")
        out.append(strip_codes(str(t)))
    return out


def banner(c):
    """The banner of the next raid: its texts and which answer controls show (codes stripped; None = hidden)."""
    b = c.eval_py("""
      local b = ns.Dashboard:GetPanel().banner.face
      local function t(fs) if fs:IsVisible() and (fs:GetText() or "") ~= "" then return fs:GetText() end end
      return { title = t(b.title), meta = t(b.meta), meter = t(b.meter), meterTip = b.meterHit.tip,
               accept = b.accept:IsShown(), tentative = b.tentative:IsShown(), more = b.more:IsShown(),
               ask = b.ask:IsShown(), pill = b.pill:IsShown() and b.pill.text:GetText() or nil,
               sub = b.pill:IsShown() and b.pill.sub:IsShown() and b.pill.sub:GetText() or nil,
               why = b.why:IsShown() and b.why.fs:GetText() or nil,
               ready = b.ready:IsShown() and b.ready.fs:GetText() or nil, readyTip = b.ready:IsShown() and b.ready.tip or nil,
               bis = b.bis:IsShown() and b.bis.fs:GetText() or nil }""") or {}
    for k in ("title", "meta", "meter", "pill", "sub", "why", "ready", "bis"):
        b[k] = strip_codes(b.get(k))
    for k in ("meterTip", "readyTip"):
        b[k] = tip_lines(b.get(k))
    for k in ("accept", "tentative", "more", "ask"):
        b[k] = bool(b.get(k))
    return b


def bis_line(c):
    """The banner's "picks that can drop here" line: (frame, [tooltip lines]) or (None, None) when hidden."""
    tip = c.eval_py("local f = ns.Dashboard:GetPanel().banner.face.bis; if f:IsShown() then return f.tip or {} end")
    if tip is None:
        return None, None
    return c.eval("return ns.Dashboard:GetPanel().banner.face.bis"), tip_lines(tip)


def answer_button(c, which):
    """The banner's answer control: "accept", "tentative", "more" or "pill" (my answer's pill)."""
    return c.eval("return ns.Dashboard:GetPanel().banner.face[...]", which)


def loot_rows(c):
    """The loot box's visible rows: ["item | who / why"] (codes stripped)."""
    out = c.eval_py("""
      local out = {}
      for _, r in ipairs(ns.Dashboard:GetPanel().lootCard.rows) do
        if r:IsShown() then out[#out + 1] = (r.l1:GetText() or "") .. " | " .. (r.l2:GetText() or "") end
      end
      return out""") or []
    return [strip_codes(t) for t in out]


def _rows(c, pool):
    out = c.eval_py("""
      local out = {}
      for _, r in ipairs(ns.Dashboard:GetPanel().calCard[...]) do
        if r:IsShown() then out[#out + 1] = (r.l1:GetText() or "") .. " | " .. (r.l2:GetText() or "") end
      end
      return out""", pool) or []
    return [strip_codes(t) for t in out]


def agenda(c):
    """The calendar's rows for the picked day: ["line 1 | line 2"] (codes stripped)."""
    return _rows(c, "agenda")


def coming(c):
    """The calendar's "Coming up" rows (the raids after the banner's, not on the picked day)."""
    return _rows(c, "coming")


def agenda_row(c, needle):
    """The calendar's visible row whose first line contains needle (codes stripped), or None."""
    return c.eval("""
      local s = ...
      for _, r in ipairs(ns.Dashboard:GetPanel().calCard.agenda) do
        local text = (r.l1:GetText() or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
        if r:IsShown() and text:find(s, 1, true) then return r end
      end""", needle)


def calendar(c):
    """{ title, day (the agenda's day title), today (the Today link shown), prev / next (the month arrows shown) }."""
    return c.eval_py("""
      local cc = ns.Dashboard:GetPanel().calCard
      return { title = cc.title:GetText(), day = cc.dayTitle:GetText(), today = cc.todayBtn:IsShown(),
               prev = cc.prevMonth:IsShown(), next = cc.nextMonth:IsShown() }""")


def pick_day(c, t):
    """Click the calendar day of server time t, paging months forward / back until it is in the shown month."""
    for _ in range(14):
        # (cell 15, in the grid's third week, is always a day of the shown month)
        cell = c.eval("""
          local key = tonumber(date("%Y%m%d", ...))
          local cc = ns.Dashboard:GetPanel().calCard
          if math.floor(cc.cells[15].key / 100) ~= math.floor(key / 100) then return nil end
          for _, cell in ipairs(cc.cells) do
            if cell.key == key then return cell end
          end""", t)
        if cell is not None:
            c.click(cell)
            c.world.tick(0.3)
            return
        later = c.eval("""local t = ...
          local first = ns.Dashboard:GetPanel().calCard.cells[15].key
          return tonumber(date("%Y%m", t)) > math.floor(first / 100)""", t)
        c.click(c.eval("return ns.Dashboard:GetPanel().calCard." + ("nextMonth" if later else "prevMonth")))
        c.world.tick(0.3)
    raise AssertionError("day not reached")


@case
def home_is_the_default_tab_with_empty_states():
    w, c = solo("Rai", guild_rank=3, tick=3, council=["Bob"], members=[("Bob", "MAGE", 3)])
    install_helpers(c)
    c.slash("/dz")
    w.tick(0.5)
    assert selected(c) == "home", selected(c)
    assert c.eval("return DisasterZoneMainFrame.Tabs[1].cdlKey") == "home"
    texts = panel_texts(c)
    cal = calendar(c)
    assert cal["day"].startswith("Today · ") and not cal["today"], cal
    assert cal["title"] == c.eval("return date('%B %Y', GetServerTime())"), cal
    assert agenda(c) == ["Nothing planned. | "], agenda(c)
    assert any("Nothing planned" in t for t in texts), texts
    assert banner(c)["title"] == "Nothing planned", banner(c)
    assert any("No loot awarded to you yet." in t for t in texts), texts
    assert coming(c) == [] and not any("Coming up" in t for t in texts), "no raids to come: no Coming up list"
    assert banner(c)["ready"] is None, "readiness is for the council / organizers"
    # the empty-phase chip opens My BiS on that phase
    ch = chip(c, "Pick your Phase 1 BiS")
    assert ch is not None, texts
    c.click(ch)
    w.tick(0.3)
    assert selected(c) == "mybis"
    # closing and reopening lands on Home again (default "Open on: Home")
    c.slash("/dz")
    c.slash("/dz")
    w.tick(0.3)
    assert selected(c) == "home"
    no_errors(w)


def greeting(c):
    """The greeting as read: "Good evening, " and the name (in its class colour) after it."""
    return strip_codes(c.eval("local p = ns.Dashboard:GetPanel(); "
                              "return (p.greeting:GetText() or '') .. (p.greetName:GetText() or '')"))


@case
def greeting_leads_the_strip_and_nothing_left_shows_no_chips():
    w, c = solo("Rai", guild_rank=3, tick=3)
    install_helpers(c)
    open_home(c)
    hour = c.eval("return tonumber(date('%H'))")
    part = "morning" if 5 <= hour < 12 else "afternoon" if 12 <= hour < 18 else "evening"
    assert greeting(c) == "Good %s, Rai" % part, greeting(c)
    # something to do: the chips follow the greeting and the name
    assert chip(c, "Pick your Phase 1 BiS") is not None
    state = c.eval_py("""
      local p = ns.Dashboard:GetPanel()
      local _, _, _, x = p.chips[1]:GetPoint(1)
      return { caught = p.allSet:IsShown(), x = x,
               w = p.greeting:GetStringWidth() + p.greetName:GetStringWidth() }""")
    assert not state["caught"], state
    assert state["x"] >= state["w"] + 10, state
    # one pick, the other slots off, the notes read: nothing left
    c.eval("""
      local class = select(2, UnitClass('player'))
      for sid = 2, ns.NUM_SLOTS or 17 do ns.BiS:SetSlotDisabled(1, sid, true) end
      ns.BiS:SetSlot(1, 1, 'main', ns.ItemDB:GetCandidates(1, { class = class, usableOnly = true })[1].itemID)
      ns.ChangelogUI:MarkRead()
      ns.Dashboard:Refresh()""")
    w.tick(0.3)
    p = "ns.Dashboard:GetPanel()"
    assert not any(c.eval("return %s.chips[...]:IsShown()" % p, i + 1)
                   for i in range(c.eval("return #%s.chips" % p))), panel_texts(c)
    # nothing to do says itself: the greeting alone, no "All caught up" line, no "+N more"
    assert not c.eval("return %s.allSet:IsShown() or %s.moreChips:IsShown()" % (p, p))
    assert not has(c, "All caught up"), panel_texts(c)
    assert greeting(c) == "Good %s, Rai" % part and has(c, "Good %s, " % part), panel_texts(c)
    no_errors(w)


@case
def open_on_last_tab_setting():
    w, c = solo("Rai", guild_rank=3, tick=3)
    c.eval("ns.DB:SetSetting('openOn', 'last')")
    c.slash("/dz bis")
    w.tick(0.3)
    c.slash("/dz")          # close
    c.slash("/dz")          # reopen on the tab used last
    w.tick(0.3)
    assert selected(c) == "mybis", selected(c)
    assert c.eval("return ns.db.settings.lastTab") == "mybis"
    c.eval("ns.DB:SetSetting('openOn', 'home')")
    c.slash("/dz")
    c.slash("/dz")
    w.tick(0.3)
    assert selected(c) == "home"
    no_errors(w)


def raid_world():
    """Gina = GM, Bob = council + raid leader, Lee / Rita / Sam = members. Bob plans Karazhan tomorrow for a team of
    Lee and Rita."""
    w, c = rp.world()
    bob = c["Bob"]
    tid = rp.team(bob, "Kara A", ["Lee", "Rita"])
    t = rp.now(bob) + DAY
    occ = rp.create(bob, i="kara", t=t, tm=[tid], sz=10)
    w.tick(2)
    return w, c, occ


@case
def next_raid_card_signs_up_and_lists_what_can_drop():
    w, c, occ = raid_world()
    lee = c["Lee"]
    install_helpers(lee)
    kara_item = lee.eval(PICK_FROM_RAID, 7, "Karazhan", "WARRIOR")       # hands
    gruul_item = lee.eval(PICK_FROM_RAID, 1, "GruulsLair", "WARRIOR")    # head
    assert kara_item and gruul_item, (kara_item, gruul_item)
    lee.eval("ns.BiS:SetSlot(1, 7, 'main', ...)", kara_item)
    lee.eval("ns.BiS:SetSlot(1, 1, 'main', ...)", gruul_item)
    w.tick(1)
    open_home(lee)
    texts = panel_texts(lee)
    b = banner(lee)
    assert b["title"] == "Karazhan" and b["meta"] == "10-player · Kara A", b
    assert b["meter"] == "No answers yet", b
    # no answer yet: the answer buttons, no pill
    assert b["accept"] and b["tentative"] and b["more"] and b["pill"] is None, b
    kara_name = lee.eval("return ns.ItemDB:GetName(...)", kara_item)
    gruul_name = lee.eval("return ns.ItemDB:GetName(...)", gruul_item)
    row, tip = bis_line(lee)
    assert row is not None, texts
    assert b["bis"] == "1 of your P1 picks can drop here", b
    assert tip[0] == "Your Phase 1 BiS picks that can drop in Karazhan", tip
    assert any(kara_name in t for t in tip), (kara_name, tip)
    assert not any(gruul_name in t for t in tip), "a Gruul pick is not listed for a Karazhan raid"
    assert chip(lee, "Sign up: ") is not None, texts
    assert "2 invited, no response" in b["meterTip"], b["meterTip"]
    # one click signs up
    lee.click(answer_button(lee, "accept"))
    w.tick(1)
    assert lee.eval_py("return ns.RaidPlan:GetMySignup(...)", occ)["st"] == "A"
    b = banner(lee)
    assert b["pill"] == "Accepted" and not b["accept"] and not b["tentative"], b
    assert b["meter"].endswith("1 of 10"), b
    assert any(t.startswith("1 accepted") for t in b["meterTip"]), b["meterTip"]
    assert chip(lee, "Sign up: ") is None, "the chip goes away once answered"
    # the banner opens the raid in the Raids tab
    lee.click(lee.eval("return ns.Dashboard:GetPanel().banner"))
    w.tick(0.5)
    assert selected(lee) == "raids"
    assert lee.eval("return ns.RaidPlanUI:GetSelectedRaid()") == occ
    w.assert_no_errors()


@case
def council_gets_readiness_and_everyones_loot_raider_only_their_own():
    w, c, occ = raid_world()
    bob, lee, rita = c["Bob"], c["Lee"], c["Rita"]
    rp.signup(lee, occ, "A")
    w.tick(1)
    item = bob.eval(PICK_FROM_RAID, 7, "Karazhan", "WARRIOR")
    bob.eval("ns.Ledger:Award(...)", item, rp.K("Lee"), "Karazhan:Attumen", None, None, "bis")
    w.tick(2)
    name = bob.eval("return ns.ItemDB:GetName(...)", item)
    open_home(bob)
    texts = panel_texts(bob)
    # the readiness: a short line in the banner's foot, only what's missing (Lee has no list, Rita hasn't answered)
    b = banner(bob)
    assert b["ready"] == "1 without a P1 list · 1 not answered", b
    tip = b["readyTip"]
    assert tip[tip.index("1 without a P1 list") + 1] == "Lee", tip
    assert tip[tip.index("1 not answered") + 1] == "Rita", tip
    assert any("Recent loot" in t for t in texts), texts
    assert ("%s | Lee · BiS" % name) in loot_rows(bob), loot_rows(bob)
    open_home(rita)
    texts = panel_texts(rita)
    assert banner(rita)["ready"] is None, "readiness is for the council / organizers"
    assert any("Your loot" in t for t in texts), texts
    assert not any(name in t for t in texts), "a raider doesn't see other players' loot"
    w.assert_no_errors()


AT_HOUR = """local days, hour = ...
local d = date("*t", GetServerTime() + days * 86400)
d.hour, d.min, d.sec = hour, 0, 0
return time(d)"""


def strip(c):
    """The banner carousel's strip: { shown, n (bars shown), at (the shown raid's bar), anim (sliding) }."""
    return c.eval_py("""
      local b = ns.Dashboard:GetPanel().banner
      local n = 0
      for _, s in ipairs(b.bars) do if s:IsShown() then n = n + 1 end end
      return { shown = b.strip:IsShown(), n = n, at = b.at, anim = b.anim ~= nil }""")


def strip_part(c, which, i=None):
    """A bar of the strip (which = "bar", i = 1..n) or one of its arrows ("prev" / "next")."""
    if which == "bar":
        return c.eval("return ns.Dashboard:GetPanel().banner.bars[...]", i)
    return c.eval("return ns.Dashboard:GetPanel().banner[...]", which)


@case
def the_weeks_raids_take_turns_on_the_banner():
    w, c = rp.world()
    bob, lee = c["Bob"], c["Lee"]
    tid = rp.team(bob, "Main", ["Lee", "Rita"])
    kara = rp.create(bob, i="kara", t=bob.eval(AT_HOUR, 1, 19), tm=[tid], sz=10)
    gruul = rp.create(bob, i="gruul", t=bob.eval(AT_HOUR, 1, 22), tm=[tid], sz=25)
    mag = rp.create(bob, i="mag", t=bob.eval(AT_HOUR, 3, 20), tm=[tid], sz=25)
    rp.create(bob, i="ssc", t=bob.eval(AT_HOUR, 9, 20), tm=[tid], sz=25)
    w.tick(2)
    install_helpers(lee)
    open_home(lee)
    s = strip(lee)
    assert s["shown"] and s["n"] == 3 and s["at"] == 1, s
    assert banner(lee)["title"] == "Karazhan", "the soonest raid is shown first"
    # the raid after the week is not on the banner: it is in the calendar's Coming up list
    up = coming(lee)
    assert len(up) == 1 and up[0].startswith("Serpentshrine Cavern | "), up
    # the next raid slides in by itself
    w.tick(9)
    s = strip(lee)
    assert s["at"] == 2 and not s["anim"], s
    assert banner(lee)["title"] == "Gruul's Lair", banner(lee)
    # ... but not while the mouse is on the banner
    lee.eval("ns.Dashboard:GetPanel().banner.IsMouseOver = function() return true end")
    w.tick(12)
    assert strip(lee)["at"] == 2, strip(lee)
    lee.eval("ns.Dashboard:GetPanel().banner.IsMouseOver = nil")
    # a bar shows its raid; answering there keeps it shown
    lee.click(strip_part(lee, "bar", 3))
    w.tick(1)
    assert banner(lee)["title"] == "Magtheridon's Lair", banner(lee)
    lee.click(answer_button(lee, "accept"))
    w.tick(1)
    assert lee.eval_py("return ns.RaidPlan:GetMySignup(...)", mag)["st"] == "A"
    assert lee.eval_py("return ns.RaidPlan:GetMySignup(...)", kara) is None
    b = banner(lee)
    assert b["title"] == "Magtheridon's Lair" and b["pill"] == "Accepted", b
    # the arrows wrap around: after the last raid comes the first, before the first the last
    lee.click(strip_part(lee, "next"))
    w.tick(1)
    assert strip(lee)["at"] == 1 and banner(lee)["title"] == "Karazhan", banner(lee)
    lee.click(strip_part(lee, "prev"))
    w.tick(1)
    assert strip(lee)["at"] == 3 and banner(lee)["title"] == "Magtheridon's Lair", banner(lee)
    # the shown raid is cancelled: back to the soonest
    rp.call(bob, "CancelRaid", mag)
    w.tick(2)
    lee.eval("ns.Dashboard:Refresh()")
    s = strip(lee)
    assert banner(lee)["title"] == "Karazhan" and s["n"] == 2 and s["at"] == 1, (banner(lee), s)
    # nothing left this week: the next raid alone, no strip
    rp.call(bob, "CancelRaid", kara)
    rp.call(bob, "CancelRaid", gruul)
    w.tick(2)
    lee.eval("ns.Dashboard:Refresh()")
    assert banner(lee)["title"] == "Serpentshrine Cavern", banner(lee)
    assert not strip(lee)["shown"], strip(lee)
    w.assert_no_errors()


@case
def bis_row_follows_the_raids_phase():
    w, c = rp.world()
    bob, lee = c["Bob"], c["Lee"]
    assert lee.eval("return ns.Guild:GetGuildPhase()") == 1
    tid = rp.team(bob, "Main", ["Lee"])
    rp.create(bob, i="ssc", t=rp.now(bob) + DAY, tm=[tid], sz=25)
    w.tick(2)
    install_helpers(lee)
    ssc_item = lee.eval(PICK_FROM_RAID, 7, "SerpentshrineCavern", "WARRIOR")
    kara_item = lee.eval(PICK_FROM_RAID, 7, "Karazhan", "WARRIOR")
    assert ssc_item and kara_item, (ssc_item, kara_item)
    lee.eval("ns.BiS:SetSlot(2, 7, 'main', ...)", ssc_item)
    lee.eval("ns.BiS:SetSlot(1, 7, 'main', ...)", kara_item)
    w.tick(1)
    open_home(lee)
    row, tip = bis_line(lee)
    assert row is not None, panel_texts(lee)
    assert banner(lee)["bis"] == "1 of your P2 picks can drop here", banner(lee)
    assert tip[0] == "Your Phase 2 BiS picks that can drop in Serpentshrine Cavern", tip
    ssc_name = lee.eval("return ns.ItemDB:GetName(...)", ssc_item)
    assert any(ssc_name in t for t in tip), (ssc_name, tip)
    assert chip(lee, "Pick your Phase") is None, "the Phase 2 list has a pick"
    # the row opens My BiS on the raid's phase
    lee.click(row)
    w.tick(0.3)
    assert selected(lee) == "mybis"
    assert lee.eval("return ns.MyBiS:GetPhase()") == 2
    w.assert_no_errors()


# A raid log record (ns.db.raids) of the raid that started `days_ago` days ago at this time, 3 hours long.
LOGGED = """local id, daysAgo = ...
local start = GetServerTime() - daysAgo * 86400
ns.db.raids[id] = { id = id, start = start, stop = start + 3 * 3600, zone = 'Karazhan', instID = 532,
                    bosses = { { enc = 652, name = 'Attumen' }, { enc = 653, name = 'Moroes' } }, att = {} }
ns:Fire('RAIDLOG_CHANGED', id)"""


@case
def calendar_shows_planned_and_logged_raids_and_opens_them():
    w, c = rp.world()
    bob, lee = c["Bob"], c["Lee"]
    tid = rp.team(bob, "Main", ["Lee", "Rita"])
    kara = rp.create(bob, i="kara", t=rp.now(bob) + DAY, tm=[tid], sz=10)
    t0 = rp.now(bob) + 2 * DAY
    rp.create(bob, i="ssc", t=t0, tm=[tid], sz=25, weekly=True)
    w.tick(2)
    for cl in (lee, bob):
        cl.eval(LOGGED, "logged", 20)
    install_helpers(lee)
    open_home(lee)
    # today has nothing: the next raid is the banner's, the raids after it are coming up; a click on its day shows it
    assert agenda(lee) == ["Nothing planned. | "], agenda(lee)
    assert banner(lee)["title"] == "Karazhan", banner(lee)
    up = coming(lee)
    assert up and all(r.startswith("Serpentshrine Cavern | ") for r in up), up
    pick_day(lee, rp.now(lee) + DAY)
    cal = calendar(lee)
    assert cal["day"].startswith("Tomorrow · ") and cal["today"], cal
    rows = agenda(lee)
    assert len(rows) == 1 and rows[0].startswith("Karazhan | ") and rows[0].endswith("Answer needed"), rows
    # a day's raid opens in the Raids tab
    lee.click(agenda_row(lee, "Karazhan"))
    w.tick(0.5)
    assert selected(lee) == "raids"
    assert lee.eval("return ns.RaidPlanUI:GetSelectedRaid()") == kara
    # weekly raids show every week, also past the Raids tab's two weeks, and open there too
    open_home(lee)
    far = t0 + 21 * DAY
    occ = lee.eval_py("local t = ...; return ns.RaidPlan:GetRaids(t - 3600, t + 3600, false, true)[1].id", far)
    assert not any(v["id"] == occ for v in rp.raids(lee)), "the Raids tab's own list stops two weeks ahead"
    pick_day(lee, far)
    rows = agenda(lee)
    assert len(rows) == 1 and rows[0].startswith("Serpentshrine Cavern | "), rows
    lee.click(agenda_row(lee, "Serpentshrine Cavern"))
    w.tick(0.5)
    assert lee.eval("return ns.RaidPlanUI:GetSelectedRaid()") == occ
    # a logged raid: the member sees how it went (no Raid log for them), the council opens it in the Raid log
    open_home(lee)
    lee.click(lee.eval("return ns.Dashboard:GetPanel().calCard.todayBtn"))
    w.tick(0.3)
    assert calendar(lee)["day"].startswith("Today · "), calendar(lee)
    pick_day(lee, rp.now(lee) - 20 * DAY)
    rows = agenda(lee)
    assert len(rows) == 1 and rows[0].startswith("Karazhan | ") and "bosses · 3h" in rows[0], rows
    assert lee.eval("return ns.Dashboard:GetPanel().calCard.agenda[1].onClick") is None
    install_helpers(bob)
    open_home(bob)
    pick_day(bob, rp.now(bob) - 20 * DAY)
    bob.click(agenda_row(bob, "Karazhan"))
    w.tick(0.5)
    assert selected(bob) == "raids"
    assert bob.eval("return ns.RaidsUI:GetView()") == "log"
    # the arrows stop a year back
    open_home(bob)
    for _ in range(12):
        bob.click(bob.eval("return ns.Dashboard:GetPanel().calCard.prevMonth"))
        w.tick(0.1)
    assert calendar(bob)["prev"] is False, calendar(bob)
    w.assert_no_errors()


@case
def a_crowded_day_ends_with_how_many_more():
    w, c = rp.world()
    bob, lee = c["Bob"], c["Lee"]
    # (the day's list has room for 7 rows: 9 raids leave 6 and a "+3 more" row)
    for hour in range(12, 21):
        rp.create(bob, i="kara", t=bob.eval(AT_HOUR, 2, hour), sz=10)
    w.tick(2)
    install_helpers(lee)
    open_home(lee)
    pick_day(lee, lee.eval(AT_HOUR, 2, 12))
    rows = agenda(lee)
    assert len(rows) == 7 and all(r.startswith("Karazhan | ") for r in rows[:6]), rows
    assert rows[6] == "+3 more | ", rows
    tip = lee.eval_py("return ns.Dashboard:GetPanel().calCard.agenda[7].tip")
    assert tip[0] == "More that day" and len(tip) == 4 and tip[1].startswith("18:00 Karazhan"), tip
    w.assert_no_errors()


@case
def nav_groups_pages_under_five_tabs():
    w, c = solo("Rai", guild_rank=3, tick=3, council=["Bob"], members=[("Bob", "MAGE", 3)])
    c.slash("/dz")
    w.tick(0.5)
    strip = c.eval_py("local o = {} for _, t in ipairs(DisasterZoneMainFrame.Tabs) do if t:IsShown() then "
                      "o[#o + 1] = t.cdlKey end end return o")
    assert strip == ["home", "grp:raids", "grp:gear", "dungeons", "grp:guild", "feedback", "changelog", "settings"], strip
    tab = "for _, t in ipairs(DisasterZoneMainFrame.Tabs) do if t.cdlKey == ... then return t end end"
    menu = "return ns.NavMenu:GetPages()"
    gear = c.eval(tab, "grp:gear")
    # resting the mouse on a group's tab opens the menu of its pages without changing the page
    c.eval("local t = ... t.IsMouseOver = function() return true end", gear)
    c.hover(gear)
    w.tick(0.3)
    assert selected(c) == "home", selected(c)
    assert c.eval_py(menu) == ["My BiS", "Gear sim", "Consumables", "Atlas"], c.eval_py(menu)
    # leaving the tab (and the menu) closes it after a moment
    c.eval("local t = ... t.IsMouseOver = nil", gear)
    c.leave(gear)
    w.tick(0.6)
    assert c.eval_py(menu) == [], c.eval_py(menu)
    # a click goes to the group's first page and closes the menu (a rest still pending doesn't open it after all)
    c.eval("local t = ... t.IsMouseOver = function() return true end", gear)
    c.hover(gear)
    w.tick(0.3)
    c.click(gear)
    w.tick(0.3)
    assert selected(c) == "mybis", selected(c)
    assert c.eval_py(menu) == [], c.eval_py(menu)
    c.leave(gear)
    c.hover(gear)
    c.click(gear)
    w.tick(0.3)
    assert c.eval_py(menu) == [], c.eval_py(menu)
    c.eval("ns.MainFrame:OpenGroupMenu('grp:gear')")
    assert c.eval_py(menu) == ["My BiS", "Gear sim", "Consumables", "Atlas"], c.eval_py(menu)
    # a spotlight: the list (the page shown now gold, the spotlit one with the bar), the page big on the right
    rows = c.eval_py("local f = ns.NavMenu:GetFrame() local o = {} for _, r in ipairs(f.rows) do if r:IsShown() then "
                     "o[#o + 1] = { r.page.key, r.bar:IsShown() } end end return o")
    assert rows == [["mybis", True], ["gearsim", False], ["consumables", False], ["atlas", False]], rows
    spot = "local s = ns.NavMenu:GetFrame().spot return { s.name:GetText(), s.line:GetText() }"
    assert c.eval_py(spot) == ["My BiS", "Your BiS lists and what you still need."], c.eval_py(spot)
    # the mouse on a row spotlights it; Atlas jumps straight into its shopping list
    c.eval("ns.NavMenu:Focus('atlas')")
    assert c.eval_py(spot)[0] == "Atlas"
    chips = c.eval_py("local o = {} for _, ch in ipairs(ns.NavMenu:GetFrame().spot.chips) do if ch:IsShown() then "
                      "o[#o + 1] = ch.fs:GetText() end end return o")
    assert chips == ["Shopping list"], chips
    c.eval("ns.NavMenu:GetFrame().spot.chips[1]:Click()")
    w.tick(0.3)
    assert selected(c) == "atlas" and c.eval_py(menu) == [], (selected(c), c.eval_py(menu))
    # the gold tie's fading lines end at the panel's corners (under Raids, near the window's edge, they ran out of it)
    raids = c.eval(tab, "grp:raids")
    c.eval("local t = ... t.IsMouseOver = function() return true end", raids)
    c.hover(raids)
    w.tick(0.3)
    tie = c.eval_py("local f = ns.NavMenu:GetFrame() local _, _, _, x = f.tie:GetPoint(1) "
                    "return { x, f.tieL:IsShown() and f.tieL:GetWidth() or 0, f.tieR:IsShown() and f.tieR:GetWidth() or 0, "
                    "f:GetWidth() }")
    x, lw, rw, pw = tie
    assert x - 22 - lw >= 0 and x + 22 + rw <= pw, tie
    c.eval("local t = ... t.IsMouseOver = nil", raids)
    c.eval("ns.NavMenu:Close()")
    c.eval("local t = ... t.IsMouseOver = nil", gear)
    c.eval("ns.NavMenu:Close()")
    # it remembers the page used last in it
    c.eval("ns.MainFrame:Open('atlas')")
    c.click(c.eval(tab, "home"))
    c.click(c.eval(tab, "grp:gear"))
    w.tick(0.3)
    assert selected(c) == "atlas", selected(c)
    assert c.eval("for _, t in ipairs(DisasterZoneMainFrame.Tabs) do if t.cdlKey == 'grp:gear' then "
                  "return t.active end end") is True
    c.eval("ns.NavMenu:Close()")
    # a page opened by key lights its group's tab
    c.eval("ns.MainFrame:Open('games')")
    assert c.eval("for _, t in ipairs(DisasterZoneMainFrame.Tabs) do if t.cdlKey == 'grp:guild' then "
                  "return t.active end end") is True
    no_errors(w)


@case
def ticker_and_demo_mode_run_clean():
    w, c = solo("Rai", guild_rank=3, tick=3)
    c.slash("/dz demo on")
    open_home(c)
    texts = panel_texts(c)
    assert any("Recent loot" in t for t in texts), "demo mode shows the council view of the loot"
    w.tick(65)       # two countdown refreshes
    c.slash("/dz demo off")
    w.tick(1)
    assert selected(c) == "home"
    no_errors(w)


if __name__ == "__main__":
    run_all()
