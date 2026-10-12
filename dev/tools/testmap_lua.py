"""The structure of the addon's Lua for move-aware test selection (tools/testmap.py): functions with an identity that
survives a move to another file, and the load-time code of a file as a list of statements.

A file is cut into top-level statements (every function body collapsed to one placeholder token) and functions. Each
function gets a key that does not depend on the file it is in:

    F <path>        `function M:Create()`, `M.f = function()`: the path with local aliases resolved, so `M` bound by
                    `local M = ns.RaidPlanUI` (or `local M = {}` + `ns.RaidPlanUI = M`) gives "F @2.RaidPlanUI:Create"
                    in every file that extends the module (@2 = the second value of `...`, the namespace)
    L <name>        `local function name()`, `local name = function()`
    A <stmt>#<n>    the n-th function written inside a top-level statement (`ns:On("X", function() ... end)`): the
                    statement's text with function bodies collapsed
    <parent> > ...  a function inside another one: its parent's key, then "L name" / "N name" / "A" and an ordinal

Two functions are the same code (equivalent) when their keys match, their parameter lists and own code (comments and
spacing ignored, nested function bodies collapsed) are identical, their parents are equivalent, and every name their
code reads that is a top-level local of their file is bound the same way in both files:

    `...` (same position)           the same constant literal         the same path (`local L = ns.L`)
    `local x = P or {}` / `local x = {}` + `P = x`: the path P (a module table, shared through P)
    an equivalent local function, or a path whose function (the last one defined there) is equivalent
    any other value (a table, a frame, ...): "state", the same text, and every function of the old file that used it
    sits with it in one file of the new program (a cache split over two files is two caches: never equivalent)

Rename rule (a local helper promoted to a kit table): a function keyed "L name" also matches a field function whose
path ends in ".name" (`Mod._.name`, `K.name`) when it is equivalent. Inside a body, the old bare `name` and the new
`<path>.name` count as the same token when `name` was bound to a function equivalent to the one at that path. Only the
last component is compared: a promoted helper must keep its name; a method (`K:name`) never matches, nor does a field
function that became a local.

Where an old function is looked for: a field function ("F <resolved path>") is the last definition of that path in
the new program's load order (a later file redefining it wins, as in the game); any other key first in the file the
old one became (same path, or moved), then anywhere. A path whose root is a local that is no path (`local P =
Define(...)`) stays as written ("F ~P.f"): looked for like a local, never as "the last definition".
Paths: `...` values are @1, @2; `local M = ns:NewModule("X")` binds M to @2.X (and creates it).

Load-time code (Compare.script_problem): each file's top-level statements, in load order, other than function
definitions, local aliases / constants / tables without calls (`local L = ns.L`, `local PAD = 4`, `local t = {}`),
`P = P or {}` and the line-1 guard naming its own file, are load-time code (E). They must be the same texts in the same
order, and the names they read bound the same way. Data (`P = <constant table/value>`, D), field functions (F) and
module registrations (`P = local`, R) are paths defined at load: everything defined before a piece of load-time code
in the old program must still be defined before it when that code may reach it (by name: every name in it, then
transitively in the code of every function called like one of them; an over-estimate), a registered module must
still be registered, and no path may be read into a local or extended before the statement that creates it.

Limits (all err towards a rerun unless noted): this is a token scanner, not a Lua parser; a shadowed name or a table
key spelled like a file local counts as a read of the local. Locals declared inside a top-level block (do/if) are not
tracked: the block itself is load-time code, compared by text. A local holding a table (state) that moved behind a
path (`local cache = K._.cache`) is never equivalent. What a function reads through globals or module fields at run
time is not part of its identity (as before: the functions that write those are checked when called; not seen when
they are only reached through code the suite did not call).
"""
import hashlib
import os
import pickle
import re

VERSION = 4   # of the parse below: bump to drop the disk cache

KEYWORDS = {"and", "break", "do", "else", "elseif", "end", "false", "for", "function", "if", "in", "local", "nil",
            "not", "or", "repeat", "return", "then", "true", "until", "while"}
F = "\x00F"   # a collapsed function

_TOK = re.compile(rb"""
    (--\[(=*)\[.*?\]\2\])                                           # 1 long comment
  | (--[^\n]*)                                                      # 3 comment
  | (\[(=*)\[.*?\]\5\])                                             # 4 long string
  | ("(?:\\.|\\\n|[^"\\\n])*"|'(?:\\.|\\\n|[^'\\\n])*')            # 6 string
  | (0[xX][0-9a-fA-F]+|(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)       # 7 number
  | ([A-Za-z_][A-Za-z0-9_]*)                                        # 8 name
  | (\.\.\.|\.\.|==|~=|<=|>=|[-+*/%^\#<>=(){}\[\];:,.])            # 9 operator
  | (\n)                                                            # 10
  | ([ \t\r\f\v]+)                                                  # 11
  | (.)                                                             # 12 anything else
""", re.S | re.X)
_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*\Z")
_GUARD = ("if", "DisasterZoneBoot", "and", "DisasterZoneBoot", ".", "Run", "(")


