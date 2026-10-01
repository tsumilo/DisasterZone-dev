# In-game updates ("hot patch")

Members install CDLoot once from a zip. After that, code changes reach them in game: the publisher signs an update,
it travels over the guild addon channel, and each member's client stores it and runs it from the next `/reload` or login.
Art, the TOC header, the libraries and the boot loader cannot travel; they need a new zip.

Built 2026-10-01 on branch `hotpatch` (the state before it is the tag `pre-hotpatch`).

## Everyday use (publisher)

Run from `C:\Users\emilo\CDLoot-dev\dev`:

| Step | Command |
|---|---|
| Once: create the signing key | `luaenv\Scripts\python.exe tools\release.py keygen` |
| A full release (zip + new base for updates) | bump `## Version` in the TOC, then `luaenv\Scripts\python.exe tools\release.py full` |
| An in-game update | bump `## Version`, then `luaenv\Scripts\python.exe tools\release.py patch`; in game `/reload`, `/cdl publish` |
| Take an update back | `luaenv\Scripts\python.exe tools\release.py patch --revoke`; in game `/reload`, `/cdl publish` |
| What changed since the base, key usage | `luaenv\Scripts\python.exe tools\release.py status` |
| Prove the addon behaves the same from the update path | `luaenv\Scripts\python.exe tools\patched_run.py` |

- `full` writes `dist\CDLoot-<version>.zip`. That zip, not the live folder, is what members install: its
  `Core\BuildInfo.lua` carries the build id updates are matched against. The live folder stays build `dev`.
- `patch` refuses a change that cannot travel and says why. Updates are cumulative: each one carries every file that
  differs from the base release, so members only ever need the newest.
- The signing key is `dev\keys\patch_key.json` (git-ignored). **Back it up.** Without it no update can be signed; a
  new key only reaches members through a full release. It signs 1023 updates.

### Art and the art pack number
`Core\BuildInfo.lua` has `assetPack`. When art changes, raise it by one and wrap the code that needs the new art in
`if ns:HasAssets(n) then ... end`. `patch` then accepts the update: every member gets the code, and the members who
have not downloaded the new zip simply do not see that content (they get a "new art" line at login). `patch`
refuses changed art while `assetPack` is unchanged, and reminds you when no changed file calls `ns:HasAssets(n)`.

## Member commands

| Command | Effect |
|---|---|
| `/cdl update` | version, what is stored, download progress |
| `/cdlpatch` | loader status (works even when the rest of the addon did not load) |
| `/cdlpatch off` / `on` | kill switch: no downloads, nothing applied, no serving |
| `/cdlpatch rollback` | mark the running update bad; after a reload the installed version runs |
| `/cdlpatch retry` | forget the bad marks |
| `/cdlpatch try` | development copy only: run the stored update once on the next reload |

## How it works

**Loader (`Core\Boot.lua`, first file in the TOC).** `## LoadSavedVariablesFirst: 1` makes the saved variable
`CDLootPatchDB` readable before the files run. Every patchable file starts with
`if CDLootBoot and CDLootBoot.Run("<path>", ...) then return end`. When a stored update applies, `Run` executes the
stored text of that file (via `loadstring`, same chunk name, so BugSack lines match the new source) and the disk copy
returns at once. New files run in the slot the manifest names; `Core\BootEnd.lua` (last file) runs the ones that go
after everything. An update applies only when its base build id equals `CDLootBuild.id`.

**Stored record.** `CDLootPatchDB.active = { seq, version, base, pack, files = {path = text}, sums = {path = adler32},
list = {{k = F|N|D, p = path, b = slot}}, z0 = signature+manifest (encoded), z = {encoded file texts} }`.
`files`/`sums`/`list` are what the loader reads; `z0`/`z` are what the client serves to others. `seq` (top level) is
the highest sequence number ever verified; `bad[seq]` marks updates that must not run; `partial` holds an unfinished
download; `off` is the kill switch.

**Signature.** W-OTS (w = 16, 67 chains) under a Merkle tree of 1024 one-time keys, all SHA-256. The manifest lists,
per file, length, Adler-32 and the SHA-256 of the file's encoded text; a file is inflated only after that hash
matched. The public key is `Core\PatchKey.lua`. `tools\patchlib.py` is the signing side; `Core\Patch.lua` verifies.
One leaf signs one manifest: the leaf number is the sequence number, taken as the larger of the key file's counter
and the release log's last number + 1, and written back before the signature is used.

**Transfer (`Core\Patch.lua`).** GUILD only, plain text. Control messages on `CDLp1`, chunks on `CDLp2..4`.

| Message | Meaning |
|---|---|
| `A:seq:build:n0` | "I hold update seq for build" (seq 0 = none). At login, every 30 min, after a download, and as a delayed, suppressed answer to someone who is behind. `n0` is informational. |
| `W:seq:0:ranges` | send me these chunks of the signature + manifest |
| `W:seq:i:ranges`, `W:seq:m:ranges`, `W:seq:all` | chunks of file i; whole files by number; every file |
| `...!Name,Name` | suffix on a request: "not from these" (their data failed my checks) |
| `C:seq:item:idx:data` | one chunk: 236 encoded bytes, the last one shorter |

