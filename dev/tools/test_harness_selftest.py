#!/usr/bin/env python
"""Self-tests proving the WoW mock + harness work WITHOUT any DisasterZone code (only DisasterZone's Libs are loaded).

Run:  luaenv\\Scripts\\python.exe tools\\test_harness_selftest.py [-v] [-k substring]
Every test_* function gets fresh World/Clients. Exit code 0 = all passed.
"""
import os
import shutil
import sys
import tempfile
import time
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import harness as H  # noqa: E402

LIBS = [
    "Libs/LibStub/LibStub.lua",
    "Libs/CallbackHandler-1.0/CallbackHandler-1.0.lua",
    "Libs/AceComm-3.0/ChatThrottleLib.lua",
    "Libs/AceComm-3.0/AceComm-3.0.lua",
    "Libs/LibSerialize/LibSerialize.lua",
    "Libs/LibDeflate/LibDeflate.lua",
    "Libs/LibDataBroker-1.1/LibDataBroker-1.1.lua",
    "Libs/LibDBIcon-1.0/LibDBIcon-1.0.lua",
    "Libs/LibCustomGlow-1.0/LibCustomGlow-1.0.lua",
]

# A throw-away addon folder: DisasterZone's Libs + a TOC with SavedVariables and one missing file, so load_addon()/relog()
# can be tested without depending on the (in-progress) DisasterZone Core/UI code.
_FIXTURE = None


def fixture_dir():
    global _FIXTURE
    if _FIXTURE is None:
        d = tempfile.mkdtemp(prefix="cdloot_selftest_", dir=os.path.dirname(HERE))
        _FIXTURE = d
        shutil.copytree(os.path.join(H.ADDON_DIR, "Libs"), os.path.join(d, "Libs"))
        with open(os.path.join(d, "DisasterZone.toc"), "w", encoding="utf-8") as fh:
            fh.write("## Interface: 20506\n## Title: DisasterZone selftest\n## Version: 9.9.9\n## X-CDL-Protocol: 7\n"
                     "## SavedVariables: DisasterZoneDB\n\n")
            fh.write("\n".join(l.replace("/", "\\") for l in LIBS) + "\n")
            fh.write("Core\\DoesNotExist.lua\nTest\\Probe.lua\n")
        os.makedirs(os.path.join(d, "Test"))
        with open(os.path.join(d, "Test", "Probe.lua"), "w", encoding="utf-8") as fh:
            fh.write("""local addonName, ns = ...
ns.probe = { addonName = addonName, loadedDBAtFileTime = DisasterZoneDB }
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
ns.events = {}
f:SetScript("OnEvent", function(self, event, ...)
  table.insert(ns.events, event)
  if event == "ADDON_LOADED" and ... == addonName then
    DisasterZoneDB = DisasterZoneDB or { created = true }
    ns.dbAtAddonLoaded = DisasterZoneDB
  elseif event == "PLAYER_ENTERING_WORLD" then
    ns.pew = { ... }
  end
end)
""")
    return _FIXTURE


def two_clients(**kw):
    w = H.World(**kw)
    a = H.Client(w, "Alice", class_file="PALADIN", guild_rank=0)
    b = H.Client(w, "Bob", class_file="MAGE", guild_rank=3)
    for c in (a, b):
        c.load_files(LIBS, fire_login=True)
    w.tick(0.1)
    return w, a, b


# ------------------------------------------------------------------------------------------------------------------
def test_libs_load_without_errors():
    w, a, b = two_clients()
    w.tick(1)
    w.assert_no_errors()
    assert a.eval("return LibStub('AceComm-3.0') ~= nil and LibStub('LibDeflate') ~= nil and LibStub('LibSerialize') ~= nil")
    assert a.eval("return ChatThrottleLib.version") >= 32


SETUP_COMM = r"""
local prefix = ...
local AceComm = LibStub("AceComm-3.0")
local obj = {}
AceComm:Embed(obj)
__TEST = { received = {} }
obj:RegisterComm(prefix, function(pfx, msg, dist, sender)
  table.insert(__TEST.received, { prefix = pfx, msg = msg, dist = dist, sender = sender })
end)
__TEST.obj = obj
"""

MAKE_PAYLOAD = r"""
local LibSerialize, LibDeflate = LibStub("LibSerialize"), LibStub("LibDeflate")
math.randomseed(42)
local data = { kind = "bis", rev = 17, items = {} }
for i = 1, 180 do
  local t = {}
  for j = 1, 6 do t[j] = string.char(33 + math.random(0, 90)) end
  data.items[i] = { id = 28000 + math.random(1, 9000), note = table.concat(t) }
end
local ser = LibSerialize:Serialize(data)
local comp = LibDeflate:CompressDeflate(ser)
local enc = LibDeflate:EncodeForWoWAddonChannel(comp)
__TEST.payload = enc
__TEST.data = data
return #enc
"""

DECODE = r"""
local msg = ...
local LibSerialize, LibDeflate = LibStub("LibSerialize"), LibStub("LibDeflate")
local ok, data = LibSerialize:Deserialize(LibDeflate:DecompressDeflate(LibDeflate:DecodeForWoWAddonChannel(msg)))
if not ok then return false, "deserialize failed" end
return data.rev == 17 and #data.items == 180, data.items[180].id
"""


