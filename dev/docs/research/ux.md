# DisasterZone: reference addon study and proposed UX

**Can we build this? Yes.** Every piece DisasterZone needs is already shown working in an addon installed on this client:

- **Picking items:** a picker that browses raid, then boss, then item (LootReserve, AtlasLoot).
- **Paper-doll gear view:** TehBoxLootCouncil's player profile.
- **Tracking what you already have:** detection of equipped, bag and bank items (LoonBestInSlot).
- **Drop detection and "who wants this" views:** LootReserve, Raidify_Loot, TehBoxLootCouncil.
- **Tooltip additions:** Loon, LootReserve, AtlasBIStooltips.
- **Guild-wide sync:** AceComm plus LibDeflate (TehBoxLootCouncil).

Loon's guide files also give us a clean, phase-aware source for "start from the suggested BiS for my spec" templates (section 2).

The hard parts are not the UI. They are:
1. An accurate raid → boss → item table, including tier token → tier piece mappings.
2. Detecting drops when the loot council members are not the ones who loot the corpse.
3. Keeping everyone's lists synced to council members who are offline or out of range.

Nothing was modified. All paths are relative to `C:\World of Warcraft\_anniversary_\Interface\AddOns\`.

---

## 1. Reference addon study

### 1.1 LoonBestInSlot (`LoonBestInSlot/`)

**What it does**
- Per-spec BiS guide browser with tabs for Items, Gems, Enchants, Custom and Edit.
- Filters by Spec, Slot, Phase, Rank, Source and Zone.
- Detects whether you own an item: equipped, in bags, or in the bank.
- Adds "# Best for:" lines to item tooltips.
- Custom per-slot ranked lists, up to 8 items per slot, with a tooltip note on each.

**Layout**
- Window: 800×600 BackdropTemplate with `UI-DialogBox-Background-Dark` and a `UI-Tooltip-Border` edge (`UI/LootBrowser.lua:476-538`). The header row of dropdowns sits at y=-28 (`UI/LootBrowser.lua:318-474`).
- Dropdowns use hardcoded x offsets. Phase and Rank share x=330 and are swapped by show/hide.
- A Wowhead link strip sits under the dropdowns. Bottom tabs use `CharacterFrameTabButtonTemplate` (`UI/LootBrowser.lua:173-237`).
- **List row** (`Common.lua:563-737`), 46px tall:
  - Left: 32px icon, item-link-colored name plus "(BIS P1)", and a grey "Armor, Plate, Head" line.
  - Right half: the source type in a color per source (`createSourceTypeText`, `Common.lua:524-561`: Drop purple, Tier Token orange, Profession blue, Reputation teal, and so on), with the source text under it.
  - A 28px mini icon for the token, profession spell, or transmute input.
  - A 24px ownership icon at top-right: `checkmark.tga`, `bag.tga` or `bank.tga` (`Common.lua:681-692`).

**How you pick items**
- Guide browsing is list-only; there is no paper doll.
- The Custom Edit tab shows one row per slot with up to 8 icons and a pencil button (`UI/CustomEditList.lua:46-101`).
- The pencil opens a search overlay (`UI/SearchFrame.lua`):
  - A 600px `InputBoxTemplate` with a 0.5s debounce and a 4-character minimum. Spaces become `.*` for fuzzy matching.
  - Search only covers Loon's own item cache, filtered by slot (`SearchFrame.lua:5-40`).
  - Autocomplete supports arrow keys (`UI/AutoComplete.lua`), and results can be reordered up, down or deleted.

**Clever**
- Ownership states (equipped, bag, bank), including bank contents cached after `BANKFRAME_OPENED` (`UserItemCache.lua:57-111`).
- "Hide obsolete" drops items from phases earlier than what you already wear (`UI/ItemList.lua:114-173`).
- Tooltip merging: when every spec of a class wants an item, it prints just the class name (`UpdateTooltips.lua:55-81`).
- A tier-token tooltip lists the pieces the token buys.
- Phase ranges are written as `"1>3"`.

**Clunky**
- Rows are created per item and cached per spec name, so frames are never recycled (`LootBrowser.lua:78-119`).
- Slot names are localized strings used as data keys.
- Phase and Rank dropdowns overlap.
- No slot visualization.
- Spec IDs ignore the phase, and phases are collapsed at load (section 2).

**Reusable code**

| Pattern | Location |
|---|---|
| Async item info (`Item:CreateFromItemID():ContinueOnItemLoad`) | `Common.lua:179-216` |
| Tooltip on a button, with Shift for comparison and `HandleModifiedItemClick` | `Common.lua:302-366` |
| Tooltip hook stub (hooks OnTooltipSetItem, OnTooltipSetSpell and OnTooltipCleared, with a guard against adding lines twice) | `UpdateTooltips.lua:122-242` |
| Inline class icon from `UI-CharacterCreate-Classes` plus `CLASS_ICON_TCOORDS` | `UpdateTooltips.lua:1-7, 108-112` |
| Slot name → WoW slot codes | `UI/ItemList.lua:97-113` |

### 1.2 TehBoxLootCouncil (`TehBoxLootCouncil/`, ~41k lines)

**What it does**
- A full loot council system: sessions, voting, awards and a ledger.
- Also covers attendance, consumables, gear inspect, raid history, and a player profile with a paper doll.
- Pops up a boss drop list after kills.
- Contains its own hardcoded BiS spec lists.

**Layout**
- Main window: 910×560, a custom "Command Center" dark navy with amber and teal accents (`_UI.lua:7-40`). Tabs share the full width. Text is 6-10pt FRIZQT with OUTLINE throughout.
- **Player profile** (`_PlayerProfile.lua:567-1000`): a 430×510 window using the native `UI-DialogBox` backdrop.
  - Slot ID lists: `PANEL_L={1,2,3,15,5,9}` (head, neck, shoulder, back, chest, wrist), `PANEL_R={10,6,7,8,16,17,18}` (hands, waist, legs, feet, main hand, off hand, ranged), `PANEL_B={11,12,13,14}` (rings and trinkets along the bottom) (`:79-81`).
  - Empty-slot textures `UI-PaperDoll-Slot-*` (`:83-99`).
  - `GearIcon` (`:326-359`): 36px icons on a `UI-Quickslot2` background; empty slots are desaturated at alpha 0.25; quality border `Interface\Common\WhiteIconFrame` tinted by quality at 0.9 alpha for green and above.
  - Tooltip on hover, Shift-click inserts a chat link, highlight `ButtonHilight-Square` ADD.
  - The center holds a `DressUpModel` for yourself or a `PlayerModel` for others, falling back to a class icon (`:930-956`).
- **Boss drop popup** (`_LootWidget.lua:3433-3754`):
  - 240px wide: 26px header with boss name and "N dropped / M queued"; 24px rows with a 20px icon, quality border, name truncated at 18 characters, a 2-hour trade timer that changes color, and a `+`/`X` queue button.
  - Footer: "Queue All" and "Queue All & Start".
  - DIALOG strata, Shift-drag to move, position saved (`AddShiftDrag`, `:252-315`).
- Vote panel column grid (`TAB_*` at `_LootWidget.lua:5109-5114`): vote checkbox, roll checkbox, response badge, class icon, name, then data columns.
  - `StampPlayerLeft` (`:5313-5360`) draws a 2px left accent bar in the response color (class color otherwise), the class icon, a class-colored name, and a click-through that opens the profile.
- Council history (`_LootCouncil.lua:824-1150`): a 160px day list on the left; on the right, item rows with voter "chips" (18px, response badge plus class-colored name, winner star) that wrap to fit the width.

**Clever**
- "Replaced in phase" pills (SSC/TK blue, BT purple, SW green, `:4200-4215`, `:4769-4830`). This is the idea of item longevity: how many phases an item stays BiS.
- Players broadcast their own equipped gear (`_GearInspect.lua:729-791`), so council members don't need to be in inspect range.
- Alt-click on the loot window queues an item (`_LootWidget.lua:10355-10372`).
- An "Awarded to" tooltip line (`:8889-8915`).
- Encounter name aliases, such as Midnight → Attumen and the Opera variants → Opera Hall (`TehBoxLootCouncil.lua:1573-1590`).
- Async icon loader with a `GetItemInfoInstant` fallback and a `GET_ITEM_INFO_RECEIVED` retry (`TehBoxLootCouncil.lua:681-730`).
- Council membership defined by names plus guild ranks, broadcast by the leader, with a 2.5s debounce against flicker (`_LootCouncil.lua:190-281`).
- The access model: the GM and rank index 1 are trusted automatically, a guild/realm fingerprint is checked, and it states plainly that this is UI gating, not security (`_Access.lua:1-45`).
- Manifest/delta sync using LibDeflate (`_Comms.lua:1-40`).

**Clunky**
- Frames are created on every refresh and hidden with `pcall(r:Hide())`, so they leak. The code's own comment at `:5390` explains the leak-free pooled alternative.
- 6-9pt outlined fonts are hard to read, and the palette doesn't look native.
- BiS data is keyed by lowercase English item names (`BIS_SPEC_LIST :4031`, `BIS_REPLACED_IN :3875`), so it breaks on other locales.
- Names are truncated by character count, not pixel width.
- Everything lives in a 10k-line file.
- Boss-popup items come from a loot log filtered to today and raid zones, which is fragile.

**Reusable code**

| Pattern | Location |
|---|---|
| Slot mapping `EQUIP_TO_SLOTS` (rings, trinkets and 1H weapons can go in two slots) and `GetSlotsForItem` (async-safe) | `_GearInspect.lua:170-261` |
| Paper doll gear icon | `_PlayerProfile.lua:326-359` |
| Loot window snapshot on `LOOT_OPENED` | `_Loot.lua:88-100` |

### 1.3 LootReserve (`LootReserve/`)

**What it does**
- Soft-reserve system. Players browse raid → boss → item or search, and reserve.
- The server view lists reserves per item, highlights items currently in the loot window, and runs rolls.
- Tooltip lines "Reserved by" and "Won by".

**Layout**
- Client window: 750×450 `BasicFrameTemplateWithInset`, resizable (`Windows/ClientWindow.xml:364-365`).
  - A `SearchBoxTemplate` (193×20) sits over a category tree on the left (`:612-646`); the loot list is on the right (`:648-662`).
  - Rows are 44px (`ClientWindow.lua:167`): 32px icon, link-colored name, and a misc line such as "Kara > Moroes" or "Head, Plate".
  - Text is red if you can't use the item. There is a favorite star.
- Tree: expansion, then raid ("[10] Karazhan"), then bosses. Sub-bosses such as the Servant Quarters rares are indented and headers are allowed (`ClientWindow.lua:545-735`). Rows use `UI-QuestTitleHighlight` for highlight and checked states and have an eye toggle to hide a category.
- **Server reserve list** (`Windows/ServerWindow.lua:133-228`):
  - Each item row has the reserving players stacked beneath it, each class-colored, with "(not in raid)" or "(offline)" in grey.
  - The misc line reads "In loot" while the item is in the open loot window, plus a `LibCustomGlow.ButtonGlow_Start` glow on the icon. After looting it reads "Looted by X". Items not yet looted fade to 0.25.
- Roll request popup: a small resizable window, minimum 364×90, with a glowing icon when the item is reserved (`Windows/RollRequestWindow.lua:1-12, 118-122`).

**How you pick items**
- Click a boss in the tree, then click Reserve on a row.
- Typing in search switches to a "Search Results" category.
- Search matches item name, item description (type and slot), source raid and boss names, and the names of players who reserved it; it also accepts a raw item ID (`ClientWindow.lua:213-244`).
- Searching for a tier piece finds its token.
- Chat `/find`, `/link` and `/getitem` rank results as exact, then contains, then other (`ItemSearch.lua:70-133`).

**Clever**
- Searching matches player names as well as items.
- Frame pooling: `list.Frames` is reused, extras are hidden, and headers are created lazily (`ClientWindow.lua:140-212, 530-535`).
- Batched item caching with the list re-rendered on load (`ClientWindow.lua:500-525`).
- The unusable-item check scans the tooltip for class restrictions, "Already known", unique-equipped, and quest-drop status (`ItemConditions.lua:150-300`).
- Class proficiency table, including TBC tweaks (no 1H axes for rogues, no polearms for druids) and a list of dual-wield classes (`Libs/ItemCache/ItemCache.lua:418-487`).
- Token → reward map (`Data.lua:17451`, API `Data.lua:21317-21328`).
- Guard for `GetLootSlotLink` sometimes returning an empty link like `|Hitem::…[]` (`Server.lua:1149-1190`, `LootReserve.lua:1202-1217`).

**Clunky**
- Loot arrays use `0` as a separator.
- A 1.4 MB item-ID list is loaded for full search.
- The layout is heavily XML and the server window is very dense.
- It uses `UnitGUID("target")` to guess the corpse instead of `GetLootSourceInfo`.

**Data example (`Data.lua:3897`)**

```lua
[2010] = { Name="Karazhan", ButtonName="[10] Karazhan", NameShort="Kara", Expansion=1,
  Children = Squish{ { Name="Attumen the Huntsman", Loot={28477,28507,...,0, 28510,28509,0,...} },
                     { Name="Servant Quarters", Header=true },
                     { Name="Rokad the Ravager", IndentType=1, Loot={30684,...} }, ... } }
