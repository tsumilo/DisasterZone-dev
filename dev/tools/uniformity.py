"""Uniformity guardrail for check.py (refactor 1.4, phase 1E): counts code that bypasses the shared design homes.

Four counts per addon file (comments and string contents are ignored):
    colour  literal colour tuples that equal a design token of UI/Style.lua:
            gold 1,0.82,0 / grey 0.62,0.62,0.62 / card 0.10,0.10,0.12 / edge 0.34,0.34,0.38 (any alpha), and the
            white hairlines/hovers 1,1,1,a with 0 < a < 0.1
    helper  a local text/colour/name helper the shared toolkit already has: "local function Text(" or
            "local Text = function" for Text, newText, Sized, Gradient, gradient, Grad, SlotLabel, ShortName,
            shortName, classOf, Hex, grey, Edge, Fill, NewCard, BuildBanner, NewChip, Now, DemoOn
    font    a SetFont call whose size argument is a number literal (sizes come from ns.Style.FONT)
    raid    a raid table declared again: a table constructor with 3+ raid keys of its own ([532] = ..., Karazhan = ...,
            kara = ...), or a local named INST_SHORT / RAID_SHORT / ART_TOP / RAID_ART / INST_ART / ART_KEY / INST_BY_ID
            (raid information lives in Data/Raids.lua + Core/ItemDB.lua)

The counts are compared with dev/tools/uniformity_baseline.json (per file, per kind): only a count that went UP is
reported, so existing code does not warn and the number can only fall. check.py prints those as WARN lines (ERROR with
--uniformity-strict); "check.py --uniformity" prints the table; "check.py --uniformity-update-baseline" rewrites the
baseline after a cleanup.
"""
import bisect
import json
import os
import re
import time

HERE = os.path.dirname(os.path.abspath(__file__))
BASELINE_PATH = os.path.join(HERE, "uniformity_baseline.json")

KINDS = ("colour", "helper", "font", "raid")
KIND_TEXT = {
    "colour": "literal token colour(s) (use ns.Style colours: S.C.GOLD / SUB / CARD / EDGE / HAIRLINE / HOVER)",
    "helper": "local helper(s) the shared toolkit has (UI:Text, UI:Gradient, UI:Fill, ns.SlotLabel, Util.Now, ...)",
    "font": "numeric SetFont size(s) (use the ns.Style type scale)",
    "raid": "raid table(s) declared again (use ns.Data.RaidMeta / ItemDB:RaidShort / RaidArt)",
}

# Files that are the home of a kind: they define the values, so they are not counted for it.
HOMES = {
    "colour": ("UI/Style.lua",),
    "font": ("UI/Style.lua",),
    "raid": ("Data/Raids.lua", "Core/ItemDB.lua"),
    "helper": (),
}

HELPER_NAMES = ("Text", "newText", "Sized", "Gradient", "gradient", "Grad", "SlotLabel", "ShortName", "shortName",
                "classOf", "Hex", "grey", "Edge", "Fill", "NewCard", "BuildBanner", "NewChip", "Now", "DemoOn")
RAID_TABLE_NAMES = ("INST_SHORT", "RAID_SHORT", "ART_TOP", "RAID_ART", "INST_ART", "ART_KEY", "INST_BY_ID")
RAID_INSTANCE_IDS = {"532", "565", "544", "548", "550", "534", "564", "568", "580"}
RAID_KEYS = {
    # item keys (Data/Items.lua)
    "Karazhan", "GruulsLair", "MagtheridonsLair", "SerpentshrineCavern", "TempestKeep", "HyjalSummit", "MountHyjal",
    "BlackTemple", "ZulAman", "SunwellPlateau",
    # plan keys (raid plans, art)
    "kara", "gruul", "mag", "ssc", "tk", "hyjal", "bt", "za", "swp", "sunwell",
}
RAID_TABLE_MIN_KEYS = 3

_NUM = r"-?(?:\d+\.?\d*|\.\d+)"
_TUPLE_RE = re.compile(r"(?<![\w.])%s(?:\s*,\s*%s){2,}(?![\w.])" % (_NUM, _NUM))  # 3+ numbers in a row
_HELPER_RE = re.compile(r"\blocal\s+(?:function\s+(%s)\s*\(|(%s)\s*=\s*function\b)" % (
    "|".join(HELPER_NAMES), "|".join(HELPER_NAMES)))
_SETFONT_RE = re.compile(r"[:.]\s*SetFont\s*\(")
_RAID_NAME_RE = re.compile(r"\blocal\s+(%s)\s*=" % "|".join(RAID_TABLE_NAMES))
_TABLE_TOKEN_RE = re.compile(r"[{}]|\[\s*(\d+)\s*\]\s*=(?!=)|(?<![.:\w])([A-Za-z_]\w*)\s*=(?!=)")


