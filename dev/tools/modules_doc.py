#!/usr/bin/env python
"""Module contract headers -> dev/docs/MODULES.md, and the header lint used by check.py --headers.

The header (dev/docs/ARCHITECTURE_PLAN.md, "Module contract header") follows the line-1 guard:

    if DisasterZoneBoot and DisasterZoneBoot.Run("<path>", ...) then return end
    -- Module   <ns name> [(<part>)]                     Layer  <n> · <folder>
    -- Owns     <saved tables / state it alone writes>
    -- Uses     <modules it calls>
    -- Fires    <messages>
    -- API
    --   Mod:Func(args) -> returns            one-line contract
    local addonName, ns = ...

Owns / Uses / Fires may continue on the next lines (indented past the key). API lines are `--   Name(args) ...` with
two or more spaces after `--`; a deeper-indented line continues the entry above. A plain comment line (`-- text`)
or code ends the header. Uses entries are module names, optionally feature-qualified (`Context.Roster` = Roster);
text in parentheses is a remark.

Checks (check.py --headers, modules_doc.py --check):
    no header                                   WARN HEADER missing
    Layer differs from tools/layers.json        WARN HEADER layer
    an API line names a function no file defines  WARN HEADER api
    Uses omits a module the file calls          WARN HEADER uses
Usage:
    modules_doc.py                 write dev/docs/MODULES.md
    modules_doc.py --check         print the header warnings (exit 0; the count is the to-do list)
    modules_doc.py --out PATH      write elsewhere
"""
import argparse
import collections
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import layers  # noqa: E402

DOC_PATH = os.path.join(os.path.dirname(HERE), "docs", "MODULES.md")

RE_GUARD = re.compile(r"^\s*if\s+DisasterZoneBoot\b")
RE_MODULE = re.compile(r"^--\s+Module\s+([A-Za-z_][\w.]*)(?:\s*\(([^)]*)\))?\s+Layer\s+(\d+)\s*(?:[·.\-|:]\s*)?(\S.*?)?\s*$")
RE_KEY = re.compile(r"^--\s+(Owns|Uses|Fires)\b\s*(.*?)\s*$")
RE_API_KEY = re.compile(r"^--\s+API\s*$")
RE_API_LINE = re.compile(r"^--\s{2,}([A-Za-z_]\w*(?:\s*[.:]\s*[A-Za-z_]\w*)+)\s*(\([^)]*\))?\s*(.*?)\s*$")
RE_CONT = re.compile(r"^--\s{4,}(\S.*?)\s*$")


class Header:
    __slots__ = ("module", "part", "layer", "folder", "owns", "uses_text", "uses", "fires", "api", "line", "path")

    def __init__(self):
        self.module = self.part = self.folder = None
        self.layer = None
        self.owns, self.uses_text, self.fires = "", "", ""
        self.uses = []
        self.api = []          # [(name, args, rest, line)]
        self.line = 0
        self.path = None


def parse_uses(text):
    """'Context.Roster, Items.ItemDB, Gear.BiS (spec only via Context.Me)' -> ['Roster', 'ItemDB', 'BiS']"""
    t = text
    while True:
        u = re.sub(r"\([^()]*\)", "", t)
        if u == t:
            break
        t = u
    out = []
    for part in re.split(r"[,;]", t):
        m = re.match(r"\s*([A-Za-z_][\w.:]*)", part)
        if not m:
            continue
        name = re.split(r"[.:]", m.group(1))[-1]
        if name.lower() in ("none", "nothing", "n", "a"):
            continue
        out.append(name)
    return out


def parse_header(text):
    """Header of one file (text with \\n line ends) or None. Starts on line 2 when line 1 is the guard, else line 1;
    the Module line may sit anywhere in the leading comment block."""
    lines = text.split("\n")
    i = 1 if lines and RE_GUARD.match(lines[0]) else 0
    while i < len(lines) and lines[i].startswith("--") and not RE_MODULE.match(lines[i]):
        i += 1
    if i >= len(lines) or not RE_MODULE.match(lines[i]):
        return None
    h = Header()
    m = RE_MODULE.match(lines[i])
    h.module, h.part, h.layer, h.folder = m.group(1), m.group(2), int(m.group(3)), (m.group(4) or "").strip() or None
    h.line = i + 1
    key = None
    i += 1
    while i < len(lines):
        ln = lines[i].rstrip()
        if not ln.startswith("--"):
            break
        if ln.strip() == "--":
            i += 1
            continue
        km = RE_KEY.match(ln)
        if km and (key != "API" or not RE_API_LINE.match(ln)):
            key = km.group(1)
            if key == "Owns":
                h.owns = km.group(2)
            elif key == "Uses":
                h.uses_text = km.group(2)
            else:
                h.fires = km.group(2)
            i += 1
            continue
        if RE_API_KEY.match(ln):
            key = "API"
            i += 1
            continue
        if key == "API":
            am = RE_API_LINE.match(ln)
            if am:
                h.api.append((re.sub(r"\s+", "", am.group(1)), am.group(2) or "", am.group(3), i + 1))
                i += 1
                continue
            cm = RE_CONT.match(ln)
            if cm and h.api:
                n, a, r, l0 = h.api[-1]
                h.api[-1] = (n, a, (r + " " + cm.group(1)).strip(), l0)
                i += 1
                continue
            break
        cm = RE_CONT.match(ln)
        if cm and key in ("Owns", "Uses", "Fires"):
            if key == "Owns":
                h.owns += " " + cm.group(1)
            elif key == "Uses":
                h.uses_text += " " + cm.group(1)
            else:
                h.fires += " " + cm.group(1)
            i += 1
            continue
        break
    h.uses = parse_uses(h.uses_text)
    return h


