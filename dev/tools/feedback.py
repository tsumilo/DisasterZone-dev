r"""The guild's feedback to Tsumil (Core/Feedback.lua), read from the developer's saved variables.

  luaenv\Scripts\python.exe tools\feedback.py              writes dev/feedback/inbox.md (+ inbox.json): every item by
                                                             status, most asked first, with its context, Lua error and
                                                             answers; "fix #42" in a session means the #42 there
  luaenv\Scripts\python.exe tools\feedback.py credits      fills the credits of changelog lines that name items:
                                                             { "text", fb = { 42 } } -> by = { names }, mt = me-toos,
                                                             k = kind (Data/Changelog.lua, written in place)
  luaenv\Scripts\python.exe tools\feedback.py credits --check   only reports lines whose credits are missing or stale
  luaenv\Scripts\python.exe tools\feedback.py plan [...]  the release plan: shows it (dev/feedback/plan.md) or changes
                                                             it (plan help); writes Core/DevPlan.lua for the next /reload

The saved variables on disk are only as fresh as the last /reload or logout of the developer's characters. Every
account under WTF/Account is read; the developer's account is the one whose store has item numbers.
"""
import glob
import json
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
DEV = os.path.dirname(HERE)
ADDON = os.environ.get("DISASTERZONE_ADDON_DIR") or os.path.join(os.path.dirname(DEV), "addon", "DisasterZone")
# (the dev kit reaches the addon through a junction: the game folder is where it really is)
WTF = os.environ.get("DZ_WTF") or os.path.normpath(os.path.join(os.path.realpath(ADDON), "..", "..", "..", "WTF",
                                                                "Account"))
OUT = os.path.join(DEV, "feedback")
CHANGELOG = os.path.join(ADDON, "Data", "Changelog.lua")

KIND = {"bug": "Bug", "idea": "Idea", "change": "Change", "love": "Love"}
STATE = {"open": "Open", "planned": "Planned", "done": "Shipped", "exists": "Already in the addon",
         "notnow": "Not planned", "dup": "Duplicate", "removed": "Removed"}
CLOSED = {"done", "exists", "notnow", "dup", "removed"}


def _py(v):
    """lupa table -> dict / list."""
    if hasattr(v, "items"):
        d = {k: _py(x) for k, x in v.items()}
        if d and all(isinstance(k, int) for k in d) and sorted(d) == list(range(1, len(d) + 1)):
            return [d[i] for i in range(1, len(d) + 1)]
        return d
    if isinstance(v, bytes):
        return v.decode("utf-8", "replace")
    return v


def load_stores():
    """[(path, mtime, guildKey, store)] for every DisasterZone saved-variables file with feedback."""
    from lupa import lua51
    out = []
    for path in sorted(glob.glob(os.path.join(WTF, "*", "SavedVariables", "DisasterZone.lua"))):
        lua = lua51.LuaRuntime(unpack_returned_tuples=True)
        with open(path, "rb") as f:
            src = f.read().decode("utf-8", "replace")
        try:
            lua.execute(src)
        except Exception as e:  # noqa: BLE001
            print("could not read %s: %s" % (path, e))
            continue
        db = lua.globals().DisasterZoneDB
        fb = db and db["feedback"]
        if not fb:
            continue
        for gk, store in _py(fb).items():
            if isinstance(store, dict) and store.get("r"):
                out.append((path, os.path.getmtime(path), gk, store))
    return out


