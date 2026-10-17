# Tests in WSL (fork per case)

`tf_e\run_all.py` runs most suites inside the WSL distro **Ubuntu-26.04**, because Linux can `fork`:
`tools\forkrun.py` builds a set-up that several cases share once (`r = setup()`: seven clients booting, a sync)
and forks a process per case from there. Each case still starts from its own clean copy, so cases cannot leak
into each other (in the old one-process runner, they could). A suite with many cases on one set-up runs 2-4x
faster (votes: 30 s -> 7 s alone); one whose time is in its cases gains little, so a whole run at 8 workers is
~20% faster (46 suites: 113 s -> 93 s, measured 2026-10-12).

Windows stays the fallback and the reference:

| What | How |
|---|---|
| Everything on Windows, as before | `tf_e\run_all.py --windows` (or `set DZ_WSL=0`) |
| Suites that always run on Windows | `WINDOWS_ONLY` in `tf_e\run_all.py`: `patch/` (whole addon trees staged over 9P are slow), `launcher/`, `scale/` (60 clients a shard need ~3.4 GB in Linux) |
| One suite in WSL by hand | `wsl -d Ubuntu-26.04 -e bash /mnt/c/Users/emilo/CDLoot-dev/dev/tools/wsl/run.sh tests/votes/test_votes.py -k name` |
| One suite in WSL without forking | `wsl -d Ubuntu-26.04 -e env DZ_FORK=0 bash /mnt/c/Users/emilo/CDLoot-dev/dev/tools/wsl/run.sh tests/votes/test_votes.py` |
| One suite on Windows | `luaenv\Scripts\python.exe tests\votes\test_votes.py` (forkrun runs the cases one after another there) |

## Set-up (once per machine)

```
wsl --install -d Ubuntu-26.04 --no-launch
wsl -d Ubuntu-26.04 -u root -e bash /mnt/c/Users/emilo/CDLoot-dev/dev/tools/wsl/setup.sh
```

`setup.sh` makes root the distro's default user, installs `python3-venv` and creates `/opt/dzenv` with
`dev\requirements.txt` (lupa 2.8) plus numpy, pillow, shapely. Run it again after changing the requirements.
`run_all.py` uses WSL only when `/opt/dzenv/bin/python` exists there.

## How a case is split (tools/forkrun.py)

The runner reads each case's source. Its leading simple statements (assignments and calls, up to the first `if`,
`for`, `with`, `assert`, `def` ...) are its set-up. Cases whose set-up is the same code form a group, which shares
the longest run of statements they all start with. One process runs that once, then forks per case, and each case
continues with the names the set-up bound. A case is run whole instead (in a fresh fork) when it closes over outer
names, takes arguments, declares `global`/`nonlocal`, reads a local before its set-up binds it, has a lambda in its
set-up, or shares its set-up with no other case. When a group's set-up raises, its cases run whole, so the error
shows in each of them.

Writing tests: put the shared world-building first (`r = setup()`, `w, c = solo()`), and keep per-case tweaks after
it. Two cases that start with the same statement share that work.

## One server per run, pre-loaded clients (2026-10-17)

`run_all` starts one `tools/testserver.py` in WSL per run and sends it every suite that runs there (stdin: one job per
line, stdout: one exit code per job; its log is `tf_e/<out>/_testserver.log`). The server imports the harness once,
reads the addon's bytecode, and pre-loads 16 clients (`harness.build_templates`, `DZ_TEMPLATES=n` to change the
number, `0` = none): for each client number (`Client.index`, which fixes a client's `GetTime` offset) a runtime in
which the addon's ~390 files already ran. Then it forks a process per suite; forkrun forks per case from there.

A client's boot used to run all those files (~130 ms of ~140). `Client.load_addon` now takes over the pre-loaded
runtime of its number instead (~10 ms) when nothing would come out differently (`Client._template_mismatch`):

- the files ran with nothing saved, at the template's time, as a default client of a default world: so the client
  has no saved variables, boots at that same moment (at `world.now == 0`, its first login), uses the default addon
  folder and options, and nothing touched its runtime before `load_addon` (`c.M`, `c.eval`, a `preload_lua`, a
  tick, a world that stores data with the saved variables like `seed_guild_council`);
- what the files read while the template loaded is recorded and checked: the player (only at a line listed in
  `harness.TEMPLATE_NAME_CHECKS`: today Core/Perf.lua's developer-name test), saved variables, the clock, items;
  a new file-time read of the player makes every client load its files itself until it is listed (or removed);
- the files must be the ones it ran (times and sizes as this process sees them), and the suite must not have
  replaced how the harness loads files (`harness._loading_hooks`).

Anything else boots as before. `DZ_TEMPLATE_LOG=<file>` logs every decision (`taken` or why not). With
`DZ_TEMPLATES=n` a suite run by hand builds its own before forking (slower than the server's, same results).
`DZ_SERVER=0` makes `run_all` start a `wsl.exe` per suite as before. If the server dies, the suites it had not
finished run that way too.

Worktrees made on Windows (`C:\Users\emilo\DZ-wt\...`) can run in WSL since `run.sh` points git at their git folder
(`GIT_DIR`/`GIT_WORK_TREE`): `dz.sh` sends their suites there when their `run.sh` has that.

## What differs from Windows

- The addon folder is reached through `/mnt/c` (9P, slow per file): the harness checks a file's time once per process
  (forgetting it when the process writes the file) and keeps its bytecode in `/var/cache/dz-bc`, by path, time and
  size. `run.sh` prunes entries unused for two weeks.
- Each case's process writes its own dependency record part (`tools/testmap_rec.py`), and `run_all` merges them.
  A suite forked from the server also carries what the server read (the harness, the files the pre-loaded clients
  ran, the functions they called while loading).
- Python is the distro's (3.14); Windows has 3.13.
