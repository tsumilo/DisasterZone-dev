-- wowmock/objects.lua : UI object model (frames, regions, scripts, events, templates, animations, fonts).
-- Deliberately PERMISSIVE for visuals, FAITHFUL for logic (scripts, events, visibility, values, text).
local M, cfg, PY = ...

local _G = _G
local type, tostring, tonumber, select, pairs, ipairs, next = type, tostring, tonumber, select, pairs, ipairs, next
local setmetatable, rawget, rawset, error = setmetatable, rawget, rawset, error
local unpack = unpack
local sformat, sgsub, sfind, ssub, smatch, supper, slower = string.format, string.gsub, string.find, string.sub, string.match, string.upper, string.lower
local tinsert, tremove, tconcat, tsort = table.insert, table.remove, table.concat, table.sort
local safecall = M.safecall

local OBJ = setmetatable({}, { __mode = "k" })  -- object -> state
M.OBJ = OBJ
M.unknown_fields = {}   -- key -> {label, key, where, count}
M.unknown_methods = {}
M.unknown_templates = {}
M.onupdate_frames = {}  -- ordered array of frames that ever had OnUpdate
M.onupdate_index = {}
M.playing_anims = {}
M.all_objects = {}

local NOOP = function() end
M.NOOP = NOOP

---------------------------------------------------------------------------------------------------
-- kinds / ancestry
---------------------------------------------------------------------------------------------------
local ANCESTRY = {
  Frame = { "Frame", "Region", "ScriptRegion", "Object" },
  Button = { "Button", "Frame", "Region", "ScriptRegion", "Object" },
  CheckButton = { "CheckButton", "Button", "Frame", "Region", "ScriptRegion", "Object" },
  EditBox = { "EditBox", "Frame", "Region", "ScriptRegion", "Object" },
  Slider = { "Slider", "Frame", "Region", "ScriptRegion", "Object" },
  StatusBar = { "StatusBar", "Frame", "Region", "ScriptRegion", "Object" },
  ScrollFrame = { "ScrollFrame", "Frame", "Region", "ScriptRegion", "Object" },
  GameTooltip = { "GameTooltip", "Frame", "Region", "ScriptRegion", "Object" },
  Cooldown = { "Cooldown", "Frame", "Region", "ScriptRegion", "Object" },
  MessageFrame = { "MessageFrame", "Frame", "Region", "ScriptRegion", "Object" },
  ScrollingMessageFrame = { "ScrollingMessageFrame", "Frame", "Region", "ScriptRegion", "Object" },
  Model = { "Model", "Frame", "Region", "ScriptRegion", "Object" },
  PlayerModel = { "PlayerModel", "Model", "Frame", "Region", "ScriptRegion", "Object" },
  DressUpModel = { "DressUpModel", "PlayerModel", "Model", "Frame", "Region", "ScriptRegion", "Object" },
  ModelScene = { "ModelScene", "Frame", "Region", "ScriptRegion", "Object" },
  ColorSelect = { "ColorSelect", "Frame", "Region", "ScriptRegion", "Object" },
  SimpleHTML = { "SimpleHTML", "Frame", "Region", "ScriptRegion", "Object" },
  Minimap = { "Minimap", "Frame", "Region", "ScriptRegion", "Object" },
  Texture = { "Texture", "TextureBase", "Region", "Object" },
  MaskTexture = { "MaskTexture", "TextureBase", "Region", "Object" },
  Line = { "Line", "TextureBase", "Region", "Object" },
  FontString = { "FontString", "Region", "Object" },
  AnimationGroup = { "AnimationGroup", "ScriptObject", "Object" },
  Animation = { "Animation", "ScriptObject", "Object" },
  Font = { "Font", "Object" },
}
local FRAME_TYPES = {}
for k in pairs(ANCESTRY) do
  if k ~= "Texture" and k ~= "MaskTexture" and k ~= "Line" and k ~= "FontString" and k ~= "AnimationGroup"
     and k ~= "Animation" and k ~= "Font" then
    FRAME_TYPES[slower(k)] = k
  end
end
FRAME_TYPES["cinematicmodel"] = "Model"
FRAME_TYPES["tabardmodel"] = "PlayerModel"
FRAME_TYPES["movieframe"] = "Frame"
FRAME_TYPES["scenarioframe"] = "Frame"
FRAME_TYPES["eventframe"] = "Frame"
FRAME_TYPES["dropdownbutton"] = "Button"
FRAME_TYPES["drivebutton"] = "Button"
FRAME_TYPES["itembutton"] = "Button"
FRAME_TYPES["containedalertframe"] = "Button"
M.FRAME_TYPES = FRAME_TYPES

local SCRIPTS = {}
local function scripts(kind, parent, list)
  local s = {}
  if parent then for k in pairs(SCRIPTS[parent]) do s[k] = true end end
  for w in list:gmatch("%S+") do s[w] = true end
  SCRIPTS[kind] = s
end
scripts("Frame", nil, [[OnEvent OnUpdate OnShow OnHide OnLoad OnEnter OnLeave OnMouseDown OnMouseUp OnMouseWheel
  OnDragStart OnDragStop OnReceiveDrag OnSizeChanged OnAttributeChanged OnKeyDown OnKeyUp OnChar OnEnable OnDisable
  OnHyperlinkClick OnHyperlinkEnter OnHyperlinkLeave OnGamePadButtonDown OnGamePadButtonUp OnGamePadStick]])
scripts("Button", "Frame", "OnClick OnDoubleClick PreClick PostClick")
scripts("CheckButton", "Button", "")
scripts("EditBox", "Frame", [[OnTextChanged OnEnterPressed OnEscapePressed OnEditFocusGained OnEditFocusLost
  OnTabPressed OnSpacePressed OnInputLanguageChanged OnTextSet OnCursorChanged OnCharComposition OnArrowPressed]])
scripts("Slider", "Frame", "OnValueChanged OnMinMaxChanged")
scripts("StatusBar", "Frame", "OnValueChanged OnMinMaxChanged")
scripts("ScrollFrame", "Frame", "OnScrollRangeChanged OnVerticalScroll OnHorizontalScroll")
scripts("GameTooltip", "Frame", [[OnTooltipSetItem OnTooltipSetUnit OnTooltipSetSpell OnTooltipCleared
  OnTooltipAddMoney OnTooltipSetDefaultAnchor OnTooltipSetQuest OnTooltipSetAchievement OnTooltipSetFramestack
  OnTooltipSetEquipmentSet]])
scripts("Cooldown", "Frame", "OnCooldownDone")
scripts("MessageFrame", "Frame", "")
scripts("ScrollingMessageFrame", "Frame", "OnMessageScrollChanged")
scripts("Model", "Frame", "OnModelLoaded OnAnimFinished OnAnimStarted OnModelCleared")
scripts("PlayerModel", "Model", "")
scripts("DressUpModel", "Model", "OnDressModel")
scripts("ModelScene", "Frame", "")
scripts("ColorSelect", "Frame", "OnColorSelect")
scripts("SimpleHTML", "Frame", "")
scripts("Minimap", "Frame", "")
scripts("AnimationGroup", nil, "OnPlay OnPause OnStop OnFinished OnLoop OnUpdate OnLoad")
scripts("Animation", nil, "OnPlay OnPause OnStop OnFinished OnUpdate OnLoad")
local ALL_SCRIPTS = {}
for _, s in pairs(SCRIPTS) do for k in pairs(s) do ALL_SCRIPTS[k] = true end end

---------------------------------------------------------------------------------------------------
-- method tables + metatable
---------------------------------------------------------------------------------------------------
local Methods = {}
M.Methods = Methods
local function define(kind, parent, t)
  local mt = {}
  if parent then for k, v in pairs(Methods[parent]) do mt[k] = v end end
  for k, v in pairs(t or {}) do mt[k] = v end
  Methods[kind] = mt
  return mt
end

-- Unknown-method heuristic: WoW widget methods start with one of these verbs; child keys do not.
local VERBS = {}
for w in ([[Set Get Is Has Can Enable Disable Register Unregister Clear Create Add Remove Start Stop Play Pause
  Update Unlock Raise Lower Adjust Refresh Init Reset Hook Fire Apply Flush Insert Release Acquire Enumerate Find
  Unhighlight Rotate Save Resize Anchor Layout Cancel Finish Restart Ignore Allow Setup Generate Override Undress
  Try Dress Freeze Unfreeze Invalidate Rebuild Recalculate Should Needs Evaluate Execute Run Trigger Notify Process
  Collapse Expand Snap Swap Attach Detach Mark Refresh Scale Show Hide Use Accept Decline Load Unload Suppress Force
  Configure Enumerate Increment Decrement Append Prepend Transform Validate Toggle]]):gmatch("%a+") do VERBS[w] = true end
local BACKDROP_METHODS = { SetBackdrop = true, SetBackdropColor = true, SetBackdropBorderColor = true,
  GetBackdrop = true, GetBackdropColor = true, GetBackdropBorderColor = true, ApplyBackdrop = true,
  SetupTextureCoordinates = true, ClearBackdrop = true, OnBackdropLoaded = true, OnBackdropSizeChanged = true,
  SetBorderBlendMode = true, HasBackdropInfo = true }