def show(text):
    """A statement's text for a message (the collapsed-function placeholder made readable)."""
    return text.replace(F, "function ... end")


def is_name(t):
    return t not in KEYWORDS and bool(_NAME.match(t))


def tokenize(src):
    """[(text, line, first on its line)] of the code tokens (comments and spacing dropped)."""
    out, line, nl = [], 1, True
    for m in _TOK.finditer(src):
        g = m.lastindex
        if g == 10:
            line += 1
            nl = True
            continue
        if g in (11,):
            continue
        text = m.group(0)
        if g in (1, 3):
            line += text.count(b"\n")
            continue
        out.append((text.decode("latin-1"), line, nl))
        nl = False
        if g in (4, 6):
            line += text.count(b"\n")
    return out


class Func(object):
    __slots__ = ("start", "end", "line", "parent", "header", "params", "own", "children", "stmt", "key", "free",
                 "local", "declared")


class Stmt(object):
    __slots__ = ("toks", "funcs", "line", "kind", "text", "target", "decls", "free", "reg", "alias")


class FileInfo(object):
    """One file's statements and functions (a version of it: parsed by content, not by path)."""

    def __init__(self, src):
        self.ok = True
        self.funcs, self.stmts = [], []
        self.by_line = {}
        self.decls = {}       # name -> [(stmt index, raw binding)]
        self.regs = {}        # local name -> path tokens it is registered under (`ns.X = name`)
        self.guard = None     # the path the line-1 guard names
        try:
            self._parse(tokenize(src))
        except (IndexError, ValueError):
            self.ok = False

    # -- parsing ---------------------------------------------------------------------------------------------------
    def _parse(self, toks):
        texts = [t[0] for t in toks]
        n = len(texts)
        funcs, stack = self.funcs, []
        i = 0
        while i < n:
            t = texts[i]
            if t == "function":
                f = Func()
                f.start, f.line, f.end = i, toks[i][1], None
                f.parent = next((e[1] for e in reversed(stack) if e[0] == "f"), None)
                j = i + 1
                while j < n and texts[j] != "(":
                    j += 1
                f.header = tuple(texts[i + 1:j])
                k = j
                while k < n and texts[k] != ")":
                    k += 1
                if k >= n:
                    raise ValueError("unclosed parameter list")
                f.params = " ".join(texts[j + 1:k])
                f.children, f.local, f.key, f.stmt = [], False, None, None
                stack.append(("f", len(funcs)))
                funcs.append(f)
                if f.parent is not None:
                    funcs[f.parent].children.append(len(funcs) - 1)
                self.by_line.setdefault(f.line, []).append(len(funcs) - 1)
                i = k + 1
                continue
            if t in ("if", "do", "repeat"):
                stack.append(("b", t))
            elif t in ("end", "until"):
                if not stack:
                    raise ValueError("unbalanced end")
                e = stack.pop()
                if e[0] == "f":
                    funcs[e[1]].end = i
            i += 1
        if stack:
            raise ValueError("unclosed block")
        # own code of each function: its body with nested functions collapsed
        for fi, f in enumerate(funcs):
            own, pos = [], f.start
            k = f.start + 1
            while texts[k] != "(":
                k += 1
            while texts[k] != ")":
                k += 1
            pos = k + 1
            for c in f.children:
                cf = funcs[c]
                own.extend(texts[pos:cf.start])
                own.append(F)
                pos = cf.end + 1
            own.extend(texts[pos:f.end])
            f.own = tuple(own)
        # nested functions declared `local function x`
        for f in funcs:
            slots = [j for j, t in enumerate(f.own) if t == F]
            for idx, c in enumerate(f.children):
                k = slots[idx]
                if k > 0 and f.own[k - 1] == "local":
                    funcs[c].local = True
        # names a function declares (parameters, locals, loop variables, local functions): not free in it or its
        # nested functions
        for f in funcs:
            d = set(x for x in f.params.replace(",", " ").split() if is_name(x))
            d.update(funcs[c].header[0] for c in f.children if funcs[c].local and funcs[c].header)
            own = f.own
            for k, t in enumerate(own):
                if t == "local" or t == "for":
                    j = k + 1
                    while j < len(own) and (is_name(own[j]) or own[j] == ","):
                        if is_name(own[j]):
                            d.add(own[j])
                        j += 1
            f.declared = d
        for f in funcs:
            d = set(f.declared)
            p = f.parent
            while p is not None:
                d |= funcs[p].declared
                p = funcs[p].parent
            f.free = frozenset(t for k, t in enumerate(f.own) if is_name(t) and t not in d
                               and (k == 0 or f.own[k - 1] not in (".", ":")))
        # top-level statements
        top = []     # (text, line, nl, func index or None)
        i = 0
        tops = [fi for fi, f in enumerate(funcs) if f.parent is None]
        ti = 0
        while i < n:
            if ti < len(tops) and funcs[tops[ti]].start == i:
                f = funcs[tops[ti]]
                top.append((F, toks[i][1], toks[i][2], tops[ti]))
                i = f.end + 1
                ti += 1
                continue
            top.append((texts[i], toks[i][1], toks[i][2], None))
            i += 1
        self._statements(top)
        self._classify()
        self._keys()

    def _statements(self, top):
        cur, bdepth, pdepth, prev = [], 0, 0, None
        stmts = []

        def close():
            if cur:
                stmts.append(list(cur))
                del cur[:]

        for item in top:
            t, line, nl = item[0], item[1], item[2]
            if cur and bdepth == 0 and pdepth == 0:
                if t == ";":
                    close()
                    prev = None
                    continue
                if _ends(prev) and _starts(t) and (nl or prev in ("end", F)):
                    close()
            cur.append(item)
            if t in ("if", "do", "repeat"):
                bdepth += 1
            elif t in ("end", "until"):
                bdepth -= 1
            elif t in ("(", "[", "{"):
                pdepth += 1
            elif t in (")", "]", "}"):
                pdepth -= 1
            prev = t
        close()
        for items in stmts:
            s = Stmt()
            s.toks = tuple(x[0] for x in items)
            s.funcs = [x[3] for x in items if x[3] is not None]
            s.line = items[0][1]
            s.kind, s.target, s.decls, s.reg, s.alias = "effect", None, (), None, None
            s.text = " ".join(s.toks)
            free = set()
            for k, t in enumerate(s.toks):
                if is_name(t) and (k == 0 or s.toks[k - 1] not in (".", ":")):
                    free.add(t)
            s.free = frozenset(free)
            self.stmts.append(s)

    def _classify(self):
        funcs = self.funcs
        declared = set()
        for si, s in enumerate(self.stmts):
            t = s.toks
            if t[:len(_GUARD)] == _GUARD and si == 0 and len(t) > 8 and t[8] == "," and t[9] == "...":
                s.kind = "guard"
                self.guard = _unquote(t[7])
                continue
            if t[0] == "local":
                if len(t) == 2 and t[1] == F:
                    f = funcs[s.funcs[0]]
                    f.local = True
                    name = f.header[0] if f.header else None
                    s.kind, s.decls = "decl", ((name, ("func", s.funcs[0])),)
                    declared.add(name)
                    continue
                eq = _find(t, "=")
                names = [x for x in (t[1:eq] if eq is not None else t[1:]) if is_name(x)]
                exprs = _split_commas(t[eq + 1:]) if eq is not None else []
                decls, effect = [], False
                fq = iter([fi for fi in s.funcs])
                for ni, name in enumerate(names):
                    if ni < len(exprs):
                        d = _desc(exprs[ni], fq)
                    elif exprs and exprs[-1] == ("...",):
                        d = ("vararg", 1 + ni - (len(exprs) - 1))
                    elif exprs and _has_call(exprs[-1]):
                        d = ("state", "<rest of %s>" % " ".join(exprs[-1]), True)
                    else:
                        d = ("state", "nil", False)
                    if d[0] == "func":
                        funcs[d[1]].local = True
                    if (d[0] == "state" and d[2]) or d[0] == "module":
                        effect = True
                    decls.append((name, d))
                s.decls = tuple(decls)
                s.kind = "effect" if effect else "decl"
                declared.update(names)
                continue
            if t[0] in ("if", "for", "while", "do", "repeat", "return", "break"):
                continue   # a block (or the module's return): load-time code
            if t == (F,):
                f = funcs[s.funcs[0]]
                if f.header:
                    s.kind, s.target = "fndef", f.header
                continue
            eq = _find(t, "=")
            if eq is None:
                continue   # a call
            targets = _split_commas(t[:eq])
            exprs = _split_commas(t[eq + 1:])
            if len(targets) == 1 and _is_path(targets[0]) and len(exprs) == 1:
                tgt, e = targets[0], exprs[0]
                if e == (F,):
                    s.kind, s.target = "fndef", tgt
                elif len(e) == 1 and is_name(e[0]) and e[0] in declared:
                    s.kind, s.target, s.reg = "register", tgt, e[0]
                    self.regs.setdefault(e[0], (tgt, si))
                elif e == tgt + ("or", "{", "}"):
                    s.kind, s.target = "ensure", tgt
                elif not _has_call(t):
                    s.kind, s.target = "data", tgt
                    s.text = " ".join(e)
            elif all(_is_path(x) for x in targets) and not _has_call(t):
                s.kind, s.target = "data", targets[0]
            # (any other assignment: load-time code)
        # declarations by name, and file-local locals registered under a path
        for si, s in enumerate(self.stmts):
            if s.decls:
                for name, d in s.decls:
                    if name:
                        self.decls.setdefault(name, []).append((si, d))
            if s.kind == "decl" and len(s.decls) == 1 and s.decls[0][1][0] == "path":
                s.alias = s.decls[0][1][1]

    def _keys(self):
        funcs = self.funcs
        for si, s in enumerate(self.stmts):
            for fi in s.funcs:
                for g in _descendants(funcs, fi):
                    funcs[g].stmt = si
        for si, s in enumerate(self.stmts):
            for k, fi in enumerate(s.funcs):
                f = funcs[fi]
                if f.header and not f.local:
                    p = self.path_str(f.header, si)
                    f.key = "F " + (p if p else "~" + "".join(f.header))
                elif f.header and f.local:
                    f.key = "L " + f.header[0]
                elif s.kind == "fndef" and s.target is not None:
                    p = self.path_str(s.target, si)
                    f.key = "F " + (p if p else "~" + "".join(s.target))
                elif s.kind in ("decl", "effect") and s.decls and any(d == ("func", fi) for _, d in s.decls):
                    f.key = "L " + next(nm for nm, d in s.decls if d == ("func", fi))
                else:
                    f.key = "A %s#%d" % (s.text if s.kind != "data" else " ".join(s.toks), k)
        order = sorted(range(len(funcs)), key=lambda x: funcs[x].start)
        for fi in order:
            f = funcs[fi]
            if f.parent is None:
                continue
            p = funcs[f.parent]
            if f.header and f.local:
                sub = "L " + f.header[0]
            elif f.header:
                sub = "N " + "".join(f.header)
            else:
                sub = "A"
            same = [c for c in p.children if _sub(funcs[c]) == sub]
            f.key = "%s > %s#%d" % (p.key, sub, same.index(fi))

    # -- bindings ----------------------------------------------------------------------------------------------------
    def lookup(self, name, si):
        """(stmt index, raw binding) of the top-level local `name` visible to statement si, or None (a global)."""
        best = None
        for s2, d in self.decls.get(name, ()):
            if s2 < si or (s2 == si and d[0] == "func" and self.funcs[d[1]].header):
                best = (s2, d)
            else:
                break
        return best

    def path_str(self, toks, si, depth=0):
        """A path (`M.a:b`) with its root resolved through local aliases, or None when the root is a local that is not
        a path (a table built here, a frame, ...)."""
        if depth > 20 or not toks:
            return None
        root, rest = toks[0], "".join(toks[1:])
        b = self.lookup(root, si)
        if b is None:
            return root + rest
        s2, d = b
        if d[0] == "vararg":
            return "@%d%s" % (d[1], rest)
        if d[0] in ("path", "ensure", "module"):
            if d[0] == "ensure" and root not in self.regs:
                return None
            p = self.path_str(d[1], s2, depth + 1)
            return p + rest if p else None
        if d[0] == "empty" and root in self.regs:
            reg, rs = self.regs[root]
            if reg[0] == root:
                return None
            p = self.path_str(reg, rs, depth + 1)
            return p + rest if p else None
        return None


