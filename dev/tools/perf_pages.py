r"""Page switch timings in the mock at guild size: a GM with 60 guild members, teams, a month of raids with
sign-ups, then every main-window page shown a few times. Prints the real CPU ms of each show (panel:Show() +
OnPanelShown, like /dz perf) and, with --profile, the hottest source lines of the slowest pages (sampling hook).

Run: luaenv\Scripts\python.exe tools\perf_pages.py [--profile] [--pages raids,members]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.join(os.path.dirname(HERE), "tests")
sys.path.insert(0, os.path.join(TESTS, "raidplan"))
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))

from rp_common import World, Client, gm_pick, set_raid_leaders, team, create, now, K, DAY  # noqa: E402

CLASSES = ["PALADIN", "WARRIOR", "DRUID", "HUNTER", "ROGUE", "PRIEST", "MAGE", "WARLOCK", "SHAMAN"]
SPECS = {"PALADIN": 3, "WARRIOR": 3, "DRUID": 4, "HUNTER": 3, "ROGUE": 3, "PRIEST": 3, "MAGE": 3, "WARLOCK": 3,
         "SHAMAN": 3}
PAGES = ["home", "raids", "members", "atlas", "council", "mybis"]

PROFILER = r"""
local counts, clock = {}, __MOCK.real_os.clock
__perf = { counts = counts }
function __perf.start()
  for k in pairs(counts) do counts[k] = nil end
  debug.sethook(function()
    local info = debug.getinfo(2, "Sl")
    if info then
      local k = info.short_src .. ":" .. (info.currentline or 0)
      counts[k] = (counts[k] or 0) + 1
    end
  end, "", 1000)
end
function __perf.stop() debug.sethook() end
function __perf.show(key)
  local t0 = clock()
  ns.MainFrame:Open(key)
  return (clock() - t0) * 1000
end
"""


def build(n=60, raids=12):
    w = World()
    gm = Client(w, "Gina", guild_rank=0, class_file="PALADIN")
    bob = Client(w, "Bob", guild_rank=1, class_file="MAGE")
    names = []
    for i in range(n - 2):
        nm = "Rdr" + chr(97 + i // 26) + chr(97 + i % 26)
        cls = CLASSES[i % 9]
        w.add_offline_member(nm, class_file=cls, rank=3)
        names.append((nm, cls))
    for c in (gm, bob):
        c.load_addon()
    w.tick(3)
    gm_pick(w, gm, ["Bob"])
    set_raid_leaders(w, gm, ["Bob"])
    w.tick(2)
    t1 = team(gm, "Main", ["Gina", "Bob"] + [x[0] for x in names[:23]])
    t2 = team(gm, "Alt", [x[0] for x in names[23:48]])
    t0 = now(gm)
    insts = ["kara", "gruul", "mag", "ssc", "tk"]
    occs = []
    for r in range(raids):
        occs.append(create(gm, i=insts[r % 5], t=t0 + (r // 2 + 1) * DAY // 2 + 3600 * (r % 3),
                           tm=[t1 if r % 2 == 0 else t2]))
    # sign-ups straight into the store (the members are offline)
    gm.eval("""
      local occs, names, t = ...
      local root = ns.db.raidplan[next(ns.db.raidplan)]
      for oi, occ in ipairs(occs) do
        root.U[occ] = root.U[occ] or {}
        for i, nm in ipairs(names) do
          if (i + oi) % 4 ~= 0 then
            local st = ({ "A", "A", "A", "T", "B", "X" })[(i + oi) % 6 + 1]
            root.U[occ][nm[1] .. "-Thunderstrike"] = { st = st, rev = t - 100 + i, at = t - 200 + i, c = nm[2], sp = 1 }
          end
        end
      end
      ns:Fire("RAIDPLAN_CHANGED")
    """, occs, [[nm, cls] for nm, cls in names], t0)
    w.tick(2)
    gm.eval(PROFILER)
    return w, gm


def main():
    profile = "--profile" in sys.argv
    pages = PAGES
    if "--pages" in sys.argv:
        pages = sys.argv[sys.argv.index("--pages") + 1].split(",")
    w, gm = build()
    gm.eval("ns.MainFrame:Open('home')")
    w.tick(3)          # background pre-build
    res = {p: [] for p in pages}
    for rnd in range(3):
        for p in pages:
            if profile and rnd == 2:
                gm.eval("__perf.start()")
            ms = gm.eval("return __perf.show(...)", p)
            if profile and rnd == 2:
                gm.eval("__perf.stop()")
                top = gm.eval_py("""
                  local t = {}
                  for k, v in pairs(__perf.counts) do t[#t + 1] = { k, v } end
                  table.sort(t, function(a, b) return a[2] > b[2] end)
                  local out = {}
                  for i = 1, math.min(15, #t) do out[i] = t[i][1] .. "  " .. t[i][2] end
                  return out
                """)
                print("--", p, "hot lines (samples):")
                for line in (top or []):
                    print("    ", line)
            res[p].append(ms)
            w.tick(0.5)
    print("page       show ms (3 rounds)")
    for p in pages:
        print("%-10s %s" % (p, "  ".join("%6.1f" % x for x in res[p])))
    errs = gm.errors
    if errs:
        print("LUA ERRORS:", errs[:3])


if __name__ == "__main__":
    main()
