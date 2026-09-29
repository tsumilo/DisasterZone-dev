-- wowmock/ui.lua : CreateFrame + templates, Blizzard UI globals, tooltips, popups, menus, settings,
-- scroll boxes / data providers, pools, mixins, colors.
local M, cfg, PY = ...

local _G = _G
local type, tostring, tonumber, select, pairs, ipairs, next = type, tostring, tonumber, select, pairs, ipairs, next
local setmetatable, rawget, rawset, error = setmetatable, rawget, rawset, error
local unpack = unpack
local sformat, sgsub, sfind, ssub, smatch, slower, supper = string.format, string.gsub, string.find, string.sub, string.match, string.lower, string.upper
local tinsert, tremove, tconcat, tsort = table.insert, table.remove, table.concat, table.sort
local safecall, OBJ, Methods, S, call_script = M.safecall, M.OBJ, M.Methods, M.S, M.call_script
local NOOP = M.NOOP

---------------------------------------------------------------------------------------------------
-- Mixins / callback registry
---------------------------------------------------------------------------------------------------
function Mixin(object, ...)
  for i = 1, select("#", ...) do
    local mixin = select(i, ...)
    if type(mixin) ~= "table" then error("Mixin: argument #" .. (i + 1) .. " is not a table", 2) end
    for k, v in pairs(mixin) do rawset(object, k, v) end
  end
  return object
end
function CreateFromMixins(...) return Mixin({}, ...) end
function CreateAndInitFromMixin(mixin, ...)
  local o = CreateFromMixins(mixin)
  o:Init(...)
  return o
end

CallbackRegistryMixin = {}
function CallbackRegistryMixin:OnLoad() self.callbackTables = {} end
CallbackRegistryMixin.Init = CallbackRegistryMixin.OnLoad
function CallbackRegistryMixin:SetUndefinedEventsAllowed() end
function CallbackRegistryMixin:GenerateCallbackEvents(events)
  self.Event = self.Event or {}
  for _, e in ipairs(events) do self.Event[e] = e end