# ---------------------------------------------------------------------------------------------------------------
# Masking: blank out comments and string contents (keeping newlines, the quotes and every offset)
# ---------------------------------------------------------------------------------------------------------------
_LONG_OPEN_RE = re.compile(r"\[(=*)\[")


def _blank(s):
    return "".join("\n" if ch == "\n" else " " for ch in s)


def mask(text):
    """Return text with comments replaced by spaces and string contents replaced by spaces (same length)."""
    out = []
    i, n = 0, len(text)
    start = 0
    while i < n:
        ch = text[i]
        if ch == "-" and text.startswith("--", i):
            out.append(text[start:i])
            m = _LONG_OPEN_RE.match(text, i + 2)
            if m:
                close = "]" + m.group(1) + "]"
                j = text.find(close, m.end())
                j = n if j < 0 else j + len(close)
            else:
                j = text.find("\n", i)
                j = n if j < 0 else j
            out.append(_blank(text[i:j]))
            i = start = j
            continue
        if ch == "[":
            m = _LONG_OPEN_RE.match(text, i)
            if m:
                out.append(text[start:m.end()])
                close = "]" + m.group(1) + "]"
                j = text.find(close, m.end())
                if j < 0:
                    out.append(_blank(text[m.end():]))
                    i = start = n
                    break
                out.append(_blank(text[m.end():j]))
                out.append(close)
                i = start = j + len(close)
                continue
        if ch == '"' or ch == "'":
            out.append(text[start:i + 1])
            j = i + 1
            while j < n:
                c = text[j]
                if c == "\\":
                    j += 2
                    continue
                if c == ch or c == "\n":
                    break
                j += 1
            j = min(j, n)
            out.append(_blank(text[i + 1:j]))
            if j < n and text[j] == ch:
                out.append(ch)
                j += 1
            i = start = j
            continue
        i += 1
    out.append(text[start:])
    return "".join(out)


# ---------------------------------------------------------------------------------------------------------------
# Counting
# ---------------------------------------------------------------------------------------------------------------
def _close(a, b):
    return abs(a - b) < 1e-6


def token_of(nums):
    """The design token the first numbers of nums (r, g, b[, a]) equal, or None."""
    if len(nums) < 3:
        return None
    r, g, b = nums[:3]
    if _close(r, 1) and _close(g, 0.82) and _close(b, 0):
        return "gold"
    if _close(r, 0.62) and _close(g, 0.62) and _close(b, 0.62):
        return "grey"
    if _close(r, 0.10) and _close(g, 0.10) and _close(b, 0.12):
        return "card"
    if _close(r, 0.34) and _close(g, 0.34) and _close(b, 0.38):
        return "edge"
    if len(nums) >= 4 and _close(r, 1) and _close(g, 1) and _close(b, 1) and 0 < nums[3] < 0.1 - 1e-9:
        return "hairline"
    return None


def tokens_in_run(nums):
    """Every token colour inside a run of number literals (a call like Text(f, 11, 1, 0.82, 0) or a gradient's
    two colours in one argument list): slide over the run, a match uses up its r, g, b (and the alpha of a hairline)."""
    out, i = [], 0
    while i + 3 <= len(nums):
        tok = token_of(nums[i:i + 4])
        if tok:
            out.append(tok)
            i += 4 if tok == "hairline" else 3
        else:
            i += 1
    return out


def _line_at(newlines, pos):
    """1-based line of offset pos; newlines: sorted list of newline offsets."""
    return bisect.bisect_right(newlines, pos) + 1


def _second_arg(masked, start):
    """Text of the 2nd argument of the call whose '(' ends just before start, or None."""
    depth, i, n = 0, start, len(masked)
    arg_start = None
    while i < n:
        c = masked[i]
        if c in "({[":
            depth += 1
        elif c in ")}]":
            if depth == 0:
                return masked[arg_start:i] if arg_start is not None else None
            depth -= 1
        elif c == "," and depth == 0:
            if arg_start is None:
                arg_start = i + 1
            else:
                return masked[arg_start:i]
        i += 1
    return None


