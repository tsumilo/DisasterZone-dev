# DisasterZone API cheat sheet: TBC Anniversary client (Interface 20506)

## 0. Environment and sources

- **Client:** `2.5.6.69795`, product `wow_anniversary` (from `C:\World of Warcraft\.build.info`). Locale enUS, portal EU (`WTF\Config.wtf`). The realm folder is `Thunderstrike` (`WTF\Account\*\Thunderstrike`).
- **No Blizzard interface code is extracted locally.** `C:\World of Warcraft\_anniversary_\Interface` contains only `AddOns`. `Logs\FrameXML.log` is just a load-error log.
- **Web source used:** `github.com/Gethe/wow-ui-source`, branch `classic_anniversary`. Anything marked [WEB] comes from there or from warcraft.wiki.gg. Everything else is local evidence.
- **Citation paths** are relative to `C:\World of Warcraft\_anniversary_\Interface\AddOns\`.
- **Deprecation fallbacks (important):** on this branch many legacy globals exist only as aliases. They are loaded only when the CVar `loadDeprecationFallbacks` is on [WEB]:
  - `Blizzard_DeprecatedItemScript/Deprecated_ItemScript.lua`: `GetItemInfo = C_Item.GetItemInfo`, `GetItemInfoInstant`, `GetItemIcon = C_Item.GetItemIconByID`, `IsEquippableItem`, `IsUsableItem`, `GetItemQualityColor`, `GetItemClassInfo`, `GetItemSubClassInfo`, `GetItemCount`, `GetDetailedItemLevelInfo`, …
  - `Blizzard_DeprecatedChatInfo/Deprecated_ChatInfo.lua`: `SendChatMessage = C_ChatInfo.SendChatMessage`.
  - `Deprecated_ChatFrame.lua`: `ChatEdit_InsertLink = ChatFrameUtil.InsertLink`, `ChatEdit_GetActiveWindow = ChatFrameUtil.GetActiveWindow`, `ChatFrame_AddMessageEventFilter = ChatFrameUtil.AddMessageEventFilter`, `ChatFrame_OpenChat`, …
  - **Rule for DisasterZone:** call `C_Item.*`, `C_ChatInfo.*`, `ChatFrameUtil.*`, `C_GuildInfo.*`, `C_PartyInfo.*` and `C_Container.*` directly.

---

## 1. Loot

### 1.1 Events

Payloads below are from `Blizzard_APIDocumentationGenerated/LootDocumentation.lua` [WEB].

| Event | Payload | Local use |
|---|---|---|
| `LOOT_READY` | `autoloot` | LootReserve/Server.lua:1149; RXPGuides/InventoryManager.lua:455 |
| `LOOT_OPENED` | `autoLoot` | TehBoxLootCouncil.lua:1387; Raidify_Loot/LootSession.lua:123-131; RareScanner/Core/Service/RSEventHandler.lua:154 |
| `LOOT_SLOT_CLEARED` | `lootSlot` | LootReserve/Server.lua:1196; TehBoxLootCouncil_Loot.lua:108 |
| `LOOT_SLOT_CHANGED` | `lootSlot` | LootReserve/Windows/ServerWindow.lua:946 |
| `LOOT_CLOSED` | – | LootReserve/Server.lua:1190 |
| `OPEN_MASTER_LOOT_LIST`, `UPDATE_MASTER_LOOT_LIST` | – | LootReserve/Server.lua:4076 |
| `START_LOOT_ROLL` | `rollID, rollTime, lootHandle` | LootReserve/Server.lua:1225, Client.lua:342 |
| `CANCEL_LOOT_ROLL` | `rollID` | [WEB] |

- Blizzard's own `LootFrame_OnEvent` handles `LOOT_OPENED`, `LOOT_READY`, `LOOT_SLOT_CLEARED`, `LOOT_SLOT_CHANGED`, `LOOT_CLOSED` and both master-loot list events [WEB, `Blizzard_UIPanels_Game/Classic/LootFrame.lua`].
- **Tip:** take the snapshot on `LOOT_READY`, because fast-loot addons can empty slots before `LOOT_OPENED` (Leatrix_Plus.lua:1849-1872).

### 1.2 Slot APIs

**`GetNumLootItems()`**

**`GetLootSlotInfo(slot)`** returns `icon, name, quantity, currencyID, quality, locked, isQuestItem, questID, isActive`.
- Evidence: Raidify_Loot/LootSession.lua:474-478 (the comment warns that quality is the 5th value), :548; Leatrix_Plus.lua:1859; the Blizzard `LootFrame_UpdateButton` [WEB].
- Gotcha: LootReserve/Server.lua:1167 does `local itemID = GetLootSlotInfo(slot)`, but the first value is the icon, not an item ID.

**`GetLootSlotLink(slot)`** can return junk like `"|Hitem:::::::::70:::::::::[]"`. Always check `link:find("item:%d")` first (LootReserve/Server.lua:1170, LootReserve.lua:1208).

**Other slot helpers:**
- `GetLootSlotType(slot)`: `1` means an item (LootReserve/Server.lua:1166).
- `LootSlotHasItem(slot)` (RSEventHandler.lua:161).
- `GetLootInfo()` returns a table (Questie/Modules/QuestieDebugOffer.lua:434).
- `GetLootThreshold()` (Leatrix_Plus.lua:1857).
- `LootSlot(i)` (Leatrix_Plus.lua:1861).

**`GetLootSourceInfo(slot)`** returns `guid1, qty1, guid2, qty2, …` (warcraft.wiki.gg: available on TBC since 1.13.2) [WEB].
- Used unguarded on a 20506 TOC at RareScanner/Core/Service/RSEventHandler.lua:162-163, and at Questie/Modules/QuestieDebugOffer.lua:436.
- Raidify_Loot/LootSession.lua:428-429 says it is "missing on some Classic builds", so it guards the call and falls back to the slot index. It exists on 2.5.6, but keep a fallback anyway.

**NPC or object ID from a GUID.** Format: `Creature-0-srv-inst-zoneUID-npcID-spawnUID`.

```lua
local unitType, _, _, _, _, id = strsplit("-", guid)   -- RSEventHandler.lua:163
-- unitType: "Creature" | "Vehicle" | "GameObject" (chests) | "Item"   (DBM-Core/DBM-Core.lua:3072-3079)
local npcID = tonumber(select(6, strsplit("-", guid)))  -- RaidHelper_TBC/AutoMark.lua:326; AtlasLootClassic/Data/VendorPrice.lua:988
```

- Boss creature IDs are in `DBM-Raids-BC/**/*.lua` `mod:SetCreatureID(...)`. Examples: GruulsLair/Gruul.lua:8 = 19044; BlackTemple/Illidan.lua:12 = 22917; IllidariCouncil.lua:12 = 22949-22952.
- Per-boss `npcID` tables are also in AtlasLootClassic_DungeonsAndRaids/data-tbc.lua:174 and onward.
- Chest loot (for example Karazhan Chess) arrives as `GameObject`.
- Avoid LootReserve's "target GUID or CHEST" guess (Server.lua:1159).

### 1.3 Loot method and master looter

**`C_PartyInfo.GetLootMethod()`** returns `method (Enum.LootMethod), masterLootPartyID?, masterLooterRaidID?` [WEB].
- Enum values: 0 Freeforall, 1 Roundrobin, 2 **Masterlooter**, 3 Group, 4 Needbeforegreed, 5 Personal.
- The wiki says it was **added in TBC 2.5.6 (68184)**.
- Local use: Leatrix_Plus.lua:1854-1855 (`== 2`); LootReserve/LootReserve.lua:366-371 (feature-detects, `Enum.LootMethod.Masterlooter`).

**The global `GetLootMethod()` is gone.** The wiki lists it for TBC Anniversary only "1.13.2 to 2.5.5", and there is no alias in `Blizzard_DeprecatedPartyInfo/Deprecated_PartyInfo.lua` [WEB]. Local breakage:
- Raidify_Loot/LootSession.lua:42 calls it unguarded, which is a Lua error for a raider who is not leader or assist.
- TehBoxLootCouncil_Access.lua:116-121 and _Loot.lua:466-467 guard it, so master-looter detection silently never fires. They also misuse `GetMasterLootCandidate(1)`.

**`IsMasterLooter()`** is used unguarded by LootReserve/Server.lua:402, 1101, 1131, 1150, 4053. It is not in the Blizzard API docs and has no wiki page. Prefer this:

```lua
local function IsPlayerML()
  local m, pid, rid = C_PartyInfo.GetLootMethod()
  if m ~= Enum.LootMethod.Masterlooter then return false end
  if rid then return UnitIsUnit("raid"..rid, "player") end
  return pid == 0
