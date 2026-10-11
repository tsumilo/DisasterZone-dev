if DisasterZoneBoot and DisasterZoneBoot.Run("UI/SimBuffs.lua", ...) then return end -- DisasterZone: UI/SimBuffs.lua
-- ns.SimBuffsUI: the gear sim's buff editor, docked beside the main window like the item picker (UI/Picker.lua).
-- Edits a draft: a preset of mine (a buff config; Start from 25-man / 10-man / None fills it) or a team lineup
-- (Start from Team: who is placed brings the buffs, my clicks are kept as overrides; ns.SimBuffs). Tiles in four
-- sections (your group, the raid, the boss, what you bring): a click goes off -> on -> improved, a right-click back.
-- Save stores it (presets: for all your characters) and picks it on the sim card.
local _, ns = ...

local SimBuffsUI = {}
ns.SimBuffsUI = SimBuffsUI

local UI, S = ns.UI, ns.Style
local floor, max = math.floor, math.max

local GOLD = S.C.GOLD_DEEP        -- the tiles' gold edge and dot (D1: fills and edges)
local WIDTH = 492
local COLS, TILE_H, GAP, PADX = 3, 30, 4, 8
local GOLD_HEX = S:Hex("GOLD")    -- "set by you" in the tiles' lines

local win, draft, view
local tiles, headers = {}, {}

local function SB() return ns.SimBuffs end
local function R() return ns.SimRunner end
local function MyClass()
  local _, cls = UnitClass("player")
  return cls
end
local function Base(key) return R():BaseConfig(key or "raid25") end

-- ---------------------------------------------------------------------------------------------------------------
-- The draft
-- ---------------------------------------------------------------------------------------------------------------
-- draft = { kind = "custom" | "team", id = preset id | nil, name, cfg (custom), from = "raid25" | "raid10" | "solo" |
-- nil, teamId, ln, st = { open, ov } (team), dirty }
local function CustomDraft(cfg, name, id, from)
  return { kind = "custom", cfg = SB():Normalize(cfg), name = name, id = id, from = from }
end

local function TeamDraft(teamId, ln)
  local plan = ns.RaidPlan
  local team = plan and plan:GetTeam(teamId)
  local l = team and plan:FindLineup(team, ln)
  if not l then return nil end
  return { kind = "team", teamId = teamId, ln = ln, st = SB():GetTeamState(teamId, ln),
    name = SB():LineupLabel(team, l) }
end

-- What the editor shows: cfg and (team) info.
local function Compute()
  if draft.kind == "team" then
    local cfg, info = SB():TeamConfig(draft.teamId, draft.ln, draft.st, MyClass(), Base())
    view = { cfg = cfg or SB():Normalize({}), info = info }
  else
    view = { cfg = draft.cfg }
  end
end

local function DraftFromKey(key)
  local kind, a, b = SB():ParseKey(key)
  if kind == "preset" then
    local p = SB():GetPreset(a)
    if p then return CustomDraft(p.cfg, p.name, p.id) end
  elseif kind == "team" then
    local d = TeamDraft(a, b)
    if d then return d end
  end
  return nil
end

-- A new preset starts as a copy of what the card uses now.
local function NewDraft()
  local cur = ns.SimPanel and ns.SimPanel:GetBuffs() or "raid25"
  if R():IsBaseKey(cur) then return CustomDraft(Base(cur), "New preset", nil, cur) end
  local cfg = R():BuffConfig(cur)
  return CustomDraft(cfg, "New preset", nil, nil)
end

-- ---------------------------------------------------------------------------------------------------------------
-- Tiles
-- ---------------------------------------------------------------------------------------------------------------
local function TileIcon(t)
  if t.item then
    local icon = UI:ItemIcon(t.item)
    if icon and icon ~= 134400 then return icon end    -- (not UI:ItemIcon's question mark: the tile's own icon then)
  end
  return "Interface\\Icons\\" .. t.icon
end

