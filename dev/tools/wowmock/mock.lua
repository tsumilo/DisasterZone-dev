-- wowmock/mock.lua : entry point of the Lua side of the mock WoW client (plain Lua 5.1).
-- Python (tools/harness.py) runs this chunk in a fresh lupa LuaRuntime per simulated player:
--     M = chunk(cfg, PY, sources)
-- cfg     identity + flags (name, realm, class_file, level, guid, talents, legacy_globals, ...)
-- PY      Python callbacks (send_addon, send_chat, set_guild_info_text, set_note, give_master_loot, item_lookup)
-- sources { ["core.lua"] = src, ... } module sources
-- M is the private control table (also exposed as the global __MOCK for debugging).
local cfg, PY, sources = ...
local M = { legacy = {} }
local sformat, smatch, slower, ssub, sgsub = string.format, string.match, string.lower, string.sub, string.gsub

M.onupdate_hidden = cfg.onupdate_hidden and true or false
M.permissive_fields = cfg.permissive_fields and true or false

local function load_module(name)
  local src = sources[name]
  if not src then error("wowmock: missing module source " .. name) end
  local f, err = loadstring(src, "@wowmock/" .. name)
  if not f then error(err) end
  f(M, cfg, PY)
end
load_module("core.lua")
for _, e in ipairs(cfg.known_events or {}) do M.known_events[e] = true end
for e in ([[ADDON_LOADED VARIABLES_LOADED PLAYER_LOGIN PLAYER_LOGOUT PLAYER_ENTERING_WORLD PLAYER_LEAVING_WORLD
  CHAT_MSG_ADDON CHAT_MSG_ADDON_LOGGED CHAT_MSG_SYSTEM CHAT_MSG_LOOT CHAT_MSG_RAID CHAT_MSG_RAID_LEADER CHAT_MSG_RAID_WARNING
  CHAT_MSG_PARTY CHAT_MSG_PARTY_LEADER CHAT_MSG_GUILD CHAT_MSG_OFFICER CHAT_MSG_SAY CHAT_MSG_YELL CHAT_MSG_WHISPER
  CHAT_MSG_WHISPER_INFORM CHAT_MSG_EMOTE GUILD_ROSTER_UPDATE PLAYER_GUILD_UPDATE GROUP_ROSTER_UPDATE PARTY_LOOT_METHOD_CHANGED
  PARTY_LEADER_CHANGED LOOT_READY LOOT_OPENED LOOT_CLOSED LOOT_SLOT_CLEARED START_LOOT_ROLL CANCEL_LOOT_ROLL
  GET_ITEM_INFO_RECEIVED ITEM_DATA_LOAD_RESULT PLAYER_EQUIPMENT_CHANGED UNIT_INVENTORY_CHANGED BAG_UPDATE BAG_UPDATE_DELAYED
  BANKFRAME_OPENED BANKFRAME_CLOSED PLAYERBANKSLOTS_CHANGED PLAYER_REGEN_DISABLED PLAYER_REGEN_ENABLED ENCOUNTER_START
  ENCOUNTER_END BOSS_KILL ZONE_CHANGED_NEW_AREA COMBAT_LOG_EVENT_UNFILTERED PLAYER_TARGET_CHANGED MODIFIER_STATE_CHANGED
  UPDATE_INSTANCE_INFO SPELLS_CHANGED INSPECT_READY OPEN_MASTER_LOOT_LIST UPDATE_MASTER_LOOT_LIST CONFIRM_LOOT_ROLL
  LOOT_ROLLS_COMPLETE LOOT_BIND_CONFIRM CONFIRM_DISENCHANT_ROLL LOOT_ITEM_AVAILABLE CHARACTER_POINTS_CHANGED
  PLAYER_TALENT_UPDATE ACTIVE_TALENT_GROUP_CHANGED UNIT_NAME_UPDATE]]):gmatch("%S+") do M.known_events[e] = true end
load_module("objects.lua")
load_module("ui.lua")
load_module("game.lua")

local safecall = M.safecall

-- deprecation-gated globals (absent unless legacy_globals=True)
if cfg.legacy_globals then
  for k, v in pairs(M.legacy) do _G[k] = v end
end
M.create_paperdoll_slots()



SlashCmdList = SlashCmdList or {}
hash_SlashCmdList = {}
M.ns = {}
__NS = M.ns
__MOCK = M

