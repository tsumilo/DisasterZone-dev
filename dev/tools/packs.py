"""Game packs (dev/docs/GAME_PACKS.md): each minigame is an addon folder of its own, DisasterZone_<Game>, installed
next to DisasterZone or left out. This file knows them (PACKS), finds them next to an addon folder (find_packs), and
moves the games out of DisasterZone (split).

    python tools/packs.py list [--addon DIR]
    python tools/packs.py split [--dry-run] [--root REPO]

split is idempotent, like tools/move.py: run it again after a merge brought new game files to the old places
(Games/<Game>/, Media/<Game>/) and it moves only those. In a checkout whose addon\\DisasterZone is a junction into the
game (the main dev kit checkout), each addon\\DisasterZone_<Game> must be a junction to an (empty) folder in AddOns
first, or git would write the pack into the dev kit: split refuses until it is.

What split does per pack:
  1. git mv Games/<Game>/** -> DisasterZone_<Game>/** and Media/<Game>/** -> DisasterZone_<Game>/Media/**;
  2. the pack's TOC: its header, Load.lua, the game's lines from DisasterZone.toc (order kept), Done.lua; those
     lines leave DisasterZone.toc;
  3. Load.lua / Done.lua (never patched in game) when missing;
  4. line-1 guards name the file with its folder: DisasterZoneBoot.Run("DisasterZone_Chess/Chess.lua", ...);
  5. art paths in the pack's Lua point into the pack (Interface\\AddOns\\DisasterZone_<Game>\\Media\\...);
  6. exact quoted path literals in dev/tests, tools, generators, tf_e, docs ("Games/<Game>/X.lua" ->
     "DisasterZone_<Game>/X.lua"; paths built from pieces are listed to check by hand), and dev/.testmap/moves.json.
(move.py: keep paths)
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
ADDON_NAME = "DisasterZone"
ROOMS_NAME = "DisasterZone_Rooms"
MAPPING = os.path.join(DEV, "docs", "arch", "PACKS.json")

# id = the game's Games:Register id (Games/Hub.lua CATALOG says the same); game / media = where it lived in DisasterZone
PACKS = [
    {"id": "bingo", "folder": "DisasterZone_Bingo", "game": "Games/Bingo", "media": None,
     "name": "Council Bingo", "tagline": "Squares fill in as the raid happens.",
     "icon": "Interface\\Icons\\INV_Misc_Note_02"},
    {"id": "trainer", "folder": "DisasterZone_Trainer", "game": "Games/Trainer", "media": None,
     "name": "Raid Trainer", "tagline": "Practise each boss in 3D before the pull.",
     "icon": "Interface\\Icons\\Spell_Shadow_DeathPact"},
    {"id": "azeromon", "folder": "DisasterZone_Azeromon", "game": "Games/Azeromon", "media": "Media/Azeromon",
     "name": "Azeromon", "tagline": "Tame and battle the beasts of Elwynn.",
     "icon": "Interface\\Icons\\Ability_Hunter_BeastTaming"},
    {"id": "chess", "folder": "DisasterZone_Chess", "game": "Games/Chess", "media": None,
     "name": "Karazhan Chess", "tagline": "Play Medivh's echo, or a guildmate.",
     "icon": "Interface\\Icons\\INV_Misc_Ogrepinata"},
    {"id": "illidan", "folder": "DisasterZone_Illidan", "game": "Games/Illidan", "media": "Media/Illidan",
     "name": "The Binding of Illidan", "tagline": "Five floors of the Black Temple, new every run.",
     "icon": "Interface\\Icons\\Spell_Shadow_Metamorphosis"},
    {"id": "holdtheline", "folder": "DisasterZone_HoldTheLine", "game": "Games/HoldTheLine", "media": "Media/HoldTheLine",
     "name": "Hold the Line", "tagline": "Fifteen minutes. One class. The whole Scourge.",
     "icon": "Interface\\Icons\\Spell_Holy_InnerFire"},
]
BY_FOLDER = {p["folder"]: p for p in PACKS}

# A pack's first and last files: never part of an in-game update (Core/Boot.lua CheckPack, Core/Init.lua PackLoaded)
PACK_FIRST, PACK_LAST = "Load.lua", "Done.lua"

LOAD_LUA = b"""-- DisasterZone game pack: the first file in the TOC (dev/docs/GAME_PACKS.md). Gives the pack's files the main addon's
-- namespace (what they read and the modules they make are DisasterZone's), then has the boot loader check that this
-- pack belongs to the installed release (Core/Boot.lua CheckPack: a pack from another release is skipped whole).
-- Never part of an in-game update.
local folder, ns = ...
local main = DisasterZone
if type(ns) == "table" and type(main) == "table" and main ~= ns then
    setmetatable(ns, { __index = main, __newindex = main })
end
if DisasterZoneBoot and DisasterZoneBoot.CheckPack then DisasterZoneBoot.CheckPack(folder) end
"""

DONE_LUA = b"""-- DisasterZone game pack: the last file in the TOC (dev/docs/GAME_PACKS.md). Starts the pack's modules: they were
-- made after DisasterZone's own start (Core/Init.lua ns:PackLoaded). Never part of an in-game update.
if DisasterZone and DisasterZone.PackLoaded then DisasterZone:PackLoaded(...) end
"""


class PackError(Exception):
    pass


def read_toc(folder, name):
    """(headers {lowercase key: value}, [files with forward slashes]) of folder/name.toc, or None without one."""
    path = os.path.join(folder, name + ".toc")
    if not os.path.isfile(path):
        return None
    with open(path, "rb") as fh:
        raw = fh.read().decode("utf-8-sig")
    headers, files = {}, []
    for line in raw.splitlines():
        line = line.strip()
        if line.startswith("##"):
            k, _, v = line[2:].partition(":")
            headers[k.strip().lower()] = v.strip()
        elif line and not line.startswith("#"):
            files.append(line.replace("\\", "/"))
    return headers, files


def find_packs(addon_dir):
    """{folder name: path} of the game packs next to an addon folder ("## X-DZ-Pack" in the TOC), by name."""
    parent = os.path.dirname(os.path.normpath(addon_dir))
    out = {}
    try:
        names = sorted(os.listdir(parent))
    except OSError:
        return out
    for name in names:
        if not name.startswith(ADDON_NAME + "_") or name == ROOMS_NAME:
            continue
        folder = os.path.join(parent, name)
        toc = read_toc(folder, name)
        if toc and toc[0].get("x-dz-pack"):
            out[name] = folder
    return out


def pack_toc_head(pack, interface):
    p = pack
    return "\r\n".join([
        "## Interface: %s" % interface,
        "## Title: |cffff8000Disaster|rZone · %s" % p["name"],
        "## Notes: %s" % p["tagline"],
        "## Author: Casual Disaster",
        "## Dependencies: DisasterZone",
        "## X-DZ-Pack: %s" % p["id"],
        "## X-DZ-Kind: game",
        "## X-DZ-Build: dev",
        "## IconTexture: %s" % p["icon"],
        "## Category: Raid",
        "",
        "# A DisasterZone game pack (dev/docs/GAME_PACKS.md). Load.lua must stay first and Done.lua last.",
        PACK_FIRST,
    ]) + "\r\n"


def _is_junction(path):
    return os.path.isjunction(path) or os.path.islink(path)


class Splitter(object):
    def __init__(self, root=REPO, dry=False, log=print):
        self.root = os.path.abspath(root)
        self.addon = os.path.join(self.root, "addon", ADDON_NAME)
        self.dev = os.path.join(self.root, "dev")
        self.dry, self.log = dry, log
        self.entries = []        # {"from": path in DisasterZone, "to": "<Folder>/<path>"} of every file moved

    def note(self, kind, text):
        self.log("%s%s: %s" % ("(dry run) " if self.dry else "", kind, text))

    def git(self, *args):
        r = subprocess.run(["git", "-C", self.root] + list(args), capture_output=True, text=True)
        if r.returncode != 0:
            raise PackError("git %s: %s" % (" ".join(args[:2]), (r.stderr or r.stdout).strip()))
        return r.stdout

    def tracked(self, rel_dir):
        out = self.git("ls-files", "-z", "--", "addon/%s/%s" % (ADDON_NAME, rel_dir))
        pre = "addon/%s/%s/" % (ADDON_NAME, rel_dir)
        return {p[len(pre):] for p in out.split("\0") if p.startswith(pre)}

    def check_places(self):
        """Every pack folder the move needs, or the reason it can't go on (junction checkouts)."""
        bad = []
        junction = _is_junction(self.addon)
        for p in PACKS:
            if not os.path.isdir(os.path.join(self.addon, p["game"])) and not (
                    p["media"] and os.path.isdir(os.path.join(self.addon, p["media"]))):
                continue
            dst = os.path.join(self.root, "addon", p["folder"])
            if junction and not os.path.isdir(dst):
                bad.append("addon\\%s: make it a junction to an empty AddOns\\%s first" % (p["folder"], p["folder"]))
        if bad:
            raise PackError("refused:\n  " + "\n  ".join(bad))

    # 1 ----------------------------------------------------------------------------------------------------------------
    def move(self, p):
        dst_root = os.path.join(self.root, "addon", p["folder"])
        moves = []                                     # (source rel in DisasterZone, target rel in the pack)
        for src_dir, dst_dir in ((p["game"], ""), (p["media"], "Media")):
            if not src_dir:
                continue
            base = os.path.join(self.addon, src_dir)
            if not os.path.isdir(base):
                continue
            tracked = self.tracked(src_dir)
            for dp, dns, fns in os.walk(base):
                for fn in sorted(fns):
                    rel = os.path.relpath(os.path.join(dp, fn), base).replace(os.sep, "/")
                    moves.append((src_dir + "/" + rel, (dst_dir + "/" + rel) if dst_dir else rel, rel in tracked))
        groups = {}
        for src, dst, tracked in moves:
            self.entries.append({"from": src, "to": p["folder"] + "/" + dst})
            groups.setdefault((os.path.dirname(dst), tracked), []).append(src)
        if not moves:
            return 0
        self.note("move", "%s: %d file(s) -> %s" % (p["game"], len(moves), p["folder"]))
        if self.dry:
            return len(moves)
        for (dst_dir, tracked), srcs in sorted(groups.items()):
            target = os.path.join(dst_root, dst_dir) if dst_dir else dst_root
            os.makedirs(target, exist_ok=True)
            if tracked:
                for i in range(0, len(srcs), 200):
                    batch = [os.path.join(self.addon, s) for s in srcs[i:i + 200]]
                    self.git("mv", "--", *(batch + [target]))
            else:
                for s in srcs:
                    shutil.move(os.path.join(self.addon, s), os.path.join(target, os.path.basename(s)))
                    self.note("move", "%s: not tracked by git, moved as a plain file" % s)
        self.prune(p)
        return len(moves)

    def prune(self, p):
        """The emptied folders the game left in DisasterZone (deepest first)."""
        if self.dry:
            return
        for src_dir in (p["game"], p["media"]):
            d = src_dir and os.path.join(self.addon, src_dir)
            if d and os.path.isdir(d):
                for dp, dns, fns in os.walk(d, topdown=False):
                    if not os.listdir(dp):
                        os.rmdir(dp)

    # 2 + 3 ------------------------------------------------------------------------------------------------------------
    def tocs(self, p):
        core_path = os.path.join(self.addon, ADDON_NAME + ".toc")
        with open(core_path, "rb") as fh:
            core = fh.read().decode("utf-8")
        nl = "\r\n" if "\r\n" in core else "\n"
        game = p["game"].replace("/", "\\") + "\\"
        game_fwd = p["game"] + "/"
        keep, mine = [], []
        for line in core.split(nl):
            s = line.strip()
            if s.startswith(game) or s.startswith(game_fwd):
                mine.append(s[len(game):].replace("/", "\\"))
            else:
                keep.append(line)
        interface = (read_toc(self.addon, ADDON_NAME) or ({}, []))[0].get("interface", "20506")
        pack_dir = os.path.join(self.root, "addon", p["folder"])
        pack_toc = os.path.join(pack_dir, p["folder"] + ".toc")
        if os.path.isfile(pack_toc):
            with open(pack_toc, "rb") as fh:
                text = fh.read().decode("utf-8")
            lines = text.split("\r\n")
            listed = {l.strip().replace("/", "\\") for l in lines}
            new = [m for m in mine if m not in listed]
            if new:
                at = max(i for i, l in enumerate(lines) if l.strip() == PACK_LAST)
                lines[at:at] = new
                text = "\r\n".join(lines)
        else:
            new = mine
            text = pack_toc_head(p, interface) + "".join(m + "\r\n" for m in mine) + PACK_LAST + "\r\n"
        if mine:
            self.note("toc", "%s.toc: %d line(s) from DisasterZone.toc" % (p["folder"], len(mine)))
        if self.dry:
            return
        if mine:
            # (no blank pair left where the block was)
            out = nl.join(keep)
            while nl + nl + nl in out:
                out = out.replace(nl + nl + nl, nl + nl)
            self._put(core_path, out.encode("utf-8"))
        if new or not os.path.isfile(pack_toc):
            os.makedirs(pack_dir, exist_ok=True)
            self._put(pack_toc, text.encode("utf-8"))
        for name, body in ((PACK_FIRST, LOAD_LUA), (PACK_LAST, DONE_LUA)):
            path = os.path.join(pack_dir, name)
            if not os.path.isfile(path):
                self._put(path, body.replace(b"\n", b"\r\n"))
                self.note("file", "%s/%s" % (p["folder"], name))

    # 4 + 5 ------------------------------------------------------------------------------------------------------------
    def fix_lua(self, p):
        import release
        pack_dir = os.path.join(self.root, "addon", p["folder"])
        toc = read_toc(pack_dir, p["folder"])
        if not toc:
            return
        bs2 = b"\\\\"                                   # \\ as written in Lua source
        media_from = []
        if p["media"]:
            old = p["media"].split("/")[-1].encode()
            media_from = [
                # "Interface\\AddOns\\DisasterZone\\Media\\<Game>\\" -> "Interface\\AddOns\\<Folder>\\Media\\"
                (b"Interface" + bs2 + b"AddOns" + bs2 + b"DisasterZone" + bs2 + b"Media" + bs2 + old + bs2,
                 b"Interface" + bs2 + b"AddOns" + bs2 + p["folder"].encode() + bs2 + b"Media" + bs2),
                # "Interface\\AddOns\\" .. addonName .. "\\Media\\<Game>\\" -> ... .. "\\Media\\"
                (b'.. addonName .. "' + bs2 + b"Media" + bs2 + old + bs2 + b'"',
                 b'.. addonName .. "' + bs2 + b"Media" + bs2 + b'"'),
            ]
        for rel in toc[1]:
            if rel in (PACK_FIRST, PACK_LAST) or not rel.endswith(".lua"):
                continue
            path = os.path.join(pack_dir, rel)
            if not os.path.isfile(path):
                continue
            with open(path, "rb") as fh:
                data = fh.read()
            orig = data
            bom = data[:3] if data.startswith(b"\xef\xbb\xbf") else b""
            body = data[len(bom):]
            key = (p["folder"] + "/" + rel).encode()
            m = release.GUARD_RE.match(body)
            if m and m.group(1) != key:
                nl = body.find(b"\n")
                end = nl if nl >= 0 else len(body)
                tail = body[m.end():end]
                old_key = m.group(1)
                tail = tail.replace(b"DisasterZone " + old_key, key).replace(old_key, key)
                body = release.guard_for(key.decode()) + tail + body[end:]
            elif not m:
                body = release.guard_for(key.decode()) + body
            for a, b in media_from:
                body = body.replace(a, b)
            data = bom + body
            if data != orig:
                self.note("lua", "%s/%s" % (p["folder"], rel))
                if not self.dry:
                    self._put(path, data)

    def hold_the_line_extras(self):
        """Hold the Line drew two of Illidan's textures (splat, vignette): it gets copies of its own."""
        p = BY_FOLDER["DisasterZone_HoldTheLine"]
        pack_dir = os.path.join(self.root, "addon", p["folder"])
        render = os.path.join(pack_dir, "Render.lua")
        if not os.path.isfile(render):
            return
        bs2 = b"\\\\"
        with open(render, "rb") as fh:
            data = fh.read()
        new = data
        for name in ("splat", "vignette"):
            old = b"Interface" + bs2 + b"AddOns" + bs2 + b"DisasterZone" + bs2 + b"Media" + bs2 + b"Illidan" + bs2 + name.encode()
            if old in new:
                new = new.replace(old, b"Interface" + bs2 + b"AddOns" + bs2 + p["folder"].encode() + bs2 + b"Media"
                                  + bs2 + name.encode())
                src = None
                for cand in (os.path.join(self.root, "addon", "DisasterZone_Illidan", "Media", name + ".tga"),
                             os.path.join(self.addon, "Media", "Illidan", name + ".tga")):
                    if os.path.isfile(cand):
                        src = cand
                        break
                dst = os.path.join(pack_dir, "Media", name + ".tga")
                self.note("copy", "%s.tga from Illidan's art into %s/Media" % (name, p["folder"]))
                if not self.dry and src and not os.path.isfile(dst):
                    os.makedirs(os.path.dirname(dst), exist_ok=True)
                    shutil.copyfile(src, dst)
                    self.git("add", "--", dst)
        if new != data:
            self.note("lua", "%s/Render.lua: its own splat and vignette" % p["folder"])
            if not self.dry:
                self._put(render, new)

    # 6 ----------------------------------------------------------------------------------------------------------------
    def literals(self):
        """Exact quoted paths of moved files in the dev kit's own files become the pack paths (tools/move.py's rules,
        but a file is only searched for the moved files whose name it contains: hundreds of moved art files)."""
        import move
        mapping_path = os.path.join(self.dev, "docs", "arch", "PACKS.json")
        old = []
        if os.path.isfile(mapping_path):
            with open(mapping_path, encoding="utf-8") as fh:
                old = json.load(fh).get("moves", [])
        seen = {e["from"] for e in self.entries}
        entries = self.entries + [e for e in old if e["from"] not in seen]
        if not entries:
            return
        if not self.dry:
            os.makedirs(os.path.dirname(mapping_path), exist_ok=True)
            with open(mapping_path, "w", encoding="utf-8") as fh:
                json.dump({"moves": entries}, fh, indent=1)
        by_base = {}
        for e in entries:
            f, t = e["from"], e["to"]
            variants = [(f.encode(), t.encode()), (f.replace("/", "\\").encode(), t.replace("/", "\\").encode()),
                        (f.replace("/", "\\\\").encode(), t.replace("/", "\\\\").encode())]
            by_base.setdefault(f.rsplit("/", 1)[-1].encode(), []).append((e, variants))
        changed = 0
        for sub in move.REWRITE_DIRS:
            top = os.path.join(self.dev, sub)
            for dp, dns, fns in os.walk(top):
                dns[:] = [d for d in dns if d not in move.SKIP_DIRS and not (sub == "tf_e" and dp == top)]
                for fn in sorted(fns):
                    ext = os.path.splitext(fn)[1].lower()
                    p = os.path.join(dp, fn)
                    if ext not in move.TEXT_EXT or os.path.normcase(p) == os.path.normcase(mapping_path):
                        continue
                    try:
                        if os.path.getsize(p) > move.MAX_BYTES:
                            continue
                        with open(p, "rb") as fh:
                            data = fh.read()
                    except OSError:
                        continue
                    if move.KEEP_MARK in data:
                        continue
                    pairs = []
                    for base, items in by_base.items():
                        if base in data:
                            for e, variants in items:
                                pairs.extend(variants)
                    if not pairs:
                        continue
                    to_of = dict(pairs)
                    quotes = re.escape(move.TEXT_EXT[ext].encode())
                    alts = b"|".join(re.escape(o) for o in sorted(to_of, key=len, reverse=True))
                    pat = re.compile(rb"([" + quotes + rb"])(" + alts + rb")(?=\1)")
                    new = pat.sub(lambda m: m.group(1) + to_of[m.group(2)], data)
                    rel = os.path.relpath(p, self.root).replace(os.sep, "/")
                    masked = new
                    for t in sorted(set(to_of.values()), key=len, reverse=True):
                        masked = masked.replace(t, b"\0" * len(t))
                    for o in sorted(to_of, key=len, reverse=True):
                        for m in re.finditer(rb"(?<![A-Za-z0-9_])" + re.escape(o) + rb"(?![A-Za-z0-9_])", masked):
                            line = masked.count(b"\n", 0, m.start()) + 1
                            self.log("check by hand: %s:%d: %s" % (rel, line, o.decode("utf-8", "replace")))
                    if new != data:
                        changed += 1
                        self.note("literal", "%s: %d path(s)" % (rel, len(pat.findall(data))))
                        if not self.dry:
                            self._put(p, new)
        self.log("%d dev kit file(s) name the packs' paths now" % changed)
        if not self.dry:
            move.Mover(mapping_path, root=self.root, dry=False, log=self.log).write_moves()

    def _put(self, path, data):
        import release
        release._put(path, data)

    def run(self):
        self.check_places()
        n = 0
        for p in PACKS:
            n += self.move(p)
            self.prune(p)
            self.tocs(p)
            self.fix_lua(p)
        self.hold_the_line_extras()
        self.literals()
        self.log("%s%d file(s) moved into %d pack(s)" % ("(dry run) " if self.dry else "", n, len(PACKS)))
        return self


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("split")
    s.add_argument("--dry-run", action="store_true")
    s.add_argument("--root", default=REPO)
    l = sub.add_parser("list")
    l.add_argument("--addon", default=os.path.join(REPO, "addon", ADDON_NAME))
    a = ap.parse_args(argv)
    try:
        if a.cmd == "split":
            Splitter(a.root, dry=a.dry_run).run()
        else:
            for name, folder in find_packs(a.addon).items():
                print("%-26s %s" % (name, folder))
    except PackError as e:
        print(e, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