def scan(text, relpath=""):
    """Find every uniformity hit in one file's source. Returns {kind: [(line, detail), ...]}."""
    masked = mask(text)
    nl = [m.start() for m in re.finditer("\n", masked)]
    hits = {k: [] for k in KINDS}

    def line(pos):
        return _line_at(nl, pos)

    homes = {k: relpath in HOMES[k] for k in KINDS}

    if not homes["colour"]:
        for m in _TUPLE_RE.finditer(masked):
            try:
                nums = [float(x) for x in re.split(r"\s*,\s*", m.group(0))]
            except ValueError:
                continue
            for tok in tokens_in_run(nums):
                hits["colour"].append((line(m.start()), tok))

    for m in _HELPER_RE.finditer(masked):
        hits["helper"].append((line(m.start()), m.group(1) or m.group(2)))

    if not homes["font"]:
        for m in _SETFONT_RE.finditer(masked):
            arg = _second_arg(masked, m.end())
            if arg is not None and re.match(r"\s*\(?\s*\d", arg):
                hits["font"].append((line(m.start()), arg.strip()))

    if not homes["raid"]:
        raid_lines = {}
        for m in _RAID_NAME_RE.finditer(masked):
            raid_lines[line(m.start())] = m.group(1)
        stack = []  # [start offset, set of raid keys at this table's own level]
        for m in _TABLE_TOKEN_RE.finditer(masked):
            tok = m.group(0)
            if tok == "{":
                stack.append([m.start(), set()])
            elif tok == "}":
                if stack:
                    pos, keys = stack.pop()
                    if len(keys) >= RAID_TABLE_MIN_KEYS:
                        ln = line(pos)
                        raid_lines.setdefault(ln, "table with %d raid keys" % len(keys))
            elif stack:
                key = m.group(1) or m.group(2)
                if (m.group(1) and key in RAID_INSTANCE_IDS) or (m.group(2) and key in RAID_KEYS):
                    stack[-1][1].add(key)
        hits["raid"] = sorted(raid_lines.items())
    return hits


def counts_of(hits):
    return {k: len(v) for k, v in hits.items()}


def scan_file(path, relpath):
    with open(path, "rb") as fh:
        return scan(fh.read().decode("utf-8", "replace"), relpath)


# ---------------------------------------------------------------------------------------------------------------
# Baseline
# ---------------------------------------------------------------------------------------------------------------
def load_baseline(path=BASELINE_PATH):
    if not os.path.exists(path):
        return {}
    with open(path, encoding="utf-8") as fh:
        return json.load(fh).get("files", {})


def save_baseline(files_counts, path=BASELINE_PATH, merge=False):
    """files_counts: {relpath: {kind: n}}. merge=True keeps the entries of files not in files_counts.
    Written one file per line, so a cleanup's diff of the baseline reads like a list of what went down."""
    files = load_baseline(path) if merge else {}
    for f, c in files_counts.items():
        nz = {k: c.get(k, 0) for k in KINDS if c.get(k, 0)}
        if nz:
            files[f] = nz
        else:
            files.pop(f, None)
    totals = {k: sum(v.get(k, 0) for v in files.values()) for k in KINDS}
    about = ("Per-file uniformity counts (dev/tools/uniformity.py). check.py warns when a file's count goes above "
             "these. Refresh with: check.py --uniformity-update-baseline")
    lines = ["{", ' "_about": %s,' % json.dumps(about), ' "generated": %s,' % json.dumps(time.strftime("%Y-%m-%d")),
             ' "totals": %s,' % json.dumps(totals), ' "files": {']
    items = sorted(files.items())
    for i, (f, c) in enumerate(items):
        lines.append("  %s: %s%s" % (json.dumps(f), json.dumps(c), "," if i < len(items) - 1 else ""))
    lines += [" }", "}", ""]
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines))
    return {"totals": totals, "files": files}


def over_baseline(relpath, hits, baseline):
    """[(kind, count, base, hits)] for every kind whose count went above the baseline."""
    base = baseline.get(relpath, {})
    out = []
    for k in KINDS:
        n, b = len(hits[k]), base.get(k, 0)
        if n > b:
            out.append((k, n, b, hits[k]))
    return out


def describe(kind, n, b, hits, max_lines=8):
    lines = ", ".join(str(ln) for ln, _ in hits[:max_lines]) + (", ..." if len(hits) > max_lines else "")
    return "UNIFORMITY %s: %d %s; baseline %d (lines %s)" % (kind, n, KIND_TEXT[kind], b, lines)


def table(rows, baseline):
    """Text table, worst first. rows: [(relpath, counts)]."""
    rows = sorted(rows, key=lambda r: (-sum(r[1].values()), r[0]))
    out = ["%-44s %6s %6s %6s %6s %6s  %s" % ("file", "total", "colour", "helper", "font", "raid", "vs baseline")]
    tot = {k: 0 for k in KINDS}
    tot_base = 0
    for f, c in rows:
        total = sum(c.values())
        if not total and not baseline.get(f):
            continue
        b = baseline.get(f, {})
        bt = sum(b.get(k, 0) for k in KINDS)
        tot_base += bt
        for k in KINDS:
            tot[k] += c.get(k, 0)
        ups = [k for k in KINDS if c.get(k, 0) > b.get(k, 0)]
        delta = total - bt
        mark = ("%+d" % delta if delta else "=") + ("  UP: " + ",".join(ups) if ups else "")
        out.append("%-44s %6d %6d %6d %6d %6d  %s" % (f, total, c["colour"], c["helper"], c["font"], c["raid"], mark))
    total = sum(tot.values())
    out.append("%-44s %6d %6d %6d %6d %6d  %s" % ("TOTAL", total, tot["colour"], tot["helper"], tot["font"],
                                                  tot["raid"], "%+d" % (total - tot_base) if total != tot_base else "="))
    return "\n".join(out)
