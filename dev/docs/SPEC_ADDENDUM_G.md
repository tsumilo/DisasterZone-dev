# DisasterZone SPEC — ADDENDUM G: award reasons, council votes, disenchanter / guild bank

User request (2026-09-28): award reasons (BiS / Alt / Offspec / Disenchant / Guild bank; offspec and disenchant must
not count as loot received), the v2 council voting, and a one-click award to a disenchanter / guild bank character
that the guild config names.

Decisions (asked with the user):
- **Votes and rolls together:** every roll session also takes council votes. Once anyone voted, the most-voted
  player is suggested instead of the roll winner. There is no separate "vote mode".
- **Raiders keep Roll / Pass.** No response categories on the popup.
- **Voter names are visible** to the council (per candidate: count, and who voted on hover).
- **DE / bank:** set by the GM in the guild config; the raid leader can override them for their raid.

The v1 rule stands: DisasterZone only suggests. Every award still needs a click and a confirmation.

## 40. Award reasons

- `ns.AWARD_REASONS` (Constants), in menu order:

  | key | label | counts as loot received | marks the item awarded on the winner's list |
  |---|---|---|---|
  | `bis` | BiS | yes | yes |
  | `alt` | Alt | yes | yes |
  | `up` | Upgrade | yes | yes |
  | `os` | Offspec | no | yes |
  | `de` | Disenchant | no | no |
  | `bank` | Guild bank | no | no |

  `ns.ReasonLabel(key)`, `ns.ReasonForTier(tier)` (1 → bis, 2 → alt, else up).
- Ledger entry fields (optional, older clients drop them): `r` = reason key, `rts` = server time of the last reason
  change.
  - `Clean` keeps any lowercase word of ≤ 8 letters as `r` (a newer version's reason must survive a relay); unknown
    keys count and own like a normal award.
  - `Merge`: the greater `rts` wins; on equal `rts` a missing reason is filled in, and two different reasons settle on
    the smaller key (deterministic on every peer).
  - Digest: an entry's digest string gets `"r" .. r .. rts` only when `rts` is set, so entries whose reason was never
    changed digest exactly like 0.5 (no sync churn with 0.5 peers until someone edits a reason).
  - `Ledger:SetReason(id, reason)` (council; demo → demo log): sets `r`, bumps `rts` (strictly increasing), applies to
    the whole auto-entry cluster of that loot line, broadcasts `A`.
  - `Ledger:CountSince` ("won N tonight") skips `os` / `de` / `bank`. The `awarded` set (Store / roll tiers "already
    awarded") skips `de` / `bank`.
  - `Ledger:Award(itemID, winner, boss, note, dg, reason)`, `Ledger:RecordRollAward(..., dg, reason)`.
- Roll awards: `Roll:Award(id, key, reason)`, `Roll:MarkAwardedExternally(id, key, note, reason)`. The reason travels
  in the popup data and ends up in `Finish`; nil = `ReasonForTier(winner's tier)`. `RW` gains `r`. Receivers record the
  sender's `r` (a 0.5 sender has none → no reason). The announce line uses the label:
  `"[item] -> Bob (rolled 54, BiS)"`, `"(2 votes, rolled 54, Alt)"`, `"(1 vote, Offspec)"`.
- UI:
  - Drop panel: roll-row menu "Award to X" (default reason) + "Award to X as ▸" reasons; the Award... menu gets an
    "Award as offspec ▸" list; an awarded item shows its reason and the Award... menu offers "Reason ▸" to change it.
  - Loot Log: a Reason column, search matches it, right-click "Reason ▸". The Add award / Someone else dialog gets a
    Reason dropdown.
  - Council Items view "Record award to ▸": main pick → BiS, alt → Alt.

## 41. Disenchanter / guild bank

- Guild council list (`CG`, `db.council.guild`) gains `de` / `bk` (wire) = `de` / `bank` (stored): name keys, optional.
  `Guild:SetGuildCouncil(members, phase, targets)` with `targets = { de = key | false, bank = key | false }` (nil keeps
  the current value). A malformed name drops the message, like a malformed list. `same` (a CG of the stored rev)
  compares the targets too.
- Raid council (`CR`, `db.council.myRaidList`, in-memory `raidCouncil`) gains the same fields;
  `Guild:SetMyRaidList(members, targets)`.
- `Guild:GetLootTarget(kind)` → key, source: the current raid leader's pick while I am in their raid, else the guild
  pick, else (demo mode) a stand-in from the demo raid. The CONFIG_UPDATED signature includes both targets.
- Compatibility: 0.5 clients ignore the new fields and relay CG without them, so a client that first learns a list
  rev from a 0.5 relay has no targets until the GM saves again (or its 7-day CQ). Everyone should update.
- UI: Council → Loot Council, in both sections: "Disenchanter" / "Guild bank" pickers (None, raid members, online /
  all guild members) that are part of the draft (Save & share). Read-only view: one line with both names.
- Drop panel: **DE** and **Bank** buttons on an item that has no winner yet (normal mode, and roll mode when nobody
  is suggested). One click →
  - item with a roll session → `Roll:Award(id, target, "de"|"bank")` (the master-loot give / confirm popups);
  - else, as master looter with the item in the loot window → `DISASTERZONE_GIVE_TARGET` "Give [item] to Name
    (Disenchant)?" → `Loot:GiveItem` → on success `Ledger:Award(..., reason)`; on failure offer "award anyway";
  - else → `DropPanel:Award(..., reason)` (recorded, council).
  Disabled with a tooltip when no target is set or the target is not in the group.

## 42. Council votes

- Session field `votes = { [voterKey] = candidateKey }`. One vote per council member; it can be moved or withdrawn
  (voting for the same candidate again) while the session is open or closed; not after the award.
- `Roll:CanVote(id)`, `Roll:Vote(id, key)`, `Roll:GetMyVote(id)`, demo `Roll:OnDemoVote(voter, id, key)`.
- Message `RV {id, k}` on the group channel (alert class); `k = ""` withdraws. Gate: group distribution, not demo,
  session known and not demo, sender is real council (`IsCouncil(sender, true)`, which covers raid council members),
  candidate in my group, ≤ 40 voters. Votes are not re-sent to late joiners (sessions are memory-only anyway).
- `GetResults` rows gain `votes` (count), `voters` (sorted keys), `myVote`, `suggestedBy` ("votes" | "roll").
  Rows are added for voted candidates in the group. Only voters who are council right now count (demo: all).
- Sorting: voted candidates (in the group, not passed) first by votes desc, then tier, then a valid roll before none,
  then the higher roll; everybody else as before.
- Suggestion: if any such vote exists, the first row is suggested (`suggestedBy = "votes"`); rows equal in votes,
  tier and valid roll are marked `tie`. Votes override the roll rules (lock-changed / can't use / won a copy): the
  council chose knowingly. Without votes the roll suggestion is unchanged.
- The winner's vote count goes into the ledger note (`"roll 54; 2 votes"`) and the announce line.
- UI (drop panel roll mode, council / anyone who may vote): each row shows its vote count; my vote is marked; the
  row tooltip lists the voters; the row menu gets "Vote for X" / "Remove my vote". The Award button tooltip says why
  the player is suggested.
- Demo: two fake officers vote a few seconds into a demo roll (the silent BiS wanter and a roller).
- Privacy: votes travel on the raid channel like rolls (README "How it syncs").