def test_acecomm_multipart_whisper_and_guild():
    w, a, b = two_clients()
    for c in (a, b):
        c.eval(SETUP_COMM, "CDLTest")
    n = a.eval(MAKE_PAYLOAD)
    assert 1500 <= n <= 2600, "payload should be ~2KB, got %d" % n
    a.eval("__TEST.obj:SendCommMessage('CDLTest', __TEST.payload, 'WHISPER', 'Bob')")
    a.eval("__TEST.obj:SendCommMessage('CDLTest', __TEST.payload, 'GUILD')")
    w.tick(20)
    w.assert_no_errors()
    got_b = b.eval_py("return __TEST.received")
    dists = sorted(r["dist"] for r in got_b)
    assert dists == ["GUILD", "WHISPER"], "Bob should get one WHISPER and one GUILD message, got %s" % dists
    for r in got_b:
        assert r["sender"] == "Alice", "AceComm Ambiguate()s same-realm senders to the short name: %r" % r["sender"]
    # payload intact (compare exact bytes inside Lua; bytes come back via eval as bytes)
    same = b.eval("local r = __TEST.received; return r[1].msg == r[2].msg and #r[1].msg")
    assert same == n, "reassembled message length mismatch: %r vs %r" % (same, n)
    orig = a.eval("return __TEST.payload")
    recv = b.eval("return __TEST.received[1].msg")
    assert isinstance(orig, bytes) and orig == recv, "payload bytes differ"
    ok, last_id = b.eval(DECODE, recv)
    assert ok is True and last_id == a.eval("return __TEST.data.items[180].id")
    # GUILD is echoed back to the sender
    got_a = a.eval_py("return __TEST.received")
    assert [r["dist"] for r in got_a] == ["GUILD"], "sender must get its own GUILD message back: %s" % got_a
    # multipart really happened over the bus: first part starts with \001, last with \003
    parts = [e for e in w.addon_log if e["prefix"] == "CDLTest" and e["chat_type"] == "WHISPER"]
    assert len(parts) >= 8, "expected >= 8 chunks, got %d" % len(parts)
    assert parts[0]["text"][:1] == b"\x01" and parts[-1]["text"][:1] == b"\x03"
    assert all(len(p["text"]) <= 255 for p in parts)
    assert all(p["recipients"] == ["Bob-Thunderstrike"] for p in parts)


def test_raw_addon_messages_routing_and_limits():
    w = H.World()
    a = H.Client(w, "Alice", guild_rank=0)
    b = H.Client(w, "Bob", guild_rank=3)
    c = H.Client(w, "Carol", guild="Other Guild")
    o = H.Client(w, "Olly", guild_rank=1)
    rec = """
      __RX = {}
      C_ChatInfo.RegisterAddonMessagePrefix("CDLRaw")
      local f = CreateFrame("Frame")
      f:RegisterEvent("CHAT_MSG_ADDON")
      f:RegisterEvent("CHAT_MSG_ADDON_LOGGED")
      f:SetScript("OnEvent", function(_, ev, prefix, text, chan, sender, target, zone, localID, name, inst)
        table.insert(__RX, { ev = ev, prefix = prefix, text = text, chan = chan, sender = sender, target = target, n = select('#', prefix, text, chan, sender, target, zone, localID, name, inst) })
      end)"""
    for x in (a, b, c, o):
        x.eval(rec)
    r = a.eval("return C_ChatInfo.SendAddonMessage('CDLRaw', 'hello guild', 'GUILD')")
    assert r == 0
    a.eval("C_ChatInfo.SendAddonMessage('CDLRaw', 'officers only', 'OFFICER')")
    b.eval("C_ChatInfo.SendAddonMessage('CDLRaw', 'not an officer', 'OFFICER')")
    a.eval("C_ChatInfo.SendAddonMessageLogged('CDLRaw', 'logged', 'WHISPER', 'bob-thunderstrike')")
    assert a.eval("return C_ChatInfo.SendAddonMessage('CDLRaw', 'x', 'RAID')") == 5, "RAID outside a group -> NotInGroup"
    assert a.eval("return C_ChatInfo.SendAddonMessage('CDLRaw', 'x', 'WHISPER')") == 6, "WHISPER without target"
    a.eval("C_ChatInfo.SendAddonMessage('CDLRaw', 'to nobody', 'WHISPER', 'Nobody')")
    w.tick(0.5)
    rx_b = b.eval_py("return __RX")
    assert [(x["ev"], x["text"]) for x in rx_b] == [("CHAT_MSG_ADDON", "hello guild"), ("CHAT_MSG_ADDON_LOGGED", "logged")], rx_b
    assert rx_b[0]["sender"] == "Alice-Thunderstrike" and rx_b[0]["n"] == 9
    assert rx_b[1]["chan"] == "WHISPER"
    assert c.eval_py("return __RX") == [], "other guild must not receive GUILD"
    rx_o = [x["text"] for x in o.eval_py("return __RX")]
    assert rx_o == ["hello guild", "officers only"], rx_o
    rx_a = [x["text"] for x in a.eval_py("return __RX")]
    assert rx_a == ["hello guild", "officers only"], "sender gets GUILD/OFFICER echo: %s" % rx_a
    assert any("No player named 'Nobody'" in l for l in a.chat_frame), a.chat_frame
    # limits
    try:
        a.eval("C_ChatInfo.SendAddonMessage('CDLRaw', string.rep('x', 256), 'GUILD')")
        raise AssertionError("256-byte message must error")
    except H.LuaEvalError as e:
        assert "max 255" in str(e)
    try:
        a.eval("C_ChatInfo.SendAddonMessage('ThisPrefixIsWayTooLong', 'x', 'GUILD')")
        raise AssertionError("17+ char prefix must error")
    except H.LuaEvalError as e:
        assert "max 16" in str(e)
    assert a.eval("return C_ChatInfo.RegisterAddonMessagePrefix('CDLRaw')") == 1, "duplicate registration"
    # unregistered prefix is not delivered
    a.eval("C_ChatInfo.SendAddonMessage('Unregistered', 'zzz', 'GUILD')")
    w.tick(0.5)
    assert all(x["prefix"] == "CDLRaw" for x in b.eval_py("return __RX"))
    # raid routing: party subgroups & raid
    w.make_raid([a, b, o] + [], extra_members=["X1", "X2", "X3"])
    w.tick(0.2)
    a.eval("C_ChatInfo.SendAddonMessage('CDLRaw', 'raid msg', 'RAID')")
    w.tick(0.5)
    assert b.eval("return __RX[#__RX].text") == "raid msg"
    assert c.eval_py("return __RX") == []
    # throttle: 10 burst per prefix, then AddonMessageThrottle (3)
    res = a.eval("local t = {} for i = 1, 12 do t[i] = C_ChatInfo.SendAddonMessage('CDLRaw', 'b' .. i, 'GUILD') end return t")
    vals = [res[i] for i in range(1, 13)]
    assert 3 in vals, "per-prefix throttle should kick in: %s" % vals
    w.assert_no_errors()


