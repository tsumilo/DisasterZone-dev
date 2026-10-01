import os, re, sys, unicodedata, collections
ROOT = r"C:\World of Warcraft\_anniversary_\Interface\AddOns\DisasterZone"
counts = collections.Counter()
rows = []
for sub in ("Core", "UI", "Data"):
    for dp, dn, fns in os.walk(os.path.join(ROOT, sub)):
        for fn in fns:
            if not fn.endswith(".lua"): continue
            p = os.path.join(dp, fn)
            for ln, line in enumerate(open(p, encoding="utf-8"), 1):
                chars = sorted(set(c for c in line if ord(c) > 127))
                if not chars: continue
                code = line.split("--", 1)[0]  # crude: code part before first comment
                in_code = [c for c in chars if c in code]
                for c in chars: counts[c] += 1
                rows.append((os.path.relpath(p, ROOT), ln, "".join(chars), "CODE" if in_code else "comment", line.strip()[:150]))
for c, n in counts.most_common():
    print("U+%04X %s %-35s %d" % (ord(c), c, unicodedata.name(c, "?"), n))
print()
for r in rows:
    if r[3] == "CODE":
        print("%s:%d [%s] %s" % (r[0], r[1], r[2], r[4]))