M.BACKDROP_METHODS = BACKDROP_METHODS

local function caller_where(level)
  local info = debug.getinfo(level or 3, "Sl")
  if info then
    local src = info.source or info.short_src or "?"
    if string.sub(src, 1, 1) == "@" then src = string.sub(src, 2) else src = info.short_src or "?" end
    return src .. ":" .. (info.currentline or 0)
  end
  return "?"
end
M.caller_where = caller_where

-- records the first location only (debug.getinfo is not called again for known keys)
local function note_unknown(tbl, st, key)
  local label = st.template or st.kind
  local k = label .. "\0" .. key
  local e = tbl[k]
  if e then e.count = e.count + 1
  else tbl[k] = { label = label, kind = st.kind, key = key, where = caller_where(4), count = 1 } end
end

local OBJ_MT = {}
M.OBJ_MT = OBJ_MT
OBJ_MT.__index = function(t, k)
  local st = OBJ[t]
  if not st then return nil end
  local m = st.methods[k]
  if m ~= nil then return m end
  if type(k) ~= "string" then return nil end
  if BACKDROP_METHODS[k] then
    note_unknown(M.unknown_methods, st, k .. " (needs BackdropTemplate)")
    return nil
  end
  local first = smatch(k, "^(%u%l+)")
  if first and VERBS[first] then
    note_unknown(M.unknown_methods, st, k)
    return NOOP
  end
  if not smatch(k, "^[%u%d_]+$") then  -- ignore ALL_CAPS dynamic lookups like self[event]
    note_unknown(M.unknown_fields, st, k)
  end
  if M.permissive_fields and st.kind ~= "Font" then
    local child = M.CreateObject("Frame", nil, t)
    OBJ[child].template = "auto:" .. k
    rawset(t, k, child)
    return child
  end
  return nil
end
OBJ_MT.__tostring = function(t)
  local st = OBJ[t]
  return st and ("<" .. st.kind .. " " .. tostring(st.name or "") .. ">") or "<object>"
end

local function S(self, method)
  local st = type(self) == "table" and OBJ[self]
  if not st then
    error("Attempt to find 'this' in non-framescript object (used '.' instead of ':' ?)" ..
          (method and (" in " .. method) or ""), 3)
  end
  return st
end
M.S = S

local function resolve(x)
  if type(x) == "string" then return _G[x] end
  return x
end
M.resolve = resolve

---------------------------------------------------------------------------------------------------
-- script dispatch
---------------------------------------------------------------------------------------------------
local function obj_label(obj)
  local st = OBJ[obj]
  if not st then return "?" end
  return st.name or (st.template and ("<" .. st.kind .. ":" .. st.template .. ">")) or ("<" .. st.kind .. ">")
end
M.obj_label = obj_label

local function call_script(obj, name, ...)
  local st = OBJ[obj]
  if not st then return end
  local fn = st.scripts[name]
  if fn then
    safecall(name .. " " .. obj_label(obj), fn, obj, ...)
  end
  local hooks = st.hooks[name]
  if hooks then
    for i = 1, #hooks do safecall(name .. "(hook) " .. obj_label(obj), hooks[i], obj, ...) end
  end
end
M.call_script = call_script

local function event_call(obj, event, ...)
  local st = OBJ[obj]
  local fn = st.scripts.OnEvent
  if fn then safecall("OnEvent(" .. event .. ") " .. obj_label(obj), fn, obj, event, ...) end
  local hooks = st.hooks.OnEvent
  if hooks then
    for i = 1, #hooks do safecall("OnEvent(" .. event .. ",hook) " .. obj_label(obj), hooks[i], obj, event, ...) end
  end
end

