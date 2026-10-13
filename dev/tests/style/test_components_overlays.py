"""The overlays of refactor 1.4 phase 2 (UI/Comp/Overlays.lua + UI/Popup.lua, REFACTOR_API.md "Overlays.lua"):
UI:Toast (one look, one stack from the top of the screen, replaced by its key, a queue behind UI.TOAST.MAX, the
timer that waits under the mouse, held for the fight's end with combat = false), UI:CreateSheet (floating over its
window with the window dimmed, or a cover inside a panel; Escape, OK / Cancel, the error line), ns.Popup:Confirm /
ns.Popup:Prompt (on the existing dialog system: danger, keyed replace, validate, trim, multiline) and
UI:CreateHudFrame (the one position store UI:SavePosition / RestorePosition, lock, drag, Escape, its X).

Run: luaenv\\Scripts\\python.exe tests\\style\\test_components_overlays.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))

from _common import case, run_all, solo, no_errors  # noqa: E402

PTS = """
local function pts(r)
  local out = {}
  for i = 1, r:GetNumPoints() do
    local p, rel, rp, x, y = r:GetPoint(i)
    local relName = rel and rel.GetName and rel:GetName() or (rel and "frame" or "none")
    out[#out + 1] = { p, relName, rp, x, y }
  end
  return out
end
"""


# ------------------------------------------------------------------------------------------------------------------
# Toasts
# ------------------------------------------------------------------------------------------------------------------
@case
def toasts_stack_down_from_the_top_and_a_key_fills_one_in_place():
    w, c = solo()
    out = c.eval_py(PTS + """
        local UI = ns.UI
        local snd0 = #__MOCK.sounds
        local a = UI:Toast({ key = "a", title = "First", text = "one", sound = "TELL_MESSAGE", duration = 0 })
        local b = UI:Toast({ key = "b", kind = "ok", kicker = "Done", title = "Second", duration = 0 })
        local res = { aPts = pts(a), bPts = pts(b), strata = a:GetFrameStrata(), w = a:GetWidth(),
          sounds = #__MOCK.sounds - snd0, kick = b.kick:GetText(), kickShown = b.kick:IsShown(),
          aKick = a.kick:IsShown() }
        local a2 = UI:Toast({ key = "a", title = "First again", text = "two", sound = "TELL_MESSAGE", duration = 0 })
        res.same = a2 == a
        res.title = a.title:GetText()
        res.text = a.text:GetText()
        res.shown = #UI:ShownToasts()
        res.soundsAfter = #__MOCK.sounds - snd0
        res.got = UI:GetToast("b") == b
        return res""")
    # (the stack starts at its anchor, which the layout places where the stack always started: TOP 0, -120)
    assert out["aPts"] == [["TOP", "DisasterZoneToastAnchor", "TOP", 0, 0]], out["aPts"]
    anchor = c.eval_py("local p, r, rp, x, y = DisasterZoneToastAnchor:GetPoint(1); return { p, r:GetName(), rp, x, y }")
    assert anchor == ["TOP", "UIParent", "TOP", 0, -120], anchor
    assert out["bPts"][0][0] == "TOP" and out["bPts"][0][2] == "BOTTOM" and out["bPts"][0][4] == -8, out["bPts"]
    assert out["bPts"][0][1] == "DisasterZoneToast1", out["bPts"]
    assert out["strata"] == "DIALOG" and out["w"] == 380, out
    assert out["sounds"] == 1, out
    assert out["kick"] == "DONE" and out["kickShown"] and not out["aKick"], out
    assert out["same"] and out["title"] == "First again" and out["text"] == "two", out
    assert out["shown"] == 2 and out["soundsAfter"] == 1 and out["got"], out
    no_errors(w)


@case
def toasts_beyond_the_max_wait_their_turn_and_a_waiting_key_is_replaced():
    w, c = solo()
    out = c.eval_py("""
        local UI = ns.UI
        local made = {}
        for i = 1, 3 do made[i] = UI:Toast({ key = "k" .. i, title = "T" .. i, duration = 0 }) end
        local res = {}
        res.fourth = UI:Toast({ key = "k4", title = "T4", duration = 0 }) == nil
        UI:Toast({ key = "k4", title = "T4 new", duration = 0 })
        res.queue = #UI:ToastQueue()
        res.queuedTitle = UI:ToastQueue()[1].title
        UI:HideToast("k2", "close")
        res.afterHide = #UI:ShownToasts()
        ns.__ov = made
        return res""")
    assert out["fourth"] and out["queue"] == 1 and out["queuedTitle"] == "T4 new", out
    assert out["afterHide"] == 2, out
    w.tick(0.5)
    out = c.eval_py("""
        local UI = ns.UI
        local t4 = UI:GetToast("k4")
        local shown = UI:ShownToasts()
        return { t4 = t4 and t4.title:GetText(), n = #shown, q = #UI:ToastQueue(),
          order = { shown[1].key, shown[2].key, shown[3].key } }""")
    assert out["t4"] == "T4 new" and out["n"] == 3 and out["q"] == 0, out
    assert out["order"] == ["k1", "k3", "k4"], out
    no_errors(w)


@case
def a_toast_that_waited_still_gets_its_callers_pieces_through_on_fill():
    # (the duel game toast's best-of pips: a toast behind UI.TOAST.MAX came without them before onFill)
    w, c = solo()
    out = c.eval_py("""
        local UI = ns.UI
        for i = 1, 3 do UI:Toast({ key = "f" .. i, title = "T" .. i, duration = 0 }) end
        local fills = 0
        local function fill(t)
          fills = fills + 1
          t.slot.mark = t.slot.mark or t.slot:CreateTexture(nil, "ARTWORK")
          t.slot.mark:Show()
        end
        ns.__ovfills = function() return fills end
        local res = { waited = UI:Toast({ key = "pips", title = "Game 2", duration = 0, onFill = fill }) == nil,
          fillsWhileWaiting = fills }
        UI:HideToast("f1", "close")
        return res""")
    assert out["waited"] and out["fillsWhileWaiting"] == 0, out
    w.tick(0.5)
    out = c.eval_py("""
        local t = ns.UI:GetToast("pips")
        return { shown = t ~= nil and t:IsShown(), mark = t ~= nil and t.slot.mark ~= nil and t.slot.mark:IsShown(),
          fills = ns.__ovfills() }""")
    assert out == {"shown": True, "mark": True, "fills": 1}, out
    no_errors(w)


@case
def toast_buttons_run_their_handler_and_close_unless_it_says_keep():
    w, c = solo()
    out = c.eval_py(PTS + """
        local UI = ns.UI
        local log = {}
        ns.__ovlog = log
        local t = UI:Toast({ key = "btn", title = "Join?", duration = 0,
          buttons = { { text = "Join", onClick = function() log[#log + 1] = "join" end } },
          onClose = function(_, why) log[#log + 1] = "close:" .. why end })
        local side = t.btns[1]
        local res = { sidePts = pts(side), kind = side.kind, closeShown = t.close:IsShown() }
        ns.__ovt = t
        return res""")
    assert out["sidePts"][0][0] == "RIGHT" and out["sidePts"][0][2] == "RIGHT", out
    assert out["kind"] == "primary" and out["closeShown"], out
    c.click(c.eval("return ns.__ovt.btns[1]"))
    out = c.eval_py("""return { log = ns.__ovlog, shown = ns.__ovt:IsShown() }""")
    assert out["log"] == ["join", "close:button"] and not out["shown"], out
    # a vote toast: two sleek buttons on the foot, a "Later" link at the right; Yes keeps it (returns true)
    out = c.eval_py(PTS + """
        local UI = ns.UI
        local log = {}
        ns.__ovlog = log
        local t = UI:Toast({ key = "poll", kicker = "New poll", title = "Raid on Friday?", text = "Yes / No",
          duration = 0, noClose = true,
          buttons = { { text = "Yes", onClick = function() log[#log + 1] = "yes"; return true end },
                      { text = "No", onClick = function() log[#log + 1] = "no" end },
                      { text = "Later", kind = "link" } } })
        ns.__ovt = t
        return { yes = pts(t.btns[1]), no = pts(t.btns[2]), later = pts(t.links[1]), noKind = t.btns[2].kind,
          laterText = t.links[1]:GetText(), close = t.close:IsShown(), h = t:GetHeight() }""")
    assert out["yes"][0][0] == "TOPLEFT" and out["no"][0][0] == "LEFT", out
    assert out["later"][0][0] == "TOPRIGHT" and out["laterText"] == "Later", out
    assert out["noKind"] == "secondary" and not out["close"], out
    assert out["h"] > 70, out
    c.click(c.eval("return ns.__ovt.btns[1]"))
    assert c.eval("return ns.__ovt:IsShown()") is True
    c.click(c.eval("return ns.__ovt.links[1]"))
    assert c.eval("return ns.__ovt:IsShown()") is False
    no_errors(w)


@case
def a_click_on_the_toast_and_its_x_close_it_with_their_reason():
    w, c = solo()
    c.eval_py("""
        local log = {}
        ns.__ovlog = log
        ns.__ovt = ns.UI:Toast({ key = "c", title = "Open", duration = 0,
          onClick = function() log[#log + 1] = "click" end,
          onClose = function(_, why) log[#log + 1] = why end })
        return true""")
    c.click(c.eval("return ns.__ovt"))
    c.eval_py("""
        ns.__ovt = ns.UI:Toast({ key = "c", title = "Again", duration = 0,
          onClose = function(_, why) ns.__ovlog[#ns.__ovlog + 1] = why end })
        return true""")
    c.click(c.eval("return ns.__ovt.close"))
    assert c.eval_py("return ns.__ovlog") == ["click", "click", "close"]
    no_errors(w)


@case
def a_toast_times_out_but_waits_under_the_mouse():
    w, c = solo()
    c.eval_py("""
        local log = {}
        ns.__ovlog = log
        ns.__ova = ns.UI:Toast({ key = "t1", title = "Short", duration = 1, timeBar = true,
          onClose = function(_, why) log[#log + 1] = "t1:" .. why end })
        ns.__ovb = ns.UI:Toast({ key = "t2", title = "Hovered", duration = 1,
          onClose = function(_, why) log[#log + 1] = "t2:" .. why end })
        ns.__ovb.IsMouseOver = function() return true end
        return true""")
    w.tick(0.5)
    half = c.eval_py("return { ns.__ova.bar:IsShown(), ns.__ova.bar:GetWidth() }")
    assert half[0] and 150 < half[1] < 230, half
    w.tick(1.0)
    out = c.eval_py("return { log = ns.__ovlog, a = ns.__ova:IsShown(), b = ns.__ovb:IsShown() }")
    assert out["log"] == ["t1:timeout"] and not out["a"] and out["b"], out
    c.eval("ns.__ovb.IsMouseOver = nil")
    w.tick(1.2)
    assert c.eval_py("return ns.__ovlog") == ["t1:timeout", "t2:timeout"]
    no_errors(w)


@case
def a_keyed_refill_with_keep_time_keeps_the_time_it_has_left():
    w, c = solo()
    c.eval_py("""
        ns.__ovk = ns.UI:Toast({ key = "kt", title = "Kept", duration = 2 })
        ns.__ovr = ns.UI:Toast({ key = "rs", title = "Reset", duration = 2 })
        return true""")
    w.tick(1.5)
    c.eval_py("""
        ns.UI:Toast({ key = "kt", title = "Kept +1", duration = 2, keepTime = true })
        ns.UI:Toast({ key = "rs", title = "Reset +1", duration = 2 })
        return true""")
    left = c.eval_py("return { ns.__ovk.left, ns.__ovr.left }")
    assert left[0] < 0.7 and left[1] > 1.9, left
    w.tick(0.8)
    out = c.eval_py("return { k = ns.__ovk:IsShown(), r = ns.__ovr:IsShown(), title = ns.__ovr.title:GetText() }")
    assert not out["k"] and out["r"] and out["title"] == "Reset +1", out
    no_errors(w)


@case
def a_toast_held_for_the_fight_comes_when_it_ends():
    w, c = solo()
    c.set_combat(True)
    out = c.eval_py("""
        local UI = ns.UI
        local held = UI:Toast({ key = "h", title = "After the fight", combat = false, duration = 0 })
        local now = UI:Toast({ key = "n", title = "Now", duration = 0 })
        return { held = held == nil, now = now ~= nil and now:IsShown(), q = #UI:ToastQueue() }""")
    assert out == {"held": True, "now": True, "q": 1}, out
    c.set_combat(False)
    w.tick(0.1)
    out = c.eval_py("""local t = ns.UI:GetToast("h"); return { t ~= nil and t:IsShown(), #ns.UI:ToastQueue() }""")
    assert out == [True, 0], out
    no_errors(w)


@case
def a_toast_with_art_or_an_icon_puts_its_words_beside_it():
    w, c = solo()
    out = c.eval_py(PTS + """
        local UI = ns.UI
        local a = UI:Toast({ key = "art", art = { "Interface\\\\X", 0, 1, 0.1, 0.9 }, title = "Karazhan", text = "l2\\nl3",
          duration = 0 })
        local i = UI:Toast({ key = "icon", icon = 134400, title = "Feedback", text = "Thanks", duration = 0 })
        return { art = a.art:IsShown(), artW = a.art:GetWidth(), fade = a.artFade:IsShown(), aTitle = pts(a.title),
          aIcon = a.icon:IsShown(), iIcon = i.icon:IsShown(), iArt = i.art:IsShown(), iTitle = pts(i.title),
          iconSize = { i.icon:GetWidth(), i.icon:GetHeight() }, aH = a:GetHeight(), iH = i:GetHeight() }""")
    assert out["art"] and out["fade"] and out["artW"] == 112 and not out["aIcon"], out
    assert out["aTitle"][0][3] == 122, out["aTitle"]
    assert out["iIcon"] and not out["iArt"] and out["iconSize"] == [32, 32], out
    assert out["iTitle"][0][3] == 12 + 32 + 10, out["iTitle"]
    assert out["aH"] >= 76 and out["iH"] >= 56, out
    no_errors(w)


# ------------------------------------------------------------------------------------------------------------------
# Sheets
# ------------------------------------------------------------------------------------------------------------------
@case
def a_sheet_floats_over_its_window_dimmed_and_escape_closes_it():
    w, c = solo()
    out = c.eval_py(PTS + """
        local UI = ns.UI
        local win = CreateFrame("Frame", "OvTestWindow", UIParent)
        win:SetSize(600, 400)
        win:SetPoint("CENTER")
        win:Show()
        local log = {}
        ns.__ovlog = log
        local sh = UI:CreateSheet(win, { title = "New event", width = 420, height = 300, ok = "Create",
          onClose = function() log[#log + 1] = "closed" end, foot = "Starts in 2 days" })
        ns.__ovsh = sh
        local res = { hidden = not sh:IsShown(), size = { sh:GetWidth(), sh:GetHeight() } }
        sh:Open()
        res.open = sh:IsOpen()
        res.pts = pts(sh)
        res.dim = sh.dim:IsShown()
        res.dimPts = pts(sh.dim)
        res.strata = sh:GetFrameStrata()
        res.title = sh.title:GetText()
        res.ok = sh.ok:GetText()
        res.cancel = sh.cancel:GetText()
        res.foot = sh.foot:GetText()
        res.body = pts(sh.body)
        sh:Error("Pick a day")
        res.err = { sh.err:IsShown(), sh.err:GetText() }
        return res""")
    assert out["hidden"] and out["size"] == [420, 300] and out["open"], out
    assert out["pts"] == [["CENTER", "OvTestWindow", "CENTER", 0, 0]], out["pts"]
    assert out["dim"] and out["dimPts"][0][1] == "OvTestWindow", out
    assert out["strata"] == "DIALOG" and out["title"] == "New event", out
    assert out["ok"] == "Create" and out["cancel"] == "Cancel" and out["foot"] == "Starts in 2 days", out
    assert out["body"][0][:4] == ["TOPLEFT", "frame", "TOPLEFT", 12] and out["body"][0][4] == -52, out["body"]
    assert out["body"][1][4] == 58, out["body"]
    assert out["err"] == [True, "Pick a day"], out
    c.eval("__MOCK.call_script(ns.__ovsh, 'OnKeyDown', 'ESCAPE')")
    out = c.eval_py("return { ns.__ovsh:IsShown(), ns.__ovsh.dim:IsShown(), ns.__ovlog }")
    assert out == [False, False, ["closed"]], out
    # opened again: the error line is gone; Cancel closes
    c.eval("ns.__ovsh:Open()")
    assert c.eval("return ns.__ovsh.err:IsShown()") is False
    c.click(c.eval("return ns.__ovsh.cancel"))
    assert c.eval("return ns.__ovsh:IsShown()") is False
    no_errors(w)


@case
def a_sheet_without_a_window_sits_on_the_screen_and_one_over_a_high_window_climbs():
    w, c = solo()
    out = c.eval_py(PTS + """
        local UI = ns.UI
        local sh = UI:CreateSheet(UIParent, { title = "Alone" })
        sh:Open()
        local high = CreateFrame("Frame", "OvTestHigh", UIParent)
        high:SetFrameStrata("FULLSCREEN_DIALOG")
        high:Show()
        local sh2 = UI:CreateSheet(high, { title = "Over" })
        sh2:Open()
        return { pts = pts(sh), dim = sh.dim:IsShown(), foot = sh.foot == nil, ok = sh.ok == nil,
          strata2 = sh2:GetFrameStrata(), dim2 = sh2.dim:GetFrameStrata() }""")
    assert out["pts"] == [["CENTER", "UIParent", "CENTER", 0, 40]] and not out["dim"], out
    assert out["foot"] and out["ok"], out
    assert out["strata2"] == "FULLSCREEN_DIALOG" and out["dim2"] == "FULLSCREEN_DIALOG", out
    no_errors(w)


@case
def a_cover_sheet_fills_its_panel():
    w, c = solo()
    out = c.eval_py(PTS + """
        local UI = ns.UI
        local panel = CreateFrame("Frame", "OvTestPanel", UIParent)
        panel:SetSize(500, 300)
        panel:Show()
        local okd = 0
        local sh = UI:CreateSheet(panel, { cover = true, title = "Post a run",
          ok = { text = "Post", onClick = function() okd = okd + 1 end } })
        sh:Open()
        sh.ok:Click()
        return { parent = sh:GetParent() == panel, pts = pts(sh), dim = sh.dim == nil, level = sh:GetFrameLevel() >
          panel:GetFrameLevel(), okd = okd, shown = sh:IsShown() }""")
    assert out["parent"] and out["dim"] and out["level"], out
    assert out["pts"][0][1] == "OvTestPanel", out["pts"]
    assert out["okd"] == 1 and out["shown"], out
    no_errors(w)


# ------------------------------------------------------------------------------------------------------------------
# Confirm / Prompt
# ------------------------------------------------------------------------------------------------------------------
@case
def confirm_asks_and_runs_accept_or_cancel():
    w, c = solo()
    out = c.eval_py("""
        local log = {}
        ns.__ovlog = log
        local d = ns.Popup:Confirm({ title = "Delete raid", text = "Delete 100% of it?", ok = "Delete", danger = true,
          onAccept = function() log[#log + 1] = "yes" end, onCancel = function(_, why) log[#log + 1] = "no:" .. why end })
        ns.__ovd = d
        return { shown = d:IsShown(), title = d.title:GetText(), text = d.text:GetText(), b1 = d.button1:GetText(),
          b2 = d.button2:GetText(), b2shown = d.button2:IsShown(), kind = d.button1.kind,
          b3 = d.button3:IsShown() }""")
    assert out["shown"] and out["title"] == "Delete raid" and out["text"] == "Delete 100% of it?", out
    assert out["b1"] == "Delete" and out["b2"] == "Cancel" and out["b2shown"] and not out["b3"], out
    assert out["kind"] == "danger", out
    c.click(c.eval("return ns.__ovd.button1"))
    assert c.eval_py("return ns.__ovlog") == ["yes"]
    assert c.eval("return ns.__ovd:IsShown()") is False
    c.eval_py("""
        ns.__ovd = ns.Popup:Confirm({ text = "Sure?", onCancel = function(_, why) ns.__ovlog[#ns.__ovlog + 1] = "no:" .. why end })
        return true""")
    assert c.eval("return ns.__ovd.button1.kind") == "primary"
    c.eval("ns.Popup:EscapePressed()")
    assert c.eval_py("return ns.__ovlog") == ["yes", "no:clicked"]
    no_errors(w)


@case
def confirm_keeps_open_on_true_and_a_key_replaces_the_shown_one():
    w, c = solo()
    out = c.eval_py("""
        local log = {}
        ns.__ovlog = log
        local d = ns.Popup:Confirm({ key = "end", text = "End the raid?", cancel = false,
          onAccept = function() log[#log + 1] = "kept"; return true end,
          onCancel = function(_, why) log[#log + 1] = "first:" .. why end })
        ns.__ovd = d
        return { b2 = d.button2:IsShown() }""")
    assert out == {"b2": False}, out
    c.click(c.eval("return ns.__ovd.button1"))
    assert c.eval("return ns.__ovd:IsShown()") is True
    out = c.eval_py("""
        local d2 = ns.Popup:Confirm({ key = "end", text = "Really end?", alt = "Later",
          onAlt = function() ns.__ovlog[#ns.__ovlog + 1] = "alt" end })
        local other = ns.Popup:Confirm({ key = "other", text = "Another" })
        return { same = d2 == ns.__ovd, text = d2.text:GetText(), b3 = d2.button3:GetText(), log = ns.__ovlog,
          two = other ~= d2 and other:IsShown() and d2:IsShown() }""")
    assert out["same"] and out["text"] == "Really end?" and out["b3"] == "Later", out
    assert out["log"] == ["kept", "first:override"] and out["two"], out
    c.click(c.eval("return ns.__ovd.button3"))
    assert c.eval_py("return ns.__ovlog") == ["kept", "first:override", "alt"]
    no_errors(w)


@case
def prompt_fills_its_default_checks_the_value_and_hands_it_over():
    w, c = solo()
    out = c.eval_py("""
        local log = {}
        ns.__ovlog = log
        local d = ns.Popup:Prompt({ title = "Rename", text = "A new name:", default = "Board", trim = true,
          maxLetters = 24,
          validate = function(v)
            if v == "" then return false end
            if #v < 3 then return "At least 3 letters" end
            return true
          end,
          onAccept = function(v) log[#log + 1] = v end })
        ns.__ovd = d
        return { box = d.editBox:GetText(), shown = d.editBox:IsShown(), ok = d.button1:IsEnabled(),
          title = d.title:GetText(), text = d.text:GetText() }""")
    assert out == {"box": "Board", "shown": True, "ok": True, "title": "Rename", "text": "A new name:"}, out
    eb = c.eval("return ns.__ovd.editBox")
    c.type_text(eb, "")
    out = c.eval_py("return { ns.__ovd.button1:IsEnabled(), ns.__ovd.err:IsShown() }")
    assert out == [False, False], out
    c.type_text(eb, "ab")
    out = c.eval_py("return { ns.__ovd.button1:IsEnabled(), ns.__ovd.err:IsShown(), ns.__ovd.err:GetText() }")
    assert out == [False, True, "At least 3 letters"], out
    h_err = c.eval("return ns.__ovd:GetHeight()")
    c.press_enter(eb)
    assert c.eval("return ns.__ovd:IsShown()") is True and c.eval_py("return ns.__ovlog") == []
    c.type_text(eb, "  Tanks  ")
    out = c.eval_py("return { ns.__ovd.button1:IsEnabled(), ns.__ovd.err:IsShown(), ns.__ovd:GetHeight() }")
    assert out[0] is True and out[1] is False and out[2] < h_err, (out, h_err)
    c.press_enter(eb)
    assert c.eval_py("return ns.__ovlog") == ["Tanks"]
    assert c.eval("return ns.__ovd:IsShown()") is False
    no_errors(w)


@case
def a_multiline_prompt_takes_several_lines_and_ctrl_enter_is_ok():
    w, c = solo()
    out = c.eval_py("""
        local log = {}
        ns.__ovlog = log
        local d = ns.Popup:Prompt({ title = "Note", multiline = true, default = "line 1",
          onAccept = function(v) log[#log + 1] = v end })
        ns.__ovd = d
        return { multi = d.multi:IsShown() and d.multiScroll:IsShown(), field = d.editBox:IsShown(), w = d:GetWidth(),
          text = d.multi:GetText(), hint = d.multiHint:GetText(), textShown = d.text:IsShown() }""")
    assert out["multi"] and not out["field"] and out["w"] == 520 and out["text"] == "line 1", out
    assert out["hint"].startswith("Ctrl+Enter: ") and not out["textShown"], out   # (+ the OK button's text)
    mb = c.eval("return ns.__ovd.multi")
    c.type_text(mb, "line 1")
    c.press_enter(mb)
    assert c.eval("return ns.__ovd.multi:GetText()") == "line 1\n"
    c.set_modifiers(ctrl=True)
    c.press_enter(mb)
    c.set_modifiers()
    assert c.eval_py("return ns.__ovlog") == ["line 1\n"]
    # a plain dialog after it has the field again and no box
    out = c.eval_py("""
        local d = ns.Popup:Prompt({ text = "Name?" })
        return { d.editBox:IsShown(), d.multi == nil or not d.multiScroll:IsShown(), d:GetWidth() }""")
    assert out == [True, True, 380], out
    no_errors(w)


# ------------------------------------------------------------------------------------------------------------------
# HUD frames
# ------------------------------------------------------------------------------------------------------------------
@case
def a_hud_frame_keeps_its_place_in_the_one_store_and_a_lock_stops_the_drag():
    w, c = solo()
    out = c.eval_py(PTS + """
        local UI = ns.UI
        local moved = 0
        local locked = false
        local f = UI:CreateHudFrame("OvTestHud", { width = 240, height = 30, default = { "TOP", nil, "TOP", 0, -200 },
          strata = "HIGH", isLocked = function() return locked end, onMoved = function() moved = moved + 1 end,
          escape = true, close = true })
        ns.__ovf = f
        local res = { pts = pts(f), size = { f:GetWidth(), f:GetHeight() }, strata = f:GetFrameStrata(),
          movable = f:IsMovable(), special = false, close = f.close ~= nil, edges = f.edges ~= nil }
        for _, n in ipairs(UISpecialFrames) do if n == "OvTestHud" then res.special = true end end
        -- a drag: moved, its place saved under its name
        __MOCK.call_script(f, "OnDragStart", "LeftButton")
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 100.4, -50.6)
        __MOCK.call_script(f, "OnDragStop")
        res.saved = ns.db.settings.windows.OvTestHud
        res.moved = moved
        -- locked: no drag
        locked = true
        __MOCK.call_script(f, "OnDragStart", "LeftButton")
        f:ClearAllPoints()
        f:SetPoint("CENTER")
        __MOCK.call_script(f, "OnDragStop")
        res.lockedSaved = ns.db.settings.windows.OvTestHud
        res.lockedMoved = moved
        res.isLocked = f:IsLocked()
        locked = false
        f:SetLocked(true)
        res.setLocked = f:IsLocked()
        f:SetLocked(false)
        -- made again: it comes back where it was saved
        local g = UI:CreateHudFrame("OvTestHud2", { position = "OvTestHud" })
        res.restored = pts(g)
        f:ResetPlace()
        res.reset = { ns.db.settings.windows.OvTestHud == nil, pts(f) }
        return res""")
    assert out["pts"] == [["TOP", "UIParent", "TOP", 0, -200]], out["pts"]
    assert out["size"] == [240, 30] and out["strata"] == "HIGH" and out["movable"], out
    assert out["special"] and out["close"] and out["edges"], out
    assert out["saved"] == ["TOPLEFT", "TOPLEFT", 100, -51] and out["moved"] == 1, out
    assert out["lockedSaved"] == ["TOPLEFT", "TOPLEFT", 100, -51] and out["lockedMoved"] == 1, out
    assert out["isLocked"] and out["setLocked"], out
    assert out["restored"] == [["TOPLEFT", "UIParent", "TOPLEFT", 100, -51]], out["restored"]
    assert out["reset"][0] and out["reset"][1] == [["TOP", "UIParent", "TOP", 0, -200]], out["reset"]
    c.click(c.eval("return ns.__ovf.close"))
    assert c.eval("return ns.__ovf:IsShown()") is False
    no_errors(w)


@case
def a_hud_frame_dragged_by_a_handle_or_kept_nowhere():
    w, c = solo()
    out = c.eval_py(PTS + """
        local UI = ns.UI
        local f = UI:CreateHudFrame("OvTestHud3", { position = false, movable = false, look = "card" })
        local res = { pts = pts(f), movable = f:IsMovable(), saveNone = f:SavePlace() }
        local closed = 0
        local g = UI:CreateHudFrame(nil, { position = "OvTestHandle", look = "none",
          close = function() closed = closed + 1 end })
        local handle = CreateFrame("Frame", nil, g)
        g:SetDragHandle(handle)
        __MOCK.call_script(handle, "OnDragStart", "LeftButton")
        g:ClearAllPoints()
        g:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, 80)
        __MOCK.call_script(handle, "OnDragStop")
        res.saved = ns.db.settings.windows.OvTestHandle
        g.close:Click()
        res.closed = closed
        res.gShown = g:IsShown()
        res.gBg = g.bg == nil
        res.cardBg = f.bg ~= nil
        return res""")
    assert out["pts"] == [["CENTER", "UIParent", "CENTER", 0, 0]] and out["saveNone"] is False, out
    assert out["saved"] == ["BOTTOM", "BOTTOM", 0, 80], out
    assert out["closed"] == 1 and out["gShown"] and out["gBg"] and out["cardBg"], out
    no_errors(w)


if __name__ == "__main__":
    run_all()