-- A buff the simmed class brings itself (a Warrior's shout, a Shaman's totems): shown, not clickable.
local function Own(t) return t.own and t.own[MyClass()] or nil end
local function Shouts(t) return Own(t) ~= nil end

-- The tile's line under its name, and how it looks: text, dim (off), open (an open comp slot brings it), changed.
local function TileLine(t, v)
  local S = SB()
  local stateText = S:StateText(t, v)
  if Shouts(t) then return Own(t)[1], true end
  local info = view.info
  if not info or t.sec == "mine" then
    local changed = info and info.tiles[t.key] and info.tiles[t.key].changed
    if v == 0 then return changed and (GOLD_HEX .. "off (you)|r") or "off", true end
    if t.kind == "tri" and v == 2 then return GOLD_HEX .. "Improved|r", false, false, changed end
    return (t.states and stateText or "on") .. (changed and (GOLD_HEX .. " (you)|r") or ""), false, false, changed
  end
  local ti = info.tiles[t.key] or { who = {} }
  local who = ti.who or {}
  local open = false
  for _, m in ipairs(who) do if m.open then open = true end end
  if ti.changed then
    if v == 0 then return GOLD_HEX .. "off \194\183 set by you|r", true, false, true end
    local s = (t.kind == "tri" and v == 2) and "Improved" or (t.kind == "count" and S:StateText(t, v) or "on")
    return GOLD_HEX .. s .. " \194\183 set by you|r", false, false, true
  end
  if v == 0 then
    if t.noInfer then return "click if someone brings it", true end
    if t.sec == "group" then
      return info.group and ("nobody in group " .. info.group) or "you're in no group", true
    end
    return "no " .. (t.needs or "one"), true
  end
  local names = S:WhoText(who, 2)
  if t.kind == "tri" and v == 2 then names = GOLD_HEX .. "Improved|r" .. (names ~= "" and (" \194\183 " .. names) or "") end
  if t.kind == "count" and v > 1 then names = "x" .. v .. " \194\183 " .. names end
  return names, false, open
end

local function PaintTile(f)
  local t = f.tile
  local v = SB():Get(view.cfg, t)
  f.icon:SetTexture(TileIcon(t))
  f.name:SetText(t.name)
  local line, dim, open, changed = TileLine(t, v)
  f.sub:SetText(line or "")
  f:SetAlpha(dim and 0.45 or 1)
  if open then
    UI:SetEdgeColor(f, GOLD[1], GOLD[2], GOLD[3], 0.9)
  else
    UI:SetEdgeColor(f, S:Color("EDGE"))
  end
  f.dot:SetShown(changed and true or false)
  f.hl:SetShown(f.hovered and not Shouts(t) or false)
end

