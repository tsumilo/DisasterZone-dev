if DisasterZoneBoot and DisasterZoneBoot.Run("Sim/Data.lua", ...) then return end -- DisasterZone: Sim/Data.lua
-- ns.GearSim item data: builds the sim's item / gem / enchant records lazily from Data/SimItems.lua (gen_sim_items.py)
-- and Data/Gems.lua (sockets, socket bonuses, gems, enchants; gen_gems.py). Records are parsed on first use and kept.
local _, ns = ...
local S = ns.GearSim

local tonumber = tonumber

local GEM_COLOR = { M = 1, R = 2, B = 3, Y = 4, G = 5, O = 6, P = 7, X = 8 }

local function ParseStats(s, sep)
  local t = {}
  if not s or s == "" then return t end
  for k, v in s:gmatch("(%d+):([%-%d%.]+)") do t[tonumber(k)] = tonumber(v) end
  return t
end

local items, gems, enchants, consumables, suffixes = {}, {}, {}, {}, {}

local function ParseItem(id)
  local raw = ns.Data and ns.Data.SimItems and ns.Data.SimItems[id]
  if not raw then return nil end
  local head, stats, set, effs = raw:match("^([^|]*)|([^|]*)|([^|]*)|(.*)$")
  local f = {}
  for x in head:gmatch("[^,]+") do f[#f + 1] = tonumber(x) end
  local it = {
    id = id, type = f[1], handType = f[2], weaponType = f[3], weaponSpeed = f[4], weaponMin = f[5], weaponMax = f[6],
    randPropPoints = f[7] or 0, stats = ParseStats(stats), setName = set ~= "" and set or nil, effects = {},
  }
  for e in effs:gmatch("[^/]+") do
    local p = {}
    for x in (e .. ","):gmatch("([^,]*),") do p[#p + 1] = x end
    local ef = { buffId = tonumber(p[1]), durationMs = tonumber(p[2]) or 0, stats = ParseStats(p[3]),
      maxStacks = tonumber(p[10]) or 0 }
    local ppm, icd, chance = tonumber(p[4]) or 0, tonumber(p[5]) or 0, tonumber(p[6]) or 0
    if ppm > 0 or icd > 0 or chance > 0 then ef.proc = { ppm = ppm, icdMs = icd, procChance = chance } end
    local cd, cat, catCd = tonumber(p[7]) or 0, tonumber(p[8]) or 0, tonumber(p[9]) or 0
    if cd > 0 or cat > 0 then ef.onUse = { cooldownMs = cd, categoryId = cat, categoryCooldownMs = catCd } end
    it.effects[#it.effects + 1] = ef
  end
  local sock = ns.Data.Sockets and ns.Data.Sockets[id]
  if sock then
    local letters, _, bonus = sock:match("^([^|]*)|([^|]*)|(.*)$")
    it.sockets = {}
    for c in (letters or ""):gmatch(".") do it.sockets[#it.sockets + 1] = GEM_COLOR[c] end
    it.socketBonus = ParseStats(bonus)
  end
  return it
end

local PROC_CB = { hit = "hit", taken = "taken", cast = "cast", periodic = "periodic", apply = "apply" }

local function ParseProc(id)
  local raw = ns.Data and ns.Data.SimProcs and ns.Data.SimProcs[id]
  if not raw then return nil end
  local cb, pm, oc, flags = raw:match("^([^,]*),([^,]*),([^,]*),(.*)$")
  local cbs = {}
  for c in cb:gmatch("[^+]+") do cbs[#cbs + 1] = PROC_CB[c] end
  return { callback = (#cbs == 1) and cbs[1] or cbs, procMask = tonumber(pm), outcome = tonumber(oc),
    requireDamage = flags:find("d") ~= nil, weaponProc = flags:find("w") ~= nil,
    canProcFromProcs = flags:find("p") ~= nil, classSpellsOnly = flags:find("c") ~= nil }
end

-- The db table S.BuildPlayer expects, backed by lazy lookups.
function S.GameDB()
  local procs = {}
  return {
    items = setmetatable({}, { __index = function(t, id)
      local it = items[id]
      if it == nil then it = ParseItem(id) or false; items[id] = it end
      return it or nil
    end }),
    gems = setmetatable({}, { __index = function(t, id)
      local g = gems[id]
      if g == nil then
        local r = ns.Data and ns.Data.Gems and ns.Data.Gems[id]
        g = r and { id = id, color = GEM_COLOR[r[1]], stats = ParseStats(r.st) } or false
        gems[id] = g
      end
      return g or nil
    end }),
    enchants = setmetatable({}, { __index = function(t, id)
      local e = enchants[id]
      if e == nil then
        local r = ns.Data and ns.Data.Enchants and ns.Data.Enchants[id]
        e = r and { effectId = id, stats = ParseStats(r.st) } or false
        enchants[id] = e
      end
      return e or nil
    end }),
    itemProcs = setmetatable({}, { __index = function(t, id)
      local p = procs[id]
      if p == nil then p = ParseProc(id) or false; procs[id] = p end
      return p or nil
    end }),
    onUse = (ns.Data and ns.Data.SimOnUse) or {},
    suffixes = setmetatable({}, { __index = function(t, id)
      local s = suffixes[id]
      if s == nil then
        local r = ns.Data and ns.Data.SimSuffixes and ns.Data.SimSuffixes[id]
        s = r and { id = id, stats = ParseStats(r) } or false
        suffixes[id] = s
      end
      return s or nil
    end }),
    consumables = setmetatable({}, { __index = function(t, id)
      local c = consumables[id]
      if c == nil then
        local r = ns.Data and ns.Data.SimConsumables and ns.Data.SimConsumables[id]
        local f = {}
        if r then for x in (r .. "|"):gmatch("([^|]*)|") do f[#f + 1] = x end end
        if f[1] then
          c = { id = id, type = tonumber(f[1]), stats = ParseStats(f[2]), buffDuration = tonumber(f[3]) or 0,
            cooldown = tonumber(f[4]) or 0, categoryCooldown = tonumber(f[5]) or 0, categoryId = tonumber(f[6]) or 0,
            gains = {} }
          for e in (f[7] or ""):gmatch("[^;]+") do
            local mn, sp, res, per, dur = e:match("^([%-%d%.]+):([%-%d%.]+):(%d+):(%d+):(%d+)$")
            if mn then
              c.gains[#c.gains + 1] = { min = tonumber(mn), spread = tonumber(sp), resource = tonumber(res),
                periodMs = tonumber(per), durationMs = tonumber(dur) }
            end
          end
        else
          c = false
        end
        consumables[id] = c
      end
      return c or nil
    end }),
  }
end