- **One stream.** A holder answers a request after a random delay (publisher 0.1-0.4 s, others 0.5-3 s, in an instance
  3-5.5 s) unless it hears another holder's chunks first. All downloaders listen to the same stream. If two start at
  once, the one with the higher name stops.
- **Manifest first.** Manifest chunks jump the queue, and a downloader asks for the manifest even while files are
  streaming. The manifest ends with its first chunk shorter than 236 bytes (an empty one if its length divides
  evenly), so nobody's claimed length is trusted.
- **Joining mid-stream.** A client that overhears chunks or requests for an update it does not know announces itself
  at once instead of after the login delay. File chunks heard before the manifest arrived are kept (bounded by the
  size an update may have) and sorted in afterwards; only what went by earlier is asked for again.
- **Fewer requests.** A downloader skips its request when somebody else sent the identical one in the last 6 s.
- **Pacing.** Chunks go at BULK priority through ChatThrottleLib within the server's allowance per prefix (10 burst,
  then 1/s): about 2.7 chunks/s, 640 bytes/s. Chunks never use the control prefix, otherwise the server's own
  announcements would be stuck behind its stream (and ChatThrottleLib would halve the stream). Nothing is served
  in combat or during an encounter.
- **Bad data.** A chunk that contradicts the signed manifest (wrong length or index) is a strike against its sender;
  three strikes, or being the only contributor to a slot that fails verification, and the sender is ignored for the
  session and named in later requests. A named holder stays silent for that request and verifies its own stored
  copy once; a damaged copy is no longer served and is fetched afresh after the next login.
- **CPU.** Verification runs in a coroutine in 8 ms slices, never in combat.

Measured in the simulator (25 members online, 43 KB update of 182 chunks): everybody had it 68 s after publishing
with the chunks sent once. With 4 more logging in during the stream and 4 after the publisher left: 119 s for the
first 29, 674 chunk messages in total for 33 members.

## Edge cases and where they are tested

Suites: `tests\patch\test_patch_boot.py` (B), `test_patch_net.py` (N), `test_release_tool.py` (T),
`test_patch_scale.py` (S).

| Case | Handling | Test |
|---|---|---|
| Client ignores `LoadSavedVariablesFirst` | nothing applies, nothing is downloaded, status says so | B client_that_ignores_the_directive, N other_build_... |
| Stored text altered / truncated | per-file Adler-32 before anything runs; whole update rejected, disk runs | B damaged_text_is_rejected |
| Malformed stored record | ignored, dropped at login | B malformed_store_is_ignored |
| Syntax error in a patched file | every file is compiled first; whole update rejected | B syntax_error_rejects_the_whole_patch |
| Error while a patched (or new) file loads | safe mode: nothing else loads, saved data untouched, update marked bad, Reload dialog | B load_error_enters_safe_mode, load_error_in_a_new_file_... |
| Errors in OnInit / OnLogin under an update | counted, rollback dialog | B startup_errors_offer_a_rollback |
| Update breaks something later | `/cdlpatch rollback`, `/cdlpatch off`, or a published revoke | B slash_rollback_and_retry, kill_switch; N revoke_... |
| Member installs another release | build id differs: update ignored, then dropped | B patch_for_another_build_..., T command_line_end_to_end |
| Development copy | never applies (build `dev`), still serves; `/cdlpatch try` | B development_copy_never_applies_unless_asked |
| New and deleted files, load order | manifest slots, end marker | B new_and_deleted_files |
| Update replaces Init.lua or the update code itself | works (they are guarded files) | B patching_init_and_the_patch_code_itself |
| Whole addon from stored text | identical behaviour | B every_file_from_the_patch, `tools\patched_run.py` |
| Loader taken out of the TOC (revert) | addon runs as before, no traffic, store untouched | B without_the_loader_the_addon_runs_as_before |
| Guards removed (revert) | exact inverse of adding them; addon runs from disk | B guards_cover_every_patchable_file |
| Art the member lacks | `ns:HasAssets(n)` false, login notice | B asset_pack_notice, T art_needs_a_raised_art_pack |
| Change that cannot travel | tool refuses (TOC header, libs, boot files, TOC order, unguarded file, art without pack) | T what_cannot_travel_is_refused |
| Forged update (no key) | signature fails, nothing stored, floor unchanged | N forged_manifest_is_rejected |
| Genuine manifest, altered file on a holder | chunks contradict the manifest: strikes, holder named, it self-checks and stops serving, re-fetches after a relog | N tampered_file_with_a_genuine_manifest_is_rejected |
| Garbage chunks racing the real ones | slot fails, bad sender ignored (single contributor) or slot refilled from one sender at a time | N garbage_chunks_from_a_member_are_survived |
| False "end of manifest", chunk beyond the end | manifest slot starts over, culprit found by the same rule | N a_false_end_of_the_manifest_is_survived |
| Manifest length a multiple of the chunk size | empty end-marker chunk | N manifest_length_a_multiple_of_the_chunk_size |
| Chunks heard before the manifest | kept within the size limits, checked like any other | N early_chunks_are_bounded_and_checked, joining_mid_stream_keeps_what_it_overhears |
| Server must answer newcomers while streaming | control prefix carries no chunks | N the_servers_own_announcements_get_through_during_a_stream |
| Guild-sized transfer, latecomers, publisher leaves | one stream, bounded traffic | S guild_sized_transfer |
| Everybody up to date | one line each at login, one per half hour | S everybody_already_up_to_date_is_quiet |
| Whole mechanism in the real client, alone | `release.py selftest` + `/cdlpatch try` | T selftest_runs_the_whole_addon_from_the_store_on_the_development_copy |
| Replay of an older signed update | sequence floor | N replay_of_an_older_signed_update_is_ignored |
| Fake / malformed announcements | bounded parsing; a number nobody serves is given up, the real one continues | N fake_announcements_do_not_block_real_updates |
| Request floods, malformed requests | 6 requests / 10 s per sender, bounded parsing | N request_flood_is_rate_limited |
| Lost messages | downloader re-asks for the missing ranges after 4 s of silence, backing off | N lossy_duplicated_reordered_channel |
| Logout mid-download | finished files and the manifest are stored; the rest resumes | N logout_mid_download_resumes |
| Newer update during a download | the older download is dropped | N newer_update_overtakes_a_download |
| Publisher offline | any holder serves | N late_login_is_served_by_a_member |
| Many downloaders | one stream, one server | N many_downloaders_one_stream |
| Server enters combat / an encounter | stops; another holder takes over | N serving_stops_in_combat_... |
| Popup timing | not in combat, not during an encounter, once per session | N encounter_pauses_serving_and_delays_the_popup |
| Other build, other key, kill switch, no guild | no download / no traffic | N other_build_other_key_..., no_guild_no_traffic |
| Signing counter lost or restored from backup | key counter and release log both push the number up | T a_lost_counter_cannot_reuse_a_signature |
| Key used up | tool refuses | T command_line_end_to_end |