end
```

**`GetRaidRosterInfo(i)`** returns `name, rank(2=leader,1=assist), subgroup, level, class(localized), fileName, zone, online, isDead, role, isML, combatRole`.
- Evidence: LootReserve.lua:799; Raidify/Core.lua:766.
- Raidify/Assignments.lua:225 swaps the labels of returns 5 and 6.

**`GetMasterLootCandidate(slot, idx)`**, with `idx` from 1 to 40, returns a name.
- Gaps in the index are possible (LootReserve/Server.lua:4081-4093).
- It is only valid while loot is open and after `OPEN_MASTER_LOOT_LIST`.

**`GiveMasterLoot(slot, idx)`** (Server.lua:4090).
- To record award attempts: `hooksecurefunc("GiveMasterLoot", …)` at Server.lua:1178-1188, then confirm on `LOOT_SLOT_CLEARED` at :1196-1201.
- LootReserve opens the master-loot list by calling `LootButton_OnClick(fakeBtn, "LeftButton")`. The fake button has `.slot`, `.quality`, `.Text` and `.IconTexture` (Server.lua:4138-4144; Windows/ServerWindow.xml:2026). The comment at :4118 says calling `LootSlot()` directly breaks LootFrame.

### 1.4 Group loot rolls

- `GetLootRollItemLink(rollID)` (LootReserve/Server.lua:1228).
- `GetLootRollItemInfo(rollID)` returns `texture, name, count, quality, …` (Auctionator/Source/Tooltips/Hooks.lua:154-156).
- Auto-need pattern: `RollOnLoot(rollID, 1)` (1 = need), then `ConfirmLootRoll(rollID, 1)`, then `StaticPopup_Hide("CONFIRM_LOOT_ROLL")` (LootReserve/Client.lua:364-366).
- Every eligible raider gets `START_LOOT_ROLL`, so a BiS indicator can be shown locally without any comms.

### 1.5 `CHAT_MSG_LOOT`

- **Arguments:** `(text, playerName, lang, channel, playerName2, …)`. Argument 5 is the looter and may be `""`, in which case fall back to argument 2 (Questie/Modules/EventHandler/EventHandler.lua:322; QuestieAnnounce.lua:213-214).
- **Build patterns from the global strings.** See LootReserve/Server.lua:1096-1124 and `FormatToRegexp` at LootReserve.lua:1296-1298. `FormatToRegexp` strips `%1$`, turns `%s` into `(.+)` and `%d` into `(%d+)`. Match the most specific first: `LOOT_ITEM_SELF_MULTIPLE`, then `LOOT_ITEM_SELF`, then `LOOT_ITEM_MULTIPLE`, then `LOOT_ITEM`.
- **Improve on it:** also escape `.` and `-`.
- **enUS strings:**
  - `LOOT_ITEM` = `"%s receives loot: %s."`, confirmed by the comment at DBM-Raids-BC/Serpentshrine/Vashj.lua:158.
  - `LOOT_ITEM_SELF` = `"You receive loot: %s."`, `*_MULTIPLE` = `"…: %sx%d."`, and `LOOT_ITEM_PUSHED_SELF` = `"You receive item: %s."` — these are [WEB] or from memory.
- **Anti-pattern:** TehBoxLootCouncil_Loot.lua:343-351 hard-codes English and checks `"You receive item"`. Its fallback pattern `^([^%s]+) receives? loot` turns `"You receive loot"` into the looter name "You".
- GudaBags/Core/Rules/RecentRule.lua:346 wraps parsing in `pcall` because of "secret strings". That is a retail-only concern, but harmless.

### 1.6 Encounter events

- **Payloads:** `ENCOUNTER_START(encounterID, name, difficultyID, groupSize)`, `ENCOUNTER_END(…, success)`, `BOSS_KILL(encounterID, name)`.
  - Registered unguarded on 20506 by RaidHelper_TBC/Core.lua:2083-2085 (payload at :2102).
  - DBM-Core/modules/CombatDetection.lua:57, 296, 363, 409.
- **IDs:** TBC uses 6xx values, for example Gruul 650. DBM passes both the classic and retail IDs: `SetEncounterID(650, 2456)` at GruulsLair/Gruul.lua:9. A full name-to-ID table is in TehBoxLootCouncil_RaidHistory.lua:426-476.
- **Anniversary quirks (TehBox claims, unverified by me):**
  - `encounterID` and/or `name` can be nil (RaidHistory.lua:418, 522-529).
  - Midnight fires a separate encounter from Attumen (:415-422).
  - "Opera Hall" is an umbrella name (TehBoxLootCouncil.lua:273).
  - Hyjal fires `ENCOUNTER_START` before the boss is engaged (:507).
- **Recommendation:** use encounter events only as "current boss" context. Identify the drop source from the `GetLootSourceInfo` NPC ID.

### 1.7 How the reference addons handle drops

**TehBoxLootCouncil**
- Snapshots on `LOOT_OPENED` (_Loot.lua:87-100).
- Stores pending entries on `LOOT_SLOT_CLEARED` (:105-130).
- Records the recipient from `CHAT_MSG_LOOT` (:311 and onward).
- Takes the boss name from `ENCOUNTER_START` (RaidHistory.lua:497-499).
- Shows an officer popup debounced by 1.5s (_Loot.lua:454-485).
- Announces to `RAID_WARNING`, chunked to 255 bytes (LootCouncil.lua:571, 725-750).
- Hooks Alt+click on `LootButton_OnClick` (LootWidget.lua:10355-10368). **Bug:** it uses `self:GetID()`, which is the button index, not `self.slot`, so it picks the wrong item on page 2 and later.

**Raidify_Loot**
- Arms `LOOT_OPENED` only while a session is running (LootSession.lua:123-131).
- Scans every slot with a quality threshold (:463-517).
- Deduplicates on `sourceGUID:itemID`, or `slot:itemID` when the source is unknown (:411-455).
- Persists the queue to SavedVariables.
- Broadcasts the whole session over AceComm with "BULK" priority to RAID, debounced (LootSync.lua:84-106).
- Announces awards with `SendChatMessage` to RAID (LootSession.lua:786-791).

**LootReserve**
- As master looter it handles `LOOT_READY`, then `AddRecentLoot` (Server.lua:1149-1176).
- Under group loot it chats "X is reserved by …" on `START_LOOT_ROLL` (:1225-1245).
- Adds reserve info to tooltips (Client.lua:371-404).

**Design implication:** only the player who opens the corpse, normally the master looter, gets slot data. The drop list must be broadcast so the Loot Council sees it. `CHAT_MSG_LOOT` reaches everyone for award tracking.

---

## 2. Default LootFrame (old classic paging frame, not ScrollBox)

**Confirmed from `Blizzard_UIPanels_Game/Classic/LootFrame.lua` on `classic_anniversary` [WEB]:**
- `LOOTFRAME_NUMBUTTONS = 4`.
- Buttons are `_G["LootButton"..i]` with `button.slot` and `button.quality`.
- Child regions: `LootButtonNIconTexture`, `…Text`, `…Count`.
- Paging uses `LootFrame.page`.
- `LootFrame_UpdateButton(index)` is a global. `LootFrame_Update()` loops over it.
- `LootButton_OnClick` sets `LootFrame.selectedSlot`, `selectedQuality` and `selectedLootButton`.
- `MasterLooterFrame_UpdatePlayers` calls `GetMasterLootCandidate(LootFrame.selectedSlot, i)`.

**Local corroboration:**
- RXPGuides/InventoryManager.lua:430-437 hooks `LootButton1..N` `OnClick`.
- LootReserve/Server.lua:4119-4133 (commented-out paging code).
- LootReserve/Server.lua:3676 uses `LootFrame:IsShown()`.

**Decoration pattern (untested; built from the Blizzard source):**

```lua
hooksecurefunc("LootFrame_UpdateButton", function(index)
  local b = _G["LootButton"..index]; if not b then return end
  b.cdl = b.cdl or b:CreateTexture(nil, "OVERLAY")  -- create once
  local link = b:IsShown() and b.slot and GetLootSlotLink(b.slot)
  -- set b.cdl texture or glow if link is on someone's BiS; else hide
end)
LootFrame:HookScript("OnHide", function() --[[clear glows]] end)
```

**LibCustomGlow-1.0** (MINOR 19) ships in LootReserve/Libs/LibCustomGlow-1.0, DBM-Core/Libs and GladiusEx/libs. Embed your own copy. API from LibCustomGlow-1.0.lua:
- `ButtonGlow_Start(r, color, frequency, frameLevel)` at :650, and `ButtonGlow_Stop` at :736.
- `PixelGlow_Start(r, color, N, frequency, length, th, x, y, border, key, frameLevel)` at :255.
- `AutoCastGlow_Start` at :394.
- `ProcGlow_Start(r, opts)` at :899.
- Usage example: LootReserve/Windows/RollRequestWindow.lua:121.

Group roll frames are `GroupLootFrame1..` (named in TehBoxLootCouncil_LootWidget.lua:539). Their internals are unverified.

---

## 3. Addon comms

**Functions** (`ChatInfoDocumentation.lua` [WEB]):
- `C_ChatInfo.RegisterAddonMessagePrefix(prefix)` returns a result enum.
- `C_ChatInfo.SendAddonMessage(prefix, msg, chatType, target)` returns an `Enum.SendAddonMessageResult`.
  - Locally mirrored in ChatThrottleLib v32 (DBM-Core/Libs/ChatThrottleLib/ChatThrottleLib.lua:349-355): Success 0, AddonMessageThrottle 3, NotInGroup 5, ChannelThrottle 8, GeneralError 9.
  - The wiki adds NotInGuild 10 and TargetOffline 12.
- Other functions: `SendAddonMessageLogged`, `IsAddonMessagePrefixRegistered`, `GetRegisteredAddonMessagePrefixes`.

**`CHAT_MSG_ADDON`** payload: `prefix, text, channel, sender, target, zoneChannelID, localID, name, instanceID` (RaidHelper_TBC/Core.lua:2283-2285).
- The sender includes the realm. AceComm passes it through `Ambiguate(sender, "none")` (Raidify/Libs/Ace3/AceComm-3.0/AceComm-3.0.lua:244), which keeps the realm.
- Strip it with `Ambiguate(sender, "short")` before comparing with `UnitName("player")` (Raidify/Sync.lua:209-217).

**Limits** [WEB, wiki]:
- Text up to 255 bytes, with no NUL. Prefix up to 16 characters. Enforced locally by AceComm-3.0.lua:61-62, :95 and CTL:636.
- Chat types: PARTY, RAID, INSTANCE_CHAT, GUILD, OFFICER, WHISPER. SAY and YELL work on Classic only.
- **Per-prefix throttle:** a burst of 10 messages, refilling at 1 per second. This covers PARTY, RAID, GUILD, OFFICER and instanced WHISPER. **Whispers outside instances are not throttled.**
- LootReserve works around the throttle by rotating 40 prefixes, `LootReserve1..40` (Comm.lua:47-66, 203).
- **Implication:** AceComm splits large payloads into 254-byte chunks marked `\001`/`\002`/`\003` (AceComm-3.0.lua:41-44, 108-130). A 5 KB sync is roughly 20 chunks, or about 10 seconds or more. Send hashes or version stamps over GUILD and do bulk sync by whisper outside instances.

**Pipeline** (Raidify/Sync.lua:191-204 send, :224-229 receive):

```lua
local enc = LibDeflate:EncodeForWoWAddonChannel(LibDeflate:CompressDeflate(self:Serialize(tbl)))
self:SendCommMessage(PREFIX, enc, "GUILD"|"RAID"|"WHISPER", target, "NORMAL"|"BULK"|"ALERT")
-- receive: Decode -> Decompress -> self:Deserialize -> pcall(handler)  (never trust payloads)
```

- LootReserve/Comm.lua:97-104 and :126 use the same pipeline with "ALERT" priority.
- Plain `C_ChatInfo` with manual chunking: RaidHelper_TBC/Sync.lua:14-20, 482-488.
- Library copies:
  - Raidify/Libs/Ace3: AceComm MINOR 14, CTL v32, AceSerializer.
  - LootReserve/Libs: AceComm, AceSerializer, LibDeflate, LibUIDropDownMenu-4.0.
  - CTL v32 honours `Enum.SendAddonMessageResult` and uses `C_ChatInfo.SendChatMessage or SendChatMessage` (CTL.lua:558).
- GUILD channel examples: DBM-Core/modules/AddonComms.lua:127; Details/core/network.lua:745; TehBoxLootCouncil_Access.lua:345.

**Gotcha:** TehBoxLootCouncil.lua:17-29 defines **global** `SendAddonMessage` and `RegisterAddonMessagePrefix` shims (its comment says the bare functions do not exist). Never feature-detect those globals, and always call `C_ChatInfo` directly.

---

## 4. Guild

**Roster refresh:**
- Request with `C_GuildInfo.GuildRoster()` (LootReserve/Server.lua:1269-1273; Raidify/Core.lua:1093-1098, which throttles itself to 10 seconds at :1087).
- The **global `GuildRoster()` is removed** (the wiki lists TBC only up to 2.5.1, and there is no deprecated alias) [WEB]. TehBoxLootCouncil_Access.lua:74 and LootWidget.lua:3137 guard it with `if GuildRoster`, so they silently do nothing.
- `GUILD_ROSTER_UPDATE(canRequestRosterUpdate)` [WEB docs] (LootReserve/Server.lua:1258).

**`GetGuildRosterInfo(i)`** returns 17 values: `name("Name-Realm"), rankName, rankIndex(0=GM), level, classDisplayName, zone, publicNote, officerNote, isOnline, status, classFile, achPts, achRank, isMobile, canSoR, repStanding, guid`.
- Evidence: Leatrix_Plus.lua:498 (reads `guid` as the 17th value); TacoTip/Libs/LibClassicInspector/LibClassicInspector.lua:3037-3039; Details/frames/window_mythickeys.lua:1308 (comment on the Name-Realm format); wiki [WEB].
- `GetNumGuildMembers()`.

**Ranks:**
- `GuildControlGetNumRanks()` and `GuildControlGetRankName(i)` are **1-based**, so pass `rankIndex + 1` [WEB, wiki]. Neither is used locally.

**`GetGuildInfo("player")`** returns `guildName, rankName, rankIndex(0-based), realm(nil if same realm)` [WEB].
- TehBoxLootCouncil_Access.lua:54 reads an 8th return value that does not exist.

**Permissions** (on 2.5.6, `GuildInfoDocumentation` [WEB]): `C_GuildInfo.CanEditOfficerNote()`, `CanViewOfficerNote()`, `IsGuildOfficer()`, `GetGuildRankOrder(guid)`, `MemberExistsByName`. `IsGuildLeader()` is not used locally and is unverified.

**Rank-based Loot Council:** TehBoxLootCouncil_LootCouncil.lua:190-215 matches rank *names*. Rank *index* is more stable when ranks get renamed.

---

## 5. Names

- `Ambiguate(name, "short")` strips the realm; `"none"` keeps it (Raidify/Sync.lua:209-217).
- Realm helpers: `GetNormalizedRealmName()`, with `GetRealmName():gsub("[%s%-]","")` as a fallback (LootReserve.lua:533-545); `UnitNameUnmodified("player")` (:567).
- **Store keys as `Name-NormalizedRealm` everywhere.** Guild roster names and `CHAT_MSG_ADDON` senders include the realm; `UnitName` and raid roster names drop it for same-realm players.
- LootReserve treats every non-Era client as cross-realm (LootReserve.lua:507-510).

---

## 6. Items

**`C_Item.GetItemInfo(item)`** has the same order as the old global: `name, link, quality, itemLevel, minLevel, type, subType, stackCount, equipLoc(9), texture(10), sellPrice, classID(12), subclassID(13), bindType, …`.
- Evidence: GudaBags/Data/ItemScanner.lua:407; AtlasLootClassic/Button/Item_type.lua:28, :323; Favourites.lua:1162 (9th value = `equipLoc`).
- It returns nil until the item is cached.

**`C_Item.GetItemInfoInstant(item)`** works without the cache. It returns `itemID, type, subType, equipLoc, icon, classID, subclassID`.
- Evidence: LoonBestInSlot/Common.lua:194; TehBoxLootCouncil.lua:690 (5th = icon); GudaBags/UI/BagFrame/BagClassifier.lua:38.

**Async loading:**
- `Item:CreateFromItemID(id):ContinueOnItemLoad(fn)`, then `item:GetItemName()`, `GetItemLink()`, `GetItemQuality()`, `GetItemIcon()` (LoonBestInSlot/Common.lua:191-205).
- `C_Item.RequestLoadItemDataByID(id)` plus `GET_ITEM_INFO_RECEIVED(itemID, success)` (GudaBags/Data/ItemScanner.lua:158-159, 630; AtlasLootClassic/Addons/Favourites_GUI.lua:289).

**Icons and quality:**
- `C_Item.GetItemIconByID(id)` (GudaBags/UI/ItemButton.lua:195).
- `C_Item.GetItemQualityByID`, `C_Item.DoesItemExistByID` (Favourites_GUI.lua:21).
- `C_Item.GetItemQualityColor(q)` returns `r, g, b, hex` (AtlasLootClassic/Button/Item_type.lua:77-79).
- `ITEM_QUALITY_COLORS[q].r/g/b` (TehBoxLootCouncil_LootCouncil.lua:991-992; also used by the Blizzard LootFrame).

**Slots:**
- `INVSLOT_*` constants exist: HEAD 1, NECK 2, SHOULDER 3, BODY 4, CHEST 5, WAIST 6, LEGS 7, FEET 8, WRIST 9, HAND 10, FINGER1/2 11/12, TRINKET1/2 13/14, BACK 15, MAINHAND 16, OFFHAND 17, RANGED 18 (ranged or relic in TBC), TABARD 19, AMMO 0.
- **INVTYPE to slot map and empty-slot icon fileIDs:** AtlasLootClassic/Addons/Favourites_GUI.lua:29-81. Examples: head 136516, neck 136519, shoulder 136526, chest/back 136512, wrist 136530, hands 136515, waist 136529, legs 136517, feet 136513, finger 136514, trinket 136528, mainhand 136518, offhand 136524, ranged 136520, relic 136522.
- A variant that maps every one-handed weapon to both 16 and 17 is at TehBoxLootCouncil_GearInspect.lua:170-189. LoonBestInSlot's version is at Common.lua:149-178.
- `GetInventorySlotInfo("HeadSlot")` or `"HEADSLOT"` returns `slotID, emptyTexture` (Wardrobe.lua:157 and on; LoonBestInSlot/UserItemCache.lua:6-10, 64; the second return value is [WEB]).
- `GetInventoryItemID` and `GetInventoryItemLink(unit, slot)` (TehBoxLootCouncil_GearInspect.lua:557-558). Other players' items require inspect range; LibClassicInspector is in RaidHelper_TBC/Libs.

**Bags and bank** — `C_Container` only; there is no deprecated container alias on this branch [WEB listing]:
- `C_Container.GetContainerNumSlots`, `GetContainerItemLink`, and `GetContainerItemInfo(bag, slot)`, which returns a table with `.itemID`, `.hyperlink`, `.stackCount`, … (GudaBags/Compatibility/API.lua:16-42; GudaBags/Data/BagScanner.lua:137-179; LoonBestInSlot/UserItemCache.lua:15-33).
- `C_Container.GetContainerItemID` is not seen locally.
- Bag IDs: bags 0-4, main bank -1, bank bags 5-11, keyring -2 (GudaBags/Core/Constants.lua:55-68).
- The main bank's 28 slots map through `BankButtonIDToInvSlotID` (GudaBags/Core/TooltipScanner.lua:44-48).
- The bank can only be read after `BANKFRAME_OPENED`, and `PLAYERBANKSLOTS_CHANGED` fires on changes. Cache it in SavedVariables.

**Class and usability filtering:**
- `C_Item.IsUsableItem` and `IsEquippableItem` only answer for the player, so the Loot Council needs its own table.
- Proficiency bitmasks keyed by `Enum.ItemClass`, `Enum.ItemWeaponSubclass` and `Enum.ItemArmorSubclass`: AtlasLootClassic/Data/ClassFilter.lua:104-148. Its armor table encodes preferred armor type (cloth, leather, mail, plate).

**Tier tokens:** token-to-reward-per-class mapping at LootReserve/Data.lua:17451-17455 (for example 29760 maps to …). Resolve tokens before BiS matching.

---

## 7. Tooltips

- **Use `HookScript("OnTooltipSetItem", fn)` plus `tt:GetItem()`.** This works on 20506:
  - LootReserve/Client.lua:399-404 (GameTooltip, ItemRefTooltip, ItemRefShoppingTooltip1/2, ShoppingTooltip1/2).
  - LoonBestInSlot/UpdateTooltips.lua:215-234; AtlasBIStooltips/AtlasBIStooltips.lua:258-262; Questie/Modules/Tooltips/Tooltip.lua:458, 479.
  - TacoTip/main.lua:417-420 does the same, but TacoTip.toc declares Interface 11304, so it is weak evidence.
- **`TooltipDataProcessor` does not exist on 2.5.x.**
  - Blizzard_GameTooltip_Classic.toc loads only `Classic\GameTooltip.lua` [WEB].
  - LootCheck's release notes say 2.5.x "has no such API" [WEB].
  - ArmoryUtils/itemlevel.lua:944-948 and Auctionator/Source/Tooltips/Hooks.lua:316-346 feature-detect it and fall back to the old path.
- **Deduplicate your added lines.** Hooks can fire repeatedly; scan `_G[tt:GetName().."TextLeft"..i]` for your marker first (LootReserve/Client.lua:378-385).

---

## 8. UI toolkit

**Frames and backdrops:**
- `BackdropTemplate` is required for `SetBackdrop` (TehBoxLootCouncil.lua:992; AtlasLootClassic/Button/Item_type.lua:408 uses `BackdropTemplateMixin and "BackdropTemplate"`).
- Use `SetResizeBounds`; `SetMinResize` is gone (Questie/Modules/QuestieCompat.lua:56-60).

**Templates seen on 20506:**

| Template | Where |
|---|---|
| `BasicFrameTemplateWithInset` | LootReserve/Windows/ClientWindow.xml:364 |
| `ButtonFrameTemplate` (+ `ButtonFrameTemplate_HidePortrait`) | GudaBags/Core/Theme.lua:155-160 |
| `PortraitFrameTemplate` | WeakAurasOptions/OptionsFrames/OptionsFrame.lua:103 |
| `InsetFrameTemplate` | LoonBestInSlot/UI/NewFeaturesWindow.lua:46 |
| `UIPanelButtonTemplate`, `UIPanelCloseButton` | TehBoxLootCouncil.lua:1016 |
| `InputBoxTemplate` | TehBoxLootCouncil_LootCouncil.lua:1306 |
| `SearchBoxTemplate` | LootReserve/Windows/ClientWindow.xml:612 |
| `UIPanelScrollFrameTemplate` | LootReserve/Windows/Common.xml:228 |
| `ScrollFrameTemplate` + `MinimalScrollBar` | Leatrix_Plus.xml:2-7 |
| `UICheckButtonTemplate` | TehBoxLootCouncil_Attendance.lua:701 |

**Modern ScrollBox is available and used on all flavors:**
- `CreateFrame("Frame", nil, p, "WowScrollBoxList")`, `CreateScrollBoxListLinearView()`, `ScrollUtil.InitScrollBoxListWithScrollBar(box, bar, view)`, `box:SetDataProvider(CreateDataProvider(rows))`.
- Evidence: Auctionator/Source/Tabs/Shopping/Mixins/ListsContainer.lua:382-423, ResultsListing.lua:10-16 (the Source manifest loads on all flavors); WeakAuras/Profiling.lua:567-575 and Profiling.xml:204 (both in WeakAuras_TBC.toc).
- `CreateScrollBoxListGridView` is not used locally, but `ScrollBoxGridView.lua` exists on the branch [WEB], so it should work for the slot grid.

**Dropdowns — all three kinds exist:**
- **Modern:** `CreateFrame("DropdownButton", nil, p, "WowStyle1DropdownTemplate")` plus `MenuUtil.CreateRadioMenu` (Leatrix_Plus.lua:13362-13374). `MenuUtil.CreateContextMenu(owner, fn(owner, root) root:CreateButton(...))` (Auctionator/Source/Tabs/Selling/Mixins/BagUse.lua:78; WeakAurasOptions/AceGUI-Widgets/AceGUIWidget-WeakAurasDisplayButton.lua:1480). Guard with `DoesTemplateExist` (GudaBags/UI/Controls/Select.lua:35).
- **Legacy Blizzard:** `UIDropDownMenuTemplate` with `UIDropDownMenu_Initialize`, `CreateInfo`, `AddButton` and `ToggleDropDownMenu` (Raidify/Components.lua:1284-1303; GudaBags/UI/CategoryEditor.lua:40-47). It can cause taint; prefer MenuUtil.
- **LibUIDropDownMenu-4.0:** `LootReserve.LibDD:Create_UIDropDownMenu` (LootReserve.lua:13; Windows/ServerWindow.xml:387).

**Tabs:**
- Use `CharacterFrameTabButtonTemplate` on Classic. GudaBags/UI/TabPanel.lua:231-233 notes that `PanelTabButtonTemplate` is the retail choice; LoonBestInSlot/UI/LootBrowser.lua:175 is another example.
- `PanelTemplates_SetNumTabs(frame, n)` and `PanelTemplates_SetTab(frame, i)` (LootReserve/Windows/ServerWindow.lua:902-903; LoonBestInSlot/UI/LootBrowser.lua:235).

**Settings panel:**
- `local cat = Settings.RegisterCanvasLayoutCategory(panel, "DisasterZone"); Settings.RegisterAddOnCategory(cat)` (Leatrix_Plus.lua:11459-11460; GudaBags/UI/SettingsPopup.lua:1639-1641).
- Subcategories: `Settings.RegisterCanvasLayoutSubcategory` (Auctionator/Source/Config/Mixins/PanelConfig.lua:25).
- Open with `Settings.OpenToCategory(cat:GetID())`. AceConfigDialog's `AddToBlizOptions` returns `(frame, categoryID)` (LoonBestInSlot/Settings.lua:534, MinimapButton.lua:19).
- `InterfaceOptions_AddCategory` should be treated as absent; AtlasLootClassic_OptionsPanel.lua:182 guards it.

**Other widgets:**
- **Minimap button:** LibDataBroker `NewDataObject` plus `LibDBIcon:Register(name, obj, db.minimap)` (RaidHelper_TBC/Core.lua:1901-1923; LibDBIcon MINOR 44).
- **Escape to close:** `tinsert(UISpecialFrames, "GlobalFrameName")` (Leatrix_Plus.lua:13392).
- **StaticPopupDialogs:** `hasEditBox`, `self.editBox` (LootReserve/Server.lua:260-283). Use `self.GetEditBox and self:GetEditBox() or self.editBox` defensively.
- **Raid warning:** `RaidWarningFrame` exists (DBM-Core.lua:4225). `RaidNotice_AddMessage` is not used anywhere locally (unverified). `SendChatMessage(msg, "RAID_WARNING")` needs leader or assist (TehBoxLootCouncil_LootCouncil.lua:571).
- **Sound:** `PlaySound(SOUNDKIT.RAID_WARNING, "Master")` (RXPGuides/Tips.lua:115); `SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON` (LibUIDropDownMenu.lua:380).
- **Class colors:** `RAID_CLASS_COLORS[classFile]` (LootReserve.lua:690-707). `C_ClassColor.GetClassColor(classFile)` exists on the branch [WEB]. Class icons: `CLASS_ICON_TCOORDS` with `Interface\TargetingFrame\UI-Classes-Circles` (TehBoxLootCouncil.lua:734-742). `SetPortraitToTexture` is unverified.
- **Model preview:** `CreateFrame("DressUpModel", …)` with `:SetUnit("player")` (AtlasLootClassic/Button/Item_type.lua:414-425); `DressUpItemLink(link)` (:141); `HandleModifiedItemClick(link)` (:131; LoonBestInSlot/Common.lua:321-323).

**Shift-click links into chat or your own EditBox:**
- AtlasLootClassic/Button/Button.lua:116 calls `ChatFrameUtil.InsertLink(link)` unguarded.
- `ChatEdit_InsertLink` and `ChatEdit_GetActiveWindow` are only deprecation aliases [WEB]. Blizzard code calls `ChatFrameUtil`, so hooking the old global **will not** catch shift-clicks.
- Questie notes the same 2.5.5 chat refactor (QuestieAnnounce.lua:19-21; QuestLinks/Link.lua:538-583).
- Pattern (LoonBestInSlot/libs/AceGUI-3.0/widgets/AceGUIWidget-EditBox.lua:20-37; Auctionator/Source/Shopping/Hooks.lua:51-55):

  ```lua
  local f = ChatFrameUtil and ChatFrameUtil.InsertLink
  if f then hooksecurefunc(ChatFrameUtil, "InsertLink", h) else hooksecurefunc("ChatEdit_InsertLink", h) end
  -- h(text): if myEditBox:HasFocus() then myEditBox:Insert(text) end
  ```

**Drag and drop:**
- `GetCursorInfo()` returns `"item", itemID, itemLink`; then call `ClearCursor()` (TehBoxLootCouncil.lua:2672-2674; Leatrix_Plus.lua:3756).
- Handle this in both `OnReceiveDrag` and `OnMouseUp`.

**Event safety:**
- `C_EventUtils.IsEventValid(evt)` before `RegisterEvent`, because unknown events raise errors (ArmoryUtils/libs/D4Lib/D4Lib.lua:167; Details/frames/window_mythicplus/window_end_of_run.lua:88).
- `EventUtil.ContinueOnAddOnLoaded(name, fn)` (Auctionator/Source/Tooltips/Hooks.lua:348).

---

## 9. Talents and spec

**`GetTalentTabInfo(tab[, isInspect, isPet, group])`** returns `id, name, description, icon, pointsSpent, background, previewPointsSpent, isUnlocked`. This is the modern order.
- Evidence: RaidHelper_TBC/RoleScan.lua:134 (5th = points, 6th = fileName); DBM-Core.lua:3444; Details/core/gears.lua:765; RXPGuides/ItemUpgrades.lua:734-740; wiki [WEB].
- The **old 2.4.3 order** (`name, icon, points, bg`) breaks. TehBoxLootCouncil_Talents.lua:385 treats the first return as the name (on 2.5.6 it is the numeric ID). SwedgeTimer/utils.lua:91-96 checks `type(r1)` to handle both orders.

**Other talent APIs:**
- `GetNumTalentTabs()`.
- `GetTalentInfo(tab, i, isInspect, isPet, group)` returns `name, icon, tier, column, rank, maxRank, …`. It is not in row/column order (TehBoxLootCouncil_Talents.lua:70-80).
- `GetActiveTalentGroup` is guarded locally.
- `UnitClass(u)` returns `localized, classFile, classID`.

---

## 10. SavedVariables, load order, TOC

- **Load order:** `ADDON_LOADED(name)` fires after your files and SavedVariables load. Then `PLAYER_LOGIN`, then `PLAYER_ENTERING_WORLD(isInitialLogin, isReloadingUi)` (TehBoxLootCouncil.lua:1437).
- **At login:** guild and item data are not ready. Request the roster and item data, then react to `GUILD_ROSTER_UPDATE` and `GET_ITEM_INFO_RECEIVED`.
- **TOC selection:** a flavor-specific TOC wins.
  - LootReserve/LootReserve.toc declares 50504, while LootReserve_TBC.toc declares 20506.
  - Both `_TBC.toc` and `-BCC.toc` are used (Questie/Questie-BCC.toc; GladiusEx-BCC.toc).
  - A single `DisasterZone.toc` with `## Interface: 20506` is enough (LoonBestInSlot, TehBox and RaidHelper_TBC all do this).
  - A comma list is allowed: `## Interface: 20504, 20505, 20506` (Raidify_Loot/Raidify_Loot_TBC.toc:1; GudaBags/GudaBags.toc:1).