def is_field(f):
    """A top-level function stored under a resolved path (`function ns.X:F()`): the last definition is the one."""
    return f.parent is None and f.key.startswith("F ") and not f.key.startswith("F ~")


def _descendants(funcs, fi):
    out, stack = [], [fi]
    while stack:
        x = stack.pop()
        out.append(x)
        stack.extend(funcs[x].children)
    return out


def _sub(f):
    if f.header and f.local:
        return "L " + f.header[0]
    if f.header:
        return "N " + "".join(f.header)
    return "A"


def _unquote(s):
    return s[1:-1] if len(s) >= 2 and s[0] in "\"'" else s


def _ends(t):
    return t is not None and (is_name(t) or t in (")", "]", "}", "end", "...", "true", "false", "nil", F)
                              or t[:1] in ("\"", "'", "[") or t[:1].isdigit())


def _starts(t):
    return is_name(t) or t in ("local", "if", "for", "while", "do", "repeat", "return", "break", "function", F)


def _find(toks, what):
    depth = 0
    for k, t in enumerate(toks):
        if t in ("(", "[", "{"):
            depth += 1
        elif t in (")", "]", "}"):
            depth -= 1
        elif t == what and depth == 0:
            return k
    return None


def _split_commas(toks):
    out, cur, depth = [], [], 0
    for t in toks:
        if t in ("(", "[", "{"):
            depth += 1
        elif t in (")", "]", "}"):
            depth -= 1
        if t == "," and depth == 0:
            out.append(tuple(cur))
            cur = []
        else:
            cur.append(t)
    if cur:
        out.append(tuple(cur))
    return out


