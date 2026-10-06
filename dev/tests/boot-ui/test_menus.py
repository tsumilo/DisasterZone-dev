"""The addon's own menus (UI/Menu.lua): every dropdown and right-click menu is drawn by the addon in the flat look of
the New raid calendar and the invite search, and drops in the same way (UI:DropIn).

- a dropdown's menu hangs under it (4px gap, at least as wide), fades up while it falls the last 6px, lights the
  dropdown (gold edges, chevron up); a pick closes it, the dropdown shows the pick
- a check box keeps the menu open and repaints; a disabled entry does nothing; MenuResponse answers are followed
- a submenu opens beside its row on hover (sliding out), another row closes it; Close from it closes only it
- a large owner (a row) or a right-click opens the menu at the cursor
- a click outside, Escape, the owner hiding or a second click on the dropdown closes it
- scroll mode caps the height: a thumb, the wheel scrolls, rows out of view take no clicks
- queued dividers only show between entries; an empty menu shows nothing
- the search dropdown's list and the comp steps drop in the same way, from the shared panel look

Run: luaenv\\Scripts\\python.exe tests\\boot-ui\\test_menus.py
"""
from _common import case, run_all, solo, no_errors, install_helpers

HOST = r"""
T_host = CreateFrame("Frame", nil, UIParent)
T_host:SetSize(600, 400)
T_host:SetPoint("CENTER")
T_pick = "b"
T_dd = ns.UI:CreateSleekDropdown(T_host, 150, function()
  return { { value = "a", text = "Apples" }, { value = "b", text = "Bananas" }, { value = "c", text = "Cherries" } }
end, function() return T_pick end, function(v) T_pick = v end)
T_dd:SetPoint("TOPLEFT", 20, -20)
function T_frames() local f, d = ns.UI:GetMenuFrames(); return f, d end
function T_row(level, text)
  local f = T_frames()[level]
  for _, r in ipairs(f.rows) do if r.desc and r.desc.text == text then return r end end
end
function T_point(f) local p, rel, rp, x, y = f:GetPoint(1); return { p, rp, x, y } end
-- the chevron points up (its top-left corner takes the texture's bottom)
function T_up(tex) local _, uly, _, lly = tex:GetTexCoord(); return uly > lly end
"""


def client():
    w, c = solo("Alice", tick=2)
    install_helpers(c)
    c.eval("__MOCK.real_geometry = true")
    c.eval(HOST)
    return w, c


def frames(c):
    return c.eval_py("local f, d = T_frames(); local o = {} for i = 1, #f do o[i] = f[i]:IsShown() end return { o, d }")


# ------------------------------------------------------------------------------------------------------------------
@case
def a_dropdown_drops_its_menu_under_it_and_a_pick_closes_it():
    w, c = client()
    c.click(c.eval("return T_dd"))
    assert c.eval("return ns.UI:GetOpenMenu() ~= nil") is True
    root = c.eval("return T_frames()[1]")
    # it drops in: transparent and 6px higher at first, in place and opaque after the drop
    first = c.eval_py("local f = T_frames()[1]; return { f:GetAlpha(), unpack(T_point(f)) }")
    assert first[0] < 1 and first[1:] == ["TOPLEFT", "BOTTOMLEFT", 0, 2], first
    w.tick(0.3, step=0.02)
    after = c.eval_py("local f = T_frames()[1]; return { f:GetAlpha(), unpack(T_point(f)) }")
    assert after == [1, "TOPLEFT", "BOTTOMLEFT", 0, -4], after
    assert c.eval("return T_frames()[1]:GetWidth() >= 150") is True
    # the dropdown is lit (gold edges) and its chevron points up while the menu is down
    assert c.eval("return T_dd.lit") is True
    assert c.eval("return T_up(T_dd.chevron)") is True
    # three radios, the picked one with its gold dot
    rows = c.eval_py("local o = {} for _, r in ipairs(T_frames()[1].rows) do if r.desc and r:IsShown() then "
                     "o[#o + 1] = { r.desc.kind, r.desc.text, r.dot:IsShown() } end end return o")
    assert rows == [["radio", "Apples", False], ["radio", "Bananas", True], ["radio", "Cherries", False]], rows
    c.click(c.eval("return T_row(1, 'Cherries')"))
    assert c.eval("return T_pick") == "c"
    assert c.eval("return ns.UI:GetOpenMenu() == nil and not T_frames()[1]:IsShown()") is True
    assert c.eval("return T_dd:GetText()") == "Cherries"
    assert not c.eval("return T_dd.lit"), "the dropdown stays lit after its menu closed"
    assert c.eval("return T_up(T_dd.chevron)") is False
    assert root is not None
    no_errors(w)


