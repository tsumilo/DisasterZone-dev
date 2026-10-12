"""Moves addon files to new paths in one go (architecture run P4: dev/docs/arch/MOVES.json) and fixes everything that
names them. Idempotent: run it again on a tree that already has the moves (a newer mainline after a merge) and it
only fixes what is still old.

    python tools/move.py MAPPING.json [--dry-run] [--root REPO] [--no-git]

MAPPING.json: a list (or {"moves": [...]}) of {"from": "UI/RaidPlanUI.lua", "to": "UI/Raids/RaidPlanUI.lua"} with
paths relative to the addon folder (either slash). Optional per entry: "after": "<path>" puts the file's TOC line
right after that file's line (old or new path) instead of keeping its place.

What it does, in order (--dry-run prints all of it and changes nothing):
  1. refuses the whole mapping when an entry names Core/BuildInfo.lua, Core/Boot.lua, Core/Outbox.lua or
     Core/BootEnd.lua (they never move: the first two and last two TOC files), anything under Libs/, a
     DisasterZone_Rooms path or room data, a path outside the addon, a duplicate, or a target that already exists
     next to its source; a source that is gone while its target exists counts as already moved;
  2. `git mv` (or a plain rename with --no-git) of each file, creating folders;
  3. DisasterZone.toc: each moved path replaced on its own line (order kept, the line's slash style kept), or moved
     after its "after" anchor; the first two and last two files are checked to be unchanged;
  4. the line-1 guards: tools/release.py `guards add` (the guard names the file's new path; the comment after it on
     line 1 too when it named the old one), then `guards check` must pass;
  5. path literals in dev/tests, dev/tools, dev/generators, dev/tf_e and dev/docs: an exact quoted path ("UI/X.lua",
     'UI\\X.lua', `UI/X.lua` in Markdown; both slash styles, escaped or not) becomes the new path. Every rewrite is
     listed. Files with the line "move.py: keep paths" are left alone (self-tests with made-up trees), as is the
     mapping file itself. Paths built from pieces (os.path.join(ADDON, "Core", "X.lua")), longer strings that only
     contain a path, and path literals in the addon's own Lua are listed as "check by hand", not changed;
  6. dev/.testmap/moves.json ({old: new}, chains collapsed): tools/testmap.py maps test records made before the move
     to the new paths, so a pure move reruns nothing. (It is not committed: run move.py once more in a checkout that
     got the move by a merge; that only writes this file.)

Options: --root REPO (default: this dev kit's repo) with --addon DIR, --dev DIR, --map-dir DIR to point the parts
elsewhere (tools/test_move.py works on a temporary copy).
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEV = os.path.dirname(HERE)
REPO = os.path.dirname(DEV)
sys.path.insert(0, HERE)
import release  # noqa: E402

ADDON_NAME = release.ADDON_NAME
NEVER_MOVE = ("Core/BuildInfo.lua", "Core/Boot.lua", "Core/Outbox.lua", "Core/BootEnd.lua")
REWRITE_DIRS = ("tests", "tools", "generators", "tf_e", "docs")
SKIP_DIRS = {"__pycache__", "luaenv", ".testmap", ".luacache", "node_modules", ".git", ".slots"}
TEXT_EXT = {".py": "\"'", ".lua": "\"'", ".json": "\"", ".sh": "\"'", ".toml": "\"'", ".txt": "\"'`",
            ".md": "\"'`"}
KEEP_MARK = b"move.py: keep paths"
MAX_BYTES = 8 * 1024 * 1024


class MoveError(Exception):
    pass


def norm(p):
    return (p or "").strip().replace("\\", "/")


def load_mapping(path):
    with open(path, encoding="utf-8") as fh:
        raw = json.load(fh)
    entries = raw.get("moves", []) if isinstance(raw, dict) else raw
    out = []
    for e in entries:
        if not isinstance(e, dict) or "from" not in e or "to" not in e:
            raise MoveError("mapping entries are {\"from\": ..., \"to\": ...}: %r" % (e,))
        out.append({"from": norm(e["from"]), "to": norm(e["to"]), "after": norm(e.get("after")) or None})
    return out


def refusals(entries):
    """Why the mapping cannot be applied (list of texts; empty: fine)."""
    bad, seen_from, seen_to = [], {}, {}
    for e in entries:
        for side in ("from", "to"):
            p = e[side]
            if not p or p.startswith("/") or re.match(r"^[A-Za-z]:", p) or ".." in p.split("/"):
                bad.append("%s %r: must be a path inside the addon folder" % (side, p))
            elif p in NEVER_MOVE:
                bad.append("%s %s: the boot files (first two and last two in the TOC) never move" % (side, p))
            elif p.startswith("Libs/"):
                bad.append("%s %s: Libs/ is not moved" % (side, p))
            elif p.startswith(release.ROOMS_NAME + "/") or release.ROOMS_NAME in p.split("/") \
                    or release.is_room_data(p):
                bad.append("%s %s: DisasterZone_Rooms / room data is not moved" % (side, p))
        if e["from"] == e["to"]:
            bad.append("%s: from and to are the same" % e["from"])
        if e["from"] in seen_from:
            bad.append("%s: listed twice" % e["from"])
        if e["to"].lower() in seen_to:
            bad.append("%s: two files moved there" % e["to"])
        if e["after"] in ("Core/BuildInfo.lua", "Core/Outbox.lua", "Core/BootEnd.lua"):
            bad.append("%s: cannot go after %s" % (e["from"], e["after"]))
        seen_from[e["from"]] = 1
        seen_to[e["to"].lower()] = 1
    return bad


class Mover(object):
    def __init__(self, mapping_path, root=REPO, addon=None, dev=None, map_dir=None, dry=False, use_git=True, log=print):
        self.mapping_path = os.path.abspath(mapping_path)
        self.root = os.path.abspath(root)
        self.addon = os.path.abspath(addon or os.path.join(self.root, "addon", ADDON_NAME))
        self.dev = os.path.abspath(dev or os.path.join(self.root, "dev"))
        self.map_dir = os.path.abspath(map_dir or os.path.join(self.dev, ".testmap"))
        self.dry, self.use_git, self.log = dry, use_git, log
        self.entries = load_mapping(mapping_path)
        self.changes = []      # (kind, text) of everything done (or that would be done)
        self.warnings = []

    def note(self, kind, text):
        self.changes.append((kind, text))
        self.log("%s%s: %s" % ("(dry run) " if self.dry else "", kind, text))

    def warn(self, text):
        self.warnings.append(text)
        self.log("check by hand: " + text)

    # 1 + 2 ------------------------------------------------------------------------------------------------------------
    def plan(self):
        bad = refusals(self.entries)
        todo = []
        for e in self.entries:
            src, dst = os.path.join(self.addon, e["from"]), os.path.join(self.addon, e["to"])
            s, d = os.path.exists(src), os.path.exists(dst)
            same = s and d and os.path.normcase(os.path.abspath(src)) == os.path.normcase(os.path.abspath(dst))
            if s and d and not same:
                bad.append("%s -> %s: both exist" % (e["from"], e["to"]))
            elif not s and not d:
                bad.append("%s -> %s: neither exists" % (e["from"], e["to"]))
            elif s:
                todo.append(e)
        if bad:
            raise MoveError("refused:\n  " + "\n  ".join(bad))
        return todo

    def move_files(self, todo):
        for e in todo:
            src, dst = os.path.join(self.addon, e["from"]), os.path.join(self.addon, e["to"])
            self.note("move", "%s -> %s" % (e["from"], e["to"]))
            if self.dry:
                continue
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            if self.use_git:
                r = subprocess.run(["git", "-C", self.addon, "mv", "--", src, dst], capture_output=True, text=True)
                if r.returncode != 0:
                    raise MoveError("git mv %s: %s" % (e["from"], (r.stderr or r.stdout).strip()))
            else:
                shutil.move(src, dst)

    # 3 ----------------------------------------------------------------------------------------------------------------
    def rewrite_toc(self):
        path = os.path.join(self.addon, ADDON_NAME + ".toc")
        with open(path, "rb") as fh:
            raw = fh.read()
        bom = raw[:3] if raw.startswith(b"\xef\xbb\xbf") else b""
        text = raw[len(bom):].decode("utf-8")
        nl = "\r\n" if "\r\n" in text else "\n"
        lines = text.split(nl)
        before = _toc_files(lines)

        def find(p):
            for i, line in enumerate(lines):
                s = line.strip()
                if s and not s.startswith("#") and norm(s) == p:
                    return i
            return None

        for e in self.entries:
            i = find(e["from"])
            if i is not None:
                old = lines[i]
                style = "\\" if "\\" in old else "/"
                lines[i] = old.replace(old.strip(), e["to"].replace("/", style))
                self.note("toc", "%s -> %s (line %d)" % (old.strip(), lines[i].strip(), i + 1))
            elif find(e["to"]) is None:
                self.note("toc", "%s is not in the TOC (moved file only)" % e["from"])
        to_of = {e["from"]: e["to"] for e in self.entries}
        for e in self.entries:
            if not e["after"]:
                continue
            i = find(e["to"])
            anchor = to_of.get(e["after"], e["after"])
            a = find(anchor)
            if i is None or a is None:
                raise MoveError("TOC: cannot put %s after %s (one of them is not in the TOC)" % (e["to"], anchor))
            nxt = a + 1
            while nxt < len(lines) and (not lines[nxt].strip() or lines[nxt].strip().startswith("#")) and nxt != i:
                nxt += 1
            if nxt == i or i == a + 1:
                continue
            line = lines.pop(i)
            if i < a:
                a -= 1
            lines.insert(a + 1, line)
            self.note("toc", "%s placed after %s" % (e["to"], anchor))
        after = _toc_files(lines)
        if after[:2] != before[:2] or after[-2:] != before[-2:] or before[:2] != list(NEVER_MOVE[:2]) \
                or before[-2:] != list(NEVER_MOVE[2:]):
            raise MoveError("TOC: the first two / last two files must stay %s / %s" % (NEVER_MOVE[:2], NEVER_MOVE[2:]))
        new = bom + nl.join(lines).encode("utf-8")
        if new != raw and not self.dry:
            release._put(path, new)

    # 4 ----------------------------------------------------------------------------------------------------------------
    def fix_guards(self):
        moved = {e["to"]: e["from"] for e in self.entries}
        if self.dry:
            for e in self.entries:
                if release.is_patchable(e["to"]):
                    self.note("guard", "%s: names %s" % (e["to"], e["to"]))
            return
        changed, _ = release.guards(self.addon, "add")
        for rel in changed:
            self.note("guard", "%s: names %s" % (rel, rel))
        for new, old in moved.items():
            p = os.path.join(self.addon, new)
            if not os.path.isfile(p) or not p.endswith(".lua"):
                continue
            with open(p, "rb") as fh:
                data = fh.read()
            bom = data[:3] if data.startswith(b"\xef\xbb\xbf") else b""
            body = data[len(bom):]
            m = release.GUARD_RE.match(body)
            if not m:
                continue
            nl = body.find(b"\n")
            end = nl if nl >= 0 else len(body)
            tail = body[m.end():end]          # the comment after the guard on line 1
            for o, n in ((old, new), (old.replace("/", "\\"), new.replace("/", "\\"))):
                if o.encode() in tail:
                    tail2 = tail.replace(o.encode(), n.encode())
                    release._put(p, bom + body[:m.end()] + tail2 + body[end:])
                    self.note("guard", "%s: line-1 comment names %s" % (new, new))
                    break
        _, problems = release.guards(self.addon, "check")
        if problems:
            raise MoveError("guards check:\n  " + "\n  ".join(problems))

    # 5 ----------------------------------------------------------------------------------------------------------------
    def rewrite_literals(self):
        pairs = []
        for e in self.entries:
            f, t = e["from"], e["to"]
            # (old bytes, new bytes): forward slashes, single backslashes, escaped backslashes
            pairs.append((f.encode(), t.encode()))
            if "/" in f:
                pairs.append((f.replace("/", "\\").encode(), t.replace("/", "\\").encode()))
                pairs.append((f.replace("/", "\\\\").encode(), t.replace("/", "\\\\").encode()))
        mapping_real = os.path.normcase(os.path.realpath(self.mapping_path))
        for sub in REWRITE_DIRS:
            top = os.path.join(self.dev, sub)
            for dp, dns, fns in os.walk(top):
                dns[:] = [d for d in dns if d not in SKIP_DIRS and not (sub == "tf_e" and dp == top)]
                for fn in sorted(fns):
                    ext = os.path.splitext(fn)[1].lower()
                    if ext not in TEXT_EXT:
                        continue
                    p = os.path.join(dp, fn)
                    if os.path.normcase(os.path.realpath(p)) == mapping_real:
                        continue
                    try:
                        if os.path.getsize(p) > MAX_BYTES:
                            continue
                        with open(p, "rb") as fh:
                            data = fh.read()
                    except OSError:
                        continue
                    if KEEP_MARK in data:
                        continue
                    self._rewrite_file(p, data, pairs, TEXT_EXT[ext])
        # the addon's own code: listed, never changed here
        for dp, dns, fns in os.walk(self.addon):
            dns[:] = [d for d in dns if d not in SKIP_DIRS and d != "Libs"]
            for fn in fns:
                if not fn.endswith(".lua"):
                    continue
                p = os.path.join(dp, fn)
                with open(p, "rb") as fh:
                    data = fh.read()
                body = data[data.find(b"\n") + 1:] if data.find(b"\n") >= 0 else b""   # (not the guard line)
                for old, _ in pairs:
                    for m in re.finditer(rb"[\"']" + re.escape(old) + rb"[\"']", body):
                        line = body.count(b"\n", 0, m.start()) + 2
                        self.warn("%s:%d: addon code names %s" % (self._rel(p), line, old.decode()))

    def _rel(self, p):
        try:
            r = os.path.relpath(p, self.root)
        except ValueError:
            return p
        return p if r.startswith("..") else r.replace("\\", "/")

    def _rewrite_file(self, p, data, pairs, quotes):
        to_of = dict(pairs)
        alts = b"|".join(re.escape(o) for o in sorted(to_of, key=len, reverse=True))
        pat = re.compile(rb"([" + re.escape(quotes.encode()) + rb"])(" + alts + rb")(?=\1)")
        for m in pat.finditer(data):
            line = data.count(b"\n", 0, m.start()) + 1
            self.note("literal", "%s:%d: %s -> %s" % (self._rel(p), line, m.group(2).decode(),
                                                       to_of[m.group(2)].decode()))
        new = pat.sub(lambda m: m.group(1) + to_of[m.group(2)], data)
        # leftovers: the old path inside a longer string, or built from pieces (new paths masked: an old path can be
        # the tail of a new one)
        masked = new
        for e in self.entries:
            for t in (e["to"], e["to"].replace("/", "\\"), e["to"].replace("/", "\\\\")):
                masked = masked.replace(t.encode(), b"\0" * len(t))
        for e in self.entries:
            f = e["from"]
            parts = f.split("/")
            leftovers = [re.escape(f.encode()), re.escape(f.replace("/", "\\").encode()),
                         re.escape(f.replace("/", "\\\\").encode())]
            if len(parts) > 1:
                leftovers.append(rb"\s*,\s*".join(rb"[\"']" + re.escape(x.encode()) + rb"[\"']" for x in parts))
            for pat in leftovers:
                for m in re.finditer(rb"(?<![A-Za-z0-9_])" + pat + rb"(?![A-Za-z0-9_])", masked):
                    line = masked.count(b"\n", 0, m.start()) + 1
                    self.warn("%s:%d: %s" % (self._rel(p), line, new[m.start():m.end()].decode("utf-8", "replace")))
        if new != data and not self.dry:
            release._put(p, new)

    # 6 ----------------------------------------------------------------------------------------------------------------
    def write_moves(self):
        path = os.path.join(self.map_dir, "moves.json")
        try:
            with open(path, encoding="utf-8") as fh:
                cur = json.load(fh)
        except (OSError, ValueError):
            cur = {}
        cur = {k: v for k, v in cur.items() if isinstance(v, str)}
        for e in self.entries:
            f, t = e["from"], e["to"]
            for k, v in list(cur.items()):
                if v == f:
                    cur[k] = t
            cur[f] = t
        cur = {k: v for k, v in sorted(cur.items()) if k != v}
        self.note("moves.json", "%s: %d path(s)" % (path, len(cur)))
        if not self.dry:
            os.makedirs(self.map_dir, exist_ok=True)
            tmp = path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as fh:
                json.dump(cur, fh, indent=1, sort_keys=True)
            os.replace(tmp, path)

    def run(self):
        todo = self.plan()
        if not todo:
            self.log("every file is in place already: fixing what still names old paths")
        self.move_files(todo)
        self.rewrite_toc()
        self.fix_guards()
        self.rewrite_literals()
        self.write_moves()
        kinds = {}
        for k, _ in self.changes:
            kinds[k] = kinds.get(k, 0) + 1
        self.log("%s%d file(s) moved, %s; %d to check by hand" % (
            "(dry run) " if self.dry else "", sum(1 for k, _ in self.changes if k == "move"),
            ", ".join("%s %d" % kv for kv in sorted(kinds.items()) if kv[0] != "move") or "nothing else",
            len(self.warnings)))
        return self


def _toc_files(lines):
    return [norm(l.strip()) for l in lines if l.strip() and not l.strip().startswith("#")]


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("mapping")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--root", default=REPO)
    ap.add_argument("--addon")
    ap.add_argument("--dev")
    ap.add_argument("--map-dir")
    ap.add_argument("--no-git", action="store_true")
    a = ap.parse_args(argv)
    try:
        Mover(a.mapping, a.root, a.addon, a.dev, a.map_dir, a.dry_run, not a.no_git).run()
    except (MoveError, release.ReleaseError) as e:
        print("move.py: %s" % e, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