function M.fire(event, ...)
  local list = M.event_frames[event]
  local snap = {}
  if list then for i = 1, #list do snap[i] = list[i] end end
  if #M.all_event_frames > 0 then
    local seen = {}
    for i = 1, #snap do seen[snap[i]] = true end
    for _, f in ipairs(M.all_event_frames) do if not seen[f] then snap[#snap + 1] = f end end
  end
  local unit = (...)
  for i = 1, #snap do
    local f = snap[i]
    local st = OBJ[f]
    if st and (st.events[event] or st.all_events) then
      local filter = st.unit_filter and st.unit_filter[event]
      if not filter or (unit ~= nil and filter[unit]) then
        event_call(f, event, ...)
      end
    end
  end
end

---------------------------------------------------------------------------------------------------
-- visibility
---------------------------------------------------------------------------------------------------
local function is_visible(obj)
  local st = OBJ[obj]
  while st do
    if not st.shown then return false end
    local p = st.parent
    if p == nil then return true end
    st = OBJ[p]
  end
  return true
end
M.is_visible = is_visible

local function show_tree(obj)
  local st = OBJ[obj]
  if st.is_frame then
    call_script(obj, "OnShow")
    if st.autofocus and st.kind == "EditBox" and not st.focus then Methods.EditBox.SetFocus(obj) end
  end
  local ch = st.children
  if ch then
    for i = 1, #ch do
      local c = ch[i]
      local cs = OBJ[c]
      if cs and cs.shown and cs.parent == obj then show_tree(c) end
    end
  end
end
local function hide_tree(obj)
  local st = OBJ[obj]
  if st.is_frame then
    call_script(obj, "OnHide")
    if st.focus then Methods.EditBox.ClearFocus(obj) end
  end
  local ch = st.children
  if ch then
    for i = 1, #ch do
      local c = ch[i]
      local cs = OBJ[c]
      if cs and cs.shown and cs.parent == obj then hide_tree(c) end
    end
  end
end

---------------------------------------------------------------------------------------------------
-- object creation
---------------------------------------------------------------------------------------------------
local function subst_name(name, parent)
  if type(name) ~= "string" then return nil end
  if sfind(name, "$parent", 1, true) or sfind(name, "$Parent", 1, true) then
    local pname = parent and OBJ[parent] and OBJ[parent].name or ""
    name = sgsub(sgsub(name, "%$parent", pname), "%$Parent", pname)
  end
  return name
end

local obj_counter = 0
function M.CreateObject(kind, name, parent, template)
  obj_counter = obj_counter + 1
  local obj = setmetatable({ [0] = newproxy(false) }, OBJ_MT)
  local is_frame = ANCESTRY[kind][2] ~= nil and (ANCESTRY[kind][#ANCESTRY[kind] - 1] == "ScriptRegion")
  local st = {
    kind = kind, methods = Methods[kind], name = subst_name(name, parent), parent = nil, children = {},
    shown = true, points = {}, scripts = {}, hooks = {}, events = {}, attrs = {},
    alpha = 1, scale = 1, is_frame = is_frame, id = 0, enabled = true, seq = obj_counter,
  }
  OBJ[obj] = st
  M.all_objects[#M.all_objects + 1] = obj
  if parent ~= nil then
    parent = resolve(parent)
    if parent ~= nil and not OBJ[parent] then
      error("CreateFrame: parent is not a frame (" .. type(parent) .. ")", 3)
    end
    if parent then
      st.parent = parent
      local ps = OBJ[parent]
      ps.children[#ps.children + 1] = obj
      st.level = (ps.level or 0) + 1
      st.strata = ps.strata
    end
  end
  if st.name then _G[st.name] = obj end
  return obj, st
end

---------------------------------------------------------------------------------------------------
-- Region methods (shared by frames and textures/fontstrings)
---------------------------------------------------------------------------------------------------
local POINTS = { TOPLEFT = true, TOP = true, TOPRIGHT = true, LEFT = true, CENTER = true, RIGHT = true,
  BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true }

local function set_parent(self, st, parent)
  parent = resolve(parent)
  if parent == st.parent then return end
  if parent ~= nil and not OBJ[parent] then error("SetParent: invalid parent", 3) end
  local was = is_visible(self)
  if st.parent then
    local ps = OBJ[st.parent]
    for i = #ps.children, 1, -1 do if ps.children[i] == self then tremove(ps.children, i) end end
  end
  st.parent = parent
  if parent then
    local ps = OBJ[parent]
    ps.children[#ps.children + 1] = self
  end
  local now = is_visible(self)
  if was and not now then hide_tree(self) elseif now and not was then show_tree(self) end
end

local function size_changed(self, st)
  if st.is_frame then call_script(self, "OnSizeChanged", st.w or 0, st.h or 0) end
end

local function eff_width(st)
  if st.w then return st.w end
  if st.all_points and st.parent then return eff_width(OBJ[st.parent]) end
  if st.kind == "FontString" then return #(st.text or "") * 6 end
  return 0
end
local function eff_height(st)
  if st.h then return st.h end
  if st.all_points and st.parent then return eff_height(OBJ[st.parent]) end
  if st.kind == "FontString" then return 12 end
  return 0
end

local Region = define("Region", nil, {
  GetName = function(self) return S(self).name end,
  GetDebugName = function(self) return obj_label(self) end,
  GetObjectType = function(self) return S(self).kind end,
  IsObjectType = function(self, t)
    for _, a in ipairs(ANCESTRY[S(self).kind]) do if a == t then return true end end
    return false
  end,
  IsForbidden = function() return false end,
  IsProtected = function() return false, false end,
  GetParent = function(self) return S(self).parent end,
  SetParent = function(self, p) set_parent(self, S(self), p) end,
  Show = function(self)
    local st = S(self, "Show")
    if st.shown then return end
    local was = is_visible(self)
    st.shown = true
    if not was and is_visible(self) then show_tree(self) end
  end,
  Hide = function(self)
    local st = S(self, "Hide")
    if not st.shown then return end
    local was = is_visible(self)
    st.shown = false
    if was then hide_tree(self) end
  end,
  SetShown = function(self, v) if v then self:Show() else self:Hide() end end,
  IsShown = function(self) return S(self).shown end,
  IsVisible = function(self) S(self); return is_visible(self) end,
  SetPoint = function(self, point, rel, relPoint, x, y)
    local st = S(self, "SetPoint")
    if type(point) ~= "string" or not POINTS[supper(point)] then
      error("SetPoint: Invalid region point '" .. tostring(point) .. "'", 2)
    end
    point = supper(point)
    if type(rel) == "number" then
      rel, relPoint, x, y = nil, point, rel, relPoint
    elseif type(rel) == "string" then
      local r = _G[rel]
      if r == nil then error("SetPoint: Couldn't find relative frame named '" .. rel .. "'", 2) end
      rel = r
    end
    if rel == self then error("SetPoint: Cannot anchor to itself", 2) end
    if type(relPoint) == "number" then relPoint, x, y = point, relPoint, x end
    if rel ~= nil and not OBJ[rel] then error("SetPoint: relativeTo is not a region", 2) end
    for i = #st.points, 1, -1 do if st.points[i][1] == point then tremove(st.points, i) end end
    st.points[#st.points + 1] = { point, rel or st.parent, supper(relPoint or point), x or 0, y or 0 }
  end,
  SetAllPoints = function(self, rel)
    local st = S(self)
    st.points = { { "TOPLEFT", resolve(rel) or st.parent, "TOPLEFT", 0, 0 },
                  { "BOTTOMRIGHT", resolve(rel) or st.parent, "BOTTOMRIGHT", 0, 0 } }
    st.all_points = true
  end,
  ClearAllPoints = function(self) local st = S(self); st.points = {}; st.all_points = nil end,
  ClearPoint = function(self, p) local st = S(self)
    for i = #st.points, 1, -1 do if st.points[i][1] == p then tremove(st.points, i) end end end,
  GetNumPoints = function(self) return #S(self).points end,
  GetPoint = function(self, i)
    local p = S(self).points[i or 1]
    if p then return p[1], p[2], p[3], p[4], p[5] end
  end,
  GetPointByName = function(self, name)
    for _, p in ipairs(S(self).points) do if p[1] == name then return p[1], p[2], p[3], p[4], p[5] end end
  end,
  AdjustPointsOffset = function() end,
  SetSize = function(self, w, h)
    local st = S(self)
    if type(w) ~= "number" then error("SetSize: width must be a number", 2) end
    h = h or w
    local changed = st.w ~= w or st.h ~= h
    st.w, st.h = w, h
    if changed then size_changed(self, st) end
  end,
  SetWidth = function(self, w)
    local st = S(self)
    if type(w) ~= "number" then error("SetWidth: number expected, got " .. type(w), 2) end
    if st.w ~= w then st.w = w; size_changed(self, st) end
  end,
  SetHeight = function(self, h)
    local st = S(self)
    if type(h) ~= "number" then error("SetHeight: number expected, got " .. type(h), 2) end
    if st.h ~= h then st.h = h; size_changed(self, st) end
  end,
  GetWidth = function(self) return eff_width(S(self)) end,
  GetHeight = function(self) return eff_height(S(self)) end,
  GetSize = function(self) local st = S(self); return eff_width(st), eff_height(st) end,
  GetRect = function(self) local st = S(self); return 0, 0, eff_width(st), eff_height(st) end,
  GetScaledRect = function(self) local st = S(self); return 0, 0, eff_width(st), eff_height(st) end,
  GetBoundsRect = function(self) local st = S(self); return 0, 0, eff_width(st), eff_height(st) end,
  GetLeft = function(self) S(self); return 0 end,
  GetBottom = function(self) S(self); return 0 end,
  GetRight = function(self) return eff_width(S(self)) end,
  GetTop = function(self) return eff_height(S(self)) end,
  GetCenter = function(self) local st = S(self); return eff_width(st) / 2, eff_height(st) / 2 end,
  IsRectValid = function() return true end,
  IsAnchoringRestricted = function() return false end,
  SetAlpha = function(self, a) S(self).alpha = tonumber(a) or 1 end,
  GetAlpha = function(self) return S(self).alpha end,
  GetEffectiveAlpha = function(self) return S(self).alpha end,
  SetScale = function(self, s) S(self).scale = tonumber(s) or 1 end,
  GetScale = function(self) return S(self).scale end,
  GetEffectiveScale = function(self)
    local st, s = S(self), 1
    while st do s = s * (st.scale or 1); st = st.parent and OBJ[st.parent] end
    return s
  end,
  SetIgnoreParentScale = function() end,
  SetIgnoreParentAlpha = function() end,
  IsMouseOver = function() return false end,
  IsMouseMotionFocus = function() return false end,
  SetDrawLayer = function(self, layer, sub) local st = S(self); st.layer, st.sublayer = layer, sub end,
  GetDrawLayer = function(self) local st = S(self); return st.layer or "ARTWORK", st.sublayer or 0 end,
  SetVertexColor = function(self, r, g, b, a) S(self).vcolor = { r or 1, g or 1, b or 1, a or 1 } end,
  GetVertexColor = function(self) local c = S(self).vcolor or { 1, 1, 1, 1 }; return c[1], c[2], c[3], c[4] end,
  CreateAnimationGroup = function(self, name, template) return M.CreateAnimationGroup(self, name, template) end,
  GetAnimationGroups = function(self) local st = S(self); return unpack(st.anims or {}) end,
  StopAnimating = function(self)
    for _, g in ipairs(S(self).anims or {}) do g:Stop() end
  end,
  IsDragging = function() return false end,
  SetSnapToPixelGrid = function() end,
  SetTexelSnappingBias = function() end,
  SetClipsChildren = function(self, v) S(self).clips = v end,
  DoesClipChildren = function(self) return S(self).clips or false end,
})

---------------------------------------------------------------------------------------------------
-- Frame
---------------------------------------------------------------------------------------------------
local function set_script(self, name, fn, method)
  local st = S(self, method)
  if type(name) ~= "string" then error(method .. ": script name must be a string", 3) end
  local valid = SCRIPTS[st.kind] or SCRIPTS.Frame
  if not valid[name] then
    if ALL_SCRIPTS[name] then
      error(st.kind .. " " .. obj_label(self) .. " doesn't have a \"" .. name .. "\" script", 3)
    end
    M.warn(method .. ": unknown script type '" .. name .. "' on " .. st.kind .. " (accepted by the mock)")
  end
  if fn ~= nil and type(fn) ~= "function" then error(method .. ": handler must be a function or nil", 3) end
  return st
end

local function track_onupdate(self, st)
  if not M.onupdate_index[self] then
    M.onupdate_index[self] = true
    M.onupdate_frames[#M.onupdate_frames + 1] = self
  end
end

local Frame = define("Frame", "Region", {
  SetScript = function(self, name, fn)
    local st = set_script(self, name, fn, "SetScript")
    st.scripts[name] = fn
    if name == "OnUpdate" and fn then track_onupdate(self, st) end
  end,
  GetScript = function(self, name) return S(self).scripts[name] end,
  HookScript = function(self, name, fn)
    local st = set_script(self, name, fn, "HookScript")
    if type(fn) ~= "function" then error("HookScript: function expected", 2) end
    local h = st.hooks[name]
    if not h then h = {}; st.hooks[name] = h end
    h[#h + 1] = fn
    if name == "OnUpdate" then track_onupdate(self, st) end
  end,
  HasScript = function(self, name) local st = S(self); return (SCRIPTS[st.kind] or SCRIPTS.Frame)[name] == true end,
  RegisterEvent = function(self, ev)
    local st = S(self, "RegisterEvent")
    if type(ev) ~= "string" then error("Usage: " .. obj_label(self) .. ":RegisterEvent(\"event\")", 2) end
    if not M.known_events[ev] and not M.unknown_events[ev] then
      M.unknown_events[ev] = caller_where(3)
    end
    if st.events[ev] then return true end
    st.events[ev] = true
    local l = M.event_frames[ev]
    if not l then l = {}; M.event_frames[ev] = l end
    l[#l + 1] = self
    return true
  end,
  RegisterUnitEvent = function(self, ev, u1, u2)
    local st = S(self)
    Methods.Frame.RegisterEvent(self, ev)
    st.unit_filter = st.unit_filter or {}
    local f = {}
    if u1 then f[u1] = true end
    if u2 then f[u2] = true end
    st.unit_filter[ev] = (u1 or u2) and f or nil
    return true
  end,
  UnregisterEvent = function(self, ev)
    local st = S(self)
    if not st.events[ev] then return end
    st.events[ev] = nil
    if st.unit_filter then st.unit_filter[ev] = nil end
    local l = M.event_frames[ev]
    if l then for i = #l, 1, -1 do if l[i] == self then tremove(l, i) end end end
  end,
  UnregisterAllEvents = function(self)
    local st = S(self)
    for ev in pairs(st.events) do Methods.Frame.UnregisterEvent(self, ev) end
    if st.all_events then
      st.all_events = nil
      for i = #M.all_event_frames, 1, -1 do if M.all_event_frames[i] == self then tremove(M.all_event_frames, i) end end
    end
  end,
  RegisterAllEvents = function(self)
    local st = S(self)
    if not st.all_events then st.all_events = true; M.all_event_frames[#M.all_event_frames + 1] = self end
  end,
  IsEventRegistered = function(self, ev)
    local st = S(self)
    if st.events[ev] or st.all_events then return true end
    return false
  end,
  CreateTexture = function(self, name, layer, template, sub)
    S(self)
    local t, ts = M.CreateObject("Texture", name, self)
    ts.layer, ts.sublayer, ts.template = layer, sub, template
    return t
  end,
  CreateMaskTexture = function(self, name, layer, template, sub)
    S(self)
    local t, ts = M.CreateObject("MaskTexture", name, self)
    ts.layer = layer
    return t
  end,
  CreateLine = function(self, name, layer, template, sub)
    S(self)
    local t, ts = M.CreateObject("Line", name, self)
    ts.layer = layer
    return t
  end,
  CreateFontString = function(self, name, layer, inherits)
    S(self)
    local fs, fst = M.CreateObject("FontString", name, self)
    fst.layer = layer
    if inherits then
      local fo = resolve(inherits)
      if fo and OBJ[fo] then fst.fontobj = fo end
      fst.template = type(inherits) == "string" and inherits or nil
    end
    return fs
  end,
  GetChildren = function(self)
    local out = {}
    for _, c in ipairs(S(self).children) do if OBJ[c].is_frame then out[#out + 1] = c end end
    return unpack(out)
  end,
  GetNumChildren = function(self)
    local n = 0
    for _, c in ipairs(S(self).children) do if OBJ[c].is_frame then n = n + 1 end end
    return n
  end,
  GetRegions = function(self)
    local out = {}
    for _, c in ipairs(S(self).children) do if not OBJ[c].is_frame and OBJ[c].kind ~= "AnimationGroup" then out[#out + 1] = c end end
    return unpack(out)
  end,
  GetNumRegions = function(self) return select("#", Methods.Frame.GetRegions(self)) end,
  SetAttribute = function(self, k, v)
    local st = S(self)
    st.attrs[k] = v
    call_script(self, "OnAttributeChanged", k, v)
  end,
  SetAttributeNoHandler = function(self, k, v) S(self).attrs[k] = v end,
  GetAttribute = function(self, k) return S(self).attrs[k] end,
  SetFrameLevel = function(self, l) S(self).level = tonumber(l) or 0 end,
  GetFrameLevel = function(self) return S(self).level or 0 end,
  SetFrameStrata = function(self, s) S(self).strata = s end,
  GetFrameStrata = function(self) return S(self).strata or "MEDIUM" end,
  SetFixedFrameStrata = function() end,
  SetFixedFrameLevel = function() end,
  SetToplevel = function(self, v) S(self).toplevel = v end,
  IsToplevel = function(self) return S(self).toplevel or false end,
  Raise = function() end,
  Lower = function() end,
  EnableMouse = function(self, v) S(self).mouse = v and true or false end,
  IsMouseEnabled = function(self) return S(self).mouse or false end,
  SetMouseClickEnabled = function(self, v) S(self).mouse = v and true or false end,
  IsMouseClickEnabled = function(self) return S(self).mouse or false end,
  SetMouseMotionEnabled = function(self, v) S(self).motion = v end,
  IsMouseMotionEnabled = function(self) return S(self).motion or false end,
  EnableMouseWheel = function(self, v) S(self).wheel = v and true or false end,
  IsMouseWheelEnabled = function(self) return S(self).wheel or false end,
  EnableKeyboard = function(self, v) S(self).keyboard = v and true or false end,
  IsKeyboardEnabled = function(self) return S(self).keyboard or false end,
  SetPropagateKeyboardInput = function() end,
  SetMovable = function(self, v) S(self).movable = v end,
  IsMovable = function(self) return S(self).movable or false end,
  SetResizable = function(self, v) S(self).resizable = v end,
  IsResizable = function(self) return S(self).resizable or false end,
  SetResizeBounds = function() end,
  SetMinResize = function() end,
  SetMaxResize = function() end,
  StartMoving = function() end,
  StartSizing = function() end,
  StopMovingOrSizing = function() end,
  RegisterForDrag = function(self, ...) S(self).drag = { ... } end,
  SetClampedToScreen = function(self, v) S(self).clamped = v end,
  IsClampedToScreen = function(self) return S(self).clamped or false end,
  SetClampRectInsets = function() end,
  SetUserPlaced = function(self, v) S(self).userplaced = v end,
  IsUserPlaced = function(self) return S(self).userplaced or false end,
  SetDontSavePosition = function() end,
  SetID = function(self, id) S(self).id = tonumber(id) or 0 end,
  GetID = function(self) return S(self).id or 0 end,
  SetHitRectInsets = function() end,
  GetHitRectInsets = function() return 0, 0, 0, 0 end,
  CanChangeProtectedState = function() return true end,
  SetFlattensRenderLayers = function() end,
  SetFrameBuffer = function() end,
  SetHyperlinksEnabled = function(self, v) S(self).hyperlinks = v end,
  GetHyperlinksEnabled = function(self) return S(self).hyperlinks or false end,
  EnableGamePadButton = function() end,
  EnableGamePadStick = function() end,
  SetWindow = function() end,
  LockHighlight = function(self) S(self).highlight_locked = true end,
  UnlockHighlight = function(self) S(self).highlight_locked = false end,
  -- enable state lives on Frame so Button/Slider/EditBox share it
  Enable = function(self) local st = S(self); if not st.enabled then st.enabled = true; call_script(self, "OnEnable") end end,
  Disable = function(self) local st = S(self); if st.enabled then st.enabled = false; call_script(self, "OnDisable") end end,
  SetEnabled = function(self, v) if v then self:Enable() else self:Disable() end end,
  IsEnabled = function(self) return S(self).enabled and true or false end,
})
-- a plain Frame has no Enable/Disable/IsEnabled in WoW; only the widget types below get them
Frame.Enable, Frame.Disable, Frame.SetEnabled, Frame.IsEnabled = nil, nil, nil, nil
local EnableMethods = {
  Enable = function(self) local st = S(self); if not st.enabled then st.enabled = true; call_script(self, "OnEnable") end end,
  Disable = function(self) local st = S(self); if st.enabled then st.enabled = false; call_script(self, "OnDisable") end end,
  SetEnabled = function(self, v) if v then self:Enable() else self:Disable() end end,
  IsEnabled = function(self) return S(self).enabled and true or false end,
}

---------------------------------------------------------------------------------------------------
-- text helper (FontString / Button / EditBox share semantics)
---------------------------------------------------------------------------------------------------
local function to_text(v, method)
  if v == nil then return nil end
  local tv = type(v)
  if tv == "string" then return v end
  if tv == "number" then return tostring(v) end
  error(method .. ": bad argument #1 (string expected, got " .. tv .. ")", 3)
end
M.to_text = to_text

local FontStringMethods = {
  SetText = function(self, v) S(self).text = to_text(v, "SetText") end,
  GetText = function(self) return S(self).text end,
  SetFormattedText = function(self, fmt, ...) S(self).text = sformat(fmt, ...) end,
  GetStringWidth = function(self) return #(S(self).text or "") * 6 end,
  GetUnboundedStringWidth = function(self) return #(S(self).text or "") * 6 end,
  GetStringHeight = function(self)
    local t = S(self).text or ""
    local _, n = sgsub(t, "\n", "")
    return 12 * (n + 1)
  end,
  GetLineHeight = function() return 12 end,
  GetNumLines = function(self) local _, n = sgsub(S(self).text or "", "\n", ""); return n + 1 end,
  IsTruncated = function() return false end,
  SetFont = function(self, path, size, flags) local st = S(self); st.font = { path, size, flags }; return true end,
  GetFont = function(self)
    local st = S(self)
    if st.font then return st.font[1], st.font[2], st.font[3] end
    if st.fontobj then return st.fontobj:GetFont() end
    return "Fonts\\FRIZQT__.TTF", 12, ""
  end,
  SetFontObject = function(self, fo)
    local st = S(self)
    local r = resolve(fo)
    if fo ~= nil and r == nil then M.warn("SetFontObject: unknown font object '" .. tostring(fo) .. "'") end
    st.fontobj = r
  end,
  GetFontObject = function(self) return S(self).fontobj end,
  SetTextColor = function(self, r, g, b, a) S(self).tcolor = { r or 1, g or 1, b or 1, a or 1 } end,
  GetTextColor = function(self) local c = S(self).tcolor or { 1, 0.82, 0, 1 }; return c[1], c[2], c[3], c[4] end,
  SetShadowColor = function() end,
  GetShadowColor = function() return 0, 0, 0, 1 end,
  SetShadowOffset = function() end,
  GetShadowOffset = function() return 1, -1 end,
  SetJustifyH = function(self, j) S(self).justifyH = j end,
  GetJustifyH = function(self) return S(self).justifyH or "CENTER" end,
  SetJustifyV = function(self, j) S(self).justifyV = j end,
  GetJustifyV = function(self) return S(self).justifyV or "MIDDLE" end,
  SetWordWrap = function(self, v) S(self).wrap = v end,
  CanWordWrap = function(self) return S(self).wrap ~= false end,
  SetNonSpaceWrap = function() end,
  SetMaxLines = function(self, n) S(self).maxlines = n end,
  GetMaxLines = function(self) return S(self).maxlines or 0 end,
  SetSpacing = function() end,
  GetSpacing = function() return 0 end,
  SetTextHeight = function() end,
  SetTextScale = function() end,
  GetTextScale = function() return 1 end,
  SetIndentedWordWrap = function() end,
  SetFixedColor = function() end,
}

define("TextureBase", "Region", {
  SetTexture = function(self, tex) local st = S(self); st.texture = tex; st.atlas = nil; return true end,
  GetTexture = function(self) return S(self).texture end,
  GetTextureFileID = function(self) local t = S(self).texture; return type(t) == "number" and t or nil end,
  GetTextureFilePath = function(self) return S(self).texture end,
  SetAtlas = function(self, atlas, useSize) local st = S(self); st.atlas = atlas; return true end,
  GetAtlas = function(self) return S(self).atlas end,
  SetColorTexture = function(self, r, g, b, a) local st = S(self); st.color = { r, g, b, a or 1 }; st.texture = "Color" end,
  SetTexCoord = function(self, ...) S(self).texcoord = { ... } end,
  GetTexCoord = function(self)
    local c = S(self).texcoord
    if c and #c == 4 then return c[1], c[3], c[1], c[4], c[2], c[3], c[2], c[4] end
    if c and #c == 8 then return unpack(c) end
    return 0, 0, 0, 1, 1, 0, 1, 1
  end,
  SetDesaturated = function(self, v) S(self).desat = v and true or false end,
  IsDesaturated = function(self) return S(self).desat or false end,
  SetDesaturation = function(self, v) S(self).desat = (v or 0) > 0 end,
  SetBlendMode = function(self, m) S(self).blend = m end,
  GetBlendMode = function(self) return S(self).blend or "BLEND" end,
  SetRotation = function(self, r) S(self).rotation = r end,
  GetRotation = function(self) return S(self).rotation or 0 end,
  SetGradient = function() end,
  SetGradientAlpha = function() end,
  SetHorizTile = function() end,
  SetVertTile = function() end,
  AddMaskTexture = function(self, m) local st = S(self); st.masks = st.masks or {}; st.masks[#st.masks + 1] = m end,
  RemoveMaskTexture = function(self, m)
    local st = S(self)
    if st.masks then for i = #st.masks, 1, -1 do if st.masks[i] == m then tremove(st.masks, i) end end end
  end,
  GetNumMaskTextures = function(self) return #(S(self).masks or {}) end,
  GetMaskTexture = function(self, i) return (S(self).masks or {})[i] end,
  SetMask = function() end,
  SetNonBlocking = function() end,
})
define("Texture", "TextureBase", {})
define("MaskTexture", "TextureBase", {})
define("Line", "TextureBase", {
  SetStartPoint = function() end, SetEndPoint = function() end,
  SetThickness = function(self, t) S(self).thickness = t end, GetThickness = function(self) return S(self).thickness or 1 end,
})
define("FontString", "Region", FontStringMethods)

---------------------------------------------------------------------------------------------------
-- Button / CheckButton
---------------------------------------------------------------------------------------------------
local function button_fs(self, st)
  if not st.fontstring then
    local fs = rawget(self, "Text")
    if not (fs and OBJ[fs] and OBJ[fs].kind == "FontString") then
      fs = Methods.Frame.CreateFontString(self, st.name and (st.name .. "Text") or nil, "ARTWORK")
    end
    st.fontstring = fs
  end
  return st.fontstring
end
local function tex_slot(key)
  return function(self, tex, blend)
    local st = S(self)
    if tex == nil then st[key] = nil; return end
    if type(tex) == "table" and OBJ[tex] then st[key] = tex; return end
    local t = st[key]
    if not t then t = Methods.Frame.CreateTexture(self); st[key] = t end
    t:SetTexture(tex)
  end
end
local function tex_get(key)
  return function(self)
    local st = S(self)
    return st[key]
  end
end
local ButtonExtra = {
  SetText = function(self, v)
    local st = S(self)
    local fs = button_fs(self, st)
    Methods.FontString.SetText(fs, to_text(v, "SetText"))
  end,
  SetFormattedText = function(self, fmt, ...) Methods.Button.SetText(self, sformat(fmt, ...)) end,
  GetText = function(self)
    local st = S(self)
    local fs = st.fontstring or rawget(self, "Text")
    if fs and OBJ[fs] then return OBJ[fs].text end
    return nil
  end,
  GetFontString = function(self) return button_fs(self, S(self)) end,
  SetFontString = function(self, fs) S(self).fontstring = fs end,
  GetTextWidth = function(self) local t = self:GetText() or ""; return #t * 6 end,
  GetTextHeight = function() return 12 end,
  SetNormalFontObject = function(self, fo) S(self).normalfont = resolve(fo) end,
  GetNormalFontObject = function(self) return S(self).normalfont end,
  SetHighlightFontObject = function(self, fo) S(self).hlfont = resolve(fo) end,
  GetHighlightFontObject = function(self) return S(self).hlfont end,
  SetDisabledFontObject = function(self, fo) S(self).disfont = resolve(fo) end,
  GetDisabledFontObject = function(self) return S(self).disfont end,
  SetNormalTexture = tex_slot("normaltex"), GetNormalTexture = tex_get("normaltex"),
  SetPushedTexture = tex_slot("pushedtex"), GetPushedTexture = tex_get("pushedtex"),
  SetHighlightTexture = tex_slot("hltex"), GetHighlightTexture = tex_get("hltex"),
  SetDisabledTexture = tex_slot("distex"), GetDisabledTexture = tex_get("distex"),
  SetNormalAtlas = function(self, a) tex_slot("normaltex")(self, a) end,
  SetPushedAtlas = function(self, a) tex_slot("pushedtex")(self, a) end,
  SetHighlightAtlas = function(self, a) tex_slot("hltex")(self, a) end,
  SetDisabledAtlas = function(self, a) tex_slot("distex")(self, a) end,
  SetPushedTextOffset = function() end,
  GetPushedTextOffset = function() return 0, 0 end,
  RegisterForClicks = function(self, ...) S(self).clicks = { ... } end,
  RegisterForMouse = function() end,
  SetButtonState = function(self, s) S(self).bstate = s end,
  GetButtonState = function(self) local st = S(self); if not st.enabled then return "DISABLED" end return st.bstate or "NORMAL" end,
  SetMotionScriptsWhileDisabled = function() end,
  Click = function(self, button, down)
    local st = S(self, "Click")
    if not st.enabled then return end
    button = button or "LeftButton"
    if st.kind == "CheckButton" then st.checked = not st.checked end
    call_script(self, "PreClick", button, down or false)
    call_script(self, "OnClick", button, down or false)
    call_script(self, "PostClick", button, down or false)
  end,
}
for k, v in pairs(EnableMethods) do ButtonExtra[k] = v end
define("Button", "Frame", ButtonExtra)
define("CheckButton", "Button", {
  SetChecked = function(self, v) S(self).checked = v and true or false end,
  GetChecked = function(self) return S(self).checked or false end,
  SetCheckedTexture = tex_slot("checkedtex"), GetCheckedTexture = tex_get("checkedtex"),
  SetDisabledCheckedTexture = tex_slot("dischecktex"), GetDisabledCheckedTexture = tex_get("dischecktex"),
})

---------------------------------------------------------------------------------------------------
-- EditBox
---------------------------------------------------------------------------------------------------
local EditBoxExtra = {
  SetText = function(self, v)
    local st = S(self)
    local t = to_text(v, "SetText") or ""
    if st.maxletters and st.maxletters > 0 and #t > st.maxletters then t = ssub(t, 1, st.maxletters) end
    local changed = st.text ~= t
    st.text = t
    st.cursor = #t
    call_script(self, "OnTextSet")
    if changed then call_script(self, "OnTextChanged", false) end
  end,
  GetText = function(self) return S(self).text or "" end,
  GetDisplayText = function(self) return S(self).text or "" end,
  SetFormattedText = function(self, fmt, ...) Methods.EditBox.SetText(self, sformat(fmt, ...)) end,
  Insert = function(self, v)
    local st = S(self)
    local t = (st.text or "") .. (to_text(v, "Insert") or "")
    if st.maxletters and st.maxletters > 0 and #t > st.maxletters then t = ssub(t, 1, st.maxletters) end
    st.text = t
    call_script(self, "OnTextChanged", false)
  end,
  GetNumLetters = function(self) return #(S(self).text or "") end,
  SetMaxLetters = function(self, n) S(self).maxletters = tonumber(n) end,
  GetMaxLetters = function(self) return S(self).maxletters or 0 end,
  SetMaxBytes = function(self, n) S(self).maxletters = tonumber(n) end,
  GetMaxBytes = function(self) return S(self).maxletters or 0 end,
  SetNumeric = function(self, v) S(self).numeric = v and true or false end,
  IsNumeric = function(self) return S(self).numeric or false end,
  SetNumber = function(self, n) Methods.EditBox.SetText(self, tostring(n)) end,
  GetNumber = function(self) return tonumber(S(self).text or "") or 0 end,
  SetMultiLine = function(self, v) S(self).multiline = v and true or false end,
  IsMultiLine = function(self) return S(self).multiline or false end,
  SetAutoFocus = function(self, v) S(self).autofocus = v and true or false end,
  IsAutoFocus = function(self) return S(self).autofocus or false end,
  SetFocus = function(self)
    local st = S(self)
    if st.focus then return end
    if M.focused and M.focused ~= self and OBJ[M.focused] then Methods.EditBox.ClearFocus(M.focused) end
    st.focus = true
    M.focused = self
    call_script(self, "OnEditFocusGained")
  end,
  ClearFocus = function(self)
    local st = S(self)
    if not st.focus then return end
    st.focus = false
    if M.focused == self then M.focused = nil end
    call_script(self, "OnEditFocusLost")
  end,
  HasFocus = function(self) return S(self).focus or false end,
  HighlightText = function() end,
  SetCursorPosition = function(self, p) S(self).cursor = p end,
  GetCursorPosition = function(self) return S(self).cursor or 0 end,
  SetTextInsets = function() end,
  GetTextInsets = function() return 0, 0, 0, 0 end,
  SetPassword = function(self, v) S(self).password = v end,
  IsPassword = function(self) return S(self).password or false end,
  AddHistoryLine = function() end,
  ClearHistory = function() end,
  SetHistoryLines = function() end,
  SetCountInvisibleLetters = function() end,
  SetBlinkSpeed = function() end,
  SetAltArrowKeyMode = function() end,
  GetInputLanguage = function() return "ROMAN" end,
}
for k, v in pairs(FontStringMethods) do
  if EditBoxExtra[k] == nil and k ~= "GetStringWidth" then EditBoxExtra[k] = v end
end
for k, v in pairs(EnableMethods) do EditBoxExtra[k] = v end
define("EditBox", "Frame", EditBoxExtra)

---------------------------------------------------------------------------------------------------
-- Slider / StatusBar
---------------------------------------------------------------------------------------------------
local function range_methods(kind)
  local t = {
    SetMinMaxValues = function(self, lo, hi)
      local st = S(self)
      if type(lo) ~= "number" or type(hi) ~= "number" then error("SetMinMaxValues: numbers expected", 2) end
      if lo > hi then error("SetMinMaxValues: min > max", 2) end
      local changed = st.min ~= lo or st.max ~= hi
      st.min, st.max = lo, hi
      if changed then call_script(self, "OnMinMaxChanged", lo, hi) end
      local v = st.value or lo
      if v < lo then v = lo elseif v > hi then v = hi end
      if v ~= st.value then st.value = v; call_script(self, "OnValueChanged", v, false) end
    end,
    GetMinMaxValues = function(self) local st = S(self); return st.min or 0, st.max or 0 end,
    SetValue = function(self, v, treatAsMouseEvent)
      local st = S(self)
      if type(v) ~= "number" then error("SetValue: number expected, got " .. type(v), 2) end
      local lo, hi = st.min or 0, st.max or 0
      if v < lo then v = lo elseif v > hi then v = hi end
      if st.value ~= v then
        st.value = v
        call_script(self, "OnValueChanged", v, treatAsMouseEvent and true or false)
      end
    end,
    GetValue = function(self) return S(self).value or (S(self).min or 0) end,
    SetOrientation = function(self, o) S(self).orientation = o end,
    GetOrientation = function(self) return S(self).orientation or "HORIZONTAL" end,
  }
  if kind == "Slider" then
    t.SetValueStep = function(self, s) S(self).step = s end
    t.GetValueStep = function(self) return S(self).step or 0 end
    t.SetObeyStepOnDrag = function(self, v) S(self).obey = v end
    t.GetObeyStepOnDrag = function(self) return S(self).obey or false end
    t.SetStepsPerPage = function() end
    t.GetStepsPerPage = function() return 1 end
    t.SetThumbTexture = tex_slot("thumb")
    t.GetThumbTexture = function(self)
      local st = S(self)
      if not st.thumb then st.thumb = Methods.Frame.CreateTexture(self) end
      return st.thumb
    end
    for k, v in pairs(EnableMethods) do t[k] = v end
  else
    t.SetStatusBarTexture = function(self, tex)
      local st = S(self)
      if type(tex) == "table" and OBJ[tex] then st.bartex = tex; return end
      if not st.bartex then st.bartex = Methods.Frame.CreateTexture(self) end
      st.bartex:SetTexture(tex)
    end
    t.GetStatusBarTexture = function(self)
      local st = S(self)
      if not st.bartex then st.bartex = Methods.Frame.CreateTexture(self) end
      return st.bartex
    end
    t.SetStatusBarColor = function(self, r, g, b, a) S(self).barcolor = { r, g, b, a or 1 } end
    t.GetStatusBarColor = function(self) local c = S(self).barcolor or { 1, 1, 1, 1 }; return c[1], c[2], c[3], c[4] end
    t.SetStatusBarAtlas = function() end
    t.SetReverseFill = function() end
    t.SetFillStyle = function() end
    t.SetRotatesTexture = function() end
    t.SetStatusBarDesaturated = function() end
  end
  return t
end
define("Slider", "Frame", range_methods("Slider"))
define("StatusBar", "Frame", range_methods("StatusBar"))

---------------------------------------------------------------------------------------------------
-- ScrollFrame, Cooldown, MessageFrames, Models, misc frame types
---------------------------------------------------------------------------------------------------
define("ScrollFrame", "Frame", {
  SetScrollChild = function(self, c)
    local st = S(self)
    st.scrollchild = c
    if c and OBJ[c] and OBJ[c].parent ~= self then set_parent(c, OBJ[c], self) end
  end,
  GetScrollChild = function(self) return S(self).scrollchild end,
  SetVerticalScroll = function(self, v) local st = S(self); st.vscroll = v; call_script(self, "OnVerticalScroll", v) end,
  GetVerticalScroll = function(self) return S(self).vscroll or 0 end,
  SetHorizontalScroll = function(self, v) local st = S(self); st.hscroll = v; call_script(self, "OnHorizontalScroll", v) end,
  GetHorizontalScroll = function(self) return S(self).hscroll or 0 end,
  GetVerticalScrollRange = function() return 0 end,
  GetHorizontalScrollRange = function() return 0 end,
  UpdateScrollChildRect = function() end,
})
define("Cooldown", "Frame", {
  SetCooldown = function(self, start, dur) local st = S(self); st.cd = { start, dur } end,
  Clear = function(self) S(self).cd = nil end,
  GetCooldownTimes = function(self) local c = S(self).cd; if c then return c[1] * 1000, c[2] * 1000 end return 0, 0 end,
  GetCooldownDuration = function(self) local c = S(self).cd; return c and c[2] * 1000 or 0 end,
})
local function message_methods()
  return {
    AddMessage = function(self, text, r, g, b, ...)
      local st = S(self)
      st.messages = st.messages or {}
      st.messages[#st.messages + 1] = tostring(text)
      if st.capture then st.capture(tostring(text), r, g, b, ...) end
    end,
    Clear = function(self) S(self).messages = {} end,
    GetNumMessages = function(self) return #(S(self).messages or {}) end,
    GetMessageInfo = function(self, i) return (S(self).messages or {})[i] end,
    SetFading = function() end, SetTimeVisible = function() end, SetMaxLines = function() end,
    SetInsertMode = function() end, ScrollToBottom = function() end, ScrollUp = function() end,
    ScrollDown = function() end, SetFontObject = FontStringMethods.SetFontObject, GetFontObject = FontStringMethods.GetFontObject,
    SetFont = FontStringMethods.SetFont, GetFont = FontStringMethods.GetFont, SetJustifyH = FontStringMethods.SetJustifyH,
    AddMsg = nil,
  }
end
define("MessageFrame", "Frame", message_methods())
define("ScrollingMessageFrame", "Frame", message_methods())
define("Model", "Frame", {
  SetFacing = function(self, v) S(self).facing = v end,
  GetFacing = function(self) return S(self).facing or 0 end,
  SetPosition = function(self, x, y, z) S(self).pos = { x, y, z } end,
  GetPosition = function(self) local p = S(self).pos or {}; return p[1] or 0, p[2] or 0, p[3] or 0 end,
  SetPortraitZoom = function(self, v) S(self).portraitZoom = v end,
  GetPortraitZoom = function(self) return S(self).portraitZoom or 0 end,
  SetCamDistanceScale = function(self, v) S(self).camScale = v end,
  GetCamDistanceScale = function(self) return S(self).camScale or 1 end,
  ClearModel = function(self) S(self).unit = nil end,
})
define("PlayerModel", "Model", {
  SetUnit = function(self, unit) S(self).unit = unit end,
  SetDisplayInfo = function(self, id) S(self).displayInfo = id end,
})
define("DressUpModel", "PlayerModel", {
  -- (item, slotName?) - the second argument is optional on Classic clients
  TryOn = function(self, item, slot) end,
  Undress = function(self) end,
  Dress = function(self) end,
})
-- ModelScene + actors (Azeromon's auto-fitted creatures). Actors are plain objects, like the real
-- ModelSceneActor. The mock reproduces what the real client showed:
--  * loading is asynchronous (MOCK_ACTOR_LOAD_TIME s); while a new model loads, the actor keeps the PREVIOUS
--    model: IsLoaded() stays true and the boxes are the old creature's (unless ClearModel() was called);
--  * with the "ModelSceneActorTemplate" template, SetOnModelLoadedCallback's callback fires when a load completes
--    (set __MOCK_NO_ACTOR_TEMPLATE = true to get bare actors without it);
--  * boxes are invented from the display ID, lopsided sideways (y from -0.3w to +0.7w); displays divisible by 3
--    "hover": their current-pose box bobs 0.3 up and down over time, and the all-animations box adds a rearing
--    animation 0.8 higher;
--  * Project3DPointTo2D uses conventions the addon does NOT assume: a HORIZONTAL field of view and screen-right
--    = -y. An addon that trusts its own camera maths gets sizes ~5% off and lopsided models off-centre; one that
--    checks with the projection gets them right.
local MOCK_ACTOR_LOAD_TIME = 0.15
local function Now() return (GetTime and GetTime()) or 0 end
local ActorMethods = {}
ActorMethods.__index = ActorMethods
function ActorMethods:Tick()
  if self.pending and Now() >= self.loadAt then
    self.display, self.pending = self.pending, nil
    if self.onLoaded then self.onLoaded(self) end
  end
end
function ActorMethods:SetModelByCreatureDisplayID(id)
  self.pending, self.loadAt = id, Now() + MOCK_ACTOR_LOAD_TIME
  return true
end
function ActorMethods:ClearModel() self.display, self.pending = nil, nil end
function ActorMethods:IsLoaded() self:Tick() return self.display ~= nil end
function ActorMethods:GetModelFileID() self:Tick() return self.display and (100000 + self.display) or nil end
function ActorMethods:SetOnModelLoadedCallback(fn)
  if not self.template then error("attempt to call method 'SetOnModelLoadedCallback' (a nil value)") end
  self.onLoaded = fn
end
function ActorMethods:SetUseCenterForOrigin(x, y, z) self.centerOrigin = { x, y, z } end
function ActorMethods:SetPreferModelCollisionBounds(v) self.collision = v end
local function MockSize(d) return 0.5 + (d % 9) * 0.6, 0.4 + (d % 5) * 0.5 end
function ActorMethods:GetActiveBoundingBox()
  self:Tick()
  if not self.display then return nil end
  local h, w = MockSize(self.display)
  local bob = (self.display % 3 == 0) and 0.3 * math.sin(Now() * 4) or 0
  return -w / 2, -0.3 * w, bob, w / 2, 0.7 * w, h + bob
end
function ActorMethods:GetMaxBoundingBox()
  self:Tick()
  if not self.display then return nil end
  local h, w = MockSize(self.display)
  local bob = (self.display % 3 == 0) and 0.3 or 0
  return -w / 2, -0.3 * w, -bob, w / 2, 0.7 * w, h + bob + 0.8
end
function ActorMethods:SetScale(v) self.scale = v end
function ActorMethods:GetScale() return self.scale or 1 end
function ActorMethods:SetPosition(x, y, z) self.pos = { x, y, z } end
function ActorMethods:GetPosition() local p = self.pos or {}; return p[1] or 0, p[2] or 0, p[3] or 0 end
function ActorMethods:SetYaw(v) self.yaw = v end
function ActorMethods:SetAlpha(v) self.alpha = v end
function ActorMethods:GetAlpha() return self.alpha or 1 end
function ActorMethods:SetAnimation(id) self.anim = id end
function ActorMethods:SetShown(v) self.shown = v and true or false end
define("ModelScene", "Frame", {
  CreateActor = function(self, name, template)
    local st = S(self)
    st.actors = st.actors or {}
    local a = setmetatable({}, ActorMethods)
    if template == "ModelSceneActorTemplate" and not rawget(_G, "__MOCK_NO_ACTOR_TEMPLATE") then a.template = template end
    st.actors[#st.actors + 1] = a
    return a
  end,
  SetCameraPosition = function(self, x, y, z) S(self).camPos = { x, y, z } end,
  GetCameraPosition = function(self) local p = S(self).camPos or { 0, 0, 0 }; return p[1], p[2], p[3] end,
  SetCameraOrientationByYawPitchRoll = function(self, y, p, r) S(self).camYPR = { y, p, r } end,
  SetCameraFieldOfView = function(self, v) S(self).fov = v end,
  GetCameraFieldOfView = function(self) return S(self).fov or 0.9 end,
  SetCameraNearClip = function(self, v) S(self).near = v end,
  SetCameraFarClip = function(self, v) S(self).far = v end,
  SetLightVisible = function(self, v) S(self).light = v end,
  SetLightDirection = function(self, x, y, z) end,
  SetLightAmbientColor = function(self, r, g, b) end,
  SetLightDiffuseColor = function(self, r, g, b) end,
  -- camera on +x looking along -x; horizontal FOV; screen-right = -y; returns pixels * effective scale
  Project3DPointTo2D = function(self, x, y, z)
    local st = S(self)
    local c = st.camPos or { 0, 0, 0 }
    local d = c[1] - x
    if d <= 0 then return nil end
    local W, H = self:GetWidth(), self:GetHeight()
    local f = (W / 2) / math.tan((st.fov or 0.9) / 2)
    local es = self:GetEffectiveScale() or 1
    return (W / 2 - (y - c[2]) / d * f) * es, (H / 2 + (z - c[3]) / d * f) * es, d
  end,
})
define("ColorSelect", "Frame", {})
define("SimpleHTML", "Frame", {
  SetText = function(self, v) S(self).text = to_text(v, "SetText") end,
  GetText = function(self) return S(self).text end,
  SetFont = FontStringMethods.SetFont, GetFont = FontStringMethods.GetFont,
  SetFontObject = FontStringMethods.SetFontObject, GetFontObject = FontStringMethods.GetFontObject,
})
define("Minimap", "Frame", {})

---------------------------------------------------------------------------------------------------
-- Animation groups (finish after their duration while M.step runs)
---------------------------------------------------------------------------------------------------
local AnimScriptMethods = {
  SetScript = function(self, name, fn)
    local st = set_script(self, name, fn, "SetScript")
    st.scripts[name] = fn
  end,
  GetScript = function(self, name) return S(self).scripts[name] end,
  HookScript = function(self, name, fn)
    local st = set_script(self, name, fn, "HookScript")
    local h = st.hooks[name] or {}
    st.hooks[name] = h
    h[#h + 1] = fn
  end,
  GetName = function(self) return S(self).name end,
  GetParent = function(self) return S(self).parent end,
  GetObjectType = function(self) return S(self).kind end,
  IsObjectType = function(self, t) for _, a in ipairs(ANCESTRY[S(self).kind]) do if a == t then return true end end return false end,
  IsForbidden = function() return false end,
}
local function group_duration(st)
  local orders = {}
  for _, a in ipairs(st.anims) do
    local as = OBJ[a]
    local o = as.order or 1
    local d = (as.duration or 0) + (as.delay or 0) + (as.enddelay or 0)
    if not orders[o] or orders[o] < d then orders[o] = d end
  end
  local total = 0
  for _, d in pairs(orders) do total = total + d end
  return total
end

local AG = {}
for k, v in pairs(AnimScriptMethods) do AG[k] = v end
AG.CreateAnimation = function(self, atype, name, template)
  local st = S(self)
  local a, as = M.CreateObject("Animation", name, nil)
  as.parent = self
  as.atype = atype or "Animation"
  as.duration = 0
  st.anims[#st.anims + 1] = a
  return a
end
AG.GetAnimations = function(self) return unpack(S(self).anims) end
AG.Play = function(self, reverse)
  local st = S(self)
  if st.playing then return end
  st.playing, st.paused, st.elapsed, st.done = true, false, 0, false
  st.duration = group_duration(st)
  M.playing_anims[self] = true
  call_script(self, "OnPlay")
end
AG.Restart = function(self) local st = S(self); st.playing = false; AG.Play(self) end
AG.Stop = function(self)
  local st = S(self)
  if not st.playing then return end
  st.playing = false
  M.playing_anims[self] = nil
  call_script(self, "OnStop", true)
end
AG.Finish = function(self)
  local st = S(self)
  if not st.playing then return end
  st.playing, st.done = false, true
  M.playing_anims[self] = nil
  call_script(self, "OnFinished", true)
end
AG.Pause = function(self) local st = S(self); if st.playing then st.paused = true; call_script(self, "OnPause") end end
AG.IsPlaying = function(self) local st = S(self); return st.playing and not st.paused or false end
AG.IsPaused = function(self) return S(self).paused or false end
AG.IsDone = function(self) return S(self).done or false end
AG.IsPendingFinish = function() return false end
AG.SetLooping = function(self, l) S(self).looping = l end
AG.GetLooping = function(self) return S(self).looping or "NONE" end
AG.GetDuration = function(self) return group_duration(S(self)) end
AG.GetProgress = function(self) local st = S(self); if st.duration and st.duration > 0 then return (st.elapsed or 0) / st.duration end return 0 end
AG.SetToFinalAlpha = function() end
AG.SetPlaying = function(self, v) if v then AG.Play(self) else AG.Stop(self) end end
define("AnimationGroup", nil, AG)

local AN = {}
for k, v in pairs(AnimScriptMethods) do AN[k] = v end
AN.SetDuration = function(self, d) S(self).duration = tonumber(d) or 0 end
AN.GetDuration = function(self) return S(self).duration or 0 end
AN.SetStartDelay = function(self, d) S(self).delay = tonumber(d) or 0 end
AN.GetStartDelay = function(self) return S(self).delay or 0 end
AN.SetEndDelay = function(self, d) S(self).enddelay = tonumber(d) or 0 end
AN.GetEndDelay = function(self) return S(self).enddelay or 0 end
AN.SetOrder = function(self, o) S(self).order = tonumber(o) or 1 end
AN.GetOrder = function(self) return S(self).order or 1 end
AN.SetChildKey = function(self, k) S(self).childkey = k end
AN.SetFromAlpha = function(self, a) S(self).fromAlpha = a end
AN.GetFromAlpha = function(self) return S(self).fromAlpha or 0 end
AN.SetToAlpha = function(self, a) S(self).toAlpha = a end
AN.GetToAlpha = function(self) return S(self).toAlpha or 0 end
AN.SetScale = function(self, x, y) S(self).scaleTo = { x, y } end
AN.SetScaleFrom = function() end
AN.SetScaleTo = function() end
AN.SetOffset = function(self, x, y) S(self).offset = { x, y } end
AN.SetDegrees = function(self, d) S(self).degrees = d end
AN.SetSmoothing = function(self, s) S(self).smoothing = s end
AN.SetOrigin = function() end
AN.SetTarget = function(self, t) S(self).target = t end
AN.GetTarget = function(self) return S(self).target end
AN.GetRegionParent = function(self) local g = S(self).parent; return g and OBJ[g] and OBJ[g].parent end
AN.Play = function() end
AN.Stop = function() end
AN.IsPlaying = function(self) local g = S(self).parent; return g and OBJ[g].playing or false end
define("Animation", nil, AN)

function M.CreateAnimationGroup(parent, name, template)
  local g, gs = M.CreateObject("AnimationGroup", name, nil)
  gs.parent = parent
  gs.anims = {}
  gs.template = template
  local ps = OBJ[parent]
  ps.anims = ps.anims or {}
  ps.anims[#ps.anims + 1] = g
  return g
end

function M.step_animations(dt)
  local list = {}
  for g in pairs(M.playing_anims) do list[#list + 1] = g end
  tsort(list, function(a, b) return OBJ[a].seq < OBJ[b].seq end)
  for _, g in ipairs(list) do
    local st = OBJ[g]
    if st.playing and not st.paused then
      st.elapsed = (st.elapsed or 0) + dt
      call_script(g, "OnUpdate", dt)
      if st.elapsed >= (st.duration or 0) then
        local loop = st.looping
        if loop == "REPEAT" or loop == "BOUNCE" then
          st.elapsed = 0
          call_script(g, "OnLoop", "FORWARD")
        else
          st.playing, st.done = false, true
          M.playing_anims[g] = nil
          call_script(g, "OnFinished", false)
        end
      end
    end
  end
end

function M.run_onupdates(dt)
  local list = M.onupdate_frames
  local n = #list
  for i = 1, n do
    local f = list[i]
    local st = OBJ[f]
    if st and (st.scripts.OnUpdate or st.hooks.OnUpdate) and (M.onupdate_hidden or is_visible(f)) then
      call_script(f, "OnUpdate", dt)
    end
  end
end

---------------------------------------------------------------------------------------------------
-- Font objects
---------------------------------------------------------------------------------------------------
define("Font", nil, {
  GetName = function(self) return S(self).name end,
  GetObjectType = function() return "Font" end,
  IsObjectType = function(self, t) return t == "Font" or t == "Object" end,
  SetFont = function(self, p, s, f) S(self).font = { p, s, f }; return true end,
  GetFont = function(self) local f = S(self).font or { "Fonts\\FRIZQT__.TTF", 12, "" }; return f[1], f[2], f[3] end,
  SetFontObject = function(self, fo) local r = resolve(fo); if r and OBJ[r] then S(self).font = { r:GetFont() } end end,
  CopyFontObject = function(self, fo) local r = resolve(fo); if r and OBJ[r] then S(self).font = { r:GetFont() } end end,
  GetFontObject = function(self) return self end,
  SetTextColor = function(self, r, g, b, a) S(self).tcolor = { r, g, b, a or 1 } end,
  GetTextColor = function(self) local c = S(self).tcolor or { 1, 0.82, 0, 1 }; return c[1], c[2], c[3], c[4] end,
  SetShadowColor = function() end, GetShadowColor = function() return 0, 0, 0, 1 end,
  SetShadowOffset = function() end, GetShadowOffset = function() return 1, -1 end,
  SetJustifyH = function() end, SetJustifyV = function() end, SetSpacing = function() end,
  GetFontObjectForAlphabet = function(self) return self end,
  IsForbidden = function() return false end,
})
function CreateFont(name)
  local f, st = M.CreateObject("Font", name, nil)
  st.font = { "Fonts\\FRIZQT__.TTF", 12, "" }
  return f
end
local FONT_NAMES = [[GameFontNormal GameFontNormalSmall GameFontNormalLarge GameFontNormalHuge GameFontNormalMed1
  GameFontNormalMed2 GameFontNormalMed3 GameFontNormalLeft GameFontNormalCenter GameFontNormalOutline GameFontNormalShadowOutline22
  GameFontHighlight GameFontHighlightSmall GameFontHighlightLarge GameFontHighlightHuge GameFontHighlightMedium
  GameFontHighlightLeft GameFontHighlightCenter GameFontHighlightRight GameFontHighlightOutline GameFontHighlightSmallOutline
  GameFontHighlightSmallLeft GameFontHighlightExtraSmall GameFontHighlightMed2 GameFontDisable GameFontDisableSmall
  GameFontDisableLarge GameFontGreen GameFontGreenSmall GameFontRed GameFontRedSmall GameFontRedLarge GameFontWhite
  GameFontWhiteSmall GameFontBlack GameFontBlackSmall GameFontDarkGraySmall GameFontNormalSmallLeft GameFontNormal_NoShadow
  GameTooltipText GameTooltipTextSmall GameTooltipHeaderText NumberFontNormal NumberFontNormalSmall NumberFontNormalLarge
  NumberFontNormalHuge NumberFont_Outline_Med NumberFont_Shadow_Med ChatFontNormal ChatFontSmall SystemFont_Small
  SystemFont_Med1 SystemFont_Med2 SystemFont_Med3 SystemFont_Large SystemFont_Huge1 SystemFont_Outline_Small
  SystemFont_Shadow_Med1 SystemFont_Shadow_Large SystemFont_Tiny QuestFont QuestTitleFont Fancy16Font Fancy22Font
  SubZoneTextFont ZoneTextFont FriendsFont_Normal FriendsFont_Small ObjectiveFont GameFontHighlightMedium
  GameFontNormalTiny GameFontHighlightTiny SplashHeaderFont DestinyFontLarge DestinyFontHuge Game11Font Game12Font
  Game13Font Game15Font Game18Font Game20Font Game24Font Game30Font GameFontHighlightShadow]]
for n in FONT_NAMES:gmatch("%S+") do if rawget(_G, n) == nil then CreateFont(n) end end
STANDARD_TEXT_FONT = "Fonts\\FRIZQT__.TTF"
UNIT_NAME_FONT = "Fonts\\FRIZQT__.TTF"
DAMAGE_TEXT_FONT = "Fonts\\FRIZQT__.TTF"
NAMEPLATE_FONT = "Fonts\\FRIZQT__.TTF"

M.define = define
M.ANCESTRY = ANCESTRY
M.set_parent = set_parent
M.SCRIPTS = SCRIPTS