@case
def check_boxes_keep_the_menu_open_and_disabled_entries_do_nothing():
    w, c = client()
    c.eval("""
      T_on = { x = true }
      T_hits = 0
      T_m = ns.UI:CreateMultiDropdown(T_host, 160, function()
        return { { value = 'x', text = 'Xeno' }, { value = 'y', text = 'Yak' }, { isDivider = true },
                 { isButton = true, text = 'Clear', onClick = function() T_on = {} end },
                 { value = 'z', text = 'Zed', disabled = true } }
      end, function(v) return T_on[v] end, function(v, on) T_on[v] = on or nil; T_hits = T_hits + 1 end,
      function() local n = 0 for _ in pairs(T_on) do n = n + 1 end return n .. ' picked' end)
      T_m:SetPoint('TOPLEFT', 200, -20)
    """)
    c.click(c.eval("return T_m"))
    c.click(c.eval("return T_row(1, 'Yak')"))
    assert c.eval("return T_on.y") is True and c.eval("return ns.UI:GetOpenMenu() ~= nil") is True
    assert c.eval("return T_row(1, 'Yak').check:IsShown()") is True
    assert c.eval("return T_m:GetText()") == "2 picked"
    # disabled: nothing happens, the menu stays
    c.click(c.eval("return T_row(1, 'Zed')"))
    assert c.eval("return T_on.z") is None and c.eval("return T_hits") == 1
    assert c.eval("return ns.UI:GetOpenMenu() ~= nil") is True
    # a divider row, then a button that closes the menu
    kinds = c.eval_py("local o = {} for _, r in ipairs(T_frames()[1].rows) do if r.desc then o[#o + 1] = r.desc.kind end end return o")
    assert kinds == ["checkbox", "checkbox", "divider", "button", "checkbox"], kinds
    c.click(c.eval("return T_row(1, 'Clear')"))
    assert c.eval("return ns.UI:GetOpenMenu() == nil") is True and c.eval("return next(T_on)") is None
    no_errors(w)


SUBMENU = r"""
T_size = 25
T_last = nil
T_menuObj = ns.UI:ContextMenu(T_dd, function(root)
  root:CreateTitle('Lineup')
  root:CreateButton('Rename', function() T_last = 'rename' end)
  local sub = root:CreateButton('Size')
  sub:CreateRadio('10-man', function() return T_size == 10 end, function() T_size = 10 end)
  sub:CreateRadio('25-man', function() return T_size == 25 end, function() T_size = 25 end)
  sub:CreateButton('Keep open', function() T_last = 'open'; return MenuResponse.Open end)
  sub:CreateButton('Close me', function() T_last = 'close'; return MenuResponse.Close end)
  root:QueueDivider()
  root:CreateButton('Copy', function() T_last = 'copy'; return MenuResponse.Refresh end)
  root:QueueDivider()
end)
"""