def _is_path(e):
    if not e or len(e) % 2 == 0 or not is_name(e[0]):
        return False
    for k in range(1, len(e), 2):
        if e[k] != "." or not is_name(e[k + 1]):
            return False
    return True


def _is_literal(e):
    if len(e) == 1:
        t = e[0]
        return t in ("true", "false", "nil") or t[:1] in ("\"", "'") or t[:1].isdigit() or t.startswith("[")
    return len(e) == 2 and e[0] == "-" and e[1][:1].isdigit()


def _has_call(toks):
    for k in range(1, len(toks)):
        t, p = toks[k], toks[k - 1]
        if t == "(" and (is_name(p) or p in (")", "]")):
            return True
        if (t[:1] in ("\"", "'") or t == "{") and (is_name(p) or p == ")"):
            return True
        if p == ":":
            return True
    return False


def _desc(e, fq):
    """Raw binding of `local x = <e>`."""
    if e == ("...",):
        return ("vararg", 1)
    if e == (F,):
        return ("func", next(fq))
    for _ in range(e.count(F)):
        next(fq, None)
    if _is_path(e):
        return ("path", e)
    if len(e) >= 6 and e[-5:-2] == (":", "NewModule", "(") and e[-1] == ")" and e[-2][:1] in "\"'" \
            and _is_path(e[:-5]):
        return ("module", e[:-5] + (".", _unquote(e[-2])))   # ns:NewModule("X") creates and returns ns.X
    if len(e) >= 4 and e[-3:] == ("or", "{", "}") and _is_path(e[:-3]):
        return ("ensure", e[:-3])
    if e == ("{", "}"):
        return ("empty",)
    if _is_literal(e):
        return ("const", e[0] if len(e) == 1 else "-" + e[1])
    return ("state", " ".join(e), _has_call(e))


