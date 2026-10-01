# DisasterZone SPEC — ADDENDUM F: picker defaults, disabled slots, crafted/rep/badge items, raid lock

User requests (2026-09-28):
1. "Raids + dungeons should be defaulted when choosing an item."
2. "You should be able to right click a slot in the My BiS to be able to disregard a slot, like disable it."
3. "We should include crafted items & reputation items in the selectable items too." (We add Badge of Justice vendor items as well — a major TBC BiS source.)
4. "The raid leader should be able to lock / unlock the list for all participants during raid."

## 35. Picker sources & default
- Replace the scope dropdown with a **Sources** dropdown of checkboxes (MenuUtil `CreateCheckbox`, the menu stays open while toggling): **Raids**, **5-man dungeons**, **Crafted**, **Reputation**, **Badge vendors**, **PvP** (arena seasons + honor gear; added at the user's request).
  - Default: **Raids + 5-man dungeons**. Remember the choice for the session (and persist it per character in `settings.pickerSources`).
- The phase filter ("up to Pn" / "only Pn" / "all phases") applies to every source that has a phase.
  - Crafted, rep and badge items take their phase from the data (§37).
  - Items without a phase count as phase 1.
- Section headers:
  - Raids and dungeons: as today.
  - Crafted: "Crafted — Blacksmithing", then sub-headers per specialisation where the data has one.
  - Reputation: "Reputation — The Sha'tar".
  - Badges: "Badge of Justice — G'eras" (and other badge vendors).
  - PvP: "PvP — Arena Season 1 (Gladiator)" … "PvP — Honor vendors".
- Row subtitles come from `ItemDB:GetSourceText`:
  - "Blacksmithing (375)" (profession + skill; add the specialisation, e.g. "Armorsmith", when known)
  - "The Sha'tar — Exalted"
  - "G'eras — 60 badges"
  - "Arena S2 — 1875 arena points (1850 rating)" / "Honor — 11794 honor + 20 marks", with faction-specific items tagged with their faction
  - "BoP" tag for bind-on-pickup crafted items when known.
- Search matches the item name plus profession, faction and vendor names.

## 36. Disabled slots (My BiS)
- Right-click a tile → the context menu adds:
  - **"Disable slot (P<n>)"** / **"Enable slot (P<n>)"**
  - **"Disable in all phases"** / **"Enable in all phases"**
- Data: a new top-level ListData key `dx = { [phase] = { [sid] = true } }`, omitted when empty.
  - Store validation accepts it with limits: phases 1..5, sids 1..17, `true` values only.
  - Old clients ignore unknown top-level keys (verify the current Store validator does; if a 0.2 client would REJECT the list because of `dx`, bump the list schema field `v` only if needed and handle it; prefer staying compatible).
  - The hash covers `dx` (it's part of data).
- Effects of a disabled slot:
  - **Paper doll**: the tile is greyed (desaturated slot texture), labelled "Disabled — not needed", with the picks kept but hidden (dimmed) if present; clicking offers "Enable slot".
  - **Progress, need counts, "Still needed from"**: the slot is excluded (x / 16 etc.).
  - **Council roster matrix**: the cell shows a dark "–" with the tooltip "Disabled by player".
  - **"Need n"**: excludes it.
  - **`Store:GetWanters`**: skips entries whose (phase, sid) is disabled, so no drop alert or wanter lists for them.
  - **`BiS:MatchItem`**: skips disabled slots.
  - **Loon suggestions / Copy phase**: never fill a disabled slot.
- API:
  - `BiS:IsSlotDisabled(phase, sid)`
  - `BiS:SetSlotDisabled(phase, sid, disabled)`
  - `BiS:SetSlotDisabledAllPhases(sid, disabled)`
  - `Store`: a helper `IsSlotDisabled(record, phase, sid)` used by the views.

## 37. Crafted / reputation / badge item data
- New generated file **`Data/Sources.lua`** (added to the TOC after Data\Dungeons.lua):
```lua
ns.Data.Crafted = { { key="Blacksmithing", name="Blacksmithing", items = { { id=, skill=, spec="Armorsmith"|nil, phase=, bop=true|nil, reagentsNote=? }, ... } }, ... }
ns.Data.Reputation = { { key="Shatar", name="The Sha'tar", factionID=, items = { { id=, standing="Exalted"|"Revered"|"Honored"|"Friendly", phase= }, ... } }, ... }
ns.Data.Badges = { { key="Geras", name="G'eras", items = { { id=, cost=60, phase= }, ... } }, ... }
ns.Data.PvP = { { key="S1", name="Arena Season 1 (Gladiator)", phase=, items = { { id=, cost="1875 arena"|nil, rating=nil|1850, faction=nil|"Alliance"|"Horde", phase= }, ... } }, { key="Honor", name="Honor vendors", ... } }
```
- Sources:
  - `AtlasLootClassic_Crafting` (TBC professions: Blacksmithing, Leatherworking, Tailoring, Jewelcrafting, Engineering, plus Alchemy for trinkets/stones where equippable).
  - `AtlasLootClassic_Factions` (TBC factions).
  - AtlasLoot collections/vendor tables for Badge of Justice rewards (G'eras; Smith Hauthaa / Sunwell badge vendors if present).
  - Plus the TBC phase modules for phases.
  - Keep **only equippable items** (armor, weapons, rings, necks, trinkets, relics, cloaks, shields, off-hands). Use Questie's item DB class/subclass or AtlasLoot data to decide. Exclude bags, consumables, gems, enchants, mounts, pets, patterns-as-items (keep the crafted RESULT item, not the recipe).
- Cross-check against LoonBestInSlot ItemSources (SourceType Profession / Reputation / Dungeon Token), but DO NOT ship Loon data (no license file).
- `ItemDB` integration:
  - `GetSources` returns entries `{ kind = "raid"|"dungeon"|"craft"|"rep"|"badge"|"pvp", ref|craft|rep|badge = ..., phase = }`, keeping existing raid/dungeon fields.
  - `GetSourceText` handles every kind.
  - `GetCandidates(sid, filter)` gets `filter.sources = { raids=true, dungeons=true, crafted=bool, rep=bool, badges=bool, pvp=bool }`, which supersedes `filter.scope`. Keep `scope` working for existing callers.
  - The My BiS "Still needed from" card groups crafted / rep / badge items under "Crafted (n)", "Reputation (n)", "Badges (n)", "PvP (n)".

## 38. Raid leader lock
- A group rule (Addendum D/E): the GS field `lk = true|nil` (plus `lkAt` = the leader's server time when locked). Only the group authority can set it.
  - In a raid, the authority is the raid leader. Per E §33 the ML can also be the authority; the lock should be settable by the authority, i.e. RL first.
  - The lock ends when the group disbands, when the authority leaves (rules cleared), or on unlock.
- Controls:
  - The raid leader gets **"Lock BiS lists" / "Unlock BiS lists"** in: the drop panel footer (small button), the Council tab toolbar, and the Settings group-rules section.
  - Slash: `/dz lock` / `/dz unlock`.
  - On lock, announce to raid chat once, if `roll.announce` is on: "DisasterZone: BiS lists are locked for this raid."
- **Raider enforcement (client side)**, while locked and I'm in that group:
  - `BiS:SetSlot`, `ClearSlot`, `SwapMainAlt`, `CopyPhase`, `ApplyTemplate`, `ClearPhase`, `SetSpec`, `SetSlotDisabled*` refuse, printing "BiS lists are locked by <RL> during the raid."
  - My BiS shows a lock banner and disables editing controls; the Picker won't open.
  - Obtained/equipped scanning and manual "Mark obtained" still work: `ob`/`eq` still sync.
- **Council detection:**
  - When a lock starts, every council client snapshots a **picks hash** for every raid member: `Util.Hash({ph=data.ph, dx=data.dx, sp=data.sp})` from its cached list.
  - When a new list for a raid member arrives during the lock and its picks hash differs from the snapshot → mark `changedDuringLock = GetServerTime()` on the cached record (memory), still accept the list (ob/eq updates matter), and print a council-only chat warning once per player: "DisasterZone: ⚠ <Name> changed their BiS list while lists were locked."
  - Show "⚠ changed during lock" in:
    - the roster row (warning icon + tooltip),
    - Member view header,
    - DropPanel candidate rows and roll rows (small ⚠ with tooltip),
    - roll suggestion — a flagged player is NOT auto-suggested (they stay listed; the council can still award).
  - Snapshots clear when the lock ends.
- Messages: no new message type; `lk`/`lkAt` ride on GS. `GetActive().values.lk` / `GroupRules:IsLocked()` / `GroupRules:GetLockInfo()` → `{by=, at=}`.

## 39. Tests
- **Picker:** the default sources are raids + dungeons; toggling Crafted/Rep/Badges/PvP adds sections; PvP faction items only show for the player's faction; search by profession/faction; subtitles.
- **Disabled slots:** disable, then the paper doll is greyed, progress is x/16, council cell "–", GetWanters/MatchItem skip it, drop alert and toast don't fire for that slot; enable restores; syncs to council; a 0.2-style validator accepts it (compat).
- **Lock:** the RL locks → raiders can't edit (every BiS API refuses, picker won't open), obtained scanning still syncs, a forged edit from a modified client (bypass via direct data change + commit) is flagged on council clients, the flagged player is not suggested in a roll, unlock clears it, the lock ends on disband, a non-RL can't lock (GS from non-authority ignored), and a mid-raid joiner learns the lock via GQ.