def build(store):
    """Items as dicts, like Core/Feedback.lua's Rebuild: { id: item }."""
    recs = store.get("r") or {}
    items = {}
    for rid, r in recs.items():
        if r.get("k") == "i":
            items[rid] = {"id": rid, "author": r.get("a"), "kind": r.get("kd"), "text": r.get("x"),
                          "about": r.get("ab"), "ctx": r.get("c") or {}, "err": r.get("e"), "at": r.get("t"),
                          "anon": r.get("an") == 1, "gone": r.get("d") == 1, "auto": r.get("au") == 1,
                          "votes": [], "replies": [], "state": None, "no": None}
    for rid, r in recs.items():
        it = items.get(r.get("i"))
        if not it:
            continue
        k = r.get("k")
        if k == "v" and r.get("d") != 1 and r.get("a") != it["author"]:
            it["votes"].append(r.get("a"))
        elif k == "r" and r.get("d") != 1:
            it["replies"].append({"author": r.get("a"), "text": r.get("x"), "at": r.get("t")})
        elif k == "s":
            it.update(state=r.get("s"), state_by=r.get("a"), state_at=r.get("rv"), dup=r.get("dp"),
                      shipped=r.get("v"))
        elif k == "n":
            it["no"] = r.get("no")
    for it in items.values():
        it["votes"].sort()
        it["replies"].sort(key=lambda x: (x["at"] or 0))
    return items


def name(key):
    return (key or "?").split("-")[0]


def day(ts):
    return time.strftime("%a %d %b %Y %H:%M", time.localtime(ts)) if ts else "?"