def test_timers():
    w, a, b = two_clients()
    a.eval("""
      __T = { after = 0, ticks = 0, cancelled = 0, timerArg = nil }
      C_Timer.After(1.0, function() __T.after = __T.after + 1 end)
      local t = C_Timer.NewTimer(2.0, function(self) __T.cancelled = __T.cancelled + 1 end)
      t:Cancel()
      __T.isCancelled = t:IsCancelled()
      C_Timer.NewTicker(0.5, function(self) __T.ticks = __T.ticks + 1; __T.timerArg = type(self) end, 3)
      C_Timer.After(0, function() __T.zero = GetTime() end)
    """)
    t0 = a.eval("return GetTime()")
    w.tick(0.05)
    assert a.eval("return __T.zero") is not None, "C_Timer.After(0) runs on the next step"
    w.tick(0.9)
    assert a.eval("return __T.after") == 0
    w.tick(0.2)
    assert a.eval("return __T.after") == 1
    w.tick(3)
    assert a.eval("return __T.ticks") == 3, "ticker with 3 iterations"
    assert a.eval("return __T.timerArg") == "table"
    assert a.eval("return __T.cancelled") == 0 and a.eval("return __T.isCancelled") is True
    assert abs(a.eval("return GetTime()") - t0 - 4.15) < 0.01
    assert a.eval("return GetTime()") != b.eval("return GetTime()"), "clients have different GetTime() bases"
    assert a.eval("return GetServerTime()") == b.eval("return GetServerTime()")
    try:
        a.eval("C_Timer.After(1)")
        raise AssertionError("bad C_Timer args must error")
    except H.LuaEvalError:
        pass
    w.assert_no_errors()


def test_events_and_scripts():
    w, a, b = two_clients()
    a.eval("""
      __E = {}
      local f = CreateFrame("Frame", "DisasterZoneEvtFrame")
      f:RegisterEvent("BAG_UPDATE")
      f:RegisterUnitEvent("UNIT_INVENTORY_CHANGED", "player")
      f:SetScript("OnEvent", function(self, event, ...) table.insert(__E, { event, ... }) end)
      local g = CreateFrame("Frame")
      g:RegisterAllEvents()
      g:SetScript("OnEvent", function(self, event) __E.all = (__E.all or 0) + 1 end)
      __G = g
    """)
    a.fire("BAG_UPDATE", 3)
    a.fire("UNIT_INVENTORY_CHANGED", "target")
    a.fire("UNIT_INVENTORY_CHANGED", "player")
    a.eval("DisasterZoneEvtFrame:UnregisterEvent('BAG_UPDATE')")
    a.fire("BAG_UPDATE", 4)
    ev = a.eval_py("return __E")
    assert ev[1] == ["BAG_UPDATE", 3] and ev[2] == ["UNIT_INVENTORY_CHANGED", "player"] and len([k for k in ev if isinstance(k, int)]) == 2, ev
    assert ev["all"] == 4
    assert a.eval("return DisasterZoneEvtFrame:IsEventRegistered('UNIT_INVENTORY_CHANGED')") is True
    # errors inside handlers are recorded, never swallowed, and do not stop other handlers
    a.eval("""
      local f1 = CreateFrame("Frame"); f1:RegisterEvent("PLAYER_TARGET_CHANGED")
      f1:SetScript("OnEvent", function() error("boom in handler") end)
      local f2 = CreateFrame("Frame"); f2:RegisterEvent("PLAYER_TARGET_CHANGED")
      f2:SetScript("OnEvent", function() __E.second = true end)
    """)
    a.fire("PLAYER_TARGET_CHANGED")
    assert a.eval("return __E.second") is True
    assert len(a.errors) == 1 and "boom in handler" in a.errors[0] and "stack traceback" in a.errors[0]
    try:
        w.assert_no_errors()
        raise AssertionError("assert_no_errors should raise")
    except H.LuaErrorsFound as e:
        assert "boom in handler" in str(e)
    w.clear_errors()
    # show/hide scripts, OnUpdate only while visible
    a.eval("""
      __S = { show = 0, hide = 0, upd = 0 }
      local p = CreateFrame("Frame", nil, UIParent)
      local c = CreateFrame("Frame", nil, p)
      c:SetScript("OnShow", function() __S.show = __S.show + 1 end)
      c:SetScript("OnHide", function() __S.hide = __S.hide + 1 end)
      c:SetScript("OnUpdate", function(self, elapsed) __S.upd = __S.upd + 1; __S.elapsed = elapsed end)
      __P, __C = p, c
    """)
    w.tick(0.2)
    upd1 = a.eval("return __S.upd")
    assert upd1 == 4 and abs(a.eval("return __S.elapsed") - 0.05) < 1e-9
    a.eval("__P:Hide()")
    w.tick(0.2)
    assert a.eval("return __S.upd") == upd1, "OnUpdate must not run for hidden frames"
    assert a.eval("return __S.hide") == 1 and a.eval("return __C:IsShown() and not __C:IsVisible()") is True
    a.eval("__P:Show()")
    assert a.eval("return __S.show") == 1
    # invalid script type errors like WoW
    try:
        a.eval("CreateFrame('Frame'):SetScript('OnClick', function() end)")
        raise AssertionError("SetScript OnClick on a Frame must error")
    except H.LuaEvalError as e:
        assert "doesn't have a \"OnClick\" script" in str(e)
    w.assert_no_errors()


