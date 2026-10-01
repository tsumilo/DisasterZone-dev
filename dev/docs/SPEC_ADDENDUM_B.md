# DisasterZone SPEC — ADDENDUM B: Dungeon mode + 5-man loot data

Read together with `SPEC.md` and `SPEC_ADDENDUM_A.md`. The user asked: "Does our addon work for dungeons? … Maybe we add a dungeon mode for it?"

Current state: all group traffic is raid-only. This includes:
- DROP `D` is sent only when `IsInRaid()`.
- Rolls `RS/RR/RE/RW` need a raid and are dropped if `dist ~= "RAID"`.
- Auto ledger entries need `Util.InRaidInstance()`.
- The quality threshold defaults to Epic.
- The item DB and picker contain raid items only.

## 21. 5-man dungeon loot data (always available, independent of the mode)

### 21.1 Data generation
- Extend the existing generator `SCRATCH\gen_cdloot_data.py`, or write a companion `SCRATCH\gen_cdloot_dungeons.py` that reuses its parser, to emit **`DisasterZone\Data\Dungeons.lua`**. Add it to the TOC right after `Data\Items.lua`.
- Source: `AtlasLootClassic_DungeonsAndRaids\data-tbc.lua`, the entries with `ContentType = DUNGEON_CONTENT` (TBC 5-mans only). Also check for Magisters' Terrace.
  - Hellfire Ramparts, Blood Furnace, Shattered Halls
  - Slave Pens, Underbog, Steamvault
  - Mana-Tombs, Auchenai Crypts, Sethekk Halls, Shadow Labyrinth
  - Old Hillsbrad, Black Morass
  - Mechanar, Botanica, Arcatraz
  - Magisters' Terrace
- Shape (mirrors `ns.Data.Raids`):
```lua
ns.Data.Dungeons = {
  { key = "HellfireRamparts", name = "Hellfire Ramparts", phase = 1, instanceID = 543, bosses = {
      { key = "Gargolmar", name = "Watchkeeper Gargolmar", npcIDs = { 17306, 18436 }, items = { ... }, heroicItems = { ... } },
  }},
}
```
- `phase`: take it from AtlasLoot's phase field if present (Magisters' Terrace = 5). Otherwise use 1.
- `items` is the NORMAL_DIFF list and `heroicItems` is the HEROIC_DIFF list.
- Apply the same row-skipping rules as the raid generator. Skip Badge of Justice and gems/currency in heroic lists, but keep patterns.
- Keep `-- Item Name` comments.
- Include chest pseudo-bosses and trash tables when AtlasLoot has them.
- npcIDs: AtlasLoot's npcIDs (normal + heroic variants), plus DBM-Party-BC / DBM-Outlands `SetCreatureID` values if installed.
- Validate that the generated Lua compiles (lupa).
- Spot-check at least 5 bosses (normal + heroic lists) by comparing the generated IDs with the AtlasLoot source rows. Do NOT rely on memory for item names.

### 21.2 ItemDB integration
- Dungeon bosses become bossRefs like raid bosses:
  - `ref.key = dungeon.key .. ":" .. boss.key`
  - `ref.raid = dungeonTbl`, with a new flag `ref.dungeon = true`
  - `ref.phase = dungeon.phase`
- Sources record the difficulty: `{ ref=, via=, heroic = true|nil }`.
- `GetSourceText` shows "Boss · Dungeon (Heroic)" when the item is only available on heroic, and "Boss · Dungeon" otherwise. Short form: "Boss (H)".
- `GetBossBySourceGUID` and `GetBossByEncounter` cover dungeon npcIDs.
- `GetCandidates(sid, filter)`:
  - New `filter.scope`: `"raids"` (default; the existing behaviour), `"dungeons"` (5-man items only), or `"all"`.
  - The existing phase filters apply to dungeons too.
  - Heroic and normal items both count; each row carries `heroic=true` when the item comes from a heroic list only.
- Nothing about Store, wanters or the council matrix changes: they work by item ID.

### 21.3 Picker
- The raid scope dropdown gains **"5-man dungeons"** and **"Raids + dungeons"**.
- Dungeon headers are shown with a "(5-man)" suffix.
- Rows from heroic-only lists show a small "Heroic" tag.

## 22. Dungeon mode

