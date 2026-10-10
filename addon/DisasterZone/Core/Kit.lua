if DisasterZoneBoot and DisasterZoneBoot.Run("Core/Kit.lua", ...) then return end -- DisasterZone: Core/Kit.lua
-- ns.Kit: the consumables kit of a spec (Data/Consumables.lua) for My BiS > Consumables (UI/KitView.lua): the best
-- pick and a budget pick per slot, what my bags hold of a night's worth, who in the guild makes it, what it costs by
-- Auctionator's last scan, the shopping list, and the gear sim's DPS for every pick (the specs it covers; run on
-- request: the kit with and without each slot, on the same random rolls, with the gear I wear).
local _, ns = ...

local Kit = {}
ns.Kit = Kit

local floor, max = math.floor, math.max
local CALLER = "DisasterZone"

Kit.ITERATIONS = 200
Kit.SIDES = { "best", "budget" }

local function D() return ns.Data and ns.Data.Consumables end
local function R() return ns.SimRunner end

-- ---------------------------------------------------------------------------------------------------------------
-- The kit
-- ---------------------------------------------------------------------------------------------------------------

-- "CLASS:Spec" of the list My BiS shows (its off-spec list's while that one is open).
function Kit:SpecKey()
  if R() then return R():SpecKey() end
  local _, cls = UnitClass("player")
  return (cls or "") .. ":" .. ((ns.BiS and ns.BiS:GetSpec()) or "")
end

function Kit:Spec()
  return (self:SpecKey():match(":(.*)$")) or ""
end

function Kit:Has(key)
  local d = D()
  return d and d.KITS[key or self:SpecKey()] ~= nil
end

function Kit:Item(id)
  local d = D()
  return d and d.ITEMS[id]
end

-- The item's name (the client's when it knows it, else the data's).
function Kit:Name(id)
  local name = C_Item and C_Item.GetItemInfo and C_Item.GetItemInfo(id)
  if name then return name end
  local it = self:Item(id)
  return it and it[1] or ("item " .. tostring(id))
end

function Kit:Kind(id)
  local it = self:Item(id)
  return it and it[4]
end

function Kit:Effect(id)
  local it = self:Item(id)
  return it and it[3] or ""
end

-- How many of an item one night takes.
function Kit:Need(id)
  local d = D()
  return d and d.NIGHT[self:Kind(id) or ""] or 1
end

local BLUNT_SUB = { [4] = true, [5] = true, [10] = true }   -- one- / two-handed maces, staves

-- Is the main hand I wear a blunt weapon (a weightstone instead of a sharpening stone)?
function Kit:BluntMainHand()
  local id = GetInventoryItemID and GetInventoryItemID("player", 16)
  if not id then return false end
  local sub
  if C_Item and C_Item.GetItemInfoInstant then sub = select(7, C_Item.GetItemInfoInstant(id)) end
  return BLUNT_SUB[tonumber(sub) or -1] or false
end

-- A pick's items, a sharpening stone swapped for the weightstone on a blunt main hand.
local function Ids(list, blunt)
  local out = {}
  local swap = D().BLUNT
  for i, id in ipairs(list) do out[i] = (blunt and swap[id]) or id end
  return out
end

-- The kit of a spec: { { key, title, why, best = side, budget = side }, ... } in the order shown; a side is
-- { kind = "items", ids = { ... } } | { kind = "same", text } | { kind = "skip", text }. Slots the spec has nothing
-- for are left out. nil for a spec without a kit.
function Kit:Get(key)
  local d = D()
  local kit = d and d.KITS[key or self:SpecKey()]
  if not kit then return nil end
  local blunt = self:BluntMainHand()
  local rows = {}
  for _, s in ipairs(d.SLOTS) do
    local k = kit[s.key]
    if k then
      local row = { key = s.key, title = s.title, why = k.why or s.why }
      row.best = { kind = "items", ids = Ids(k.best, blunt) }
      if k.budget == "same" then
        row.budget = { kind = "same", text = k.sameWhy or "" }
      elseif k.budget == false then
        row.budget = { kind = "skip", text = k.skip or "" }
      else
        row.budget = { kind = "items", ids = Ids(k.budget, blunt), text = k.budgetWhy }
      end
      rows[#rows + 1] = row
    end
  end
  return rows
end

-- The items a side of the kit takes (the best pick's for "same", none for "skip").
function Kit:SideIds(row, side)
  local s = row[side]
  if s.kind == "items" then return s.ids end
  if s.kind == "same" then return row.best.ids end
  return {}
end

-- ---------------------------------------------------------------------------------------------------------------
-- Bags, crafters, prices, the shopping list
-- ---------------------------------------------------------------------------------------------------------------

local function Count(id, bank)
  if C_Item and C_Item.GetItemCount then return C_Item.GetItemCount(id, bank) or 0 end
  return GetItemCount and GetItemCount(id, bank) or 0
end

function Kit:Have(id) return Count(id, false) end
function Kit:InBank(id) return max(0, Count(id, true) - Count(id, false)) end

-- Do my bags hold a night's worth of every item of a pick?
function Kit:Ready(ids)
  if #ids == 0 then return false end
  for _, id in ipairs(ids) do
    if self:Have(id) < self:Need(id) then return false end
  end
  return true
end

-- How many of a pick's items my bags still lack for the night: { [id] = n }.
function Kit:Missing(ids)
  local out = {}
  for _, id in ipairs(ids) do
    local n = self:Need(id) - self:Have(id)
    if n > 0 then out[id] = n end
  end
  return out
end

function Kit:CanList(id)
  return ns.Shop and ns.Shop:CanAdd(id) and true or false
end

-- Who makes it: "me" (one of my characters), a guild member's key (reachable first), or nil.
function Kit:Crafter(id)
  local Shop = ns.Shop
  if not (Shop and Shop:CanAdd(id)) then return nil end
  if Shop:CanMake(id) then return "me" end
  local c = Shop:GetCrafters(id)[1]
  return c and c.key or nil
end

-- What one costs at the auction house by Auctionator's last scan (copper), nil without Auctionator or a price.
function Kit:Price(id)
  local api = _G.Auctionator and _G.Auctionator.API and _G.Auctionator.API.v1
  local get = api and api.GetAuctionPriceByItemID
  if not get then return nil end
  local ok, p = pcall(get, CALLER, id)
  return ok and tonumber(p) or nil
end

-- What a pick costs for a night (copper), nil when a price is missing.
function Kit:Cost(ids)
  if #ids == 0 then return nil end
  local sum = 0
  for _, id in ipairs(ids) do
    local p = self:Price(id)
    if not p then return nil end
    sum = sum + p * self:Need(id)
  end
  return sum
end

-- A side of the whole kit: { ready = slots with a night's worth in my bags, slots = slots that take something,
-- toList = { [id] = n } what the shopping list can take, listCount = how many of those the list still lacks, other = n items no craft makes, cost = copper or nil,
-- crafted = n missing items a guildie (not me) makes }.
function Kit:Summary(rows, side)
  local out = { ready = 0, slots = 0, toList = {}, other = 0, crafted = 0, cost = 0 }
  for _, row in ipairs(rows or {}) do
    local ids = self:SideIds(row, side)
    if #ids > 0 then
      out.slots = out.slots + 1
      if self:Ready(ids) then out.ready = out.ready + 1 end
      for id, n in pairs(self:Missing(ids)) do
        if self:CanList(id) then
          out.toList[id] = (out.toList[id] or 0) + n
          local who = self:Crafter(id)
          if who and who ~= "me" then out.crafted = out.crafted + 1 end
        else
          out.other = out.other + 1
        end
      end
      local c = out.cost and self:Cost(ids)
      out.cost = c and (out.cost + c) or nil
    end
  end
  -- what the list still lacks of it (the buttons' count)
  local n = 0
  for id, want in pairs(out.toList) do
    if want > ((ns.Shop and ns.Shop:GetAmount(id)) or 0) then n = n + 1 end
  end
  out.listCount = n
  return out
end

-- Puts what a side of the kit still lacks for the night on my shopping list (crafted items only). Returns how many
-- items went on it.
function Kit:AddToList(rows, side)
  local Shop = ns.Shop
  if not Shop then return 0 end
  local n = 0
  for id, count in pairs(self:Summary(rows, side).toList) do
    local have = Shop:GetAmount(id) or 0
    if count > have then
      if Shop:Add(id, count - have) then n = n + 1 end
    elseif have > 0 then
      n = n + 1
    end
  end
  return n
end

-- ---------------------------------------------------------------------------------------------------------------
-- The gear sim: DPS of each pick
-- ---------------------------------------------------------------------------------------------------------------

-- Fields of the sim's consumables the kit sets; the rest of the buffs setting's (drums, explosives, a rogue's
-- poison) stay.
local MANAGED = { "flaskId", "battleElixirId", "guardianElixirId", "foodId", "potId", "conjuredId", "mhImbueId",
  "scrollAgi", "scrollStr", "scrollInt", "scrollSpi" }
local FIELD = { flask = "flaskId", battle = "battleElixirId", guardian = "guardianElixirId", food = "foodId",
  potion = "potId" }

-- Does the sim know what this item does?
function Kit:Simmed(id)
  local d, kind = D(), self:Kind(id)
  if kind == "stone" or kind == "oil" then return d.SIM_IMBUE[id] ~= nil end
  if kind == "scroll" then return d.SIM_SCROLL[id] ~= nil end
  if kind == "rune" then return d.SIM_RUNE[id] ~= nil end
  if FIELD[kind] then
    local db = R() and R():DB()
    return db and db.consumables[id] ~= nil or false
  end
  return false
end

function Kit:CanSim(key)
  return R() and R():IsSupported(key) and self:Has(key) and true or false
end

-- The sim's consumables: the buffs setting's own, the kit's fields replaced by the picks given ({ slot = ids }).
function Kit:SimConsumables(base, picks)
  local d = D()
  local out = {}
  for k, v in pairs(base or {}) do out[k] = v end
  for _, f in ipairs(MANAGED) do out[f] = nil end
  for _, ids in pairs(picks) do
    for _, id in ipairs(ids) do
      local kind = self:Kind(id)
      if FIELD[kind] then out[FIELD[kind]] = id
      elseif kind == "rune" and d.SIM_RUNE[id] then out.conjuredId = id
      elseif (kind == "stone" or kind == "oil") and d.SIM_IMBUE[id] then out.mhImbueId = d.SIM_IMBUE[id]
      elseif kind == "scroll" and d.SIM_SCROLL[id] then out[d.SIM_SCROLL[id]] = true end
    end
  end
  -- a rogue without an imbue of his own would lose his off-hand poison (Runner RogueOwn): keep it
  if self:SpecKey():match("^ROGUE:") and not out.ohImbueId then out.ohImbueId = 27186 end
  return out
end

local run = { running = false, done = 0, total = 0 }
Kit.results = nil   -- { key = spec key, best = { slot = dps }, budget = { slot = dps }, prog, farm, se }

local function SimSlotIds(ids)
  local out = {}
  for _, id in ipairs(ids) do if Kit:Simmed(id) then out[#out + 1] = id end end
  return out
end

-- The runs a kit takes: the whole best kit, the whole budget kit, none, and per slot the best kit without the slot and
-- with the budget pick in it. jobs[i] = { key, picks }.
function Kit:Jobs(rows)
  local best, budget = {}, {}
  for _, row in ipairs(rows) do
    best[row.key] = SimSlotIds(row.best.ids)
    budget[row.key] = SimSlotIds(self:SideIds(row, "budget"))
  end
  local function with(slot, ids)
    local t = {}
    for k, v in pairs(best) do t[k] = v end
    t[slot] = ids
    return t
  end
  local jobs = { { key = "prog", picks = best }, { key = "farm", picks = budget }, { key = "none", picks = {} } }
  for _, row in ipairs(rows) do
    local b = best[row.key]
    if #b > 0 then jobs[#jobs + 1] = { key = "no:" .. row.key, picks = with(row.key, {}) } end
    local u = budget[row.key]
    if #u > 0 and table.concat(u, ",") ~= table.concat(b, ",") then
      jobs[#jobs + 1] = { key = "bud:" .. row.key, picks = with(row.key, u) }
    end
  end
  return jobs, best, budget
end

function Kit:IsRunning() return run.running end
function Kit:Progress() return run.done / max(1, run.total), run.paused end

function Kit:Results(key)
  local r = self.results
  if r and r.key == (key or self:SpecKey()) then return r end
  return nil
end

function Kit:ClearResults() self.results = nil end

function Kit:Cancel()
  if run.running and R() then R():Cancel() end
end

-- Sims the shown spec's kit with the gear I wear and the gear sim card's buffs, fight length and boss type.
-- onUpdate() hears every progress step and the end.
function Kit:Run(onUpdate)
  local Rn = R()
  local key = self:SpecKey()
  if run.running then self:Cancel() return true end
  if not self:CanSim(key) then return false, "The gear sim doesn't cover this spec yet." end
  local rows = self:Get(key)
  local jobs, best, budget = self:Jobs(rows)
  local settings = ns.SimPanel and ns.SimPanel.RunSettings and ns.SimPanel:RunSettings() or {}
  local base = Rn:BuffConfig(settings.buffs or "raid25").consumables
  local set = Rn:EquippedSet()
  local list = {}
  for i, j in ipairs(jobs) do list[i] = { key = j.key, set = set, cons = self:SimConsumables(base, j.picks) } end
  run.running, run.done, run.total, run.paused = true, 0, 1, false
  local function finish()
    run.running = false
    if onUpdate then onUpdate() end
  end
  -- every job has its own consumables: the Runner takes them per set through the settings
  local ok, err = Rn:Start(list, {
    iterations = self.ITERATIONS, settings = settings,
    onProgress = function(done, total, paused)
      run.done, run.total, run.paused = done, total, paused
      if onUpdate then onUpdate() end
    end,
    onCancel = finish,
    onDone = function(res, e)
      if res then
        local out = { key = key, best = {}, budget = {}, at = time and time() or 0 }
        local function diff(a, b)
          local m, se = res.diff(a, b)
          return m, se
        end
        out.prog, out.progSE = diff("prog", "none")
        out.farm, out.farmSE = diff("farm", "none")
        -- per slot: the DPS and its standard error (a number within 2 of them is too close to call)
        out.bestSE, out.budgetSE = {}, {}
        local k
        for _, row in ipairs(rows) do
          k = row.key
          if res["no:" .. k] then
            out.best[k], out.bestSE[k] = diff("prog", "no:" .. k)
            if res["bud:" .. k] then
              out.budget[k], out.budgetSE[k] = diff("bud:" .. k, "no:" .. k)
            elseif #budget[k] > 0 then
              out.budget[k], out.budgetSE[k] = out.best[k], out.bestSE[k]   -- the same items
            end
          elseif res["bud:" .. k] then
            out.budget[k], out.budgetSE[k] = diff("bud:" .. k, "prog")
          end
        end
        self.results = out
      else
        ns:Print("The gear sim stopped: %s", tostring(e))
      end
      finish()
    end,
  })
  if not ok then
    run.running = false
    return false, err
  end
  if onUpdate then onUpdate() end
  return true
end

-- Gear changes make the numbers old.
ns:RegisterEvent("PLAYER_EQUIPMENT_CHANGED", function() Kit.results = nil end)