def write_inbox():
    stores = load_stores()
    if not stores:
        print("no feedback in any saved variables under", WTF)
        return 1
    # the developer's account: the store with the most numbered items
    path, mtime, gk, store = max(stores, key=lambda s: sum(1 for r in s[3]["r"].values() if r.get("k") == "n"))
    items = [it for it in build(store).values() if not it["gone"]]
    by_no = {it["no"]: it for it in items if it["no"]}
    groups = [("Waiting for an answer", lambda it: not it["state"] or it["state"] == "open"),
              ("Planned", lambda it: it["state"] == "planned"),
              ("Shipped", lambda it: it["state"] == "done"),
              ("Closed", lambda it: it["state"] in CLOSED - {"done"})]
    lines = ["# Feedback inbox", "",
             "From `%s` (guild %s), saved %s. Only as fresh as the last /reload or logout." % (
                 os.path.relpath(path, os.path.dirname(WTF)), gk, day(mtime)),
             "", "%d items: %s." % (len(items), ", ".join(
                 "%d %s" % (sum(1 for it in items if f(it)), t.lower()) for t, f in groups)), ""]
    for title, f in groups:
        group = sorted([it for it in items if f(it)], key=lambda it: (-len(it["votes"]), -(it["at"] or 0)))
        if not group:
            continue
        lines += ["## %s (%d)" % (title, len(group)), ""]
        for it in group:
            no = "#%d" % it["no"] if it["no"] else "(no number yet)"
            lines.append("### %s · %s · %s" % (no, KIND.get(it["kind"], it["kind"]), (it["text"] or "")[:70]))
            lines.append("")
            lines.append("- **From** %s%s%s, %s" % (name(it["author"]), " (no name in the changelog)" if it["anon"]
                                                    else "", " (a Lua error, sent by itself)" if it["auto"] else "",
                                                    day(it["at"])))
            if it["about"]:
                lines.append("- **About** %s" % it["about"])
            c = it["ctx"]
            ctx = ", ".join(x for x in [c.get("v") and "v" + c["v"], c.get("b") and "build " + c["b"], c.get("z"),
                                        " ".join(filter(None, [c.get("sp"), c.get("cl")])) or None,
                                        c.get("p") and "page " + c["p"], c.get("lo")] if x)
            if ctx:
                lines.append("- **With it** %s" % ctx)
            if it["votes"]:
                lines.append("- **Me too (%d)** %s" % (len(it["votes"]), ", ".join(name(v) for v in it["votes"])))
            if it["state"] and it["state"] != "open":
                extra = ""
                if it["state"] == "dup" and it.get("dup"):
                    other = next((o for o in items if o["id"] == it["dup"]), None)
                    extra = " of #%s" % (other and other["no"])
                if it["state"] == "done" and it.get("shipped"):
                    extra = " in %s" % it["shipped"]
                lines.append("- **Status** %s%s (by %s)" % (STATE.get(it["state"], it["state"]), extra,
                                                            name(it.get("state_by"))))
            lines.append("")
            lines.append("> " + (it["text"] or "").replace("\n", "\n> "))
            lines.append("")
            if it["err"]:
                e = it["err"]
                if e.get("p"):
                    lines += ["%s%s:" % ("Error report" if it["auto"] else "Pasted error",
                                         e.get("v") and " (" + e["v"] + ")" or ""), "", "```", e["p"], "```", ""]
                else:
                    lines += ["Lua error (%sx%s):" % (e.get("v") and e["v"] + ", " or "", e.get("n") or 1), "", "```",
                              e.get("m") or "", e.get("s") or "", "```", ""]
            for rep in it["replies"]:
                lines.append("- *%s, %s:* %s" % (name(rep["author"]), day(rep["at"]), rep["text"]))
            if it["replies"]:
                lines.append("")
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, "inbox.md"), "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines))
    with open(os.path.join(OUT, "inbox.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump({"source": path, "saved": mtime, "guild": gk, "items": sorted(items, key=lambda i: i["no"] or 0)},
                  f, indent=1, ensure_ascii=False)
    print("wrote %s (%d items, %d numbered)" % (os.path.join(OUT, "inbox.md"), len(items), len(by_no)))
    return 0


LINE_RE = re.compile(r'\{\s*("(?:[^"\\]|\\.)*")\s*,\s*fb\s*=\s*\{([^}]*)\}((?:\s*,\s*(?:by\s*=\s*\{[^}]*\}|mt\s*=\s*\d+|'
                     r'k\s*=\s*"\w+"))*)\s*\}')


def credits(check=False):
    stores = load_stores()
    path, _, _, store = max(stores, key=lambda s: sum(1 for r in s[3]["r"].values() if r.get("k") == "n")) \
        if stores else (None, 0, None, {"r": {}})
    by_no = {it["no"]: it for it in build(store).values() if it["no"]}
    with open(CHANGELOG, "rb") as f:
        src = f.read().decode("utf-8")
    problems, changed = [], 0

    def fix(m):
        nonlocal changed
        text, nums = m.group(1), [int(x) for x in re.findall(r"\d+", m.group(2))]
        names, voters, kind = [], set(), None
        for no in nums:
            it = by_no.get(no)
            if not it:
                problems.append("#%d is not in the feedback (%s)" % (no, text[:50]))
                return m.group(0)
            # (an error that reported itself names its player only when they added what they were doing)
            told = not it["auto"] or any(rep["author"] == it["author"] for rep in it["replies"])
            if not it["anon"] and told and name(it["author"]) not in names:
                names.append(name(it["author"]))
            voters.update(v for v in it["votes"] if v != it["author"])
            kind = kind or it["kind"]
        new = "{ %s, fb = { %s }" % (text, ", ".join(str(n) for n in nums))
        if names:
            new += ", by = { %s }" % ", ".join('"%s"' % n for n in names)
        if voters:
            new += ", mt = %d" % len(voters)
        new += ', k = "%s" }' % kind
        if new != m.group(0):
            changed += 1
            if check:
                problems.append("stale credits: %s" % text[:60])
        return new

    out = LINE_RE.sub(fix, src)
    for p in problems:
        print(p)
    if not check and changed:
        with open(CHANGELOG, "wb") as f:
            f.write(out.encode("utf-8"))
        print("credited %d changelog line(s)" % changed)
    elif not changed and not problems:
        print("changelog credits are up to date")
    return 1 if problems else 0


# ---------------------------------------------------------------------------------------------------------------
# The release plan (Core/FeedbackPlan.lua): read from the saved variables and Core/DevPlan.lua, changed here, written
# back to Core/DevPlan.lua (git-ignored, shipped empty by release.py). The developer's client merges the file at the
# next /reload: per release and per item the newer edit (u) wins, so edits made in game since are kept.
# ---------------------------------------------------------------------------------------------------------------

DEVPLAN = os.path.join(ADDON, "Core", "DevPlan.lua")
SIZE_H = {"S": 1, "M": 3, "L": 8, "XL": 12}
DEV_KINDS = ("idea", "change", "bug", "chore")
VER_RE = re.compile(r"^\d+[.\d]*$")
PLAN_USAGE = """feedback.py plan                                   writes dev/feedback/plan.md and prints the plan
feedback.py plan release VER [--theme T] [--date YYYY-MM-DD] [--budget H] [--public | --private] [--released]
                                                   [--open-again] [--delete]   creates or changes a release
feedback.py plan put REF... --to VER|later|none [--size S|M|L|XL]   places items (REF: #21, D-4)
feedback.py plan size REF... S|M|L|XL|none
feedback.py plan group NAME|none REF...
feedback.py plan note REF TEXT|none
feedback.py plan add TITLE [--kind idea|change|bug|chore] [--size S] [--to VER|later]   one of my own items
feedback.py plan done REF... / undone REF... / remove REF...
Changes reach the game at the developer's next /reload."""


def vkey(v):
    return [int(x) if x.isdigit() else 0 for x in v.split(".")]


def lua_str(s):
    return '"%s"' % s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\r", "")


def lua_val(v, indent):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return str(int(v)) if float(v).is_integer() else repr(v)
    if isinstance(v, str):
        return lua_str(v)
    if isinstance(v, dict):
        if not v:
            return "{}"
        pad = "    " * (indent + 1)
        rows = []
        for k in sorted(v, key=lambda x: (isinstance(x, str), str(x))):
            key = k if isinstance(k, str) and re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", k) else "[%s]" % (
                lua_str(k) if isinstance(k, str) else k)
            rows.append("%s%s = %s," % (pad, key, lua_val(v[k], indent + 1)))
        return "{\n%s\n%s}" % ("\n".join(rows), "    " * indent)
    if isinstance(v, list):
        return "{ %s }" % ", ".join(lua_val(x, indent + 1) for x in v)
    raise ValueError("cannot write %r" % (v,))