def headers(dm):
    out = {}
    for f in dm.files:
        h = parse_header(dm.info[f].raw)
        if h:
            h.path = f
            out[f] = h
    return out


def api_exists(dm, path, name):
    parts = re.split(r"[.:]", name)
    mod, func = parts[0], parts[-1]
    if mod == "ns":
        return func in dm.owner_mod
    mod = dm.info[path].aliases.get(mod, mod) if path in dm.info else mod
    if (mod, func) in dm.owner_meth:
        return True
    return len(parts) == 1 and mod in dm.owner_mod


def check(dm, files=None):
    """-> [(path, line, category, name, text)] header warnings for the given files (default: all TOC files)."""
    hs = headers(dm)
    out = []
    for f in (files if files is not None else dm.files):
        if f not in dm.info:
            continue
        h = hs.get(f)
        guard = 2 if RE_GUARD.match(dm.info[f].raw.split("\n", 1)[0]) else 1
        if h is None:
            out.append((f, guard, "missing", "", "WARN HEADER missing: no '-- Module <name> Layer <n>' block after "
                                                 "the guard (ARCHITECTURE_PLAN.md, Module contract header)"))
            continue
        lay = dm.layer(f)
        if lay is not None and h.layer != lay:
            out.append((f, h.line, "layer", str(h.layer), "WARN HEADER layer: the header says Layer %d, "
                                                           "tools/layers.json says %d" % (h.layer, lay)))
        for name, _, _, ln in h.api:
            if not api_exists(dm, f, name):
                out.append((f, ln, "api", name, "WARN HEADER api: '%s' is not defined by any file" % name))
        called = dm.called_modules(f) - {h.module}
        missing = sorted(called - set(h.uses))
        if missing:
            out.append((f, h.line, "uses", ",".join(missing),
                        "WARN HEADER uses: the file calls %s; 'Uses' does not list %s" % (
                            ", ".join(missing), "it" if len(missing) == 1 else "them")))
    return out


# ---------------------------------------------------------------------------------------------------------------
# MODULES.md
# ---------------------------------------------------------------------------------------------------------------
def _md(s):
    return s.replace("|", "\\|")


def render(dm):
    cfg = dm.config
    hs = headers(dm)
    w = []
    w.append("# DisasterZone modules")
    w.append("")
    w.append("Generated by `dev/tools/modules_doc.py` from the module contract headers (`dev/docs/ARCHITECTURE_PLAN.md`, "
             "\"Module contract header\") and the dependency map of `dev/tools/layers.py`. Do not edit by hand: change "
             "the header in the Lua file and re-run the tool.")
    w.append("")
    w.append("%d files in the TOC, %d with a header, %d without (\"no header yet\", with the functions other files call "
             "in them: the API to document)." % (len(dm.files), len(hs), len(dm.files) - len(hs)))
    w.append("")
    by_layer = collections.OrderedDict((n, []) for n in sorted(cfg.layer_names))
    for f in dm.files:
        by_layer.setdefault(dm.layer(f), []).append(f)
    for lay, files in by_layer.items():
        if not files:
            continue
        w.append("## Layer %s · %s" % (lay, cfg.layer_names.get(lay, "unmapped")))
        w.append("")
        with_h = [f for f in files if f in hs]
        for f in sorted(with_h, key=lambda f: (hs[f].module.lower(), f)):
            h = hs[f]
            w.append("### %s%s" % (h.module, " (%s)" % h.part if h.part else ""))
            w.append("")
            w.append("`%s` · Layer %d%s · feature %s · %d lines" % (f, h.layer, " · " + h.folder if h.folder else "",
                                                                   dm.feature(f), dm.info[f].lines))
            w.append("")
            for k, v in (("Owns", h.owns), ("Uses", h.uses_text), ("Fires", h.fires)):
                if v:
                    w.append("- **%s** %s" % (k, v))
            if h.api:
                w.append("")
                w.append("| Function | Args | Contract |")
                w.append("|---|---|---|")
                for name, args, rest, _ in h.api:
                    w.append("| `%s` | `%s` | %s |" % (name, _md(args), _md(rest)))
            w.append("")
        without = [f for f in files if f not in hs]
        if without:
            w.append("### No header yet (%d)" % len(without))
            w.append("")
            w.append("| File | Feature | Lines | Called from other files (symbol, calling files) |")
            w.append("|---|---|---|---|")
            for f in without:
                api = dm.external_api(f)
                syms = sorted(api.items(), key=lambda kv: (-kv[1], kv[0]))
                txt = ", ".join("`%s`%s" % (dm.display(s), "×%d" % n if n > 1 else "") for s, n in syms) or "-"
                w.append("| `%s` | %s | %d | %s |" % (f, dm.feature(f), dm.info[f].lines, txt))
            w.append("")
    return "\n".join(w).rstrip() + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--addon")
    ap.add_argument("--config")
    ap.add_argument("--out", default=DOC_PATH)
    ap.add_argument("--check", action="store_true", help="print the header warnings instead of writing the doc")
    args = ap.parse_args(argv)
    dm = layers.build(args.addon, layers.load_config(args.config))
    if args.check:
        rows = check(dm)
        for f, ln, cat, nm, tx in rows:
            print("%s:%d: %s" % (f, ln, tx))
        c = collections.Counter(r[2] for r in rows)
        print("-- headers: %d file(s), %d warning(s) [%s]" % (len(dm.files), len(rows),
                                                            ", ".join("%s=%d" % kv for kv in sorted(c.items()))))
        return 0
    text = render(dm)
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)
    print("modules_doc: %d files, %d with a header -> %s (%d KB)" % (
        len(dm.files), len(headers(dm)), args.out, len(text.encode("utf-8")) // 1024))
    return 0


if __name__ == "__main__":
    sys.exit(main())
