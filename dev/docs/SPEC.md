# DisasterZone — Architecture & Implementation Spec (v1)

Guild loot-assistance addon for **<Casual Disaster>** on the **WoW TBC Anniversary** client (game 2.5.6, TOC `Interface: 20506`, Lua 5.1).
Addon folder: `C:\World of Warcraft\_anniversary_\Interface\AddOns\DisasterZone` (below: `DisasterZone/`).
Scratch/research folder: `C:\Users\emilo\AppData\Local\Temp\claude\C--World-of-Warcraft--anniversary--Interface-AddOns-DisasterZone\ad52e6fc-e309-49be-aa3a-9ce45a30ad4b\scratchpad` (below: `SCRATCH/`).

**Mandatory reading for every implementer:** this spec, plus `SCRATCH/research/api.md` (verified 2.5.x API cheat sheet — which APIs exist, return orders, gotchas). Also useful: `SCRATCH/research/ux.md` (UX study + wireframes), `SCRATCH/research/sync.md` (sync study), `SCRATCH/research/data.md` (loot DB notes). Reference addons are installed in `C:\World of Warcraft\_anniversary_\Interface\AddOns\` — read them for proven 20506 code patterns (e.g. Auctionator for ScrollBox, Leatrix_Plus for MenuUtil dropdowns, LootReserve for loot/comm, GudaBags for C_Container). Never modify other addons.

## 0. Product summary (what the user asked for)

- Every guild member builds **their own BiS list**: separate lists for phases **P1–P5**; each of 17 slots has a **main** BiS pick plus one optional **alt** (backup / upgrade-path) pick.
- **Obtained** status is detected automatically (equipped / bags / bank / holding the tier token) and can be toggled manually.
- A **Loot Council** (guild-rank threshold + extra names − exclusions, stored in a tag in the Guild Information text) sees every member's lists: roster × slot matrix, "who wants item X" per raid/boss, member detail.
- **Boss drop alert**: when a corpse/chest is looted, council members get a panel listing each dropped item and which raid members have it on BiS (main/alt, phase, obtained, equipped, awarded tonight). Regular raiders get a small personal "On your BiS!" toast + loot-button glow.
- **Tooltips**: own status on every item; council sees who wants it.
- **Award log / history** (council only): auto-recorded from loot chat messages in raids + manual awards, synced between council members, with void/undo.
- v2 (NOT now, but keep the data model ready): RCLootCouncil-style voting sessions.
- **No external addon dependencies.** All libs are embedded in `DisasterZone/Libs`. LoonBestInSlot is an *optional* extra for "Suggest BiS" templates only.
- English only (enUS). No localization layer needed, but keep user-facing strings in obvious places.

## 1. Files & load order (already in `DisasterZone/DisasterZone.toc` — do not reorder)

```
Libs/...                       (already present: LibStub, CallbackHandler-1.0, AceComm-3.0 (+ChatThrottleLib v32),
                                LibSerialize (v6), LibDeflate, LibDataBroker-1.1, LibDBIcon-1.0, LibCustomGlow-1.0)