def read_devplan():
    """(gk, plan) from Core/DevPlan.lua, or (None, None)."""
    if not os.path.isfile(DEVPLAN):
        return None, None
    from lupa import lua51
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    with open(DEVPLAN, "rb") as f:
        lua.execute(f.read().decode("utf-8"))
    t = _py(lua.globals().DisasterZoneDevPlan) if lua.globals().DisasterZoneDevPlan else None
    if not t:
        return None, None
    return t.get("gk"), t.get("p")


def norm_plan(p):
    p = dict(p or {})
    p["rev"] = int(p.get("rev") or 0)
    p["rel"] = dict(p.get("rel") or {})
    p["it"] = dict(p.get("it") or {})
    return p


def merge(dst, src):
    for part in ("rel", "it"):
        for k, e in (src.get(part) or {}).items():
            cur = dst[part].get(k)
            if not cur or (e.get("u") or 0) > (cur.get("u") or 0):
                dst[part][k] = dict(e)
    newest = max([e.get("u") or 0 for part in ("rel", "it") for e in dst[part].values()] + [dst["rev"]])
    dst["rev"] = newest


def dev_store():
    """(path, mtime, gk, feedback store, saved plan) of the developer's account, or Nones."""
    stores = load_stores()
    if not stores:
        return None, 0, None, {"r": {}}, None
    path, mtime, gk, store = max(stores, key=lambda s: sum(1 for r in s[3]["r"].values() if r.get("k") == "n"))
    from lupa import lua51
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    with open(path, "rb") as f:
        lua.execute(f.read().decode("utf-8", "replace"))
    db = lua.globals().DisasterZoneDB
    fp = db and db["feedbackPlan"]
    saved = None
    if fp and fp[gk]:
        b = _py(fp[gk])
        saved = b.get("plan") if isinstance(b, dict) else None
    return path, mtime, gk, store, saved


