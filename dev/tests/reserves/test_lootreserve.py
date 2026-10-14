"""Loot reserves and LootReserve (1.4.3, Core/ReserveLR.lua), against LootReserve's own code: a pug client runs
LootReserve's real Comm.lua and Constants.lua (dev/thirdparty/LootReserve, d0afcf1c 2026-09-04) with its own LibStub,
AceComm, ChatThrottleLib and LibDeflate; only its windows are stand-ins that note what they are told. Both ways:
  - DisasterZone hosts: the LootReserve player finds the session, reserves and cancels in "its window", gets asked to
    roll and hears who won.
  - LootReserve hosts: a DisasterZone raid reads its reserves (a stand-in host built from the same Comm.lua)."""
import os

from rv_common import *  # noqa: F403

R = Runner("reserves / LootReserve both ways")

LR_LIBS = ["Libs/LibStub/LibStub.lua", "Libs/CallbackHandler-1.0/CallbackHandler-1.0.lua",
           "Libs/AceComm-3.0/ChatThrottleLib.lua", "Libs/AceComm-3.0/AceComm-3.0.lua", "Libs/LibDeflate/LibDeflate.lua"]

# LootReserve's globals its Comm.lua needs, with its windows replaced by notes (__LRN).
SHIM = r"""
__LRN = { started = {}, results = {}, cancels = {}, info = {}, rolls = {}, winners = {}, errors = {} }
LootReserve = { Enabled = true, Version = "2026-09-04", MinAllowedVersion = "2026-08-27", LatestKnownVersion = "",
  Settings = {}, Server = { Settings = {} } }
LibStub("AceComm-3.0"):Embed(LootReserve)
function LootReserve:IsCrossRealm() return false end
Enum = Enum or {}
Enum.SeasonID = Enum.SeasonID or { SeasonOfDiscovery = 2, NoSeason = 0 }
function LootReserve:GetNumClasses() return 0 end
function LootReserve:GetClassInfo() return nil end
LOCALIZED_CLASS_NAMES_MALE = LOCALIZED_CLASS_NAMES_MALE or {}
LOCALIZED_CLASS_NAMES_FEMALE = LOCALIZED_CLASS_NAMES_FEMALE or {}
function LootReserve:Player(p) return Ambiguate(p, "short") end
function LootReserve:Me() return UnitName("player") end
function LootReserve:IsMe(p) return Ambiguate(p, "short") == UnitName("player") end
function LootReserve:IsSamePlayer(a, b) return Ambiguate(a, "short") == Ambiguate(b, "short") end
function LootReserve:IsPlayerOnline() return true end
function LootReserve:ShowError(...) __LRN.errors[#__LRN.errors + 1] = string.format(...) end
LootReserve.PrintError = LootReserve.ShowError
function LootReserve:PrintMessage() end
function LootReserve:debug() end
function LootReserve:NotifyListeners() end
function LootReserve:Contains(t, v) for _, x in ipairs(t) do if x == v then return true end end return false end
function LootReserve:GetReservesData(players, me)
  local mine, n = 0, 0
  for _, p in ipairs(players or {}) do n = n + 1; if p == me then mine = mine + 1 end end
  return nil, mine, nil, n
end
function LootReserve:GetCategoriesText() return "" end
function LootReserve:GetReservesStringColored() return "" end
function LootReserve:ColoredPlayer(p) return p end
LootReserve.ItemConditions = { Unpack = function(_, packed) return { Hidden = packed:find("-") and true or nil } end }
LootReserve.Data = { GetTokenRewards = function() return nil end }
local function Item(id, suffix)
  return { GetID = function() return tonumber(id) end, GetSuffix = function() return tonumber(suffix) or 0 end,
           GetLink = function() return "item:" .. tostring(id) end, OnCache = function(self, fn) fn(self) end }
end
LootReserve.ItemCache = setmetatable({ Item = function(_, id, suffix) return Item(id, suffix) end },
  { __call = function(_, id) return Item(id) end })
local C = {}
LootReserve.Client = C
C.ItemReserves, C.Settings, C.Window = {}, {}, { PendOpen = function() end, Hide = function() end }
function C:StartSession(server, starting, startTime, accepting, cats, duration, maxDuration, equip, blind, multi)
  self.SessionServer, self.StartTime, self.AcceptingReserves = server, startTime, accepting
  __LRN.started[#__LRN.started + 1] = { server = server, starting = starting, accepting = accepting, cats = cats }
end
function C:StopSession() self.AcceptingReserves = false end
function C:ResetSession() self.SessionServer = nil end
for _, fn in ipairs({ "UpdateCategories", "UpdateLootList", "UpdateReserveStatus", "FlashCategory", "SetItemPending",
                      "SetOptPending" }) do C[fn] = function() end end
function C:IsItemReservedByMe(id) for _, p in ipairs(self.ItemReserves[id] or {}) do if p == UnitName("player") then return true end end return false end
function C:RollRequested(sender, item, players, custom, duration)
  __LRN.rolls[#__LRN.rolls + 1] = { sender = sender, item = item:GetID(), players = players, custom = custom }
end
function C:IsFavorite() return false end
LootReserve.Server.SetAddonUser = function() end
"""