```

### 1.4 Raidify and Raidify_Loot (`Raidify_Loot/`)

**What it does**
- Imports wishlists from Raidify's web app, with a tier (BiS / Upgrade / Minor / Offspec / Pass), a rank, and officer priorities.
- A candidate card opens by itself when the master looter opens the corpse.
- Clicking a name records the award. There are also Disenchant and Bank dispositions.
- The source is full of UX reasoning comments. Treat them as a design review we get for free.

**Layout**
- Candidate card (`LootWindow.lua:95-250, 317-627`):
  - 420px wide, flat `WHITE8X8` 1px border, DIALOG strata, position saved (`:103-107`), in `UISpecialFrames` so ESC closes it.
  - Header: 32px icon, title, and a subtitle.
  - Rows are 34px; 12 are visible, then it scrolls, with a "13-24 of 27" note.
  - Each row: rank or priority `P1`, class-colored name, the class name as a plain word (for color-blind readers), a tier word on the right in the tier color, and a right-aligned detail line.
  - The detail line holds "cannot use", "not in raid", "won N tonight", "+N offspec", "att%", and "days since loot".
- Tier colors (`:53-59`): BiS `{.98,.78,.22}`, which is deliberately not the heading gold; Upgrade `{.41,.80,.94}`; then greys that differ by lightness.
- Sort order (`Loot.lua:325-466`): **present in the raid**, then officer priority, then tier, then wishlist rank. Anyone in the raid who didn't list the item still appears, unranked, rather than being left off.

**Clever**
- "Nobody wishlisted this — showing the raid."
- Ineligible people stay visible but marked, so nobody wonders whether someone was skipped.
- The offspec toggle resets for every item.
- The first click on an offspec row arms offspec instead of awarding.
- The header shows "Loading…" with a 4-second give-up for uncached items (`:355-375`).
- The theme follows a "chroma ceiling": window chrome stays desaturated, class and quality colors stay saturated (`Raidify/Theme.lua:13-40`).

**Clunky**
- Clicking a row awards immediately, so a wrong click is costly. They add mitigations.
- It depends on the web import and is not slot- or BiS-aware in-game.

**Loot detection**
- `OnLootOpened` reads quality correctly: it is the 5th return of `GetLootSlotInfo`.
- It uses `GetLootSourceInfo(slot)` for the corpse GUID.
- Details at `LootSession.lua:465-527`.

### 1.5 AtlasBIStooltips (`AtlasBIStooltips/`)

**What it does**
- Tooltip only: "AtlasLootTBC Phase X BiS for / Rank:", then one line per class and spec with a class icon, class-colored, and the rank right-aligned (`AtlasBIStooltips.lua:127-205`).

**Data format**

```lua
local bis = sliccNote:RegisterBIS("Paladin", "Holy_P2")
sliccNote:RECslot(bis, "30728", "1")   -- itemID, rank within its slot
```

- There is **no slot field**, and phases are encoded as a `_P2` or `_P3` suffix on the spec name.
- It cannot drive a paper doll without deriving the slot from each item's equip location.

**Clunky**
- Forces `bisPhase = 3` on every login, ignoring the user's choice (`ConfigManager:Initialize`, around line 68).
- Hard dependency on AtlasLoot.
- The data files are written in an obfuscated-looking style.
- I read the code and did not see anything malicious.

### 1.6 RaidHelper_TBC (`RaidHelper_TBC/`)

**Layout**
- 540×560 window with the native `UI-DialogBox` border, custom tab buttons, and `UIPanelScrollFrameTemplate` scroll areas (`UI_Main.lua:337-380, 884-915`).
- **Raid Check matrix** (`UI_RaidCheck.lua:275-520`) is the closest existing analogue to a roster × slot grid:
  - Header row of 16px buff icons. Right-click a header to ignore that column; it is then desaturated at alpha 0.4.
  - 14px rows grouped under "Group N" subheaders, class-colored names with a grey `[spec]` tag.
  - Cells show `+`, `-` or `~`. Right-click a cell to ignore it for one player. Hovering a cell explains it.
- Attendance heat color: red → yellow → green (`UI_Attendance.lua:25-45`), plus a search filter.

**Clunky**
- Content is rebuilt from new frames on each refresh (`RCClearAll`/`RCNewContent`).
- 14px rows are tiny, and cells are text glyphs rather than icons.

### 1.7 AtlasLootClassic GUI (`AtlasLootClassic/GUI`, `Button`)

**Layout**
- Main window 920×600 (`GUI.lua:1160-1300`).
- Top: module and subcategory dropdowns, 245px each.
- Right: a difficulty selector (2 entries), then a boss list 320px wide with 22 visible entries, then an "extra" list (5).
- Left: a 560×450 item area containing **30 pooled buttons** in two columns of 15 (`ItemFrame.lua:24-73`).
- Each button is 270×28 with a 26px icon, a name line, an "extra" line, a completed check (`ReadyCheck-Ready`), a favorite marker (`VignetteKill` atlas), a phase indicator, and a quality-border overlay (`Button/Button.lua:232-340`).

**How you pick items**
- Module → instance → boss.
- Ctrl-click previews the item on your character (`DressUpItemLink`, `Item_type.lua:141`); Shift shows comparison tooltips; Shift-click inserts a chat link.
- The class filter and search **dim** non-matching items to alpha 0.33 instead of hiding them (`ItemFrame.lua:21, 93-120`), so the loot table keeps its familiar layout.

**Data**
- `data["Karazhan"].items[i] = { name=AL[...], npcID=16152, [NORMAL_DIFF] = {{1,28477},{2,28507},...,{16,28509}} }` (`AtlasLootClassic_DungeonsAndRaids/data-tbc.lua:2386+`).
- Every boss has an **npcID**, which is exactly what we need to map a loot corpse GUID to a boss. The module declares GPL v2.
- The `AtlasLootClassic_BiS` module has flat ranked lists per spec and slot with **no phases**, so Loon is the better template source.

**Clunky**
- Pages instead of scrolling.
- A large, heavy module system.

### 1.8 Client API confirmations from other installed addons

These are features other addons on this client already use, so DisasterZone can rely on them:

| Feature | Confirmed by |
|---|---|
| `WowScrollBoxList` + `WowTrimScrollBar` + `CreateScrollBoxListLinearView` | `Auctionator/Source/Tabs/Shopping/Mixins/RecentsContainer.lua:111-134` |
| `CreateFrame("ItemButton", …)` with `.IconBorder` | `GudaBags/UI/ItemButton.lua:621`, Auctionator `ViewItem.lua:25` |
| `ButtonFrameTemplate` and `PortraitFrameTemplate` | GudaBags, WeakAurasOptions |
| On Classic/Anniversary, tabs use `CharacterFrameTabButtonTemplate` | `GudaBags/UI/TabPanel.lua:231-233` |
| Shift-click link capture: hook `ChatFrameUtil.InsertLink` if present, else `ChatEdit_InsertLink`, and insert into your own focused edit box | `WowSimsExporter/Libs/AceGUI-3.0/widgets/AceGUIWidget-EditBox.lua:20-37` |
| Drag-and-drop from bags via `OnReceiveDrag` + `GetCursorInfo()` | same file, `:81-100` |
| Classic `LootButton1..N` loot buttons still exist | `RXPGuides/InventoryManager.lua:430-437` |
| `ENCOUNTER_END` fires | TehBoxLootCouncil |
| `LibCustomGlow-1.0` | bundled in `LootReserve/Libs` |

---

## 2. LoonBestInSlot guide format and how DisasterZone can use it for templates

### Load path
1. `Guides/Guides.xml` includes one file per spec, for 25 specs.
2. Each file defines `function LBIS:Load<Class><Spec>()`.
3. `LBIS:LoadGuides()` (`Common.lua:5-31`) calls them from `LBIS:Startup()` (`LoonBestInSlot.lua:36-44`), which runs on `PLAYER_ENTERING_WORLD` (`UpdateTooltips.lua:227-242`).
4. `LBIS` is a global table (`Localization/localization.core.lua:1`).

### Encoding (exact)

```lua
function LBIS:LoadPaladinHoly()
    -- one RegisterSpec per phase: (localized class, localized spec, phase string, wowhead URL)
    local spec0 = LBIS:RegisterSpec(LBIS.L["Paladin"], LBIS.L["Holy"], "0", "https://www.wowhead.com/tbc/guide/...")
    local spec1 = LBIS:RegisterSpec(LBIS.L["Paladin"], LBIS.L["Holy"], "1", "...")
    ...                                                                         -- "2","3","4","5"
    LBIS:AddGem(spec0, "25897", "3", "True")                 -- gemItemID, gem quality "3"/"4", isMeta "True"/"False"
    LBIS:AddEnchant(spec0, "35445", LBIS.L["Head"])          -- enchant spellID/itemID, slot
    LBIS:AddItem(spec1, "29061", LBIS.L["Head"], "BIS")      --Justicar Diadem   (PaladinHoly.lua:169)
    LBIS:AddItem(spec1, "28803", LBIS.L["Head"], "Alt")      --Cowl of Nature's Breath
    ...
    LBIS:AddItem(spec3, "32528", LBIS.L["Ring"], "BIS")      --Blessed Band of Karabor   (:357)
    LBIS:AddItem(spec3, "32238", LBIS.L["Ring"], "BIS")      --Ring of Calming Waves
    LBIS:AddItem(spec3, "29309", LBIS.L["Ring"], "BIS")      --Band of the Eternal Restorer
    LBIS:AddItem(spec3, "30736", LBIS.L["Ring"], "Alt")      --Ring of Flowing Light