@case
def a_submenu_slides_out_beside_its_row_and_answers_are_followed():
    w, c = client()
    c.eval(SUBMENU)
    w.tick(0.3, step=0.02)
    # (the trailing queued divider is not shown; the one between entries is)
    kinds = c.eval_py("local o = {} for _, r in ipairs(T_frames()[1].rows) do if r.desc then o[#o + 1] = r.desc.kind end end return o")
    assert kinds == ["title", "button", "button", "divider", "button"], kinds
    size = c.eval("return T_row(1, 'Size')")
    assert c.eval("return T_row(1, 'Size').arrow:IsShown()") is True
    c.hover(size)
    assert frames(c) == [[True, True], 2], frames(c)
    first = c.eval_py("local f = T_frames()[2]; return { f:GetAlpha(), unpack(T_point(f)) }")
    assert first[0] < 1 and first[1:3] == ["TOPLEFT", "TOPRIGHT"] and first[3] < 7, first
    w.tick(0.3, step=0.02)
    assert c.eval_py("return T_point(T_frames()[2])") == ["TOPLEFT", "TOPRIGHT", 7, 5]
    assert c.eval("return T_row(1, 'Size').hl:IsShown()") is True       # (its row stays lit while it is open)
    # Open keeps everything; Close closes the submenu only
    c.click(c.eval("return T_row(2, 'Keep open')"))
    assert c.eval("return T_last") == "open" and frames(c)[1] == 2
    c.click(c.eval("return T_row(2, 'Close me')"))
    assert c.eval("return T_last") == "close" and frames(c) == [[True, False], 1], frames(c)
    # another row closes an open submenu
    c.hover(size)
    assert frames(c)[1] == 2
    c.hover(c.eval("return T_row(1, 'Rename')"))
    assert frames(c)[1] == 1
    # Refresh keeps it open; a radio in the submenu closes everything
    c.click(c.eval("return T_row(1, 'Copy')"))
    assert c.eval("return T_last") == "copy" and c.eval("return T_menuObj:IsShown()") is True
    c.hover(size)
    assert c.eval("return T_row(2, '25-man').dot:IsShown()") is True
    c.click(c.eval("return T_row(2, '10-man')"))
    assert c.eval("return T_size") == 10 and c.eval("return T_menuObj:IsShown()") is False
    assert frames(c) == [[False, False], 0], frames(c)
    no_errors(w)


@case
def rows_and_right_clicks_open_at_the_cursor():
    w, c = client()
    c.eval("""
      T_rowOwner = CreateFrame('Button', nil, T_host)
      T_rowOwner:SetSize(560, 20)
      T_rowOwner:SetPoint('TOPLEFT', 20, -100)
      ns.UI:ContextMenu(T_rowOwner, function(root) root:CreateButton('Show member', function() end) end)
    """)
    assert c.eval("return ns.UI:GetOpenMenu().anchored") is False
    p = c.eval_py("return T_point(T_frames()[1])")
    assert p[0] == "TOPLEFT" and p[1] == "BOTTOMLEFT", p
    assert c.eval("local _, rel = T_frames()[1]:GetPoint(1); return rel == UIParent") is True
    # owner.cdlMenuAt = 'cursor' asks for it on a small button too
    c.eval("T_dd.cdlMenuAt = 'cursor'; ns.UI:ContextMenu(T_dd, function(root) root:CreateButton('X', function() end) end)")
    assert c.eval("return ns.UI:GetOpenMenu().anchored") is False
    no_errors(w)


@case
def a_click_outside_escape_the_owner_hiding_or_its_second_click_close_it():
    w, c = client()
    def open_dd():
        c.click(c.eval("return T_dd"))
        assert c.eval("return ns.UI:GetOpenMenu() ~= nil") is True
    open_dd()
    c.eval("__MOCK.fire('GLOBAL_MOUSE_DOWN', 'LeftButton')")            # (nothing is under the mouse in the mock)
    assert c.eval("return ns.UI:GetOpenMenu() == nil") is True
    open_dd()
    c.eval("local f = T_frames()[1]; f:GetScript('OnKeyDown')(f, 'ESCAPE')")
    assert c.eval("return ns.UI:GetOpenMenu() == nil") is True
    open_dd()
    c.eval("T_host:Hide()")
    w.tick(0.1)
    assert c.eval("return ns.UI:GetOpenMenu() == nil") is True
    c.eval("T_host:Show()")
    open_dd()
    # a press on the open dropdown (GLOBAL_MOUSE_DOWN over it), then its click: closed, not opened again
    c.eval("T_dd.IsMouseOver = function() return true end; __MOCK.fire('GLOBAL_MOUSE_DOWN', 'LeftButton')")
    assert c.eval("return ns.UI:GetOpenMenu() ~= nil") is True
    c.click(c.eval("return T_dd"))
    assert c.eval("return ns.UI:GetOpenMenu() == nil") is True
    # (without the press, as code or the tests open it: opened again)
    c.eval("T_dd.IsMouseOver = nil")
    open_dd()
    open_dd()
    no_errors(w)