# -- parse cache ------------------------------------------------------------------------------------------------------
_MEM = {}


def parse(src, cache_dir=None):
    """FileInfo of a source (memoized by content; on disk under cache_dir/<sha1>.pkl when given)."""
    key = hashlib.sha1(src).hexdigest()
    hit = _MEM.get(key)
    if hit is not None:
        return hit
    path = os.path.join(cache_dir, "%s.v%d.pkl" % (key, VERSION)) if cache_dir else None
    if path and os.path.exists(path):
        try:
            with open(path, "rb") as fh:
                hit = pickle.load(fh)
        except Exception:  # noqa: BLE001
            hit = None
    if hit is None:
        hit = FileInfo(src)
        if path:
            try:
                os.makedirs(cache_dir, exist_ok=True)
                tmp = "%s.%d.tmp" % (path, os.getpid())
                with open(tmp, "wb") as fh:
                    pickle.dump(hit, fh, protocol=pickle.HIGHEST_PROTOCOL)
                os.replace(tmp, path)
            except OSError:
                pass
    _MEM[key] = hit
    return hit


# -- programs ---------------------------------------------------------------------------------------------------------
class Program(object):
    """The files a suite ran (or would run now), in load order: [(path, FileInfo)]."""

    def __init__(self, entries):
        self.files = entries
        self.index = {}       # function key -> [(file index, func index)]
        self.fields = {}      # path of a field function -> (file index, func index) of its last definition
        self.data = {}        # path -> [(file index, stmt index)] of `path = <constant data>`
        self.pos = {}         # path -> file index
        for i, (rel, fi) in enumerate(entries):
            self.pos[rel] = i
            for k, f in enumerate(fi.funcs):
                self.index.setdefault(f.key, []).append((i, k))
                if is_field(f):
                    self.fields[f.key[2:]] = (i, k)
            for si, s in enumerate(fi.stmts):
                if s.kind == "data":
                    p = fi.path_str(s.target, si)
                    if p:
                        self.data.setdefault(p, []).append((i, si))

    def binding(self, i, si, name):
        """The resolved binding of the top-level local `name` seen by statement si of file i (None: a global)."""
        fi = self.files[i][1]
        b = fi.lookup(name, si)
        if b is None:
            return None
        s2, d = b
        kind = d[0]
        if kind == "vararg":
            return ("vararg", d[1])
        if kind == "const":
            return ("const", d[1])
        if kind == "func":
            return ("func", i, d[1])
        if kind in ("path", "ensure", "empty", "module"):
            p = fi.path_str((name,), s2 + 1) if kind in ("ensure", "empty") else fi.path_str(d[1], s2)
            if p:
                return ("path", p)
        text = d[1] if kind == "state" else ("{}" if kind == "empty" else " ".join(d[1]) + " or {}")
        return ("state", text, i, s2, name)

    def data_texts(self, path):
        return [self.files[i][1].stmts[si].text for i, si in self.data.get(path, ())]


