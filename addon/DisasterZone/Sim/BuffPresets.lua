if DisasterZoneBoot and DisasterZoneBoot.Run("Sim/BuffPresets.lua", ...) then return end -- DisasterZone: Sim/BuffPresets.lua
-- ns.SimBuffs: the gear sim's buff presets beside WoWSims' three (Sim/Runner.lua Runner.BUFFS).
--   * My presets: buff setups you build in the editor (UI/SimBuffs.lua), saved for all your characters.
--   * My teams: one entry per lineup of a team you are on (Raids > Teams). It follows who is placed in the lineup:
--     your group's party buffs, the raid's buffs and the boss debuffs, from the specs placed there (and, when ticked,
--     the comp's open slots, placed into groups the way the Teams page shows them). Your clicks in the editor are
--     kept as overrides on top; nothing else is stored, so roster changes show up by themselves.
-- A buff setup is the sim's buff config (WoWSims' field names: raid / party / individual / debuffs / consumables;
-- Sim/Buffs.lua reads it). Tiles are the editor's view of it: one per buff the sim knows, with 2-3 states.
-- Keys (the card's buffs setting): "raid25" | "raid10" | "solo" (WoWSims') | "p:<id>" (mine) | "t:<team>:<lineup>".
local _, ns = ...

local SimBuffs = {}
ns.SimBuffs = SimBuffs

local pairs, ipairs, type, tostring = pairs, ipairs, type, tostring
local tsort, tconcat = table.sort, table.concat
local min = math.min

local I = "Interface\\Icons\\"

