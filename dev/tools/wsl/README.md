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

## What differs from Windows

- The addon folder is reached through `/mnt/c` (9P, slow per file): the harness checks a file's time once per process
  (forgetting it when the process writes the file) and keeps its bytecode in `/var/cache/dz-bc`, by path, time and
  size. `run.sh` prunes entries unused for two weeks.
- Each case's process writes its own dependency record part (`tools/testmap_rec.py`), and `run_all` merges them.
- Python is the distro's (3.14); Windows has 3.13.