def test_frames_widgets_and_unknown_fields():
    w, a, b = two_clients()
    a.eval("""
      local f = CreateFrame("Frame", "DisasterZoneMain", UIParent, "BasicFrameTemplateWithInset")
      f.TitleText:SetText("CD Loot")
      f:SetSize(300, 200)
      __R = { title = f.TitleText:GetText(), w = f:GetWidth(), close = f.CloseButton ~= nil, inset = f.Inset ~= nil,
              unknownChild = f.SomeChild, noopMethod = f:SetFooBar(1) }
      f.CloseButton:Click()
      __R.hiddenByClose = not f:IsShown()
      local cb = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
      cb.Text:SetText("Opt"); cb:SetChecked(true); cb:Click()
      __R.checked = cb:GetChecked()
      local eb = CreateFrame("EditBox", "DisasterZoneEdit", f, "InputBoxTemplate")
      eb:SetText("abc"); eb:Insert("d")
      __R.eb = eb:GetText()
      local sl = CreateFrame("Slider", nil, f, "OptionsSliderTemplate")
      sl:SetMinMaxValues(0, 10); sl:SetValue(15)
      __R.slider = sl:GetValue()
      local btn = CreateFrame("Button", "DisasterZoneBtn", f, "UIPanelButtonTemplate")
      btn:SetText("Go"); btn:SetScript("OnClick", function(self, button) __R.clicked = button end)
      __R.btntext = btn:GetText()
      local fs = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
      fs:SetText("hello")
      __R.fsw = fs:GetStringWidth()
      __R.nobackdrop = (CreateFrame("Frame").SetBackdrop == nil)
      __R.backdrop = CreateFrame("Frame", nil, UIParent, "BackdropTemplate").SetBackdrop ~= nil
    """)
    r = a.eval_py("return __R")
    assert r["title"] == "CD Loot" and r["w"] == 300 and r["close"] and r["inset"]
    assert "unknownChild" not in r and "noopMethod" not in r
    assert r["hiddenByClose"] is True and r["checked"] is False and r["eb"] == "abcd" and r["slider"] == 10
    assert r["btntext"] == "Go" and r["fsw"] == 30 and r["nobackdrop"] and r["backdrop"]
    a.click("DisasterZoneBtn")
    a.type_text("DisasterZoneEdit", "typed", enter=True)
    assert a.eval("return __R.clicked") == "LeftButton" and a.eval("return DisasterZoneEdit:GetText()") == "typed"
    rep = w.report_unknown_fields(addon_only=False)
    assert "SomeChild" in rep, rep
    assert "SetFooBar" in w.report_unknown_methods(addon_only=False)
    # permissive_fields
    w2 = H.World()
    p = H.Client(w2, "Perm", permissive_fields=True)
    assert p.eval("local f = CreateFrame('Frame'); return f.Whatever:GetObjectType()") == "Frame"
    w.assert_no_errors()


def test_scrollbox_dataprovider_menu_popup_settings():
    w, a, b = two_clients()
    a.eval("""
      __R = { inits = {} }
      local f = CreateFrame("Frame", "DisasterZoneList", UIParent)
      local box = CreateFrame("Frame", nil, f, "WowScrollBoxList")
      local bar = CreateFrame("EventFrame", nil, f, "MinimalScrollBar")
      local view = CreateScrollBoxListLinearView()
      view:SetElementInitializer("Button", function(row, data)
        row.label = row.label or row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        row.label:SetText(data.name)
        table.insert(__R.inits, data.name)
      end)
      view:SetElementExtent(20)
      ScrollUtil.InitScrollBoxListWithScrollBar(box, bar, view)
      local dp = CreateDataProvider({ { name = "a" }, { name = "b" } })
      box:SetDataProvider(dp)
      dp:Insert({ name = "c" })
      __R.size = dp:GetSize()
      __R.found = dp:FindElementDataByPredicate(function(d) return d.name == "b" end).name
      __R.frames = #box:GetFrames()
      __BOX = box
      MenuUtil.CreateContextMenu(UIParent, function(owner, root)
        root:CreateTitle("Actions")
        root:CreateButton("Award", function(data) __R.award = data end, 42)
        root:CreateCheckbox("Show offline", function() return true end, function() __R.toggled = true end)
        root:CreateDivider()
      end)
      StaticPopupDialogs["DISASTERZONE_TEST"] = { text = "Delete %s?", button1 = YES, button2 = NO, hasEditBox = true,
        OnAccept = function(self, data) __R.accepted = { data, self.editBox:GetText() } end, timeout = 0 }
      __R.popup = StaticPopup_Show("DISASTERZONE_TEST", "Bob", nil, "payload") ~= nil
      local panel = CreateFrame("Frame")
      local cat = Settings.RegisterCanvasLayoutCategory(panel, "DisasterZone")
      Settings.RegisterAddOnCategory(cat)
      __R.catid = cat:GetID()
      local dd = CreateFrame("DropdownButton", nil, f, "WowStyle1DropdownTemplate")
      local sel = "B"
      dd:SetupMenu(function(owner, root)
        root:CreateRadio("A", function(v) return sel == v end, function(v) sel = v end, "A")
        root:CreateRadio("B", function(v) return sel == v end, function(v) sel = v end, "B")
      end)
      __R.ddtext = dd.Text:GetText()
      __DD = dd
    """)
    r = a.eval_py("return __R")
    assert r["inits"] == ["a", "b", "a", "b", "c"], "initializer runs for every element (and again on change): %s" % r["inits"]
    assert r["size"] == 3 and r["found"] == "b" and r["frames"] == 3
    menu = a.last_menu()
    assert [c["kind"] for c in menu["children"]] == ["title", "button", "checkbox", "divider"]
    assert menu["children"][2]["selected"] is True
    a.menu_select("Award")
    assert a.eval("return __R.award") == 42
    assert a.popups() == ["DISASTERZONE_TEST"]
    a.accept_popup("DISASTERZONE_TEST", text="typed")
    assert a.eval_py("return __R.accepted") == ["payload", "typed"] and a.popups() == []
    assert isinstance(r["catid"], (int, float)) and r["ddtext"] == "B"
    dd = a.dropdown_menu(a.eval("return __DD"))
    assert [c["text"] for c in dd["children"]] == ["A", "B"]
    a.menu_select("A")
    a.eval("__DD:GenerateMenu()")
    assert a.eval("return __DD.Text:GetText()") == "A"
    w.assert_no_errors()


