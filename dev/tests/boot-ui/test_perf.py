"""Performance sanity: council refresh (roster / items / member) with demo data and with 60 extra cached lists
(Store:Put path, then a relog so they come from SavedVariables), refresh coalescing during a sync burst, the
wanted-item index rebuild, and the tooltip hook cost (cached / uncached, raider / council).

Times are wall-clock (time.perf_counter around one Lua loop of n calls; the mock's os.clock is virtual). The mock builds a frame for EVERY scroll-list row (WoW
only builds the visible ~20), so row-heavy numbers are pessimistic. Limits flag pathological behaviour only.

Run: luaenv\\Scripts\\python.exe tests\\boot-ui\\test_perf.py
"""
import time

from _common import case, run_all, solo, no_errors, World, Client, install_helpers, seed_guild_council


def timed(c, n, code, *args):
    """ms per iteration of T_time(n, fn) run inside Lua (code must evaluate T_time(n, ...))."""
    t0 = time.perf_counter()
    c.eval(code, *args)
    return (time.perf_counter() - t0) * 1000.0 / n

LIMIT_MS = {
    "roster": 250.0, "items": 250.0, "member": 120.0,
    "tooltip_uncached": 10.0, "tooltip_cached": 2.0, "index_rebuild": 150.0,
}

TIMER_LUA = r"""
function T_time(n, fn)
  for i = 1, n do fn(i) end
end
"""

LIST_LUA = r"""
function T_make_list(klass, seed)
  local specs = ns.SPECS[klass]
  local data = { v = 1, cl = klass, sp = specs[(seed % #specs) + 1].label, ph = {}, ob = {}, eq = {} }
  for p = 1, 5 do
    local slots = {}
    for sid = 1, 17 do
      local c = ns.ItemDB:GetCandidates(sid, { maxPhase = p, class = klass, usableOnly = true, primaryArmorOnly = true })
      if #c > 0 then
        local i = ((seed * 7 + sid * 3 + p) % #c) + 1
        local a = ((seed * 5 + sid + p * 2) % #c) + 1
        slots[sid] = { c[i].itemID, (a ~= i) and c[a].itemID or 0 }
      end
    end
    data.ph[p] = slots
  end
  local ob = {}
  for sid = 1, 6 do local s = data.ph[1][sid]; if s then ob[#ob + 1] = s[1] end end
  table.sort(ob)
  local uniq = {}
  for _, id in ipairs(ob) do if uniq[#uniq] ~= id then uniq[#uniq + 1] = id end end
  data.ob = uniq
  for sid = 1, 17 do local s = data.ph[1][sid]; if s then data.eq[sid] = s[1] end end
  return data
end
"""

results = {}


def measure_views(c, label, n=5):
    out = {}
    for view in ("roster", "items", "member"):
        c.eval("ns.CouncilUI:SetView(...)", view)
        c.world.tick(0.3)
        out[view] = timed(c, n, "T_time(..., function() ns.CouncilUI:Refresh() end)", n)
    results[label] = out
    print("    %-28s roster %.1f ms, items %.1f ms, member %.1f ms" % (label, out["roster"], out["items"], out["member"]))
    return out


def check_limits(out, label):
    bad = ["%s %s %.1f ms > %.0f ms" % (label, k, v, LIMIT_MS[k]) for k, v in out.items() if v > LIMIT_MS[k]]
    assert not bad, bad


@case
def council_refresh_with_demo_data():
    w, c = solo("Alice", guild_rank=3, tick=3)
    install_helpers(c)
    c.eval(TIMER_LUA)
    c.slash("/dz demo on")
    c.slash("/dz council")
    w.tick(0.5)
    out = measure_views(c, "demo (19 lists)")
    check_limits(out, "demo")
    no_errors(w)


def big_guild(n=60):
    w = World()
    seed_guild_council(w, ["Cou"])          # Addendum E: Cou is on the GM's guild council list
    classes = ["WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID"]
    members = [w.add_offline_member("Mem%02d" % i, classes[i % 9], 3) for i in range(n)]
    c = Client(w, "Cou", guild_rank=1, class_file="PRIEST")
    c.load_addon()
    w.tick(3)
    install_helpers(c)
    c.eval(TIMER_LUA)
    c.eval(LIST_LUA)
    return w, c, members