- **Per-file conditions:** `file.lua [AllowLoadGameType tbc, wrath]` (Auctionator/Auctionator.toc:29-50).
- **Other directives:**
  - `## SavedVariables` and `## SavedVariablesPerCharacter` (LootReserve_TBC.toc).
  - `## Category`, `## IconTexture` (fileID or path).
  - `## OptionalDeps`, `## Dependencies`.
  - `## LoadSavedVariablesFirst: true` appears in Leatrix_Plus.toc:9; its exact semantics are unverified.
- **Metadata:** use `C_AddOns.GetAddOnMetadata` and `C_AddOns.IsAddOnLoaded` (LootReserve.lua:93-98).
- **Project ID:** `WOW_PROJECT_ID == WOW_PROJECT_BURNING_CRUSADE_CLASSIC` (5) (GudaBags/Core/Expansion.lua:9-19).

---

## 11. Things that break naive retail-11.x or 2.4.3 code

| Area | Wrong | Right on 20506 |
|---|---|---|
| Loot method | global `GetLootMethod()` returning a string (gone after 2.5.5) | `C_PartyInfo.GetLootMethod()` compared with `Enum.LootMethod.Masterlooter` (2) |
| Guild refresh | `GuildRoster()` | `C_GuildInfo.GuildRoster()` |
| Tooltips | `TooltipDataProcessor` (retail) | `HookScript("OnTooltipSetItem")` |
| LootFrame | retail ScrollBox `LootFrame.ScrollBox` | `LootButton1-4`, `.slot`, `LootFrame_UpdateButton` |
| Chat links and filters | hooking `ChatEdit_InsertLink` or `ChatFrame_*` (aliases only) | `ChatFrameUtil.InsertLink`, `.AddMessageEventFilter`; hyperlinks via `ChatFrameMixin` OnHyperlinkClick (Questie Link.lua:564-583) |
| Item and chat globals | `GetItemInfo`, `SendChatMessage`, `IsEquippableItem` (fallbacks gated by CVar) | `C_Item.*`, `C_ChatInfo.SendChatMessage` |
| Containers | `GetContainerItemInfo` returning several values | `C_Container.GetContainerItemInfo` returning a table |
| Talents | `name, icon, points = GetTalentTabInfo` | `id, name, desc, icon, points, bg…` |
| Loot slot | `local itemID = GetLootSlotInfo()` | returns icon first; quality is 5th; validate the `GetLootSlotLink` result |
| Master-loot candidate | `GetMasterLootCandidate(1)` | `(slot, 1..40)`, allowing gaps |
| Loot button slot | `button:GetID()` | `button.slot` |
| Addon comms | ignoring the throttle | 10 burst, 1/s per prefix; check the result enum; whisper outside instances is unthrottled |
| Names | assuming bare names | `CHAT_MSG_ADDON` and the guild roster give `Name-Realm` |
| Frames | `SetMinResize`; backdrop without template | `SetResizeBounds`; `BackdropTemplate` |
| Missing events | `GUILDBANKFRAME_OPENED`, `PLAYER_INTERACTION_MANAGER_*` | not present on TBC (GudaBags/Data/GuildBankScanner.lua:533; Core/Expansion.lua:47) |