end
function CallbackRegistryMixin:RegisterCallback(event, func, owner, ...)
  self.callbackTables = self.callbackTables or {}
  local t = self.callbackTables[event]
  if not t then t = {}; self.callbackTables[event] = t end
  owner = owner or func
  local n = select("#", ...)
  local args = { ... }
  t[#t + 1] = { owner = owner, func = func, args = args, n = n }
  return owner
end
function CallbackRegistryMixin:RegisterCallbackWithHandle(event, func, owner, ...)
  local o = self:RegisterCallback(event, func, owner, ...)
  local reg = self
  return { Unregister = function() reg:UnregisterCallback(event, o) end }
end
function CallbackRegistryMixin:UnregisterCallback(event, owner)
  local t = self.callbackTables and self.callbackTables[event]
  if not t then return end
  for i = #t, 1, -1 do if t[i].owner == owner then tremove(t, i) end end
end
function CallbackRegistryMixin:UnregisterEvents(events) for _, e in ipairs(events or {}) do self.callbackTables[e] = nil end end
function CallbackRegistryMixin:TriggerEvent(event, ...)
  local t = self.callbackTables and self.callbackTables[event]
  if not t then return end
  local copy = {}
  for i = 1, #t do copy[i] = t[i] end
  for _, cb in ipairs(copy) do
    if cb.n > 0 then
      local extra = { unpack(cb.args, 1, cb.n) }
      local n2 = select("#", ...)
      for i = 1, n2 do extra[cb.n + i] = select(i, ...) end
      safecall("TriggerEvent(" .. tostring(event) .. ")", cb.func, cb.owner, unpack(extra, 1, cb.n + n2))
    else
      safecall("TriggerEvent(" .. tostring(event) .. ")", cb.func, cb.owner, ...)
    end
  end
end
function CallbackRegistryMixin:HasRegistrantsForEvent(event)
  local t = self.callbackTables and self.callbackTables[event]
  return t ~= nil and #t > 0
end

EventRegistry = CreateFromMixins(CallbackRegistryMixin)
EventRegistry:OnLoad()
do
  local evframe
  function EventRegistry:RegisterFrameEventAndCallback(event, func, owner, ...)
    if not evframe then
      evframe = CreateFrame("Frame")
      evframe:SetScript("OnEvent", function(_, ev, ...) EventRegistry:TriggerEvent(ev, ...) end)
    end
    evframe:RegisterEvent(event)
    return self:RegisterCallback(event, func, owner, ...)
  end
  function EventRegistry:UnregisterFrameEventAndCallback(event, owner) self:UnregisterCallback(event, owner) end
end

EventUtil = {}
function EventUtil.ContinueOnAddOnLoaded(addon, fn)
  if M.loaded_addons[addon] then fn(); return end
  local f = CreateFrame("Frame")
  f:RegisterEvent("ADDON_LOADED")
  f:SetScript("OnEvent", function(self, _, name)
    if name == addon then self:UnregisterEvent("ADDON_LOADED"); fn() end
  end)
end
function EventUtil.RegisterOnceFrameEventAndCallback(event, fn, ...)
  local f = CreateFrame("Frame")
  local n = select("#", ...)
  local args = { ... }
  f:RegisterEvent(event)
  f:SetScript("OnEvent", function(self, ev, ...)
    self:UnregisterEvent(event)
    if n > 0 then fn(unpack(args, 1, n)) else fn(ev, ...) end
  end)
end
function EventUtil.ContinueAfterAllEvents(fn, ...)
  local pending, left = {}, select("#", ...)
  local f = CreateFrame("Frame")
  for i = 1, select("#", ...) do local e = select(i, ...); pending[e] = true; f:RegisterEvent(e) end
  f:SetScript("OnEvent", function(self, ev)
    if pending[ev] then pending[ev] = nil; left = left - 1; self:UnregisterEvent(ev) end
    if left <= 0 then fn() end
  end)
end
function EventUtil.CreateFrameEventHandle() return nil end
function EventUtil.AreVariablesLoaded() return M.variables_loaded == true end
C_EventUtils = { IsEventValid = function() return true end, IsCallbackEvent = function() return false end }
FunctionUtil = {}
function FunctionUtil.ExecuteFrameScript(frame, script, ...) call_script(frame, script, ...) end

---------------------------------------------------------------------------------------------------
-- Colors
---------------------------------------------------------------------------------------------------
ColorMixin = {}
function ColorMixin:OnLoad(r, g, b, a) self:SetRGBA(r, g, b, a) end
function ColorMixin:SetRGBA(r, g, b, a) self.r, self.g, self.b, self.a = r, g, b, a end
function ColorMixin:SetRGB(r, g, b) self:SetRGBA(r, g, b, nil) end
function ColorMixin:GetRGB() return self.r, self.g, self.b end
function ColorMixin:GetRGBA() return self.r, self.g, self.b, self.a or 1 end
function ColorMixin:GetRGBAsBytes() return math.floor(self.r * 255 + 0.5), math.floor(self.g * 255 + 0.5), math.floor(self.b * 255 + 0.5) end
function ColorMixin:GetRGBAAsBytes() local r, g, b = self:GetRGBAsBytes(); return r, g, b, math.floor((self.a or 1) * 255 + 0.5) end
function ColorMixin:IsEqualTo(o) return self.r == o.r and self.g == o.g and self.b == o.b and (self.a or 1) == (o.a or 1) end
function ColorMixin:GenerateHexColor() local r, g, b, a = self:GetRGBAAsBytes(); return sformat("%02x%02x%02x%02x", a, r, g, b) end
function ColorMixin:GenerateHexColorNoAlpha() local r, g, b = self:GetRGBAsBytes(); return sformat("%02x%02x%02x", r, g, b) end
function ColorMixin:GenerateHexColorMarkup() return "|c" .. self:GenerateHexColor() end
function ColorMixin:WrapTextInColorCode(text) return "|c" .. self:GenerateHexColor() .. tostring(text) .. "|r" end
function CreateColor(r, g, b, a)
  local c = CreateFromMixins(ColorMixin)
  c:OnLoad(r, g, b, a)
  return c
end
function CreateColorFromBytes(r, g, b, a) return CreateColor(r / 255, g / 255, b / 255, (a or 255) / 255) end
function CreateColorFromHexString(hex)
  if #hex == 8 then
    local a, r, g, b = tonumber(ssub(hex, 1, 2), 16), tonumber(ssub(hex, 3, 4), 16), tonumber(ssub(hex, 5, 6), 16), tonumber(ssub(hex, 7, 8), 16)
    return CreateColorFromBytes(r, g, b, a)
  end
end
CreateColorFromRGBAHexString = function(hex)
  local r, g, b, a = tonumber(ssub(hex, 1, 2), 16), tonumber(ssub(hex, 3, 4), 16), tonumber(ssub(hex, 5, 6), 16), tonumber(ssub(hex, 7, 8), 16)
  return CreateColorFromBytes(r, g, b, a)
end
function WrapTextInColorCode(text, hex) return "|c" .. hex .. tostring(text) .. "|r" end
function WrapTextInColor(text, color) return color:WrapTextInColorCode(text) end
NORMAL_FONT_COLOR = CreateColor(1.0, 0.82, 0.0)
HIGHLIGHT_FONT_COLOR = CreateColor(1.0, 1.0, 1.0)
WHITE_FONT_COLOR = CreateColor(1.0, 1.0, 1.0)
GRAY_FONT_COLOR = CreateColor(0.5, 0.5, 0.5)
DISABLED_FONT_COLOR = CreateColor(0.5, 0.5, 0.5)
GREEN_FONT_COLOR = CreateColor(0.1, 1.0, 0.1)
RED_FONT_COLOR = CreateColor(1.0, 0.1, 0.1)
DIM_RED_FONT_COLOR = CreateColor(0.8, 0.1, 0.1)
YELLOW_FONT_COLOR = CreateColor(1.0, 1.0, 0.0)
ORANGE_FONT_COLOR = CreateColor(1.0, 0.5, 0.25)
LIGHTBLUE_FONT_COLOR = CreateColor(0.53, 0.67, 1.0)
BLUE_FONT_COLOR = CreateColor(0.0, 0.749, 0.953)
BLACK_FONT_COLOR = CreateColor(0, 0, 0)
EPIC_PURPLE_COLOR = CreateColor(0.64, 0.21, 0.93)
LEGENDARY_ORANGE_COLOR = CreateColor(1.0, 0.5, 0.0)
PASSIVE_SPELL_FONT_COLOR = CreateColor(0.77, 0.64, 0.0)
NORMAL_FONT_COLOR_CODE = "|cffffd200"
HIGHLIGHT_FONT_COLOR_CODE = "|cffffffff"
RED_FONT_COLOR_CODE = "|cffff2020"
GREEN_FONT_COLOR_CODE = "|cff20ff20"
GRAY_FONT_COLOR_CODE = "|cff808080"
YELLOW_FONT_COLOR_CODE = "|cffffff00"
LIGHTYELLOW_FONT_COLOR_CODE = "|cffffff9a"
ORANGE_FONT_COLOR_CODE = "|cffff7f3f"
FONT_COLOR_CODE_CLOSE = "|r"

---------------------------------------------------------------------------------------------------
-- Backdrop
---------------------------------------------------------------------------------------------------
BackdropTemplateMixin = {
  SetBackdrop = function(self, info) S(self).backdrop_info = info end,
  GetBackdrop = function(self) return S(self).backdrop_info end,
  ApplyBackdrop = function() end,
  ClearBackdrop = function(self) S(self).backdrop_info = nil end,
  HasBackdropInfo = function(self, info) return S(self).backdrop_info == info end,
  SetBackdropColor = function(self, r, g, b, a) S(self).bdcolor = { r, g, b, a or 1 } end,
  GetBackdropColor = function(self) local c = S(self).bdcolor or { 1, 1, 1, 1 }; return c[1], c[2], c[3], c[4] end,
  SetBackdropBorderColor = function(self, r, g, b, a) S(self).bdbcolor = { r, g, b, a or 1 } end,
  GetBackdropBorderColor = function(self) local c = S(self).bdbcolor or { 1, 1, 1, 1 }; return c[1], c[2], c[3], c[4] end,
  OnBackdropLoaded = function() end,
  OnBackdropSizeChanged = function() end,
  SetupTextureCoordinates = function() end,
  SetBorderBlendMode = function() end,
}
BACKDROP_TOOLTIP_16_16_5555 = { bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileEdge = true, tileSize = 16, edgeSize = 16, insets = { left = 5, right = 5, top = 5, bottom = 5 } }
BACKDROP_DIALOG_32_32 = { bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background", edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border", tile = true, tileEdge = true, tileSize = 32, edgeSize = 32, insets = { left = 11, right = 12, top = 12, bottom = 11 } }
BACKDROP_DARK_DIALOG_32_32 = BACKDROP_DIALOG_32_32
BACKDROP_SLIDER_8_8 = { bgFile = "Interface\\Buttons\\UI-SliderBar-Background", edgeFile = "Interface\\Buttons\\UI-SliderBar-Border", tile = true, tileEdge = true, tileSize = 8, edgeSize = 8, insets = { left = 3, right = 3, top = 6, bottom = 6 } }
BACKDROP_TEXT_PANEL_0_16 = BACKDROP_TOOLTIP_16_16_5555
BACKDROP_TUTORIAL_16_16 = BACKDROP_TOOLTIP_16_16_5555

---------------------------------------------------------------------------------------------------
-- Templates
---------------------------------------------------------------------------------------------------
local TEMPLATES = {}
M.TEMPLATES = TEMPLATES

local function child(frame, kind, key, suffix, layer, template)
  local st = OBJ[frame]
  local name = (st.name and suffix) and (st.name .. suffix) or nil
  local obj
  if kind == "Texture" then obj = Methods.Frame.CreateTexture(frame, name, layer or "ARTWORK")
  elseif kind == "FontString" then obj = Methods.Frame.CreateFontString(frame, name, layer or "OVERLAY")
  else obj = M.CreateFrameInternal(kind, name, frame, template) end
  if key then rawset(frame, key, obj) end
  local cs = OBJ[obj]
  cs.template = cs.template or ((st.template or st.kind) .. "." .. (key or suffix or "?"))
  return obj
end
M.template_child = child

local function T(names, fn) for n in names:gmatch("%S+") do TEMPLATES[n] = fn end end

local function panel_title(frame, st, with_close, with_inset, with_portrait)
  child(frame, "Frame", "NineSlice")
  child(frame, "Texture", "Bg", "Bg", "BACKGROUND")
  local tc = child(frame, "Frame", "TitleContainer")
  local tt = child(tc, "FontString", "TitleText", nil, "OVERLAY")
  rawset(frame, "TitleText", tt)
  if with_close then
    local cb = child(frame, "Button", "CloseButton", "CloseButton", nil, "UIPanelCloseButton")
  end
  if with_inset then child(frame, "Frame", "Inset", "Inset", nil, "InsetFrameTemplate") end
  if with_portrait then
    local pc = child(frame, "Frame", "PortraitContainer")
    local p = child(pc, "Texture", "portrait", nil, "OVERLAY")
    rawset(frame, "portrait", p)
  end
  rawset(frame, "SetTitle", function(self, text) tt:SetText(text) end)
  rawset(frame, "SetTitleFormatted", function(self, fmt, ...) tt:SetFormattedText(fmt, ...) end)
  rawset(frame, "GetTitleText", function(self) return tt end)
  rawset(frame, "SetTitleOffsets", NOOP)
  rawset(frame, "SetPortraitToAsset", NOOP)
  rawset(frame, "SetPortraitTextureRaw", NOOP)
  rawset(frame, "SetPortraitToUnit", NOOP)
  rawset(frame, "SetPortraitShown", NOOP)
  rawset(frame, "SetBorder", NOOP)
end

T("BackdropTemplate", function(f) Mixin(f, BackdropTemplateMixin) end)
T("TooltipBackdropTemplate TooltipBorderBackdropTemplate TooltipBorderedFrameTemplate TranslucentFrameTemplate",
  function(f) Mixin(f, BackdropTemplateMixin); child(f, "Frame", "NineSlice"); child(f, "Texture", "Bg", nil, "BACKGROUND") end)
T("BasicFrameTemplate BasicFrameTemplateWithInset", function(f, st, tname)
  child(f, "Texture", "Bg", "Bg", "BACKGROUND")
  child(f, "Texture", "TitleBg", "TitleBg", "BACKGROUND")
  child(f, "FontString", "TitleText", "TitleText", "OVERLAY")
  child(f, "Button", "CloseButton", "CloseButton", nil, "UIPanelCloseButton")
  if tname == "BasicFrameTemplateWithInset" then child(f, "Frame", "Inset", "Inset", nil, "InsetFrameTemplate") end
end)
T("PortraitFrameTemplate PortraitFrameFlatTemplate PortraitFrameTexturedBaseTemplate", function(f, st) panel_title(f, st, true, false, true) end)
T("PortraitFrameTemplateNoCloseButton PortraitFrameFlatBaseTemplate", function(f, st) panel_title(f, st, false, false, true) end)
T("ButtonFrameTemplate ButtonFrameTemplateMinimizable", function(f, st) panel_title(f, st, true, true, true) end)
T("ButtonFrameTemplateNoPortrait", function(f, st) panel_title(f, st, true, true, false) end)
T("DefaultPanelTemplate DefaultPanelFlatTemplate DefaultPanelBaseTemplate", function(f, st) panel_title(f, st, false, false, false) end)
T("InsetFrameTemplate InsetFrameTemplate2 InsetFrameTemplate3 InsetFrameTemplate4 DialogBorderTemplate DialogBorderDarkTemplate DialogBorderTranslucentTemplate DialogBorderOpaqueTemplate NineSlicePanelTemplate",
  function(f) child(f, "Texture", "Bg", "Bg", "BACKGROUND"); child(f, "Frame", "NineSlice") end)
T("UIPanelButtonTemplate UIPanelButtonNoTooltipTemplate UIPanelDynamicResizeButtonTemplate SharedButtonTemplate SharedButtonSmallTemplate SharedButtonLargeTemplate GameMenuButtonTemplate MagicButtonTemplate UIMenuButtonStretchTemplate UIPanelButtonGrayTemplate UIGoldBorderButtonTemplate UIPanelSquareButton UIPanelLargeSilverButton",
  function(f, st)
    child(f, "Texture", "Left", "Left", "BACKGROUND")
    child(f, "Texture", "Middle", "Middle", "BACKGROUND")
    child(f, "Texture", "Right", "Right", "BACKGROUND")
    local fs = child(f, "FontString", "Text", "Text", "OVERLAY")
    st.fontstring = fs
    rawset(f, "FitToText", NOOP)
  end)
T("UIPanelCloseButton UIPanelCloseButtonDefaultAnchors UIPanelCloseButtonNoScripts UIPanelHideButtonNoScripts", function(f, st, tname)
  if tname ~= "UIPanelCloseButtonNoScripts" and tname ~= "UIPanelHideButtonNoScripts" then
    st.scripts.OnClick = function(self) local p = self:GetParent(); if p then p:Hide() end end
  end
end)
T("UICheckButtonTemplate InterfaceOptionsCheckButtonTemplate ChatConfigCheckButtonTemplate OptionsBaseCheckButtonTemplate OptionsSmallCheckButtonTemplate OptionsCheckButtonTemplate SettingsCheckBoxTemplate SettingsCheckboxTemplate MinimalCheckboxTemplate ResizeCheckButtonTemplate UIRadioButtonTemplate",
  function(f, st)
    local fs = child(f, "FontString", "Text", "Text", "ARTWORK")
    rawset(f, "text", fs)
    st.fontstring = fs
  end)
T("OptionsSliderTemplate HorizontalSliderTemplate UISliderTemplate UISliderTemplateWithLabels OptionsBaseSliderTemplate",
  function(f, st)
    child(f, "FontString", "Text", "Text", "ARTWORK")
    child(f, "FontString", "Low", "Low", "ARTWORK")
    child(f, "FontString", "High", "High", "ARTWORK")
    st.thumb = child(f, "Texture", "Thumb", "Thumb", "ARTWORK")
  end)
MinimalSliderWithSteppersMixin = { Event = { OnValueChanged = "OnValueChanged", OnInteractStart = "OnInteractStart", OnInteractEnd = "OnInteractEnd" },
  Label = { Left = 1, Right = 2, Top = 3, Min = 4, Max = 5 } }
T("MinimalSliderWithSteppersTemplate", function(f, st)
  local sl = child(f, "Slider", "Slider")
  child(f, "Button", "Back")
  child(f, "Button", "Forward")
  for _, k in ipairs({ "LeftText", "RightText", "TopText", "MinText", "MaxText" }) do child(f, "FontString", k) end
  Mixin(f, CallbackRegistryMixin)
  f:OnLoad()
  rawset(f, "Event", MinimalSliderWithSteppersMixin.Event)
  sl:SetScript("OnValueChanged", function(_, v) f:TriggerEvent("OnValueChanged", v) end)
  rawset(f, "Init", function(self, value, min, max, steps, formatters)
    sl:SetMinMaxValues(min or 0, max or 1)
    if steps and steps > 0 then sl:SetValueStep(((max or 1) - (min or 0)) / steps) end
    sl:SetValue(value or min or 0)
  end)
  rawset(f, "SetValue", function(self, v) sl:SetValue(v) end)
  rawset(f, "GetValue", function(self) return sl:GetValue() end)
  rawset(f, "SetEnabled", function(self, v) sl:SetEnabled(v) end)
  rawset(f, "IsEnabled", function(self) return sl:IsEnabled() end)
  rawset(f, "FormatValue", NOOP)
end)
T("InputBoxTemplate InputBoxInstructionsTemplate SearchBoxTemplate InputBoxScriptTemplate LargeInputBoxTemplate BagSearchBoxTemplate",
  function(f, st, tname)
    child(f, "Texture", "Left", "Left", "BACKGROUND")
    child(f, "Texture", "Middle", "Middle", "BACKGROUND")
    child(f, "Texture", "Right", "Right", "BACKGROUND")
    if tname ~= "InputBoxTemplate" and tname ~= "InputBoxScriptTemplate" then
      child(f, "FontString", "Instructions", nil, "ARTWORK")
    end
    if tname == "SearchBoxTemplate" or tname == "BagSearchBoxTemplate" then
      child(f, "Texture", "searchIcon", nil, "OVERLAY")
      child(f, "Button", "clearButton")
    end
    if st.kind == "EditBox" then
      st.scripts.OnEscapePressed = function(self) self:ClearFocus() end
    end
  end)
T("UIPanelScrollFrameTemplate UIPanelScrollFrameTemplate2 UIPanelScrollFrameCodeTemplate FauxScrollFrameTemplate FauxScrollFrameTemplateLight",
  function(f, st)
    local sb = child(f, "Slider", "ScrollBar", "ScrollBar")
    child(sb, "Button", "ScrollUpButton", "ScrollUpButton")
    child(sb, "Button", "ScrollDownButton", "ScrollDownButton")
    OBJ[sb].thumb = child(sb, "Texture", "ThumbTexture", "ThumbTexture")
  end)
T("InputScrollFrameTemplate", function(f, st)
  local sb = child(f, "Slider", "ScrollBar", "ScrollBar")
  local eb = child(f, "EditBox", "EditBox", "EditBox")
  OBJ[eb].multiline = true
  child(f, "FontString", "CharCount")
  if st.kind == "ScrollFrame" then st.scrollchild = eb end
end)
local function scrollbar_children(f)
  child(f, "Button", "Back")
  child(f, "Button", "Forward")
  local tr = child(f, "Frame", "Track")
  child(tr, "Button", "Thumb")
end
T("MinimalScrollBar WowTrimScrollBar WowClassicScrollBar ScrollBarTemplate OribosScrollBar", function(f) scrollbar_children(f) end)
T("ScrollFrameTemplate", function(f, st)
  local sb = child(f, "Frame", "ScrollBar", nil, nil, "MinimalScrollBar")
end)

---------------------------------------------------------------------------------------------------
-- Tabs / dropdowns / item buttons
---------------------------------------------------------------------------------------------------
T("TabButtonTemplate PanelTabButtonTemplate CharacterFrameTabButtonTemplate PanelTopTabButtonTemplate TabSystemButtonTemplate MinimalTabTemplate CharacterFrameTabTemplate",
  function(f, st)
    local fs = child(f, "FontString", "Text", "Text", "OVERLAY")
    st.fontstring = fs
    for _, k in ipairs({ "Left", "Middle", "Right", "LeftActive", "MiddleActive", "RightActive",
                         "LeftDisabled", "MiddleDisabled", "RightDisabled", "LeftHighlight", "MiddleHighlight", "RightHighlight" }) do
      child(f, "Texture", k, k, "BACKGROUND")
    end
    child(f, "Texture", "HighlightTexture", "HighlightTexture", "HIGHLIGHT")
  end)
T("UIDropDownMenuTemplate", function(f, st)
  child(f, "Texture", "Left", "Left", "ARTWORK")
  child(f, "Texture", "Middle", "Middle", "ARTWORK")
  child(f, "Texture", "Right", "Right", "ARTWORK")
  child(f, "FontString", "Text", "Text", "ARTWORK")
  child(f, "Button", "Button", "Button")
  child(f, "Texture", "Icon", "Icon", "ARTWORK")
end)
local function item_button(f, st, tname)
  local ic = child(f, "Texture", "icon", "IconTexture", "BORDER")
  rawset(f, "Icon", ic)
  child(f, "FontString", "Count", "Count", "ARTWORK")
  child(f, "FontString", "Stock", "Stock", "ARTWORK")
  child(f, "Texture", "IconBorder", nil, "OVERLAY")
  child(f, "Texture", "IconOverlay", nil, "OVERLAY")
  child(f, "Texture", "IconOverlay2", nil, "OVERLAY")
  st.normaltex = child(f, "Texture", "NormalTexture", "NormalTexture", "ARTWORK")
  child(f, "Texture", "searchOverlay", "SearchOverlay", "OVERLAY")
  child(f, "Texture", "ItemContextOverlay", nil, "OVERLAY")
  if tname == "LootButtonTemplate" then
    local tx = child(f, "FontString", "Text", "Text", "ARTWORK")
    child(f, "Texture", "IconQuestTexture", "IconQuestTexture", "OVERLAY")
    child(f, "Frame", "NameFrame", "NameFrame")
  end
  if tname == "LargeItemButtonTemplate" or tname == "SmallItemButtonTemplate" then
    child(f, "Frame", "NameFrame", "NameFrame")
    child(f, "FontString", "Name", "Name", "ARTWORK")
  end
end
T("ItemButtonTemplate ContainerFrameItemButtonTemplate LargeItemButtonTemplate SmallItemButtonTemplate LootButtonTemplate PaperDollItemSlotButtonTemplate EnhancedItemButtonTemplate CircularItemButtonTemplate",
  item_button)
T("ActionButtonTemplate", function(f, st)
  child(f, "Texture", "icon", "Icon", "BACKGROUND")
  rawset(f, "Icon", rawget(f, "icon"))
  child(f, "FontString", "Name", "Name", "OVERLAY")
  child(f, "FontString", "Count", "Count", "ARTWORK")
  child(f, "FontString", "HotKey", "HotKey", "ARTWORK")
  child(f, "Texture", "Border", "Border", "OVERLAY")
  child(f, "Cooldown", "cooldown", "Cooldown", nil)
  st.normaltex = child(f, "Texture", "NormalTexture", "NormalTexture", "ARTWORK")
  child(f, "Texture", "Flash", "Flash", "ARTWORK")
  child(f, "Texture", "FlyoutArrow", nil, "OVERLAY")
  child(f, "MaskTexture", "IconMask", nil, "ARTWORK")
end)
local NOTHING = function() end
T("SecureActionButtonTemplate SecureUnitButtonTemplate SecureHandlerStateTemplate SecureHandlerBaseTemplate SecureHandlerClickTemplate SecureHandlerAttributeTemplate SecureFrameTemplate SecureHandlerShowHideTemplate SecureHandlerEnterLeaveTemplate CooldownFrameTemplate UIPanelInfoButton UIPanelScrollUpButtonTemplate UIPanelScrollDownButtonTemplate GlowBoxTemplate ThinBorderTemplate UIMenuTemplate SettingsListElementTemplate DefaultScaleFrame ResizeLayoutFrame VerticalLayoutFrame HorizontalLayoutFrame GridLayoutFrame UIDropDownListTemplate UIPanelDialogTemplate ColorSwatchTemplate MainMenuBarMicroButton HelpPlateButton",
  NOTHING)
T("GameTooltipTemplate SharedTooltipTemplate SharedNoHeaderTooltipTemplate ShoppingTooltipTemplate", function(f, st)
  if st.kind ~= "GameTooltip" then M.warn("GameTooltipTemplate used on a " .. st.kind .. " (should be CreateFrame(\"GameTooltip\", ...))") end
  child(f, "Frame", "NineSlice")
end)

-- Modern dropdown button (WowStyle1DropdownTemplate & friends)
local DropdownMock = {}
function DropdownMock:SetupMenu(generator)
  local st = S(self)
  st.menu_gen = generator
  self:GenerateMenu()
end
function DropdownMock:GenerateMenu()
  local st = S(self)
  if not st.menu_gen then return end
  local root = M.new_menu_desc("root", nil)
  root.owner = self
  safecall("Dropdown menu generator " .. M.obj_label(self), st.menu_gen, self, root)
  st.menu = root
  local sel = M.menu_selected_text(root)
  local fs = rawget(self, "Text")
  if st.override_text then
    if fs then fs:SetText(st.override_text) end
  elseif sel then
    if fs then fs:SetText(sel) end
  elseif st.default_text and fs then fs:SetText(st.default_text) end
end
function DropdownMock:OpenMenu()
  local st = S(self)
  self:GenerateMenu()
  st.menu_open = true
  M.last_menu = st.menu
  M.menus[#M.menus + 1] = st.menu
end
function DropdownMock:CloseMenu() S(self).menu_open = false end
function DropdownMock:IsMenuOpen() return S(self).menu_open or false end
function DropdownMock:SetDefaultText(t) S(self).default_text = t; self:GenerateMenu() end
function DropdownMock:GetDefaultText() return S(self).default_text end
function DropdownMock:OverrideText(t) local st = S(self); st.override_text = t; local fs = rawget(self, "Text"); if fs then fs:SetText(t) end end
function DropdownMock:GetMenuDescription() return S(self).menu end
function DropdownMock:SetSelectionTranslator(fn) S(self).sel_translator = fn end
function DropdownMock:SetSelectionText(fn) S(self).sel_text = fn end
function DropdownMock:Update() self:GenerateMenu() end
function DropdownMock:SignalUpdate() self:GenerateMenu() end
function DropdownMock:HasElements() local m = S(self).menu; return m ~= nil and #m.children > 0 end
function DropdownMock:SetMenuAnchor() end
function DropdownMock:SetMenuOpen(v) if v then self:OpenMenu() else self:CloseMenu() end end
function DropdownMock:RegisterCallback() end
function DropdownMock:GetText() local fs = rawget(self, "Text"); return fs and fs:GetText() end
function DropdownMock:SetText(t) local fs = rawget(self, "Text"); if fs then fs:SetText(t) end end
DropdownButtonMixin = DropdownMock
T("WowStyle1DropdownTemplate WowStyle1FilterDropdownTemplate WowStyle2DropdownTemplate WowStyle1ArrowDropdownTemplate DropdownButton WowStyleDropdownTemplate",
  function(f, st)
    child(f, "FontString", "Text", nil, "ARTWORK")
    child(f, "Texture", "Arrow", nil, "ARTWORK")
    child(f, "Texture", "Background", nil, "BACKGROUND")
    Mixin(f, DropdownMock)
  end)
T("WowScrollBoxList WowScrollBox", function(f, st, tname)
  child(f, "Frame", "ScrollTarget")
  Mixin(f, M.ScrollBoxMock)
  st.scrollbox = { frames = {}, list = tname == "WowScrollBoxList" }
end)

local COMMON_CHILDREN = {
  { "Button", "CloseButton" }, { "FontString", "TitleText" }, { "Frame", "Inset" }, { "Texture", "TitleBg" },
  { "Frame", "NineSlice" }, { "Slider", "ScrollBar" }, { "FontString", "Text" }, { "Texture", "Icon" },
  { "Texture", "IconBorder" }, { "Texture", "Left" }, { "Texture", "Middle" }, { "Texture", "Right" },
}
function M.apply_template(f, st, tname)
  local fn = TEMPLATES[tname]
  if fn then
    fn(f, st, tname)
    return
  end
  if not M.unknown_templates[tname] then
    M.unknown_templates[tname] = M.caller_where(5)
    M.warn("CreateFrame: template '" .. tname .. "' is not modelled by the mock; added generic children " ..
           "(CloseButton, TitleText, Inset, TitleBg, NineSlice, ScrollBar, Text, Icon, IconBorder, Left/Middle/Right)")
  end
  for _, c in ipairs(COMMON_CHILDREN) do
    if rawget(f, c[2]) == nil then child(f, c[1], c[2], c[2]) end
  end
  if st.kind == "Button" or st.kind == "CheckButton" then st.fontstring = rawget(f, "Text") end
end

function M.CreateFrameInternal(kind, name, parent, template)
  local f, st = M.CreateObject(kind, name, parent)
  if kind == "EditBox" then st.autofocus = true; st.text = "" end
  if kind == "Slider" or kind == "StatusBar" then st.min, st.max, st.value = 0, 0, 0 end
  if kind == "CheckButton" then st.checked = false end
  if kind == "GameTooltip" then M.init_tooltip(f, st) end
  if template then
    st.template = template
    for t in template:gmatch("[^,%s]+") do M.apply_template(f, st, t) end
  end
  return f
end

function CreateFrame(frameType, name, parent, template, id)
  if type(frameType) ~= "string" then error("CreateFrame: bad argument #1 (frameType string expected, got " .. type(frameType) .. ")", 2) end
  local kind = M.FRAME_TYPES[slower(frameType)]
  if not kind then error("CreateFrame: Unknown frame type '" .. frameType .. "'", 2) end
  if name ~= nil and type(name) ~= "string" then error("CreateFrame: bad argument #2 (name must be a string or nil)", 2) end
  if template ~= nil and type(template) ~= "string" then error("CreateFrame: bad argument #4 (template must be a string or nil)", 2) end
  if parent ~= nil and type(parent) ~= "table" and type(parent) ~= "string" then
    error("CreateFrame: bad argument #3 (parent must be a frame)", 2)
  end
  local f = M.CreateFrameInternal(kind, name, parent, template)
  if id then f:SetID(id) end
  return f
end
UIParent = CreateFrame("Frame", "UIParent")
UIParent:SetSize(1920, 1080)
WorldFrame = CreateFrame("Frame", "WorldFrame")
WorldFrame:SetSize(1920, 1080)
function DoesTemplateExist(name) return true end
function C_XMLUtil_GetTemplateInfo() return nil end
C_XMLUtil = { GetTemplateInfo = function(name) return { type = "Frame", width = 0, height = 0 } end }

---------------------------------------------------------------------------------------------------
-- GameTooltip
---------------------------------------------------------------------------------------------------
local function tt_line(self, st, i, side)
  st.lines[i] = st.lines[i] or {}
  local l = st.lines[i]
  if not l[side] then
    local name = st.name and (st.name .. "Text" .. (side == "left" and "Left" or "Right") .. i) or nil
    l[side] = Methods.Frame.CreateFontString(self, name, "ARTWORK")
  end
  return l[side]
end
local function tt_clear(self, st)
  for i, l in ipairs(st.lines) do
    if l.left then Methods.FontString.SetText(l.left, nil) end
    if l.right then Methods.FontString.SetText(l.right, nil) end
  end
  st.nlines = 0
  st.item, st.unit, st.spell = nil, nil, nil
end
local function tt_add(self, st, left, right, lr, lg, lb)
  st.nlines = st.nlines + 1
  local l = tt_line(self, st, st.nlines, "left")
  Methods.FontString.SetText(l, left)
  if lr then Methods.FontString.SetTextColor(l, lr, lg, lb) end
  if right ~= nil then Methods.FontString.SetText(tt_line(self, st, st.nlines, "right"), right) end
end
function M.init_tooltip(f, st)
  st.lines, st.nlines = {}, 0
  st.shown = false
end
local function tt_owned(self, st, method)
  if not st.owner then
    M.warn("GameTooltip:" .. method .. " called on " .. M.obj_label(self) .. " without SetOwner - ignored (as in WoW)")
    return false
  end
  return true
end
local function tt_set_item(self, st, id, link)
  local rec = M.item_rec(id)
  tt_clear(self, st)
  if not rec then return end
  st.item = link or M.item_link(id)
  local q = ITEM_QUALITY_COLORS[rec.quality] or ITEM_QUALITY_COLORS[1]
  tt_add(self, st, rec.name, nil, q.r, q.g, q.b)
  if rec.bind == 1 then tt_add(self, st, ITEM_BIND_ON_PICKUP or "Binds when picked up") end
  local loc = rec.loc
  if loc and loc ~= "" and loc ~= "INVTYPE_NON_EQUIP_IGNORE" then
    tt_add(self, st, _G[loc] or loc, M.item_subtype_name(rec.cls, rec.sub))
  end
  if rec.ilvl and rec.ilvl > 0 then tt_add(self, st, sformat(ITEM_LEVEL or "Item Level %d", rec.ilvl)) end
  call_script(self, "OnTooltipSetItem")
end
M.define("GameTooltip", "Frame", {
  SetOwner = function(self, owner, anchor, x, y)
    local st = S(self)
    st.owner, st.anchor = owner, anchor or "ANCHOR_LEFT"
    tt_clear(self, st)
  end,
  GetOwner = function(self) return S(self).owner end,
  IsOwned = function(self, f) return S(self).owner == f end,
  SetAnchorType = function(self, a) S(self).anchor = a end,
  GetAnchorType = function(self) return S(self).anchor end,
  ClearLines = function(self) local st = S(self); tt_clear(self, st); call_script(self, "OnTooltipCleared") end,
  NumLines = function(self) return S(self).nlines end,
  AddLine = function(self, text, r, g, b, wrap) local st = S(self); tt_add(self, st, M.to_text(text, "AddLine") or "", nil, r, g, b) end,
  AddDoubleLine = function(self, l, r, lr, lg, lb) local st = S(self); tt_add(self, st, M.to_text(l, "AddDoubleLine") or "", M.to_text(r, "AddDoubleLine") or "", lr, lg, lb) end,
  AppendText = function(self, text)
    local st = S(self)
    if st.nlines == 0 then tt_add(self, st, text) return end
    local l = tt_line(self, st, 1, "left")
    Methods.FontString.SetText(l, (OBJ[l].text or "") .. tostring(text))
  end,
  SetText = function(self, text, r, g, b)
    local st = S(self)
    tt_clear(self, st)
    tt_add(self, st, M.to_text(text, "SetText") or "", nil, r, g, b)
  end,
  AddTexture = function() end,
  SetItemByID = function(self, id)
    local st = S(self)
    if not tt_owned(self, st, "SetItemByID") then return end
    tt_set_item(self, st, tonumber(id))
  end,
  SetHyperlink = function(self, link)
    local st = S(self)
    if not tt_owned(self, st, "SetHyperlink") then return end
    if type(link) ~= "string" then error("GameTooltip:SetHyperlink: link string expected", 2) end
    local id = tonumber(smatch(link, "item:(%d+)"))
    if id then tt_set_item(self, st, id, sfind(link, "|H", 1, true) and link or nil); return end
    tt_clear(self, st)
    local sid = tonumber(smatch(link, "spell:(%d+)"))
    if sid then st.spell = sid; tt_add(self, st, "Spell " .. sid); call_script(self, "OnTooltipSetSpell"); return end
    tt_add(self, st, link)
  end,
  SetBagItem = function(self, bag, slot)
    local st = S(self)
    if not tt_owned(self, st, "SetBagItem") then return end
    local id = C_Container.GetContainerItemID(bag, slot)
    if id then tt_set_item(self, st, id) else tt_clear(self, st) end
    return id ~= nil
  end,
  SetInventoryItem = function(self, unit, slot)
    local st = S(self)
    if not tt_owned(self, st, "SetInventoryItem") then return end
    local id = GetInventoryItemID(unit, slot)
    if id then tt_set_item(self, st, id) else tt_clear(self, st) end
    return id ~= nil, false, 0
  end,
  SetLootItem = function(self, slot)
    local st = S(self)
    if not tt_owned(self, st, "SetLootItem") then return end
    local l = M.loot and M.loot.slots[slot]
    if l and l.itemID then tt_set_item(self, st, l.itemID) else tt_clear(self, st) end
  end,
  SetLootRollItem = function(self, rollID)
    local st = S(self)
    if not tt_owned(self, st, "SetLootRollItem") then return end
    local r = M.rolls[rollID]
    if r then tt_set_item(self, st, r.itemID) else tt_clear(self, st) end
  end,
  SetUnit = function(self, unit)
    local st = S(self)
    if not tt_owned(self, st, "SetUnit") then return end
    tt_clear(self, st)
    local name = UnitName(unit)
    if name then st.unit = unit; tt_add(self, st, name); call_script(self, "OnTooltipSetUnit") end
  end,
  SetSpellByID = function(self, id)
    local st = S(self)
    if not tt_owned(self, st, "SetSpellByID") then return end
    tt_clear(self, st)
    st.spell = id
    tt_add(self, st, "Spell " .. tostring(id))
    call_script(self, "OnTooltipSetSpell")
  end,
  GetItem = function(self)
    local st = S(self)
    if not st.item then return nil end
    local id = tonumber(smatch(st.item, "item:(%d+)"))
    local rec = id and M.item_rec(id)
    return rec and rec.name or "", st.item, id
  end,
  GetUnit = function(self) local st = S(self); if st.unit then return UnitName(st.unit), st.unit end end,
  GetSpell = function(self) local st = S(self); if st.spell then return "Spell " .. st.spell, st.spell end end,
  SetMinimumWidth = function() end,
  SetPadding = function() end,
  FadeOut = function(self) self:Hide() end,
  IsEquippedItem = function() return false end,
  SetCurrencyToken = function() end,
})
-- Hide clears the owner (WoW behaviour)
do
  local base_hide = Methods.GameTooltip.Hide
  Methods.GameTooltip.Hide = function(self)
    base_hide(self)
    S(self).owner = nil
  end
end

---------------------------------------------------------------------------------------------------
-- Pools
---------------------------------------------------------------------------------------------------
ObjectPoolMixin = {}
function ObjectPoolMixin:OnLoad(creationFunc, resetterFunc)
  self.creationFunc, self.resetterFunc = creationFunc, resetterFunc
  self.activeObjects, self.inactiveObjects, self.numActiveObjects = {}, {}, 0
end
function ObjectPoolMixin:Acquire()
  local n = #self.inactiveObjects
  if n > 0 then
    local obj = tremove(self.inactiveObjects, n)
    self.activeObjects[obj] = true
    self.numActiveObjects = self.numActiveObjects + 1
    return obj, false
  end
  local obj = self.creationFunc(self)
  if self.resetterFunc and not self.disallowResetIfNew then self.resetterFunc(self, obj, true) end
  self.activeObjects[obj] = true
  self.numActiveObjects = self.numActiveObjects + 1
  return obj, true
end
function ObjectPoolMixin:Release(obj)
  if self.activeObjects[obj] == nil then return false end
  if self.resetterFunc then self.resetterFunc(self, obj, false) end
  self.activeObjects[obj] = nil
  self.numActiveObjects = self.numActiveObjects - 1
  self.inactiveObjects[#self.inactiveObjects + 1] = obj
  return true
end
function ObjectPoolMixin:ReleaseAll()
  local list = {}
  for obj in pairs(self.activeObjects) do list[#list + 1] = obj end
  for _, obj in ipairs(list) do self:Release(obj) end
end
function ObjectPoolMixin:EnumerateActive() return pairs(self.activeObjects) end
function ObjectPoolMixin:GetNextActive(cur) return (next(self.activeObjects, cur)) end
function ObjectPoolMixin:IsActive(obj) return self.activeObjects[obj] ~= nil end
function ObjectPoolMixin:GetNumActive() return self.numActiveObjects end
function ObjectPoolMixin:EnumerateInactive() return ipairs(self.inactiveObjects) end
function ObjectPoolMixin:SetResetDisallowedIfNew(v) self.disallowResetIfNew = v end
FramePoolMixin = CreateFromMixins(ObjectPoolMixin)
function CreateObjectPool(creationFunc, resetterFunc)
  local p = CreateFromMixins(ObjectPoolMixin)
  p:OnLoad(creationFunc, resetterFunc)
  return p
end
function Pool_HideAndClearAnchors(pool, region) region:Hide(); region:ClearAllPoints() end
FramePool_HideAndClearAnchors = Pool_HideAndClearAnchors
TexturePool_HideAndClearAnchors = Pool_HideAndClearAnchors
FontStringPool_HideAndClearAnchors = Pool_HideAndClearAnchors
function CreateFramePool(frameType, parent, template, resetterFunc, forbidden, frameInitFunc)
  local p = CreateObjectPool(function()
    local f = CreateFrame(frameType, nil, parent, template)
    if frameInitFunc then frameInitFunc(f) end
    return f
  end, resetterFunc or Pool_HideAndClearAnchors)
  p.frameType, p.parent, p.frameTemplate = frameType, parent, template
  return p
end
function CreateTexturePool(parent, layer, subLayer, template, resetterFunc)
  return CreateObjectPool(function() return parent:CreateTexture(nil, layer, template, subLayer) end,
    resetterFunc or Pool_HideAndClearAnchors)
end
function CreateFontStringPool(parent, layer, subLayer, template, resetterFunc)
  return CreateObjectPool(function() return parent:CreateFontString(nil, layer, template) end,
    resetterFunc or Pool_HideAndClearAnchors)
end
function CreateFramePoolCollection()
  local c = { pools = {} }
  function c:GetOrCreatePool(frameType, parent, template, resetter, forbidden, init)
    local key = tostring(template or frameType)
    if not self.pools[key] then self.pools[key] = CreateFramePool(frameType, parent, template, resetter, forbidden, init) end
    return self.pools[key]
  end
  c.CreatePool = c.GetOrCreatePool
  function c:GetPool(template) return self.pools[tostring(template)] end
  function c:Acquire(template)
    local p = self.pools[tostring(template)]
    if not p then error("FramePoolCollection: no pool for template " .. tostring(template), 2) end
    return p:Acquire()
  end
  function c:Release(obj) for _, p in pairs(self.pools) do if p:Release(obj) then return true end end return false end
  function c:ReleaseAll() for _, p in pairs(self.pools) do p:ReleaseAll() end end
  function c:EnumerateActive()
    local list = {}
    for _, p in pairs(self.pools) do for o in p:EnumerateActive() do list[#list + 1] = o end end
    local i = 0
    return function() i = i + 1; if list[i] then return list[i], true end end
  end
  function c:GetNumActive() local n = 0 for _, p in pairs(self.pools) do n = n + p:GetNumActive() end return n end
  return c
end
CreatePoolCollection = CreateFramePoolCollection

---------------------------------------------------------------------------------------------------
-- DataProvider + ScrollBox (initializer runs for EVERY element with a real mock frame)
---------------------------------------------------------------------------------------------------
DataProviderMixin = CreateFromMixins(CallbackRegistryMixin)
DataProviderMixin.Event = { OnSizeChanged = "OnSizeChanged", OnInsert = "OnInsert", OnRemove = "OnRemove", OnSort = "OnSort", OnMove = "OnMove" }
function DataProviderMixin:Init(tbl)
  self.collection = {}
  self.callbackTables = {}
  self._listeners = {}
  if tbl then for _, v in ipairs(tbl) do self.collection[#self.collection + 1] = v end end
end
function DataProviderMixin:_changed(ev)
  if self.sortComparator and not self._sorting then self._sorting = true; tsort(self.collection, self.sortComparator); self._sorting = false end
  self:TriggerEvent(ev or "OnSizeChanged")
  for box in pairs(self._listeners) do box:_Rebuild() end
end
function DataProviderMixin:Insert(...)
  for i = 1, select("#", ...) do self.collection[#self.collection + 1] = (select(i, ...)) end
  self:_changed("OnInsert")
end
function DataProviderMixin:InsertTable(t) for _, v in ipairs(t) do self.collection[#self.collection + 1] = v end self:_changed("OnInsert") end
function DataProviderMixin:InsertTableRange(t, a, b) for i = a, b do self.collection[#self.collection + 1] = t[i] end self:_changed("OnInsert") end
function DataProviderMixin:InsertAtIndex(v, idx) tinsert(self.collection, idx, v); self:_changed("OnInsert") end
function DataProviderMixin:Remove(...)
  local last
  for i = 1, select("#", ...) do
    local v = select(i, ...)
    for j = #self.collection, 1, -1 do if self.collection[j] == v then tremove(self.collection, j); last = j end end
  end
  self:_changed("OnRemove")
  return last
end
function DataProviderMixin:RemoveIndex(i) local v = tremove(self.collection, i); self:_changed("OnRemove"); return v end
function DataProviderMixin:RemoveIndexRange(a, b) for i = b, a, -1 do tremove(self.collection, i) end self:_changed("OnRemove") end
function DataProviderMixin:RemoveByPredicate(pred)
  for j = #self.collection, 1, -1 do if pred(self.collection[j]) then tremove(self.collection, j) end end
  self:_changed("OnRemove")
end
function DataProviderMixin:Flush() self.collection = {}; self:_changed("OnSizeChanged") end
function DataProviderMixin:GetSize() return #self.collection end
function DataProviderMixin:IsEmpty() return #self.collection == 0 end
function DataProviderMixin:Enumerate(a, b)
  local i = (a or 1) - 1
  local last = b or #self.collection
  local col = self.collection
  return function() i = i + 1; if i <= last and col[i] ~= nil then return i, col[i] end end
end
function DataProviderMixin:ReverseEnumerate(a, b)
  local i = (b or #self.collection) + 1
  local first = a or 1
  local col = self.collection
  return function() i = i - 1; if i >= first and col[i] ~= nil then return i, col[i] end end
end
function DataProviderMixin:EnumerateEntireRange() return self:Enumerate() end
function DataProviderMixin:ForEach(fn) for _, v in ipairs(self.collection) do fn(v) end end
function DataProviderMixin:Find(i) return self.collection[i] end
function DataProviderMixin:FindIndex(v) for i, x in ipairs(self.collection) do if x == v then return i end end end
function DataProviderMixin:FindByPredicate(pred) for i, x in ipairs(self.collection) do if pred(x) then return i, x end end end
function DataProviderMixin:FindElementDataByPredicate(pred) local _, x = self:FindByPredicate(pred); return x end
function DataProviderMixin:FindIndexByPredicate(pred) return (self:FindByPredicate(pred)) end
function DataProviderMixin:ContainsByPredicate(pred) return self:FindByPredicate(pred) ~= nil end
function DataProviderMixin:SetSortComparator(cmp, skipSort) self.sortComparator = cmp; if not skipSort then self:Sort() end end
function DataProviderMixin:ClearSortComparator() self.sortComparator = nil end
function DataProviderMixin:HasSortComparator() return self.sortComparator ~= nil end
function DataProviderMixin:Sort() if self.sortComparator then tsort(self.collection, self.sortComparator); self:_changed("OnSort") end end
function DataProviderMixin:GetCollection() return self.collection end
function CreateDataProvider(tbl)
  local dp = CreateFromMixins(DataProviderMixin)
  dp:Init(tbl)
  return dp
end
function CreateIndexRangeDataProvider(n)
  local t = {}
  for i = 1, n do t[i] = i end
  return CreateDataProvider(t)
end

local ViewMock = {}
function ViewMock:SetElementInitializer(template, initializer)
  if type(template) == "function" and initializer == nil then template, initializer = "Frame", template end
  self.template, self.initializer = template, initializer
end
function ViewMock:SetElementFactory(fn) self.factory = fn end
function ViewMock:SetElementResetter(fn) self.resetter = fn end
function ViewMock:SetElementExtent(e) self.extent = e end
function ViewMock:GetElementExtent() return self.extent end
function ViewMock:SetElementExtentCalculator(fn) self.extentCalc = fn end
function ViewMock:SetPadding(...) self.padding = { ... } end
function ViewMock:SetPanExtent() end
function ViewMock:SetVirtualized() end
function ViewMock:SetHorizontal(v) self.horizontal = v end
function ViewMock:GetDataProvider() return self.box and self.box._dp end
function ViewMock:SetDataProvider(dp, retain) if self.box then self.box:SetDataProvider(dp, retain) end end
function ViewMock:ForEachFrame(fn) if self.box then self.box:ForEachFrame(fn) end end
function ViewMock:FindFrame(e) if self.box then return self.box:FindFrame(e) end end
function ViewMock:GetFrames() if self.box then return self.box:GetFrames() end return {} end
setmetatable(ViewMock, { __index = function(t, k) if type(k) == "string" and smatch(k, "^%u") then return NOOP end end })
function CreateScrollBoxListLinearView(top, bottom, left, right, spacing)
  local v = setmetatable({}, { __index = ViewMock })
  v.padding = { top, bottom, left, right, spacing }
  return v
end
CreateScrollBoxListGridView = function(stride, ...) local v = CreateScrollBoxListLinearView(...); v.stride = stride; return v end
CreateScrollBoxLinearView = CreateScrollBoxListLinearView

local function acquire_row(box, bst, idx, template)
  local rows = bst.frames
  local f = rows[idx]
  if f and OBJ[f].row_template ~= template then f:Hide(); f = nil end
  local new = false
  if not f then
    local kind = "Frame"
    if type(template) == "string" then
      local first = smatch(template, "^[^,%s]+")
      if first and (smatch(first, "Button") or first == "UIPanelButtonTemplate") then kind = "Button" end
    end
    f = M.CreateFrameInternal(kind, nil, rawget(box, "ScrollTarget") or box, type(template) == "string" and template or nil)
    OBJ[f].row_template = template
    rows[idx] = f
    new = true
  end
  f:Show()
  return f, new
end

M.ScrollBoxMock = {
  Init = function(self, view)
    local bst = OBJ[self].scrollbox
    bst.view = view
    view.box = self
    if self._dp then self:_Rebuild() end
  end,
  GetView = function(self) return OBJ[self].scrollbox.view end,
  SetDataProvider = function(self, dp, retain)
    if dp == nil then error("ScrollBox:SetDataProvider: dataProvider is nil", 2) end
    if self._dp and self._dp._listeners then self._dp._listeners[self] = nil end
    rawset(self, "_dp", dp)
    if dp._listeners then dp._listeners[self] = true end
    self:_Rebuild()
  end,
  GetDataProvider = function(self) return self._dp end,
  HasDataProvider = function(self) return self._dp ~= nil end,
  ClearDataProvider = function(self)
    if self._dp and self._dp._listeners then self._dp._listeners[self] = nil end
    rawset(self, "_dp", nil)
    self:_Rebuild()
  end,
  RemoveDataProvider = function(self) self:ClearDataProvider() end,
  FlushDataProvider = function(self) if self._dp then self._dp:Flush() end end,
  _Rebuild = function(self)
    local bst = OBJ[self].scrollbox
    local view = bst.view
    local dp = self._dp
    local n = 0
    if dp and view then
      if not view.initializer and not view.factory then
        error("ScrollBox: view has no element initializer/factory (call view:SetElementInitializer before SetDataProvider)", 3)
      end
      for i, elem in ipairs(dp.collection) do
        n = i
        local function make(template, init)
          local f, new = acquire_row(self, bst, i, template)
          rawset(f, "GetElementData", function() return elem end)
          rawset(f, "GetElementDataIndex", function() return i end)
          rawset(f, "GetOrderIndex", function() return i end)
          rawset(f, "ElementDataMatches", function(_, e) return e == elem end)
          if bst.acquired_cb then safecall("ScrollBox acquired callback", bst.acquired_cb, bst.acquired_owner, f, elem, new) end
          if init then safecall("ScrollBox element initializer", init, f, elem) end
        end
        if view.factory then
          safecall("ScrollBox element factory", view.factory, make, elem)
        else
          make(view.template, view.initializer)
        end
      end
    end
    for i = n + 1, #bst.frames do
      local f = bst.frames[i]
      if f then
        if view and view.resetter then safecall("ScrollBox element resetter", view.resetter, f, f.GetElementData and f:GetElementData()) end
        f:Hide()
        bst.frames[i] = nil
      end
    end
    bst.count = n
  end,
  Rebuild = function(self) self:_Rebuild() end,
  FullUpdate = function(self) self:_Rebuild() end,
  Update = function() end,
  Layout = function() end,
  ForEachFrame = function(self, fn)
    local bst = OBJ[self].scrollbox
    for i = 1, bst.count or 0 do if bst.frames[i] then fn(bst.frames[i], bst.frames[i]:GetElementData()) end end
  end,
  EnumerateFrames = function(self)
    local bst = OBJ[self].scrollbox
    local i = 0
    return function()
      i = i + 1
      if i <= (bst.count or 0) then return i, bst.frames[i] end
    end
  end,
  GetFrames = function(self)
    local bst, out = OBJ[self].scrollbox, {}
    for i = 1, bst.count or 0 do out[i] = bst.frames[i] end
    return out
  end,
  GetFrameCount = function(self) return OBJ[self].scrollbox.count or 0 end,
  FindFrame = function(self, elem)
    local bst = OBJ[self].scrollbox
    for i = 1, bst.count or 0 do local f = bst.frames[i]; if f and f:GetElementData() == elem then return f end end
  end,
  FindFrameByPredicate = function(self, pred)
    local bst = OBJ[self].scrollbox
    for i = 1, bst.count or 0 do local f = bst.frames[i]; if f and pred(f, f:GetElementData()) then return f end end
  end,
  FindElementDataByPredicate = function(self, pred) if self._dp then return self._dp:FindElementDataByPredicate(pred) end end,
  FindElementDataIndexByPredicate = function(self, pred) if self._dp then return self._dp:FindIndexByPredicate(pred) end end,
  ScrollToElementData = function() end,
  ScrollToElementDataIndex = function() end,
  ScrollToFrame = function() end,
  ScrollToEnd = function() end,
  ScrollToBegin = function() end,
  ScrollToOffset = function() end,
  SetScrollPercentage = function(self, p) OBJ[self].scrollbox.pct = p end,
  GetScrollPercentage = function(self) return OBJ[self].scrollbox.pct or 0 end,
  HasScrollableExtent = function() return false end,
  SetPanExtent = function() end,
  SetInterpolateScroll = function() end,
  SetAlignmentOverlapIgnored = function() end,
  RegisterCallback = function() end,
  UnregisterCallback = function() end,
  GetScrollTarget = function(self) return rawget(self, "ScrollTarget") end,
}
ScrollBoxListMixin = { Event = { OnScroll = "OnScroll", OnLayout = "OnLayout", OnAcquiredFrame = "OnAcquiredFrame",
  OnReleasedFrame = "OnReleasedFrame", OnDataRangeChanged = "OnDataRangeChanged", OnUpdate = "OnUpdate" } }
ScrollBoxConstants = { UpdateQueued = false, UpdateImmediately = true, NoScrollInterpolation = true, RetainScrollPosition = true,
  DiscardScrollPosition = false, AlignBegin = 0, AlignCenter = 0.5, AlignEnd = 1, AlignNearest = -1, ScrollBegin = 0, ScrollEnd = 1 }

ScrollUtil = {}
function ScrollUtil.InitScrollBoxListWithScrollBar(box, bar, view)
  if not (box and OBJ[box] and OBJ[box].scrollbox) then
    error("ScrollUtil.InitScrollBoxListWithScrollBar: box must be created from WowScrollBoxList", 2)
  end
  box:Init(view)
  OBJ[box].scrollbox.bar = bar
end
ScrollUtil.InitScrollBoxWithScrollBar = ScrollUtil.InitScrollBoxListWithScrollBar
function ScrollUtil.AddManagedScrollBarVisibilityBehavior() return { } end
function ScrollUtil.RegisterScrollBoxWithScrollBar() end
function ScrollUtil.AddResizableChildrenBehavior() end
function ScrollUtil.AddAcquiredFrameCallback(box, cb, owner, iterateExisting)
  local bst = OBJ[box].scrollbox
  bst.acquired_cb, bst.acquired_owner = cb, owner
  if iterateExisting then box:ForEachFrame(function(f, e) safecall("AcquiredFrameCallback", cb, owner, f, e, false) end) end
end
function ScrollUtil.AddReleasedFrameCallback() end
function ScrollUtil.AddInitializedFrameCallback(box, cb, owner, iterateExisting) ScrollUtil.AddAcquiredFrameCallback(box, cb, owner, iterateExisting) end
function ScrollUtil.RegisterScrollBoxSelectionBehavior() return {} end

---------------------------------------------------------------------------------------------------
-- Menus (MenuUtil / root descriptions recorded for tests)
---------------------------------------------------------------------------------------------------
M.menus = {}
local DescMethods = {}
local DESC_MT = { __index = function(t, k) local m = DescMethods[k]; if m ~= nil then return m end if type(k) == "string" and smatch(k, "^%u") then return NOOP end end }
function M.new_menu_desc(kind, text)
  return setmetatable({ kind = kind, text = text, children = {}, enabled = true }, DESC_MT)
end
local function add_child(self, d) d.parent = self; self.children[#self.children + 1] = d; return d end
function DescMethods:CreateButton(text, callback, data)
  local d = M.new_menu_desc("button", text); d.callback, d.data = callback, data; return add_child(self, d)
end
function DescMethods:CreateCheckbox(text, isSelected, setSelected, data)
  local d = M.new_menu_desc("checkbox", text); d.isSelected, d.setSelected, d.data = isSelected, setSelected, data; return add_child(self, d)
end
function DescMethods:CreateRadio(text, isSelected, setSelected, data)
  local d = M.new_menu_desc("radio", text); d.isSelected, d.setSelected, d.data = isSelected, setSelected, data; return add_child(self, d)
end
function DescMethods:CreateTitle(text) return add_child(self, M.new_menu_desc("title", text)) end
function DescMethods:CreateDivider() return add_child(self, M.new_menu_desc("divider", nil)) end
function DescMethods:CreateSpacer() return add_child(self, M.new_menu_desc("spacer", nil)) end
function DescMethods:QueueDivider() return add_child(self, M.new_menu_desc("divider", nil)) end
function DescMethods:QueueSpacer() return add_child(self, M.new_menu_desc("spacer", nil)) end
function DescMethods:CreateTemplate(template) local d = M.new_menu_desc("template", nil); d.template = template; return add_child(self, d) end
function DescMethods:CreateColorSwatch(text, callback, colorInfo) local d = M.new_menu_desc("colorswatch", text); d.callback = callback; return add_child(self, d) end
function DescMethods:Insert(d) return add_child(self, d) end
function DescMethods:SetEnabled(v) self.enabled = v end
function DescMethods:IsEnabled() if type(self.enabled) == "function" then return self.enabled(self) end return self.enabled ~= false end
function DescMethods:SetData(d) self.data = d end
function DescMethods:GetData() return self.data end
function DescMethods:SetTooltip(fn) self.tooltip = fn end
function DescMethods:SetTag(tag, ctx) self.tag = tag end
function DescMethods:GetTag() return self.tag end
function DescMethods:SetIsSelected(fn) self.isSelected = fn end
function DescMethods:SetResponse(r) self.response = r end
function DescMethods:SetResponder(fn) self.responder = fn end
function DescMethods:SetOnEnter(fn) self.onEnter = fn end
function DescMethods:SetOnLeave(fn) self.onLeave = fn end
function DescMethods:AddInitializer(fn) self.initializers = self.initializers or {}; self.initializers[#self.initializers + 1] = fn end
function DescMethods:SetTitleAndTextTooltip() end
function DescMethods:GetChildren() return self.children end
function DescMethods:HasElements() return #self.children > 0 end
function DescMethods:EnumerateElementDescriptions() return ipairs(self.children) end

function M.menu_selected_text(root)
  local found
  local function walk(d)
    for _, c in ipairs(d.children) do
      if found then return end
      if (c.kind == "radio" or c.kind == "checkbox") and c.isSelected then
        local ok, sel = safecall("menu isSelected", c.isSelected, c.data)
        if ok and sel then found = c.text; return end
      end
      walk(c)
    end
  end
  walk(root)
  return found
end

MenuResponse = { Open = 1, Refresh = 2, Close = 3, CloseAll = 4 }
MenuInputContext = { None = 1, MouseButton = 2, MouseWheel = 3 }
MenuConstants = { VerticalLinearDirection = 1, VerticalGridDirection = 2, HorizontalGridDirection = 3,
  AutoCalculateColumns = nil, ElementPollFrequencySeconds = 0.2, PrintSecure = false }
MenuUtil = {}
function MenuUtil.CreateContextMenu(owner, generator, ...)
  if type(generator) ~= "function" then error("MenuUtil.CreateContextMenu: generator function expected", 2) end
  local root = M.new_menu_desc("root", nil)
  root.owner = owner
  safecall("MenuUtil.CreateContextMenu generator", generator, owner, root, ...)
  M.last_menu = root
  M.menus[#M.menus + 1] = root
  local menu = { root = root, Close = function() root.closed = true end, IsShown = function() return not root.closed end }
  return menu
end
function MenuUtil.CreateButtonMenu(owner, ...) return MenuUtil.CreateContextMenu(owner, function(_, root, ...) for i = 1, select("#", ...) do local e = select(i, ...); root:CreateButton(e[1], e[2]) end end, ...) end
function MenuUtil.CreateCheckboxContextMenu(owner, isSelected, setSelected, ...)
  return MenuUtil.CreateContextMenu(owner, function(_, root, ...) for i = 1, select("#", ...) do local e = select(i, ...); root:CreateCheckbox(e[1], isSelected, setSelected, e[2]) end end, ...)
end
function MenuUtil.CreateRadioContextMenu(owner, isSelected, setSelected, ...)
  return MenuUtil.CreateContextMenu(owner, function(_, root, ...) for i = 1, select("#", ...) do local e = select(i, ...); root:CreateRadio(e[1], isSelected, setSelected, e[2]) end end, ...)
end
function MenuUtil.GetElementText(desc) return desc.text end
function MenuUtil.SetElementText(desc, text) desc.text = text end
function MenuUtil.ShowTooltip() end
function MenuUtil.HideTooltip() end
function MenuUtil.HookTooltipScripts() end
function MenuUtil.CreateRootMenuDescription() return M.new_menu_desc("root", nil) end
Menu = { ModifyMenu = function(tag, fn) M.menu_modifiers = M.menu_modifiers or {}; M.menu_modifiers[tag] = fn end,
  GetManager = function() return nil end, PopulateDescription = function() end }

---------------------------------------------------------------------------------------------------
-- Settings (modern options UI)
---------------------------------------------------------------------------------------------------
M.settings_categories = {}
M.settings_values = {}
local next_cat_id = 100
local CategoryMethods = {}
local CAT_MT = { __index = function(t, k) local m = CategoryMethods[k]; if m ~= nil then return m end if type(k) == "string" and smatch(k, "^%u") then return NOOP end end }
function CategoryMethods:GetID() return self.ID end
function CategoryMethods:GetName() return self.name end
function CategoryMethods:SetName(n) self.name = n end
function CategoryMethods:GetParentCategory() return self.parent end
function CategoryMethods:GetSubcategories() return self.subcategories end
function CategoryMethods:HasSubcategories() return #self.subcategories > 0 end
function CategoryMethods:SetExpanded(v) self.expanded = v end
function CategoryMethods:GetLayout() return self.layout end
local function new_category(name, frame, parent)
  next_cat_id = next_cat_id + 1
  local c = setmetatable({ ID = next_cat_id, name = name, frame = frame, parent = parent, subcategories = {} }, CAT_MT)
  c.layout = setmetatable({ frame = frame, initializers = {} }, { __index = function(t, k)
    if k == "AddInitializer" then return function(self, i) self.initializers[#self.initializers + 1] = i end end
    if type(k) == "string" and smatch(k, "^%u") then return NOOP end end })
  M.settings_categories[#M.settings_categories + 1] = c
  if parent then parent.subcategories[#parent.subcategories + 1] = c end
  if frame and OBJ[frame] then
    rawset(frame, "name", rawget(frame, "name") or name)
  end
  return c
end
local SettingMethods = {}
local SETTING_MT = { __index = function(t, k) local m = SettingMethods[k]; if m ~= nil then return m end if type(k) == "string" and smatch(k, "^%u") then return NOOP end end }
function SettingMethods:GetValue()
  if self.getter then return self.getter() end
  if self.tbl then local v = self.tbl[self.key]; if v == nil then return self.default end return v end
  return M.settings_values[self.variable]
end
function SettingMethods:SetValue(v)
  if self.setter then self.setter(v)
  elseif self.tbl then self.tbl[self.key] = v
  else M.settings_values[self.variable] = v end
  for _, cb in ipairs(self.callbacks) do safecall("Setting value changed " .. tostring(self.variable), cb.fn, cb.owner, self, v) end
end
function SettingMethods:GetVariable() return self.variable end
function SettingMethods:GetName() return self.name end
function SettingMethods:GetDefaultValue() return self.default end
function SettingMethods:GetVariableType() return self.vartype end
function SettingMethods:SetValueChangedCallback(fn, owner) self.callbacks[#self.callbacks + 1] = { fn = fn, owner = owner } end
local function new_setting(t)
  t.callbacks = {}
  M.settings_by_var = M.settings_by_var or {}
  M.settings_by_var[t.variable] = t
  return setmetatable(t, SETTING_MT)
end
local function initializer() return setmetatable({}, { __index = function(t, k) if type(k) == "string" and smatch(k, "^%u") then return NOOP end end }) end
Settings = {
  VarType = { Boolean = "boolean", Number = "number", String = "string" },
  Default = { True = true, False = false },
  RegisterCanvasLayoutCategory = function(frame, name, group)
    if frame == nil or not OBJ[frame] then error("Settings.RegisterCanvasLayoutCategory: frame expected", 2) end
    local c = new_category(name, frame)
    return c, c.layout
  end,
  RegisterCanvasLayoutSubcategory = function(parent, frame, name)
    local c = new_category(name, frame, parent)
    return c, c.layout
  end,
  RegisterVerticalLayoutCategory = function(name) local c = new_category(name, nil); return c, c.layout end,
  RegisterVerticalLayoutSubcategory = function(parent, name) local c = new_category(name, nil, parent); return c, c.layout end,
  RegisterAddOnCategory = function(cat) cat.registered = true end,
  GetCategory = function(id) for _, c in ipairs(M.settings_categories) do if c.ID == id or c.name == id then return c end end end,
  OpenToCategory = function(id)
    local cat
    for _, c in ipairs(M.settings_categories) do if c.ID == id or c.name == id or c == id then cat = c end end
    M.settings_opened = cat and cat.ID or id
    if not cat then M.warn("Settings.OpenToCategory: unknown category " .. tostring(id)); return false end
    if SettingsPanel then SettingsPanel:Show() end
    if cat.frame and OBJ[cat.frame] then cat.frame:Show() end
    return true
  end,
  RegisterAddOnSetting = function(category, variable, variableKey, variableTbl, varType, name, default)
    if type(variableTbl) ~= "table" then error("Settings.RegisterAddOnSetting: variableTbl must be a table", 2) end
    return new_setting({ category = category, variable = variable, key = variableKey, tbl = variableTbl, vartype = varType, name = name, default = default })
  end,
  RegisterProxySetting = function(category, variable, varType, name, default, getter, setter)
    return new_setting({ category = category, variable = variable, vartype = varType, name = name, default = default, getter = getter, setter = setter })
  end,
  CreateCheckbox = function() return initializer() end,
  CreateCheckBox = function() return initializer() end,
  CreateSlider = function() return initializer() end,
  CreateDropdown = function() return initializer() end,
  CreateDropDown = function() return initializer() end,
  CreateControlTextContainer = function()
    local c = { data = {} }
    function c:Add(value, label, tooltip) self.data[#self.data + 1] = { value = value, label = label, tooltip = tooltip } end
    function c:GetData() return self.data end
    return c
  end,
  CreateSliderOptions = function(min, max, step)
    local o = { min = min, max = max, steps = step }
    function o:SetLabelFormatter() end
    return o
  end,
  CreateElementInitializer = function() return initializer() end,
  CreateSettingInitializer = function() return initializer() end,
  CreatePanelInitializer = function() return initializer() end,
  SetValue = function(var, v) local s = M.settings_by_var and M.settings_by_var[var]; if s then s:SetValue(v) else M.settings_values[var] = v end end,
  GetValue = function(var) local s = M.settings_by_var and M.settings_by_var[var]; if s then return s:GetValue() end return M.settings_values[var] end,
  GetSetting = function(var) return M.settings_by_var and M.settings_by_var[var] end,
  SetOnValueChangedCallback = function(var, fn, owner) local s = M.settings_by_var and M.settings_by_var[var]; if s then s:SetValueChangedCallback(fn, owner) end end,
  NotifyUpdate = function() end,
  AssignLayoutToCategory = function() end,
  CreateCheckboxWithOptions = function() return initializer() end,
}
SettingsPanel = CreateFrame("Frame", "SettingsPanel", UIParent)
SettingsPanel:Hide()
rawset(SettingsPanel, "Open", function(self) self:Show() end)
rawset(SettingsPanel, "Close", function(self) self:Hide() end)
rawset(SettingsPanel, "OpenToCategory", function(self, id) return Settings.OpenToCategory(id) end)

---------------------------------------------------------------------------------------------------
-- StaticPopups
---------------------------------------------------------------------------------------------------
StaticPopupDialogs = {}
STATICPOPUP_NUMDIALOGS = 4
M.popup_frames = {}
local function popup_frame(i)
  local f = M.popup_frames[i]
  if f then return f end
  f = CreateFrame("Frame", "StaticPopup" .. i, UIParent)
  f:Hide()
  local text = f:CreateFontString("StaticPopup" .. i .. "Text", "ARTWORK")
  rawset(f, "text", text)
  rawset(f, "Text", text)
  local eb = CreateFrame("EditBox", "StaticPopup" .. i .. "EditBox", f)
  OBJ[eb].autofocus = false
  rawset(f, "editBox", eb)
  rawset(f, "EditBox", eb)
  for b = 1, 4 do
    local btn = CreateFrame("Button", "StaticPopup" .. i .. "Button" .. b, f, "UIPanelButtonTemplate")
    rawset(f, "button" .. b, btn)
  end
  rawset(f, "GetEditBox", function(self) return eb end)
  rawset(f, "GetButton1", function(self) return rawget(self, "button1") end)
  rawset(f, "GetButton2", function(self) return rawget(self, "button2") end)
  rawset(f, "GetTextFontString", function(self) return text end)
  M.popup_frames[i] = f
  return f
end
function StaticPopup_Show(which, text1, text2, data, insertedFrame)
  local info = StaticPopupDialogs[which]
  if not info then
    M.warn("StaticPopup_Show('" .. tostring(which) .. "'): no such StaticPopupDialogs entry (returns nil, like WoW)")
    return nil
  end
  local dialog
  for i = 1, STATICPOPUP_NUMDIALOGS do
    local f = popup_frame(i)
    if f:IsShown() and f.which == which and (not info.multiple or f.data == data) then dialog = f; break end
  end
  if dialog then
    -- Like classic_anniversary StaticPopup_Show: a visible dialog of the same kind is reused after its
    -- OnCancel(dialog, data, "override") (unless noCancelOnReuse).
    dialog:Hide()
    if not info.noCancelOnReuse and info.OnCancel then
      safecall("StaticPopup " .. which .. " OnCancel", info.OnCancel, dialog, dialog.data, "override")
    end
  else
    for i = 1, STATICPOPUP_NUMDIALOGS do
      local f = popup_frame(i)
      if not f:IsShown() then dialog = f; break end
    end
  end
  if not dialog then
    -- All four frames busy: WoW calls OnCancel(nil, data) (reason nil) and shows nothing.
    M.warn("StaticPopup_Show: all dialogs busy")
    if info.OnCancel then safecall("StaticPopup " .. which .. " OnCancel", info.OnCancel, nil, data) end
    return nil
  end
  rawset(dialog, "which", which)
  rawset(dialog, "data", data)
  rawset(dialog, "data2", nil)
  local txt = info.text or ""
  local ok, formatted = pcall(sformat, txt, text1, text2)
  dialog.text:SetText(ok and formatted or txt)
  if info.hasEditBox then dialog.editBox:Show(); dialog.editBox:SetText("") else dialog.editBox:Hide() end
  if info.button1 then dialog.button1:SetText(info.button1) end
  if info.button2 then dialog.button2:SetText(info.button2) end
  dialog:Show()
  if info.OnShow then safecall("StaticPopup " .. which .. " OnShow", info.OnShow, dialog, data) end
  M.popup_log = M.popup_log or {}
  M.popup_log[#M.popup_log + 1] = { which = which, text = dialog.text:GetText(), data = data }
  return dialog
end
function StaticPopup_Hide(which, data)
  for i = 1, STATICPOPUP_NUMDIALOGS do
    local f = M.popup_frames[i]
    if f and f:IsShown() and f.which == which and (data == nil or f.data == data) then
      f:Hide()
      local info = StaticPopupDialogs[which]
      if info and info.OnHide then safecall("StaticPopup " .. which .. " OnHide", info.OnHide, f, f.data) end
    end
  end
end
function StaticPopup_Visible(which)
  for i = 1, STATICPOPUP_NUMDIALOGS do
    local f = M.popup_frames[i]
    if f and f:IsShown() and f.which == which then return f:GetName(), f end
  end
  return nil
end
function StaticPopup_FindVisible(which, data)
  for i = 1, STATICPOPUP_NUMDIALOGS do
    local f = M.popup_frames[i]
    if f and f:IsShown() and f.which == which and (data == nil or f.data == data) then return f end
  end
end
function StaticPopup_HideAll() for i = 1, STATICPOPUP_NUMDIALOGS do local f = M.popup_frames[i]; if f then f:Hide() end end end
function StaticPopup_OnClick(dialog, index)
  local info = StaticPopupDialogs[dialog.which]
  if not info then return end
  local keep
  if index == 1 and info.OnAccept then
    local ok, r = safecall("StaticPopup " .. dialog.which .. " OnAccept", info.OnAccept, dialog, dialog.data, dialog.data2)
    keep = ok and r
  elseif index == 2 and info.OnCancel then
    local ok, r = safecall("StaticPopup " .. dialog.which .. " OnCancel", info.OnCancel, dialog, dialog.data, "clicked")
    keep = ok and r
  elseif index == 3 and info.OnAlt then
    safecall("StaticPopup " .. dialog.which .. " OnAlt", info.OnAlt, dialog, dialog.data, "clicked")
  end
  if not keep and dialog:IsShown() then
    dialog:Hide()
    if info.OnHide then safecall("StaticPopup " .. dialog.which .. " OnHide", info.OnHide, dialog, dialog.data) end
  end
end
-- Port of classic_anniversary Blizzard_StaticPopup/StaticPopup.lua StaticPopup_EscapePressed (called first by
-- ToggleGameMenu, i.e. by every Escape press): every shown hideOnEscape dialog gets OnCancel(dialog, data,
-- "clicked") unless noCancelOnEscape, then hides. Returns 1 if a dialog was closed.
function StaticPopup_EscapePressed()
  local closed
  for i = STATICPOPUP_NUMDIALOGS, 1, -1 do
    local dialog = M.popup_frames[i]
    if dialog and dialog:IsShown() then
      local info = StaticPopupDialogs[dialog.which]
      if info and info.hideOnEscape then
        if info.OnCancel and not info.noCancelOnEscape then
          safecall("StaticPopup " .. dialog.which .. " OnCancel", info.OnCancel, dialog, dialog.data, "clicked")
        end
        dialog:Hide()
        if info.OnHide then safecall("StaticPopup " .. dialog.which .. " OnHide", info.OnHide, dialog, dialog.data) end
        closed = 1
      end
    end
  end
  return closed
end
function M.popup_escape() return StaticPopup_EscapePressed() and true or false end

function M.popup_act(which, index, text)
  local f = StaticPopup_FindVisible(which)
  if not f then return false end
  if text ~= nil then f.editBox:SetText(text) end
  StaticPopup_OnClick(f, index)
  return true
end

---------------------------------------------------------------------------------------------------
-- Blizzard frames / helpers
---------------------------------------------------------------------------------------------------
M.printed = {}
M.chat_lines = {}
M.ui_errors = {}
M.raid_notices = {}
M.sounds = {}
M.inserted_links = {}

local function chat_capture(text) M.chat_lines[#M.chat_lines + 1] = text end
for i = 1, 3 do
  local cf = CreateFrame("ScrollingMessageFrame", "ChatFrame" .. i, UIParent)
  if i == 1 then OBJ[cf].capture = chat_capture end
  local eb = CreateFrame("EditBox", "ChatFrame" .. i .. "EditBox", UIParent)
  OBJ[eb].autofocus = false
  eb:Hide()
  rawset(cf, "editBox", eb)
end
DEFAULT_CHAT_FRAME = ChatFrame1
SELECTED_CHAT_FRAME = ChatFrame1
NUM_CHAT_WINDOWS = 10
function print(...)
  local n = select("#", ...)
  local t = {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  local line = tconcat(t, " ")
  M.printed[#M.printed + 1] = line
  DEFAULT_CHAT_FRAME:AddMessage(line)
end
function setprinthandler() end
function getprinthandler() return print end
UIErrorsFrame = CreateFrame("MessageFrame", "UIErrorsFrame", UIParent)
OBJ[UIErrorsFrame].capture = function(text) M.ui_errors[#M.ui_errors + 1] = text end
RaidWarningFrame = CreateFrame("MessageFrame", "RaidWarningFrame", UIParent)
RaidBossEmoteFrame = CreateFrame("MessageFrame", "RaidBossEmoteFrame", UIParent)
function RaidNotice_AddMessage(frame, text, colorInfo, displayTime)
  M.raid_notices[#M.raid_notices + 1] = tostring(text)
end
function RaidNotice_Clear() end

M.chat_filters = {}
function ChatFrame_AddMessageEventFilter(event, fn)
  M.chat_filters[event] = M.chat_filters[event] or {}
  tinsert(M.chat_filters[event], fn)
end
function ChatFrame_RemoveMessageEventFilter(event, fn)
  local l = M.chat_filters[event]
  if l then for i = #l, 1, -1 do if l[i] == fn then tremove(l, i) end end end
end
function ChatFrame_GetMessageEventFilters(event) return M.chat_filters[event] end
function ChatEdit_InsertLink(link) M.inserted_links[#M.inserted_links + 1] = link; return false end
function ChatEdit_GetActiveWindow() return nil end
function ChatEdit_ActivateChat() end
function ChatFrame_OpenChat(text, chatFrame) M.opened_chat = text end
ChatFrameUtil = {
  InsertLink = function(link) M.inserted_links[#M.inserted_links + 1] = link; return false end,
  GetActiveWindow = function() return nil end,
  AddMessageEventFilter = ChatFrame_AddMessageEventFilter,
  RemoveMessageEventFilter = ChatFrame_RemoveMessageEventFilter,
  DisplayTimePlayed = function() end,
}

GameTooltip = CreateFrame("GameTooltip", "GameTooltip", UIParent, "GameTooltipTemplate")
ItemRefTooltip = CreateFrame("GameTooltip", "ItemRefTooltip", UIParent, "GameTooltipTemplate")
ShoppingTooltip1 = CreateFrame("GameTooltip", "ShoppingTooltip1", UIParent, "GameTooltipTemplate")
ShoppingTooltip2 = CreateFrame("GameTooltip", "ShoppingTooltip2", UIParent, "GameTooltipTemplate")
ItemRefShoppingTooltip1 = CreateFrame("GameTooltip", "ItemRefShoppingTooltip1", UIParent, "GameTooltipTemplate")
ItemRefShoppingTooltip2 = CreateFrame("GameTooltip", "ItemRefShoppingTooltip2", UIParent, "GameTooltipTemplate")
rawset(GameTooltip, "shoppingTooltips", { ShoppingTooltip1, ShoppingTooltip2 })
rawset(ItemRefTooltip, "shoppingTooltips", { ItemRefShoppingTooltip1, ItemRefShoppingTooltip2 })
function GameTooltip_Hide() GameTooltip:Hide() end
function GameTooltip_SetDefaultAnchor(tt, parent) tt:SetOwner(parent, "ANCHOR_NONE") end
function GameTooltip_AddNormalLine(tt, text, wrap) tt:AddLine(text, 1, 0.82, 0, wrap) end
function GameTooltip_AddHighlightLine(tt, text, wrap) tt:AddLine(text, 1, 1, 1, wrap) end
function GameTooltip_AddColoredLine(tt, text, color, wrap) tt:AddLine(text, color.r, color.g, color.b, wrap) end
function GameTooltip_AddBlankLineToTooltip(tt) tt:AddLine(" ") end
function GameTooltip_SetTitle(tt, text) tt:SetText(text) end
function GameTooltip_ShowCompareItem() end
function GameTooltip_OnHide() end

Minimap = CreateFrame("Minimap", "Minimap", UIParent)
Minimap:SetSize(140, 140)
MinimapCluster = CreateFrame("Frame", "MinimapCluster", UIParent)
MinimapBackdrop = CreateFrame("Frame", "MinimapBackdrop", Minimap)
-- GetMinimapShape is not defined by the default UI (minimap addons define it); LibDBIcon falls back to ROUND
GameMenuFrame = CreateFrame("Frame", "GameMenuFrame", UIParent)
GameMenuFrame:Hide()
UISpecialFrames = {}
UIPanelWindows = {}
function ShowUIPanel(f) if f then f:Show() end end
function HideUIPanel(f) if f then f:Hide() end end
function ToggleFrame(f) if f:IsShown() then f:Hide() else f:Show() end end
function CloseSpecialWindows()
  local any = false
  for _, name in ipairs(UISpecialFrames) do
    local f = _G[name]
    if f and f:IsShown() then f:Hide(); any = true end
  end
  return any
end
function AnimateTexCoords(texture, textureWidth, textureHeight, frameWidth, frameHeight, numFrames, elapsed, throttle) end
function SetPortraitTexture() end
function SetPortraitToTexture() end
function EditBox_ClearFocus(eb) eb:ClearFocus() end
function EditBox_HighlightText(eb) eb:HighlightText() end
function EditBox_ClearHighlight(eb) eb:HighlightText(0, 0) end
function FauxScrollFrame_GetOffset(frame) return rawget(frame, "offset") or 0 end
function FauxScrollFrame_SetOffset(frame, off) rawset(frame, "offset", off) end
function FauxScrollFrame_Update(frame, numItems, numToDisplay, buttonHeight)
  local show = numItems > numToDisplay
  local sb = rawget(frame, "ScrollBar")
  if show then frame:Show() end
  if (rawget(frame, "offset") or 0) > math.max(0, numItems - numToDisplay) then rawset(frame, "offset", math.max(0, numItems - numToDisplay)) end
  return show
end
function FauxScrollFrame_OnVerticalScroll(self, value, itemHeight, updateFunction)
  rawset(self, "offset", math.floor(value / itemHeight + 0.5))
  if updateFunction then updateFunction(self) end
end
function SetItemButtonTexture(button, tex) local ic = rawget(button, "icon") or rawget(button, "Icon"); if ic then ic:SetTexture(tex) end; OBJ[button].item_texture = tex end
function SetItemButtonCount(button, count) OBJ[button].item_count = count; local c = rawget(button, "Count"); if c then c:SetText((count and count > 1) and count or "") end end
function SetItemButtonStock() end
function SetItemButtonQuality(button, quality, link) OBJ[button].item_quality = quality end
function SetItemButtonDesaturated(button, v) OBJ[button].item_desat = v end
function SetItemButtonTextureVertexColor() end
function SetItemButtonNormalTextureVertexColor() end
function SetItemButtonNameFrameVertexColor() end
function SetItemButtonSlotVertexColor() end
function ClearItemButtonOverlay() end
function PlaySound(id, channel) M.sounds[#M.sounds + 1] = id; return true, 1 end
function PlaySoundFile(f) M.sounds[#M.sounds + 1] = f; return true, 1 end
function StopSound() end
function PlayMusic(f) M.music = f; return true end
function StopMusic() M.music = nil end
function FlashClientIcon() end
SOUNDKIT = setmetatable({ IG_MAINMENU_OPEN = 850, IG_MAINMENU_CLOSE = 851, IG_CHARACTER_INFO_TAB = 841,
  U_CHAT_SCROLL_BUTTON = 1115, IG_CHARACTER_INFO_OPEN = 839, IG_CHARACTER_INFO_CLOSE = 840, RAID_WARNING = 8959,
  READY_CHECK = 8960, TELL_MESSAGE = 3081, IG_QUEST_LIST_OPEN = 875, IG_QUEST_LIST_CLOSE = 876, UI_EPICLOOT_TOAST = 31578,
  IG_BACKPACK_OPEN = 862, IG_BACKPACK_CLOSE = 863, LOOT_WINDOW_COIN_SOUND = 120, AUCTION_WINDOW_OPEN = 5274 },
  { __index = function(t, k)
    local v = 100000 + (#(rawget(t, "__auto") or {}))
    M.warn("SOUNDKIT." .. tostring(k) .. " is not a known sound kit (auto-numbered)")
    rawset(t, k, v)
    return v
  end })

-- PanelTemplates (tab bookkeeping that addons read back)
function PanelTemplates_SetNumTabs(frame, n) rawset(frame, "numTabs", n) end
function PanelTemplates_SetTab(frame, id) rawset(frame, "selectedTab", id) end
function PanelTemplates_GetSelectedTab(frame) return rawget(frame, "selectedTab") end
function PanelTemplates_UpdateTabs(frame) end
function PanelTemplates_TabResize() end
function PanelTemplates_SelectTab(tab) OBJ[tab].tab_selected = true end
function PanelTemplates_DeselectTab(tab) OBJ[tab].tab_selected = false end
function PanelTemplates_EnableTab() end
function PanelTemplates_DisableTab() end
function PanelTemplates_ResizeTabsToFit() end
function PanelTemplates_HideTab(frame, i) end
function PanelTemplates_ShowTab(frame, i) end

-- UIDropDownMenu (legacy; still shipped in classic clients)
M.dropdown_buttons = {}
function UIDropDownMenu_CreateInfo() return {} end
function UIDropDownMenu_Initialize(frame, initFunc, displayMode, level, menuList)
  rawset(frame, "initialize", initFunc)
  rawset(frame, "displayMode", displayMode)
  if initFunc then
    M.dropdown_buttons = {}
    safecall("UIDropDownMenu_Initialize", initFunc, frame, level or 1, menuList)
  end
end
function UIDropDownMenu_AddButton(info, level) M.dropdown_buttons[#M.dropdown_buttons + 1] = info end
function UIDropDownMenu_SetText(frame, text) rawset(frame, "__dd_text", text); local t = rawget(frame, "Text"); if t then t:SetText(text) end end
function UIDropDownMenu_GetText(frame) return rawget(frame, "__dd_text") end
function UIDropDownMenu_SetSelectedValue(frame, v) rawset(frame, "selectedValue", v) end
function UIDropDownMenu_GetSelectedValue(frame) return rawget(frame, "selectedValue") end
function UIDropDownMenu_SetSelectedID(frame, v) rawset(frame, "selectedID", v) end
function UIDropDownMenu_GetSelectedID(frame) return rawget(frame, "selectedID") end
function UIDropDownMenu_SetSelectedName(frame, v) rawset(frame, "selectedName", v) end
function ToggleDropDownMenu() end
function CloseDropDownMenus() end
UIDROPDOWNMENU_MENU_LEVEL = 1
UIDROPDOWNMENU_MENU_VALUE = nil
UIDROPDOWNMENU_OPEN_MENU = nil

-- Loot frames (Blizzard LootFrame registered BEFORE addon frames, like the real UI)
LOOTFRAME_NUMBUTTONS = 4
LootFrame = CreateFrame("Frame", "LootFrame", UIParent)
LootFrame:Hide()
rawset(LootFrame, "page", 1)
for i = 1, LOOTFRAME_NUMBUTTONS do
  local b = CreateFrame("Button", "LootButton" .. i, LootFrame, "LootButtonTemplate")
  b:SetID(i)
  rawset(b, "slot", nil)
end
function LootFrame_UpdateButton(index)
  local button = _G["LootButton" .. index]
  local slot = button and rawget(button, "slot")
  if not slot then return end
  local texture, name, quantity, currencyID, quality = GetLootSlotInfo(slot)
  if texture then
    SetItemButtonTexture(button, texture)
    local t = rawget(button, "Text")
    if t then t:SetText(name) end
    SetItemButtonCount(button, quantity)
    rawset(button, "quality", quality)
  end
end
function LootFrame_Update()
  local num = GetNumLootItems()
  local page = rawget(LootFrame, "page") or 1
  for index = 1, LOOTFRAME_NUMBUTTONS do
    local button = _G["LootButton" .. index]
    local slot = (LOOTFRAME_NUMBUTTONS * (page - 1)) + index
    if slot <= num and (LootSlotHasItem(slot) or GetLootSlotType(slot) ~= 0) then
      rawset(button, "slot", slot)
      button:Show()
      LootFrame_UpdateButton(index)
    else
      rawset(button, "slot", nil)
      button:Hide()
    end
  end
end
function LootFrame_Show(self) self:Show(); LootFrame_Update() end
function LootFrame_OnEvent(self, event, ...)
  if event == "LOOT_OPENED" then
    rawset(self, "page", 1)
    LootFrame_Show(self)
  elseif event == "LOOT_SLOT_CLEARED" then
    if self:IsShown() then LootFrame_Update() end
  elseif event == "LOOT_CLOSED" then
    self:Hide()
  end
end
LootFrame:RegisterEvent("LOOT_OPENED")
LootFrame:RegisterEvent("LOOT_SLOT_CLEARED")
LootFrame:RegisterEvent("LOOT_CLOSED")
LootFrame:SetScript("OnEvent", function(self, ...) LootFrame_OnEvent(self, ...) end)

NUM_GROUP_LOOT_FRAMES = 4
for i = 1, NUM_GROUP_LOOT_FRAMES do
  local f = CreateFrame("Frame", "GroupLootFrame" .. i, UIParent)
  f:Hide()
  local iconFrame = CreateFrame("Button", "GroupLootFrame" .. i .. "IconFrame", f)
  rawset(f, "IconFrame", iconFrame)
  rawset(iconFrame, "Icon", iconFrame:CreateTexture("GroupLootFrame" .. i .. "IconFrameIcon"))
  rawset(f, "Name", f:CreateFontString("GroupLootFrame" .. i .. "Name"))
  rawset(f, "Timer", CreateFrame("StatusBar", "GroupLootFrame" .. i .. "Timer", f))
  for _, b in ipairs({ "NeedButton", "GreedButton", "PassButton", "DisenchantButton" }) do
    rawset(f, b, CreateFrame("Button", "GroupLootFrame" .. i .. b, f))
  end
end
function GroupLootFrame_OpenNewFrame(rollID, rollTime)
  for i = 1, NUM_GROUP_LOOT_FRAMES do
    local f = _G["GroupLootFrame" .. i]
    if not f:IsShown() then
      rawset(f, "rollID", rollID)
      rawset(f, "rollTime", rollTime)
      local _, name = GetLootRollItemInfo(rollID)
      f.Name:SetText(name)
      f:Show()
      return f
    end
  end
end
local glf_events = CreateFrame("Frame")
glf_events:RegisterEvent("START_LOOT_ROLL")
glf_events:RegisterEvent("CANCEL_LOOT_ROLL")
glf_events:SetScript("OnEvent", function(self, event, rollID, rollTime)
  if event == "START_LOOT_ROLL" then
    GroupLootFrame_OpenNewFrame(rollID, rollTime)
  else
    for i = 1, NUM_GROUP_LOOT_FRAMES do
      local f = _G["GroupLootFrame" .. i]
      if f:IsShown() and rawget(f, "rollID") == rollID then f:Hide() end
    end
  end
end)

-- Character frame / paper doll (for addons that decorate the default paper doll)
CharacterFrame = CreateFrame("Frame", "CharacterFrame", UIParent, "ButtonFrameTemplate")
CharacterFrame:Hide()
PaperDollFrame = CreateFrame("Frame", "PaperDollFrame", CharacterFrame)
PaperDollItemsFrame = CreateFrame("Frame", "PaperDollItemsFrame", PaperDollFrame)
M.PAPERDOLL_SLOTS = { "HeadSlot", "NeckSlot", "ShoulderSlot", "BackSlot", "ChestSlot", "ShirtSlot", "TabardSlot",
  "WristSlot", "HandsSlot", "WaistSlot", "LegsSlot", "FeetSlot", "Finger0Slot", "Finger1Slot", "Trinket0Slot",
  "Trinket1Slot", "MainHandSlot", "SecondaryHandSlot", "RangedSlot", "AmmoSlot" }
function PaperDollItemSlotButton_Update(button) end
function ToggleCharacter(tab)
  if CharacterFrame:IsShown() then CharacterFrame:Hide() else CharacterFrame:Show() end
end
function M.create_paperdoll_slots()
  for _, s in ipairs(M.PAPERDOLL_SLOTS) do
    local b = CreateFrame("Button", "Character" .. s, PaperDollItemsFrame, "PaperDollItemSlotButtonTemplate")
    b:SetID((GetInventorySlotInfo(s)))
  end
end

InterfaceOptionsFramePanelContainer = nil
AddonCompartmentFrame = nil