@case
def council_refresh_with_60_cached_lists_after_relog():
    w, c, members = big_guild(60)
    c.slash("/dz council")
    w.tick(0.5)
    # count refreshes during a burst of 60 incoming lists while the panel is visible
    c.eval("__REFRESHES = 0; local orig = ns.CouncilUI.Refresh; ns.CouncilUI.Refresh = function(...) __REFRESHES = __REFRESHES + 1; return orig(...) end")
    t0 = time.perf_counter()
    c.eval("""
      local keys = ...
      for i, k in ipairs(keys) do
        local cl = ns.Guild:GetClass(k)
        local d = T_make_list(cl, i)
        assert(ns.Store:Put(k, { r = 1, ts = GetServerTime() - i * 3600, h = ns.Util.Hash(d), d = d }, 'direct'))
      end""", [m.full_name for m in members])
    put_ms = (time.perf_counter() - t0) * 1000
    w.tick(1)
    refreshes = c.eval("return __REFRESHES")
    print("    60 Store:Put (build+hash+validate+copy): %.0f ms total; council refreshes during the burst: %d" % (put_ms, refreshes))
    assert refreshes <= 3, "refresh not coalesced: %d refreshes for 60 LIST_UPDATED" % refreshes
    assert c.eval("return #T_data(DisasterZoneCouncilPanel.rosterView.list.box)") == 61
    # SavedVariables round trip: the 60 lists come back from DisasterZoneDB
    c.relog()
    w.tick(3)
    install_helpers(c)
    c.eval(TIMER_LUA)
    assert c.eval("local n = 0 for _ in pairs(DisasterZoneDB.lists) do n = n + 1 end return n") == 60
    c.slash("/dz council")
    w.tick(0.5)
    assert c.eval("return #T_data(DisasterZoneCouncilPanel.rosterView.list.box)") == 61
    out = measure_views(c, "real (61 lists)")
    # wanted-item index rebuild after one LIST_UPDATED + a lookup of a popular item
    idx = timed(c, 5, """T_time(5, function()
        ns:Fire('LIST_UPDATED', 'Mem00-Thunderstrike')
        ns.Store:GetWanters(32385, { includeObtained = true })
      end)""")
    out2 = {"index_rebuild": idx}
    print("    index rebuild + GetWanters(Magtheridon's Head): %.1f ms" % idx)
    check_limits(out, "61 lists")
    check_limits(out2, "61 lists")
    no_errors(w)


@case
def tooltip_hook_cost():
    w, c, members = big_guild(60)
    for i, m in enumerate(members):
        c.eval("local k, cl, i = ...; local d = T_make_list(cl, i); ns.Store:Put(k, { r = 1, ts = GetServerTime(), h = ns.Util.Hash(d), d = d }, 'direct')",
               m.full_name, m.class_file, i)
    ids = c.eval_py("""
      local o = {}
      for _, raid in ipairs(ns.ItemDB:GetRaids()) do
        for _, boss in ipairs(raid.bosses) do
          for _, id in ipairs(boss.items) do o[#o + 1] = id end
        end
      end
      return o""")
    ids = ids[:300]
    c.eval("GameTooltip:SetOwner(UIParent, 'ANCHOR_NONE'); ns.DB:SetSetting('tooltip.enabled', false)")
    base = timed(c, len(ids), """
      local ids = ...
      T_time(#ids, function(i) GameTooltip:SetItemByID(ids[i]) end)""", ids)
    c.eval("ns.DB:SetSetting('tooltip.enabled', true)")
    uncached = timed(c, len(ids), """
      local ids = ...
      T_time(#ids, function(i) ns.Tooltip:Invalidate(); GameTooltip:SetItemByID(ids[i]) end)""", ids)
    c.eval("local ids = ...; for i = 1, #ids do GameTooltip:SetItemByID(ids[i]) end", ids)
    cached = timed(c, len(ids), """
      local ids = ...
      T_time(#ids, function(i) GameTooltip:SetItemByID(ids[i]) end)""", ids)
    lines = c.show_tooltip_item(32385)
    assert any("wanted by" in (l or "") for l, _ in lines), lines
    over_unc, over_c = max(0.0, uncached - base), max(0.0, cached - base)
    print("    tooltip (council, 61 lists): plain %.3f ms, +DisasterZone uncached %.3f ms, cached %.3f ms per SetItemByID"
          % (base, over_unc, over_c))
    results["tooltip"] = (base, over_unc, over_c)
    assert over_unc <= LIMIT_MS["tooltip_uncached"], over_unc
    assert over_c <= LIMIT_MS["tooltip_cached"], over_c
    # a raider (no council lines) is cheaper still
    w2, r = solo("Rai", guild_rank=3, tick=3)
    r.eval(TIMER_LUA)
    r.eval("GameTooltip:SetOwner(UIParent, 'ANCHOR_NONE')")
    raider = timed(r, len(ids), """
      local ids = ...
      T_time(#ids, function(i) ns.Tooltip:Invalidate(); GameTooltip:SetItemByID(ids[i]) end)""", ids)
    print("    tooltip (raider): %.3f ms per SetItemByID incl. mock" % raider)
    no_errors(w)
    no_errors(w2)


if __name__ == "__main__":
    run_all()