-- A tile's tooltip (UI:AttachTooltip): what it does, its state now, who brings it in the lineup, the clicks.
local function FillTileTip(f, tt)
  local t = f.tile
  if not (t and view) then return false end
  local B = SB()
  local v = B:Get(view.cfg, t)
  local gr, gg, gb = S:Color("GOLD")
  tt:AddLine(t.name, gr, gg, gb)
  if t.tip then tt:AddLine(t.tip, 1, 1, 1, true) end
  if Shouts(t) then
    tt:AddLine(Own(t)[2], 1, 1, 1, true)
    return
  end
  tt:AddLine("Now: " .. B:StateText(t, v), 0.8, 0.8, 0.8)
  local ti = view.info and view.info.tiles[t.key]
  if ti and t.sec ~= "mine" then
    local who = B:WhoText(ti.who, 6)
    if who ~= "" then tt:AddLine("From the lineup: " .. who, 1, 1, 1, true) end
    if ti.changed then
      tt:AddLine(("The lineup says %s; you set it. Click until it matches to follow the lineup again.")
        :format(B:StateText(t, ti.inferred or 0)), gr, gg, gb, true)
    end
  end
  local names = {}
  for i = 0, B:StateCount(t) - 1 do names[#names + 1] = B:StateText(t, i) end
  local sr, sg, sb = S:Color("SUB")
  tt:AddLine("Click: " .. table.concat(names, " > ") .. ". Right-click: back.", sr, sg, sb, true)
end

-- (the tooltip again after a click changed the tile under the mouse)
local function TileTooltip(f)
  GameTooltip:SetOwner(f, "ANCHOR_RIGHT")
  if FillTileTip(f, GameTooltip) == false then GameTooltip:Hide() return end
  GameTooltip:Show()
end

local function ClickTile(f, button)
  local t = f.tile
  if Shouts(t) then return end
  local S = SB()
  local v = S:Get(view.cfg, t)
  local nv = S:NextState(t, v, button == "RightButton")
  if draft.kind == "team" then
    local ti = view.info and view.info.tiles[t.key]
    local follows
    if t.sec == "mine" then
      local base = S:Normalize({ consumables = S.Copy(Base().consumables or {}) })
      follows = S:Get(base, t) == nv
    else
      follows = ti and ti.inferred == nv
    end
    draft.st.ov[t.key] = (not follows) and nv or nil
  else
    S:Set(draft.cfg, t, nv)
  end
  draft.dirty = true
  SimBuffsUI:Refresh()
  if f.hovered then TileTooltip(f) end
end

local function NewTile(parent)
  local f = CreateFrame("Button", nil, parent)
  f:SetHeight(TILE_H)
  f:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  f.bg = UI:Fill(f, "CARD")
  UI:AddEdges(f, "BORDER")
  f.hl = f:CreateTexture(nil, "ARTWORK")
  f.hl:SetPoint("TOPLEFT", 1, -1)
  f.hl:SetPoint("BOTTOMRIGHT", -1, 1)
  f.hl:SetColorTexture(S:Color("SELECT"))
  f.hl:Hide()
  f.icon = f:CreateTexture(nil, "ARTWORK")
  f.icon:SetSize(22, 22)
  f.icon:SetPoint("LEFT", 4, 0)
  f.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  f.name = UI:Text(f, "small", "TEXT")
  f.name:SetPoint("TOPLEFT", f.icon, "TOPRIGHT", 5, 0)
  f.name:SetPoint("RIGHT", f, "RIGHT", -4, 0)
  f.sub = UI:Text(f, "caps", "SUB")
  f.sub:SetPoint("BOTTOMLEFT", f.icon, "BOTTOMRIGHT", 5, 0)
  f.sub:SetPoint("RIGHT", f, "RIGHT", -4, 0)
  f.dot = f:CreateTexture(nil, "OVERLAY")
  f.dot:SetSize(4, 4)
  f.dot:SetPoint("TOPRIGHT", -3, -3)
  f.dot:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 1)
  f.dot:Hide()
  f:SetScript("OnEnter", function(self)
    self.hovered = true
    PaintTile(self)
  end)
  f:SetScript("OnLeave", function(self)
    self.hovered = false
    PaintTile(self)
  end)
  UI:AttachTooltip(f, FillTileTip)
  f:SetScript("OnClick", ClickTile)
  return f
end

-- ---------------------------------------------------------------------------------------------------------------
-- Window
-- ---------------------------------------------------------------------------------------------------------------
local function Position()
  win:ClearAllPoints()
  local main = ns.MainFrame and ns.MainFrame:IsShown() and ns.MainFrame:GetFrame() or nil
  if main then
    win:SetHeight(main:GetHeight() or 608)
    local right, left = main:GetRight(), main:GetLeft()
    local screenRight = UIParent:GetRight()
    if right and left and screenRight and right + WIDTH + 2 > screenRight and left - WIDTH - 2 >= 0 then
      win:SetPoint("TOPRIGHT", main, "TOPLEFT", -2, 0)
    else
      win:SetPoint("TOPLEFT", main, "TOPRIGHT", 2, 0)
    end
  else
    win:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
  end
end

local CHIPS = { { key = "raid25", text = "25-man" }, { key = "raid10", text = "10-man" }, { key = "solo", text = "None" } }