Also present on this client: modern Settings, Menu/MenuUtil, ScrollBox, EditMode (there are `edit-mode-cache` files in WTF), `C_EventUtils` and the Item mixin.

**Global pollution from other addons:** TehBox defines `TBRT`, `SendAddonMessage` and `RegisterAddonMessagePrefix`. `Details/luaserver.lua` is a lint stub that is not loaded — ignore its fake APIs. Prefix all DisasterZone globals with `DisasterZone`.

---

## 12. Open uncertainties

- `IsMasterLooter()`, `IsGuildLeader()`, `RaidNotice_AddMessage`, `SetPortraitToTexture` and `C_Container.GetContainerItemID` exist in theory but no local 20506 addon proves them (except LootReserve for `IsMasterLooter`).
- Whether non-master-looter raiders can open a master-looted corpse and read slot data is unverified. Design as if only the master looter can, and broadcast.
- TehBox's claim that encounter events sometimes arrive with nil ID or name on Anniversary is unverified.
- The meaning of `LoadSavedVariablesFirst` is unverified.
- The exact LibCustomGlow look on the 4-button LootFrame is untested.
- The `LootFrame_UpdateButton` hook above is built from the Blizzard source, not taken from an installed addon.

Sources: [GetLootMethod](https://warcraft.wiki.gg/wiki/API_GetLootMethod), [C_PartyInfo.GetLootMethod](https://warcraft.wiki.gg/wiki/API_C_PartyInfo.GetLootMethod), [C_ChatInfo.SendAddonMessage](https://warcraft.wiki.gg/wiki/API_C_ChatInfo.SendAddonMessage), [GuildRoster](https://warcraft.wiki.gg/wiki/API_GuildRoster), [GetGuildRosterInfo](https://warcraft.wiki.gg/wiki/API_GetGuildRosterInfo), [GuildControlGetRankName](https://warcraft.wiki.gg/wiki/API_GuildControlGetRankName), [GetGuildInfo](https://warcraft.wiki.gg/wiki/API_GetGuildInfo), [GetLootSourceInfo](https://warcraft.wiki.gg/wiki/API_GetLootSourceInfo), [GetMasterLootCandidate](https://warcraft.wiki.gg/wiki/API_GetMasterLootCandidate), [GetTalentTabInfo](https://warcraft.wiki.gg/wiki/API_GetTalentTabInfo), [wow-ui-source classic_anniversary](https://github.com/Gethe/wow-ui-source/tree/classic_anniversary), [LootCheck v1.9.1 notes](https://github.com/mikebvs/LootCheck/releases/tag/v1.9.1).