Core/Init.lua        ns bootstrap: module registry, event dispatcher, message bus, lifecycle, slash commands, print/debug
Core/Util.lua        ns.Util: names, timers/debounce, tables, canonical encoding + hash, formatting, group helpers
Core/Constants.lua   slots, phases, classes/specs/roles, proficiency tables, colors, textures
Data/Items.lua       GENERATED raid loot DB (already present; do not edit)
Core/ItemDB.lua      ns.ItemDB: indexes over Data, item info async cache, slot/class filtering, sources, drop expansion
Core/DB.lua          ns.DB: SavedVariables (DisasterZoneDB) defaults/migration; sets ns.db
Core/Guild.lua       ns.Guild: roster cache, guild-info config tag (council, phase), IsCouncil
Core/BiS.lua         ns.BiS: the player's own list model, edits, commit/rev, spec, owned scanning, obtained
Core/Store.lua       ns.Store: cached lists of other players (council), unified record access, wanted-item index
Core/Comm.lua        ns.Comm: transport (AceComm + LibSerialize + LibDeflate), prefixes, send helpers, receive dispatch
Core/Sync.lua        ns.Sync: protocol flows (HELLO/STATE/MANIFEST/WANT/LIST/RELAY), peers, restore
Core/Ledger.lua      ns.Ledger: award log model, merge, digest sync (AWARD/LEDGER messages)
Core/Loot.lua        ns.Loot: loot window scan, DROP broadcast/receive, CHAT_MSG_LOOT parsing, roll hooks, simulate
Core/Loon.lua        ns.Loon: optional LoonBestInSlot template capture
Core/Demo.lua        ns.Demo: in-memory demo data (fake members, lists, raid) to try the UI solo
UI/Widgets.lua       ns.UI: shared widget factory (windows, item buttons, scroll lists, dropdowns, menus, tabs, ...)
UI/MainFrame.lua     ns.MainFrame: main window + tab registry + minimap/LDB launcher
UI/PaperDoll.lua     ns.PaperDoll: reusable paper-doll slot layout (editable or read-only)
UI/MyBiS.lua         ns.MyBiS: "My BiS" tab (phase tabs, spec, doll, summary, suggest)
UI/Picker.lua        ns.Picker: item picker flyout for a slot
UI/Council.lua       ns.CouncilUI: "Council" tab (Roster matrix / Items / Member views)
UI/LootLog.lua       ns.LootLogUI: "Loot Log" tab (ledger list, void, manual add)
UI/DropPanel.lua     ns.DropPanel: council drop panel, personal toast, loot-frame badges/glow
UI/Tooltip.lua       ns.Tooltip: item tooltip lines
UI/Settings.lua      ns.SettingsUI: "Settings" tab + guild config editor + Blizzard Settings entry
```

## 2. Coding conventions (all files)

- Every file starts with a 1–3 line header comment, then `local addonName, ns = ...`.
- Lua **5.1** only: no `goto`, no `//`, no `table.unpack` (use `unpack`), no integer-only assumptions, `#` only on sequences.
- **Globals:** the only globals DisasterZone may write are `DisasterZone` (= ns, set in Init.lua), `DisasterZoneDB` (SavedVariables), `SLASH_DISASTERZONE1`, `SLASH_DISASTERZONE2`, `SlashCmdList["DISASTERZONE"]` (field write), `StaticPopupDialogs["DISASTERZONE_*"]` (field writes), `UISpecialFrames` insertions, and named frames whose names start with `DisasterZone`. Everything else is `local`. Cache frequently used globals as locals at file top where it helps readability (not required).
- **API rules for 20506** (see `research/api.md` §11): use `C_Item.GetItemInfo`, `C_Item.GetItemInfoInstant`, `C_Item.GetItemIconByID`, `C_Item.GetItemQualityByID`, `C_Container.*`, `C_ChatInfo.SendAddonMessage` (via AceComm), `C_ChatInfo.SendChatMessage` (fallback `SendChatMessage` if C_ChatInfo.SendChatMessage is nil), `C_GuildInfo.GuildRoster()`, `C_PartyInfo.GetLootMethod()`, `ChatFrameUtil.InsertLink` (fallback `ChatEdit_InsertLink`), `Settings.RegisterCanvasLayoutCategory`. **Never** call the bare globals `GetItemInfo`, `GetItemInfoInstant`, `GetLootMethod`, `GuildRoster`, `GetContainerItemInfo`, `SendAddonMessage`. Use `BackdropTemplate` for any frame that calls `SetBackdrop`. Use `SetResizeBounds` not `SetMinResize` (we don't resize in v1 anyway). `GetLootSlotInfo` returns icon first; **quality is the 5th return**. Loot buttons: use `button.slot`, never `button:GetID()`. `GetTalentTabInfo` returns `id, name, description, icon, pointsSpent, ...` (points = 5th).
- **Names:** every player identifier stored or compared is a **name key** `"Name-Realm"` (realm normalized, no spaces), produced by `ns.Util.NormalizeName`. Display with `ns.Util.ShortName` (strips realm if it's the player's own realm).
- **Slot IDs:** DisasterZone uses its own slot index **`sid` 1..17** (see §4), NOT inventory slot IDs. Convert with `ns.SLOTS[sid].invSlot`.
- **Error handling:** event/message/comm handlers are dispatched through `xpcall(fn, geterrorhandler())` by Init/Comm; don't wrap your own code in silent `pcall` unless handling untrusted input (comm payloads) — in that case log via `ns:Debug`.
- **No OnUpdate polling** except short-lived animations (toast fade). Use `C_Timer.After`/`NewTimer`/`NewTicker` and `ns.Util.Debounce`.
- **UI refresh:** panels subscribe to internal messages (§3.3) and refresh only if shown (`if not panel:IsVisible() then panel.dirty = true return end`, refresh on `OnShow` when dirty). Use `ns.Util.Debounce` to coalesce bursts.
- Indent with 4 spaces. Keep functions short; prefer data-driven layout tables.
- Do NOT use XML files. All frames in Lua.
- Before finishing, syntax-check your files (§17).

## 3. Core/Init.lua — bootstrap (implemented by the Core agent)

```lua
local addonName, ns = ...
DisasterZone = ns                       -- the ONE debugging global
ns.name = addonName               -- "DisasterZone"
ns.version = C_AddOns.GetAddOnMetadata(addonName, "Version") or "0.0.0"
ns.PROTO = 1                      -- wire protocol major (matches TOC X-CDL-Protocol)
```

### 3.1 Module registry & lifecycle
- `ns:NewModule(name) -> M` — creates table `M` (with `M.name = name`), stores `ns[name] = M` and appends to an ordered list. Error if name exists.
- Lifecycle, dispatched in module registration order (= TOC order), each call in `xpcall`:
  - `M:OnInit()` — on `ADDON_LOADED` for DisasterZone, **after** `ns.DB` has initialized `ns.db` (DB's OnInit runs first among modules that come after it; modules before DB in the TOC — Util, Constants, ItemDB — must not touch `ns.db` in OnInit). Must NOT depend on player name/realm/guild (not reliable yet).
  - `M:OnLogin()` — on `PLAYER_LOGIN`. Player identity is available. Register player-dependent stuff here.
- `ns.loggedIn` becomes true right before OnLogin dispatch.

### 3.2 Events
- `ns:RegisterEvent(event, fn)` — `fn(event, ...)`. Multiple handlers per event allowed; registering the same fn twice is a no-op. Uses one hidden frame; guards unknown events with `C_EventUtils and C_EventUtils.IsEventValid and not C_EventUtils.IsEventValid(event)` → skip + debug message.
- `ns:UnregisterEvent(event, fn)`.

### 3.3 Internal message bus
- `ns:On(msg, fn)` / `ns:Off(msg, fn)` / `ns:Fire(msg, ...)` — `fn(...)` (no msg argument). Handlers run in `xpcall`.
- Message catalogue (the ONLY names to use):

| Message | Args | Fired by | Meaning |
|---|---|---|---|
| `ROSTER_UPDATED` | – | Guild | guild roster cache rebuilt |
| `CONFIG_UPDATED` | cfg | Guild | guild config (council set / phase) parsed & changed, or my council status changed |
| `GROUP_UPDATED` | – | Util | raid/party membership changed |
| `MYLIST_CHANGED` | phase, sid | BiS | own list edited (not yet committed); `phase`/`sid` may be nil for bulk changes |
| `MYLIST_COMMITTED` | record | BiS | own list committed with a new rev |
| `OWNED_UPDATED` | – | BiS | equipped/bags/bank scan changed obtained states |
| `LIST_UPDATED` | nameKey | Store | a cached list of another player was added/replaced/removed |
| `LISTS_RESET` | – | Store/Demo | bulk change (e.g. demo toggled); UIs rebuild everything |
| `ITEMINFO_READY` | – | ItemDB | one or more items finished loading (debounced ~0.25s) |
| `DROP` | drop | Loot | a drop event (see §10.2) is new and should be shown |
| `LEDGER_UPDATED` | – | Ledger | award log changed |
| `PEERS_UPDATED` | – | Sync | addon peer info changed (versions, online council) |
| `SYNC_STATUS` | – | Sync/BiS | sync status text changed (see `ns.Sync:GetStatusText()`) |
| `SETTINGS_CHANGED` | key | Settings/DB | a setting changed (`key` = dotted path, e.g. `"alerts.sound"`) |
| `DEMO_TOGGLED` | enabled | Demo | demo mode switched |

### 3.4 Output
- `ns:Print(fmt, ...)` → `DEFAULT_CHAT_FRAME:AddMessage("|cffff8000DisasterZone|r: " .. msg)` (uses `string.format` only when extra args are given).
- `ns:Debug(fmt, ...)` → same, prefixed `[debug]`, only when `ns.db and ns.db.settings.debug`.

### 3.5 Slash commands
- `SLASH_DISASTERZONE1 = "/dz"`, `SLASH_DISASTERZONE2 = "/disasterzone"`.
- `ns:RegisterSlash(sub, fn, help)` — modules register subcommands; `fn(rest)` receives the remaining text.
- Init handles: empty → `ns.MainFrame:Toggle()`; `help` → list registered subcommands; unknown → help.
- Subcommands registered by their owner modules: `council` (MainFrame → open "council"), `log` (MainFrame → "loot"), `settings`/`config` (MainFrame → "settings"), `sync` (Sync), `demo` (Demo), `test` (Loot: simulate drop), `drop` (Loot: manual drop from shift-clicked links, council/lead only), `version` (Sync: print peer versions), `debug` (Init: toggle `ns.db.settings.debug`).

## 4. Core/Constants.lua

### 4.1 Slots (`ns.SLOTS`, array indexed by sid)
Each entry: `{ id=sid, key=, label=, short=, invSlot=, slotName=, invTypes={[INVTYPE]=true,...} }`

| sid | key | label | short | invSlot | slotName (for GetInventorySlotInfo) | invTypes |
|---|---|---|---|---|---|---|
| 1 | HEAD | Head | Hd | 1 | HeadSlot | INVTYPE_HEAD |
| 2 | NECK | Neck | Nk | 2 | NeckSlot | INVTYPE_NECK |
| 3 | SHOULDER | Shoulder | Sh | 3 | ShoulderSlot | INVTYPE_SHOULDER |
| 4 | BACK | Back | Bk | 15 | BackSlot | INVTYPE_CLOAK |
| 5 | CHEST | Chest | Ch | 5 | ChestSlot | INVTYPE_CHEST, INVTYPE_ROBE |
| 6 | WRIST | Wrist | Wr | 9 | WristSlot | INVTYPE_WRIST |
| 7 | HANDS | Hands | Hn | 10 | HandsSlot | INVTYPE_HAND |
| 8 | WAIST | Waist | Wa | 6 | WaistSlot | INVTYPE_WAIST |
| 9 | LEGS | Legs | Lg | 7 | LegsSlot | INVTYPE_LEGS |
| 10 | FEET | Feet | Ft | 8 | FeetSlot | INVTYPE_FEET |
| 11 | FINGER1 | Ring 1 | R1 | 11 | Finger0Slot | INVTYPE_FINGER |
| 12 | FINGER2 | Ring 2 | R2 | 12 | Finger1Slot | INVTYPE_FINGER |
| 13 | TRINKET1 | Trinket 1 | T1 | 13 | Trinket0Slot | INVTYPE_TRINKET |
| 14 | TRINKET2 | Trinket 2 | T2 | 14 | Trinket1Slot | INVTYPE_TRINKET |
| 15 | MAINHAND | Main Hand | MH | 16 | MainHandSlot | INVTYPE_WEAPON, INVTYPE_2HWEAPON, INVTYPE_WEAPONMAINHAND |
| 16 | OFFHAND | Off Hand | OH | 17 | SecondaryHandSlot | INVTYPE_WEAPON, INVTYPE_WEAPONOFFHAND, INVTYPE_SHIELD, INVTYPE_HOLDABLE |
| 17 | RANGED | Ranged / Relic | Rg | 18 | RangedSlot | INVTYPE_RANGED, INVTYPE_RANGEDRIGHT, INVTYPE_THROWN, INVTYPE_RELIC |

Also: `ns.NUM_SLOTS = 17`, `ns.SLOT_BY_KEY[key] = sid`, `ns.INVTYPE_TO_SIDS[invType] = {sid,...}` (e.g. INVTYPE_FINGER → {11,12}, INVTYPE_WEAPON → {15,16}), `ns.INVSLOT_TO_SID[invSlot] = sid`.
Paper-doll layout constants: `ns.DOLL_LEFT = {1,2,3,4,5,6}`, `ns.DOLL_RIGHT = {7,8,9,10,11,12,13,14}`, `ns.DOLL_BOTTOM = {15,16,17}`.

### 4.2 Phases
`ns.PHASES = {1,2,3,4,5}`; `ns.PHASE_INFO[p] = { short="P1", name="Phase 1", raids="Karazhan · Gruul · Magtheridon" }`
(P2 "Serpentshrine · Tempest Keep", P3 "Hyjal · Black Temple", P4 "Zul'Aman", P5 "Sunwell Plateau"). `ns.MAX_PHASE = 5`.

### 4.3 Classes, specs, roles
- `ns.CLASSES = {"WARRIOR","PALADIN","HUNTER","ROGUE","PRIEST","SHAMAN","MAGE","WARLOCK","DRUID"}`.
- `ns.SPECS[classFile] = { {label=, tab=talentTabIndex, role=}, ... }` with roles `"tank"|"healer"|"melee"|"caster"|"ranged"`:
  - WARRIOR: Arms(1,melee), Fury(2,melee), Protection(3,tank)
  - PALADIN: Holy(1,healer), Protection(2,tank), Retribution(3,melee)
  - HUNTER: Beast Mastery(1,ranged), Marksmanship(2,ranged), Survival(3,ranged)
  - ROGUE: Assassination(1,melee), Combat(2,melee), Subtlety(3,melee)
  - PRIEST: Discipline(1,healer), Holy(2,healer), Shadow(3,caster)
  - SHAMAN: Elemental(1,caster), Enhancement(2,melee), Restoration(3,healer)
  - MAGE: Arcane(1,caster), Fire(2,caster), Frost(3,caster)
  - WARLOCK: Affliction(1,caster), Demonology(2,caster), Destruction(3,caster)
  - DRUID: Balance(1,caster), Feral (Cat)(2,melee), Feral (Bear)(2,tank), Restoration(3,healer)
- `ns.GetSpecRole(classFile, specLabel) -> role|nil`.
- `ns.ROLE_LABELS = { tank="Tank", healer="Healer", melee="Melee", caster="Caster", ranged="Ranged" }`.

### 4.4 Proficiencies (for picker "usable by my class" filter)
- `ns.ARMOR_PRIMARY[classFile] = armorSubclassID` (Enum.ItemArmorSubclass: Cloth=1, Leather=2, Mail=3, Plate=4) — TBC at 70: WARRIOR/PALADIN plate, HUNTER/SHAMAN mail, ROGUE/DRUID leather, PRIEST/MAGE/WARLOCK cloth.
- `ns.ARMOR_ALLOWED[classFile] = {[subclassID]=true}` including Miscellaneous(0) for all, Shield(6) for WARRIOR/PALADIN/SHAMAN, Libram(7) PALADIN, Idol(8) DRUID, Totem(9) SHAMAN.
- `ns.WEAPON_ALLOWED[classFile] = {[weaponSubclassID]=true}` — copy the TBC table from `LootReserve/Libs/ItemCache/ItemCache.lua` (~lines 418–487) and verify against Enum.ItemWeaponSubclass numbering (Axe1H=0, Axe2H=1, Bows=2, Guns=3, Mace1H=4, Mace2H=5, Polearm=6, Sword1H=7, Sword2H=8, Staff=10, Unarmed(fist)=13, Generic=14, Dagger=15, Thrown=16, Crossbow=18, Wand=19, Fishingpole=20). Include `ns.DUAL_WIELD = {WARRIOR=true, ROGUE=true, HUNTER=true, SHAMAN=true}`.
- Item class IDs: Weapon=2, Armor=4 (Enum.ItemClass). Use numeric constants with a comment.

### 4.5 Colors & textures
```lua
ns.COLORS = {
  main     = {0.98, 0.78, 0.22},   -- BiS gold (text badges)
  alt      = {0.41, 0.80, 0.94},   -- alt blue
  obtained = {0.30, 0.90, 0.40},
  needed   = {1, 1, 1},
  muted    = {0.55, 0.55, 0.55},
  warn     = {1.00, 0.55, 0.20},
  bad      = {1.00, 0.30, 0.30},
  council  = {1.00, 0.50, 0.00},   -- addon accent (#ff8000)
}
ns.TEX = {
  check   = "Interface\\RaidFrame\\ReadyCheck-Ready",
  cross   = "Interface\\RaidFrame\\ReadyCheck-NotReady",
  waiting = "Interface\\RaidFrame\\ReadyCheck-Waiting",
  slotBg  = "Interface\\Buttons\\UI-Quickslot2",
  border  = "Interface\\Common\\WhiteIconFrame",
  hilight = "Interface\\Buttons\\ButtonHilight-Square",
  rowHilight = "Interface\\QuestFrame\\UI-QuestTitleHighlight",
  star    = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_1",
  bag     = "Interface\\Buttons\\Button-Backpack-Up",
  bank    = "Interface\\Icons\\INV_Misc_Bag_10_Blue",
  classIcons = "Interface\\TargetingFrame\\UI-Classes-Circles",   -- with CLASS_ICON_TCOORDS
}
```

## 5. Core/Util.lua — `ns.Util` (plain table, not a module with lifecycle except group tracking)

`ns.Util = {}`; it may register events via `ns:RegisterEvent` at file load (Init's dispatcher exists by then) — but group tracking should start in an `ns:On`-free way: Util registers `GROUP_ROSTER_UPDATE` and `PLAYER_ENTERING_WORLD` and fires `GROUP_UPDATED`.

Names:
- `Util.GetPlayerRealm()` → `GetNormalizedRealmName()` or `(GetRealmName() or ""):gsub("[%s%-]", "")`; cache once non-empty.
- `Util.NormalizeName(name)` → nil for nil/""; if it contains "-" return it unchanged except strip spaces from the realm part; else `name .. "-" .. Util.GetPlayerRealm()`.
- `Util.ShortName(key)` → strip `-<ownRealm>`; keep foreign realms.
- `Util.PlayerKey()` → own key (cached after login; valid only after PLAYER_LOGIN).
- `Util.IsMe(key)`.

Timers:
- `Util.After(sec, fn)`; `Util.Debounce(key, sec, fn)` — (re)starts a named timer; `Util.CancelDebounce(key)`; `Util.RandomDelay(minSec, maxSec, fn)`.

Tables & encoding:
- `Util.CopyTable(t)` deep copy; `Util.Count(t)`; `Util.Keys(t)` sorted keys.
- `Util.Canonical(v)` → deterministic string encoding of nested tables of numbers/strings/booleans: keys sorted (numbers ascending before strings ascending), format `{k=v,...}`; numbers via `string.format("%d")` if integral else `%.6f`. Errors on functions/userdata.
- `Util.Hash(v)` → `string.format("%08x", LibDeflate:Adler32(Util.Canonical(v)))`.
- `Util.ItemIDFromLink(link)` → number|nil (`link:match("item:(%d+)")`).
- `Util.ItemIDsFromText(text)` → array of itemIDs from all item links in text.
- `Util.CompareVersions(a, b)` → -1/0/1 numeric dotted compare.

Formatting:
- `Util.FormatAgo(ts)` → "just now", "5m ago", "3h ago", "2d ago" (vs `GetServerTime()`); nil/0 → "never".
- `Util.ColorText(text, r, g, b)`, `Util.ClassColorHex(classFile)` → "ffrrggbb" (from RAID_CLASS_COLORS, fallback white).

Group:
- `Util.RefreshGroup()` rebuilds `Util.group = { [key] = {classFile=, rank=, subgroup=, online=, isML=} }` from `GetRaidRosterInfo` (raid) or `UnitName("partyN")`+player (party); fires `GROUP_UPDATED` if the set changed.
- `Util.IsInMyGroup(key)` → bool (honours Demo: if `ns.Demo and ns.Demo:IsEnabled()` then `ns.Demo:IsInDemoRaid(key)`).
- `Util.GetGroupKeys()` → array.
- `Util.IsPlayerMasterLooter()` → per `api.md` §1.3 (C_PartyInfo.GetLootMethod; `Enum.LootMethod.Masterlooter`; compare raid index / party id).
- `Util.IsPlayerLeaderOrAssist()` → `UnitIsGroupLeader("player") or UnitIsGroupAssistant("player")`.
- `Util.InRaidInstance()` → `local inInst, t = IsInInstance(); return inInst and t == "raid"`.

## 6. Core/ItemDB.lua — `ns.ItemDB` (module)

Data source `ns.Data` (see `DisasterZone/Data/Items.lua` header): `Raids` (array of raids → `bosses` → `items`), `Tokens[tokenID] = {pieceIDs}` (tier tokens and gear-quest items like Magtheridon's Head / Verdant Sphere), `TokenClasses[tokenID] = {classFiles}`, `Upgrades[baseID] = upgradedID` (Sunmote), `TokenArenaExchanges[tokenID] = {patch=, items={...}}`, `TierPieceClass[pieceID] = classFile`.

OnInit builds (once):
- `raidByKey[raidKey]`, `bossRef` objects: for every boss `{ raid=raidTbl, boss=bossTbl, key = raid.key .. ":" .. boss.key }`; `bossByKey[rbKey]`.
- `sources[itemID] = { bossRef, ... }` for every item row.
- `pieceToTokens[pieceID] = {tokenID,...}` (from Tokens and TokenArenaExchanges); `upgradeToBase[upgradedID] = baseID`.
- `bossByNpc[npcID] = bossRef`, `bossByObject[objectID] = bossRef`, `bossByEncounter[encounterID] = bossRef` (first wins; Opera shares 655 → first Opera boss; fine).

API:
- `ItemDB:GetRaids()` → `ns.Data.Raids`.
- `ItemDB:GetBossRef(rbKey)` → bossRef|nil.
- `ItemDB:GetSources(itemID)` → array of `{ ref=bossRef, via=nil|"token"|"upgrade"|"arena", viaItem=tokenOrBaseID }` — direct sources first, then via tokens (for tier pieces / quest rewards), via upgrade base, via arena exchange. Empty array if unknown. Cache results.
- `ItemDB:GetSourceText(itemID, short)` → e.g. `"Prince Malchezaar · Karazhan"`, `"Token · Prince Malchezaar · Karazhan"`, `"+1 more"` suffix when several; `short=true` → `"Prince · Kara"`-ish (use boss.name and raid.name; no abbreviation table needed — just boss name). nil if unknown.
- `ItemDB:GetPhase(itemID)` → lowest raid phase among sources (incl. via), or nil.
- `ItemDB:IsToken(itemID)` → `ns.Data.Tokens[itemID] ~= nil`.
- `ItemDB:ExpandDrop(itemID)` → array: `{itemID}` + Tokens[itemID] pieces + TokenArenaExchanges[itemID].items + Upgrades[itemID] (dedup). Cached.
- `ItemDB:GetBossBySourceGUID(guid)` → bossRef|nil. Parse with `strsplit("-", guid)`: unitType = 1st field, id = 6th field; "Creature"/"Vehicle" → bossByNpc, "GameObject" → bossByObject.
- `ItemDB:GetBossByEncounter(encounterID)` → bossRef|nil.
- `ItemDB:GetEquipLoc(itemID)` → invType string via `C_Item.GetItemInfoInstant` (4th return) — works uncached. For tokens: the equipLoc of the token's first piece. nil if not equippable ("" → nil).
- `ItemDB:GetSlotsForItem(itemID)` → array of sids from `ns.INVTYPE_TO_SIDS[equipLoc]` (tokens resolved as above).
- `ItemDB:FitsSlot(itemID, sid)` → bool.
- `ItemDB:IsUsableBy(itemID, classFile)` → true/false/nil. Rules: TierPieceClass wins; tokens → TokenClasses contains class; else via GetItemInfoInstant classID/subclassID: armor (4) → `ARMOR_ALLOWED`; weapon (2) → `WEAPON_ALLOWED`; other → true. Off-hand one-handers (INVTYPE_WEAPON/WEAPONOFFHAND in OH) need DUAL_WIELD (caller passes sid; add optional 3rd param `sid`).
- `ItemDB:IsPrimaryArmor(itemID, classFile)` → true if not armor, or armor subclass == ARMOR_PRIMARY or subclass not in {1,2,3,4} (cloaks are cloth subclass 1 but INVTYPE_CLOAK — treat cloaks, rings, necks, trinkets, shields, relics as always "primary").
- `ItemDB:GetCandidates(sid, filter)` → array of rows for the picker/council, in raid → boss → item order: `{ itemID=, ref=bossRef, via=nil|"token", viaItem=tokenID }`. For each boss item: if it's a token whose pieces fit `sid`, emit the **pieces** (not the token) filtered by `filter.class` via TierPieceClass (only that class's pieces; all pieces if filter.class nil), with `via="token", viaItem=token`; else emit the item if `FitsSlot(item, sid)`. Skip trash `isTrash` bosses unless `filter.includeTrash` (default true). Filters: `filter.maxPhase` (raid.phase ≤), `filter.phase` (== exact), `filter.class` + `filter.usableOnly` (IsUsableBy), `filter.primaryArmorOnly` (IsPrimaryArmor). Dedupe by itemID (first source wins). NOTE: equipLoc comes from GetItemInfoInstant which works uncached; if it returns nil for an ID, skip it (and debug-log once).
- Item info (async, cached by the client):
  - `ItemDB:GetInfo(itemID)` → `name, link, quality, icon` if cached, else `nil` and requests load (`C_Item.RequestLoadItemDataByID`), remembering the id as pending.
  - `ItemDB:GetIcon(itemID)` → `C_Item.GetItemIconByID(itemID)` (works uncached) or `134400` (question mark).
  - `ItemDB:GetName(itemID)` / `GetLink(itemID)` / `GetQuality(itemID)` → cached or nil (and request).
  - `ItemDB:Prefetch(ids)` → request load for a list.
  - Listens to `GET_ITEM_INFO_RECEIVED(itemID, success)`: if itemID pending → remove and `Util.Debounce("iteminfo", 0.25, fire ITEMINFO_READY)`.
- `ItemDB:Search(text, candidates)` → filter a candidates array by case-insensitive substring match on item name (if cached), boss name, raid name, or exact numeric itemID. Returns new array.

## 7. Core/DB.lua — `ns.DB` (module) — SavedVariables

`OnInit`: `DisasterZoneDB = DisasterZoneDB or {}`; apply defaults (deep-fill missing keys, never overwrite existing); run migrations by `schema`; set `ns.db = DisasterZoneDB`.

```lua
DEFAULTS = {
  schema = 1,
  settings = {
    minimap = { hide = false },          -- LibDBIcon storage table
    alerts = {
      councilPanel = true,   -- show drop panel (council only)
      personalToast = true,  -- "On your BiS!" toast
      sound = true,
      glow = true,           -- glow loot button for own BiS
      chat = true,           -- chat line for own BiS drops
      lootBadges = true,     -- badges on default loot frame buttons
    },
    dropPanelMode = "auto",  -- "auto" (anchor to LootFrame when it is open, else floating) | "floating"
    tooltip = { enabled = true, council = true, maxNames = 5 },
    announceChannel = "RAID",-- "RAID" | "RAID_WARNING"
    qualityThreshold = 4,    -- 4 = epic, 3 = rare
    viewPhase = nil,         -- nil = follow guild phase; else 1..5 (council views & alerts)
    debug = false,
    windows = {},            -- [frameName] = {point, relPoint, x, y}
  },
  chars = {},        -- [nameKey] = own record (see §8), one per own character
  lists = {},        -- [nameKey] = cached record of other players (council only)
  ledger = {},       -- [id] = award entry (§11)
  peers = {},        -- [nameKey] = { v="0.1.0", c=bool, lastSeen=serverTime }
  guildCfg = {},     -- { raw=, cfg=, fetchedAt= } last parsed config cache
  dropHistory = {},  -- array of recent drops (§10.2), newest last, max 40, pruned > 24h
}
```
API: `ns.DB:GetSetting(path)` / `ns.DB:SetSetting(path, value)` (dotted path like `"alerts.sound"`; SetSetting fires `SETTINGS_CHANGED(path)`).

## 8. Core/BiS.lua — `ns.BiS` (module): the player's own list

### 8.1 Record & payload
Own record lives at `ns.db.chars[Util.PlayerKey()]` (created on first access after login):
```lua
record = {
  rev = 0,              -- increments on every commit that changes `hash`
  highestSeenRev = 0,   -- highest rev of my own list seen anywhere (restore protection)
  ts = 0,               -- GetServerTime() of last commit
  hash = "",            -- Util.Hash(data)
  data = ListData,      -- the synced payload (below)
  manual = {},          -- [itemID] = true  manual "obtained" flags (local only; folded into data.ob)
  bank = {},            -- [itemID] = count  last bank snapshot (local only)
  bankTs = 0,
}
ListData = {             -- THIS table is what gets synced; keep it compact
  v  = 1,                -- list schema version
  cl = "PALADIN",        -- classFile
  sp = "Holy",           -- spec label from ns.SPECS or ""
  ph = { [phase] = { [sid] = { mainID, altID } } },  -- numbers, 0 = empty; omit empty slots/phases
  ob = { itemID, ... },  -- sorted array: list items (any phase, main or alt) currently obtained
  eq = { [sid] = itemID },   -- currently equipped item per sid (omit empty)
}
```
Validation limits (also enforced by Store on receipt, §9.2): phases 1..5, sids 1..17, item IDs integers 1..200000, `ob` ≤ 200 entries, strings ≤ 24 chars.

### 8.2 API
- `BiS:GetRecord()` → own record (creates default with `cl` from `UnitClass("player")`, `sp` from DetectSpec()).
- `BiS:GetData()` → record.data.
- `BiS:GetSlot(phase, sid)` → `mainID|nil, altID|nil`.
- `BiS:SetSlot(phase, sid, which, itemID)` — `which` = `"main"|"alt"`; `itemID` nil/0 clears. Validates `ItemDB:FitsSlot` (reject with `ns:Print` message if it doesn't fit; return false). If setting main to the current alt, swap. If the same item is already main in the *paired* slot (ring/trinket 11↔12, 13↔14) and the item is unique… no validation (keep simple). Fires `MYLIST_CHANGED(phase, sid)`, then `BiS:MarkDirty()`. Returns true.
- `BiS:ClearSlot(phase, sid)`, `BiS:SwapMainAlt(phase, sid)`, `BiS:ClearPhase(phase)`, `BiS:CopyPhase(fromPhase, toPhase, overwrite)` (overwrite=false fills empty slots only), `BiS:ApplyTemplate(phase, slots, overwrite)` where `slots[sid] = {main, alt}`.
- `BiS:GetSpec()`, `BiS:SetSpec(label)`; `BiS:DetectSpec()` → label from the talent tab with most points (`GetTalentTabInfo(tab)` 5th return), mapped through `ns.SPECS[class]` (first spec with that tab; DRUID tab 2 → "Feral (Cat)"); returns "" if no talents.
- `BiS:GetPhaseItems(phase)` → array of `{sid=, which=, itemID=}` for non-empty entries.
- `BiS:AllListItems()` → set `{[itemID]=true}` over all phases, main+alt.
- Obtained:
  - Scans (debounced 1.5s, key "bis-scan") on `PLAYER_EQUIPMENT_CHANGED`, `BAG_UPDATE_DELAYED`, `PLAYER_LOGIN` (+3s), `BANKFRAME_OPENED`, `PLAYERBANKSLOTS_CHANGED` (bank only while bank open: remember `bankOpen` via BANKFRAME_OPENED/CLOSED).
  - Sets: `equipped[itemID]` (inventory slots 1..19), `bags[itemID]` (bags 0..NUM_BAG_SLOTS via `C_Container.GetContainerNumSlots/GetContainerItemID`), `record.bank` (container -1 and bank bags NUM_BAG_SLOTS+1 .. NUM_BAG_SLOTS+NUM_BANKBAGSLOTS, only while bank is open; persist).
  - `BiS:GetObtainedState(itemID)` → `"equipped"|"bags"|"bank"|"token"|"manual"|nil`, checked in that order. `"token"` = the player holds (equipped/bags/bank) a token/quest item whose `ItemDB:ExpandDrop(token)` contains itemID.
  - `BiS:IsObtained(itemID)` → state ~= nil.
  - `BiS:SetManualObtained(itemID, bool)` → record.manual; recompute; `MarkDirty()`.
  - After a scan: rebuild `data.ob` (sorted list items that are obtained) and `data.eq` (sid → equipped item ID; for sid 11/12, 13/14, 15/16 map invSlots 11/12,13/14,16/17 directly). If changed: fire `OWNED_UPDATED` and `MarkDirty()`.
- Commit:
  - `BiS:MarkDirty()` → `Util.Debounce("bis-commit", 8, function() BiS:Commit() end)`; fires `SYNC_STATUS`.
  - `BiS:Commit()` → `newHash = Util.Hash(data)`; if equal to `record.hash` → return false. Else `record.rev = max(record.rev, record.highestSeenRev) + 1; record.highestSeenRev = record.rev; record.ts = GetServerTime(); record.hash = newHash`; fire `MYLIST_COMMITTED(record)`; return true. Also call Commit immediately (cancel debounce) when the main window hides and on `PLAYER_LOGOUT`.
  - `BiS:IsDirty()` → debounce pending or hash mismatch.
- Drop matching for the personal toast/tooltips:
  - `BiS:MatchItem(itemID)` → array of `{phase=, sid=, which="main"|"alt", wanted=wantedItemID, via=nil|"token"|"upgrade"|"arena", obtained=bool}` over all phases for every wanted item in `ItemDB:ExpandDrop(itemID)`; sorted: current view phase first (`ns.Guild:GetViewPhase()`), then ascending phase, main before alt.
- Restore support (called by Sync): `BiS:AdoptRestored(entry)` where entry = `{r=rev, ts=, h=, d=data}` → validate via `ns.Store:ValidateData`, replace `record.data` with a copy (then keep own `cl`), set `rev = entry.r`, `highestSeenRev = max(...)`, `ts`, `hash = Util.Hash(record.data)`; rescan owned; fire `MYLIST_CHANGED()`; `ns:Print("Restored your BiS list from the council (rev %d).")`.
- `BiS:NoteSeenRev(rev)` → `highestSeenRev = max(highestSeenRev, rev)`.

## 9. Core/Store.lua — `ns.Store` (module): everyone's lists (council cache)

### 9.1 Records
`ns.db.lists[nameKey] = { rev=, ts=, hash=, data=ListData, recvAt=GetServerTime(), via="direct"|<councilKey> }`.

### 9.2 API
- `Store:Get(key)` → record|nil. For `Util.IsMe(key)` return the own record from BiS (same fields). When Demo is enabled return demo records instead (own record still real).
- `Store:GetAllKeys()` → sorted array of keys that have a record: own key + (council or demo) cached keys. Non-council clients return only the own key. Exclude keys not in the guild roster unless Demo (show them only if `includeFormer`? — v1: exclude former members; prune records whose key has been missing from a *ready* roster for > 30 days using a `missingSince` field).
- `Store:ValidateData(data)` → ok, err (limits §8.1; types; unknown top-level keys allowed but ignored).
- `Store:Put(key, entry, via)` — `entry = {r=, ts=, h=, d=}` (wire shape). Rules: ignore if `Util.IsMe(key)` (owner authoritative); require `ns.Guild:AmICouncil()`; require `ns.Guild:IsInGuild(key)`; validate data; verify `Util.Hash(entry.d) == entry.h` (reject on mismatch); accept if no current record, or `entry.r > cur.rev`, or (`entry.r == cur.rev` and `entry.h ~= cur.hash` and `via == "direct"`). On accept: store a copy, `recvAt`, `via`; mark index dirty; fire `LIST_UPDATED(key)`. Returns true if stored.
- `Store:Remove(key)`; `Store:GetManifest()` → `{ [key] = rev }` for all cached lists **plus own** (own rev included).
- Wanted-item index (rebuilt lazily when dirty; dirty on LIST_UPDATED, MYLIST_CHANGED, OWNED_UPDATED, LEDGER_UPDATED, DEMO_TOGGLED, CONFIG_UPDATED):
  - internal `index[wantedItemID] = { {key=, phase=, sid=, which=} ... }` over all records returned by GetAllKeys.
  - `Store:GetWanters(itemID, opts)` → one entry per (player, wantedItem) for every wanted item in `ItemDB:ExpandDrop(itemID)`:
    ```lua
    { key=, classFile=, spec=, wanted=wantedItemID, via=nil|"token"|"upgrade"|"arena",
      phase=chosenPhase, phases={sorted phases where listed}, which="main"|"alt" (best in chosenPhase),
      sid=, obtained=bool (wanted ∈ data.ob), awarded=bool (ns.Ledger:HasAward(key, wanted)),
      inRaid=Util.IsInMyGroup(key), online=ns.Guild:IsOnline(key), equipped=data.eq[sid] or nil,
      listTs=record.ts, wonTonight=ns.Ledger:CountSince(key, GetServerTime()-6*3600) }
    ```
    chosenPhase = the view phase if listed there, else the lowest listed phase ≥ view phase, else the highest listed phase.
    `opts = { includeObtained=false, phase=nil (restrict to one phase), raidOnly=false }`.
    Sort: inRaid desc → (phase == viewPhase) desc → which main before alt → obtained asc → wonTonight asc → ShortName asc.
  - `Store:CountWanters(itemID, opts)` → number (same filtering).
- `Store:GetPlayerSummary(key, phase)` → `{ filled=, obtained=, needed=, total=17 }` counting main picks.

## 10. Comm, Sync, Loot — the network layer

### 10.1 Core/Comm.lua — `ns.Comm` (module)
- Embed AceComm: `LibStub("AceComm-3.0"):Embed(Comm)`. Prefixes & priorities:
  - `CDLc` control → `"NORMAL"`; `CDLd` data → `"BULK"`; `CDLa` alert → `"ALERT"`. Register all three in OnInit (`Comm:RegisterComm(prefix, "OnCommReceived")`).
  - Each (prefix, distribution) carries one priority only (never mix).
- Wire format: `text = tostring(ns.PROTO) .. LibDeflate:EncodeForWoWAddonChannel(LibDeflate:CompressDeflate(LibSerialize:Serialize(msg)))` where `msg` is a table with `msg.t` = type string.
- `Comm:Register(msgType, handler)` → `handler(senderKey, msg, distribution)`.
- `Comm:Send(msg, distribution, target, class)` → `class` ∈ `"ctrl"|"data"|"alert"` picks prefix+priority. `distribution` ∈ "GUILD","RAID","PARTY","WHISPER". For WHISPER, `target` is a name key; send `Ambiguate(target, "none")` (AceComm/ChatThrottleLib handle "Name-Realm"). Refuse (return false) WHISPER to targets not currently online per `ns.Guild:IsOnline(target)` unless they are in my group. Refuse GUILD if `not IsInGuild()`, RAID if `not IsInRaid()` (use PARTY if in party and caller passed "RAID"? — no: return false).
- `Comm:SendToCouncil(msg, class)` → whisper to every online council peer (`ns.Sync:GetOnlineCouncilPeers()`), excluding self; returns count.
- Receive (`OnCommReceived(prefix, text, distribution, sender)`):
  1. `senderKey = Util.NormalizeName(sender)`; ignore own messages (`Util.IsMe`).
  2. First char must equal `tostring(ns.PROTO)`; else record `ns.Sync:NotePeerProtocol(senderKey, firstChar)` and drop.
  3. Decode/decompress/deserialize inside `pcall`; drop on failure (`ns:Debug`).
  4. `msg` must be a table with string `t` and a registered handler; basic sender gate: for distribution GUILD/WHISPER require `ns.Guild:IsInGuild(senderKey)`; RAID/PARTY require `Util.IsInMyGroup(senderKey)`.
  5. Dispatch `xpcall(handler, errorhandler, senderKey, msg, distribution)`.
- `Comm:RateLimit(key, seconds)` → true if allowed now (and records), false if called again within `seconds`.
- Stats for debugging: `Comm.stats = {sent=0, recv=0, bytesSent=0}`.

### 10.2 Messages (types, fields, channel, class)
All `n`-arrays are name keys. Sender identity ALWAYS comes from the transport, never from payload fields.

| t | Name | Channel / class | Fields | Sender gate on receipt |
|---|---|---|---|---|
| `H` | HELLO | GUILD / ctrl | `r`=own rev, `v`=addon version, `c`=I-am-council bool, `m`=manifest `{[key]=rev}` (only if c), `ld`=ledger digest (only if c) | guild member |
| `S` | STATE | WHISPER / ctrl | `r`=my cached rev of *your* list (0 if none) | sender is council (ns.Guild:IsCouncil) |
| `M` | MANIFEST | WHISPER / ctrl | `m`, `ld` | sender council AND I am council |
| `W` | WANT | WHISPER / ctrl | `n`=array of keys (≤40) | sender council; OR (`n == {senderKey}` and I am council) = restore request |
| `L` | LIST | WHISPER / data | `r`,`ts`,`h`,`d` (owner's list) | I am council; owner = sender |
| `R` | RELAY | WHISPER / data | `e`=array of `{o=ownerKey,r=,ts=,h=,d=}` (≤8 per message) | sender council |
| `D` | DROP | RAID / alert | `s`=source key, `b`=bossRef key or "", `i`=array itemIDs, `ts` | sender in my raid |
| `A` | AWARD | WHISPER / ctrl | `e`=ledger entry | sender council AND I am council |
| `LW` | LEDGER WANT | WHISPER / ctrl | `d`=array of day numbers (≤30) | sender council AND I am council |
| `LG` | LEDGER | WHISPER / data | `e`=array of ledger entries (≤20 per message) | sender council AND I am council |

### 10.3 Core/Sync.lua — `ns.Sync` (module)
State: `peers` (persisted in `ns.db.peers`: `{v, c, lastSeen}`), session sets `sessionSeen[key]=true` (sent us H/S/M this session), `pushedRev[councilKey]=rev`, `requested[key]=rev` (WANTs in flight), `restoreOffered`.

API:
- `Sync:GetOnlineCouncilPeers()` → array of keys: `sessionSeen` ∩ `ns.Guild:IsCouncil(key)` ∩ `ns.Guild:IsOnline(key)`, excluding me.
- `Sync:GetPeer(key)` → `{v=, c=, lastSeen=}`.
- `Sync:GetStatusText()` → short status for UI, one of: `"Not in a guild"`, `"Waiting for guild roster…"`, `"Not shared yet — no council member online"`, `"Changes pending…"` (BiS dirty), `"Shared with council ✓ <ago>"` (when at least one council peer has acknowledged our current rev via S/M or we pushed L to one this session; track `lastSharedTs`).
- `Sync:SendHello()` — rate-limited (30s) — builds H. Called automatically once per session: after `ns.Guild:IsReady()` (fires CONFIG_UPDATED / ROSTER_UPDATED) plus `Util.RandomDelay(8, 20)`. `/dz sync` calls it manually (and prints "Sync requested").
- Handlers (see §10.2 gates):
  - **H** from X: update peer (`v`, `c`, lastSeen), `sessionSeen[X]=true`, fire PEERS_UPDATED.
    - If I am council: `Util.RandomDelay(0.5, 4)` → send `S{r = cachedRev(X) or 0}` to X.
    - If `msg.c` and `ns.Guild:IsCouncil(X)`:
      - own-list check: `their = msg.m and msg.m[me] or 0`; if `record.rev > their and record.rev > 0` → `Sync:PushListTo(X)` after `RandomDelay(2, 10)`; if `their > record.rev` → `Sync:OnCouncilHasNewer(X, their)`.
      - If I am council: `RandomDelay(1, 5)` → send `M{m=Store:GetManifest(), ld=Ledger:GetDigest()}` to X; then `Sync:PullFrom(X, msg.m)` and `ns.Ledger:SyncFromDigest(X, msg.ld)`.
  - **S** from council X: `sessionSeen[X]=true`; peer c=true; if `record.rev > msg.r and record.rev > 0` → `PushListTo(X)`; elseif `msg.r > record.rev` → `OnCouncilHasNewer(X, msg.r)`; elseif equal → mark shared (`lastSharedTs`), fire SYNC_STATUS.
  - **M** from council X: `sessionSeen[X]=true`; own-list check as for H (using `msg.m[me]`); `PullFrom(X, msg.m)`; `ns.Ledger:SyncFromDigest(X, msg.ld)`.
  - **W** from X: build entries for requested keys I have (own record for my key; cached records if I'm council) → send in `R` batches of ≤8 to X (data class). Rate limit: `Comm:RateLimit("W:"..X, 3)` — if limited, merge names into a pending set flushed after 3s.
  - **L** from owner X: `ns.Store:Put(X, msg, "direct")`; if stored or equal rev → reply nothing (the owner learns via S/M later). (No ACK message in v1.)
  - **R** from council X: for each `e`: if `e.o` is me → if `restorePending` → `ns.BiS:AdoptRestored(e)`; else `ns.BiS:NoteSeenRev(e.r)`. Else if I am council → `ns.Store:Put(e.o, e, X)`; clear `requested[e.o]` when satisfied.
- `Sync:PushListTo(X)` → if `pushedRev[X] == record.rev` skip; send `L{r,ts,h,d}` (data) to X; set `pushedRev[X]`, `lastSharedTs = GetServerTime()`; fire SYNC_STATUS.
- On `MYLIST_COMMITTED`: push to every `GetOnlineCouncilPeers()` (stagger 0.3s apart).
- `Sync:PullFrom(X, manifest)` → names where `manifest[k] > (Store rev or 0)`, `k ~= me`, `ns.Guild:IsInGuild(k)`, and not already `requested[k] >= manifest[k]` → send `W` batches (≤40 names) to X, set `requested[k]=manifest[k]`; clear stale `requested` after 60s.
- `Sync:OnCouncilHasNewer(X, rev)`: `BiS:NoteSeenRev(rev)`. If own `record.rev == 0` (fresh install / lost data) → `restorePending = true`, send `W{n={me}}` to X automatically. Else (once per session) show StaticPopup `DISASTERZONE_RESTORE`: "A council member (%s) has a newer copy of your BiS list (rev %d, yours %d). Restore it?" Accept → restorePending, send W to X. Cancel → force a new commit that supersedes it: `BiS:Commit()` (rev becomes highestSeenRev+1; if data hash unchanged, bump anyway via `BiS:ForceBump()` which increments rev/ts and fires MYLIST_COMMITTED).
- `Sync:NotePeerProtocol(key, major)` — remember incompatible peers; print once "X uses an incompatible DisasterZone version".
- `Sync:GetVersions()` → array `{key, v, lastSeen, online}` (for `/dz version` and the council UI).
- Non-guild: if `not IsInGuild()` the addon still works locally (My BiS, personal alerts, drop detection); Sync stays idle.

### 10.4 Core/Loot.lua — `ns.Loot` (module)

Drop object (also the `DROP` message payload and `ns.db.dropHistory` entries):
```lua
drop = { s = sourceKey, b = bossRefKey or "", i = {itemID, ...}, ts = GetServerTime(), from = senderKey or me, test = bool|nil }
```
- `LOOT_READY` → `Loot:ScanLoot()`:
  - For `slot = 1, GetNumLootItems()`: require `GetLootSlotType(slot) == 1` (item); `link = GetLootSlotLink(slot)` must match `item:(%d+)` with a nonzero id; `quality = select(5, GetLootSlotInfo(slot))`; keep if `quality >= settings.qualityThreshold` OR `ns.ItemDB:IsToken(id)`.
  - Source: `guid = GetLootSourceInfo and GetLootSourceInfo(slot)` (first return). If nil: `UnitGUID("target")` when `UnitIsDead("target")`; else `"UNKNOWN-" .. math.floor(GetTime() / 30)`. `bossRef = ItemDB:GetBossBySourceGUID(guid)` or the last encounter (`ENCOUNTER_END` with success within 5 minutes → `ItemDB:GetBossByEncounter`).
  - Group items by source key; for each source not in `seenSources` (session table; also skip if already in dropHistory) build a drop.
  - If no items pass the filter → nothing.
  - Broadcast rule (if `IsInRaid()`): if `Util.IsPlayerMasterLooter()` → send `D` now; else `Util.RandomDelay(0.3, 1.5)` then send only if no `D` with the same `s` arrived meanwhile. Always handle locally immediately (`Loot:HandleDrop(drop)`).
- `D` handler: `Loot:HandleDrop(msg-as-drop, senderKey)`.
- `Loot:HandleDrop(drop, from)` → dedupe by `drop.s` (seenSources + dropHistory); append to `ns.db.dropHistory` (cap 40, prune >24h); `ns:Fire("DROP", drop)`.
- `Loot:GetHistory()` → dropHistory (newest last).
- `CHAT_MSG_LOOT(text, playerName, ...)`: build patterns once from globalstrings (escape magic chars; `%s`→`(.+)`, `%d`→`(%d+)`; try `LOOT_ITEM_SELF_MULTIPLE`, `LOOT_ITEM_SELF`, `LOOT_ITEM_PUSHED_SELF_MULTIPLE`, `LOOT_ITEM_PUSHED_SELF`, `LOOT_ITEM_MULTIPLE`, `LOOT_ITEM` — self patterns first). Winner = me for SELF forms, else `Util.NormalizeName(captured name)`. itemID from the link. Then:
  - if I am council and `Util.InRaidInstance()` and the item qualifies (quality via `ItemDB:GetQuality` or link color ≥ threshold, and (`#ItemDB:GetSources(id) > 0` or `ItemDB:IsToken(id)`)) → `ns.Ledger:RecordAuto(id, winnerKey, Loot:GetRecentBossKey())`.
- `START_LOOT_ROLL(rollID)` → `link = GetLootRollItemLink(rollID)` → `ns:Fire("DROP", {s="ROLL-"..rollID, b=Loot:GetRecentBossKey() or "", i={id}, ts=..., roll=true})` locally (not broadcast, not stored in history) so the personal toast shows.
- `ENCOUNTER_END(encounterID, name, difficultyID, groupSize, success)` → if success == 1 remember `{ref=ItemDB:GetBossByEncounter(encounterID), time=GetTime()}`. `Loot:GetRecentBossKey()` → key if within 10 minutes.
- `Loot:SimulateDrop()` (`/dz test`): pick a boss from the current view phase that has items wanted by someone in `Store` (fallback: random boss of that phase); choose up to 4 items (wanted ones first); `Loot:HandleDrop({s="TEST-"..GetTime(), b=ref.key, i=ids, ts=GetServerTime(), test=true}, me)`; print what was simulated.
- `/dz drop <links>`: requires council or leader/assist; builds a drop from `Util.ItemIDsFromText(rest)` with `s="MANUAL-"..GetServerTime()`, `b = GetRecentBossKey() or ""`; handles locally and broadcasts `D` to RAID if in raid.

## 11. Core/Ledger.lua — `ns.Ledger` (module): award log (council only)

Entry (stored in `ns.db.ledger[id]`, sent as-is on the wire):
```lua
{ id = "a1790000000Bob12345" ,  -- ("a" auto | "m" manual) .. ts .. shortName .. itemID  (unique enough)
  i = itemID, w = winnerKey, b = bossRefKey or "", ts = serverTime, by = recorderKey,
  s = "a" | "m",  n = note or nil,  vd = true|nil (voided),  vts = serverTime|nil }
```
- `Ledger:RecordAuto(itemID, winnerKey, bossKey)` → id `"a"..ts..ShortName(winner)..itemID`; add; if I'm council send `A` to online council.
- `Ledger:Award(itemID, winnerKey, bossKey, note)` → manual entry `"m"..ts..ShortName(me)..itemID`; add; send `A`; return entry.
- `Ledger:Void(id, voided)` → set `vd=true/nil`, `vts=GetServerTime()`; send `A` with the updated entry.
- `Ledger:Merge(entry, fromKey)` → validate (types, id ≤ 64 chars, i integer, w/by strings, ts number); union by id; if exists: `vd` = if either vd and that side's vts ≥ other's vts…: rule = take the version with the greater `vts or 0`; ties → vd wins. Fire LEDGER_UPDATED (debounced 0.2s).
- `Ledger:GetEntries(filter)` → array newest-first of *visible* entries after de-dupe: among non-void entries with the same `(w, i)`: two auto entries within 120s → keep the smaller id; an auto entry within 6h after a manual one → hidden (manual wins). `filter = {player=key, includeVoid=bool, since=ts}`. Voided entries are returned only with `includeVoid` (and flagged).
- `Ledger:HasAward(key, wantedItemID)` → true if a visible non-void entry for `key` has `i == wantedItemID` or `ItemDB:ExpandDrop(e.i)` contains wantedItemID.
- `Ledger:CountSince(key, ts)` → visible non-void entries for key with `e.ts >= ts`.
- Digest sync: `day = floor(ts / 86400)`. `Ledger:GetDigest()` → `{[day] = string.format("%08x", Adler32(concat of sorted (id .. (vd and "v" .. vts or "")) for that day))}` for days within the last 120 days. `Ledger:SyncFromDigest(X, digest)` → days where `digest[day] ~= mine[day]` (either side) → send `LW{d=days}` to X (≤30 days per message). **LW** handler → send my entries for those days in `LG` batches of ≤20. **LG** handler → merge each. **A** handler → merge.
- Only council clients record/merge/send; non-council ignore ledger traffic.

## 12. UI

### 12.1 UI/Widgets.lua — `ns.UI` (module)
Visual style: native WoW (research/ux.md §4.5): `BasicFrameTemplateWithInset` windows, GameFontNormal (gold) headings, GameFontHighlight/HighlightSmall body, GameFontDisableSmall secondary; saturated colour only for data (quality, class, BiS gold, alt blue, obtained green); every colour signal also has a word or glyph.

API (all return frames; caller positions them):
- `UI:CreateWindow(name, title, width, height)` → frame `name` (global name, starts with "DisasterZone"), `BasicFrameTemplateWithInset`, `SetMovable(true)`, `EnableMouse(true)`, `RegisterForDrag("LeftButton")` + StartMoving/StopMovingOrSizing, `SetClampedToScreen(true)`, `SetFrameStrata("HIGH")`, `tinsert(UISpecialFrames, name)`, title via `frame.TitleText` (fallback: create fontstring), position saved to/restored from `ns.db.settings.windows[name]` (default CENTER). Returns frame with `frame.content` = a frame filling the inset (use `frame.Inset` if present, else inset by 6/26/6/6).
- `UI:CreateItemButton(parent, size)` → Button with fields/methods:
  - `.icon` (texture), `.border` (quality border texture, `ns.TEX.border`, tinted), `.overlay` (obtained check, 40% size, bottom-right), `.badge` (FontString top-right, GameFontNormalSmall), `.itemID`.
  - `btn:SetItem(itemID, emptyTexture)` → nil itemID shows `emptyTexture` (or slotBg) desaturated at 0.6 alpha, hides border; else icon = `ItemDB:GetIcon`, border colour from quality (when known; re-apply on ITEMINFO_READY — the button should refresh itself if its itemID is still pending: keep a weak registry of buttons and update on ITEMINFO_READY).
  - `btn:SetState(state)` → `nil` normal; `"obtained"` desaturate icon 60%, show check; `"equipped"` show check (full colour); `"awarded"` show star; `"dim"` alpha 0.35.
  - `btn:SetBadge(text, r, g, b)` / `btn:SetBadge(nil)`.
  - Mouse: OnEnter → `GameTooltip:SetOwner(self, "ANCHOR_RIGHT")`, `GameTooltip:SetItemByID(itemID)` (if itemID) then `if self.onTooltip then self.onTooltip(self, GameTooltip) end`, `GameTooltip:Show()`; OnLeave hides. OnClick (register "LeftButtonUp","RightButtonUp"): if `IsModifiedClick()` and itemID and `HandleModifiedItemClick(link)` returns true → stop; if Shift+click with itemID → `ChatFrameUtil.InsertLink(link)` (fallback `ChatEdit_InsertLink`) → stop; else `self.onClick(self, mouseButton)` if set.
  - Drag & drop: `OnReceiveDrag` and `OnMouseUp`: if `GetCursorInfo()` returns `"item", itemID` and `self.onReceiveItem` → `ClearCursor()`; `self.onReceiveItem(self, itemID)`.
- `UI:CreateScrollList(parent, rowHeight, initRow)` → object `{frame, box, bar, SetData(self, array), Refresh(self)}` built with modern ScrollBox: `CreateFrame("Frame", nil, parent, "WowScrollBoxList")`, `CreateFrame("EventFrame", nil, parent, "WowTrimScrollBar")`, `view = CreateScrollBoxListLinearView()`, `view:SetElementExtent(rowHeight)`, `view:SetElementInitializer("Button", function(row, data) ... end)`, `ScrollUtil.InitScrollBoxListWithScrollBar(box, bar, view)`, `box:SetDataProvider(CreateDataProvider(array))`. **Verify the exact API usage against `Auctionator/Source` (e.g. RecentsContainer.lua / ListsContainer.lua) and WeakAuras/Profiling.lua** — use what they use. `initRow(row, data)` must fully (re)initialize the row every call (rows are recycled); lazily create sub-widgets on first use (`if not row.initialized then ... end`). The box should anchor TOPLEFT/BOTTOMRIGHT of `frame` with room for the bar on the right.
- `UI:CreateButton(parent, text, width, height, onClick)` → `UIPanelButtonTemplate`.
- `UI:CreateCheckbox(parent, label, getter, setter)` → `UICheckButtonTemplate` with label text; `cb:Refresh()`.
- `UI:CreateSearchBox(parent, width, onChanged)` → `SearchBoxTemplate` EditBox; calls `onChanged(text)` debounced 0.2s.
- `UI:CreateDropdown(parent, width, getOptions, getSelected, onSelect)` → modern `WowStyle1DropdownTemplate` + `dd:SetupMenu(function(dd, root) ... root:CreateRadio(text, isSelected, setSelected, value) end)` (see `Leatrix_Plus.lua` ~13362 for the proven pattern on this client). `getOptions()` → array of `{value=, text=}`. Returns dd with `dd:Refresh()` (calls `dd:GenerateMenu()` / updates text). If `DoesTemplateExist` exists and returns false for "WowStyle1DropdownTemplate", fall back to a simple button that opens `UI:ContextMenu` with radio entries.
- `UI:ContextMenu(owner, build)` → `MenuUtil.CreateContextMenu(owner, function(owner, root) build(root) end)`. Inside `build`, use `root:CreateTitle(text)`, `root:CreateButton(text, fn)`, `root:CreateDivider()`, `root:CreateCheckbox(text, isChecked, toggle)`; submenus: `local sub = root:CreateButton(text); sub:CreateButton(...)`.
- `UI:CreateTabs(frame, tabs, onSelect)` → bottom tab buttons (`CharacterFrameTabButtonTemplate`) anchored under the frame's bottom-left, using `PanelTemplates_SetNumTabs(frame, n)`, `PanelTemplates_SetTab(frame, i)`, `PanelTemplates_TabResize(tab, 0)`; `tabs = { {key=, label=} ... }`. Returns object with `:Select(key)`, `:SetTabShown(key, shown)` (re-anchors visible tabs in order), `:GetSelected()`.
- `UI:ClassColor(classFile)` → r, g, b (RAID_CLASS_COLORS; fallback 1,1,1). `UI:ColoredName(key, classFile)` → `"|cff......" .. Util.ShortName(key) .. "|r"`.
- `UI:ClassIcon(texture, classFile)` → sets `ns.TEX.classIcons` + `CLASS_ICON_TCOORDS[classFile]` on a texture (hide if unknown).
- `UI:QualityColor(q)` → r,g,b (`C_Item.GetItemQualityColor` or ITEM_QUALITY_COLORS).
- `UI:ItemText(itemID)` → quality-coloured name, or `"|cff808080Loading…|r"` (requests load).
- `UI:SetItemTooltip(owner, itemID, extraFn)`; `UI:HideTooltip()`.
- `UI:Glow(frame, on)` → LibCustomGlow `ButtonGlow_Start(frame)` / `ButtonGlow_Stop(frame)` (guard lib presence).
- `UI:CreateLabel(parent, text, fontObject)` → FontString; `UI:CreatePanel(parent)` → plain Frame with a subtle BackdropTemplate backdrop (dark translucent bg `Interface\Tooltips\UI-Tooltip-Background` 0.6 alpha, 1px border `Interface\Tooltips\UI-Tooltip-Border` edgeSize 12).
- `UI:EmptySlotTexture(sid)` → `select(2, GetInventorySlotInfo(ns.SLOTS[sid].slotName))` (cached; fallback `ns.TEX.slotBg`).
- `UI:AnnounceLine(text)` → sends to `ns.db.settings.announceChannel` via `C_ChatInfo.SendChatMessage or SendChatMessage`; falls back to RAID if RAID_WARNING not permitted (not leader/assist) and to PARTY / local print when not in raid. Chunk to ≤255 bytes.

### 12.2 UI/MainFrame.lua — `ns.MainFrame` (module)
- Window `DisasterZoneMainFrame`, 800 × 580, title `"DisasterZone"` + guild name when known. Right side of the title bar: a small status FontString showing `ns.Sync:GetStatusText()` (refresh on SYNC_STATUS/PEERS_UPDATED).
- Tab registry: `MainFrame:RegisterTab(key, label, order, createFn, isAvailableFn)` — `createFn(parent)` returns a panel frame (created lazily on first selection; parent = `frame.content`; panel fills parent). Panels may implement `panel:OnPanelShown()`.
- Tabs (registered by their modules in OnInit or at file load — MainFrame must accept registrations before its own frame exists): `"mybis"` "My BiS" (order 1, always), `"council"` "Council" (2, `ns.Guild:AmICouncil()`), `"loot"` "Loot Log" (3, council), `"settings"` "Settings" (4, always).
- `MainFrame:Open(key)` (shows window, selects tab; if tab unavailable → "mybis"), `MainFrame:Toggle()`, `MainFrame:IsShown()`, `MainFrame:GetFrame()`, `MainFrame:RefreshTabs()` (on CONFIG_UPDATED / DEMO_TOGGLED).
- On hide: `ns.BiS:Commit()` (flush pending edits) and hide the Picker.
- Launcher: LibDataBroker `NewDataObject("DisasterZone", {type="launcher", icon="Interface\\Icons\\INV_Misc_Bag_10_Blue", OnClick=..., OnTooltipShow=...})`; `LibStub("LibDBIcon-1.0"):Register("DisasterZone", obj, ns.db.settings.minimap)`. Left click toggle; right click → Open("settings"); tooltip: "DisasterZone", council status, sync status, "Left-click: open · Right-click: settings".
- Slash: `council`, `log`, `settings`/`config`.

### 12.3 UI/PaperDoll.lua — `ns.PaperDoll`
`ns.PaperDoll:Create(parent, opts)` → doll object. `opts = { readOnly=bool, onSlotClick=function(sid, which, mouseButton, tile) end, onSlotReceiveItem=function(sid, itemID) end }`.
- Layout (fits a 780 × ~470 area): left column tiles for `ns.DOLL_LEFT` (6) at x=8; right column `ns.DOLL_RIGHT` (8) mirrored at the right edge (labels on the inner side); bottom row `ns.DOLL_BOTTOM` (3) centred along the bottom. Row pitch 46px. Each **tile** = main ItemButton (36px) + alt ItemButton (22px, next to main, slightly lower) + two text lines (170px wide): line 1 main item name (quality colour) or `"<Slot label> — click to choose"` (grey) when empty; line 2 source text (grey, `ItemDB:GetSourceText(main, true)`) or obtained state in green ("Equipped", "In bags", "In bank", "Have token", "Marked obtained"). Alt button shows the alt item (or a faint empty square with "+" badge when editable and empty; hidden when read-only and empty).
- `doll.center` — a frame between the columns that callers can fill (MyBiS puts its summary card there; Council member view puts member info).
- `doll:Update(record, phase, ctx)` → paints all 17 tiles from `record.data.ph[phase]`. `ctx = { obtainedState=function(itemID) -> state|nil, awarded=function(itemID) -> bool, showEquipped=bool }`. When `showEquipped` and `record.data.eq[sid]` differs from main, show a tiny 14px icon of the equipped item under the main icon ("wearing").
- Two-hander: if main MH item's equipLoc is `INVTYPE_2HWEAPON`, the OH tile shows dimmed with text "Two-hander equipped in main hand" (still clickable when editable).
- Tile interactions (editable): main left-click → `onSlotClick(sid, "main", "LeftButton")`; alt click → `onSlotClick(sid, "alt", button)`; right-click main → `onSlotClick(sid, "main", "RightButton", tile)` (MyBiS opens the context menu); drag an item on a tile → `onSlotReceiveItem(sid, itemID)`. Read-only: clicks only show tooltips / shift-link.
- `doll:SetHighlight(sid)` (gold border on the tile being edited; nil clears).

### 12.4 UI/MyBiS.lua — `ns.MyBiS`
Panel for tab "mybis".
- Top bar (y = -8): phase buttons **P1…P5** (small tabs/buttons 44×22; selected highlighted; the guild's current phase gets a small gold "•" marker and tooltip "Guild's current phase"); **Spec** dropdown (ns.SPECS for my class; "Auto-detect" option calls DetectSpec); **Copy from ▾** (menu: "Copy P<n> (fill empty)", "Copy P<n> (overwrite)" for other phases with items); **Suggest ▾** only when `ns.Loon:IsAvailable()` ("Fill empty slots from LoonBestInSlot (<spec> P<phase>)", "Replace all (confirm)"); **Clear phase** (confirm StaticPopup `DISASTERZONE_CLEAR_PHASE`).
- Default selected phase: the guild's current phase (`ns.Guild:GetGuildPhase()`), remembered for the session.
- Body: `ns.PaperDoll:Create(panel, {readOnly=false, ...})` filling the rest.
- Center card (in `doll.center`): **Phase progress** "P2 · 9 / 17 obtained" + a thin progress bar; **Still needed from** — up to 6 lines "Karazhan — 3 (Prince 2, Curator 1)" grouped by raid (only main picks not obtained, via `ItemDB:GetSources` first source), then "Other sources — N" for items without a raid source; **Sharing** line: `ns.Sync:GetStatusText()`; a hint when the list is empty: "Click a slot to choose your best-in-slot item. Drag items from your bags onto a slot to use crafted / badge / dungeon items."
- Interactions: click main/alt → `ns.Picker:Open(phase, sid, which, anchorFrame)`; right-click tile → `UI:ContextMenu` with: "Choose main…", "Choose alt…", "Swap main / alt", "Mark obtained"/"Mark not obtained" (for main; uses `BiS:SetManualObtained`), "Clear slot", "Link main in chat"; drag item onto tile → `BiS:SetSlot(phase, sid, "main", itemID)` (it prints why if it doesn't fit).
- Refresh on MYLIST_CHANGED, OWNED_UPDATED, ITEMINFO_READY, CONFIG_UPDATED, SYNC_STATUS (status line only).

### 12.5 UI/Picker.lua — `ns.Picker`
Flyout window `DisasterZonePicker` (use `UI:CreateWindow`, 360 × 560) anchored to the right of the main window (`TOPLEFT` to main frame `TOPRIGHT` +2,0); not saved-position.
- `Picker:Open(phase, sid, which, anchor)`, `Picker:Close()`, `Picker:IsOpen()`.
- Header: "Choose <Slot label> (<Main|Alt>) · P<phase>"; current selection shown as an item button with a **Clear** button.
- Controls: search box (`UI:CreateSearchBox`); raid scope dropdown: "Raids up to P<phase>" (default) / "Only P<phase> raids" / "All raids"; checkboxes "Usable by my class" (default on) and "My armor type only" (default on; only shown for armor slots 1,3,5,6,7,8,9,10).
- List (`UI:CreateScrollList`, row 34px): headers for raid (gold, 20px) and boss (white, 18px) interleaved with item rows. Build data as a flat array of `{type="raid"|"boss"|"item", ...}` from `ItemDB:GetCandidates(sid, filter)`; after search filtering, drop headers that have no items. Item row: 28px icon, name (quality colour via `UI:ItemText`), subtitle grey: `"via <token name>"` for tier pieces (use `ItemDB:GetName(viaItem)` or "tier token"), else item type line (e.g. equipLoc label); right side markers: `"Main"`/`"Alt"` if already on this phase's list (in this or another slot), `"✓ owned"` if `BiS:IsObtained`. Hover → item tooltip. Click → `ns.BiS:SetSlot(phase, sid, which, itemID)` then `Picker:Close()`. Shift-click → link.
- Non-raid items: bottom hint "Shift-click an item link or drag an item from your bags here to use a non-raid item." — while the picker is open, hook `ChatFrameUtil.InsertLink` (hooksecurefunc once; only acts while `Picker:IsOpen()`): extract itemID; if `ItemDB:FitsSlot(id, sid)` → SetSlot + close (return nothing — don't block normal link insertion; that's fine). The whole picker frame also accepts drag & drop (OnReceiveDrag/OnMouseUp with GetCursorInfo).
- `ItemDB:Prefetch` all candidate ids on open; re-render on ITEMINFO_READY while open.
- Empty state text: "No raid items match. Try 'All raids' or untick the filters — or shift-click any item."

### 12.6 UI/Council.lua — `ns.CouncilUI`
Panel for tab "council" (only when `ns.Guild:AmICouncil()`; Demo makes it available).
- Toolbar row 1: **Phase** dropdown (P1..P5; default `ns.Guild:GetViewPhase()`); view switch buttons **Roster** | **Items** | **Member**; name search box.
- Toolbar row 2: **Class** dropdown (All + 9 classes), **Role** dropdown (All + roles), checkboxes "In my raid only", "Hide obtained".
- **Roster view** (default): `UI:CreateScrollList` rows 24px. Columns: presence dot (green = in raid, yellow = online, grey = offline) · 14px class icon · class-coloured name (120px) · spec (60px grey) · "Need n" (40px) · 17 cells of 20px ItemButtons (`sid` order 1..17; small gaps after 10 and after 14) · list age (grey "3d", orange if > 7 days). Column header row above: 16px empty-slot textures per sid with tooltip slot names. Cell = main item of that slot in the chosen phase: `SetState("obtained")` if in `ob`, `"awarded"` if `ns.Ledger:HasAward`, empty → dark slot texture. Cell tooltip: item tooltip + extra lines: "Main (P2)" / "Alt: <alt item name>", "Obtained" / "Awarded <ago>", "Wearing: <equipped item>". Click cell → switch to Items view focused on the boss that drops it (or Member view if no source). Click name → Member view.
- **Items view**: left list (200px): phase's raids → bosses (and "Other / no raid source") with demand counts "(n)"; right list rows 40px: 28px icon + item name + source; second line = wanters summary: class-coloured short names, main first; alts as grey "(alt)"; obtained hidden unless "Hide obtained" unticked (then grey ✓). Tooltip on row lists all wanters with details. Uses `ns.Store:GetWanters(itemID, {includeObtained=not hideObtained})` (restricted to the chosen phase: filter entries whose `phases` contains the phase).
- **Member view**: header (name, class, spec, rank name, "updated <ago>", addon version `ns.Sync:GetPeer(key)`), ◀ ▶ buttons to step through the filtered roster order, a read-only `ns.PaperDoll` (ctx: obtainedState from `data.ob`, awarded from Ledger, showEquipped=true), and in `doll.center` the member's recent awards (from `ns.Ledger:GetEntries({player=key})`, max 8 lines).
- Footer: "N members with lists · M in raid · K lists older than 7 days" + **Request sync** button (`ns.Sync:SendHello()`).
- Refresh on LIST_UPDATED/LISTS_RESET/LEDGER_UPDATED/GROUP_UPDATED/ROSTER_UPDATED/ITEMINFO_READY/CONFIG_UPDATED (debounced 0.2s, only when visible).

### 12.7 UI/LootLog.lua — `ns.LootLogUI`
Panel for tab "loot" (council only).
- Toolbar: search box (player or item name), checkbox "Show voided", **Add award…** button.
- List rows 26px: date/time (`date("%m/%d %H:%M", ts)`) · 20px item button · item name · winner (class-coloured; class from roster or record) · boss name (`ItemDB:GetBossRef(b)`) · "auto"/"manual" + recorder short name (grey). Voided rows grey with strike-like "(void)" suffix.
- Right-click row → menu: "Void entry" / "Restore entry", "Link item in chat", "Show member" (opens Council member view).
- **Add award…** → small dialog frame (`UI:CreateWindow("DisasterZoneAwardDialog", "Record award", 320, 200)`): item field (EditBox accepting shift-click via the same `ChatFrameUtil.InsertLink` hook pattern or item ID), winner dropdown (raid members first, then guild online, then all guild), note field, **Save** → `ns.Ledger:Award(...)`.
- Refresh on LEDGER_UPDATED, ITEMINFO_READY.

### 12.8 UI/DropPanel.lua — `ns.DropPanel`
Listens to `DROP`.
- **Council panel** (if `ns.Guild:AmICouncil()` and `alerts.councilPanel`, and the drop isn't a `roll` drop): window `DisasterZoneDropPanel` (340 wide, height fits content, max 520, scrolls). Header: boss name + raid (`ItemDB:GetBossRef(drop.b)`; "Unknown source" otherwise) + time; ◀ ▶ pager through `ns.Loot:GetHistory()`.
  - Per item block: 32px item button; name; subtitle (for tokens "Token → <slot> (<classes>)" via `ns.Data.TokenClasses`); candidate rows (18px) from `ns.Store:GetWanters(itemID, {includeObtained=false})`: presence dot, 12px class icon, class-coloured name, spec, badge `[BiS]` (gold) or `[Alt]` (blue) + `" P3"` if `phase ~= viewPhase`, `"won N"` if wonTonight > 0, 14px equipped-item icon (tooltip "Currently wearing"), "not in raid" grey for `not inRaid`. Max 8 rows then "+N more" (tooltip lists the rest). Items nobody wants: single dim line "Nobody has this on their BiS list".
  - Per item buttons: **Announce** (one line to raid via `UI:AnnounceLine`: `"DisasterZone: [item] — BiS: A, B · Alt: C"`, rate-limited 2s per item), **Award ▾** (context menu of the candidates + "Someone else…" → the LootLog award dialog prefilled) → `ns.Ledger:Award(itemID, key, drop.b)`; awarded items show "Awarded to X" in green.
  - Footer: **Announce all**, **Close**.
  - Placement: `dropPanelMode == "auto"` and `LootFrame:IsShown()` → anchor TOPLEFT to `LootFrame` TOPRIGHT (+4,0); else floating (saved position). Sound: `PlaySound(SOUNDKIT.RAID_WARNING)` if `alerts.sound` (guard SOUNDKIT key).
- **Personal toast** (everyone, if `alerts.personalToast`): if `ns.BiS:MatchItem(id)` returns matches for any dropped item, show `DisasterZoneToast` (300×56, top-centre y=-160, BackdropTemplate dark with gold 1px border): icon, "★ On your BiS list!" (gold), item name + "— <Slot> · P<phase> (main|alt)"; fades out after 8s unless hovered; click → link item into chat. Multiple matches → queue/stack (show next after dismiss). Plus chat line if `alerts.chat`. Sound if `alerts.sound` and not already played for the council panel.
- **Loot frame decoration** (if `alerts.lootBadges`): `hooksecurefunc("LootFrame_UpdateButton", function(index) ... end)` when the global exists; for `_G["LootButton"..index]` with `.slot`: get itemID from `GetLootSlotLink(button.slot)`; council → badge FontString (created once per button, right-aligned over the button) `"BiS ×n"` (gold) where n = in-raid, not-obtained main wanters (`Store:CountWanters(id, {raidOnly=true})`); non-council → `"★ Yours"` if `BiS:MatchItem` has an unobtained match; glow the button via `UI:Glow` when it's the player's own BiS and `alerts.glow`. Clear badges/glows on `LOOT_CLOSED` and when a button hides.
- Also expose `DropPanel:ShowDrop(drop)` and `DropPanel:ShowHistory()` (slash `/dz test` path uses DROP → this).

### 12.9 UI/Tooltip.lua — `ns.Tooltip`
- Hook `OnTooltipSetItem` via `HookScript` on `GameTooltip`, `ItemRefTooltip`, `ShoppingTooltip1`, `ShoppingTooltip2`, `ItemRefShoppingTooltip1`, `ItemRefShoppingTooltip2` (guard each exists). `local _, link = tooltip:GetItem()`.
- Dedupe: skip if the tooltip already contains a line starting with the DisasterZone marker for this item (scan `_G[tt:GetName().."TextLeft"..i]`), or track `tt.__cdlItem`/reset on `OnTooltipCleared` (HookScript).
- Lines (if `tooltip.enabled`):
  - Own: from `ns.BiS:MatchItem(id)` → first match: `"|cffff8000DisasterZone|r ★ Your P2 BiS (main) — Head"` gold, or `"Your P3 alt — Head"` blue; `" ✓ obtained"` green suffix when obtained; tokens: `"via token"`.
  - Council (if `AmICouncil()` and `tooltip.council`): `"DisasterZone: BiS for N (M in raid)"` then up to `maxNames` lines via `AddDoubleLine`: left = class-coloured name + `" (alt)"`/`" P3"`, right = `"in raid"`/`"obtained"`/`""` grey. `"+K more"` if truncated. Hold Shift → show all.
- Cache per itemID for 2s to keep hovering cheap (invalidate on LIST_UPDATED/MYLIST_CHANGED/OWNED_UPDATED/LEDGER_UPDATED).

### 12.10 UI/Settings.lua — `ns.SettingsUI`
Panel for tab "settings" + a Blizzard options entry: `Settings.RegisterCanvasLayoutCategory(canvas, "DisasterZone")` + `Settings.RegisterAddOnCategory(cat)` (guard `Settings`), where the canvas has a short description and a button "Open DisasterZone settings" → `ns.MainFrame:Open("settings")`.
- Sections:
  1. **Alerts**: checkboxes for each `alerts.*` key; "Drop panel position: Attach to loot window when open / Always floating" dropdown (`dropPanelMode`); "Minimum quality: Epic / Rare" (`qualityThreshold`); announce channel dropdown (Raid / Raid Warning).
  2. **Tooltips**: enabled, council lines, max names (dropdown 3/5/8/12).
  3. **Minimap button**: show/hide (`LibDBIcon:Show/Hide("DisasterZone")`, stores `minimap.hide`).
  4. **Loot Council (guild settings)**: read-only summary: "Council: ranks ≤ <rank name> + <names> − <names> · Current phase P2" + resolved council member list (short names, class coloured; online dot). If `ns.Guild:CanEditConfig()`: editor — rank dropdown (ranks from `GuildControlGetNumRanks`/`GuildControlGetRankName(i+1)` for index i), "Add name" edit box + button, list of added names with remove buttons, "Exclude name" similar, current-phase dropdown, **Save to Guild Info** → confirm popup `DISASTERZONE_SAVE_CONFIG` showing the tag → `ns.Guild:WriteConfig(cfg)`. Otherwise: explanatory text "Your Guild Master or an officer can set this up from their DisasterZone settings (it is stored as a small CDL{...} tag in the Guild Information text)."
  5. **View phase override**: dropdown "Follow guild (P2)" / P1..P5 → `settings.viewPhase`.
  6. **Demo mode**: checkbox "Demo data (fake guild members & raid) — try the council views solo" → `ns.Demo:SetEnabled`. Button "Simulate a boss drop" → `ns.Loot:SimulateDrop()`.
  7. **About**: version, protocol, "Peers seen: N · council online: M".
- Use a scroll frame (`UIPanelScrollFrameTemplate`) if content exceeds the panel height.

## 13. Guild config tag — Core/Guild.lua — `ns.Guild` (module)

- Tag format inside the Guild Information text: **`CDL{r1 p2 +Alice +Bob-OtherRealm -Carl}`**
  - `rN` — guild ranks with rankIndex ≤ N are council (0 = Guild Master). Default when no tag: `r1`.
  - `pN` — guild's current phase 1..5. Default: 1.
  - `+Name` — extra council member; `-Name` — excluded (wins over rank and +). Names without realm = own realm.
  - Tokens separated by spaces or commas; unknown tokens ignored. Only the first `CDL{...}` counts.
- Roster: `C_GuildInfo.GuildRoster()` on login (and at most every 15s on demand); rebuild on `GUILD_ROSTER_UPDATE` from `GetGuildRosterInfo(i)` (17 returns; `name` is "Name-Realm"; `rankIndex` 0-based; `isOnline` 9th; `classFile` 11th) → `roster[key] = {rankIndex, rankName, classFile, online, level}`; set `ready = true` after the first successful build (when `GetNumGuildMembers() > 0`). Then parse `GetGuildInfoText()` (may be nil/"" early → treat as default config but retry parse on next roster update). Fire `ROSTER_UPDATED`; fire `CONFIG_UPDATED(cfg)` when the parsed config or my council status changed. Also handle `PLAYER_GUILD_UPDATE` (joined/left guild → reset).
- API:
  - `Guild:IsReady()`, `Guild:GetGuildName()`.
  - `Guild:IsInGuild(key)`, `Guild:GetMember(key)` → roster entry, `Guild:IsOnline(key)`, `Guild:GetClass(key)`, `Guild:GetRankName(key)`, `Guild:GetMembers()` → array of keys (sorted).
  - `Guild:GetConfig()` → `{ rank=N, phase=P, add={[key]=true}, remove={[key]=true}, raw="CDL{...}" or nil }`.
  - `Guild:IsCouncil(key)` → `(roster[key] and (roster[key].rankIndex <= cfg.rank or cfg.add[key])) and not cfg.remove[key]` — returns false for keys not in the roster. Demo: `ns.Demo:IsEnabled()` → `IsCouncil(me)` true.
  - `Guild:AmICouncil()`.
  - `Guild:GetCouncilMembers()` → array of keys.
  - `Guild:GetGuildPhase()` → cfg.phase. `Guild:GetViewPhase()` → `ns.db.settings.viewPhase or cfg.phase`.
  - `Guild:CanEditConfig()` → `CanEditGuildInfo and CanEditGuildInfo()`.
  - `Guild:BuildTag(cfg)` → string (canonical order: r, p, +names sorted, -names sorted; strip own realm from names).
  - `Guild:WriteConfig(cfg)` → text = `GetGuildInfoText() or ""`; replace existing `CDL{...}` or append on a new line; refuse (print) if resulting length > 500; `SetGuildInfoText(text)`; request roster refresh; return true/false.

## 14. Core/Demo.lua — `ns.Demo` (module)
- `Demo:IsEnabled()`, `Demo:SetEnabled(bool)` (in-memory only, never saved; fires `DEMO_TOGGLED(enabled)` then `LISTS_RESET`), `/dz demo` toggles and prints.
- On enable: generate ~16 fake members (2 per class-ish; names like "Aldrin", "Brakka", ... with realm = own realm; classes/specs varied), each with lists for phases 1..3 (and 4..5 partially): for each sid pick a random candidate from `ns.ItemDB:GetCandidates(sid, {maxPhase=p, class=cl, usableOnly=true, primaryArmorOnly=true})` (main) and sometimes an alt; ~30% of picks in `ob`; `eq` = random earlier-phase items; `ts` random within last 10 days. Use a fixed-seed local PRNG (simple LCG) so the demo is stable across toggles.
- `Demo:GetRecords()` → `{[key]=record}`; `Demo:GetRoster()` → fake roster entries (Guild uses these for IsInGuild/GetClass/IsOnline/GetRankName when demo enabled); `Demo:IsInDemoRaid(key)` → ~10 of the fake members + me are "in raid".
- Store/Guild/Util consult Demo when enabled (see their sections). Ledger is NOT faked (real ledger stays), but the award dialog works with demo names.

## 15. Core/Loon.lua — `ns.Loon` (module) — optional templates
- `Loon:IsAvailable()` → `type(LBIS) == "table" and type(LBIS.RegisterSpec) == "function"` (LoonBestInSlot loaded).
- `Loon:GetSpecFunctions(classFile)` → map specLabel → loader function name, derived from LoonBestInSlot's `Guides/*.lua` (read that addon to get the exact function names, e.g. `LoadPaladinHoly`; Rogue has one "Dps" guide; Druid Feral has Bear/Cat guides).
- `Loon:GetTemplate(classFile, specLabel, phase)` → `{ [sid] = {main, alt} }` using the capture approach in `research/ux.md` §2 (temporarily replace `LBIS.RegisterSpec`/`AddItem`/`AddGem`/`AddEnchant`, call the loader in pcall, ALWAYS restore originals). Slot mapping from Loon's localized slot names (`LBIS.L[...]` reverse map) → sids: Head 1, Neck 2, Shoulder 3, Back 4, Chest 5, Wrist 6, Hands 7, Waist 8, Legs 9, Feet 10, Ring → 11 & 12 (first two distinct BIS, top up from Alt), Trinket → 13 & 14 (same), "Main Hand" → 15, "Off Hand" → 16, "Two Hand" → 15 (prefer the Two Hand BIS if its rank entry comes first; if a Two Hand is chosen, leave 16 empty), "Ranged/Relic" → 17. Main = first "BIS*" entry; alt = next entry. Cache per (class, spec, phase).
- Never error if Loon changes: every step guarded; on failure return nil and `ns:Debug`.

## 16. Test hooks for the harness
The harness (SCRATCH/tools) runs the addon in a mocked client. To make that easy:
- Init.lua sets the global `DisasterZone = ns` (harness may also expose `__NS`).
- Keep side effects out of file scope except table/function definitions, `ns:NewModule`, `ns:RegisterEvent`, `ns:On`, `ns:RegisterSlash`, `MainFrame:RegisterTab`. Create frames lazily (first show), except the event frame, AceComm registration and tooltip hooks (OnLogin).

## 17. Checking your work (no WoW client available)
- Python venv with a real **Lua 5.1** runtime (lupa): `SCRATCH\luaenv\Scripts\python.exe`.
- If `SCRATCH\tools\check.py` exists (another agent is building it; see `SCRATCH\tools\README.md`), run:
  `SCRATCH\luaenv\Scripts\python.exe SCRATCH\tools\check.py <your files>` — syntax errors + accidental global writes + unknown global reads (verify those against research/api.md or installed addons).
- Otherwise at minimum compile each file with Lua 5.1:
  ```
  SCRATCH\luaenv\Scripts\python.exe -c "import sys; from lupa import lua51; L=lua51.LuaRuntime(); f=sys.argv[1]; src=open(f,encoding='utf-8').read(); r=L.eval('function(s,n) local f,e=loadstring(s,n); return e end')(src,'@'+f); print(f, 'OK' if r is None else r)" "<path-to-file.lua>"
  ```
- A WoW-client mock harness (`SCRATCH\tools\harness.py`, multi-client, addon-message bus) may also be available — see its README. Implementers don't have to write harness tests; the integration phase will.