-- ---------------------------------------------------------------------------------------------------------------
-- Tiles
-- ---------------------------------------------------------------------------------------------------------------
-- sec: "group" (your party), "raid", "boss" (debuffs), "mine" (what you bring). path = { cfg section, field };
-- kind: "tri" (off / on / improved), "bool", "count" (0-3: Ferocious Inspiration, one per Beast Mastery hunter), or
-- a tile with its own get / set. mana = only for classes with mana; only = { CLASS = true }; item = an item whose icon
-- the tile shows. needs: who brings it, for an empty tile ("no Survival hunter").
local TRI = { "Off", "On", "Improved" }
local TILES = {
  -- your group
  { key = "windfury", sec = "group", name = "Windfury Totem", icon = "Spell_Nature_Windfury",
    path = { "party", "windfuryTotem" }, kind = "tri", needs = "shaman",
    own = { SHAMAN = { "your own totem", "You drop your own totems; the sim's rotation keeps them up (twisting Windfury and Grace of Air)." } } },
  { key = "graceofair", sec = "group", name = "Grace of Air", icon = "Spell_Nature_InvisibilityTotem",
    path = { "party", "graceOfAirTotem" }, kind = "tri", needs = "shaman",
    own = { SHAMAN = { "your own totem", "You drop your own totems; the sim's rotation keeps them up (twisting Windfury and Grace of Air)." } } },
  { key = "strengthofearth", sec = "group", name = "Strength of Earth", icon = "Spell_Nature_EarthBindTotem",
    path = { "party", "strengthOfEarthTotem" }, kind = "tri", needs = "shaman",
    own = { SHAMAN = { "your own totem", "You drop your own totems; the sim's rotation keeps them up (twisting Windfury and Grace of Air)." } } },
  { key = "manaspring", sec = "group", name = "Mana Spring", icon = "Spell_Nature_ManaRegenTotem",
    path = { "party", "manaSpringTotem" }, kind = "tri", needs = "shaman", mana = true,
    own = { SHAMAN = { "your own totem", "You drop your own totems; the sim's rotation keeps them up (twisting Windfury and Grace of Air)." } } },
  { key = "unleashedrage", sec = "group", name = "Unleashed Rage", icon = "Spell_Nature_UnleashedRage",
    path = { "individual", "unleashedRage" }, kind = "bool", needs = "Enhancement shaman",
    own = { SHAMAN = { "your own talent", "Unleashed Rage is your own talent here; the sim gives it to you on your crits." } } },
  { key = "battleshout", sec = "group", name = "Battle Shout", icon = "Ability_Warrior_BattleShout",
    path = { "party", "battleShout" }, kind = "tri", needs = "warrior",
    own = { WARRIOR = { "you shout yourself", "You shout yourself; the sim's rotation keeps your own Battle Shout up." } } },
  { key = "lotp", sec = "group", name = "Leader of the Pack", icon = "Spell_Nature_UnyeildingStamina",
    own = { DRUID = { "your own talent", "As a cat you bring Leader of the Pack yourself (the sim adds it)." } },
    path = { "party", "leaderOfThePack" }, kind = "tri", needs = "Feral druid" },
  { key = "ferocious", sec = "group", name = "Ferocious Inspiration", icon = "Ability_Hunter_FerociousInspiration",
    path = { "party", "ferociousInspiration" }, kind = "count", needs = "Beast Mastery hunter" },
  { key = "trueshot", sec = "group", name = "Trueshot Aura", icon = "Ability_TrueShot",
    path = { "party", "trueshotAura" }, kind = "bool", needs = "Marksmanship hunter" },
  { key = "drums", sec = "group", name = "Drums of Battle", icon = "INV_Misc_Drum_02", kind = "custom",
    needs = "leatherworker",
    get = function(c) local d = c.party and c.party.drums; return (d and d ~= 0 and d ~= "DrumsUnknown") and 1 or 0 end,
    set = function(c, v) c.party.drums = v > 0 and "LesserDrumsOfBattle" or nil end },
  { key = "braided", sec = "group", name = "Braided Eternium", icon = "INV_Jewelry_Necklace_29",
    path = { "party", "braidedEterniumChain" }, kind = "bool", needs = "jewelcrafter's chain", noInfer = true },
  -- the raid
  { key = "bloodlust", sec = "raid", name = "Bloodlust", icon = "Spell_Nature_BloodLust",
    path = { "raid", "bloodlust" }, kind = "bool", needs = "shaman" },
  { key = "kings", sec = "raid", name = "Blessing of Kings", icon = "Spell_Magic_GreaterBlessingofKings",
    path = { "individual", "blessingOfKings" }, kind = "bool", needs = "paladin" },
  { key = "might", sec = "raid", name = "Blessing of Might", icon = "Spell_Holy_GreaterBlessingofKings",
    path = { "individual", "blessingOfMight" }, kind = "tri", needs = "second paladin" },
  { key = "wisdom", sec = "raid", name = "Blessing of Wisdom", icon = "Spell_Holy_GreaterBlessingofWisdom",
    path = { "individual", "blessingOfWisdom" }, kind = "tri", needs = "third paladin", mana = true },
  { key = "gotw", sec = "raid", name = "Gift of the Wild", icon = "Spell_Nature_GiftoftheWild",
    path = { "raid", "giftOfTheWild" }, kind = "tri", needs = "druid" },
  { key = "fortitude", sec = "raid", name = "Fortitude", icon = "Spell_Holy_PrayerOfFortitude",
    path = { "raid", "powerWordFortitude" }, kind = "tri", needs = "priest" },
  { key = "arcaneint", sec = "raid", name = "Arcane Intellect", icon = "Spell_Holy_ArcaneIntellect",
    path = { "raid", "arcaneBrilliance" }, kind = "bool", needs = "mage", mana = true },
  { key = "divinespirit", sec = "raid", name = "Divine Spirit", icon = "Spell_Holy_PrayerofSpirit",
    path = { "raid", "divineSpirit" }, kind = "tri", needs = "Discipline priest", mana = true },
  -- the boss
  { key = "sunder", sec = "boss", name = "Sunder Armor", icon = "Ability_Warrior_Sunder",
    path = { "debuffs", "sunderArmor" }, kind = "bool", needs = "warrior" },
  { key = "exposearmor", sec = "boss", name = "Expose Armor", icon = "Ability_Warrior_Riposte",
    path = { "debuffs", "exposeArmor" }, kind = "tri", needs = "rogue",
    own = { ROGUE = { "your own Expose Armor", "You keep up your own Expose Armor; the sim's rotation casts it with 5 combo points." } } },
  { key = "faeriefire", sec = "boss", name = "Faerie Fire", icon = "Spell_Nature_FaerieFire",
    path = { "debuffs", "faerieFire" }, kind = "tri", needs = "druid" },
  { key = "recklessness", sec = "boss", name = "Recklessness", icon = "Spell_Shadow_UnholyStrength",
    path = { "debuffs", "curseOfRecklessness" }, kind = "bool", needs = "second warlock",
    tip = "Curse of Recklessness: the boss's armor down by 800." },
  { key = "elements", sec = "boss", name = "Elements", icon = "Spell_Shadow_ChillTouch",
    path = { "debuffs", "curseOfElements" }, kind = "tri", needs = "warlock", mana = true,
    tip = "Curse of the Elements: more fire, frost, arcane and shadow damage taken." },
  { key = "bloodfrenzy", sec = "boss", name = "Blood Frenzy", icon = "Ability_Warrior_BloodFrenzy",
    path = { "debuffs", "bloodFrenzy" }, kind = "bool", needs = "Arms warrior" },
  { key = "mangle", sec = "boss", name = "Mangle", icon = "Ability_Druid_Mangle2",
    path = { "debuffs", "mangle" }, kind = "bool", needs = "Feral druid", only = { WARRIOR = true } },
  { key = "misery", sec = "boss", name = "Misery", icon = "Spell_Shadow_Misery",
    path = { "debuffs", "misery" }, kind = "bool", needs = "Shadow priest", mana = true },
  { key = "huntersmark", sec = "boss", name = "Hunter's Mark", icon = "Ability_Hunter_SniperShot",
    path = { "debuffs", "huntersMark" }, kind = "tri", needs = "hunter" },
  { key = "exposeweakness", sec = "boss", name = "Expose Weakness", icon = "Ability_Rogue_FindWeakness",
    kind = "custom", needs = "Survival hunter",
    tip = "A Survival hunter's crits: attack power against the boss (90% uptime, 1080 agility, as WoWSims).",
    get = function(c) return ((c.debuffs.exposeWeaknessUptime or 0) > 0) and 1 or 0 end,
    set = function(c, v)
      c.debuffs.exposeWeaknessUptime = v > 0 and 0.9 or nil
      c.debuffs.exposeWeaknessHunterAgility = v > 0 and 1080 or nil
    end },
  { key = "jow", sec = "boss", name = "Wisdom Judgement", icon = "Spell_Holy_RighteousnessAura",
    path = { "debuffs", "judgementOfWisdom" }, kind = "bool", needs = "paladin", mana = true },
  { key = "jotc", sec = "boss", name = "Crusader Judgement", icon = "Spell_Holy_HolySmite",
    path = { "debuffs", "improvedSealOfTheCrusader" }, kind = "tri", needs = "two paladins",
    tip = "Judgement of the Crusader: more holy damage taken; improved, 3% more crit against the boss." },
  { key = "arthas", sec = "boss", name = "Gift of Arthas", icon = "INV_Potion_28", item = 9088,
    path = { "debuffs", "giftOfArthas" }, kind = "bool", needs = "someone's potion", noInfer = true },
  -- what you bring
  { key = "flask", sec = "mine", name = "Relentless Assault", icon = "INV_Potion_117", item = 22854,
    path = { "consumables", "flaskId" }, kind = "custom", value = 22854 },
  { key = "food", sec = "mine", name = "Roasted Clefthoof", icon = "INV_Misc_Food_60", item = 27658,
    path = { "consumables", "foodId" }, kind = "custom", value = 27658 },
  { key = "potion", sec = "mine", name = "Haste Potion", icon = "INV_Potion_108", item = 22838,
    path = { "consumables", "potId" }, kind = "custom", value = 22838 },
  { key = "conjured", sec = "mine", name = "Rune / Flame Cap", icon = "INV_Misc_Rune_04", kind = "custom",
    states = { "None", "Demonic Rune", "Flame Cap" },
    get = function(c)
      local id = c.consumables.conjuredId
      return (id == 12662 and 1) or (id == 22788 and 2) or 0
    end,
    set = function(c, v) c.consumables.conjuredId = (v == 1 and 12662) or (v == 2 and 22788) or nil end },
  { key = "scrolls", sec = "mine", name = "Scrolls (Agi + Str)", icon = "INV_Scroll_02", kind = "custom",
    get = function(c) return (c.consumables.scrollAgi or c.consumables.scrollStr) and 1 or 0 end,
    set = function(c, v) c.consumables.scrollAgi = v > 0 or nil; c.consumables.scrollStr = v > 0 or nil end },
  { key = "stone", sec = "mine", name = "Sharpening Stone", icon = "INV_Stone_02", item = 23529, kind = "custom",
    only = { WARRIOR = true }, tip = "On the off hand (Windfury Totem replaces the main hand's).",
    get = function(c) return (c.consumables.ohImbueId or c.consumables.mhImbueId) and 1 or 0 end,
    set = function(c, v) c.consumables.ohImbueId = v > 0 and 29453 or nil; c.consumables.mhImbueId = nil end },
  { key = "explosives", sec = "mine", name = "Explosives", icon = "INV_Misc_Bomb_08", item = 30217, kind = "custom",
    tip = "Adamantite Grenades and sappers; only an engineer throws them.",
    get = function(c) return c.consumables.explosiveId and 1 or 0 end,
    set = function(c, v)
      local on = v > 0 or nil
      c.consumables.explosiveId = on and 30217 or nil
      c.consumables.superSapper, c.consumables.goblinSapper = on, on
    end },
}
local TILE_BY_KEY = {}
for _, t in ipairs(TILES) do TILE_BY_KEY[t.key] = t end
SimBuffs.TILES = TILES