# Notes of LootReserve's ReserveResult / CancelReserveResult / ReserveInfo / SendWinner (wrapped after Comm.lua loads)
WRAP = r"""
local H = LootReserve.Comm.Handlers
local function wrap(op, list, names)
  local old = H[op]
  H[op] = function(sender, ...)
    local t = { sender = sender }
    for i, n in ipairs(names) do t[n] = select(i, ...) end
    __LRN[list][#__LRN[list] + 1] = t
    return old(sender, ...)
  end
end
wrap(8, "results", { "item", "result", "left" })
wrap(11, "cancels", { "item", "result", "left" })
wrap(9, "info", { "item", "players" })
wrap(19, "winners", { "item", "winners", "losers", "roll" })
LootReserve.Comm:StartListening()
"""


def lr_client(r, name="Lars", cls="MAGE"):
    """A pug in the raid with LootReserve (and no DisasterZone)."""
    c = Client(r.w, name, class_file=cls, guild=None)
    files = [os.path.join(THERE, f) for f in LR_LIBS]
    c.load_files(files, addon_name="LootReserve")
    c.eval(SHIM)
    c.load_files([os.path.join(THERE, "Constants.lua"), os.path.join(THERE, "Comm.lua")], addon_name="LootReserve")
    c.eval(WRAP)
    r.c[name] = c
    r.form_raid(list(r.c.values()))
    r.w.tick(10)      # (ChatThrottleLib holds messages for a few seconds after login)
    return c


def notes(c, kind):
    return c.eval_py("return __LRN[...]", kind) or []


@R.case
def a_lootreserve_player_finds_the_session_reserves_and_cancels():
    r = reserve_raid()
    lars = lr_client(r)
    open_reserves(r, n=2, held=[HELM_CHAMPION])
    r.w.tick(3)
    # the opening SessionInfo reaches them: Alice is their host, reserves open, Karazhan's category
    st = notes(lars, "started")
    assert st and st[-1]["server"] == "Alice" and st[-1]["accepting"] and st[-1]["cats"] == [2010], st
    # a fresh LootReserve asks with Hello and gets it again
    n0 = len(st)
    lars.eval("LootReserve.Comm:BroadcastHello()")
    r.w.tick(3)
    assert len(notes(lars, "started")) > n0
    assert lars.eval_py("return LootReserve.Client.RemainingReserves") == 2
    # reserve from "the window"
    lars.eval("LootReserve.Comm:SendReserveItem(...)", RUBY_DRAPE)
    r.w.tick(3)
    res = notes(lars, "results")
    assert res and res[-1]["result"] == "0" and res[-1]["left"] == "1", res
    assert reserves_of(r["Alice"], "Lars") == [RUBY_DRAPE]
    assert r["Alice"].eval_py("return ns.Reserves:SourceOf(...)", key("Lars"), RUBY_DRAPE) == "l"
    info = notes(lars, "info")
    assert info and info[-1]["item"] == str(RUBY_DRAPE) and info[-1]["players"] == "Lars", info
    assert lars.eval_py("return LootReserve.Client.ItemReserves[...]", RUBY_DRAPE) == ["Lars"]
    # every other raid member reads the list as it is too
    r.w.tick(2)
    assert reserves_of(r["Carol"], "Lars") == [RUBY_DRAPE]
    # refused: a guild item (LootReserve's "item not reservable"), the same item twice
    lars.eval("LootReserve.Comm:SendReserveItem(...)", HELM_CHAMPION)
    lars.eval("LootReserve.Comm:SendReserveItem(...)", RUBY_DRAPE)
    r.w.tick(3)
    codes = [x["result"] for x in notes(lars, "results")[-2:]]
    assert codes == ["5", "6"], notes(lars, "results")
    # someone else reserves by whisper: the LootReserve player sees it in their list
    whisper(r, "Yuri", "!sr Ruby Drape")
    r.w.tick(3)
    assert sorted(lars.eval_py("return LootReserve.Client.ItemReserves[...]", RUBY_DRAPE)) == ["Lars", "Yuri"]
    # cancel
    lars.eval("LootReserve.Comm:SendCancelReserve(...)", RUBY_DRAPE)
    r.w.tick(3)
    can = notes(lars, "cancels")
    assert can and can[-1]["result"] == "0" and can[-1]["left"] == "2", can
    assert reserves_of(r["Alice"], "Lars") == []
    assert notes(lars, "errors") == [] or all("Failed" in e for e in notes(lars, "errors")), notes(lars, "errors")
    r.w.assert_no_errors()


@R.case
def the_guild_items_are_hidden_and_closing_stops_new_reserves():
    r = reserve_raid()
    lars = lr_client(r)
    open_reserves(r, n=1, held=[HELM_CHAMPION])
    r.w.tick(3)
    cond = lars.eval_py("local c = LootReserve.Client.ItemConditions[...]; return c and c.Hidden", HELM_CHAMPION)
    assert cond is True, cond
    r["Alice"].eval("ns.Reserves:Close()")
    r.w.tick(4)
    assert lars.eval("return LootReserve.Client.AcceptingReserves") is False
    lars.eval("LootReserve.Comm:SendReserveItem(...)", RUBY_DRAPE)
    r.w.tick(3)
    assert notes(lars, "results")[-1]["result"] == "3", notes(lars, "results")
    r.w.assert_no_errors()