### 22.1 Settings & activation
- New settings (DB defaults): `dungeon = { enabled = false, quality = 3 }`. `quality` is the minimum quality for drops inside 5-man instances (3 = Rare).
- Toggle it from a Settings "Dungeon mode" section (checkbox + quality dropdown Rare/Epic + short explanation), or with `/dz dungeon [on|off]`.
- **Group propagation**: a new message `DM` on **PARTY** (alert class), fields `{t="DM", on=bool}`.
  - **Sending**:
    - When a player turns dungeon mode on while in a party (not a raid) and is the party leader or council, send `DM{on=true}`. Turning it off sends `DM{on=false}`.
    - While on, the enabler re-sends `DM{on=true}` (debounced 3s) on `GROUP_UPDATED` so newly joined members pick it up.
  - **Receiving**:
    - Gate: the sender is in my party AND (`UnitIsGroupLeader(senderUnit)` or `ns.Guild:IsCouncil(sender)`).
    - On receipt, set the session-only flag `Dungeon.groupEnabledBy = senderKey` (or clear it), fire `DUNGEON_MODE_CHANGED`, and print "DisasterZone: dungeon mode enabled by X (5-man loot sharing & rolls)".
    - The flag clears when I leave the group, or when the group becomes a raid.
- **Effective mode** — implement in Util (or a small new module `Core/Dungeon.lua`; if new, add it to the TOC after Core/Util.lua):
  - `Util.IsDungeonModeActive()` = `IsInGroup() and not IsInRaid() and (settings.dungeon.enabled or groupEnabledBy ~= nil)`.
- **`Util.GetGroupChannel()`**:
  - Returns `"RAID"` if `IsInRaid()`.
  - Returns `"PARTY"` if `Util.IsDungeonModeActive()`.
  - Returns nil otherwise.
- Add `DUNGEON_MODE_CHANGED(active)` to the §3.3 message catalogue.

### 22.2 Behaviour while dungeon mode is active (in a 5-man party)
- **Drops (Loot.lua)**:
  - Broadcast `D` on `Util.GetGroupChannel()` instead of RAID-only.
  - The suppression and "am I the looter" logic works for a party too: in a party, the master looter is `C_PartyInfo.GetLootMethod()` with `masterLootPartyID`, and party loot is often group loot.
  - Receivers accept `D` on PARTY when dungeon mode is active for them.
  - The quality threshold inside a 5-man instance (`IsInInstance()` type `"party"`) is `settings.dungeon.quality`.
  - The personal toast and chat line work as in raids.
- **Rolls (Roll.lua)**:
  - All `RS/RR/RE/RW` send/receive paths use `Util.GetGroupChannel()`. Receivers accept `dist == "PARTY"` only when dungeon mode is active.
  - `Roll:CanStart()` in dungeon mode is true for the party leader, the master looter, or council.
  - RS gate on receipt, party variant: the sender is the party leader, the ML, or council.
  - Rolls parse `RANDOM_ROLL_RESULT` the same way; party members see each other's rolls.
- **UI**:
  - `RollFrame` shows in a party when dungeon mode is active.
  - The DropPanel opens for council, and for the party leader in dungeon mode.
  - Announce lines go to PARTY (`UI:AnnounceLine` already falls back to PARTY in a party).
- **Ledger**:
  - Entries created while dungeon mode is active and inside a 5-man instance get `dg = true`: manual awards from the panel/rolls, and auto entries from `CHAT_MSG_LOOT` when the recorder is council.
  - `Ledger:Merge` validation accepts the optional boolean `dg`. The digest covers entries unchanged; `dg` doesn't need to be in the digest string.
  - `Ledger:CountSince` (used for "won N tonight") ignores `dg` entries by default. Add an optional param to include them.
  - Loot Log UI: dungeon rows show a grey "(dungeon)" tag. A new checkbox **"Show dungeon loot"** (default on) filters them.
- **Not in dungeon mode**: a party keeps today's behaviour. Local-only personal alerts apply if the player opens loot; nothing is broadcast.

### 22.3 Demo & tests
- `/dz test` in a 5-man instance with dungeon mode active should simulate a drop from a dungeon boss (a random boss of a random dungeon with `heroicItems`, picking 2–3 items).
- Harness scenarios to add (tests/dungeon/):
  - A 5-client party in a 5-man instance (`world.enter_instance("Black Morass", 269, "party", 5, 2)`); make_party.
  - The leader enables dungeon mode and every member gets `DM`.
  - Loot opens with a dungeon boss GUID and a rare item → `D` on PARTY; council/leader panel; personal toasts.
  - A roll in the party: popups, `RandomRoll`, suggestion, award → ledger entry with `dg=true`, which the Loot Log shows with "(dungeon)".
  - Disband → the mode clears.
  - A non-leader, non-council member can't enable it for others: DM from them is ignored.
  - Dungeon mode off → a party drop is not broadcast.
