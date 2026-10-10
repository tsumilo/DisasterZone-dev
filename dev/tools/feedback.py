r"""The guild's feedback to Tsumil (Core/Feedback.lua), read from the developer's saved variables.

  luaenv\Scripts\python.exe tools\feedback.py              writes dev/feedback/inbox.md (+ inbox.json): every item by
                                                             status, most asked first, with its context, Lua error and
                                                             answers; "fix #42" in a session means the #42 there
  luaenv\Scripts\python.exe tools\feedback.py credits      fills the credits of changelog lines that name items:
                                                             { "text", fb = { 42 } } -> by = { names }, mt = me-toos,
                                                             k = kind (Data/Changelog.lua, written in place)
  luaenv\Scripts\python.exe tools\feedback.py credits --check   only reports lines whose credits are missing or stale

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
                          "anon": r.get("an") == 1, "gone": r.get("d") == 1, "votes": [], "replies": [],
                          "state": None, "no": None}
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
            lines.append("- **From** %s%s, %s" % (name(it["author"]), " (no name in the changelog)" if it["anon"]
                                                  else "", day(it["at"])))
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
            if not it["anon"] and name(it["author"]) not in names:
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


if __name__ == "__main__":
    args = sys.argv[1:]
    if args and args[0] == "credits":
        sys.exit(credits(check="--check" in args))
    sys.exit(write_inbox())