class PlanModel:
    def __init__(self):
        self.path, self.mtime, self.gk, store, saved = dev_store()
        self.items = build(store)
        self.by_no = {it["no"]: it for it in self.items.values() if it["no"]}
        # (what the changelog names has shipped, whatever the saved status says: as in the game's Rebuild)
        with open(CHANGELOG, "rb") as f:
            src = f.read().decode("utf-8")
        for nums in re.findall(r"fb\s*=\s*\{([^}]*)\}", src):
            for no in re.findall(r"\d+", nums):
                it = self.by_no.get(int(no))
                if it:
                    it["state"] = "done"
        fgk, fplan = read_devplan()
        self.plan = norm_plan(saved)
        if fplan and (fgk == self.gk or not self.gk):
            merge(self.plan, norm_plan(fplan))
            self.gk = self.gk or fgk
        self.now = int(time.time())

    def ref(self, r):
        r = r.strip()
        if re.match(r"^D-\d+$", r):
            if r not in self.plan["it"]:
                raise SystemExit("%s is not one of your items" % r)
            return r
        m = re.match(r"^#?(\d+)$", r)
        if m:
            it = self.by_no.get(int(m.group(1)))
            if not it:
                raise SystemExit("#%s is not in the feedback (read it at the last /reload)" % m.group(1))
            return it["id"]
        if r in self.items:
            return r
        raise SystemExit("unknown item %r (use #21 or D-4)" % r)

    def touch(self, part, key, **fields):
        old = self.plan[part].get(key)
        e = dict(old or {})
        for k, v in fields.items():
            if v is None:
                e.pop(k, None)
            else:
                e[k] = v
        e["u"] = max(self.now, (old or {}).get("u", 0) + 1)
        self.plan[part][key] = e
        self.plan["rev"] = max(self.plan["rev"], e["u"])

    def live(self, part, key):
        e = self.plan[part].get(key)
        return e if e and e.get("x") != 1 else None

    def check_rl(self, rl):
        if rl in (None, "later"):
            return
        if not self.live("rel", rl):
            raise SystemExit("no release %s (plan release %s first)" % (rl, rl))

    def save(self):
        if not self.gk:
            raise SystemExit("the guild is not known: log in once with the developer's character")
        body = lua_val({"gk": self.gk, "p": self.plan}, 0)
        with open(DEVPLAN, "w", encoding="utf-8", newline="\n") as f:
            f.write("-- DisasterZone: the developer's release plan, written by dev/tools/feedback.py plan %s. The\n"
                    "-- developer's client takes it in at /reload (Core/FeedbackPlan.lua). Never shipped.\n"
                    % time.strftime("%Y-%m-%d %H:%M"))
            f.write("DisasterZoneDevPlan = %s\n" % body)

    # -- views
    def releases(self, with_done=False):
        out = [(v, r) for v, r in self.plan["rel"].items() if r.get("x") != 1 and (with_done or not r.get("done"))]
        return sorted(out, key=lambda x: vkey(x[0]))

    def label(self, key):
        e = self.plan["it"].get(key) or {}
        if key.startswith("D-"):
            return key, e.get("tt") or "?", e.get("kd") or "idea", None
        it = self.items.get(key) or {}
        return ("#%s" % it["no"]) if it.get("no") else "(no number)", (it.get("text") or "?").replace("\n", " "), \
            it.get("kind") or "?", it

    def cards(self, rl):
        out = []
        for key, e in self.plan["it"].items():
            if e.get("x") == 1 or e.get("rl") != rl:
                continue
            if not key.startswith("D-"):
                it = self.items.get(key)
                if not it or it["gone"] or it["state"] in ("removed", "exists", "notnow", "dup"):
                    continue
            out.append(key)
        return sorted(out, key=lambda k: (SIZE_H.get((self.plan["it"][k]).get("sz"), 99), k))

    def to_sort(self):
        placed = {k for k, e in self.plan["it"].items() if e.get("x") != 1 and e.get("rl") and (
            e["rl"] == "later" or self.live("rel", e["rl"]))}
        out = [it for it in self.items.values() if not it["gone"] and it["state"] not in CLOSED and it["id"] not in placed
               and it["kind"] != "love"]
        return sorted(out, key=lambda it: (-len(it["votes"]), -(it["at"] or 0)))

    def report(self):
        lines = ["# Release plan", "",
                 "Saved plan from `%s` (%s) merged with Core/DevPlan.lua. Sizes: S 1 h, M 3 h, L 8 h, XL 12 h." % (
                     os.path.relpath(self.path, os.path.dirname(WTF)) if self.path else "-", day(self.mtime)), ""]

        def card_line(key):
            e = self.plan["it"][key]
            ref, text, kind, it = self.label(key)
            bits = [e.get("sz") or "?", ref, KIND.get(kind, kind.title())]
            extra = []
            if it and it.get("votes"):
                extra.append("+%d" % len(it["votes"]))
            if it:
                extra.append(name(it["author"]))
            if e.get("g"):
                extra.append("group: %s" % e["g"])
            if key.startswith("D-") and e.get("dn"):
                extra.append("done")
            if it and it.get("state") == "done":
                extra.append("shipped %s" % (it.get("shipped") or ""))
            s = "- **%s** %s · %s: %s" % (bits[0], bits[1], bits[2], text[:90])
            if extra:
                s += " (%s)" % ", ".join(extra)
            if e.get("nt"):
                s += "  \n  _note: %s_" % e["nt"]
            return s

        for v, r in self.releases():
            keys = self.cards(v)
            hours = sum(SIZE_H.get(self.plan["it"][k].get("sz"), 0) for k in keys)
            head = "## %s · %s" % (v, r.get("th") or "(no theme)")
            meta = ["%d of %s h" % (hours, r.get("bg") if r.get("bg") is not None else "?"),
                    "guild sees it" if r.get("pub") == 1 else "staff only"]
            if r.get("dt"):
                meta.append("target %s" % time.strftime("%a %d %b", time.localtime(r["dt"])))
            lines += [head, "", "_%s_" % " · ".join(meta), ""]
            lines += [card_line(k) for k in keys] or ["(empty)"]
            lines.append("")
        later = self.cards("later")
        lines += ["## Later", ""] + ([card_line(k) for k in later] or ["(empty)"]) + [""]
        sort = self.to_sort()
        lines += ["## To sort (%d)" % len(sort), ""]
        for it in sort:
            lines.append("- %s · %s: %s (%s%s)" % ("#%s" % it["no"] if it["no"] else "(no number)",
                                                    KIND.get(it["kind"], it["kind"]), (it["text"] or "").replace(
                                                        "\n", " ")[:90], name(it["author"]),
                                                    ", +%d" % len(it["votes"]) if it["votes"] else ""))
        done = self.releases(with_done=True)
        shipped = [(v, r) for v, r in done if r.get("done")]
        if shipped:
            lines += ["", "## Released", ""] + ["- %s · %s (%s)" % (v, r.get("th") or "", day(r["done"]))
                                                for v, r in shipped[-5:]]
        os.makedirs(OUT, exist_ok=True)
        out = os.path.join(OUT, "plan.md")
        with open(out, "w", encoding="utf-8", newline="\n") as f:
            f.write("\n".join(lines) + "\n")
        return out, lines


