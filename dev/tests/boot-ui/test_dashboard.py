"""The Home tab (UI/Dashboard.lua): the page the main window opens on.

Covers: Home is the default tab (and the fallback when a tab goes away), the "Open on: tab used last" setting,
empty states for a fresh raider, action chips (unanswered raid, empty BiS phase) that deep-link into their tab,
the next-raid card with one-click sign-up, "can drop" picks filtered to the next raid's instance, recent loot
(council: everyone's, raider: own), the council readiness card vs the raider's later-raids card, and the countdown
ticker / demo mode without Lua errors.

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
    c.slash("/cdl home")
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


@case
def home_is_the_default_tab_with_empty_states():
    w, c = solo("Rai", guild_rank=3, tick=3, council=["Bob"], members=[("Bob", "MAGE", 3)])
    install_helpers(c)
    c.slash("/cdl")
    w.tick(0.5)
    assert selected(c) == "home", selected(c)
    assert c.eval("return CDLootMainFrame.Tabs[1].cdlKey") == "home"
    texts = panel_texts(c)
    assert any("Your BiS · Phase 1" in t for t in texts), texts
    assert any("No picks yet" in t for t in texts), texts
    assert any("Nothing planned" in t for t in texts), texts
    assert any("No loot awarded to you yet." in t for t in texts), texts
    assert any("Later raids" in t for t in texts), "a raider gets the later-raids card"
    assert not any("Raid readiness" in t for t in texts), "readiness is for the council / organizers"
    # the empty-phase chip opens My BiS on that phase
    ch = chip(c, "Pick your Phase 1 BiS")
    assert ch is not None, texts
    c.click(ch)
    w.tick(0.3)
    assert selected(c) == "mybis"
    # closing and reopening lands on Home again (default "Open on: Home")
    c.slash("/cdl")
    c.slash("/cdl")
    w.tick(0.3)
    assert selected(c) == "home"
    no_errors(w)


@case
def open_on_last_tab_setting():
    w, c = solo("Rai", guild_rank=3, tick=3)
    c.eval("ns.DB:SetSetting('openOn', 'last')")
    c.slash("/cdl bis")
    w.tick(0.3)
    c.slash("/cdl")          # close
    c.slash("/cdl")          # reopen on the tab used last
    w.tick(0.3)
    assert selected(c) == "mybis", selected(c)
    assert c.eval("return ns.db.settings.lastTab") == "mybis"
    c.eval("ns.DB:SetSetting('openOn', 'home')")
    c.slash("/cdl")
    c.slash("/cdl")
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
    assert any(t.startswith("Karazhan · ") for t in texts), texts
    assert any("Your answer: none yet" in t for t in texts), texts
    kara_name = lee.eval("return ns.ItemDB:GetName(...)", kara_item)
    gruul_name = lee.eval("return ns.ItemDB:GetName(...)", gruul_item)
    assert any("Can drop in Karazhan" in t for t in texts), texts
    assert any(kara_name in t for t in texts), (kara_name, texts)
    assert not any(gruul_name in t for t in texts), "a Gruul pick is not listed for a Karazhan raid"
    assert chip(lee, "Sign up: ") is not None, texts
    assert any("2 invited, no response" in t for t in texts), texts
    # one click signs up
    lee.click(lee.eval("return ns.Dashboard:GetPanel().raidCard.buttons[1]"))
    w.tick(1)
    assert lee.eval_py("return ns.RaidPlan:GetMySignup(...)", occ)["st"] == "A"
    texts = panel_texts(lee)
    assert any("Your answer: Accepted" in t for t in texts), texts
    assert any("1 accepted" in t for t in texts), texts
    assert chip(lee, "Sign up: ") is None, "the chip goes away once answered"
    # the card's link opens the raid in the Raids tab
    lee.click(lee.eval("return ns.Dashboard:GetPanel().raidCard.link"))
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
    assert any(t.startswith("Raid readiness · Karazhan") for t in texts), texts
    assert any("1 invited, no response" in t for t in texts), texts
    assert any("1 coming without a Phase 1 list" in t for t in texts), texts
    assert any("Recent loot" in t for t in texts), texts
    assert any(("Lee " + name) in t for t in texts), texts
    open_home(rita)
    texts = panel_texts(rita)
    assert any("Later raids" in t for t in texts), texts
    assert not any("Raid readiness" in t for t in texts), texts
    assert any("Your loot" in t for t in texts), texts
    assert not any(name in t for t in texts), "a raider doesn't see other players' loot"
    w.assert_no_errors()


AT_HOUR = """local days, hour = ...
local d = date("*t", GetServerTime() + days * 86400)
d.hour, d.min, d.sec = hour, 0, 0
return time(d)"""


def pills(c):
    """Visible day pills of the Next raid card: [text] (codes stripped)."""
    out = c.eval_py("""
      local out = {}
      for _, b in ipairs(ns.Dashboard:GetPanel().raidCard.pills) do
        if b:IsShown() then out[#out + 1] = b.text:GetText() end
      end
      return out""") or []
    return [strip_codes(t) for t in out]


def pill(c, text):
    return c.eval("""
      local s = ...
      for _, b in ipairs(ns.Dashboard:GetPanel().raidCard.pills) do
        if b:IsShown() and (b.text:GetText() or ""):find(s, 1, true) then return b end
      end""", text)


@case
def several_raids_on_one_day_get_pills():
    w, c = rp.world()
    bob, lee = c["Bob"], c["Lee"]
    tid = rp.team(bob, "Main", ["Lee", "Rita"])
    kara = rp.create(bob, i="kara", t=bob.eval(AT_HOUR, 1, 19), tm=[tid], sz=10)
    gruul = rp.create(bob, i="gruul", t=bob.eval(AT_HOUR, 1, 22), tm=[tid], sz=25)
    rp.create(bob, i="mag", t=bob.eval(AT_HOUR, 3, 20), tm=[tid], sz=25)
    w.tick(2)
    install_helpers(lee)
    open_home(lee)
    texts = panel_texts(lee)
    assert any(t.endswith("· 2 raids") for t in texts), texts
    assert any(t.startswith("Karazhan · ") for t in texts), "the soonest raid is shown first"
    ps = pills(lee)
    assert len(ps) == 2 and "19:00 Kara" in ps[0] and "22:00 Gruul" in ps[1], ps
    assert all(p.startswith("! ") for p in ps), "unanswered raids are marked"
    # the raid on another day is not a pill: it is in the later-raids card
    assert any("Magtheridon's Lair" in t for t in texts), texts
    # switch to Gruul and sign up for it only
    lee.click(pill(lee, "Gruul"))
    w.tick(0.3)
    assert any(t.startswith("Gruul's Lair · ") for t in panel_texts(lee)), panel_texts(lee)
    lee.click(lee.eval("return ns.Dashboard:GetPanel().raidCard.buttons[1]"))
    w.tick(1)
    assert lee.eval_py("return ns.RaidPlan:GetMySignup(...)", gruul)["st"] == "A"
    assert lee.eval_py("return ns.RaidPlan:GetMySignup(...)", kara) is None
    ps = pills(lee)
    assert ps[0].startswith("! ") and not ps[1].startswith("! "), ps
    assert any(t.startswith("Gruul's Lair · ") for t in panel_texts(lee)), "the picked raid stays shown"
    assert chip(lee, "Sign up: ") is not None, "Karazhan still needs an answer"
    # the picked raid is cancelled: back to the soonest, and no pills for a single raid
    rp.call(bob, "CancelRaid", gruul)
    w.tick(2)
    lee.eval("ns.Dashboard:Refresh()")
    assert any(t.startswith("Karazhan · ") for t in panel_texts(lee)), panel_texts(lee)
    assert pills(lee) == [], pills(lee)
    w.assert_no_errors()


@case
def ticker_and_demo_mode_run_clean():
    w, c = solo("Rai", guild_rank=3, tick=3)
    c.slash("/cdl demo on")
    open_home(c)
    texts = panel_texts(c)
    assert any("Recent loot" in t for t in texts), "demo mode shows the council view of the loot"
    w.tick(65)       # two countdown refreshes
    c.slash("/cdl demo off")
    w.tick(1)
    assert selected(c) == "home"
    no_errors(w)


if __name__ == "__main__":
    run_all()