Primitives are checked against Python: SHA-256 (`hashlib`), Adler-32 (`zlib`), the printable encoding (LibDeflate),
signatures (accept, and reject on any flipped bit, wrong key, wrong leaf, truncation).

## Not verifiable offline (check in game)

**Check 1, alone, on the development copy** (`release.py selftest` builds an update that carries every file and is
addressed to no real build, so no member picks it up):

| Step | Expect |
|---|---|
| `luaenv\Scripts\python.exe tools\release.py selftest` | "self-test update #n: 89 files ..." |
| `/reload`, then `/reload` once more, then `/cdlpatch` | "saved variables before files: **yes**" (the first reload after installing says "not known yet") |
| `/cdl publish` | after a few seconds "published update 0.x.y-selftest". Note how long it takes and whether the game stutters: this hashes and inflates the whole addon. |
| `/cdlpatch try`, `/reload` | chat: "running 0.x.y-selftest (in-game update ...)"; `/cdlpatch` says "running an in-game update: ... (89 file(s))" |
| use the addon normally for a while | everything works as before; BugSack stays empty |
| `/reload` | back on the files on disk (`/cdlpatch` says the stored update "is for another build and is ignored") |

What each failure means: "saved variables before files: no" = the client ignores `LoadSavedVariablesFirst` (the
fallback is a second, tiny addon folder that only holds the saved update). "checksum mismatch in <file>" after the
`try` reload = the client's SavedVariables writer did not store that file's text byte for byte. A safe-mode dialog =
a file fails when run through `loadstring`; the BugSack error names it.

**Check 2, with one guild member** who installed the zip from `release.py full`: make a small visible change, bump
the version, `release.py patch`, `/reload`, `/cdl publish`. The member should see the popup within a minute or two,
and `/cdl update` shows progress meanwhile. Things to watch: real transfer speed; council traffic (rolls, drop
alerts) staying instant while an update travels; "action blocked" messages (taint); a stutter when a large file is
unpacked.

## Turning it off / reverting

- **A member:** `/cdlpatch off`.
- **Everyone, without a release:** publish a revoke.
- **In the code, keeping the files:** remove `Core\BuildInfo.lua`, `Core\Boot.lua`, `Core\Outbox.lua`,
  `Core\BootEnd.lua` and the `LoadSavedVariablesFirst` line from the TOC. Every guard is `if CDLootBoot and ...`, so
  without the loader the addon runs exactly as before. `Core\Patch.lua` and `UI\PatchUI.lua` then do nothing
  (remove them from the TOC too).
- **Remove the guards:** `luaenv\Scripts\python.exe tools\release.py guards remove` (exact inverse of `guards add`).
- **Everything:** `git checkout main` in `C:\Users\emilo\CDLoot-dev` (or `git reset --hard pre-hotpatch` on the
  branch). Existing files changed by the feature: the guard on line 1 of 86 files, `Core\Init.lua`, the TOC,
  `UI\Settings.lua` (version label), `Data\Changelog.lua`.