end
```

**Phase numbers**
- `"0"` = pre-raid, `"1"` = Kara/Gruul/Mag, `"2"` = SSC/TK, `"3"` = Hyjal/BT, `"4"` = ZA, `"5"` = Sunwell.
- `"99"` means pre-patch. The code handles it, but no shipped guide uses it.
- Every guide defines all six phases, and every phase block lists all 15 slot keys, so each phase is complete on its own.
- Loon's `LBIS.CurrentPhase = 3` (`Common.lua:3`).

**Slot keys** are English canonical names wrapped in `LBIS.L[...]`, so the string you see at runtime is **localized**:
- `Head, Neck, Shoulder, Back, Chest, Wrist, Hands, Waist, Legs, Feet, Ring, Trinket, Main Hand, Off Hand, Two Hand, Ranged/Relic`.
- `Main Hand~Off Hand` appears only on enchants.
- **Ring and Trinket are single keys, with no 1 and 2.**

**Rank values**
- `"BIS"` (3778 across all guides) and `"Alt"` (10324).
- Tank variants: `"BIS Mit"` 148, `"BIS Thrt"` 118, `"BIS Stam"` 10, `"Alt Mit"` 178, `"Alt Thrt"` 185, `"Alt Stam"` 32.
- One stray `"Alt/BIS"`.
- **Order in the file is the priority order.**
- Several "BIS" entries per slot are common. Ring has between 1 and 5 BIS entries depending on spec and phase, and Holy Paladin pre-raid Wrist has 3. "BIS" means "top tier", not "unique best".
- Weapons can be ambiguous: Balance Druid P1 lists 1 Two Hand BIS and 2 Main Hand BIS.

**Item sources** live in `LBIS.ItemSources[itemID]`, for example `DB/ItemSources.lua:1704`:

```lua
[29061] = { Name="Justicar Diadem", SourceType=LBIS.L["Tier Token"], Source=LBIS.L["Prince Malchezaar"],
            SourceNumber="29760", SourceLocation=LBIS.L["Karazhan"], SourceFaction="B" },