---------------------------------------------------------------------------------------------------
-- control API used by Python
---------------------------------------------------------------------------------------------------
function M.set_time(now, server_time)
  M.now = now
  M.server_time = server_time
end

function M.step(now, server_time, dt)
  M.now = now
  M.server_time = server_time
  M.run_deferred()
  M.run_internal()
  M.run_timers()
  M.run_onupdates(dt)
  M.step_animations(dt)
end

function M.fire_safe(event, ...)
  local ok = safecall("fire " .. tostring(event), M.fire, event, ...)
  return ok
end

function M.load_file(src, chunkname, addonName)
  local f, err = loadstring(src, chunkname)
  if not f then
    M.record_error(err, "load " .. chunkname, "syntax error while loading " .. chunkname .. ": " .. tostring(err))
    return false
  end
  local ok = safecall("load " .. chunkname, f, addonName, M.ns)
  return ok
end

function M.set_toc_meta(addon, meta, order)
  M.toc_meta[addon] = meta
  M.addon_order = M.addon_order or {}
  local found = false
  for _, n in ipairs(M.addon_order) do if n == addon then found = true end end
  if not found then M.addon_order[#M.addon_order + 1] = addon end
end

function M.apply_saved(name, src)
  local f, err = loadstring("return " .. src, "@SavedVariables/" .. name)
  if not f then
    M.record_error(err, "SavedVariables " .. name, "could not parse saved " .. name .. ": " .. tostring(err))
    return false
  end
  setfenv(f, { math = math })
  local ok, v = pcall(f)
  if not ok then M.record_error(v, "SavedVariables " .. name); return false end
  _G[name] = v
  return true
end

function M.serialize_global(name)
  local v = rawget(_G, name)
  local ok, res = pcall(M.serialize, v, "", nil, name)
  if not ok then
    M.record_error(res, "save SavedVariables " .. name, "SavedVariables " .. name .. " could not be saved: " .. tostring(res))
    return nil
  end
  return res
end

function M.addon_loaded(addonName)
  M.loaded_addons[addonName] = true
  M.fire("ADDON_LOADED", addonName)
end

function M.login_events(isInitial, isReload, roster_delay)
  M.variables_loaded = true
  M.fire("VARIABLES_LOADED")
  M.fire("SPELLS_CHANGED")
  M.logged_in = true
  M.fire("PLAYER_LOGIN")
  M.fire("PLAYER_ENTERING_WORLD", isInitial and true or false, isReload and true or false)
  if M.W.group then M.defer("GROUP_ROSTER_UPDATE") end
  if IsInGuild() and not M.guild_loaded then
    if roster_delay and roster_delay > 0 then
      M.after(roster_delay, function()
        M.guild_loaded = true
        M.fire("GUILD_ROSTER_UPDATE", false)
      end, "guild roster (login)")
    else
      M.guild_loaded = true
      M.defer("GUILD_ROSTER_UPDATE", false)
    end
  end
end

function M.logout_events()
  M.fire("PLAYER_LEAVING_WORLD")
  M.fire("PLAYER_LOGOUT")
end

function M.set_modifiers(shift, ctrl, alt)
  local old = M.mods
  M.mods = { shift = shift and true or false, ctrl = ctrl and true or false, alt = alt and true or false }
  if old.shift ~= M.mods.shift then M.fire("MODIFIER_STATE_CHANGED", "LSHIFT", M.mods.shift and 1 or 0) end
  if old.ctrl ~= M.mods.ctrl then M.fire("MODIFIER_STATE_CHANGED", "LCTRL", M.mods.ctrl and 1 or 0) end
  if old.alt ~= M.mods.alt then M.fire("MODIFIER_STATE_CHANGED", "LALT", M.mods.alt and 1 or 0) end
end

function M.set_combat(v)
  v = v and true or false
  if M.combat == v then return end
  M.combat = v
  M.fire(v and "PLAYER_REGEN_DISABLED" or "PLAYER_REGEN_ENABLED")
end

function M.set_target(name)
  M.target = name
  M.fire("PLAYER_TARGET_CHANGED")
end

function M.set_cursor_item(id)
  if id then M.cursor = { kind = "item", id = id, link = M.item_link(id) } else M.cursor = nil end
end

function M.combat_log(...)
  M.cleu = { n = select("#", ...), ... }
  M.fire("COMBAT_LOG_EVENT_UNFILTERED")
  M.cleu = {}
end

-- UI interaction helpers
local function need_obj(f, what)
  if type(f) == "string" then
    local g = rawget(_G, f)
    if not g then error(what .. ": no global frame named '" .. f .. "'", 3) end
    f = g
  end
  if not (type(f) == "table" and M.OBJ[f]) then error(what .. ": not a frame", 3) end
  return f
end
M.need_obj = need_obj

function M.click(f, button)
  f = need_obj(f, "click")
  if not M.is_visible(f) then M.warn("click on hidden frame " .. M.obj_label(f) .. " (a user could not click it)") end
  if f.Click and M.OBJ[f].kind ~= "Frame" then
    f:Click(button or "LeftButton")
  else
    M.call_script(f, "OnMouseDown", button or "LeftButton")
    M.call_script(f, "OnMouseUp", button or "LeftButton", true)
  end
end
function M.hover(f) f = need_obj(f, "hover"); M.call_script(f, "OnEnter", true) end
function M.leave(f) f = need_obj(f, "leave"); M.call_script(f, "OnLeave", true) end
function M.type_text(eb, text, enter)
  eb = need_obj(eb, "type_text")
  local st = M.OBJ[eb]
  if st.kind ~= "EditBox" then error("type_text: " .. M.obj_label(eb) .. " is a " .. st.kind .. ", not an EditBox", 2) end
  M.Methods.EditBox.SetFocus(eb)
  local t = tostring(text)
  if st.numeric then t = sgsub(t, "[^%d]", "") end
  if st.maxletters and st.maxletters > 0 then t = ssub(t, 1, st.maxletters) end
  st.text = t
  st.cursor = #t
  M.call_script(eb, "OnTextChanged", true)
  if enter then M.call_script(eb, "OnEnterPressed") end
end
function M.press_enter(eb) eb = need_obj(eb, "press_enter"); M.call_script(eb, "OnEnterPressed") end
function M.press_escape(eb) eb = need_obj(eb, "press_escape"); M.call_script(eb, "OnEscapePressed") end

function M.slash(line)
  local cmd, rest = smatch(line, "^(/%S+)%s*(.-)%s*$")
  if not cmd then error("slash: line must start with '/'", 2) end
  cmd = slower(cmd)
  for key, fn in pairs(SlashCmdList) do
    local i = 1
    while true do
      local s = rawget(_G, "SLASH_" .. key .. i)
      if s == nil then break end
      if slower(s) == cmd then
        safecall("SlashCmdList." .. key .. " " .. line, fn, rest, ChatFrame1EditBox)
        return true
      end
      i = i + 1
    end
  end
  return false
end

function M.show_tooltip_item(id)
  GameTooltip:SetOwner(UIParent, "ANCHOR_NONE")
  GameTooltip:SetItemByID(id)
  GameTooltip:Show()
  local st = M.OBJ[GameTooltip]
  local out = {}
  for i = 1, st.nlines do
    local l = st.lines[i]
    out[i] = { l.left and M.OBJ[l.left].text or "", l.right and M.OBJ[l.right].text or nil }
  end
  return out
end

function M.menu_export(d)
  d = d or M.last_menu
  if not d then return nil end
  local function exp(x)
    local e = { kind = x.kind, text = x.text, enabled = x.enabled ~= false and true or false, children = {} }
    if type(x.enabled) == "function" then local ok, v = pcall(x.enabled, x); e.enabled = ok and v and true or false end
    if (x.kind == "checkbox" or x.kind == "radio") and x.isSelected then
      local ok, v = safecall("menu isSelected " .. tostring(x.text), x.isSelected, x.data)
      e.selected = ok and v and true or false
    end
    for i, c in ipairs(x.children) do e.children[i] = exp(c) end
    return e
  end
  return exp(d)
end
function M.menu_select(text, d)
  d = d or M.last_menu
  if not d then error("menu_select: no menu has been opened", 2) end
  local found
  local function walk(x)
    for _, c in ipairs(x.children) do
      if found then return end
      if c.text == text then found = c; return end
      walk(c)
    end
  end
  walk(d)
  if not found then error("menu_select: no menu entry with text '" .. tostring(text) .. "'", 2) end
  if found.kind == "button" and found.callback then
    local ok, r = safecall("menu button '" .. tostring(text) .. "'", found.callback, found.data, { buttonName = "LeftButton", context = 2 }, nil)
    return r
  elseif (found.kind == "checkbox" or found.kind == "radio") and found.setSelected then
    local ok, r = safecall("menu " .. found.kind .. " '" .. tostring(text) .. "'", found.setSelected, found.data, { buttonName = "LeftButton", context = 2 }, nil)
    return r
  end
  M.warn("menu_select: entry '" .. tostring(text) .. "' has no callback")
end

function M.dump(f, depth, textures, out, indent)
  f = f and need_obj(f, "dump") or UIParent
  depth = depth or 6
  out = out or {}
  indent = indent or ""
  local st = M.OBJ[f]
  if not textures and indent ~= "" and (st.kind == "Texture" or st.kind == "MaskTexture" or st.kind == "Line") then
    return table.concat(out, "\n")
  end
  local line = indent .. st.kind .. " " .. (st.name or ("<" .. (st.template or "anon") .. ">"))
  if not st.shown then line = line .. " [hidden]" end
  if st.text and st.text ~= "" then line = line .. " text=" .. sformat("%q", M.safe_str(st.text)) end
  if st.kind == "Button" or st.kind == "CheckButton" then
    local t = f.GetText and f:GetText()
    if t then line = line .. " label=" .. sformat("%q", M.safe_str(t)) end
    if st.kind == "CheckButton" then line = line .. " checked=" .. tostring(st.checked) end
    if not st.enabled then line = line .. " [disabled]" end
  end
  if st.value then line = line .. " value=" .. tostring(st.value) end
  if st.texture then line = line .. " tex=" .. tostring(st.texture) end
  out[#out + 1] = line
  if depth > 0 then
    for _, c in ipairs(st.children) do
      local cs = M.OBJ[c]
      if cs and cs.kind ~= "AnimationGroup" then M.dump(c, depth - 1, textures, out, indent .. "  ") end
    end
  end
  return table.concat(out, "\n")
end

function M.find_text(pattern, visible_only, plain)
  local out = {}
  for _, o in ipairs(M.all_objects) do
    local st = M.OBJ[o]
    if st and type(st.text) == "string" and string.find(st.text, pattern, 1, plain) then
      if not visible_only or M.is_visible(o) then out[#out + 1] = o end
    end
  end
  return out
end

function M.get_errors(from)
  local out = {}
  for i = (from or 1), #M.errors do
    local e = M.errors[i]
    out[#out + 1] = M.safe_str(e.where) .. ": " .. M.safe_str(e.traceback or e.msg)
  end
  return out
end
function M.error_count() return #M.errors end

function M.report_tables()
  local uf, um, mg, ev = {}, {}, {}, {}
  for _, e in pairs(M.unknown_fields) do uf[#uf + 1] = { e.label, e.key, e.where, e.count } end
  for _, e in pairs(M.unknown_methods) do um[#um + 1] = { e.label, e.key, e.where, e.count } end
  for k, e in pairs(M.missing_globals) do mg[#mg + 1] = { k, e.where, e.count } end
  for k, w in pairs(M.unknown_events) do ev[#ev + 1] = { k, w } end
  local tpl = {}
  for k, w in pairs(M.unknown_templates) do tpl[#tpl + 1] = { k, w } end
  return { fields = uf, methods = um, globals = mg, events = ev, templates = tpl }
end

---------------------------------------------------------------------------------------------------
-- _G fallback: log reads of missing globals; UIDropDownMenu_*/PanelTemplates_* are no-op stubs
---------------------------------------------------------------------------------------------------
M.missing_globals = {}
local NOOP_PREFIX = { "UIDropDownMenu_", "PanelTemplates_" }
setmetatable(_G, { __index = function(t, k)
  if type(k) ~= "string" then return nil end
  for _, p in ipairs(NOOP_PREFIX) do
    if ssub(k, 1, #p) == p then
      local f = function() end
      rawset(t, k, f)
      M.warn("no-op stub used for " .. k)
      return f
    end
  end
  local e = M.missing_globals[k]
  if e then e.count = e.count + 1 else M.missing_globals[k] = { count = 1, where = M.caller_where(3) } end
  return nil
end })

return M