SimBuffs.SECTIONS = {
  { key = "group", title = "YOUR GROUP", hint = "party-only buffs" },
  { key = "raid", title = "THE RAID", hint = "everyone" },
  { key = "boss", title = "THE BOSS", hint = "debuffs" },
  { key = "mine", title = "YOU BRING", hint = "consumables" },
}

local MANA = { PALADIN = true, HUNTER = true, SHAMAN = true, MAGE = true, PRIEST = true, WARLOCK = true, DRUID = true }

function SimBuffs:GetTile(key) return TILE_BY_KEY[key] end

-- The tiles that matter for a class (classFile), in display order.
function SimBuffs:Tiles(classFile, sec)
  local out = {}
  for _, t in ipairs(TILES) do
    if (not sec or t.sec == sec) and (not t.mana or MANA[classFile]) and (not t.only or t.only[classFile]) then
      out[#out + 1] = t
    end
  end
  return out
end

-- How many states a tile has, and the name of state v.
function SimBuffs:StateCount(t)
  if t.states then return #t.states end
  if t.kind == "tri" then return 3 end
  if t.kind == "count" then return 4 end
  return 2
end

function SimBuffs:StateText(t, v)
  if t.states then return t.states[v + 1] end
  if t.kind == "tri" then return TRI[v + 1] end
  if t.kind == "count" then return v == 0 and "Off" or (v == 1 and "On" or ("x" .. v)) end
  return v > 0 and "On" or "Off"
end

local function Section(c, name)
  c[name] = c[name] or {}
  return c[name]
end

-- A tile's state in a buff config (0 = off).
function SimBuffs:Get(c, t)
  if type(t) == "string" then t = TILE_BY_KEY[t] end
  for _, s in ipairs({ "raid", "party", "individual", "debuffs", "consumables" }) do Section(c, s) end
  if t.get then return t.get(c) end
  local v = c[t.path[1]][t.path[2]]
  if t.value then return v == t.value and 1 or 0 end
  if t.kind == "tri" then
    if v == true then return 1 end
    return type(v) == "number" and min(v, 2) or 0
  end
  if t.kind == "count" then return type(v) == "number" and min(v, 3) or 0 end
  return v and 1 or 0
end

function SimBuffs:Set(c, t, v)
  if type(t) == "string" then t = TILE_BY_KEY[t] end
  for _, s in ipairs({ "raid", "party", "individual", "debuffs", "consumables" }) do Section(c, s) end
  if t.set then return t.set(c, v) end
  local sec = c[t.path[1]]
  if t.value then sec[t.path[2]] = v > 0 and t.value or nil
  elseif t.kind == "tri" or t.kind == "count" then sec[t.path[2]] = v > 0 and v or nil
  else sec[t.path[2]] = v > 0 or nil end
end

-- The next state on a click (right-click: the one before).
function SimBuffs:NextState(t, v, back)
  local n = self:StateCount(t)
  if back then return (v - 1) % n end
  return (v + 1) % n
end

local function DeepCopy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = DeepCopy(x) end
  return out
end
SimBuffs.Copy = DeepCopy

-- A clean copy of a config: only the sections the sim reads; Grace of Air twists when Windfury is down too and one
-- shaman drops both (set by the team rules; a preset keeps its own).
function SimBuffs:Normalize(c)
  c = DeepCopy(type(c) == "table" and c or {})
  for _, s in ipairs({ "raid", "party", "individual", "debuffs", "consumables" }) do
    if type(c[s]) ~= "table" then c[s] = {} end
  end
  return c
end

-- ---------------------------------------------------------------------------------------------------------------
-- Saved: presets (account-wide) and the overrides on team lineups
-- ---------------------------------------------------------------------------------------------------------------
local function Store(path, create)
  local DB = ns.DB
  if not DB then return nil end
  local t = DB:GetSetting(path)
  if type(t) ~= "table" then
    if not create then return nil end
    DB:SetSetting(path, {})
    t = DB:GetSetting(path)
  end
  return t
end

SimBuffs.MAX_PRESETS = 30
SimBuffs.MAX_NAME = 32

-- My presets, sorted by name: { { id, key = "p:<id>", name, cfg }, ... } (cfg: the saved table; copy before changing).
function SimBuffs:GetPresets()
  local out = {}
  for id, p in pairs(Store("sim.presets") or {}) do
    if type(p) == "table" and type(p.name) == "string" and type(p.cfg) == "table" then
      out[#out + 1] = { id = id, key = "p:" .. id, name = p.name, cfg = p.cfg }
    end
  end
  tsort(out, function(a, b)
    local la, lb = a.name:lower(), b.name:lower()
    if la ~= lb then return la < lb end
    return a.id < b.id
  end)
  return out
end

function SimBuffs:GetPreset(id)
  local p = (Store("sim.presets") or {})[id]
  if type(p) ~= "table" or type(p.cfg) ~= "table" then return nil end
  return { id = id, key = "p:" .. id, name = p.name, cfg = p.cfg }
end

local function CleanName(name)
  name = tostring(name or ""):gsub("|", ""):gsub("^%s+", ""):gsub("%s+$", "")
  if #name > SimBuffs.MAX_NAME then name = name:sub(1, SimBuffs.MAX_NAME) end
  return name
end

-- Saves a preset (id nil: a new one). Returns its id, or nil and why.
function SimBuffs:SavePreset(id, name, cfg)
  name = CleanName(name)
  if name == "" then return nil, "Give the preset a name." end
  local store = Store("sim.presets", true)
  if not store then return nil, "Nothing to save to." end
  if not (id and store[id]) then
    local n = 0
    for _ in pairs(store) do n = n + 1 end
    if n >= self.MAX_PRESETS then return nil, ("You have %d presets; delete one first."):format(n) end
    local i = n + 1
    while store["b" .. i] do i = i + 1 end
    id = "b" .. i
  end
  store[id] = { name = name, cfg = self:Normalize(cfg), at = time and time() or 0 }
  return id
end

function SimBuffs:DeletePreset(id)
  local store = Store("sim.presets")
  if store then store[id] = nil end
end

local function TeamKey(teamId, ln) return tostring(teamId) .. ":" .. tostring(ln or "") end

-- A team lineup's saved choices: { open = bool (count the comp's open slots as filled; default on), ov = { [tile] =
-- state } (your clicks) } (a copy).
function SimBuffs:GetTeamState(teamId, ln)
  local s = (Store("sim.teams") or {})[TeamKey(teamId, ln)]
  local ov = {}
  if type(s) == "table" and type(s.ov) == "table" then
    for k, v in pairs(s.ov) do if TILE_BY_KEY[k] and type(v) == "number" then ov[k] = v end end
  end
  return { open = not (type(s) == "table" and s.open == false), ov = ov }