def _users(prog, i, s2, name):
    """Who uses the state local `name` declared by statement s2 of file i: keys of the functions there whose code
    reads it under that declaration, and the texts of top-level statements that read it."""
    fi = prog.files[i][1]
    out = set()
    for f in fi.funcs:
        if name in f.free and f.stmt is not None:
            b = fi.lookup(name, f.stmt)
            if b and b[0] == s2:
                out.add(f.key)
    for si, s in enumerate(fi.stmts):
        if si != s2 and name in s.free:
            b = fi.lookup(name, si)
            if b and b[0] == s2:
                out.add("stmt " + s.text)
    return out


class Compare(object):
    """Old program (the version a suite ran) against the new one."""

    def __init__(self, old, new, back=None):
        self.O, self.N = old, new
        self.back = back or {}   # new file index -> index of the old file it was (same path, or moved)
        self._eq = {}

    # functions -------------------------------------------------------------------------------------------------------
    def find(self, oi, ofi, counterpart=None):
        """True when the old function (file oi, func ofi) has an equivalent in the new program (see the module doc)."""
        O, N = self.O, self.N
        f = O.files[oi][1].funcs[ofi]
        key = f.key
        cands = []
        if is_field(f):
            c = N.fields.get(key[2:])
            cands = [c] if c else []
        else:
            allc = N.index.get(key, [])
            if counterpart is not None:
                cands = [c for c in allc if c[0] == counterpart]
            if not cands:
                cands = allc
            if not cands and key.startswith("L ") and f.parent is None:
                name = key[2:]
                cands = [v for p, v in N.fields.items() if p.endswith("." + name)]
        return any(self.eq_func((oi, ofi), c) for c in cands)

    def eq_func(self, a, b):
        k = (a, b)
        if k in self._eq:
            return self._eq[k]
        self._eq[k] = True     # assumed while comparing (recursive helpers): a cycle proves nothing wrong
        r = self._eq_func(a, b)
        self._eq[k] = r
        return r

    def _eq_func(self, a, b):
        O, N = self.O, self.N
        fo, fn = O.files[a[0]][1].funcs[a[1]], N.files[b[0]][1].funcs[b[1]]
        if fo.params != fn.params:
            return False
        if (fo.parent is None) != (fn.parent is None):
            return False
        if fo.parent is not None and not self.eq_func((a[0], fo.parent), (b[0], fn.parent)):
            return False
        if fo.stmt is None or fn.stmt is None:
            return False
        renamed = set()
        if fo.own != fn.own:
            renamed = self._eq_renamed(a[0], fo, b[0], fn)
            if renamed is None:
                return False
        for name in fo.free | fn.free:
            if name in renamed and name not in fn.free:
                continue
            if not self.eq_binding(a[0], fo.stmt, b[0], fn.stmt, name):
                return False
        return True

    def _eq_renamed(self, oi, fo, ni, fn):
        """Own code equal but for old bare `name` = new `<path>.name` (a promoted helper): the set of such names, or
        None when the code differs otherwise."""
        x, y = fo.own, fn.own
        i = j = 0
        names = set()
        while i < len(x) and j < len(y):
            if x[i] == y[j]:
                i += 1
                j += 1
                continue
            t = x[i]
            if not is_name(t) or (i > 0 and x[i - 1] in (".", ":")):
                return None
            # new side: a dotted path ending in t
            k = j
            while k + 2 < len(y) and is_name(y[k]) and y[k + 1] == ".":
                if y[k + 2] == t and (k + 3 >= len(y) or y[k + 3] != "."):
                    break
                k += 2
            else:
                return None
            if not (k + 2 < len(y) and y[k + 2] == t) or (j > 0 and y[j - 1] in (".", ":")):
                return None
            path_toks = tuple(y[j:k + 3])
            p = self.N.files[ni][1].path_str(path_toks, fn.stmt)
            ob = self.O.binding(oi, fo.stmt, t)
            if not p or not ob or ob[0] != "func":
                return None
            c = self.N.fields.get(p)
            if not c or not self.eq_func((ob[1], ob[2]), c):
                return None
            names.add(t)
            i += 1
            j = k + 3
        return names if i == len(x) and j == len(y) else None

    # bindings --------------------------------------------------------------------------------------------------------
    def eq_binding(self, oi, osi, ni, nsi, name):
        ob, nb = self.O.binding(oi, osi, name), self.N.binding(ni, nsi, name)
        if ob is None or nb is None:
            return ob is None and nb is None
        if ob[0] == nb[0]:
            if ob[0] in ("vararg", "const", "path"):
                return ob[1] == nb[1]
            if ob[0] == "func":
                return self.eq_func((ob[1], ob[2]), (nb[1], nb[2]))
            if ob[0] == "state":
                if ob[1] != nb[1]:
                    return False
                k = ("state",) + ob[2:] + nb[2:]
                if k not in self._eq:
                    self._eq[k] = self._eq_state(ob, nb)
                return self._eq[k]
            return False
        if nb[0] == "path":
            if ob[0] == "func":
                c = self.N.fields.get(nb[1])
                return bool(c) and self.eq_func((ob[1], ob[2]), c)
            if ob[0] == "const":
                return self.N.data_texts(nb[1]) == [ob[1]]
        return False

    def _eq_state(self, ob, nb):
        """A state local (a table, a frame) is the same thing only if every function that shared it still does."""
        old_users = _users(self.O, ob[2], ob[3], ob[4])
        known = set(self.N.index) | {u for u in old_users if u.startswith("stmt ")}
        old_users &= known
        new_users = _users(self.N, nb[2], nb[3], nb[4])
        if not old_users <= new_users:
            return False
        name = ob[4]
        same_as_before = {id(fi) for _, fi in self.O.files}   # (parses are shared by content: unchanged files)
        for i, (rel, fi) in enumerate(self.N.files):
            if id(fi) in same_as_before:
                continue   # a file nobody touched cannot have taken a copy of it
            was = self.back.get(i)
            had = set()
            if was is not None:
                had = {d for s2, d in self.O.files[was][1].decls.get(name, ())}
            for s2, d in fi.decls.get(name, ()):
                if (i, s2) == (nb[2], nb[3]) or d[0] not in ("state", "empty") or d in had:
                    continue   # (the same local the file had before: its own, not a copy)
                if _users(self.N, i, s2, name) & old_users:
                    return False
        return True

    # load-time code --------------------------------------------------------------------------------------------------
    def script_problem(self, guards):
        """Why the load-time code differs (text), or None. guards: {file index: own path} per program, so a line-1
        guard naming its own file is not load-time code."""
        O, N = self.O, self.N
        oe, ne = _script(O, guards[0]), _script(N, guards[1])
        oeff = [x for x in oe if x[0] == "E"]
        neff = [x for x in ne if x[0] == "E"]
        for k in range(max(len(oeff), len(neff))):
            a = oeff[k] if k < len(oeff) else None
            b = neff[k] if k < len(neff) else None
            if a is None or b is None or a[1] != b[1]:
                x = b or a
                prog = N if b else O
                return "load-time code changed or moved: %s:%d %s" % (
                    prog.files[x[2]][0], prog.files[x[2]][1].stmts[x[3]].line, show(x[1])[:80])
            for name in O.files[a[2]][1].stmts[a[3]].free:
                if not self.eq_binding(a[2], a[3], b[2], b[3], name):
                    return "load-time code in %s:%d reads %s, now bound differently" % (
                        N.files[b[2]][0], N.files[b[2]][1].stmts[b[3]].line, name)
        # what is defined before each piece of load-time code: never less than before
        so, sn = _segments(oe), _segments(ne)
        missing, extra = set(), set()
        for k in range(len(so)):
            for p in so[k]:
                if p in extra:
                    extra.discard(p)
                else:
                    missing.add(p)
            for p in sn[k]:
                if p in missing:
                    missing.discard(p)
                else:
                    extra.add(p)
            if k < len(oeff) and missing:
                b = neff[k]
                need = self._reach(b)
                late = sorted(p for p in missing if _reaches(need, p))
                if late:
                    return "%s is now defined after load-time code that may use it, %s:%d" % (
                        late[0], N.files[b[2]][0], N.files[b[2]][1].stmts[b[3]].line)
        regs_o = {x[1] for x in oe if x[0] == "R"}
        gone = regs_o & missing
        if gone:
            return "module %s is no longer created" % sorted(gone)[0]
        # a path read or extended before the file that creates it
        po, pn = _order_problems(oe), _order_problems(ne)
        new = sorted(pn - po)
        if new:
            return "%s is used before it is created" % new[0]
        return None

    def _reach(self, item):
        """Paths a piece of load-time code may read or call while it runs: every module path written in it (locals
        resolved: `Atlas:Init()` -> @2.Atlas:Init), then the same in the own code of every function it calls through
        such a path (the last definition of it), a local function of the file, or `self:X()` inside a module's method;
        and so on. Function bodies written inside count only where they are called on the spot (`(function() ...
        end)()`): a handler passed along (`ns:On("X", function() ... end)`) runs later. Not followed: calls on values
        that are no module path (a frame, a parameter, a table of handlers filled earlier)."""
        N = self.N
        reached, done, todo = set(), set(), []

        def scan(i, toks, si, children, mod):
            fi = N.files[i][1]
            n = len(toks)
            j = 0
            while j < n:
                t = toks[j]
                if not is_name(t) or (j > 0 and toks[j - 1] in (".", ":")):
                    j += 1
                    continue
                k = j + 1
                while k + 1 < n and toks[k] in (".", ":") and is_name(toks[k + 1]):
                    k += 2
                chain = toks[j:k]
                call = k < n and (toks[k] in ("(", "{") or toks[k][:1] in ("\"", "'"))
                j = k
                if t == "self" and mod:
                    p = mod + "".join(chain[1:]) if len(chain) > 1 else None
                else:
                    b = fi.lookup(t, si)
                    if b is not None and b[1][0] == "func" and len(chain) == 1:
                        if call:
                            todo.append((i, b[1][1]))
                        continue
                    p = fi.path_str(chain, si)
                if not p:
                    continue
                reached.add(p)
                if call:
                    c = N.fields.get(p)
                    if c is None and ":" not in p[-30:] and "." in p:
                        cut = p.rfind(".")
                        c = N.fields.get(p[:cut] + ":" + p[cut + 1:])
                    if c is not None:
                        todo.append(c)
            slots = [k for k, x in enumerate(toks) if x == F]
            for k, c in zip(slots, children):
                if toks[k + 1:k + 2] == ("(",) or toks[k + 1:k + 3] == (")", "("):
                    g = fi.funcs[c]
                    scan(i, g.own, si, g.children, mod)

        fi = N.files[item[2]][1]
        s = fi.stmts[item[3]]
        scan(item[2], s.toks, item[3], s.funcs, None)
        while todo:
            i, k = todo.pop()
            if (i, k) in done:
                continue
            done.add((i, k))
            f = N.files[i][1].funcs[k]
            mod = None
            if is_field(f):
                path = f.key[2:]
                cut = max(path.rfind("."), path.rfind(":"))
                mod = path[:cut] if cut > 0 else None
            scan(i, f.own, f.stmt if f.stmt is not None else 0, f.children, mod)
        return reached