def test_relog_persistence_and_toc_loading():
    d = fixture_dir()
    w = H.World(addon_dir=d)
    a = H.Client(w, "Alice")
    a.load_addon()
    assert "Core/DoesNotExist.lua" in a.load_warnings[0]
    assert a.eval("return ns.probe.addonName") == "DisasterZone"
    assert a.eval("return ns.probe.loadedDBAtFileTime") is None, "SavedVariables are not set while files execute"
    assert a.eval_py("return ns.events") == ["ADDON_LOADED", "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD"]
    assert a.eval_py("return ns.pew") == [True, False]
    assert a.eval("return C_AddOns.GetAddOnMetadata('DisasterZone', 'X-CDL-Protocol')") == "7"
    assert a.eval("return C_AddOns.GetAddOnMetadata('DisasterZone', 'Version')") == "9.9.9"
    a.eval(r"""
      DisasterZoneDB.nested = { s = "q\"uote\nnl\\bs", t = true, f = false, [5] = 3.25, big = 2^40, neg = -7,
                          deep = { { 1, 2, { x = "y" } } }, ["key with space"] = 1 }
      DisasterZoneDB.bin = "\1\2\255\0end"
      DisasterZoneDB.fn = function() end
    """)
    a.relog()
    assert a.eval("return ns.probe.loadedDBAtFileTime") is None
    assert a.eval_py("return ns.pew") == [False, True], "/reload fires PLAYER_ENTERING_WORLD(false, true)"
    db = a.eval_py("return DisasterZoneDB")
    assert db["created"] is True and db["nested"]["s"] == 'q"uote\nnl\\bs' and db["nested"]["t"] is True
    assert db["nested"]["f"] is False and db["nested"][5] == 3.25 and db["nested"]["big"] == 2 ** 40
    assert db["nested"]["deep"] == [[1, 2, {"x": "y"}]] and db["nested"]["key with space"] == 1
    assert db["bin"] == b"\x01\x02\xff\x00end" and "fn" not in db
    assert a.eval("return ns.dbAtAddonLoaded == DisasterZoneDB") is True
    # full logout / login
    a.logout()
    assert a.runtime is None and not a.online
    a.login()
    assert a.eval("return DisasterZoneDB.nested.neg") == -7
    assert a.eval_py("return ns.pew") == [True, False]
    # recursive tables cannot be saved -> recorded error
    a.eval("DisasterZoneDB.loop = {}; DisasterZoneDB.loop.self = DisasterZoneDB.loop")
    a.relog()
    assert any("recursive table" in e for e in a.errors)
    w.clear_errors()
    # pre-seeded SavedVariables + optional "assign before files" timing
    c = H.Client(w, "Seeded", sv_before_files=True)
    c.set_saved_variable("DisasterZoneDB", "{ seeded = 1 }")
    c.load_addon()
    assert c.eval("return ns.probe.loadedDBAtFileTime.seeded") == 1
    # fractional ticks advance exactly
    t0 = w.now
    w.tick(0.12)
    assert abs(w.now - t0 - 0.12) < 1e-9
    w.assert_no_errors()


def test_loot_mock():
    w, a, b = two_clients()
    w.make_raid([a, b], master_looter=a)
    a.eval("""
      __L = { events = {}, hooked = 0 }
      local f = CreateFrame("Frame")
      for _, e in ipairs({ "LOOT_READY", "LOOT_OPENED", "LOOT_CLOSED", "LOOT_SLOT_CLEARED" }) do f:RegisterEvent(e) end
      f:SetScript("OnEvent", function(_, e, ...) table.insert(__L.events, e) end)
      hooksecurefunc("LootFrame_UpdateButton", function(i) __L.hooked = __L.hooked + 1 end)
    """)
    a.open_loot([(28477, 4), (29760, 4), (30480, None)])
    r = a.eval_py("""
      local t = { n = GetNumLootItems(), link = GetLootSlotLink(1), info = { GetLootSlotInfo(2) }, typ = GetLootSlotType(1),
                  src = { GetLootSourceInfo(1) }, has = LootSlotHasItem(3), thr = GetLootThreshold(),
                  lm = { C_PartyInfo.GetLootMethod() }, cand1 = GetMasterLootCandidate(1, 1), cand2 = GetMasterLootCandidate(1, 2),
                  slot1 = LootButton1.slot, shown = LootFrame:IsShown() }
      return t""")
    assert r["n"] == 3
    assert r["link"] == "|cffa335ee|Hitem:28477::::::::70:::::::::|h[Harbinger Bands]|h|r", r["link"]
    assert r["info"][1] == "Helm of the Fallen Champion" and r["info"][2] == 1 and r["info"][3] is None and r["info"][4] == 4, r["info"]
    assert r["typ"] == 1 and r["src"] == ["Creature-0-1-2-3-15690-000ABC", 1] and r["has"] is True and r["thr"] == 2
    assert r["lm"][0] == 2 and r["lm"][1] == 0 and r["lm"][2] == 1, "ML: (2, partyID 0 = me, raidIndex 1): %s" % r["lm"]
    assert r["cand1"] == "Alice" and r["cand2"] == "Bob" and r["slot1"] == 1 and r["shown"] is True
    assert a.eval("return __L.hooked") >= 3
    assert b.eval_py("return {C_PartyInfo.GetLootMethod()}") == [2, 1, 1] or b.eval("return select(3, C_PartyInfo.GetLootMethod())") == 1
    # master loot -> CHAT_MSG_LOOT on everybody + item in winner bags
    for c in (a, b):
        c.eval("""__CL = {}; local f = CreateFrame("Frame"); f:RegisterEvent("CHAT_MSG_LOOT")
                  f:SetScript("OnEvent", function(_, e, text, ...) table.insert(__CL, text) end)""")
    a.eval("GiveMasterLoot(1, 2)")
    w.tick(0.5)
    assert b.eval_py("return __CL") == ["You receive loot: |cffa335ee|Hitem:28477::::::::70:::::::::|h[Harbinger Bands]|h|r."]
    assert a.eval_py("return __CL") == ["Bob receives loot: |cffa335ee|Hitem:28477::::::::70:::::::::|h[Harbinger Bands]|h|r."]
    assert b.eval("return C_Item.GetItemCount(28477)") == 1
    a.close_loot()
    assert a.eval_py("return __L.events") == ["LOOT_READY", "LOOT_OPENED", "LOOT_SLOT_CLEARED", "LOOT_CLOSED"]
    assert a.eval("return GetNumLootItems()") == 0
    texts = w.broadcast_loot_received(b, 29760, count=2)
    assert texts["Bob-Thunderstrike"].startswith("You receive loot: ") and texts["Bob-Thunderstrike"].endswith("x2.")
    # rolls
    rid = a.start_loot_roll(28477)
    assert a.eval("return GetLootRollItemLink(...)", rid).endswith("[Harbinger Bands]|h|r")
    assert a.eval("return (select(2, GetLootRollItemInfo(...)))", rid) == "Harbinger Bands"
    assert a.eval("return GroupLootFrame1.rollID") == rid
    w.assert_no_errors()