def plan_cmd(args):
    import argparse
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    if args and args[0] in ("-h", "--help", "help"):
        print(PLAN_USAGE)
        return 0
    m = PlanModel()
    cmd = args[0] if args else "show"
    rest = args[1:]
    ap = argparse.ArgumentParser(prog="feedback.py plan " + cmd, usage=PLAN_USAGE)
    changed = True
    if cmd == "show":
        changed = False
    elif cmd == "release":
        ap.add_argument("ver")
        ap.add_argument("--theme")
        ap.add_argument("--date")
        ap.add_argument("--budget", type=int)
        ap.add_argument("--public", action="store_true")
        ap.add_argument("--private", action="store_true")
        ap.add_argument("--released", action="store_true")
        ap.add_argument("--open-again", action="store_true")
        ap.add_argument("--delete", action="store_true")
        a = ap.parse_args(rest)
        if not VER_RE.match(a.ver):
            raise SystemExit("a version is numbers and dots: 1.6.0")
        f = {"x": None}
        if a.delete:
            f = {"x": 1}
        if a.theme is not None:
            f["th"] = a.theme[:40] or None
        if a.date:
            f["dt"] = int(time.mktime(time.strptime(a.date + " 20:00", "%Y-%m-%d %H:%M")))
        if a.budget is not None:
            f["bg"] = max(0, min(999, a.budget))
        if a.public:
            f["pub"] = 1
        if a.private:
            f["pub"] = None
        if a.released:
            f["done"] = m.now
        if a.open_again:
            f["done"] = None
        m.touch("rel", a.ver, **f)
    elif cmd == "put":
        ap.add_argument("refs", nargs="+")
        ap.add_argument("--to", required=True)
        ap.add_argument("--size", choices=list(SIZE_H))
        a = ap.parse_args(rest)
        rl = None if a.to == "none" else a.to
        m.check_rl(rl)
        for r in a.refs:
            key = m.ref(r)
            f = {"rl": rl, "x": None}
            if a.size:
                f["sz"] = a.size
            m.touch("it", key, **f)
    elif cmd == "size":
        if len(rest) < 2:
            raise SystemExit(PLAN_USAGE)
        sz = rest[-1].upper()
        if sz not in SIZE_H and sz != "NONE":
            raise SystemExit("pick S, M, L or XL")
        for r in rest[:-1]:
            m.touch("it", m.ref(r), sz=None if sz == "NONE" else sz, x=None)
    elif cmd == "group":
        if len(rest) < 2:
            raise SystemExit(PLAN_USAGE)
        g = None if rest[0] == "none" else rest[0][:30]
        for r in rest[1:]:
            m.touch("it", m.ref(r), g=g, x=None)
    elif cmd == "note":
        if len(rest) < 2:
            raise SystemExit(PLAN_USAGE)
        text = " ".join(rest[1:]).replace("|", "/").replace("\n", " ")[:120]
        m.touch("it", m.ref(rest[0]), nt=None if text == "none" else text, x=None)
    elif cmd == "add":
        ap.add_argument("title")
        ap.add_argument("--kind", choices=DEV_KINDS, default="idea")
        ap.add_argument("--size", choices=list(SIZE_H))
        ap.add_argument("--to")
        a = ap.parse_args(rest)
        m.check_rl(a.to)
        n = max([int(k[2:]) for k in m.plan["it"] if k.startswith("D-")] + [0]) + 1
        key = "D-%d" % n
        m.touch("it", key, tt=a.title.replace("|", "/")[:80], kd=a.kind, sz=a.size, rl=a.to, at=m.now)
        print("added", key)
    elif cmd in ("done", "undone"):
        for r in rest:
            key = m.ref(r)
            if not key.startswith("D-"):
                raise SystemExit("%s: feedback items ship through the changelog (fb = { n })" % r)
            m.touch("it", key, dn=m.now if cmd == "done" else None)
    elif cmd == "remove":
        for r in rest:
            m.touch("it", m.ref(r), x=1)
    else:
        print(PLAN_USAGE)
        return 2
    if changed:
        m.save()
    out, lines = m.report()
    print("\n".join(lines))
    print("\nwrote %s%s" % (out, "; Core/DevPlan.lua updated: /reload in game to take it in" if changed else ""))
    return 0


if __name__ == "__main__":
    args = sys.argv[1:]
    if args and args[0] == "credits":
        sys.exit(credits(check="--check" in args))
    if args and args[0] == "plan":
        sys.exit(plan_cmd(args[1:]))
    sys.exit(write_inbox())