end

function SimBuffs:SaveTeamState(teamId, ln, st)
  local store = Store("sim.teams", true)
  if not store then return end
  local ov = {}
  for k, v in pairs(st and st.ov or {}) do if TILE_BY_KEY[k] then ov[k] = v end end
  if (st == nil or st.open ~= false) and next(ov) == nil then
    store[TeamKey(teamId, ln)] = nil
  else
    store[TeamKey(teamId, ln)] = { open = st.open ~= false, ov = ov }
  end
end

-- ---------------------------------------------------------------------------------------------------------------
-- Teams: who is placed, and what they bring
-- ---------------------------------------------------------------------------------------------------------------
local function RP() return ns.RaidPlan end
local function Comp() return ns.RaidComp end
local function Me() return ns.Util and ns.Util.PlayerKey and ns.Util.PlayerKey() or nil end

-- "Disaster Crew · 25-man", "Disaster Crew · Kara A".
function SimBuffs:LineupLabel(team, l)
  return (team.name or "?") .. " \194\183 " .. (RP():LineupName(team, l) or "?")
end

-- The lineups of the teams I am on (my character on the roster), by team name then lineup order:
-- { { key = "t:<team>:<lineup>", teamId, ln, name, group = my group | nil, open = open comp slots, size }, ... }.
function SimBuffs:MyLineups()
  local out = {}
  local plan = RP()
  local me = Me()
  if not (plan and plan.GetTeams and me) then return out end
  for _, team in ipairs(plan:GetTeams()) do
    local on = false
    for _, k in ipairs(team.members or {}) do if k == me then on = true end end
    if on then
      for _, l in ipairs(team.lineups or {}) do
        local g = l.groups and l.groups[me]
        local nGroups = Comp():GroupCount(l.size)
        if not (type(g) == "number" and g >= 1 and g <= nGroups) then g = nil end
        local _, open = plan:GetTeamOpenSlots({ id = team.id, ln = l.id })
        out[#out + 1] = { key = "t:" .. team.id .. ":" .. l.id, teamId = team.id, ln = l.id,
          name = self:LineupLabel(team, l), group = g, open = open or 0, size = l.size }
      end
    end
  end
  return out