def test_items_guild_group_units_gear():
    w = H.World()
    a = H.Client(w, "Alice", guild_rank=1, class_file="PALADIN", talents=(0, 11, 50))
    b = H.Client(w, "Bob", guild_rank=3, class_file="MAGE", realm="Other Realm")
    w.add_offline_member("Dave", "ROGUE", 4, public_note="alt", officer_note="main=Carl")
    for c in (a, b):
        c.load_files(LIBS, fire_login=True)
    assert a.eval("return (GetNumGuildMembers())") == 0, "roster not loaded before GUILD_ROSTER_UPDATE"
    w.tick(1)
    assert a.eval_py("return {GetNumGuildMembers()}") == [3, 2, 2]
    rows = a.eval_py("local t = {} for i = 1, GetNumGuildMembers() do t[i] = { GetGuildRosterInfo(i) } end return t")
    assert len(rows[0]) == 17 or len(rows[0]) == 16  # guid last
    alice = [r for r in rows if r[0] == "Alice-Thunderstrike"][0]
    assert alice[1] == "Officer" and alice[2] == 1 and alice[10] == "PALADIN" and alice[8] is True
    dave = [r for r in rows if r[0] == "Dave-Thunderstrike"][0]
    assert dave[6] == "alt" and dave[7] == "main=Carl" and dave[8] is False
    assert all(b.eval("return (select(8, GetGuildRosterInfo(...)))", i) == "" for i in (1, 2, 3)), "rank 3 cannot view officer notes"
    assert a.eval_py("return {GetGuildInfo('player')}") == ["Casual Disaster", "Officer", 1]
    assert a.eval("return GuildControlGetRankName(1)") == "Guild Master" and a.eval("return GuildControlGetNumRanks()") == 5
    assert a.eval("return CanEditGuildInfo()") is True and b.eval("return CanEditGuildInfo()") is False
    b.eval("__GRU = 0; local f = CreateFrame('Frame'); f:RegisterEvent('GUILD_ROSTER_UPDATE'); f:SetScript('OnEvent', function() __GRU = __GRU + 1 end)")
    a.eval("SetGuildInfoText('CDL:v1:abc')")
    w.tick(0.2)
    assert b.eval("return GetGuildInfoText()") == "CDL:v1:abc" and b.eval("return __GRU") >= 1
    a.eval("C_GuildInfo.GuildRoster()")
    w.tick(0.5)
    # group / units
    w.make_raid([a, b], leader=b, assistants=[a], extra_members=[H.ExtraMember("Xan", "WARLOCK")])
    info = a.eval_py("return { GetRaidRosterInfo(2) }")
    assert info[:6] == ["Bob-OtherRealm", 2, 1, 70, "Mage", "MAGE"] and len(info) == 12, info
    assert a.eval("return UnitInRaid('player')") == 1 and a.eval("return UnitInRaid('Bob-OtherRealm')") == 2
    assert a.eval_py("return { UnitName('raid2') }") == ["Bob", "OtherRealm"]
    assert a.eval("return UnitIsGroupLeader('raid2')") is True and a.eval("return UnitIsGroupAssistant('player')") is True
    assert a.eval_py("return { UnitClass('player') }") == ["Paladin", "PALADIN", 2]
    assert a.eval("return GetNumGroupMembers()") == 3 and a.eval("return IsInRaid()") is True
    assert a.eval("return Ambiguate('Bob-OtherRealm', 'none')") == "Bob-OtherRealm"
    assert a.eval("return Ambiguate('Alice-Thunderstrike', 'none')") == "Alice"
    assert a.eval("return C_PartyInfo.GetLootMethod()") == 3
    w.enter_instance("Karazhan", 532)
    assert a.eval_py("return { IsInInstance() }") == [True, "raid"]
    assert a.eval("return (select(8, GetInstanceInfo()))") == 532
    # items
    it = a.eval_py("return { C_Item.GetItemInfo(28477) }")
    assert it[0] == "Harbinger Bands" and it[2] == 4 and it[8] == "INVTYPE_WRIST" and it[11] == 4 and it[12] == 1, it
    assert a.eval("return GetItemInfo") is None, "legacy GetItemInfo is absent by default"
    inst = a.eval_py("return { C_Item.GetItemInfoInstant('item:28504') }")
    assert inst[0] == 28504 and inst[3] == "INVTYPE_RANGEDRIGHT" and inst[5] == 2 and inst[6] == 18
    assert a.eval("return (select(4, C_Item.GetItemQualityColor(4)))") == "ffa335ee"
    assert a.eval("return C_Item.IsEquippableItem(29760)") is False and a.eval("return C_Item.IsEquippableItem(28477)") is True
    assert a.eval("local it = Item:CreateFromItemID(28477); local n; it:ContinueOnItemLoad(function() n = it:GetItemName() end); return n") == "Harbinger Bands"
    assert a.eval("return RAID_CLASS_COLORS.PALADIN:GenerateHexColor()") == "fff58cba"
    assert a.eval("return C_ClassColor.GetClassColor('MAGE').colorStr") == "ff69ccf0"
    fb = a.eval("return (C_Item.GetItemInfo(19019))")  # not in DisasterZone data -> Questie fallback DB
    assert fb == "Thunderfury, Blessed Blade of the Windseeker", fb
    # uncached item flow
    u = H.Client(w, "Uncached", items_uncached=True)
    u.eval("__IR = {}; local f = CreateFrame('Frame'); f:RegisterEvent('GET_ITEM_INFO_RECEIVED'); f:SetScript('OnEvent', function(_, _, id, ok) table.insert(__IR, id) end)")
    assert u.eval("return C_Item.GetItemInfo(28477)") is None
    w.tick(0.2)
    assert u.eval_py("return __IR") == [28477] and u.eval("return (C_Item.GetItemInfo(28477))") == "Harbinger Bands"
    # gear / bags / bank
    a.eval("__G = {}; local f = CreateFrame('Frame'); for _, e in ipairs({'PLAYER_EQUIPMENT_CHANGED','BAG_UPDATE','BAG_UPDATE_DELAYED','BANKFRAME_OPENED','PLAYERBANKSLOTS_CHANGED'}) do f:RegisterEvent(e) end f:SetScript('OnEvent', function(_, e, ...) table.insert(__G, e) end)")
    a.equip({9: 28477, 1: 29061})
    a.set_bags({(0, 1): 28510, (1, 3): (22559, 1)})
    a.set_bank({(-1, 2): 28528, (5, 1): 28609})
    g = a.eval_py("return __G")
    assert g[:2] == ["PLAYER_EQUIPMENT_CHANGED", "PLAYER_EQUIPMENT_CHANGED"] and "BAG_UPDATE_DELAYED" in g and "BANKFRAME_OPENED" in g and "PLAYERBANKSLOTS_CHANGED" in g
    # The real 2.5.x API returns TWO values (itemID, <number>); the mock mirrors that.
    assert a.eval("return (GetInventoryItemID('player', select(1, GetInventorySlotInfo('WristSlot'))))") == 28477
    assert a.eval("return select('#', GetInventoryItemID('player', select(1, GetInventorySlotInfo('WristSlot'))))") == 2
    assert a.eval("return C_Container.GetContainerItemInfo(1, 3).itemID") == 22559
    assert a.eval("return C_Container.GetContainerItemID(-1, 2)") == 28528
    assert a.eval("return C_Container.GetContainerItemInfo(0, 1).hyperlink").endswith("[Spectral Band of Innervation]|h|r")
    a.close_bank()
    assert a.eval("return C_Container.GetContainerItemID(-1, 2)") is None, "bank contents unavailable when closed"
    try:
        a.eval("GetInventorySlotInfo('RingSlot')")
        raise AssertionError("invalid slot names must error")
    except H.LuaEvalError:
        pass
    assert a.eval_py("return { GetTalentTabInfo(3) }")[:5] == [381, "Retribution", "Retribution talents", 136246, 50]
    # tooltip hook
    a.eval("GameTooltip:HookScript('OnTooltipSetItem', function(tt) local _, link = tt:GetItem(); tt:AddLine('DisasterZone: BiS for 2') end)")
    lines = a.show_tooltip_item(28477)
    assert lines[0][0] == "Harbinger Bands" and lines[-1][0] == "DisasterZone: BiS for 2", lines
    w.assert_no_errors()