```

- `SourceType` is one of Drop, Tier Token, Dungeon Token, Profession, Reputation, Quest, PvP, Vendor, Token, Transmute.
- `~` separates alternative sources and `&` joins combined ones.
- `SourceNumber` holds the token item ID, badge cost, or skill level.

**Do not read `LBIS.ItemsBySpecAndId` for templates.** At load, `AddItem` (`LoonBestInSlot.lua:98-160`):
- skips phases above the user's `LBISSettings.ShowPhase`;
- merges all phases into one record per item and spec, with phase ranges like `"1>3"`;
- rewrites earlier-phase "BIS" to "Alt".

The spec ID is `Spec..Class` (for example `"HolyPaladin"`), with no phase.

### Recommended integration: runtime capture with Loon as an optional dependency

Loon ships no license file, so reading its data at runtime is cleaner than copying it into DisasterZone:

```lua
-- DisasterZone.toc: ## OptionalDeps: LoonBestInSlot
local function CaptureLoonGuide(fnName)           -- e.g. "LoadPaladinHoly"
  local L = LBIS; if not (L and L[fnName]) then return end
  local saved = { L.RegisterSpec, L.AddItem, L.AddGem, L.AddEnchant }
  local out = {}                                   -- out[phase] = { {slotKey, itemID, rank, order}, ... }
  local rev = {}; for _, k in ipairs(CANON_SLOTS) do rev[L.L[k]] = k end   -- localized -> canonical
  L.RegisterSpec = function(_, class, spec, phase) return { Phase = tonumber(phase) } end
  L.AddItem = function(_, e, id, slot, rank)
      local t = out[e.Phase] or {}; out[e.Phase] = t
      t[#t+1] = { slot = rev[slot] or slot, itemID = tonumber(id), rank = rank, order = #t + 1 } end
  L.AddGem, L.AddEnchant = function() end, function() end
  local ok = pcall(L[fnName], L)
  L.RegisterSpec, L.AddItem, L.AddGem, L.AddEnchant = unpack(saved)
  return ok and out
end
```

**Turning a captured phase into a DisasterZone template**

For each slot key, walk the entries in file order:
- **Normal slots:** the primary is the first entry whose rank starts with `BIS`. The next 2-3 entries become alternates.
- **Ring and Trinket:** the first two distinct BIS entries fill slot 1 and slot 2, topped up from Alt if there are fewer than two.
- **Weapons:** if both a Two Hand BIS and a Main Hand BIS exist, show **both options** as suggestions and let the player choose.
- **Tank variants:** ask once whether the player prefers Mitigation, Threat or Stamina. Default to Mitigation.
- **Slot for picking:** prefer the equip location from `GetItemInfoInstant` over Loon's localized slot strings.

Fallback sources:
- `AtlasLootClassic_BiS`: ranked lists per slot, no phases.
- `AtlasBIStooltips`: no slot info, phases as spec suffixes.

---

## 3. Takeaways across all addons

**Borrow**
1. Paper-doll slot IDs and empty textures (TehBox), but look the texture up with `GetInventorySlotInfo(slotName)` rather than hardcoding it.
2. The raid → boss tree with search that also matches boss and player names (LootReserve).
3. Dim instead of hide when filtering (AtlasLoot).
4. Ownership states: equipped, bag, bank (Loon).
5. Sort by who is present in the raid first, and show "cannot use" or "not in raid" without hiding the person (Raidify).
6. Always pair color with a word: class name, "BiS", "alt" (Raidify's color-blind rule).
7. A glow on the loot icon when the item concerns you (LootReserve).
8. Movable popups with saved positions that ESC can close (Raidify, TehBox).
9. Players broadcast their own gear, so no inspecting is needed (TehBox).
10. Manifest/delta sync (TehBox).
11. Pooled rows, or ScrollBox, which is confirmed available.

**Avoid**
1. Creating frames on every refresh (TehBox, RaidHelper, Loon).
2. Data keyed by localized names (TehBox, Loon).
3. 6-8pt outlined fonts and custom neon palettes (TehBox).
4. Settings that reset on login (AtlasBIStooltips).
5. Absolute x-offset toolbars that overlap (Loon).
6. Rows where a single click writes something that can't be undone (Raidify notes this themselves).

---

## 4. Proposed UX for DisasterZone

### 4.0 Window and navigation
- **Opening it:** `/dz`, plus a minimap/LDB button via LibDBIcon (Loon and TehBox bundle it).
- **Main window:** `ButtonFrameTemplate`, base size **660×520**, resizable up to 1000×760 (the Council view gains larger cells). Portrait is the class icon (or DisasterZone icon); ESC-closable via `UISpecialFrames`; position saved.
- **Bottom tabs** (`CharacterFrameTabButtonTemplate`): **My BiS** | **Council**¹ | **Loot Table**¹ | **Settings**.
  - ¹ Shown only to loot council members. Whether regular raiders get a read-only version is an open question (section 5).

### 4.1 My BiS editor (660×520)

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│(◎) My BiS — Tehlo <Casual Disaster>                                         [x] │ title 24
│    Holy Paladin [▾]        [Pre][ P1 ][ P2 ][ P3 ][ P4 ][ P5 ]    [Suggest ▾]   │ y-32; phase tabs 44×22
│    P1: ███████████░░░░░░ 9/17 obtained        ● Shared with guild 2m ago        │ y-56; bar 160×8
├─────────────────────────────────────────────────────────────────────────────────┤ y-78
│ ┌36┐ Justicar Diadem          ✓│                    │ Justicar Gloves    ┌36┐  │ rows 42 (36+6)
│ └──┘ Prince Malch. · Kara      │                    │  The Curator · Kara└──┘  │ label 170, 2 lines
│ ┌36┐ Emberspur Talisman        │   DressUpModel     │ Belt of Divine Insp┌36┐  │
│ └──┘ Doomwalker · World        │   180 × 336        │  Moroes · Kara     └──┘  │
│ ┌36┐ Justicar Pauldrons    +2  │   wearing BiS      │ Legs …             ┌36┐  │
│ ┌36┐ Stainless Cloak …         │                    │ Feet …             ┌36┐  │
│ ┌36┐ Justicar Chestpiece       │  [Current | BiS]   │ Ring 1 …           ┌36┐  │
│ ┌36┐ (empty)  Click to choose  │   toggle  18px     │ Ring 2 …           ┌36┐  │
│ ┌ Still needed from ───────┐   │                    │ Trinket 1 …        ┌36┐  │
│ │ Kara 5 · Gruul 1 · Mag 1 │   │                    │ Trinket 2 …        ┌36┐  │
│ │ Badges 2 · Crafted 1     │ 212×84                 │                          │
│ └──────────────────────────┘                                                    │
│          ┌36┐              ┌36┐              ┌36┐                              │ weapons row y-420
│        Light's Justice   Triptych Shield   Libram of Souls R.                   │ label under, 120w
└─────────────────────────────────────────────────────────────────────────────────┘
```

**Arrangement**
- Left column (212px: 36 icon + 6 + 170 label): Head, Neck, Shoulder, Back, Chest, Wrist.
- Right column (mirrored, label on the left): Hands, Waist, Legs, Feet, Ring 1, Ring 2, Trinket 1, Trinket 2.
- Bottom row: Main Hand, Off Hand, Ranged/Relic.
- The two spare rows under the left column hold a **"Still needed from"** card: remaining items grouped by source. This tells players where to farm.
- The center model uses `DressUpModel:TryOn(itemID)` to show the BiS set, with a toggle to show current gear. It is optional and can be turned off for performance.

**Slot tile**
- 36px `ItemButton`: `UI-Quickslot2` background, `IconBorder` or `WhiteIconFrame` tinted by quality, and `ButtonHilight-Square` ADD for hover.
- Label line 1: item name in its quality color (GameFontNormalSmall-sized, truncated by pixel width).
- Label line 2: "Boss · Raid" in grey (GameFontDisableSmall).
- Tier pieces show "Token · Prince · Kara".

**Slot states**

| State | Visual |
|---|---|
| Empty | Blizzard empty-slot texture from `GetInventorySlotInfo`, desaturated at 0.5 alpha; label "Click to choose" |
| Suggested (template ghost) | Suggested icon desaturated at 45% alpha, grey "Suggested — click to accept" |
| Chosen, needed | Full color with quality border |
| Obtained – equipped | 12px `ReadyCheck-Ready` check bottom-right, green "Equipped" on line 2 |
| Obtained – bags / bank | 12px bag or bank glyph (Loon pattern). Tier pieces also count if you hold the matching token |
| Obtained – manual | Grey check (set from right-click) |
| Has alternates | "+2" badge top-right, 10pt |
| Off hand locked by a 2H | Desaturated tile with "2H" text; clicking explains why |
| Can't equip / wrong slot | Red name with a tooltip reason. Still allowed, but flagged to the council |

**Slot interactions**
- **Click:** open the picker for that slot. The selected tile stays highlighted.
- **Right-click menu:**
  - Choose…
  - Add alternate…
  - Reorder alternates
  - Mark obtained / not obtained
  - Clear
  - Copy from previous phase
  - Link to chat
- **Shift-click:** link to chat. **Ctrl-click:** preview on the model (native conventions via `HandleModifiedItemClick`).
- **Drop an item from your bags on a tile:** sets it, if its equip location fits (`OnReceiveDrag` + `GetCursorInfo`).
- **Warnings:** a unique-equipped duplicate in Ring or Trinket 1/2; a 2H in Main Hand locks Off Hand; the weapon config can be flipped with an inline "2H ⇄ 1H + OH" toggle.

**Phase tabs**
- A small dot on each tab shows completeness: grey = empty, half = partial, gold = full.
- The guild's current phase (set by an officer and synced) gets a gold underline and opens by default.
- An empty phase shows a centered call to action: [Copy from P1] [Start from suggested] [Start empty].

**Suggest menu (only if Loon is installed)**
- "Show suggestions in empty slots": the ghost mode, the default for first-time users.
- "Fill empty slots".
- "Replace all (confirm)".
- A spec dropdown for off-spec templates.
- The tank preference: Mitigation, Threat or Stamina.

**Footer and sync**
- Changes save automatically and sync with a 2-second debounce.
- The status line shows "Shared 2m ago ✓", "Pending…", or orange "Not shared (not in guild channel)".

**Item picker: a 320×520 flyout docked to the right edge of the main window**

It uses `BasicFrameTemplateWithInset` and keeps the paper doll visible.

```
┌ Choose: Head ─────────────────────────── [x] ┐ 320
│ [🔍 Search raid items, or paste/shift-click ] │ SearchBoxTemplate 296×20
│ [Phase 1 raids ▾]   ☑ Plate only  ☐ All usable │ dropdown 140, checks 22
│ ──────────────────────────────────────────── │
│ ▾ Karazhan (6)                               │ header 20 (GameFontNormal, gold)
│   ▾ Prince Malchezaar                        │ subheader 18 (white)
│   ┌28┐ Justicar Diadem            ★Suggested │ row 34: icon 28 + 2 lines
│   └──┘ Plate · via Helm of the Fallen Champ. │
│   ┌28┐ Helm of … (other)            ✓ owned  │
│   ▸ Nightbane (1)                            │
│ ▸ Gruul's Lair (1)                           │
│ ▸ Magtheridon's Lair (2)                     │
│ ▸ Other suggested (badges / crafted) (3)     │ only from Loon suggestions
│ ──────────────────────────────────────────── │
│ Shift-click or drag any item here to use a   │ hint, GameFontDisableSmall
│ non-raid item (quest, crafted, badge…)       │
└──────────────────────────────────────────────┘
```

- **Scope:** filtered to the slot's equip locations, using TehBox's `EQUIP_TO_SLOTS` mapping plus a Two Hand vs Main Hand/Off Hand distinction.
- **Class filter:** LootReserve's proficiency table plus a tooltip scan for "Classes:".
- **Armor default:** "My armor type" means the class's primary armor type. "All usable" widens it.
- **Search:**
  - 0.25s debounce, 3+ characters or an item ID.
  - Matches item names and boss/raid names (LootReserve).
  - Covers the DisasterZone raid DB, not the whole game item list.
  - Non-raid items enter via Shift-click (the `InsertLink` hook, active only while the box has focus) or by dragging from bags, and are tagged with source "Other".
- **Row actions:**
  - Click: set as primary.
  - Right-click: add as alternate (#2, #3).
  - Hover: tooltip plus a live preview on the center model.
  - Ctrl-click: pin the preview. Shift-click: link.
- **Guidance labels:** "★Suggested" for the Loon pick and "✓ owned".
- **Empty state:** "Nothing in P1 raids for Head — try 'All usable' or shift-click an item."

### 4.2 Council overview (same window, **Council** tab, 660×520, resizable)

**Toolbar**
- Row 1 (y-32): `Phase [P1 ▾]` `Raid [All ▾ / Kara / Gruul / Mag / Boss…]` then a segmented view switch `(•) Roster ( ) Items ( ) Member` then `[🔍 player or item ]`.
- Row 2 (y-56):
  - 9 class toggle icons at 18px (off = desaturated).
  - Armor type `[Cl][Le][Ma][Pl]` and role `[T][H][M][R]` as 22px toggles.
  - `☑ In my raid now`, `☐ Hide obtained`.
  - `Sort [Most needed ▾]`, with options Name, Class, Most needed, Progress %, Last updated.

**Roster matrix**

```
                         Armor                           Jewelry        Weapons
 Name (130)        Need │Hd Nk Sh Bk Ch Wr Hn Wa Lg Ft │R1 R2 T1 T2 │MH OH Rg │   ← header: 18px empty-slot icons
 ─────────────────────────────────────────────────────────────────────────────
 ● ⚔ Tehlo   HPal  8 ▮▮▮▯│▣  ✓  ▣  ▣  ·  ▣  ▣  ▣  ✓  ▣ │▣  ▣  ✓  ▣  │▣  ▣  ✓  │   ← rows 22 (cells 20 @ 22 stride)
 ● ⛨ Arwen   PPal  5 ▮▮▮▮│…                                                        
 ○ ✦ Brax    Ret  11 ▮▯▯▯│…  (row at 60% alpha: not in raid)                        
 ─────────────────────────────────────────────────────────────────────────────
 18 members · 12 in raid · 3 lists older than 7 days (!)          [Request sync]
```

- **Width:** 12 pad + 130 name + 60 need + 17×22 cells + 3×6 group gaps + 20 scrollbar = about 614px, so it fits in 660.
- **Height:** about 16 rows visible at 22px. A **compact density** option uses 18px rows and 16px icons (about 20 rows).
- **Left side of each row:**
  - Presence dot: green = in raid, yellow = online in guild, grey = offline.
  - 14px class icon, class-colored name, and a grey short spec word so class isn't shown by color alone.
  - "Need" count with a 4-segment bar.
  - An orange "!" if the list is stale; the tooltip shows the last sync time and version.
- **Cell states:**
  - Needed: full-color 20px icon with a 1px quality border.
  - Obtained: desaturated at 40% alpha with a 10px green check.
  - No pick: "·" on a dark cell.
  - Picked item the member can't use: red corner.
- **Raid or boss filter:** cells whose item drops there get a 1px gold border, and all other cells dim to 0.35 (AtlasLoot's dimming). This instantly answers "who needs something from Prince?"
- **Interactions:**
  - Hover a cell: item tooltip plus a DisasterZone footer showing primary or alt rank, obtained source, the member's note, and when that slot was last changed.
  - Click a cell: jump to the Items view focused on that item.
  - Click a name: open Member detail.
  - Click a column header: sort by "needs this slot".
  - Right-click a header: hide the column (RaidHelper).
  - Mouse wheel scrolls.
  - Rows come from `WowScrollBoxList` with pooling.

**Items view ("who wants X")**

```
┌ Tree 170 ──────────────┐┌ List 450 ─────────────────────────────────────────────┐
│ ▾ Phase 1              ││ Prince Malchezaar                    6 items · 11 claims │ boss header 22
│   ▾ Karazhan      (38) ││ ┌28┐ Helm of the Fallen Champion  token → T4 Head  4 ▮▮ │ item row 30
│      Attumen       (3) ││      [Tehlo HPal] [Arwen PPal] [Sneaky alt] [Stormy ○] │ chips 18, wrap
│      Moroes        (5) ││ ┌28┐ Light's Justice   Main Hand · Mace          2 ▮   │
│      ▸ Opera       (4) ││      [Tehlo] [Priesty alt]                             │
│      Prince       (11)◄││ ┌28┐ Gorehowl   Two Hand · Axe        nobody (dimmed)   │
│   ▸ Gruul's Lair   (6) ││                                                        │
│   ▸ Magtheridon    (4) ││                                                        │
│ ☐ Hide items nobody wants                                                        │
└────────────────────────┘└───────────────────────────────────────────────────────┘
```

- **Tree:** based on LootReserve's. A demand count per node guides the eye.
- **Items:** sorted by demand.
- **Chips** (based on TehBox's voter chips):
  - Primary: class-colored name on a dark fill.
  - Alternate: the word "alt" and an outline only.
  - Not in raid: 50% alpha plus ○.
  - Obtained: hidden unless "show obtained" is on, then grey with ✓.
  - Hover a chip for details; click it for Member detail.
- **Tokens:** a token row expands into its class pieces on hover. Claims are counted against the token.

**Member detail**
- Reuses the My BiS paper doll in read-only mode.
- Header: name, class and spec, guild rank, last synced, and ◀ ▶ buttons to step through the roster in the current sort order for quick review.
- Under each tile: a 14px icon of what the member has **equipped** in that slot, if they broadcast their gear.
- A council-only note field, synced only among council members.
- A small **"recently changed"** marker: items edited less than 24h before raid time show a clock glyph. This is an anti-gaming signal the council can weigh.

### 4.3 Boss drop alert

**Pipeline**
1. `ENCOUNTER_END` marks the current boss, using TehBox's alias map.
2. When a DisasterZone user (ideally the master looter or raid leader) opens the corpse (`LOOT_READY`), read the slots:
   - Use quality from the 5th return of `GetLootSlotInfo` (Raidify).
   - Use `GetLootSourceInfo(slot)` → npcID → boss.
   - Guard against empty links (LootReserve).
3. Broadcast `DROP{boss, itemIDs}` to RAID. Deduplicate by corpse GUID.
4. Fallback when no looter runs DisasterZone: `CHAT_MSG_LOOT`, which creates a "received by X" entry.
5. Manual paths: Alt-click a loot button (TehBox), or `/dz drop <shift-click>`.

**Council popup (320px wide, height fits content up to a 460px maximum, then scrolls)**

```
┌ Prince Malchezaar · Karazhan ──────────── 21:14 ─ [⚙][x] ┐ header 26 (GameFontNormal)
│ ┌32┐ Helm of the Fallen Champion                  4 claims │ item header 36
│ └──┘ Token → T4 Head (Paladin · Rogue · Shaman)             │
│   ● ⚔ Tehlo    Holy Paladin   [BiS]  needs   won 0 tonight  │ candidate rows 18
│   ● ⛨ Arwen    Prot Paladin   [BiS]  needs   won 1 tonight  │
│   ● ✦ Sneaky   Rogue          [alt]  needs                  │
│   ○ ⚡ Stormy   Enh Shaman     [BiS]  not in raid (dimmed)   │
│   [Announce] [Link] [Collapse]                              │ action bar 22 (UIPanelButton 70×18)
│ ─────────────────────────────────────────────────────────── │
│ ┌32┐ Light's Justice                              1 claim    │
│   ● ⚔ Tehlo    Holy Paladin   [BiS]  needs                  │
│ ─────────────────────────────────────────────────────────── │
│ ┌32┐ Gorehowl — nobody has this on BiS   [show usable]      │ collapsed 36, 0.6 alpha
│ ─────────────────────────────────────────────────────────── │
│ [Announce all]                           ◀ previous bosses ▶ │ footer 26
└──────────────────────────────────────────────────────────────┘
```

- **Candidate sort** (Raidify's rule): in raid, then primary before alternate, then fewest items won tonight, then name.
- **Obtained** claims are hidden by default. A ⚙ toggle shows them grey with ✓.
- **Each row shows:** presence dot, 12px class icon, class-colored name, spec as a word, a [BiS]/[alt] badge, and "won N tonight" (from `CHAT_MSG_LOOT`). Optional: attendance %.
- **Announce** sends one line per item to RAID, or RAID_WARNING for leader/assist (configurable):
  - Example: `DisasterZone: [Helm of the Fallen Champion] BiS: Tehlo, Arwen · alt: Sneaky`
  - Rate-limited. **Link** puts the item link in chat.
- **Placement**, set in Settings:
  - **Attach to loot window** is the default for whoever is looting: TOPLEFT anchored to `LootFrame` TOPRIGHT +4, following it.
  - **Free-floating** is the default for other council members: movable, saved position, DIALOG strata, ESC closes.
  - Stays open until dismissed. A "previous bosses" pager keeps tonight's history.
- **Loot window badges:** a right-aligned 10pt label on each `LootButtonN`: "BiS ×3" in gold (council) or "★ Yours" (raider). Updated on `LOOT_OPENED` and on loot-frame page changes.

**Personal highlight for regular raiders**

```
┌──────────────────────────────────────────────┐ 300×52, top-center y-140, gold 1px border
│ ┌32┐ ★ On your BiS list!                     │ GameFontNormal (gold)
│ └──┘ Justicar Diadem — Head · P1 (via token) │ quality-colored name
└──────────────────────────────────────────────┘
```

- Fades after 8 seconds and stays while hovered; click to link. A chat line is printed too.
- `LibCustomGlow.ButtonGlow` on the matching loot button when you open the corpse.
- Optional sound. Each part (toast, glow, sound, chat) can be turned off in Settings.

### 4.4 Tooltip integration

Hooked like LootReserve and Loon: `OnTooltipSetItem` on GameTooltip, ItemRefTooltip and the shopping tooltips, with Loon's guard against adding lines twice. Results are cached per itemID and cleared on sync.

**Everyone (one or two lines)**
- Gold "DisasterZone: ★ Your BiS — Head (P1)".
- Or grey "DisasterZone: Alternate #2 — Head (P1)".
- Green "✓ Obtained (equipped)" once you have it.
- On a token: "Your BiS: Justicar Diadem (via this token)".

**Council members (compact by default, capped at 4 lines; Shift expands)**

```
DisasterZone · P1 BiS for 3 (2 in raid)
  ⚔ Tehlo   Holy Paladin      BiS · needs      ● in raid
  ⛨ Arwen   Prot Paladin      BiS · needs      ● in raid
  ✦ Sneaky  Rogue             alt · needs      ○
  +2 obtained  (hold Shift for all)
```

- Defaults to the guild's current phase; "all phases" is an option.
- Tokens resolve to their tier pieces for each class.
- Uses `AddDoubleLine` with class colors, the same way Loon and AtlasBIStooltips do.

### 4.5 Visual style (native look)

**Frames**
- Main window: `ButtonFrameTemplate` with the portrait.
- Picker: `BasicFrameTemplateWithInset`.
- Alerts and toasts: native `UI-DialogBox-Background-Dark` with `UI-Tooltip-Border` (edge 10), like Loon.
- Tabs: `CharacterFrameTabButtonTemplate`.
- Search: `SearchBoxTemplate`. Buttons: `UIPanelButtonTemplate`. Checkboxes: `UICheckButtonTemplate`.
- No custom neon palette.

**Type**
- GameFontNormal (gold) for headings, GameFontHighlight/Small (white) for names and body, GameFontDisableSmall (grey) for secondary lines. Minimum about 10pt; no outlined 6-8pt text.

**Color rules (Raidify's "chroma ceiling")**
- Window chrome stays neutral and desaturated. Saturated color is reserved for data:
  - Item quality via `ITEM_QUALITY_COLORS`, class via `RAID_CLASS_COLORS`.
  - Obtained = `GREEN_FONT_COLOR`, needed = white, alternate = `GRAY_FONT_COLOR`.
  - The BiS badge is gold text on a dark pill, so it doesn't read as a heading.
- Every color signal also has a word or glyph.

**Textures**

| Use | Texture |
|---|---|
| Empty slot | `GetInventorySlotInfo(...)` texture. For the relic slot use `UnitHasRelicSlot`; the relic texture path needs checking in-game |
| Slot background | `Interface\Buttons\UI-Quickslot2` |
| Quality border | `IconBorder` / `Interface\Common\WhiteIconFrame` |
| Obtained / missing / pending | `Interface\RaidFrame\ReadyCheck-Ready` / `-NotReady` / `-Waiting` |
| List row highlight | `Interface\QuestFrame\UI-QuestTitleHighlight` |
| Icon hover | `Interface\Buttons\ButtonHilight-Square` (ADD) |

**Sizes**
- Slot icons 36 (the native paper doll uses 37), picker/list icons 28, drop-alert icons 32, matrix icons 20 (16 compact), class icons 14, status overlays 10-12.

### 4.6 What the UX depends on underneath

- **Ship our own raid DB:** raid → boss (encounterID, npcIDs, name, phase) → itemIDs, plus a token → rewards map and special cases (Chess chest, Opera variants, Servant Quarters rares, Nightbane, world bosses, trash). It can be seeded from AtlasLoot `data-tbc.lua` (npcIDs, GPL v2) and LootReserve `Data.lua` (token map). Check licenses before copying.
- **Slot model:** 17 slot keys. MAINHAND can hold a 2H, which locks OFFHAND.
- **Item data loads asynchronously:** show "Loading…" with a give-up timer (Raidify), and re-render on `GET_ITEM_INFO_RECEIVED` (TehBox).
- **Sync:**
  - AceComm + ChatThrottleLib + LibDeflate.
  - Each member broadcasts their list (with an `updatedAt` version and obtained flags) on the GUILD channel.
  - Council members cache all lists in SavedVariables and run manifest/delta sync on login.
  - Names are stored as Name-Realm and shortened for display with `Ambiguate`.
- **Council membership:** defined by an officer as guild ranks plus names, versioned and synced (TehBox's model). This is UI gating only.

---

## 5. Decisions for you

1. **Who sees the Council and Loot Table views?** Council only, or everyone read-only? Transparency builds trust but invites politics.
2. **Phases:** does an officer set the guild's current phase? Do we need a pre-raid tab?
3. **Alternates:** how many per slot (I'd suggest 2), and do they count as real claims for the council?
4. **List changes:** should lists lock before raid, or only show "recently changed" markers?
5. **Loot rules:** is master loot available in TBC Anniversary for your guild, or does one person loot everything and trade it? This decides how drops are detected.
6. **Scope:** should DisasterZone record awards and mark items obtained automatically, or stay purely BiS plus alerts? Voting and awarding are out of scope unless you want them.
7. **Loon dependency:** OK to rely on LoonBestInSlot being installed for templates, or should we bundle template data (needs the author's permission)?
8. **Tank lists:** default to Mitigation, Threat or Stamina rankings?