local function StartFrom(key)
  local keepName = draft.kind == "custom" and draft.name or "New preset"
  draft = CustomDraft(Base(key), keepName, draft.kind == "custom" and draft.id or nil, key)
  draft.dirty = true
  SimBuffsUI:Refresh()
end

local function FollowTeam(l)
  local d = TeamDraft(l.teamId, l.ln)
  if not d then return end
  draft = d
  draft.dirty = true
  SimBuffsUI:Refresh()
end

local function EnsureWindow()
  if win then return win end
  win = UI:CreateWindow("DisasterZoneSimBuffs", "Buffs", WIDTH, 608, { noSavePosition = true })
  win:Hide()
  local c = win.content

  -- a tool window (UI:CreateLayout "tool"): the banner says what the draft follows, the tool row where it starts
  -- from, an info notice how the tiles work; the tiles and the footer fill the body
  local L = UI:CreateLayout("tool", c, { width = WIDTH - 10, pad = PADX, bottom = 0, toolbar = true,
    banner = { size = "strip", title = "Your preset" } })
  win.layout = L
  local row = L.toolbar

  -- Start from
  local lbl = UI:Text(row, "small", "SUB")
  lbl:SetPoint("LEFT", row, "LEFT", 0, 0)
  lbl:SetText("Start from")
  win.chips = {}
  local prev
  for _, ch in ipairs(CHIPS) do
    local b = UI:CreateSleekButton(row, ch.text, 58, 20, function() StartFrom(ch.key) end, "secondary")
    b:GetFontString():SetFontObject("GameFontHighlightSmall")
    if prev then b:SetPoint("LEFT", prev, "RIGHT", 4, 0) else b:SetPoint("LEFT", lbl, "RIGHT", 10, 0) end
    b.key = ch.key
    win.chips[#win.chips + 1] = b
    prev = b
  end
  win.team = UI:CreateSleekMenuButton(row, "Team", 150, function(root)
    local lineups = SB():MyLineups()
    if #lineups == 0 then
      local e = root:CreateButton("You're on no team's roster yet", function() end)
      e:SetEnabled(false)
      return
    end
    root:CreateTitle("Follow who is placed in")
    for _, l in ipairs(lineups) do
      root:CreateRadio(l.name, function() return draft.kind == "team" and draft.teamId == l.teamId and draft.ln == l.ln end,
        function() FollowTeam(l) end, l.key)
    end
  end, 20)
  win.team:SetPoint("LEFT", prev, "RIGHT", 4, 0)
  win.team:SetWidth(120)
  win.teamAfter = prev
  UI:AttachTooltip(win.team, "Team", { "Follow a lineup of a team you're on: your group's party buffs, the raid's buffs "
    .. "and the boss debuffs come from the specs placed there, and change with it." }, { anchor = "ANCHOR_TOP" })

  -- the banner: what the draft follows (its title and sub line, set by Refresh); a team's open comp slots on a
  -- checkbox at the top of the body
  win.banner = L.banner
  local cb = UI:CreateCheckbox(L.body, "", function() return draft and draft.kind == "team" and draft.st.open ~= false end,
    function(v)
      if draft.kind ~= "team" then return end
      draft.st.open = v and true or false
      draft.dirty = true
      SimBuffsUI:Refresh()
    end)
  cb:SetPoint("TOPLEFT", L.body, "TOPLEFT", -4, 2)
  win.openBox = cb

  -- the tiles
  local sf = UI:CreateScrollFrame(c)
  sf:SetPoint("TOPLEFT", L.body, "TOPLEFT", 0, 0)
  sf:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", -PADX - 8, 52)
  win.scrollTop = function(y)
    sf:SetPoint("TOPLEFT", L.body, "TOPLEFT", 0, -y)
  end
  local body = CreateFrame("Frame", nil, sf)
  body:SetSize(WIDTH - 2 * PADX - 30, 10)
  sf:SetScrollChild(body)
  win.scroll, win.body = sf, body

  -- footer
  win.note = UI:Text(c, "caps", "DIM", { justify = "RIGHT" })
  win.note:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", -PADX, 36)
  win.save = UI:CreateSleekButton(c, "Save", 76, S.BTN_H, function() SimBuffsUI:Save() end, "primary")
  win.save:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", -PADX, 6)
  win.del = UI:CreateSleekButton(c, "Delete", 76, S.BTN_H, function() SimBuffsUI:Delete() end, "secondary")
  win.del:SetPoint("RIGHT", win.save, "LEFT", -6, 0)
  win.name = UI:CreateSleekEditBox(c, 200, S.BTN_H)
  win.name:SetPoint("BOTTOMLEFT", c, "BOTTOMLEFT", PADX, 6)
  win.name:SetPoint("RIGHT", win.del, "LEFT", -8, 0)
  win.name:SetMaxLetters(SB().MAX_NAME)
  win.name:SetScript("OnTextChanged", function(self, user)
    if user and draft and draft.kind == "custom" then
      draft.name = self:GetText()
      draft.dirty = true
      SimBuffsUI:RefreshFooter()
    end
  end)
  win.name:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  win.name:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  win:HookScript("OnHide", function()
    GameTooltip:Hide()
    draft, view = nil, nil
  end)
  return win
end

-- ---------------------------------------------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------------------------------------------
local function Header(i)
  local h = headers[i]
  if not h then
    h = UI:CreateSectionHeader(win.body, "", { style = "caps" })
    h:SetHeight(18)
    headers[i] = h
  end
  return h
end

function SimBuffsUI:Layout()
  local S = SB()
  local body = win.body
  local w = body:GetWidth()
  local colW = floor((w - (COLS - 1) * GAP) / COLS)
  local y, n, nh = 0, 0, 0
  local cls = MyClass()
  for _, sec in ipairs(S.SECTIONS) do
    local list = S:Tiles(cls, sec.key)
    if #list > 0 then
      nh = nh + 1
      local h = Header(nh)
      h:ClearAllPoints()
      h:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -y)
      h:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, -y)
      local title, hint = sec.title, sec.hint
      if sec.key == "group" and view.info then
        title = view.info.group and (title .. " \194\183 GROUP " .. view.info.group) or (title .. " \194\183 NO GROUP YET")
      end
      h:SetTitle(title)
      h:SetRight(hint)
      h:Show()
      y = y + 18
      for i, t in ipairs(list) do
        n = n + 1
        local f = tiles[n] or NewTile(body)
        tiles[n] = f
        f.tile = t
        local col = (i - 1) % COLS
        local row = floor((i - 1) / COLS)
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", body, "TOPLEFT", col * (colW + GAP), -(y + row * (TILE_H + GAP)))
        f:SetWidth(colW)
        PaintTile(f)
        f:Show()
      end
      y = y + floor((#list + COLS - 1) / COLS) * (TILE_H + GAP) + 4
    end
  end
  for i = n + 1, #tiles do tiles[i]:Hide() end
  for i = nh + 1, #headers do headers[i]:Hide() end
  body:SetHeight(max(y, 10))
end

function SimBuffsUI:RefreshFooter()
  if not (win and draft) then return end
  local custom = draft.kind == "custom"
  local nameOk = not custom or (draft.name or ""):gsub("%s", "") ~= ""
  win.save:SetEnabled((draft.dirty and nameOk) and true or false)
  if custom then
    win.del:SetText("Delete")
    win.del:SetEnabled(draft.id ~= nil)
    win.note:SetText("Saved for all your characters.")
  else
    win.del:SetText("Reset")
    local st = draft.st
    win.del:SetEnabled((st.open == false or next(st.ov) ~= nil) and true or false)
    win.note:SetText("Your changes stay on top of the lineup.")
  end
end

function SimBuffsUI:Refresh()
  if not (win and win:IsShown() and draft) then return end
  Compute()
  local custom = draft.kind == "custom"
  win:SetWindowTitle("Buffs \194\183 " .. ((draft.name and draft.name ~= "") and draft.name or "New preset"))
  for _, b in ipairs(win.chips) do
    local on = custom and draft.from == b.key
    b:SetKind(on and "primary" or "secondary")
  end
  win.team:SetText("Team")
  win.team:SetKind(custom and "secondary" or "primary")
  local cr, pr = win.content:GetRight(), win.teamAfter:GetRight()
  if cr and pr then win.team:SetWidth(max(80, floor(cr - pr - 4 - PADX))) end
  local L, bn, cb = win.layout, win.banner, win.openBox
  local info = view.info
  if custom then
    bn:SetTitle(draft.id and "Your preset" or "A new preset")
    bn:SetSub(nil)
    L:ShowNotice("info", "Click a buff to switch it off, on or improved; right-click goes back. Saved presets show in "
      .. "the card's buffs list for all your characters.")
    cb:Hide()
  else
    bn:SetTitle("Follows " .. draft.name)
    bn:SetSub(info and info.group and ("You're in group " .. info.group) or "You're in no group yet: no party buffs")
    L:ShowNotice("info", "Who is placed in the lineup today; changes to the team show up here by themselves. Click a "
      .. "buff to switch it off, on or improved.")
    local open = info and info.openCount or 0
    cb:SetShown(open > 0)
    if open > 0 then
      cb:SetChecked(draft.st.open ~= false)
      cb:SetLabel(("Count the comp's open slots (%d) as filled"):format(open))
    end
  end
  win.scrollTop(cb:IsShown() and 28 or 0)
  win.name:SetText(draft.name or "")
  if custom then win.name:Enable() else win.name:Disable() end
  win.name:SetAlpha(custom and 1 or 0.6)
  self:Layout()
  self:RefreshFooter()
end

-- ---------------------------------------------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------------------------------------------
-- Opens the editor on a buffs key ("p:<id>" / "t:<team>:<lineup>"), or a new preset (key nil, or one of WoWSims').
function SimBuffsUI:Open(key)
  draft = DraftFromKey(key) or NewDraft()
  if ns.SimPanel then ns.SimPanel:ClosePicker() end
  EnsureWindow()
  Position()
  win:Show()
  win:Raise()
  self:Refresh()
  return true
end

function SimBuffsUI:Close()
  if win and win:IsShown() then win:Hide() end
end

function SimBuffsUI:IsOpen() return win ~= nil and win:IsShown() end

function SimBuffsUI:Save()
  if not draft then return end
  local key
  if draft.kind == "custom" then
    local id, err = SB():SavePreset(draft.id, draft.name, draft.cfg)
    if not id then
      if UIErrorsFrame and err then UIErrorsFrame:AddMessage(err, 1, 0.3, 0.3) end
      return
    end
    draft.id = id
    key = "p:" .. id
  else
    SB():SaveTeamState(draft.teamId, draft.ln, draft.st)
    key = "t:" .. draft.teamId .. ":" .. draft.ln
  end
  draft.dirty = false
  if ns.SimPanel then ns.SimPanel:SetBuffs(key) end
  self:Refresh()
end

-- Delete (a preset) or Reset (a team lineup: back to who is placed, open slots counted).
function SimBuffsUI:Delete()
  if not draft then return end
  if draft.kind == "team" then
    draft.st = { open = true, ov = {} }
    draft.dirty = true
    return self:Refresh()
  end
  if not draft.id then return end
  local key = "p:" .. draft.id
  SB():DeletePreset(draft.id)
  if ns.SimPanel and ns.SimPanel:GetBuffs() == key then ns.SimPanel:SetBuffs("raid25") end
  self:Close()
end

-- Test hooks
function SimBuffsUI._draft() return draft end
function SimBuffsUI._view() return view end
function SimBuffsUI._tiles() return tiles end
function SimBuffsUI._win() return win end