def _script(prog, guards):
    """[(kind, text or path, file index, stmt index)] in load order. E: load-time code (by text); D / F / R: a path
    defined (data, a field function, a module registered); A: a path read into a local."""
    out = []
    for i, (rel, fi) in enumerate(prog.files):
        if not fi.ok:
            out.append(("E", "<unparsed %s>" % rel, i, 0))
            continue
        for si, s in enumerate(fi.stmts):
            k = s.kind
            if k == "guard":
                if fi.guard == guards.get(i):
                    continue
                out.append(("E", s.text, i, si))
            elif k == "decl":
                if s.alias:
                    p = fi.path_str(s.alias, si)
                    if p:
                        out.append(("A", p, i, si))
            elif k == "ensure":
                continue
            elif k in ("data", "fndef", "register"):
                p = fi.path_str(s.target, si)
                if not p:
                    out.append(("E", s.text, i, si))
                    continue
                if k == "fndef":
                    f = fi.funcs[s.funcs[0]]
                    if f.header and ":" in f.header:
                        p = fi.path_str(f.header, si) or p
                out.append(({"data": "D", "fndef": "F", "register": "R"}[k], p, i, si))
            else:
                out.append(("E", s.text, i, si))
                for name, d in s.decls:
                    if d[0] == "module":
                        p = fi.path_str(d[1], si)
                        if p:
                            out.append(("R", p, i, si))
    return out