@R.case
def reservers_with_lootreserve_are_asked_to_roll_and_hear_the_winner():
    r = reserve_raid()
    lars = lr_client(r)
    open_reserves(r, n=1)
    r.w.tick(3)
    lars.eval("LootReserve.Comm:SendReserveItem(...)", RUBY_DRAPE)
    r["Bob"].eval("ns.Reserves:Reserve(...)", RUBY_DRAPE)
    r.w.tick(3)
    r["Alice"].open_loot([(RUBY_DRAPE, 4)])
    r.w.tick(2)
    s = start_roll(r, RUBY_DRAPE)
    r.w.tick(2)
    rolls = notes(lars, "rolls")
    assert rolls and rolls[-1]["sender"] == "Alice" and rolls[-1]["item"] == RUBY_DRAPE, rolls
    assert sorted(rolls[-1]["players"]) == ["Bob", "Lars"] and not rolls[-1]["custom"], rolls
    r.w.player_roll("Lars", 77)
    r.w.player_roll("Bob", 12)
    r.w.tick(1)
    r["Alice"].eval("ns.Roll:MarkAwardedExternally(...)", s["id"], key("Lars"))
    r.w.tick(3)
    win = notes(lars, "winners")
    assert win and win[-1]["winners"] == "Lars" and win[-1]["losers"] == "Bob" and win[-1]["roll"] == "77", win
    r.w.assert_no_errors()


@R.case
def a_lootreserve_host_in_the_raid_is_read_not_answered():
    r = reserve_raid()
    host = lr_client(r, "Hanna", "PRIEST")
    # Hanna hosts a LootReserve session: her SessionInfo names who reserved what (built with LootReserve's own code)
    host.eval(r"""
      LootReserve.Server.CurrentSession = { Settings = { Blind = false, MaxReservesPerPlayer = 1, LootCategories = { 2010 },
        Duration = 0, Lock = false, Equip = false, Multireserve = 1 }, Duration = 0, StartTime = 100, AcceptingReserves = true,
        Members = { Hanna = { ReservesLeft = 0, ReservesDelta = 0 }, Carol = { ReservesLeft = 0, ReservesDelta = 0 },
                    Yuri = { ReservesLeft = 1, ReservesDelta = 0 } },
        ItemReserves = { [...] = { Players = { "Carol", "Hanna" } } }, ItemConditions = {} }
      LootReserve.Comm:BroadcastSessionInfo(true)""", RUBY_DRAPE)
    r.w.tick(4)
    for n in ("Alice", "Carol"):
        assert r[n].eval_py("return ns.Reserves:IsForeign()") == key("Hanna"), n
        assert reservers(r[n], RUBY_DRAPE) == [key("Carol"), key("Hanna")], (n, reservers(r[n], RUBY_DRAPE))
    assert decide(r["Alice"], RUBY_DRAPE) == {"k": "s", "keys": [key("Carol"), key("Hanna")]}
    # one more reserve (ReserveInfo) and the session's end (SessionReset)
    host.eval(r"LootReserve.Comm:BroadcastReserveInfo(..., { 'Carol', 'Hanna', 'Yuri' })", RUBY_DRAPE)
    r.w.tick(3)
    assert reservers(r["Bob"], RUBY_DRAPE) == [key("Carol"), key("Hanna"), key("Yuri")]
    # Alice can't open her own list over it ... unless the LootReserve session goes away
    host.eval("LootReserve.Comm:SendSessionReset()")
    r.w.tick(3)
    assert r["Alice"].eval_py("return ns.Reserves:Get()") is None
    r.w.assert_no_errors()


@R.case
def a_second_host_makes_mine_go_quiet():
    r = reserve_raid()
    lars = lr_client(r)
    open_reserves(r, n=1)
    r.w.tick(3)
    assert r["Alice"].eval("return ns.ReserveLR.Hosting()")
    host = lr_client(r, "Hanna", "PRIEST")
    host.eval(r"""
      LootReserve.Server.CurrentSession = { Settings = { Blind = false, MaxReservesPerPlayer = 1, LootCategories = { 2010 },
        Duration = 0, Lock = false, Equip = false, Multireserve = 1 }, Duration = 0, StartTime = 100, AcceptingReserves = true,
        Members = { Hanna = { ReservesLeft = 1, ReservesDelta = 0 } }, ItemReserves = {}, ItemConditions = {} }
      LootReserve.Comm:BroadcastSessionInfo(true)""")
    r.w.tick(3)
    assert not r["Alice"].eval("return ns.ReserveLR.Hosting()")
    assert any("Hanna runs a LootReserve session" in strip_codes(str(x)) for x in r["Alice"].chat_frame)
    # Alice's own list stays hers
    assert r["Alice"].eval_py("return ns.Reserves:IsForeign()") is None
    r.w.assert_no_errors()


if __name__ == "__main__":
    main(R)
