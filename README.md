# CDLoot dev kit

Development repository for **CDLoot**, the loot-council addon for <Casual Disaster> on WoW TBC Anniversary (Interface 20506).
It tracks the addon source together with everything needed to change it safely: the specs, an offline WoW-client mock, 34 test suites and the data generators.

The guild-facing documentation is in `addon/CDLoot/README.md`.

## Layout

```
CDLoot-dev/
  addon/CDLoot/   -> JUNCTION to C:\World of Warcraft\_anniversary_\Interface\AddOns\CDLoot  (the live addon)
  dev/
    docs/         SPEC.md + SPEC_ADDENDUM_A..F.md (design), research/ (api.md = verified 2.5.6 API notes),
                  impl/ (per-phase implementation, fix and review reports)
    tools/        check.py (static checker), harness.py + wowmock/ (Lua 5.1 mock WoW client), README.md
    tests/        34 scenario suites: tests/<area>/test_*.py
    tf_e/         run_all.py (runs every suite in parallel; output goes to tf_e/<name>/, git-ignored)
    generators/   gen_cdloot_data.py (raids), gen_cdloot_dungeons.py, gen_cdloot_sources.py
                  (crafted/rep/badges/PvP), gen_itemclasses.py (class-restricted items), reports, validators
    find_multiret.py   scans for tonumber(<multi-return call>) hazards
    requirements.txt   lupa==2.8 (real Lua 5.1 inside Python)
```

### The addon junction
`addon/CDLoot` is a Windows directory junction pointing at the real addon folder in the game directory. That gives one set of files:
- the game loads it;
- the tools and tests read it;
- git tracks it here.

No `.git` or dev files end up in the AddOns folder you share with the guild.

**Warning:** delete the junction with `rmdir addon\CDLoot` (cmd) only. Never use a recursive delete (Explorer "delete", `rm -rf`, `Remove-Item -Recurse`): those can follow the junction and **delete the real addon**.

If the junction is ever missing, recreate it (PowerShell):
```
New-Item -ItemType Junction -Path C:\Users\emilo\CDLoot-dev\addon\CDLoot -Target "C:\World of Warcraft\_anniversary_\Interface\AddOns\CDLoot"
```

## Setup (once, or after deleting `dev\luaenv`)
Run from `C:\Users\emilo\CDLoot-dev\dev`:
```
python -m venv luaenv
luaenv\Scripts\python.exe -m pip install -r requirements.txt
```

## Everyday commands
Run everything from `C:\Users\emilo\CDLoot-dev\dev`:

| What | Command |
|---|---|
| Static check (syntax, stray globals, unknown APIs) | `luaenv\Scripts\python.exe tools\check.py` |
| All test suites | `luaenv\Scripts\python.exe tf_e\run_all.py` |
| One suite | `luaenv\Scripts\python.exe tests\loot-roll\test_rolls.py` (add `-k name` to run cases matching `name`) |
| Harness self-test | `luaenv\Scripts\python.exe tools\test_harness_selftest.py` |
| Multi-return hazard scan | `luaenv\Scripts\python.exe find_multiret.py` |
| Regenerate the dungeon or sources data | `luaenv\Scripts\python.exe generators\gen_cdloot_dungeons.py` / `gen_cdloot_sources.py` (they write into `addon\CDLoot\Data\`) |

`tools\README.md` documents the mock client (World / Client, the guild and raid simulation, loot, `/roll`, relog). Use it to write new scenarios.

## Making a change
1. Edit the addon under `addon\CDLoot\`. This is the same folder as the game's AddOns folder.
2. Run `tools\check.py` and `tf_e\run_all.py`, and add a test for any bug you fix.
3. Test it in game with `/reload`. Paste any BugSack error into the next Claude session.
4. Bump `## Version` in `CDLoot.toc` when you ship to the guild.
5. Commit here: `git add -A && git commit -m "..."`.

**Mock fidelity lesson.** The only bug that reached the game so far was a mock/real API mismatch: `GetInventoryItemID` returns 2 values in the real client, and the mock returned 1. Whenever the real client disagrees with the mock, fix the mock first, then the addon.

## Sharing the addon
Zip `C:\World of Warcraft\_anniversary_\Interface\AddOns\CDLoot` and send that zip. It holds only the addon.

Read `addon\CDLoot\NOTICE.md` before sharing outside the guild. The data files are generated from GPL v2 AtlasLoot data.