def _reaches(reached, p):
    """A path p (defined at load) is used by code that read / called the paths in reached: p itself, something under
    it, or a module above it (one with at least one dot: not the bare namespace)."""
    if p in reached:
        return True
    for r in reached:
        if r.startswith(p) and r[len(p):len(p) + 1] in (".", ":"):
            return True
        if p.startswith(r) and p[len(r):len(r) + 1] in (".", ":") and ("." in r or ":" in r):
            return True
    return False


def _last(path):
    """Last component of a path ("@2.Big:Build" -> "Build")."""
    return re.split(r"[.:]", path)[-1]


def _segments(items):
    """Paths defined (D/F/R) between pieces of load-time code: one list per gap (len = pieces + 1)."""
    segs, cur = [], []
    for x in items:
        if x[0] == "E":
            segs.append(cur)
            cur = []
        elif x[0] in ("D", "F", "R"):
            cur.append(x[1])
    segs.append(cur)
    return segs


def _order_problems(items):
    """Paths read (A) or extended (D/F/R under them) before the module path they belong to is registered (R)."""
    created = {x[1] for x in items if x[0] in ("R", "D")}
    seen, out = set(), set()
    for kind, p, _, _ in items:
        if kind == "E":
            continue
        if kind == "A":
            if p in created and p not in seen:
                out.add(p)
            continue
        q = p
        while True:
            cut = max(q.rfind("."), q.rfind(":"))
            if cut <= 0:
                break
            q = q[:cut]
            if q in created and q not in seen:
                out.add(q)
                break
        seen.add(p)
    return out