def test_libdbicon_and_customglow():
    w, a, b = two_clients()
    a.eval("""
      local ldb = LibStub("LibDataBroker-1.1")
      local obj = ldb:NewDataObject("DisasterZoneSelftest", { type = "launcher", icon = 134400, OnClick = function() __CLICKED = true end })
      __DB = { minimap = { hide = false } }
      LibStub("LibDBIcon-1.0"):Register("DisasterZoneSelftest", obj, __DB.minimap)
      local btn = CreateFrame("Button", "DisasterZoneGlowBtn", UIParent)
      btn:SetSize(36, 36)
      local LCG = LibStub("LibCustomGlow-1.0")
      LCG.ButtonGlow_Start(btn)
      LCG.PixelGlow_Start(btn)
      LCG.AutoCastGlow_Start(btn)
    """)
    assert a.eval("return LibDBIcon10_DisasterZoneSelftest ~= nil and LibDBIcon10_DisasterZoneSelftest:IsShown()") is True
    w.tick(1.0)
    a.eval("""
      local LCG = LibStub("LibCustomGlow-1.0")
      LCG.ButtonGlow_Stop(DisasterZoneGlowBtn)
      LCG.PixelGlow_Stop(DisasterZoneGlowBtn)
      LCG.AutoCastGlow_Stop(DisasterZoneGlowBtn)
      LCG.ProcGlow_Start(DisasterZoneGlowBtn)
    """)
    w.tick(1.0)
    a.eval("LibStub('LibCustomGlow-1.0').ProcGlow_Stop(DisasterZoneGlowBtn); LibStub('LibDBIcon-1.0'):Hide('DisasterZoneSelftest')")
    w.tick(0.5)
    w.assert_no_errors()


def test_chat_and_slash():
    w, a, b = two_clients()
    w.make_raid([a, b])
    for c in (a, b):
        c.eval("__C = {}; local f = CreateFrame('Frame'); for _, e in ipairs({'CHAT_MSG_RAID','CHAT_MSG_RAID_LEADER','CHAT_MSG_RAID_WARNING','CHAT_MSG_GUILD','CHAT_MSG_WHISPER','CHAT_MSG_WHISPER_INFORM'}) do f:RegisterEvent(e) end f:SetScript('OnEvent', function(_, e, text, sender) table.insert(__C, {e, text, sender}) end)")
    a.eval("SendChatMessage('pull in 5', 'RAID_WARNING')")
    b.eval("C_ChatInfo.SendChatMessage('hi', 'WHISPER', nil, 'Alice')")
    a.eval("ChatThrottleLib:SendChatMessage('NORMAL', 'DisasterZone', 'guild via CTL', 'GUILD')")
    w.tick(1)
    ca = a.eval_py("return __C")
    assert ["CHAT_MSG_RAID_WARNING", "pull in 5", "Alice-Thunderstrike"] in ca and ["CHAT_MSG_WHISPER", "hi", "Bob-Thunderstrike"] in ca
    assert ["CHAT_MSG_GUILD", "guild via CTL", "Alice-Thunderstrike"] in ca
    assert ["CHAT_MSG_WHISPER_INFORM", "hi", "Alice-Thunderstrike"] in b.eval_py("return __C")
    assert "pull in 5" in b.raid_notices
    assert [e["text"] for e in w.chat_log] == ["pull in 5", "hi", "guild via CTL"]
    a.eval("SLASH_DISASTERZONETEST1 = '/cdltest'; SlashCmdList.DISASTERZONETEST = function(msg) print('got', msg) end")
    assert a.slash("/cdltest sync now") is True and a.printed[-1] == "got sync now"
    w.assert_no_errors()


