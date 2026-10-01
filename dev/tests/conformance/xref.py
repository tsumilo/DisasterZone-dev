"""Cross-module reference extractor for DisasterZone (read-only audit helper).

Usage: python xref.py [--calls] [--missing] [--msgs] [--settings] [--comm] [--slash] [--popups] [--frames]
"""
import os, re, sys, json, collections

ADDON = r"C:\World of Warcraft\_anniversary_\Interface\AddOns\DisasterZone"
TOC_ORDER = []
for line in open(os.path.join(ADDON, "DisasterZone.toc"), encoding="utf-8"):
    line = line.strip()
    if line and not line.startswith("#") and (line.startswith("Core") or line.startswith("UI")):
        TOC_ORDER.append(line.replace("\\", "/"))


def strip(src):
    """Replace comments with spaces and string contents with 'S' placeholders (keep quotes & newlines)."""
    out = []
    i, n = 0, len(src)
    strings = []  # (line, text)
    line = 1
    while i < n:
        c = src[i]
        if src.startswith("--", i):
            m = re.match(r"--\[(=*)\[", src[i:])
            if m:
                close = "]" + m.group(1) + "]"
                j = src.find(close, i + len(m.group(0)))
                j = n if j < 0 else j + len(close)
                seg = src[i:j]
                out.append(re.sub(r"[^\n]", " ", seg))
                line += seg.count("\n")
                i = j
                continue
            j = src.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i))
            i = j
            continue
        if c in "\"'":
            j = i + 1
            buf = []
            while j < n and src[j] != c:
                if src[j] == "\\":
                    buf.append(src[j:j + 2]); j += 2; continue
                if src[j] == "\n":
                    break
                buf.append(src[j]); j += 1
            text = "".join(buf)
            strings.append((line, text))
            out.append(c + re.sub(r"[^\n]", "S", src[i + 1:j]) + c)
            i = j + 1
            continue
        m = re.match(r"\[(=*)\[", src[i:i + 10])
        if m:
            close = "]" + m.group(1) + "]"
            j = src.find(close, i + len(m.group(0)))
            j = n if j < 0 else j + len(close)
            seg = src[i:j]
            strings.append((line, seg))
            out.append(re.sub(r"[^\n]", "S", seg))
            line += seg.count("\n")
            i = j
            continue
        if c == "\n":
            line += 1
        out.append(c)
        i += 1
    return "".join(out), strings


def lineno(src, pos):
    return src.count("\n", 0, pos) + 1


def read_args(s, pos):
    """s[pos] == '(' -> return (argtext, endpos)."""
    depth = 0
    j = pos
    while j < len(s):
        ch = s[j]
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
            if depth == 0:
                return s[pos + 1:j], j
        j += 1
    return s[pos + 1:], len(s)


def split_args(a):
    a = a.strip()
    if not a:
        return []
    toks = re.finditer(r"[A-Za-z_]\w*|[(){}\[\],]", a)
    parts, depth, kw, last = [], 0, 0, 0
    for t in toks:
        v = t.group(0)
        if v in ("function", "if", "do", "repeat"):
            kw += 1
        elif v in ("end", "until"):
            kw -= 1
        elif v in "([{":
            depth += 1
        elif v in ")]}":
            depth -= 1
        elif v == "," and depth == 0 and kw == 0:
            parts.append(a[last:t.start()].strip()); last = t.end()
    parts.append(a[last:].strip())
    return parts


files = {}
raw = {}
for rel in TOC_ORDER:
    p = os.path.join(ADDON, rel)
    src = open(p, encoding="utf-8").read()
    raw[rel] = src
    files[rel], _ = strip(src)

# module alias detection
module_file = {}
aliases = collections.defaultdict(dict)  # file -> alias -> module
for rel, s in files.items():
    for m in re.finditer(r"local\s+(\w+)\s*=\s*ns:NewModule\(\"(\w+)\"\)", raw[rel]):
        aliases[rel][m.group(1)] = m.group(2)
        module_file.setdefault(m.group(2), rel)
    for m in re.finditer(r"^ns\.(\w+)\s*=\s*(\w+)\s*$", raw[rel], re.M):
        aliases[rel][m.group(2)] = m.group(1)
        module_file.setdefault(m.group(1), rel)
    for m in re.finditer(r"local\s+(\w+)\s*=\s*ns\.([A-Z]\w*)\s*(?:$|;|--)", raw[rel], re.M):
        aliases[rel].setdefault(m.group(1), m.group(2))

    # multi-assign aliases: local A, B = ns.X, ns.Y
for rel in list(files):
    for m in re.finditer(r"local\s+([\w\s,]+?)\s*=\s*((?:ns\.[A-Z]\w*\s*,\s*)+ns\.[A-Z]\w*)\s*(?:$|;|--)", raw[rel], re.M):
        names = [x.strip() for x in m.group(1).split(",")]
        mods = [x.strip()[3:] for x in m.group(2).split(",")]
        for a, b in zip(names, mods):
            aliases[rel].setdefault(a, b)

