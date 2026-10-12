#!/usr/bin/env python
"""DisasterZone layer map and layer lint (dev/docs/ARCHITECTURE_PLAN.md, phase P0).

Builds a file-level dependency map of the addon from its TOC: who calls whom through `ns.X`, local aliases
(`local X = ns.Y`, `local X = ns.Y or {}`, `local A, B = ns.A, ns.B`), function aliases (`local Now = ns.Util.Now`),
`ns:NewModule("X")` owners and method owners (`function Alias:Method`, `Alias.Method = function`, `ns.X.Y = ...`) in
whichever file defines them, so a module split across files resolves to the file that really holds the function.
Comments and string contents are ignored.

Each file gets a layer and a feature from tools/layers.json (prefix rules + per-file overrides + feature rules; the
same config covers today's flat folders and the target folders of P4). Three kinds of violations:
    up     a file calls a file in a higher layer
    kit    a UI kit file names a feature (calls a feature's logic or pages)
    order  at the logic level (L2-L3) a feature calls a later feature, or a sibling of its own rank
Today's violations are allowlisted in tools/layers_allow.json (file -> file pairs with the symbols). The list only
shrinks: check.py --layers reports NEW violations (a new pair, or a new symbol on an allowed pair) and entries that no
longer occur; --prune drops those.

Usage (luaenv python; the addon is $DISASTERZONE_ADDON_DIR or the live folder):
    layers.py --report                 summary: upward edges by layer pair, feature cycles, logic+wire files, Core->UI
    layers.py --check [--strict]       new violations (exit 1 with --strict) + stale allowlist entries
    layers.py --baseline               (re)write tools/layers_allow.json from today's code
    layers.py --prune                  drop allowlist entries / symbols that no longer occur (never adds)
    layers.py --file Core/Util.lua     edges out of and into one file, with layers, features and symbols
    layers.py --rename MOVES.json      rewrite allowlist paths after a move ({old: new} or [[old, new], ...])
    layers.py --json OUT.json          write the whole map
Options: --addon DIR, --config PATH, --allow PATH.
"""
import argparse
import bisect
import collections
import json
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))

LIVE_ADDON_DIR = r"C:\World of Warcraft\_anniversary_\Interface\AddOns\DisasterZone"
CONFIG_PATH = os.path.join(HERE, "layers.json")
ALLOW_PATH = os.path.join(HERE, "layers_allow.json")
KINDS = ("up", "kit", "order")


def default_addon_dir():
    return os.environ.get("DISASTERZONE_ADDON_DIR") or LIVE_ADDON_DIR


# ---------------------------------------------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------------------------------------------
class Config:
    """tools/layers.json: layer per path prefix (longest wins) and per file, feature rules (first regex wins; the
    feature may use the match's groups, e.g. "\\1"), the feature order at the logic level, the kit rule and the
    wire modules."""

    def __init__(self, data):
        self.data = data
        self.layer_names = {int(k): v for k, v in data["layers"].items()}
        self.prefixes = sorted(data["prefixes"].items(), key=lambda kv: -len(kv[0]))
        self.files = dict(data.get("files", {}))
        self.feature_rules = [(re.compile(rx), feat) for rx, feat in data["features"]]
        self.order = [list(g) for g in data["feature_order"]]
        self.rank = {f: i for i, grp in enumerate(self.order) for f in grp}
        self.logic_layers = set(data.get("logic_layers", [2, 3]))
        kit = data.get("kit", {})
        self.kit_feature = kit.get("feature", "Kit")
        self.kit_forbidden = set(kit.get("forbidden", ()))
        self.kit_min_layer = kit.get("min_target_layer", 2)
        self.wire = {mod: re.compile(rx) for mod, rx in data.get("wire", {}).items()}
        self._lcache, self._fcache = {}, {}

    def layer(self, path):
        if path in self._lcache:
            return self._lcache[path]
        lay = self.files.get(path)
        if lay is None:
            for pre, n in self.prefixes:
                if path.startswith(pre):
                    lay = n
                    break
        self._lcache[path] = lay
        return lay

    def feature(self, path):
        if path in self._fcache:
            return self._fcache[path]
        feat = "?"
        for rx, f in self.feature_rules:
            m = rx.search(path)
            if m:
                feat = m.expand(f) if "\\" in f else f
                break
        self._fcache[path] = feat
        return feat

    def layer_label(self, n):
        return "L%s %s" % (n, self.layer_names.get(n, "?")) if n is not None else "L? unmapped"


def load_config(path=None):
    with open(path or CONFIG_PATH, encoding="utf-8") as fh:
        return Config(json.load(fh))


# ---------------------------------------------------------------------------------------------------------------
# Reading the addon
# ---------------------------------------------------------------------------------------------------------------
def find_toc(addon_dir):
    name = os.path.basename(os.path.normpath(addon_dir)) + ".toc"
    p = os.path.join(addon_dir, name)
    if os.path.exists(p):
        return p
    tocs = sorted(f for f in os.listdir(addon_dir) if f.lower().endswith(".toc"))
    if not tocs:
        raise FileNotFoundError("no .toc in %s" % addon_dir)
    return os.path.join(addon_dir, tocs[0])


