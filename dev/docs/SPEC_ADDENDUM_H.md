# CDLoot SPEC — ADDENDUM H: main-spec / off-spec lists

User request (2026-09-28): separate main-spec and off-spec BiS lists, switched in the My BiS header. Agreed design
(the user accepted both recommendations): **one** off-spec list per character, and off-spec wanters rank **between**
main-spec alts and players who don't list the item.

## 43. Data

- The synced ListData gets three optional top-level keys, all omitted while the player has no off spec:
  - `os` = the off-spec label (a `ns.SPECS` label of the class; `""` = off spec started, spec not chosen yet);
  - `op` = its phases, exactly the shape of `ph`;
  - `ox` = its disabled slots, exactly the shape of `dx`.
- **Why flat:** 0.6 validators cap nesting at depth 4 (`data → ph → phase → pair`). A nested `os = { ph = … }` would
  be depth 5 and 0.6 council members would reject the whole list. Flat keys have the depth of `ph` / `dx`; older
  validators ignore unknown keys and still verify the hash (which covers them).
- `ob` (obtained) and `eq` (equipped) are shared: `ob` covers items of both lists.
- `ns.HasOffSpec(data)`, `ns.ListView(data, list)` (a read-only ListData-shaped view: `list == "os"` → `sp = os`,
  `ph = op`, `dx = ox`, shared `ob` / `eq`, `offSpec = true`), `ns.ListRecordView(rec, list)`.
- The lock's picks hash (Addendum F §38) covers `os` / `op` / `ox` too.

## 44. BiS API

- Every edit / query takes an optional trailing `list` (`"ms"` default, `"os"`): `GetSlot`, `SetSlot`, `ClearSlot`,
  `SwapMainAlt`, `ClearPhase`, `ApplyTemplate`, `IsSlotDisabled`, `GetDisabledSlots`, `SetSlotDisabled`,
  `SetSlotDisabledAllPhases`, `GetSpec`, `SetSpec` (off spec: class specs only, no auto-detect), `GetPhaseItems`.
- `CopyPhase(from, to, overwrite, list, fromList)`: also across lists (`CopyPhase(2, 2, false, "os", "ms")`).
- `HasOffSpec()`, `AddOffSpec(label)`, `RemoveOffSpec()`, `GetListView(list)`. Any off-spec pick creates `os = ""`.
- `MYLIST_CHANGED(phase, sid, list)`: third argument `"os"` for off-spec edits.
- `MatchItem` returns off-spec matches with `os = true`, after every main-spec match.
- `AllListItems` / `HasPicks` cover both lists. The raid lock refuses off-spec edits like main-spec ones.

## 45. Council

- `Store:ValidateData` validates `os` (string ≤ 24, no escapes), `op` (as `ph`), `ox` (as `dx`).
- The index adds off-spec rows (`os = true`); disabled `ox` slots are left out.
- `Store:GetWanters(itemID, { list = "ms" | "os" | "both" })`: default `"ms"` (unchanged for every existing caller);
  `"both"` = main-spec wanters first, then off-spec wanters who don't list the item for their main spec. Off-spec
  entries carry `os = true` and `spec` = the off-spec label.
- `Store:IsSlotDisabled(record, phase, sid, list)`, `Store:GetPlayerSummary(key, phase, list)`.
- Council tab: an **Off-spec lists** checkbox switches Roster / Items / Member to the off-spec lists (only players
  who have one, with the off-spec spec). Items view "Record award to" defaults to reason Offspec there.

## 46. Rolls, awards, alerts

- Roll tiers: 1 main-spec BiS, 2 main-spec alt, **3 off-spec list** (main or alt pick, not obtained), 4 everyone else
  (was 3). `LiveWanters` uses `list = "both"`. RT carries tier 3 (0.6 receivers skip it).
- `ns.ReasonForTier(3) = "os"`: a roll won through the off-spec list is recorded as Offspec (not loot won).
- Drop panel: wanters with `list = "both"`; badge `[OS]` / `[OS alt]` (colour `ns.COLORS.offspec`); count
  `"1 want +1 OS"`; announce `"... Alt: Dave; OS: Carol"`; roll rows `[OS]`; Award... menu defaults to Offspec for
  off-spec wanters.
- Tooltips: own `"Your P1 off-spec BiS (Protection) - Main Hand"` (and `"+ off spec"` after a main-spec line);
  council header `"+N off spec"` and names with `(OS)`.
- Roll popup: `"Your P1 off-spec BiS (Protection) - Main Hand"`.
- Personal alerts: toast `"On your off-spec list (Protection)"` and chat line, behind the new personal setting
  `alerts.offspec` (default on). Loot-window badges and glow stay main-spec only.

## 47. My BiS

- Top bar: P1–P5 (narrower), **[Main spec] [Off spec]** buttons (the shown list highlighted; `"+ Off spec"` until
  one exists), then the spec dropdown of the shown list (off spec: class specs + "Remove off-spec list..." with a
  confirmation), Copy from (adds "Copy main spec Pn" / "Copy off spec Pn"), Suggest (LoonBestInSlot for the shown
  list's spec), Clear phase (the shown list).
- The doll, slot menu, picker (`Picker:Open(..., list)`; title "· Off spec"), disabling, drag and drop and the
  progress card ("Off-spec progress") all follow the shown list. `MyBiS:SetList / GetList / ConfirmRemoveOffSpec`.
- Demo: Brakka (Prot), Caelith (Prot), Kaelyn (Elemental) and Quillon (Feral bear) have off-spec lists, generated after
  every main list so the rest of the demo data is unchanged.
