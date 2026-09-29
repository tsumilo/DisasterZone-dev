-- CDLoot Games/Azeromon/Achievements.lua
-- ns.AzeroAch: Azeromon achievements, fed by the game's event feed (G:On / G:Emit, see Game.lua).
--
-- Adding an achievement = one entry in ACHIEVEMENTS below:
--   { id, name, desc, icon, points,
--     on = "event" or { "event", ... },          -- when to check (feed events; "load" re-checks on a loaded save)
--     test = function(G, e, A) return bool end,   -- earned now?
--     progress = function(G, A) return cur, max end }   -- optional, shown on the Achievements page
-- Earned achievements and lifetime stats live in CDLootDB.games.azeromon (they survive a new game, like WoW's).
-- The toast copies Blizzard's achievement alert (its artwork ships with this client) and plays the achievement
-- jingle (sound kit 12891), falling back to the loot-toast sound.
local addonName, ns = ...

local A = ns:NewModule("AzeroAch")
local G = ns.Azero
local D = ns.AzeroData

local ICON = "Interface\\Icons\\"

---------------------------------------------------------------------------
-- Helpers for tests
---------------------------------------------------------------------------

function A.Stat(key) return (A.Stats()[key]) or 0 end

function A.BestSkill(g)
    local best = 0
    local p = g.save and g.save.prof
    if type(p) == "table" then for _, v in pairs(p) do best = math.max(best, tonumber(v) or 0) end end
    return best
end

function A.TradePartners(g)
    local n = 0
    local t = g:Data().trades
    if type(t) == "table" then for _ in pairs(t) do n = n + 1 end end
    return n
end

function A.TamedCount(g)
    local n = 0
    for sp in pairs(g.save and g.save.caught or {}) do if D.species[sp] then n = n + 1 end end
    return n
end

-- how many of `list` (species ids) have been tamed
function A.TamedOf(g, list)
    local n = 0
    for _, sp in ipairs(list) do if g.save and g.save.caught[sp] then n = n + 1 end end
    return n
end

function A.UsedType(e, typeId)
    for _, sp in ipairs(e.used or {}) do
        local s = D.species[sp]
        if s and s.type == typeId then return true end
    end
    return false
end

local ELWYNN = { "wolfpup", "webling", "kobling", "owlet", "tuskling" }
A.DM_BOSSES = { "rhahkzor", "sneed", "gilnid", "smite", "greenskin", "cookie", "vancleef" }
local WESTFALL = { "coyote", "fleshripper", "rustgolem", "dustdevil", "crawler", "coastrunner" }
A.ELWYNN, A.WESTFALL = ELWYNN, WESTFALL

local function MaxLevel(g)
    local best = 0
    for _, list in ipairs({ g.save and g.save.party or {}, g.save and g.save.box or {} }) do
        for _, mon in ipairs(list) do if mon.lvl > best then best = mon.lvl end end
    end
    return best
end

---------------------------------------------------------------------------
-- The achievements
---------------------------------------------------------------------------

local ACHIEVEMENTS = {
    -- taming
    { id = "tame1", name = "Beast Friend", points = 10, icon = "Ability_Hunter_BeastTaming",
      desc = "Tame a wild beast with a Taming Rod.",
      on = { "tame", "load" }, test = function(g, e) return A.Stat("caught") >= 1 end,
      progress = function() return math.min(1, A.Stat("caught")), 1 end },
    { id = "tame10", name = "Tamer", points = 10, icon = "Ability_Hunter_BeastCall",
      desc = "Tame 10 different kinds of beast.",
      on = { "tame", "evolve", "load" }, test = function(g) return A.TamedCount(g) >= 10 end,
      progress = function(g) return math.min(10, A.TamedCount(g)), 10 end },
    { id = "tame20", name = "Master Tamer", points = 25, icon = "Ability_Hunter_BeastWithin",
      desc = "Tame 20 different kinds of beast.",
      on = { "tame", "evolve", "load" }, test = function(g) return A.TamedCount(g) >= 20 end,
      progress = function(g) return math.min(20, A.TamedCount(g)), 20 end },
    { id = "elwynn", name = "Elwynn Naturalist", points = 10, icon = "Ability_Hunter_Pet_Wolf",
      desc = "Tame every wild beast of Elwynn Forest.",
      on = { "tame", "load" }, test = function(g) return A.TamedOf(g, ELWYNN) == #ELWYNN end,
      progress = function(g) return A.TamedOf(g, ELWYNN), #ELWYNN end },
    { id = "westfall", name = "Westfall Naturalist", points = 10, icon = "Ability_Hunter_Pet_Vulture",
      desc = "Tame every wild beast of Westfall.",
      on = { "tame", "load" }, test = function(g) return A.TamedOf(g, WESTFALL) == #WESTFALL end,
      progress = function(g) return A.TamedOf(g, WESTFALL), #WESTFALL end },

    -- professions
    { id = "gather1", name = "Gatherer", points = 10, icon = "INV_Misc_Flower_02",
      desc = "Pick a herb or mine an ore vein.",
      on = "gather", test = function() return true end },
    { id = "craft1", name = "Handiwork", points = 10, icon = "Trade_BlackSmithing",
      desc = "Craft something.",
      on = "craft", test = function() return true end },
    { id = "geared", name = "Well Equipped", points = 10, icon = "INV_Chest_Chain",
      desc = "Put crafted gear on one of your beasts.",
      on = "equip", test = function() return true end },
    { id = "skill50", name = "Journeyman", points = 10, icon = "INV_Misc_Book_08",
      desc = "Reach 50 skill in a profession.",
      on = { "skillup", "load" }, test = function(g) return A.BestSkill(g) >= 50 end,
      progress = function(g) return math.min(50, A.BestSkill(g)), 50 end },
    { id = "skill100", name = "Artisan", points = 25, icon = "INV_Misc_Book_11",
      desc = "Reach 100 skill in a profession.",
      on = { "skillup", "load" }, test = function(g) return A.BestSkill(g) >= 100 end,
      progress = function(g) return math.min(100, A.BestSkill(g)), 100 end },

    -- the Gurubashi Arena
    { id = "arena5", name = "Gladiator", points = 10, icon = "Ability_Warrior_Rampage",
      desc = "Win 5 fights in a row in the Gurubashi Arena.",
      on = { "arena", "load" }, test = function(g) return (tonumber(g:Data().arenaBest) or 0) >= 5 end },
    { id = "arena10", name = "Arena Champion", points = 25, icon = "Spell_Holy_SealOfMight",
      desc = "Win 10 fights in a row in the Gurubashi Arena.",
      on = { "arena", "load" }, test = function(g) return (tonumber(g:Data().arenaBest) or 0) >= 10 end,
      progress = function(g) return math.min(10, tonumber(g:Data().arenaBest) or 0), 10 end },

    -- rematches
    { id = "rematch1", name = "Old Rivals", points = 10, icon = "Ability_Warrior_Challange",
      desc = "Win a rematch against a trainer.",
      on = "rematch", test = function() return true end },

    -- trading
    { id = "trade1", name = "Trading Partners", points = 10, icon = "INV_Misc_Coin_02",
      desc = "Trade a beast with a guildmate.",
      on = "trade", test = function() return true end },
    { id = "trade5", name = "Well Connected", points = 25, icon = "INV_Letter_15",
      desc = "Trade with 5 different guildmates.",
      on = { "trade", "load" }, test = function(g) return A.TradePartners(g) >= 5 end,
      progress = function(g) return math.min(5, A.TradePartners(g)), 5 end },

    -- the bounty board
    { id = "bounty1", name = "Bounty Hunter", points = 10, icon = "INV_Misc_Note_01",
      desc = "Complete a daily bounty.",
      on = "bounty", test = function() return true end },
    { id = "bounty25", name = "Most Wanted", points = 25, icon = "INV_Misc_Note_02",
      desc = "Complete 25 daily bounties.",
      on = { "bounty", "load" }, test = function() return A.Stat("bounties") >= 25 end,
      progress = function() return math.min(25, A.Stat("bounties")), 25 end },
    { id = "guildgold", name = "Stronger Together", points = 25, icon = "INV_Shirt_GuildTabard_01",
      desc = "Help the guild reach Gold in a weekly goal.",
      on = "guildtier", test = function(g, e) return (e.tier or 0) >= 3 end },

    -- shinies
    { id = "shinyseen", name = "Something Glimmers", points = 10, icon = "INV_Enchant_ShardBrilliantSmall",
      desc = "Meet a shiny beast in the wild.",
      on = "shiny", test = function() return true end },
    { id = "shinytame", name = "Shiny!", points = 25, icon = "INV_Misc_Gem_Diamond_02",
      desc = "Tame a shiny beast.",
      on = { "tame", "load" }, test = function() return A.Stat("shinies") >= 1 end },

    -- growth
    { id = "evolve", name = "Metamorphosis", points = 10, icon = "Spell_Nature_Polymorph",
      desc = "Watch one of your beasts evolve.",
      on = "evolve", test = function() return true end },
    { id = "lvl20", name = "Seasoned", points = 10, icon = "Spell_Holy_BlessingOfStamina",
      desc = "Raise a beast to level 20.",
      on = { "level", "load" }, test = function(g) return MaxLevel(g) >= 20 end,
      progress = function(g) return math.min(20, MaxLevel(g)), 20 end },
    { id = "lvl30", name = "Veteran", points = 10, icon = "Spell_Holy_BlessingOfStrength",
      desc = "Raise a beast to level 30.",
      on = { "level", "load" }, test = function(g) return MaxLevel(g) >= 30 end,
      progress = function(g) return math.min(30, MaxLevel(g)), 30 end },

    -- story and trainers
    { id = "rival", name = "Sibling Rivalry", points = 10, icon = "Ability_DualWield",
      desc = "Defeat Vera in your very first battle.",
      on = "battle", test = function(g, e) return e.trainer == "rival1" and e.result == "win" end },
    { id = "hogger", name = "Hogwash", points = 10, icon = "INV_Misc_Head_Gnoll_01",
      desc = "Defeat Hogger and earn Hogger's Claw.",
      on = { "badge", "load" }, test = function(g) return g:Flag("badge_hogger") and true or false end },
    { id = "hoggernofire", name = "No Fire Needed", points = 25, icon = "Spell_Fire_Fire",
      desc = "Defeat Hogger without a Fire-type beast fighting.",
      on = "battle", test = function(g, e) return e.trainer == "hogger" and e.result == "win" and not A.UsedType(e, "FIRE") end },
    { id = "hoggersolo", name = "One Beast Army", points = 25, icon = "Ability_Warrior_Rampage",
      desc = "Defeat Hogger using only one beast.",
      on = "battle", test = function(g, e) return e.trainer == "hogger" and e.result == "win" and #(e.used or {}) == 1 end },
    { id = "militia", name = "Friend of the Militia", points = 10, icon = "INV_Misc_Bandana_03",
      desc = "Defeat Militia Sergeant Dane on the road to Sentinel Hill.",
      on = "battle", test = function(g, e) return e.trainer == "militia1" and e.result == "win" end },
    { id = "trainers10", name = "Challenger", points = 10, icon = "INV_Sword_27",
      desc = "Win 10 battles against trainers.",
      on = { "battle", "load" }, test = function() return A.Stat("trainersWon") >= 10 end,
      progress = function() return math.min(10, A.Stat("trainersWon")), 10 end },
    { id = "wild50", name = "Pest Control", points = 10, icon = "Ability_Hunter_SniperShot",
      desc = "Defeat 50 wild beasts.",
      on = { "battle", "load" }, test = function() return A.Stat("wildWon") >= 50 end,
      progress = function() return math.min(50, A.Stat("wildWon")), 50 end },
    { id = "closecall", name = "Close Call", points = 10, icon = "Spell_Holy_Heal",
      desc = "Win a battle with only one beast left standing, below 10% health.",
      on = "battle", test = function(g, e)
          local m = e.lastStanding
          return e.result == "win" and m ~= nil and m.hp > 0 and m.hp / ns.AzeroMon.MaxHP(m) < 0.1
      end },

    -- players
    { id = "pvp1", name = "Guild Duelist", points = 10, icon = "Ability_Parry",
      desc = "Win a battle against a guildmate.",
      on = { "pvp", "load" }, test = function() return A.Stat("pvpWon") >= 1 end },
    { id = "pvp5", name = "Guild Champion", points = 25, icon = "INV_BannerPVP_02",
      desc = "Win 5 battles against guildmates.",
      on = { "pvp", "load" }, test = function() return A.Stat("pvpWon") >= 5 end,
      progress = function() return math.min(5, A.Stat("pvpWon")), 5 end },

    -- rares, night, raids
    { id = "rare1", name = "Rare Find", points = 10, icon = "INV_Misc_Gem_Pearl_04",
      desc = "Tame a rare beast.",
      on = "tame", test = function(g, e) return e.how == "caught" and D.species[e.mon.sp] and D.species[e.mon.sp].rare end },
    { id = "nightowl", name = "Night Owl", points = 10, icon = "Spell_Nature_Starfall",
      desc = "Tame 3 beasts after dark (realm time).",
      on = { "tame", "load" }, test = function() return A.Stat("nightTames") >= 3 end,
      progress = function() return math.min(3, A.Stat("nightTames")), 3 end },
    { id = "raidscout", name = "Word Travels Fast", points = 10, icon = "INV_Misc_Note_02",
      desc = "Kill a raid boss that sets a rare beast loose in Azeromon.",
      on = "raidkill", test = function() return true end },
    { id = "raidrare", name = "Raid Trophy", points = 25, icon = "INV_Misc_Head_Dragon_Black",
      desc = "Tame a beast set loose by a raid boss kill.",
      on = "tame", test = function(g, e)
          if e.how ~= "caught" then return false end
          for _, r in ipairs(D.raidRares) do if r.sp == e.mon.sp then return true end end
          return false
      end },

    -- the Deadmines
    { id = "vancleef", name = "The Deadmines", points = 25, icon = "INV_Misc_Bandana_03",
      desc = "Defeat Edwin VanCleef and earn his bandana.",
      on = { "badge", "load" }, test = function(g) return g:Flag("badge_vancleef") and true or false end },
    { id = "dmbosses", name = "Brotherhood Broken", points = 25, icon = "INV_Sword_33",
      desc = "Defeat every boss of the Deadmines: Rhahk'Zor, Sneed, Gilnid, Mr. Smite, Captain Greenskin, Cookie and VanCleef.",
      on = { "beaten", "load" }, test = function(g)
          for _, id in ipairs(A.DM_BOSSES) do if not g:Flag("beat_" .. id) then return false end end
          return true
      end,
      progress = function(g)
          local n = 0
          for _, id in ipairs(A.DM_BOSSES) do if g:Flag("beat_" .. id) then n = n + 1 end end
          return n, #A.DM_BOSSES
      end },
    { id = "shredder", name = "Some Assembly Required", points = 10, icon = "INV_Misc_Gear_03",
      desc = "Tame a Goblin Shredder.",
      on = "tame", test = function(g, e) return e.how == "caught" and e.mon.sp == "shredder" end },

    -- the Bestiary and the guild
    { id = "bestiary", name = "Collector", points = 50, icon = "INV_Misc_Book_09",
      desc = "Complete the Bestiary: tame every beast that is not a rare.",
      on = { "bestiary", "load" }, test = function(g) return g:Data().bestiaryDone ~= nil end,
      progress = function(g)
          local ids = ns.AzeroGuild.CompletableIds()
          return A.TamedOf(g, ids), #ids
      end },
    { id = "guildfirst", name = "First in the Guild", points = 25, icon = "INV_Misc_Book_11",
      desc = "Be the first player in your guild known to complete the Bestiary.",
      on = "bestiary", test = function(g, e)
          local first = ns.AzeroGuild:FirstComplete()
          return first ~= nil and first.me == true
      end },

    -- odds and ends
    { id = "chests", name = "Treasure Hunter", points = 10, icon = "INV_Box_02",
      desc = "Open 4 treasure chests.",
      on = { "chest", "load" }, test = function() return A.Stat("chests") >= 4 end,
      progress = function() return math.min(4, A.Stat("chests")), 4 end },
    { id = "blackout", name = "Not Prepared", points = 5, icon = "Spell_Shadow_DeathScream",
      desc = "Black out. It happens to the best of us.",
      on = "blackout", test = function() return true end },
}
A.list = ACHIEVEMENTS
A.byId = {}
for _, a in ipairs(ACHIEVEMENTS) do
    a.icon = a.icon:find("\\", 1, true) and a.icon or (ICON .. a.icon)
    if type(a.on) == "string" then a.on = { a.on } end
    A.byId[a.id] = a
end

---------------------------------------------------------------------------
-- Storage
---------------------------------------------------------------------------

function A.Earned()
    local d = G:Data()
    if type(d.ach) ~= "table" then d.ach = {} end
    return d.ach
end

function A.Stats()
    local d = G:Data()
    if type(d.stats) ~= "table" then d.stats = {} end
    return d.stats
end

local function Bump(key, n)
    local st = A.Stats()
    st[key] = (st[key] or 0) + (n or 1)
end

function A:Points()
    local n = 0
    for id in pairs(A.Earned()) do if A.byId[id] then n = n + A.byId[id].points end end
    return n
end

function A:Count()
    local n = 0
    for id in pairs(A.Earned()) do if A.byId[id] then n = n + 1 end end
    return n
end

---------------------------------------------------------------------------
-- Engine
---------------------------------------------------------------------------

local queue = {}          -- toasts waiting to be shown
local Toast               -- forward declaration

function A:Award(id)
    local a = A.byId[id]
    local earned = A.Earned()
    if not a or earned[id] then return false end
    earned[id] = time and time() or 0
    queue[#queue + 1] = a
    Toast()
    ns:Fire("AZERO_ACHIEVEMENT", id)
    G:Emit("achievement", { id = id, points = a.points })
    return true
end

local function Check(g, e)
    local earned = A.Earned()
    for _, a in ipairs(ACHIEVEMENTS) do
        if not earned[a.id] then
            for _, ev in ipairs(a.on) do
                if ev == e.event then
                    local ok, yes = pcall(a.test, g, e, A)
                    if ok and yes then A:Award(a.id) end
                    break
                end
            end
        end
    end
end

-- lifetime stats first, then the checks (so "the 10th win" counts itself)
local function Count(g, e)
    local ev = e.event
    if ev == "tame" and e.how == "caught" then
        Bump("caught")
        if e.mon and e.mon.shiny then Bump("shinies") end
        if g:IsNight() then Bump("nightTames") end
    elseif ev == "battle" and e.result == "win" then
        Bump(e.wild and "wildWon" or "trainersWon")
    elseif ev == "pvp" and e.result == "win" then Bump("pvpWon")
    elseif ev == "chest" then Bump("chests")
    elseif ev == "blackout" then Bump("blackouts")
    elseif ev == "evolve" then Bump("evolutions")
    elseif ev == "bounty" then Bump("bounties")
    end
end

---------------------------------------------------------------------------
-- Toast (a copy of Blizzard's AchievementAlertFrame look)
---------------------------------------------------------------------------

local toast
local SOUND_ACHIEVEMENT = 12891            -- UI_Alert_AchievementGained
local SOUND_FALLBACK = 31578               -- UI_EPICLOOT_TOAST

local function PlayJingle()
    if not PlaySound then return end
    local ok, willPlay = pcall(PlaySound, SOUND_ACHIEVEMENT, "Master")
    if not ok or willPlay == false then pcall(PlaySound, SOUND_FALLBACK, "Master") end
end

local function BuildToast()
    local f = CreateFrame("Button", nil, UIParent)
    f:SetSize(300, 88)
    f:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, 190)
    f:SetFrameStrata("DIALOG")
    f:Hide()
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture("Interface\\AchievementFrame\\UI-Achievement-Alert-Background")
    bg:SetTexCoord(0, 0.605, 0, 0.703)
    f.unlocked = f:CreateFontString(nil, "ARTWORK", "GameFontBlackTiny")
    f.unlocked:SetSize(200, 12)
    f.unlocked:SetPoint("TOP", 7, -23)
    f.name = f:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    f.name:SetPoint("BOTTOMLEFT", 72, 36)
    f.name:SetPoint("BOTTOMRIGHT", -60, 36)
    f.name:SetHeight(16)
    local icon = CreateFrame("Frame", nil, f)
    icon:SetSize(124, 124)
    icon:SetPoint("TOPLEFT", -26, 16)
    f.icon = icon:CreateTexture(nil, "ARTWORK")
    f.icon:SetSize(50, 50)
    f.icon:SetPoint("CENTER", 0, 3)
    local frame = icon:CreateTexture(nil, "OVERLAY")
    frame:SetTexture("Interface\\AchievementFrame\\UI-Achievement-IconFrame")
    frame:SetTexCoord(0, 0.5625, 0, 0.5625)
    frame:SetSize(72, 72)
    frame:SetPoint("CENTER", -1, 2)
    local shield = CreateFrame("Frame", nil, f)
    f.shield = shield
    shield:SetSize(64, 64)
    shield:SetPoint("TOPRIGHT", -10, -13)
    local sicon = shield:CreateTexture(nil, "BACKGROUND")
    sicon:SetTexture("Interface\\AchievementFrame\\UI-Achievement-Shields")
    sicon:SetTexCoord(0, 0.5, 0, 0.45)
    sicon:SetSize(52, 48)
    sicon:SetPoint("TOPRIGHT", 1, -6)
    f.points = shield:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.points:SetPoint("CENTER", 0, 2)
    f.glow = f:CreateTexture(nil, "OVERLAY")
    f.glow:SetTexture("Interface\\AchievementFrame\\UI-Achievement-Alert-Glow")
    f.glow:SetBlendMode("ADD")
    f.glow:SetTexCoord(0, 0.78125, 0, 0.66796875)
    f.glow:SetSize(400, 171)
    f.glow:SetPoint("CENTER")
    f.shine = f:CreateTexture(nil, "OVERLAY")
    f.shine:SetTexture("Interface\\AchievementFrame\\UI-Achievement-Alert-Glow")
    f.shine:SetBlendMode("ADD")
    f.shine:SetTexCoord(0.78125, 0.912109375, 0, 0.28125)
    f.shine:SetSize(67, 72)
    f:SetScript("OnClick", function(self)
        self:Hide()
        local open = self.current and self.current.open
        if open then open() elseif ns.AzeroUI and ns.AzeroUI.OpenAchievements then ns.AzeroUI:OpenAchievements() end
    end)
    -- the real alert: 0.2 s fade in, glow flash, a shine sweeping across, ~4 s hold, 1.5 s fade out
    f:SetScript("OnUpdate", function(self, dt)
        self.t = self.t + dt
        local t = self.t
        self:SetAlpha(t < 0.2 and t / 0.2 or (t > 4.25 and math.max(0, 1 - (t - 4.25) / 1.5) or 1))
        self.glow:SetAlpha(t < 0.2 and t / 0.2 or math.max(0, 1 - (t - 0.2) / 0.5))
        local s = math.min(1, math.max(0, (t - 0.2) / 0.85))
        self.shine:ClearAllPoints()
        self.shine:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", 240 * s, 8)
        self.shine:SetAlpha(t < 0.2 and t / 0.2 or math.max(0, 1 - math.max(0, t - 0.55) / 0.5))
        if t > 5.75 then
            self:Hide()
            Toast()
        end
    end)
    return f
end

Toast = function()
    if #queue == 0 or not UIParent then return end
    toast = toast or BuildToast()
    if toast:IsShown() then return end
    local a = table.remove(queue, 1)
    toast.current = a
    toast.unlocked:SetText(a.label or "Azeromon Achievement")
    toast.name:SetText(a.name)
    toast.icon:SetTexture(a.icon)
    toast.points:SetText(a.points or "")
    toast.shield:SetShown(a.points ~= nil)
    toast.t = 0
    toast:SetAlpha(0)
    toast:Show()
    if a.sound then
        if PlaySound then pcall(PlaySound, a.sound, "Master") end
    else
        PlayJingle()
    end
end

-- Other Azeromon news in the same toast (bounties, the guild goal): { label, name, icon, sound, open = fn }.
function A:Notify(t)
    queue[#queue + 1] = { label = t.label, name = t.name, icon = t.icon, sound = t.sound, open = t.open }
    Toast()
end

function A:ToastFrame() return toast end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function A:OnInit()
    G:On("*", function(g, e)
        Count(g, e)
        Check(g, e)
    end)
end