@case
def scroll_mode_caps_the_height_and_the_wheel_scrolls():
    w, c = client()
    c.eval("""
      ns.UI:ContextMenu(T_dd, function(root)
        root:SetScrollMode(200)
        for i = 1, 30 do root:CreateButton('Player ' .. i, function() end) end
      end)
    """)
    f = c.eval_py("local f = T_frames()[1]; return { f:GetHeight(), f.scrolls, f.thumb:IsShown(), f.offset }")
    assert f == [210, True, True, 0], f
    assert c.eval("return T_row(1, 'Player 1'):IsMouseEnabled()") is True
    assert c.eval("return T_row(1, 'Player 20'):IsMouseEnabled()") is False
    c.eval("local f = T_frames()[1]; f:GetScript('OnMouseWheel')(f, -3)")
    assert c.eval("return T_frames()[1].offset") == 120
    assert c.eval("return T_row(1, 'Player 1'):IsMouseEnabled()") is False
    assert c.eval("return T_row(1, 'Player 12'):IsMouseEnabled()") is True
    c.eval("local f = T_frames()[1]; for i = 1, 10 do f:GetScript('OnMouseWheel')(f, -3) end")
    assert c.eval("return T_frames()[1].offset") == 400            # (30 rows x 20 - 200: the end)
    no_errors(w)


@case
def the_harness_picks_entries_the_way_a_click_does():
    w, c = client()
    c.click(c.eval("return T_dd"))
    menu = c.last_menu()
    assert [ch["text"] for ch in menu["children"]] == ["Apples", "Bananas", "Cherries"], menu
    assert [ch["selected"] for ch in menu["children"]] == [False, True, False]
    c.menu_select("Apples")
    assert c.eval("return T_pick") == "a" and c.eval("return ns.UI:GetOpenMenu() == nil") is True
    # an empty menu shows nothing (and is still the last menu)
    assert c.eval("return ns.UI:ContextMenu(T_dd, function() end)") is None
    assert c.last_menu()["children"] == []
    no_errors(w)


@case
def the_search_list_drops_in_like_a_menu():
    w, c = client()
    c.eval("""
      T_sd = ns.UI:CreateSearchDropdown(T_host, 180, { placeholder = 'Invite players',
        getItems = function() return { { key = 'Bob-Realm', text = 'Bob', classFile = 'MAGE' } } end,
        isChecked = function() return false end, onToggle = function() end })
      T_sd.frame:SetPoint('TOPLEFT', 20, -200)
      T_sd:Open()
    """)
    first = c.eval_py("local p = T_sd.panel; return { p:GetAlpha(), unpack(T_point(p)) }")
    assert first[0] < 1 and first[1:] == ["TOPLEFT", "BOTTOMLEFT", 0, 2], first
    w.tick(0.3, step=0.02)
    assert c.eval_py("local p = T_sd.panel; return { p:GetAlpha(), unpack(T_point(p)) }") == [1, "TOPLEFT", "BOTTOMLEFT", 0, -4]
    assert c.eval("return T_up(T_sd.arrow.icon)") is True       # (the chevron up while open)
    c.eval("T_sd:Close()")
    assert c.eval("return T_up(T_sd.arrow.icon)") is False
    no_errors(w)


if __name__ == "__main__":
    run_all()