def test_misc_helpers():
    w, a, b = two_clients()
    a.eval("""
      __M = { ev = {} }
      local f = CreateFrame("Frame")
      for _, e in ipairs({ "MODIFIER_STATE_CHANGED", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED",
                           "PLAYER_TARGET_CHANGED", "COMBAT_LOG_EVENT_UNFILTERED", "CHAT_MSG_SYSTEM" }) do f:RegisterEvent(e) end
      f:SetScript("OnEvent", function(_, e, ...)
        table.insert(__M.ev, e)
        if e == "COMBAT_LOG_EVENT_UNFILTERED" then __M.cleu = { CombatLogGetCurrentEventInfo() } end
        if e == "CHAT_MSG_SYSTEM" then __M.sys = ... end
      end)
      local b = CreateFrame("Button", "DisasterZoneHoverBtn", UIParent)
      b:SetScript("OnEnter", function() __M.enter = true end)
      b:SetScript("OnLeave", function() __M.leave = true end)
      local e = CreateFrame("EditBox", "DisasterZoneEsc", UIParent, "InputBoxTemplate")
      e:SetAutoFocus(false)
      local fs = UIParent:CreateFontString(nil, "OVERLAY")
      fs:SetText("Needle in haystack")
    """)
    a.hover("DisasterZoneHoverBtn")
    a.leave("DisasterZoneHoverBtn")
    a.eval("DisasterZoneEsc:SetFocus()")
    a.press_escape("DisasterZoneEsc")
    assert a.eval("return DisasterZoneEsc:HasFocus()") is False, "InputBoxTemplate OnEscapePressed clears focus"
    assert len(a.find_text("Needle")) == 1 and a.find_text("nothing-like-this") == []
    a.set_modifiers(shift=True)
    assert a.eval("return IsShiftKeyDown() and IsModifiedClick('CHATLINK')") is True
    a.set_combat(True)
    assert a.eval("return InCombatLockdown() and UnitAffectingCombat('player')") is True
    a.set_combat(False)
    a.set_target("Bob")
    assert a.eval("return UnitName('target')") == "Bob" and a.eval("return UnitGUID('target')") == b.guid
    assert a.eval("return UnitIsUnit('target', 'Bob')") is False, "name units only resolve group members (WoW)"
    a.combat_log(123.0, "UNIT_DIED", False, "", "", 0, 0, "Creature-0-1-2-3-15690-000ABC", "Attumen", 0, 0)
    a.set_cursor_item(28477)
    assert a.eval("return (select(2, GetCursorInfo()))") == 28477
    m = a.eval_py("return __M")
    assert m["enter"] and m["leave"] and m["cleu"][1] == "UNIT_DIED" and m["cleu"][7] == "Creature-0-1-2-3-15690-000ABC"
    assert m["ev"][:4] == ["MODIFIER_STATE_CHANGED", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "PLAYER_TARGET_CHANGED"]
    w.define_item(990001, "Test Blade", quality=4, equip_loc="INVTYPE_WEAPON", class_id=2, subclass_id=7, ilvl=141)
    assert a.eval_py("return { C_Item.GetItemInfo(990001) }")[8] == "INVTYPE_WEAPON"
    c = H.Client(w, "Late")
    assert c.eval("return (C_Item.GetItemInfo(990001))") == "Test Blade", "world items apply to new clients"
    # logout notice + roster online flags + show offline
    w.tick(1)
    b.logout()
    w.tick(0.2)
    assert a.eval("return __M.sys") == "Bob has gone offline."
    assert a.eval_py("return {GetNumGuildMembers()}")[:2] == [3, 2]
    a.eval("SetGuildRosterShowOffline(false)")
    names = a.eval_py("local t = {} for i = 1, 10 do local n = GetGuildRosterInfo(i); if n then t[#t+1] = n end end return t")
    assert "Bob-Thunderstrike" not in names and "Alice-Thunderstrike" in names
    b.login(load=False)
    w.tick(0.2)
    assert "has come online" in a.eval("return __M.sys")
    # legacy globals flag
    lg = H.Client(w, "Legacy", legacy_globals=True)
    assert lg.eval("return (GetItemInfo(28477))") == "Harbinger Bands" and lg.eval("return GetLootMethod()") == "freeforall"
    assert a.eval("return GetItemInfo == nil and GetContainerNumSlots == nil and GetLootMethod == nil") is True
    try:
        a.eval("C_Item.GetItemInfo(nil)")
        raise AssertionError("nil item arg must error")
    except H.LuaEvalError:
        pass
    w.assert_no_errors()


TESTS = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]


def main(argv):
    verbose = "-v" in argv
    pattern = None
    if "-k" in argv:
        pattern = argv[argv.index("-k") + 1]
    failed = 0
    t_all = time.time()
    for t in TESTS:
        if pattern and pattern not in t.__name__:
            continue
        t0 = time.time()
        try:
            t()
            print("PASS %-50s %.2fs" % (t.__name__, time.time() - t0))
        except Exception as e:  # noqa: BLE001
            failed += 1
            print("FAIL %-50s %.2fs" % (t.__name__, time.time() - t0))
            if verbose or True:
                traceback.print_exc()
    if _FIXTURE and os.path.isdir(_FIXTURE):
        shutil.rmtree(_FIXTURE, ignore_errors=True)
    print("-- %d test(s), %d failed, %.1fs" % (len([t for t in TESTS if not pattern or pattern in t.__name__]), failed, time.time() - t_all))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