# definitions
defs = collections.defaultdict(dict)  # module -> name -> (file, line, params or None)
for rel, s in files.items():
    for alias, mod in aliases[rel].items():
        if module_file.get(mod) != rel:
            continue
        for m in re.finditer(r"function\s+%s\s*([:.])\s*(\w+)\s*\(([^)]*)\)" % re.escape(alias), s):
            params = [x.strip() for x in m.group(3).split(",") if x.strip()]
            defs[mod][m.group(2)] = (rel, lineno(s, m.start()), m.group(1), params)
        for m in re.finditer(r"(?<![\w.])%s\s*\.\s*(\w+)\s*=\s*(function\s*\(([^)]*)\))?" % re.escape(alias), s):
            if m.group(1) in defs[mod]:
                continue
            params = None
            if m.group(2):
                params = [x.strip() for x in m.group(3).split(",") if x.strip()]
            defs[mod][m.group(1)] = (rel, lineno(s, m.start()), "." if params is not None else "field", params)
    for m in re.finditer(r"function\s+ns\.(\w+)\s*([:.])\s*(\w+)\s*\(([^)]*)\)", s):
        params = [x.strip() for x in m.group(4).split(",") if x.strip()]
        defs[m.group(1)].setdefault(m.group(3), (rel, lineno(s, m.start()), m.group(2), params))
    for m in re.finditer(r"(?<![\w.])ns\.(\w+)\s*\.\s*(\w+)\s*=[^=]", s):
        defs[m.group(1)].setdefault(m.group(2), (rel, lineno(s, m.start()), "field", None))
    # ns.<field> = (top level namespace fields, e.g. ns.SLOTS)
    for m in re.finditer(r"(?<![\w.])ns\.(\w+)\s*=[^=]", s):
        defs["<ns>"].setdefault(m.group(1), (rel, lineno(s, m.start()), "field", None))
    for m in re.finditer(r"function\s+ns:(\w+)\s*\(([^)]*)\)", s):
        defs["<ns>"].setdefault(m.group(1), (rel, lineno(s, m.start()), ":", [x.strip() for x in m.group(2).split(",") if x.strip()]))

# uses
uses = []  # (file, line, module, sep, name, args or None, guarded_text)
for rel, s in files.items():
    patt = r"(?<![\w.])ns\.([A-Z]\w*)\s*([:.])\s*(\w+)"
    for m in re.finditer(patt, s):
        mod, sep, name = m.group(1), m.group(2), m.group(3)
        end = m.end()
        k = end
        while k < len(s) and s[k] in " \t":
            k += 1
        args = None
        if k < len(s) and s[k] == "(":
            a, _ = read_args(s, k)
            args = split_args(a)
        uses.append((rel, lineno(s, m.start()), mod, sep, name, args))
    for alias, mod in aliases[rel].items():
        if module_file.get(mod) == rel:
            continue
        patt = r"(?<![\w.])%s\s*([:.])\s*(\w+)" % re.escape(alias)
        for m in re.finditer(patt, s):
            sep, name = m.group(1), m.group(2)
            k = m.end()
            while k < len(s) and s[k] in " \t":
                k += 1
            args = None
            if k < len(s) and s[k] == "(":
                a, _ = read_args(s, k)
                args = split_args(a)
            uses.append((rel, lineno(s, m.start()), mod, sep, name, args))

if __name__ == "__main__":
    what = set(sys.argv[1:])
    if "--defs" in what:
        for mod in sorted(defs):
            for name, d in sorted(defs[mod].items()):
                print(mod, name, d)
    if "--missing" in what or not what:
        print("== uses of undefined members ==")
        for (rel, ln, mod, sep, name, args) in uses:
            if mod in ("Data",):
                continue
            if name not in defs.get(mod, {}):
                print("%s:%d  ns.%s%s%s" % (rel, ln, mod, sep, name))
    if "--calls" in what:
        print("== arity / separator mismatches ==")
        for (rel, ln, mod, sep, name, args) in uses:
            d = defs.get(mod, {}).get(name)
            if not d or args is None:
                continue
            dfile, dline, dsep, params = d
            if params is None:
                continue
            if dsep in (":", ".") and sep != dsep:
                print("%s:%d  ns.%s%s%s  called with '%s' but defined with '%s' at %s:%d" % (rel, ln, mod, sep, name, sep, dsep, dfile, dline))
            if "..." in params:
                continue
            if len(args) > len(params):
                print("%s:%d  ns.%s%s%s  %d args > %d params %s (%s:%d)" % (rel, ln, mod, sep, name, len(args), len(params), params, dfile, dline))
    if "--order" in what:
        print("== load order: file-scope uses of modules defined later ==")
        idx = {f: i for i, f in enumerate(TOC_ORDER)}
        for (rel, ln, mod, sep, name, args) in uses:
            mf = module_file.get(mod)
            if mf and idx.get(mf, -1) > idx[rel]:
                print("%s:%d  ns.%s%s%s (module in %s)" % (rel, ln, mod, sep, name, mf))

def summary():
    agg = collections.defaultdict(lambda: collections.defaultdict(list))
    for (rel, ln, mod, sep, name, args) in uses:
        mf = module_file.get(mod)
        if mf == rel:
            continue
        agg[(mod, name)][rel].append((ln, None if args is None else len(args)))
    for (mod, name) in sorted(agg):
        d = defs.get(mod, {}).get(name)
        dd = "UNDEF" if not d else "%s:%d %s%s" % (d[0], d[1], d[2], "" if d[3] is None else "(" + ",".join(d[3]) + ")")
        callers = "; ".join("%s:%s" % (os.path.basename(f), ",".join("%d/%s" % (l, a) for l, a in v)) for f, v in agg[(mod, name)].items())
        print("%s.%s  [%s]  <- %s" % (mod, name, dd, callers))

if __name__ == "__main__" and "--summary" in sys.argv:
    summary()