end

local function SpecLabel(m) return m.c and m.sp and Comp():SpecLabel(m.c, m.sp) or nil end

local function Is(m, classFile, ...)
  if m.c ~= classFile then return false end
  local n = select("#", ...)
  if n == 0 then return true end
  local label = SpecLabel(m)
  for i = 1, n do if select(i, ...) == label then return true end end
  return false
end

local function Filter(list, fn)
  local out = {}
  for _, m in ipairs(list) do if fn(m) then out[#out + 1] = m end end
  return out
end

local function Any(list, fn)
  for _, m in ipairs(list) do if fn(m) then return true end end
  return false
end

-- What the people placed bring. ctx = { party = my group's others, raid = everyone else, all = everyone with me,
-- me = { c, sp }, partyAll = my group with me }. Returns { [tile] = { v = state, who = { member, ... } } }.
local function Infer(ctx, classFile)
  local res = {}
  local function put(key, v, who) res[key] = { v = v, who = who or {} } end
  local party, raid = ctx.party, ctx.raid

  -- your group: the shamans' totems follow the group (RaidComp:AirTotem); one shaman twists Windfury and Grace of Air
  local sh = Filter(party, function(m) return m.c == "SHAMAN" end)
  local enh = Any(sh, function(m) return Is(m, "SHAMAN", "Enhancement") end)
  local air = #sh > 0 and Comp():AirTotem(ctx.partyAll) or nil
  local wf = #sh > 0 and air ~= "wrathofair"
  put("windfury", wf and (enh and 2 or 1) or 0, wf and sh or nil)
  put("graceofair", wf and (enh and 2 or 1) or 0, wf and sh or nil)
  put("strengthofearth", #sh > 0 and (enh and 2 or 1) or 0, sh)
  local resto = Any(sh, function(m) return Is(m, "SHAMAN", "Restoration") end)
  put("manaspring", #sh > 0 and (resto and 2 or 1) or 0, sh)
  local ur = Filter(party, function(m) return Is(m, "SHAMAN", "Enhancement") end)
  put("unleashedrage", #ur > 0 and 1 or 0, ur)
  local war = Filter(party, function(m) return m.c == "WARRIOR" end)
  local impBs = Any(war, function(m) return Is(m, "WARRIOR", "Fury", "Arms") end)
  put("battleshout", #war > 0 and (impBs and 2 or 1) or 0, war)
  local feral = Filter(party, function(m) return Is(m, "DRUID", "Feral (Cat)", "Feral (Bear)") end)
  put("lotp", #feral > 0 and 2 or 0, feral)
  local bm = Filter(party, function(m) return Is(m, "HUNTER", "Beast Mastery") end)
  put("ferocious", min(#bm, 3), bm)
  local mm = Filter(party, function(m) return Is(m, "HUNTER", "Marksmanship") end)
  put("trueshot", #mm > 0 and 1 or 0, mm)
  local lw = Filter(party, function(m) return m.lw end)
  put("drums", #lw > 0 and 1 or 0, lw)

  -- the raid
  local shr = Filter(raid, function(m) return m.c == "SHAMAN" end)
  put("bloodlust", #shr > 0 and 1 or 0, shr)
  -- one Greater Blessing per paladin (you bless too): Kings, then Might, then Wisdom for a class with mana; Might
  -- goes to a Retribution paladin first (improved), Wisdom to a Holy one (improved)
  local pals = Filter(ctx.all, function(m) return m.c == "PALADIN" end)
  local taken = {}
  local function pick(pref)
    for _, m in ipairs(pals) do if not taken[m] and pref(m) then taken[m] = true; return m end end
    for _, m in ipairs(pals) do if not taken[m] then taken[m] = true; return m end end
  end
  local mightBy = #pals >= 2 and pick(function(m) return Is(m, "PALADIN", "Retribution") end) or nil
  local wisBy = (#pals >= 3 and MANA[classFile]) and pick(function(m) return Is(m, "PALADIN", "Holy") end) or nil
  local kingsBy = #pals >= 1 and pick(function(m) return Is(m, "PALADIN", "Protection", "Holy") end) or nil
  put("kings", kingsBy and 1 or 0, { kingsBy })
  put("might", mightBy and (Is(mightBy, "PALADIN", "Retribution") and 2 or 1) or 0, { mightBy })
  put("wisdom", wisBy and (Is(wisBy, "PALADIN", "Holy") and 2 or 1) or 0, { wisBy })
  local dru = Filter(raid, function(m) return m.c == "DRUID" end)
  put("gotw", #dru > 0 and (Any(dru, function(m) return Is(m, "DRUID", "Restoration") end) and 2 or 1) or 0, dru)
  local pri = Filter(raid, function(m) return m.c == "PRIEST" end)
  put("fortitude", #pri > 0 and (Any(pri, function(m) return Is(m, "PRIEST", "Discipline", "Holy") end) and 2 or 1) or 0, pri)
  local mages = Filter(raid, function(m) return m.c == "MAGE" end)
  put("arcaneint", #mages > 0 and 1 or 0, mages)
  local disc = Filter(raid, function(m) return Is(m, "PRIEST", "Discipline") end)
  put("divinespirit", #disc > 0 and 2 or 0, disc)

  -- the boss
  local wr = Filter(raid, function(m) return m.c == "WARRIOR" end)
  put("sunder", #wr > 0 and 1 or 0, wr)
  local rog = Filter(raid, function(m) return m.c == "ROGUE" end)
  put("exposearmor", #rog > 0 and 2 or 0, rog)
  local ff = Filter(raid, function(m) return Is(m, "DRUID", "Balance", "Feral (Cat)", "Feral (Bear)") end)
  put("faeriefire", #ff > 0 and (Any(ff, function(m) return Is(m, "DRUID", "Balance") end) and 2 or 1) or 0, ff)
  -- one curse per warlock: Elements first, Recklessness from the second
  local wl = Filter(raid, function(m) return m.c == "WARLOCK" end)
  local aff = Any(wl, function(m) return Is(m, "WARLOCK", "Affliction") end)
  if MANA[classFile] then
    put("elements", #wl > 0 and (aff and 2 or 1) or 0, { wl[1] })
    put("recklessness", #wl > 1 and 1 or 0, { wl[2] })
  else
    put("recklessness", #wl > 0 and 1 or 0, { wl[1] })
    put("elements", 0, {})
  end
  local arms = Filter(raid, function(m) return Is(m, "WARRIOR", "Arms") end)
  put("bloodfrenzy", #arms > 0 and 1 or 0, arms)
  local mangle = Filter(raid, function(m) return Is(m, "DRUID", "Feral (Cat)", "Feral (Bear)") end)
  put("mangle", #mangle > 0 and 1 or 0, mangle)
  local sp = Filter(raid, function(m) return Is(m, "PRIEST", "Shadow") end)
  put("misery", #sp > 0 and 1 or 0, sp)
  local hun = Filter(raid, function(m) return m.c == "HUNTER" end)
  put("huntersmark", #hun > 0 and (Any(hun, function(m) return Is(m, "HUNTER", "Beast Mastery", "Marksmanship") end) and 2 or 1) or 0, hun)
  local sv = Filter(raid, function(m) return Is(m, "HUNTER", "Survival") end)
  put("exposeweakness", #sv > 0 and 1 or 0, sv)
  -- other paladins judge: Wisdom from one, the Crusader (improved) from a second
  local opals = Filter(raid, function(m) return m.c == "PALADIN" end)
  put("jow", #opals > 0 and 1 or 0, { opals[1] })
  put("jotc", #opals > 1 and 2 or 0, { opals[2] })
  return res
end
SimBuffs._Infer = Infer

-- The people a lineup counts: { key, c, sp, g = group, open = true for a comp slot, lw = leatherworker }. Open slots
-- go into groups as the Teams page places them (RaidComp:PlaceOpen). Returns members, info { group, openCount, size }.
function SimBuffs:LineupMembers(teamId, ln, withOpen)
  local plan, C = RP(), Comp()
  local t = plan:ResolveTeam({ id = teamId, ln = ln })
  if not t then return nil end
  local me = Me()
  local nGroups = C:GroupCount(t.size)
  local Prof = ns.Professions
  local out, byGroup = {}, {}
  local myGroup
  for _, m in ipairs(plan:GetTeamMembers(t)) do
    local g = t.groups[m.key]
    if m.key == me then myGroup = m.seated and g or nil end
    if m.seated and m.key ~= me then
      local lw = false
      local profs = Prof and Prof.GetMember and Prof:GetMember(m.key)
      for _, p in ipairs(profs or {}) do if p.id == 165 and (p.rank or 0) >= 350 then lw = true end end
      local e = { key = m.key, c = m.c, sp = m.sp, g = g, lw = lw }
      out[#out + 1] = e
      byGroup[g] = byGroup[g] or {}
      byGroup[g][#byGroup[g] + 1] = e
    end
  end
  local open, openCount = plan:GetTeamOpenSlots(t)
  if withOpen and openCount > 0 then
    -- the placed players (me included) decide where the open slots sit
    local seats = {}
    for g, l in pairs(byGroup) do seats[g] = l end
    if myGroup then
      seats[myGroup] = seats[myGroup] or {}
      local copy = {}
      for _, e in ipairs(seats[myGroup]) do copy[#copy + 1] = e end
      local _, myClass = UnitClass("player")
      copy[#copy + 1] = { c = myClass, sp = ns.SimBuffs:MySpecIndex() }
      seats[myGroup] = copy
    end
    local slots = {}
    for _, o in ipairs(open) do
      for _ = 1, o.n or 1 do slots[#slots + 1] = { c = o.c, sp = o.sp, name = o.name } end
    end
    local placed = C:PlaceOpen(seats, slots, nGroups)
    for g, l in pairs(placed) do
      for i, s in ipairs(l) do
        out[#out + 1] = { key = "open:" .. g .. ":" .. i, c = s.c, sp = s.sp, g = g, open = true, name = s.name }
      end
    end
  end
  return out, { group = myGroup, openCount = openCount or 0, size = t.size, nGroups = nGroups }
end

-- My spec index as the sim plays it (the My BiS list's spec), for the group's air totem and open-slot seating.
function SimBuffs:MySpecIndex()
  local R = ns.SimRunner
  local label = R and R.Spec and R:Spec() or nil
  local _, cls = UnitClass("player")
  for i, s in ipairs(ns.SPECS[cls or ""] or {}) do if s.label == label then return i end end
  return nil
end

-- A lineup's buff config for a class: what you bring from the class's 25-man preset, the rest from who is placed
-- (and the open slots when st.open), your overrides on top. Returns cfg, info { group, openCount, size,
-- tiles = { [tile] = { v, who, inferred, changed } } } or nil (an unknown lineup).
function SimBuffs:TeamConfig(teamId, ln, st, classFile, base)
  st = st or self:GetTeamState(teamId, ln)
  local members, info = self:LineupMembers(teamId, ln, st.open ~= false)
  if not members then return nil end
  local me = { c = classFile, sp = self:MySpecIndex(), key = Me() }
  local party, partyAll, all = {}, { me }, { me }
  for _, m in ipairs(members) do
    all[#all + 1] = m
    if info.group and m.g == info.group then party[#party + 1] = m; partyAll[#partyAll + 1] = m end
  end
  local ctx = { party = party, partyAll = partyAll, raid = members, all = all, me = me }
  local inferred = Infer(ctx, classFile)
  local cfg = self:Normalize({ consumables = DeepCopy(base and base.consumables or {}) })
  info.tiles = {}
  for _, t in ipairs(TILES) do
    if t.sec ~= "mine" then
      local r = inferred[t.key] or { v = 0, who = {} }
      local v = r.v
      if t.noInfer then v = 0 end
      local ov = st.ov[t.key]
      if ov ~= nil then v = ov end
      self:Set(cfg, t, v)
      info.tiles[t.key] = { v = v, who = r.who, inferred = t.noInfer and 0 or r.v, changed = ov ~= nil and ov ~= r.v }
    else
      local ov = st.ov[t.key]
      if ov ~= nil then self:Set(cfg, t, ov) end
      local v = self:Get(cfg, t)
      info.tiles[t.key] = { v = v, who = {}, changed = ov ~= nil }
    end
  end
  -- one shaman in the group drops both air totems in turn (WoWSims' totem twisting)
  local shamans = 0
  for _, m in ipairs(party) do if m.c == "SHAMAN" then shamans = shamans + 1 end end
  if self:Get(cfg, "windfury") > 0 and self:Get(cfg, "graceofair") > 0 and shamans <= 1 then cfg.party.totemTwisting = true end
  return cfg, info
end

-- ---------------------------------------------------------------------------------------------------------------
-- Keys
-- ---------------------------------------------------------------------------------------------------------------
function SimBuffs:ParseKey(key)
  if type(key) ~= "string" then return nil end
  local id = key:match("^p:(.+)$")
  if id then return "preset", id end
  local team, ln = key:match("^t:([^:]+):(.+)$")
  if team then return "team", team, ln end
  return nil
end

-- The buff config of a key of mine ("p:" / "t:"): cfg, info, name; nil when it is gone (deleted preset, a team I
-- left). base: the class's 25-man config (what you bring in a team lineup).
function SimBuffs:Resolve(key, classFile, base)
  local kind, a, b = self:ParseKey(key)
  if kind == "preset" then
    local p = self:GetPreset(a)
    if not p then return nil end
    return self:Normalize(p.cfg), nil, p.name
  elseif kind == "team" then
    local plan = RP()
    local team = plan and plan:GetTeam(a)
    local l = team and plan:FindLineup(team, b)
    if not l then return nil end
    local me = Me()
    local on = false
    for _, k in ipairs(team.members or {}) do if k == me then on = true end end
    if not on then return nil end
    local cfg, info = self:TeamConfig(a, b, nil, classFile, base)
    if not cfg then return nil end
    return cfg, info, self:LineupLabel(team, l)
  end
  return nil
end

-- A short line naming who brings a tile in a team lineup: "Kaelith, Tidecall", "open slot · Feral Druid".
function SimBuffs:WhoText(who, max)
  local names = {}
  max = max or 2
  local U = ns.Util
  for i, m in ipairs(who or {}) do
    if i > max then
      names[#names + 1] = "+" .. (#who - max)
      break
    end
    if m.open then
      names[#names + 1] = "|cffe2b33eopen slot \194\183 " .. (m.name or "?") .. "|r"
    else
      local name = U and U.DisplayName and U.DisplayName(m.key) or tostring(m.key)
      local hex = U and U.ClassColorHex and m.c and U.ClassColorHex(m.c)
      names[#names + 1] = hex and ("|c" .. hex .. name .. "|r") or name
    end
  end
  return tconcat(names, ", ")
end