def toc_files(addon_dir):
    """Lua files the TOC loads, in load order (Libs/ excluded), as forward-slash paths relative to the addon."""
    out = []
    with open(find_toc(addon_dir), encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            p = line.replace("\\", "/")
            if not p.lower().endswith(".lua") or p.startswith("Libs/") or "/Libs/" in p:
                continue
            if os.path.isfile(os.path.join(addon_dir, p)):
                out.append(p)
    return out


def read_text(path):
    with open(path, "rb") as fh:
        b = fh.read()
    if b.startswith(b"\xef\xbb\xbf"):
        b = b[3:]
    return b.decode("utf-8", "replace").replace("\r\n", "\n")


def split_top(s):
    """Split an expression list on top-level commas."""
    out, depth, cur = [], 0, []
    for ch in s:
        if ch in "({[":
            depth += 1
        elif ch in ")}]":
            depth -= 1
        if ch == "," and depth == 0:
            out.append("".join(cur).strip())
            cur = []
        else:
            cur.append(ch)
    out.append("".join(cur).strip())
    return out


_MASK_RE = re.compile(r"""(?P<lc>--\[(?P<e1>=*)\[.*?\](?P=e1)\])|(?P<lcu>--\[=*\[.*)|(?P<c>--[^\n]*)"""
                      r"""|(?P<lo>\[(?P<e2>=*)\[)(?P<ls>.*?)\](?P=e2)\]|(?P<lsu>\[=*\[)(?P<lsr>.*)"""
                      r"""|(?P<q>["'])(?P<qs>(?:\\.|(?!(?P=q))[^\\\n])*)(?P<qc>(?P=q))?""", re.S)


def _blank(seg):
    if "\n" not in seg:
        return " " * len(seg)
    return "\n".join(" " * len(x) for x in seg.split("\n"))


def _mask_repl(m):
    if m.group("q"):
        return m.group("q") + _blank(m.group("qs")) + (m.group("qc") or "")
    if m.group("lo"):
        t = m.group(0)
        n = len(m.group("lo"))
        return t[:n] + _blank(m.group("ls")) + t[len(t) - n:]
    if m.group("lsu"):
        return m.group("lsu") + _blank(m.group("lsr"))
    return _blank(m.group(0))      # a comment


def mask(text):
    """Comments -> spaces, string contents -> spaces (quotes and long brackets kept); same length and lines."""
    return _MASK_RE.sub(_mask_repl, text)


RE_LOCAL = re.compile(r"^[ \t]*local[ \t]+([A-Za-z_]\w*(?:[ \t]*,[ \t]*[A-Za-z_]\w*)*)[ \t]*=[ \t]*([^\n]*)$", re.M)
RE_EXPR_MOD = re.compile(r"^ns\s*\.\s*([A-Za-z_]\w*)(?:\s+or\b.*)?$")
RE_EXPR_FN = re.compile(r"^ns\s*\.\s*([A-Za-z_]\w*)\s*\.\s*([A-Za-z_]\w*)$")
RE_NEWMOD = re.compile(r"""NewModule[ \t]*\([ \t]*["'](\w+)["']""")
RE_NEWMOD_HEAD = re.compile(r"""(?:\blocal[ \t]+([A-Za-z_]\w*)[ \t]*=[ \t]*)?\bns[ \t]*:[ \t]*$""")
# definitions (all start with a literal so the scan is fast; the char before is checked by hand)
RE_DEF = re.compile(r"function\s+([A-Za-z_]\w*)\s*([.:])\s*([A-Za-z_]\w*)(?:\s*([.:])\s*([A-Za-z_]\w*))?"
                    r"(?:\s*[.:]\s*[A-Za-z_]\w*)*\s*\(")
RE_DEF_ASSIGN = re.compile(r"^([ \t]*)([A-Za-z_]\w*)\s*\.\s*([A-Za-z_]\w*)(?:\s*\.\s*([A-Za-z_]\w*))?\s*=(?!=)\s*(function\b)?",
                           re.M)
RE_NS = re.compile(r"ns\s*([.:])\s*([A-Za-z_]\w*)(?:\s*([.:])\s*([A-Za-z_]\w*))?(\s*=(?!=))?")
RE_ASSIGN_NAME = re.compile(r"[ \t]*([A-Za-z_]\w*)[ \t]*(?=;|\n|$|end\b)")
LUA_WORDS = set("and break do else elseif end false for function if in local nil not or repeat return then true "
                "until while".split())
RE_NAME = re.compile(r"[A-Za-z_]\w*")
RE_FUNCTION_TAIL = re.compile(r"(?<![\w.:])function\s+$")
_NOT_BEFORE = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.:")


def _free(text, pos):
    """True when the token at pos is not the tail of a longer name or a field (x.ns, x:ns, abcns)."""
    return pos == 0 or text[pos - 1] not in _NOT_BEFORE


class Edge:
    __slots__ = ("n", "syms", "symline", "line")

    def __init__(self):
        self.n = 0
        self.syms = collections.Counter()
        self.symline = {}
        self.line = None


class FileInfo:
    __slots__ = ("path", "order", "lines", "layer", "feature", "aliases", "fnaliases", "raw", "masked", "nl")


class DepMap:
    """files (TOC order), info[path] -> FileInfo, owner_mod[X] -> path, owner_meth[(X, m)] -> path,
    defs[path] -> {(X, m)}, modules (names that are modules), refs[path] -> [(line, mod, meth, sep, tgt)],
    edges[(src, dst)] -> Edge, unresolved Counter(mod)."""

    def __init__(self):
        self.files, self.info = [], {}
        self.owner_mod, self.owner_meth = {}, {}
        self.defs = collections.defaultdict(set)
        self.newmods = set()
        self.modules = set()
        self.refs = collections.defaultdict(list)
        self.edges = collections.defaultdict(Edge)
        self.unresolved = collections.Counter()
        self.colon = set()   # (X, m) seen called with ':'
        self.config = None

    def layer(self, path):
        return self.info[path].layer if path in self.info else self.config.layer(path)

    def feature(self, path):
        return self.info[path].feature if path in self.info else self.config.feature(path)

    def out_edges(self, path):
        return {d: e for (s, d), e in self.edges.items() if s == path}

    def in_edges(self, path):
        return {s: e for (s, d), e in self.edges.items() if d == path}

    def called_modules(self, path):
        """Modules a file calls in another file (from the refs)."""
        return {mod for _, mod, _, _, tgt in self.refs.get(path, ()) if tgt and tgt != path and mod in self.modules}

    def external_api(self, path):
        """Symbols other files reach in this file: {"Mod.meth": number of calling files}."""
        c = collections.Counter()
        for s, e in self.in_edges(path).items():
            for sym in e.syms:
                c[sym] += 1
        return c

    def display(self, sym):
        if "." in sym:
            mod, meth = sym.split(".", 1)
            if (mod, meth) in self.colon:
                return "%s:%s" % (mod, meth)
        return sym


def _line_of(nl, pos):
    return bisect.bisect_right(nl, pos) + 1


def build(addon_dir=None, config=None, files=None):
    """Parse every TOC file and resolve the references. files: optional explicit list (relative paths)."""
    addon_dir = addon_dir or default_addon_dir()
    cfg = config or load_config()
    dm = DepMap()
    dm.config = cfg
    dm.files = list(files) if files is not None else toc_files(addon_dir)
    for i, f in enumerate(dm.files):
        fi = FileInfo()
        fi.path, fi.order = f, i
        fi.raw = read_text(os.path.join(addon_dir, f))
        fi.masked = mask(fi.raw)
        fi.nl = [m.start() for m in re.finditer("\n", fi.raw)]
        fi.lines = len(fi.nl) + 1
        fi.layer, fi.feature = cfg.layer(f), cfg.feature(f)
        fi.aliases, fi.fnaliases = {}, {}
        dm.info[f] = fi

    # pass 1: module owners (NewModule, function ns.X / ns:X, ns.X = ...), aliases, ns.X.Y definitions, ns refs
    decl_spans, skip_pos, ns_refs, ns_member_defs = {}, {}, {}, {}
    mod_cands = collections.defaultdict(list)    # X -> [(rank, toc order, file)]
    for f in dm.files:
        fi = dm.info[f]
        raw, mk = fi.raw, fi.masked
        spans, skip, refs, mdefs = set(), set(), [], []
        for m in RE_NEWMOD.finditer(raw):
            if mk[m.start()] == " ":      # inside a comment or a string
                continue
            ls = mk.rfind("\n", 0, m.start()) + 1
            hm = RE_NEWMOD_HEAD.search(mk, ls, m.start())
            if not hm:
                continue
            name = m.group(1)
            dm.newmods.add(name)
            mod_cands[name].append((0, fi.order, f))
            if hm.group(1):
                fi.aliases.setdefault(hm.group(1), name)
        for m in RE_LOCAL.finditer(mk):
            names = []
            for nm in RE_NAME.finditer(m.group(1)):
                names.append(nm.group(0))
                spans.add(m.start(1) + nm.start())
            exprs = split_top(m.group(2).strip())
            cur = m.start(2)
            for k, e in enumerate(exprs):
                p = mk.find(e, cur, m.end(2) + 1) if e else -1
                if p >= 0:
                    cur = p + len(e)
                if k >= len(names):
                    continue
                name = names[k]
                fm = RE_EXPR_FN.match(e)
                mm = None if fm else RE_EXPR_MOD.match(e)
                if (fm or mm) and p >= 0:
                    skip.add(p)       # the alias declaration itself is not a call
                if fm:
                    fi.fnaliases.setdefault(name, (fm.group(1), fm.group(2)))
                elif mm and name != "ns":
                    fi.aliases.setdefault(name, mm.group(1))
        for m in RE_NS.finditer(mk):
            pos = m.start()
            if not _free(mk, pos):
                continue
            sep1, x, sep2, y, assign = m.groups()
            if sep1 == ":":
                sep2 = y = None
            is_fn = RE_FUNCTION_TAIL.search(mk, max(0, pos - 24), pos) is not None
            if is_fn:                                   # function ns.X(  function ns:X(  function ns.X:Y(
                if y:
                    mdefs.append((x, y, 1))
                else:
                    mod_cands[x].append((1, fi.order, f))
                continue
            if assign and sep1 == ".":
                if y and sep2 == ".":                   # ns.X.Y = ...
                    mdefs.append((x, y, 2))
                    continue
                if not y:                               # ns.X = ...
                    mod_cands[x].append((2, fi.order, f))
                    vm = RE_ASSIGN_NAME.match(mk, m.end())
                    if vm and vm.group(1) not in LUA_WORDS and vm.group(1) != "ns":
                        fi.aliases.setdefault(vm.group(1), x)   # local M = {} ... ns.X = M
                    continue
            if pos in skip:
                continue
            if sep1 == ":":
                refs.append((pos, x, None, ":", None))
            else:
                refs.append((pos, x, y, sep2 if y else ".", None))
        decl_spans[f], skip_pos[f], ns_refs[f], ns_member_defs[f] = spans, skip, refs, mdefs
    # owner of a module: NewModule, else the first `function ns.X`, else the first `ns.X = ...` (TOC order)
    dm.owner_mod = {x: min(c)[2] for x, c in mod_cands.items()}

    # pass 2: method / field owners. A definition in the module's own file wins, then the first `function X:Y`
    # statement in TOC order, then the first assignment (X.Y = function / top-level X.Y = value / ns.X.Y = value),
    # so a hook installed by another file (Perf wrapping Comm.Send) does not steal the method.
    meth_cands = collections.defaultdict(list)
    for f in dm.files:
        fi = dm.info[f]
        mk, al = fi.masked, fi.aliases

        def own(mod, meth, rank):
            if dm.owner_mod.get(mod) == f:
                rank = 0
            meth_cands[(mod, meth)].append((rank, fi.order, f))
            dm.defs[f].add((mod, meth))

        for x, y, rank in ns_member_defs[f]:
            own(x, y, rank)
        for m in RE_DEF.finditer(mk):
            if not _free(mk, m.start()):
                continue
            a = m.group(1)
            if a in al:
                own(al[a], m.group(3), 1)
        for m in RE_DEF_ASSIGN.finditer(mk):
            a = m.group(2)
            if a in al and not m.group(4) and (m.group(5) or not m.group(1)):
                own(al[a], m.group(3), 2)
    dm.owner_meth = {k: min(c)[2] for k, c in meth_cands.items()}
    dm.modules = set(dm.newmods) | {mod for mod, _ in dm.owner_meth if mod[:1].isupper()}

    # pass 3: references
    for f in dm.files:
        fi = dm.info[f]
        mk, nl = fi.masked, fi.nl
        found = list(ns_refs[f])   # (pos, mod, meth, sep, symbol)
        for a, mod in fi.aliases.items():
            if a not in mk:
                continue
            for m in re.finditer(re.escape(a) + r"\s*([.:])\s*([A-Za-z_]\w*)", mk):
                if _free(mk, m.start()):
                    found.append((m.start(), mod, m.group(2), m.group(1), "%s%s%s" % (mod, m.group(1), m.group(2))))
        for a, mod in fi.aliases.items():
            if mod in dm.modules or a not in mk:
                continue
            # an alias of a namespace function / value (local SafeCall = ns.SafeCall): its bare uses are refs
            for m in re.finditer(re.escape(a) + r"(?!\w)(?!\s*[.:])(?!\s*=[^=])", mk):
                if m.start() in decl_spans[f] or not _free(mk, m.start()):
                    continue
                found.append((m.start(), mod, None, ".", None))
        for a, (mod, meth) in fi.fnaliases.items():
            for m in re.finditer(re.escape(a) + r"(?!\w)(?!\s*=[^=])", mk):
                if m.start() in decl_spans[f] or not _free(mk, m.start()):
                    continue
                found.append((m.start(), mod, meth, ".", "%s.%s" % (mod, meth)))
        found.sort()
        for pos, mod, meth, sep, sym in found:
            ln = _line_of(nl, pos)
            if meth and sep == ":":
                dm.colon.add((mod, meth))
            tgt = dm.owner_meth.get((mod, meth)) if meth else None
            if tgt is None:
                tgt = dm.owner_mod.get(mod)
            dm.refs[f].append((ln, mod, meth, sep, tgt))
            if tgt is None:
                dm.unresolved[mod] += 1
                continue
            if tgt == f:
                continue
            if sym is None:                             # a ns.X / ns:X reference
                if meth:
                    sym = "%s.%s" % (mod, meth)
                elif mod in dm.modules:
                    sym = mod
                else:
                    sym = "ns." + mod                   # a namespace function / field (ns:Fire, ns.db)
                    if sep == ":":
                        dm.colon.add(("ns", mod))
            else:
                sym = sym.replace(":", ".", 1)
            e = dm.edges[(f, tgt)]
            e.n += 1
            e.syms[sym] += 1
            if sym not in e.symline or ln < e.symline[sym]:
                e.symline[sym] = ln
            if e.line is None or ln < e.line:
                e.line = ln
    return dm


# ---------------------------------------------------------------------------------------------------------------
# Violations
# ---------------------------------------------------------------------------------------------------------------
class Violation:
    __slots__ = ("kind", "src", "dst", "syms", "symline", "line", "n", "ls", "ld", "fs", "fd")

    def key(self):
        return (self.kind, self.src, self.dst)

    def describe(self, cfg, syms=None):
        syms = sorted(syms if syms is not None else self.syms)
        shown = ", ".join(syms[:6]) + (" +%d more" % (len(syms) - 6) if len(syms) > 6 else "")
        if self.kind == "up":
            why = "L%s %s calls L%s %s" % (self.ls, cfg.layer_names.get(self.ls, "?"), self.ld,
                                         cfg.layer_names.get(self.ld, "?"))
        elif self.kind == "kit":
            why = "the UI kit names %s" % self.fd
        else:
            why = "%s calls %s (feature order)" % (self.fs, self.fd)
        return "%s %s -> %s: %s [%s]" % (self.kind, self.src, self.dst, why, shown)


def classify(cfg, ls, ld, fs, fd):
    if ls is not None and ld is not None and ld > ls:
        return "up"
    if fs == cfg.kit_feature and fd in cfg.kit_forbidden and ld is not None and ld >= cfg.kit_min_layer:
        return "kit"
    if (ls in cfg.logic_layers and ld in cfg.logic_layers and fs != fd and fs in cfg.rank and fd in cfg.rank
            and cfg.rank[fd] >= cfg.rank[fs]):
        return "order"
    return None


def violations(dm, cfg=None):
    cfg = cfg or dm.config
    out = []
    for (src, dst), e in sorted(dm.edges.items()):
        ls, ld, fs, fd = dm.layer(src), dm.layer(dst), dm.feature(src), dm.feature(dst)
        kind = classify(cfg, ls, ld, fs, fd)
        if not kind:
            continue
        v = Violation()
        v.kind, v.src, v.dst = kind, src, dst
        v.syms, v.symline, v.line, v.n = set(e.syms), dict(e.symline), e.line, e.n
        v.ls, v.ld, v.fs, v.fd = ls, ld, fs, fd
        out.append(v)
    return out


# ---------------------------------------------------------------------------------------------------------------
# Allowlist
# ---------------------------------------------------------------------------------------------------------------
def load_allow(path=None):
    path = path or ALLOW_PATH
    if not os.path.exists(path):
        return {"entries": []}
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def allow_index(allow):
    return {(e["kind"], e["from"], e["to"]): set(e.get("syms", ())) for e in allow.get("entries", ())}


def compare(viols, allow):
    """-> (new, stale). new: [(Violation, new_syms)] (new_syms = all syms when the pair is new).
    stale: [(key, gone_syms, whole)] whole=True when the pair no longer occurs at all."""
    idx = allow_index(allow)
    new, seen = [], set()
    for v in viols:
        k = v.key()
        seen.add(k)
        if k not in idx:
            new.append((v, set(v.syms)))
            continue
        extra = v.syms - idx[k]
        if extra:
            new.append((v, extra))
    stale = []
    cur = {v.key(): v.syms for v in viols}
    for k, syms in sorted(idx.items()):
        if k not in seen:
            stale.append((k, set(syms), True))
        else:
            gone = syms - cur[k]
            if gone:
                stale.append((k, gone, False))
    return new, stale


def _entry(v, cfg, syms=None):
    return {"kind": v.kind, "from": v.src, "to": v.dst,
            "why": "L%s->L%s %s->%s" % (v.ls, v.ld, v.fs, v.fd),
            "syms": sorted(syms if syms is not None else v.syms)}


def _write_allow(entries, path, note):
    entries = sorted(entries, key=lambda e: (KINDS.index(e["kind"]) if e["kind"] in KINDS else 9, e["from"], e["to"]))
    data = {"_doc": ["Today's layer violations (tools/layers.py). This list only shrinks: check.py --layers reports "
                     "violations not listed here, and entries or symbols that no longer occur (--prune drops them).",
                     "Regenerate from scratch only on purpose: tools/layers.py --baseline."],
            "generated": time.strftime("%Y-%m-%d %H:%M:%S"), "note": note,
            "counts": dict(collections.Counter(e["kind"] for e in entries)),
            "entries": entries}
    head = json.dumps({k: v for k, v in data.items() if k != "entries"}, indent=1, ensure_ascii=False)
    rows = ",\n".join("  " + json.dumps(e, ensure_ascii=False) for e in entries)   # one entry per line: small diffs
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(head[:-2] + ',\n "entries": [\n' + rows + "\n ]\n}\n")
    return data


def baseline(viols, cfg, path=None):
    return _write_allow([_entry(v, cfg) for v in viols], path or ALLOW_PATH, "baseline")


def prune(viols, allow, path=None):
    """Drop entries and symbols that no longer occur. Never adds anything. Returns (data, removed_pairs, removed_syms)."""
    cur = {v.key(): v.syms for v in viols}
    kept, rp, rs = [], 0, 0
    for e in allow.get("entries", ()):
        k = (e["kind"], e["from"], e["to"])
        if k not in cur:
            rp += 1
            continue
        syms = [s for s in e.get("syms", ()) if s in cur[k]]
        rs += len(e.get("syms", ())) - len(syms)
        ne = dict(e)
        ne["syms"] = sorted(syms)
        kept.append(ne)
    return _write_allow(kept, path or ALLOW_PATH, "pruned"), rp, rs


def rename(mapping, allow, path=None):
    """Rewrite allowlist paths after a move. mapping: {old: new}."""
    out = []
    for e in allow.get("entries", ()):
        ne = dict(e)
        ne["from"] = mapping.get(e["from"], e["from"])
        ne["to"] = mapping.get(e["to"], e["to"])
        out.append(ne)
    return _write_allow(out, path or ALLOW_PATH, "renamed")


def load_moves(path):
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    if isinstance(data, dict) and "moves" in data:
        data = data["moves"]
    if isinstance(data, dict):
        return {k.replace("\\", "/"): v.replace("\\", "/") for k, v in data.items() if isinstance(v, str)}
    out = {}
    for item in data:
        if isinstance(item, dict):
            out[item["from"].replace("\\", "/")] = item["to"].replace("\\", "/")
        else:
            out[item[0].replace("\\", "/")] = item[1].replace("\\", "/")
    return out


# ---------------------------------------------------------------------------------------------------------------
# Lint (shared with check.py)
# ---------------------------------------------------------------------------------------------------------------
def lint(dm, allow, only=None, strict=False, stale_too=True):
    """-> list of (path, line, severity, category, name, text) in check.py's Report format.
    only: set of paths to report new violations for (None = all). Stale entries only when stale_too."""
    cfg = dm.config
    viols = violations(dm, cfg)
    new, stale = compare(viols, allow)
    sev = "ERROR" if strict else "WARN"
    out = []
    idx = allow_index(allow)
    for v, syms in new:
        if only is not None and v.src not in only:
            continue
        line = min(v.symline.get(s, v.line or 0) for s in syms) if syms else (v.line or 0)
        tag = " (new symbols on an allowed pair)" if v.key() in idx else ""
        out.append((v.src, line, sev, "layers", "%s>%s" % (v.kind, v.dst),
                    "%s LAYERS %s%s" % (sev, v.describe(cfg, syms), tag)))
    if stale_too:
        for (kind, src, dst), syms, whole in stale:
            what = "no longer occurs" if whole else "symbols no longer used: %s" % ", ".join(sorted(syms))
            out.append((src, 0, "WARN", "layers-stale", "%s>%s" % (kind, dst),
                        "WARN LAYERS-STALE allowlist entry %s %s -> %s %s (check.py --prune drops it)"
                        % (kind, src, dst, what)))
    return out, viols, new, stale


# ---------------------------------------------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------------------------------------------
def _short(p):
    return p[:-4] if p.endswith(".lua") else p


def wire_refs(dm, path):
    """{"send/register...": n} wire calls of one file (Comm sends/registers, DigestSync)."""
    c = collections.Counter()
    for _, mod, meth, _, tgt in dm.refs.get(path, ()):
        rx = dm.config.wire.get(mod)
        if rx is None or tgt == path:
            continue
        if meth and rx.search(meth):
            c["%s.%s" % (mod, meth) if meth else mod] += 1
    return c


def report(dm, out=sys.stdout):
    cfg = dm.config
    w = lambda s="": print(s, file=out)  # noqa: E731
    viols = violations(dm, cfg)
    by_layer = collections.OrderedDict()
    for f in dm.files:
        fi = dm.info[f]
        by_layer.setdefault(fi.layer, [0, 0])
        by_layer[fi.layer][0] += 1
        by_layer[fi.layer][1] += fi.lines
    w("== map: %d files, %d file->file edges, %d resolved refs, %d unresolved refs ==" % (
        len(dm.files), len(dm.edges), sum(e.n for e in dm.edges.values()), sum(dm.unresolved.values())))
    for lay in sorted(by_layer, key=lambda x: (x is None, x)):
        n, ln = by_layer[lay]
        w("  %-18s %4d files %8d lines" % (cfg.layer_label(lay), n, ln))
    unm = [f for f in dm.files if dm.info[f].layer is None]
    unf = [f for f in dm.files if dm.info[f].feature == "?"]
    if unm:
        w("  UNMAPPED (no layer): %s" % ", ".join(unm))
    if unf:
        w("  NO FEATURE TAG: %s" % ", ".join(unf))
    if dm.unresolved:
        w("  unresolved ns.X (not defined in any TOC file): %s" % ", ".join(
            "%s x%d" % kv for kv in dm.unresolved.most_common(12)))
    stale_over = [p for p in cfg.files if p not in dm.info]
    if stale_over:
        w("  layers.json 'files' overrides naming files not in the TOC (after a move: delete them): %s"
          % ", ".join(stale_over))
    kinds = collections.Counter(v.kind for v in viols)
    w()
    w("== violations: %d file pairs (%s), %d refs ==" % (
        len(viols), ", ".join("%s=%d" % (k, kinds[k]) for k in KINDS), sum(v.n for v in viols)))

    w()
    w("== upward edges by layer pair (file pairs, refs) ==")
    pairs = collections.defaultdict(list)
    for v in viols:
        if v.kind == "up":
            pairs[(v.ls, v.ld)].append(v)
    for (a, b) in sorted(pairs):
        vs = pairs[(a, b)]
        w("  %s -> %s: %d pairs, %d refs" % (cfg.layer_label(a), cfg.layer_label(b), len(vs), sum(v.n for v in vs)))
        for v in sorted(vs, key=lambda v: -v.n)[:8]:
            w("      %-30s -> %-28s x%-3d %s" % (_short(v.src), _short(v.dst), v.n, ", ".join(sorted(v.syms)[:4])))
        if len(vs) > 8:
            w("      ... %d more" % (len(vs) - 8))

    w()
    w("== UI kit naming features ==")
    for v in sorted((v for v in viols if v.kind == "kit"), key=lambda v: -v.n):
        w("  %-30s -> %-28s %-10s x%-3d %s" % (_short(v.src), _short(v.dst), v.fd, v.n, ", ".join(sorted(v.syms)[:4])))

    w()
    w("== feature order at the logic level (L%s): later/sibling feature calls ==" % "-".join(
        str(x) for x in sorted(cfg.logic_layers)))
    fo = collections.defaultdict(list)
    for v in viols:
        if v.kind == "order":
            fo[(v.fs, v.fd)].append(v)
    for (a, b), vs in sorted(fo.items(), key=lambda kv: -sum(v.n for v in kv[1])):
        w("  %-10s -> %-10s %3d refs  %s" % (a, b, sum(v.n for v in vs), ", ".join(
            "%s->%s" % (_short(v.src).split("/")[-1], _short(v.dst).split("/")[-1]) for v in vs[:6])))

    w()
    w("== feature cycles at the logic level (both directions between logic files) ==")
    fe = collections.defaultdict(lambda: [0, set()])
    fpair_files = collections.defaultdict(set)
    for (s, d), e in dm.edges.items():
        if dm.layer(s) in cfg.logic_layers and dm.layer(d) in cfg.logic_layers:
            a, b = dm.feature(s), dm.feature(d)
            if a != b:
                fe[(a, b)][0] += e.n
                fe[(a, b)][1].add("%s->%s" % (_short(s).split("/")[-1], _short(d).split("/")[-1]))
            fpair_files[(s, d)] = e.n
    cyc = sorted({tuple(sorted(k)) for k in fe if (k[1], k[0]) in fe}, key=lambda k: -(fe[k][0] + fe[(k[1], k[0])][0]))
    for a, b in cyc:
        w("  %s <-> %s   %d / %d refs" % (a, b, fe[(a, b)][0], fe[(b, a)][0]))
        w("      %s -> %s: %s" % (a, b, ", ".join(sorted(fe[(a, b)][1])[:6])))
        w("      %s -> %s: %s" % (b, a, ", ".join(sorted(fe[(b, a)][1])[:6])))
    mutual = sorted({tuple(sorted(k)) for k in fpair_files if (k[1], k[0]) in fpair_files})
    w("  file pairs calling each other at the logic level: %d" % len(mutual))
    for a, b in mutual:
        w("      %s <-> %s  (%d / %d)" % (_short(a), _short(b), fpair_files[(a, b)], fpair_files[(b, a)]))

    w()
    w("== files mixing logic + wire (L0-L3 files calling %s) ==" % " / ".join(
        "%s(%s)" % (m, rx.pattern) for m, rx in cfg.wire.items()))
    rows = []
    for f in dm.files:
        lay = dm.layer(f)
        if lay is None or lay > 3:
            continue
        c = wire_refs(dm, f)
        if c:
            rows.append((f, dm.info[f].lines, sum(c.values()), c))
    for f, ln, n, c in sorted(rows, key=lambda r: -r[1]):
        w("  %-30s %6d lines  %3d wire refs  %s" % (_short(f), ln, n, ", ".join(
            "%s x%d" % kv for kv in c.most_common(4))))
    w("  %d files" % len(rows))

    w()
    w("== Core files calling the UI (L0-L4 -> L5+) ==")
    rows = [v for v in viols if v.kind == "up" and v.ls is not None and v.ls <= 4 and v.ld >= 5]
    for v in sorted(rows, key=lambda v: (v.src, v.dst)):
        w("  %-30s -> %-28s x%-3d %s" % (_short(v.src), _short(v.dst), v.n, ", ".join(sorted(v.syms)[:5])))
    w("  %d edges, %d refs, %d files" % (len(rows), sum(v.n for v in rows), len({v.src for v in rows})))
    return viols


def file_report(dm, path, out=sys.stdout):
    cfg = dm.config
    w = lambda s="": print(s, file=out)  # noqa: E731
    fi = dm.info[path]
    w("%s  %s  feature %s  %d lines" % (path, cfg.layer_label(fi.layer), fi.feature, fi.lines))
    w("aliases: %s" % ", ".join("%s=%s" % kv for kv in sorted(fi.aliases.items())))
    if fi.fnaliases:
        w("function aliases: %s" % ", ".join("%s=%s.%s" % (k, a, b) for k, (a, b) in sorted(fi.fnaliases.items())))
    w("calls:")
    for d, e in sorted(dm.out_edges(path).items(), key=lambda kv: -kv[1].n):
        kind = classify(cfg, fi.layer, dm.layer(d), fi.feature, dm.feature(d))
        w("  -> %-30s %-14s %-10s x%-3d %s%s" % (d, cfg.layer_label(dm.layer(d)), dm.feature(d), e.n,
                                                  ", ".join(sorted(e.syms)[:8]), ("   ** %s" % kind) if kind else ""))
    w("called by:")
    for s, e in sorted(dm.in_edges(path).items(), key=lambda kv: -kv[1].n):
        w("  <- %-30s %-14s x%-3d %s" % (s, cfg.layer_label(dm.layer(s)), e.n, ", ".join(sorted(e.syms)[:8])))


def to_json(dm):
    cfg = dm.config
    return {"files": [{"f": f, "layer": dm.info[f].layer, "feature": dm.info[f].feature, "lines": dm.info[f].lines,
                       "aliases": dm.info[f].aliases} for f in dm.files],
            "edges": [{"from": s, "to": d, "n": e.n, "syms": dict(e.syms),
                       "kind": classify(cfg, dm.layer(s), dm.layer(d), dm.feature(s), dm.feature(d))}
                      for (s, d), e in sorted(dm.edges.items())],
            "unresolved": dict(dm.unresolved)}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--addon", help="addon folder (default: $DISASTERZONE_ADDON_DIR or the live folder)")
    ap.add_argument("--config", help="layers.json (default: tools/layers.json)")
    ap.add_argument("--allow", help="allowlist (default: tools/layers_allow.json)")
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--report", action="store_true")
    g.add_argument("--check", action="store_true")
    g.add_argument("--baseline", action="store_true")
    g.add_argument("--prune", action="store_true")
    g.add_argument("--file")
    g.add_argument("--rename", metavar="MOVES.json")
    g.add_argument("--json", metavar="OUT")
    ap.add_argument("--strict", action="store_true", help="with --check: new violations are errors (exit 1)")
    args = ap.parse_args(argv)
    cfg = load_config(args.config)
    allow_path = args.allow or ALLOW_PATH
    if args.rename:
        data = rename(load_moves(args.rename), load_allow(allow_path), allow_path)
        print("layers: %d allowlist entries rewritten -> %s" % (len(data["entries"]), allow_path))
        return 0
    dm = build(args.addon, cfg)
    if args.baseline:
        data = baseline(violations(dm, cfg), cfg, allow_path)
        print("layers: baseline of %d violation(s) %s -> %s" % (len(data["entries"]), data["counts"], allow_path))
        return 0
    if args.prune:
        data, rp, rs = prune(violations(dm, cfg), load_allow(allow_path), allow_path)
        print("layers: pruned %d entr(ies) and %d symbol(s); %d left -> %s" % (rp, rs, len(data["entries"]), allow_path))
        return 0
    if args.file:
        p = args.file.replace("\\", "/")
        if p not in dm.info:
            print("layers: %s is not a TOC file" % p, file=sys.stderr)
            return 2
        file_report(dm, p)
        return 0
    if args.json:
        with open(args.json, "w", encoding="utf-8") as fh:
            json.dump(to_json(dm), fh, indent=1)
        print("layers: map written -> %s" % args.json)
        return 0
    if args.check:
        lines, viols, new, stale = lint(dm, load_allow(allow_path), strict=args.strict)
        for f, ln, sev, cat, nm, tx in sorted(lines, key=lambda x: (x[0], x[1])):
            print("%s:%d: %s" % (f, ln, tx))
        print("-- layers: %d violation(s) in the map, %d new, %d stale allowlist entr(ies)" % (
            len(viols), len(new), len(stale)))
        return 1 if (args.strict and new) else 0
    report(dm)
    return 0


if __name__ == "__main__":
    sys.exit(main())
